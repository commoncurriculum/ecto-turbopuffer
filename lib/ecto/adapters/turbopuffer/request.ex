defmodule Ecto.Adapters.Turbopuffer.Request do
  @moduledoc false
  # Sends the adapter's request bodies through the turbopuffer driver and turns its errors into TP.Error.

  @client_options [:api_key, :region, :base_url, :finch_name, :json_library, :max_retries, :retry_delay]

  def client(config), do: config |> Keyword.take(@client_options) |> Turbopuffer.Client.new()

  def write(client, namespace, body, opts \\ []) do
    client |> Turbopuffer.Client.post("/v2/namespaces/#{path!(namespace)}", body, opts) |> result()
  end

  def query(client, namespace, body, opts \\ []) do
    client |> Turbopuffer.Client.post("/v2/namespaces/#{path!(namespace)}/query", body, opts) |> result()
  end

  def metadata(client, namespace) do
    client |> Turbopuffer.Client.get("/v1/namespaces/#{path!(namespace)}/metadata") |> result()
  end

  def delete_namespace(client, namespace) do
    client |> Turbopuffer.Namespace.new(path!(namespace)) |> Turbopuffer.delete_namespace() |> result()
  end

  @doc "Every namespace name starting with `prefix`, following pagination."
  def namespaces(client, prefix, cursor \\ nil, acc \\ []) do
    opts = if cursor, do: [prefix: prefix, cursor: cursor], else: [prefix: prefix]

    case client |> Turbopuffer.list_namespaces(opts) |> result() do
      {:ok, %{namespaces: namespaces, next_cursor: next}} ->
        names = acc ++ Enum.map(namespaces, & &1["id"])
        if next, do: namespaces(client, prefix, next, names), else: {:ok, names}

      error ->
        error
    end
  end

  defp result({:ok, body}), do: {:ok, body}

  defp result({:error, {:http_error, status, %{"error" => message}}}) do
    {:error, %TP.Error{status: status, message: message}}
  end

  defp result({:error, {:http_error, status, body}}) do
    {:error, %TP.Error{status: status, message: inspect(body)}}
  end

  defp result({:error, exception}) when is_exception(exception) do
    {:error, %TP.Error{message: Exception.message(exception)}}
  end

  defp result({:error, reason}), do: {:error, %TP.Error{message: inspect(reason)}}

  defp path!(namespace) do
    if String.match?(namespace, ~r/\A[A-Za-z0-9\-_.]{1,128}\z/) do
      namespace
    else
      raise ArgumentError, "turbopuffer namespace names must match [A-Za-z0-9-_.]{1,128}, got: #{inspect(namespace)}"
    end
  end
end
