defmodule Ecto.Adapters.TurbopufferTest do
  # Repos that never reach turbopuffer, so these run without an API key.
  use ExUnit.Case, async: true

  alias TP.Test.{CardStack, Repo}

  defp start_repo(opts) do
    opts = Keyword.merge([api_key: "unused", region: "gcp-us-central1"], opts)
    repo = start_supervised!({Repo, opts}, id: make_ref())
    Repo.put_dynamic_repo(repo)
    repo
  end

  defp finch(repo), do: Ecto.Adapters.Turbopuffer.client(repo).finch_name

  test "each repo runs its own Finch pool" do
    start_repo(name: __MODULE__.Named)
    assert finch(__MODULE__.Named) == __MODULE__.Named.Finch
    assert is_pid(Process.whereis(__MODULE__.Named.Finch))

    anonymous = start_repo(name: nil)
    other = start_repo(name: nil)
    assert finch(anonymous) != finch(other)
    assert is_pid(Process.whereis(finch(anonymous)))
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
