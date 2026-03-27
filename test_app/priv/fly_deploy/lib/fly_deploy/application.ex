defmodule FlyDeploy.Application do
  @moduledoc false
  use Application

  def start(_type, _args) do
    children = [
      {Registry, keys: :duplicate, name: FlyDeploy.Registry}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: FlyDeploy.AppSupervisor)
  end
end
