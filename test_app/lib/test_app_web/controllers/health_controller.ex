defmodule TestAppWeb.HealthController do
  use TestAppWeb, :controller

  def show(conn, _params) do
    counter_info = TestApp.Counter.get_info()

    json(conn, %{
      status: "ok-v3",
      counter: %{
        count: counter_info.count,
        version: counter_info.version,
        pid: inspect(counter_info.pid)
      }
    })
  end
end
