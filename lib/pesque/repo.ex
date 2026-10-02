defmodule Pesque.Repo do
  use Ecto.Repo, otp_app: :pesque, adapter: Ecto.Adapters.SQLite3
end
