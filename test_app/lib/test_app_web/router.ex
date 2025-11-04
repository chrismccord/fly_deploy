defmodule TestAppWeb.Router do
  use TestAppWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", TestAppWeb do
    pipe_through :api

    get "/health", HealthController, :show
    post "/counter/increment", CounterController, :increment
  end
end
