defmodule PesqueWeb.Router do
  use PesqueWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", PesqueWeb do
    pipe_through :api
  end
end
