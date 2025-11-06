defmodule TestAppWeb.HealthController do
  use TestAppWeb, :controller

  def show(conn, _params) do
    counter_info = TestApp.Counter.get_info()

    json(conn, %{
      status: "ok-v3",
      counter: %{
        count: counter_info.count,
        version: counter_info.version,
        pid: inspect(counter_info.pid),
        protocol_version: counter_info.protocol_version,
        string_representation: counter_info.string_representation,
        protocol_consolidated: counter_info.protocol_consolidated
      }
    })
  end
end
