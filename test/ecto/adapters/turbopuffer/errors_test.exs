defmodule Ecto.Adapters.Turbopuffer.ErrorsTest do
  use TP.Test.Case, async: true

  alias TP.Test.CardStack

  test "raises turbopuffer's errors as TP.Error" do
    Repo.insert!(%CardStack{id: "a", vector: [1.0, 0.0, 0.0]})

    error = assert_raise TP.Error, fn -> Repo.all(from c in "card_stacks", where: c.nope == 1, select: c.id) end
    assert error.status == 400
    assert error.message =~ "attribute not found"
  end

  test "raises connection errors as TP.Error" do
    Repo.put_dynamic_repo(start_supervised!({Repo, name: nil, base_url: "http://127.0.0.1:1", max_retries: 0}))

    error = assert_raise TP.Error, fn -> Repo.all(CardStack) end
    assert error.status == nil
    assert error.message =~ "connection refused"
  end

  test "rejects invalid namespace names before sending" do
    assert_raise ArgumentError, ~r/must match \[A-Za-z0-9-_.\]\{1,128\}, got: "card stacks-card_stacks"/, fn ->
      Repo.all(CardStack, prefix: "card stacks")
    end
  end
end
