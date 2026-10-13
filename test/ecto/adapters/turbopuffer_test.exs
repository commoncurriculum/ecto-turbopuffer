defmodule Ecto.Adapters.TurbopufferTest do
  # Repos that never reach turbopuffer, so these run without an API key. Not async, because one test counts atoms.
  use ExUnit.Case

  import ExUnit.CaptureLog

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

  test "keeps the API key a copy from another organization sends out of telemetry" do
    start_repo(name: nil, base_url: "http://127.0.0.1:1", max_retries: 0)
    handler = make_ref()
    :telemetry.attach(handler, [:tp, :test, :repo, :query], &__MODULE__.send_query/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)

    assert_raise TP.Error, fn ->
      Ecto.Adapters.Turbopuffer.copy(Repo, CardStack,
        from: "source",
        from_region: "aws-us-east-1",
        from_api_key: "tpuf_secret"
      )
    end

    assert_received %{"copy_from_namespace" => %{"source_namespace" => "source", "source_api_key" => "[REDACTED]"}}
  end

  test "logs each request at the repo's level, unless a call passes log: false" do
    start_repo(name: nil, base_url: "http://127.0.0.1:1", max_retries: 0, log: :info)

    log = capture_log(fn -> assert_raise TP.Error, fn -> Repo.all(CardStack) end end)
    assert log =~ ~r/\[info\].*TURBOPUFFER ERROR source="card_stacks" db=[\d.]+ms queue=[\d.]+ms/
    assert log =~ ~s(POST /v2/namespaces/card_stacks/query %{)
    assert log =~ "connection refused"

    assert capture_log(fn -> assert_raise TP.Error, fn -> Repo.all(CardStack, log: false) end end) == ""
  end

  test "a request that can't get a connection from the pool in time raises TP.Error, and reports the wait" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(listener)
    test = self()

    spawn_link(fn ->
      {:ok, _socket} = :gen_tcp.accept(listener)
      send(test, :connected)
      Process.sleep(:infinity)
    end)

    start_repo(
      name: __MODULE__.Pooled,
      base_url: "http://127.0.0.1:#{port}",
      max_retries: 0,
      pools: %{default: [size: 1, count: 1]},
      pool_timeout: 100
    )

    # A server that never answers holds the pool's only connection.
    holder =
      Task.async(fn ->
        Repo.put_dynamic_repo(__MODULE__.Pooled)
        Repo.all(CardStack)
      end)

    assert_receive :connected, 1_000

    handler = make_ref()
    :telemetry.attach(handler, [:tp, :test, :repo, :query], &__MODULE__.send_measurements/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)

    error = assert_raise TP.Error, fn -> Repo.all(CardStack) end
    assert error.message =~ "Finch was unable to provide a connection within the timeout"
    Task.shutdown(holder, :brutal_kill)

    assert_received {:measurements, %{queue_time: queue_time, query_time: query_time, total_time: total_time}}
    assert System.convert_time_unit(queue_time, :native, :millisecond) >= 100
    assert total_time == queue_time + query_time
  end

  def send_query(_event, _measurements, metadata, test), do: send(test, metadata.query)

  def send_measurements(_event, measurements, _metadata, test),
    do: if(self() == test, do: send(test, {:measurements, measurements}))
end
