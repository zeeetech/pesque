ExUnit.start(capture_log: true)

# Manual mode for the whole suite. In :auto the pool checks a connection out
# implicitly and outside any transaction, which is what let test rows survive
# the test that wrote them. Set once here; each test that touches the database
# owns its connection through Pesque.DataCase.
:ok = Ecto.Adapters.SQL.Sandbox.mode(Pesque.Repo, :manual)

# Account creation in multi mode mints did:plc. Never let ordinary tests submit
# those operations to the public directory, and keep did:plc resolution local
# too. PLC-specific tests can configure FakeStore results or replace either
# seam explicitly; the default submission answer is :ok.
Application.put_env(:pesque, :plc_client, Pesque.Plc.TestClient)
Application.put_env(:pesque, :did_resolver_directory, Pesque.Plc.TestClient)
