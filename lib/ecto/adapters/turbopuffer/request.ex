defmodule Ecto.Adapters.Turbopuffer.Request do
  @moduledoc false

  # Sends a request through the driver and reports it the way Ecto's SQL adapters do: a telemetry event with
  # queue and query times, a log line, and errors as TP.Error.

  require Logger

  @queue_time {__MODULE__, :queue_time}

  @doc """
  Finch reports pool waits only to telemetry, in the process making the request. Attaching again is a no-op.
  """
  def attach do
    :telemetry.attach_many(
      @queue_time,
      [[:finch, :queue, :stop], [:finch, :queue, :exception]],
      &__MODULE__.handle_queue_event/4,
      nil
    )
  end

  @doc "Sends a request with the repo's `meta`, returning `{:ok, body}` or `{:error, %TP.Error{}}`."
  def run(meta, method, path, body, opts, kind, namespace, client_opts \\ []) do
    %{client: client, telemetry: {repo, event}} = meta
    start = System.monotonic_time()
    {result, queue_time} = send(client, method, path, body, Keyword.merge(meta.request_opts, client_opts))
    total_time = System.monotonic_time() - start
    measurements = %{total_time: total_time, queue_time: queue_time, query_time: total_time - queue_time}

    :telemetry.execute(event, measurements, %{
      type: :ecto_turbopuffer_query,
      repo: repo,
      kind: kind,
      source: namespace,
      query: redact(body),
      result: result,
      options: Keyword.get(opts, :telemetry_options, [])
    })

    case Keyword.get(opts, :log, meta.log) do
      false -> :ok
      level -> Logger.log(level, fn -> log_message(method, path, body, namespace, result, measurements) end)
    end

    result
  end

  # Finch raises a bare RuntimeError when no connection frees up within the pool timeout. The queue exception
  # event before it says that's what happened, rather than some other RuntimeError.
  defp send(client, method, path, body, client_opts) do
    Process.put(@queue_time, {0, false})

    try do
      result = client |> Turbopuffer.Client.request(method, path, body, client_opts) |> result()
      {result, elem(Process.get(@queue_time), 0)}
    rescue
      error in RuntimeError ->
        case Process.get(@queue_time) do
          {queue_time, true} -> {{:error, %TP.Error{message: String.trim(Exception.message(error))}}, queue_time}
          _ -> reraise error, __STACKTRACE__
        end
    after
      Process.delete(@queue_time)
    end
  end

  @doc false
  def handle_queue_event(event, measurements, _metadata, _config) do
    case Process.get(@queue_time) do
      {queue_time, timed_out} ->
        Process.put(@queue_time, {queue_time + Map.get(measurements, :duration, 0), timed_out or :exception in event})

      nil ->
        :ok
    end
  end

  defp log_message(method, path, body, namespace, result, measurements) do
    {status, error} =
      case result do
        {:ok, _} -> {"OK", ""}
        {:error, error} -> {"ERROR", "\n" <> Exception.message(error)}
      end

    source = if namespace, do: ~s( source="#{namespace}"), else: ""
    times = "db=#{milliseconds(measurements.query_time)}ms queue=#{milliseconds(measurements.queue_time)}ms"
    line = String.upcase(Atom.to_string(method)) <> " " <> path
    line = if body, do: line <> " " <> inspect(redact(body)), else: line
    "TURBOPUFFER #{status}#{source} #{times}\n#{line}#{error}"
  end

  defp milliseconds(native), do: Float.round(System.convert_time_unit(native, :native, :microsecond) / 1_000, 1)

  # Telemetry handlers and logs would otherwise carry the API key a copy from another organization sends.
  defp redact(%{"copy_from_namespace" => %{"source_api_key" => _} = from} = body),
    do: %{body | "copy_from_namespace" => %{from | "source_api_key" => "[REDACTED]"}}

  defp redact(body), do: body

  defp result({:ok, body}), do: {:ok, body}

  # An operation turbopuffer ran in the background fails with its message alone.
  defp result({:error, {:http_error, status, body}}) do
    message =
      cond do
        is_map(body) and is_binary(body["error"]) -> body["error"]
        is_binary(body) -> body
        true -> inspect(body)
      end

    {:error, %TP.Error{status: status, message: message}}
  end

  defp result({:error, reason}) do
    message = if is_exception(reason), do: Exception.message(reason), else: inspect(reason)
    {:error, %TP.Error{message: message}}
  end
end
