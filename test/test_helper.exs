ExUnit.start()

# Manual mode for the whole suite. In :auto the pool checks a connection out
# implicitly and outside any transaction, which is what let test rows survive
# the test that wrote them. Set once here; each test that touches the database
# owns its connection through Pesque.DataCase.
:ok = Ecto.Adapters.SQL.Sandbox.mode(Pesque.Repo, :manual)
