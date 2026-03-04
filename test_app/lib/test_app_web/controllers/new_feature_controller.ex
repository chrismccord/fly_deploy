defmodule TestAppWeb.NewFeatureController do
  @moduledoc """
  A new controller added in v2 to test hot upgrade loading of new modules.
  """
  use TestAppWeb, :controller

  def show(conn, _params) do
    json(conn, %{
      status: "ok",
      version: "v2",
      message: "This controller was added in v2 via hot upgrade"
    })
  end
end
