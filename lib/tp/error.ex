defmodule TP.Error do
  @moduledoc """
  A failed turbopuffer request. `status` is the HTTP status, or `nil` when the request never got a response.
  """
  defexception [:status, :message]

  @type t :: %__MODULE__{status: pos_integer() | nil, message: String.t()}
end
