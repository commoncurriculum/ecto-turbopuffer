defmodule TP.ConflictError do
  @moduledoc """
  Raised by `insert_all` with the default `on_conflict: :raise` when some ids already exist. turbopuffer skipped
  those documents and wrote the rest: `ids` lists the skipped ones.
  """
  defexception [:namespace, :ids, :count]

  @type t :: %__MODULE__{namespace: String.t(), ids: [term()], count: non_neg_integer()}

  @impl true
  def message(%__MODULE__{} = error) do
    "#{length(error.ids)} of #{error.count} ids already exist in #{error.namespace}, so they weren't inserted and " <>
      "the rest were: #{inspect(error.ids)}. Pass on_conflict: :replace_all to overwrite them or :nothing to skip " <>
      "them."
  end
end
