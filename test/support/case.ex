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
end
