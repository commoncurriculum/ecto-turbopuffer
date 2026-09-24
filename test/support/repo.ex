defmodule TP.Test.Repo do
  use Ecto.Repo, otp_app: :ecto_turbopuffer, adapter: Ecto.Adapters.Turbopuffer

  # Each test writes to namespaces under its own prefix (see TP.Test.Case).
  @impl Ecto.Repo
  def default_options(_operation), do: [prefix: Process.get(:tp_test_prefix)]
end
