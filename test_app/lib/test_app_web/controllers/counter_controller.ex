defmodule TestAppWeb.CounterController do
  use TestAppWeb, :controller

  def increment(conn, _params) do
    new_value = TestApp.Counter.increment()
    json(conn, %{count: new_value})
  end
end
