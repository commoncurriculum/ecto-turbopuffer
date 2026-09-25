defmodule Ecto.Adapters.TurbopufferTest do
  # Repos that never reach turbopuffer, so these run without an API key. Not async, because one test counts atoms.
  use ExUnit.Case

  alias TP.Test.{CardStack, Repo}

  defp start_repo(opts) do
    opts = Keyword.merge([api_key: "unused", region: "gcp-us-central1"], opts)
    repo = start_supervised!({Repo, opts}, id: make_ref())
    Repo.put_dynamic_repo(repo)
    repo
  end

  defp finch(repo), do: Ecto.Adapters.Turbopuffer.client(repo).finch_name

  test "a named repo runs its own Finch pool" do
    start_repo(name: __MODULE__.Named)
    assert finch(__MODULE__.Named) == __MODULE__.Named.Finch
    assert is_pid(Process.whereis(__MODULE__.Named.Finch))
  end

  test "repos started without a name share the driver's pool, so starting them creates no atoms" do
    assert finch(start_repo(name: nil)) == Turbopuffer.Finch

    atoms = :erlang.system_info(:atom_count)

    for i <- 1..20 do
      start_supervised!({Repo, name: nil, api_key: "unused"}, id: {:anonymous, i})
      :ok = stop_supervised({:anonymous, i})
    end

    assert :erlang.system_info(:atom_count) - atoms < 20

    assert_raise ArgumentError, ~r/shares the turbopuffer driver's pool, so it can't take :pools/, fn ->
      Ecto.Adapters.Turbopuffer.init(repo: Repo, name: nil, telemetry_prefix: [:repo], pools: %{default: [size: 1]})
    end
  end

  test "checks turbopuffer's limits before writing, and says which one" do
    start_repo(name: nil, base_url: "http://127.0.0.1:1", max_retries: 0)
    stack = %CardStack{id: "a", planbook_id: String.duplicate("a", 4_097), vector: [1.0, 0.0, 0.0]}

    assert_raise ArgumentError, ~r/CardStack.planbook_id: it's 4097 bytes, over turbopuffer's 4 KiB limit/, fn ->
      Repo.insert!(stack)
    end
  end

  test "raises connection errors as TP.Error" do
    start_repo(name: nil, base_url: "http://127.0.0.1:1", max_retries: 0)

    error = assert_raise TP.Error, fn -> Repo.all(CardStack) end
    assert error.status == nil
    assert error.message =~ "connection refused"
  end
end
