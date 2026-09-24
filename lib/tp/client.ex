defmodule TP.Client do
  @moduledoc """
  A thin client for turbopuffer's HTTP API. See `docs/turbopuffer/api-overview.md`.

      client = TP.Client.new(api_key: System.fetch_env!("TURBOPUFFER_API_KEY"), region: "gcp-us-central1")
      {:ok, %{"rows" => rows}} = TP.Client.query(client, "card_stacks", %{rank_by: ["id", "asc"], limit: 10})

  Options for `new/1`:

    * `:api_key` - required
    * `:region` - e.g. `"gcp-us-central1"`, see `docs/turbopuffer/regions.md`. Required unless `:base_url` is set.
    * `:base_url` - overrides the regional URL
    * `:receive_timeout` - milliseconds, defaults to 60 seconds
    * `:retry` - Req's retry option, defaults to `:transient`, which retries 408, 429, 5xx and transport errors
  """

  defstruct [:req]

  @type t :: %__MODULE__{req: Req.Request.t()}
  @type result :: {:ok, map()} | {:error, TP.Error.t()}

  @spec new(keyword()) :: t()
  def new(opts) do
    api_key = opts[:api_key] || raise ArgumentError, "turbopuffer needs an :api_key"

    base_url =
      opts[:base_url] ||
        "https://#{opts[:region] || raise(ArgumentError, "turbopuffer needs a :region or :base_url")}.turbopuffer.com"

    req =
      Req.new(
        base_url: base_url,
        auth: {:bearer, api_key},
        retry: Keyword.get(opts, :retry, :transient),
        receive_timeout: Keyword.get(opts, :receive_timeout, 60_000),
        # turbopuffer recommends no compression: clients are CPU-bound, not bandwidth-bound.
        compressed: false
      )

    %__MODULE__{req: req}
  end

  @doc "Writes to a namespace, creating it on first write. See `docs/turbopuffer/write.md`."
  @spec write(t(), String.t(), map()) :: result()
  def write(client, namespace, body), do: request(client, :post, "/v2/namespaces/#{path!(namespace)}", json: body)

  @doc "Queries a namespace. See `docs/turbopuffer/query.md`."
  @spec query(t(), String.t(), map()) :: result()
  def query(client, namespace, body) do
    request(client, :post, "/v2/namespaces/#{path!(namespace)}/query", json: body)
  end

  @doc "A namespace's schema, size, and index status. See `docs/turbopuffer/metadata.md`."
  @spec metadata(t(), String.t()) :: result()
  def metadata(client, namespace), do: request(client, :get, "/v1/namespaces/#{path!(namespace)}/metadata", [])

  @doc "Deletes a namespace and all its documents. See `docs/turbopuffer/delete-namespace.md`."
  @spec delete_namespace(t(), String.t()) :: result()
  def delete_namespace(client, namespace), do: request(client, :delete, "/v2/namespaces/#{path!(namespace)}", [])

  @doc """
  Lists every namespace name, following pagination. See `docs/turbopuffer/namespaces.md`.
  Takes `prefix: "..."` to list only the names starting with it.
  """
  @spec namespaces(t(), keyword()) :: {:ok, [String.t()]} | {:error, TP.Error.t()}
  def namespaces(client, opts \\ []), do: list_namespaces(client, Keyword.take(opts, [:prefix]), [])

  defp list_namespaces(client, params, acc) do
    with {:ok, body} <- request(client, :get, "/v1/namespaces", params: params) do
      names = acc ++ Enum.map(body["namespaces"], & &1["id"])

      case body["next_cursor"] do
        nil -> {:ok, names}
        cursor -> list_namespaces(client, Keyword.put(params, :cursor, cursor), names)
      end
    end
  end

  defp request(%__MODULE__{req: req}, method, url, opts) do
    case Req.request(req, [method: method, url: url] ++ opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: %{"error" => message}}} ->
        {:error, %TP.Error{status: status, message: message}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %TP.Error{status: status, message: inspect(body)}}

      {:error, exception} ->
        {:error, %TP.Error{message: Exception.message(exception)}}
    end
  end

  defp path!(namespace) do
    if String.match?(namespace, ~r/\A[A-Za-z0-9\-_.]{1,128}\z/) do
      namespace
    else
      raise ArgumentError, "turbopuffer namespace names must match [A-Za-z0-9-_.]{1,128}, got: #{inspect(namespace)}"
    end
  end
end
