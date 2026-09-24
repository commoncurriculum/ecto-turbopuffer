defmodule TP.Test.Case do
  @moduledoc """
  Gives each test its own namespace prefix and deletes those namespaces afterwards, as turbopuffer's testing guide
  recommends (docs/turbopuffer/testing.md).
  """
  use ExUnit.CaseTemplate

  alias TP.Test.Repo

  using do
    quote do
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
      {:ok, namespaces} = TP.Client.namespaces(client, prefix: prefix <> "-")
      Enum.each(namespaces, &TP.Client.delete_namespace(client, &1))
    end)

    {:ok, prefix: prefix}
  end
end
