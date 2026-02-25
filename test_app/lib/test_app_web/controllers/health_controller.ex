defmodule TestAppWeb.HealthController do
  use TestAppWeb, :controller

  def show(conn, _params) do
    counter_info = TestApp.Counter.get_info()
    fly_deploy_vsn = FlyDeploy.current_vsn()

    priv_content =
      case File.read(Application.app_dir(:test_app, "priv/deploy_test.txt")) do
        {:ok, data} -> String.trim(data)
        {:error, _} -> nil
      end

    nif_result =
      if Code.ensure_loaded?(Bcrypt) do
        try do
          hash = Bcrypt.hash_pwd_salt("nif_test")
          if is_binary(hash) and String.starts_with?(hash, "$2"), do: hash, else: "bad_hash"
        rescue
          e -> "error: #{Exception.message(e)}"
        end
      else
        nil
      end

    json(conn, %{
      status: "ok-v1",
      components_defined: Code.ensure_loaded?(FlyDeploy.Components),
      fly_deploy_vsn: fly_deploy_vsn,
      compile_config: Application.get_env(:test_app, :compile_version),
      runtime_config: Application.get_env(:test_app, :runtime_version),
      new_dep_loaded: Code.ensure_loaded?(NimbleCSV),
      nif_result: nif_result,
      priv_file: priv_content,
      counter: %{
        count: counter_info.count,
        version: counter_info.version,
        pid: inspect(counter_info.pid),
        protocol_version: counter_info.protocol_version,
        string_representation: counter_info.string_representation,
        protocol_consolidated: counter_info.protocol_consolidated,
      }
    })
  end
end
