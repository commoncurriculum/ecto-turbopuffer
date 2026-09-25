defmodule TP.Test.Case do
  @moduledoc """
  Gives each test its own namespace prefix and deletes those namespaces afterwards, as turbopuffer's testing guide
  recommends (docs/turbopuffer/testing.md).
  """
  use ExUnit.CaseTemplate

  alias TP.Test.Repo

  using do
    quote do
      @moduletag :integration

      import Ecto.Query
      import TP.Query
      import TP.Test.Case, only: [requests: 1]
      alias Ecto.Adapters.Turbopuffer
      alias TP.Test.Repo
    end
  end

  setup do
    prefix = "ecto-tpuf-test-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    Process.put(:tp_test_prefix, prefix)

    on_exit(fn ->
      client = Ecto.Adapters.Turbopuffer.client(Repo)
      {:ok, %{namespaces: namespaces}} = Turbopuffer.Namespace.list(client, prefix: prefix <> "-")

      for %{"id" => name} <- namespaces do
        {:ok, _} = client |> Turbopuffer.Namespace.new(name) |> Turbopuffer.Namespace.delete()
      end
    end)

    {:ok, prefix: prefix}
  end

  @doc "Runs `fun`, returning its result and the requests it sent, as their telemetry metadata."
  def requests(fun) do
    handler = {__MODULE__, make_ref()}
    :telemetry.attach(handler, [:tp, :test, :repo, :query], &__MODULE__.forward/4, self())

    try do
      result = fun.()
      {result, collect([])}
    after
      :telemetry.detach(handler)
    end
  end

  @doc false
  def forward(_event, _measurements, metadata, test), do: if(self() == test, do: send(test, {:tp_request, metadata}))

  defp collect(acc) do
    receive do
      {:tp_request, metadata} -> collect([metadata | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
