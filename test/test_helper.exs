api_key =
  System.get_env("TURBOPUFFER_API_KEY") ||
    raise """
    The tests write to real turbopuffer namespaces, so set TURBOPUFFER_API_KEY.
    Each test uses its own namespaces and deletes them when it finishes.
    """

Application.put_env(:ecto_turbopuffer, TP.Test.Repo,
  api_key: api_key,
  region: System.get_env("TURBOPUFFER_REGION", "gcp-us-central1")
)

{:ok, _} = TP.Test.Repo.start_link()

ExUnit.start()
