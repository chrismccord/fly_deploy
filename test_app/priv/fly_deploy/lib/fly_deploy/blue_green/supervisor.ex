defmodule FlyDeploy.BlueGreen.Supervisor do
  @moduledoc false
  # Supervises the PeerManager and Poller for blue-green mode.
  #
  # The PeerManager boots the user's app in a peer node.
  # The Poller watches S3 for new releases and tells PeerManager to upgrade.

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    parent_children = Keyword.get(opts, :children, [])
    endpoint = Keyword.get(opts, :endpoint)
    poll_interval = Keyword.get(opts, :poll_interval, 1_000)
    shutdown_timeout = Keyword.get(opts, :shutdown_timeout)
    before_cutover = Keyword.get(opts, :before_cutover)
    after_cutover = Keyword.get(opts, :after_cutover)

    children =
      parent_children ++
        [
          {Task.Supervisor, name: FlyDeploy.BlueGreen.TaskSupervisor},
          {FlyDeploy.BlueGreen.PeerManager,
           otp_app: otp_app,
           endpoint: endpoint,
           shutdown_timeout: shutdown_timeout,
           before_cutover: before_cutover,
           after_cutover: after_cutover},
          {FlyDeploy.Poller, otp_app: otp_app, poll_interval: poll_interval, mode: :blue_green}
        ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
