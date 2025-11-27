defmodule TestAppWeb.Router do
  use TestAppWeb, :router
  import Phoenix.LiveView.Router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", TestAppWeb do
    pipe_through :api

    get "/health", HealthController, :show
    post "/counter/increment", CounterController, :increment
  end

  scope "/", TestAppWeb do
    pipe_through :api

    live "/lv", TestLive, :show
  end
end
