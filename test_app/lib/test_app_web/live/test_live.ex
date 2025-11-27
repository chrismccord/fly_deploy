defmodule TestAppWeb.TestLive do
  use Phoenix.LiveView

  def render(assigns) do
    ~H"""
    <FlyDeploy.Components.hot_reload_css socket={@socket} asset="app.css" />
    """
  end

  def mount(_, _, socket) do
    {:ok, socket}
  end
end
