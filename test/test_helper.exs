# GitHub Actions sets a missing secret to an empty string, so treat empty as unset.
api_key =
  case System.get_env("TURBOPUFFER_API_KEY") do
    key when key in [nil, ""] ->
      raise """
      The tests write to real turbopuffer namespaces, so set TURBOPUFFER_API_KEY.
      Each test uses its own namespaces and deletes them when it finishes.
      In CI, add it as the repository's TURBOPUFFER_API_KEY Actions secret.
      """

    key ->
      key
  end

Application.put_env(:ecto_turbopuffer, TP.Test.Repo,
  api_key: api_key,
  region: System.get_env("TURBOPUFFER_REGION", "gcp-us-central1")
)

{:ok, _} = TP.Test.Repo.start_link()

ExUnit.start()
