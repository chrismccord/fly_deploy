defmodule Mix.Tasks.FlyDeploy.HotTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.FlyDeploy.Hot

  @config %{fly_config: "fly.toml"}
  @base_args ["deploy", "--build-only", "--push", "--remote-only", "-c", "fly.toml"]

  describe "build_image_args/2" do
    test "builds base fly deploy args" do
      assert Hot.build_image_args(@config, []) == @base_args
    end

    test "appends a --build-arg pair per build_arg option" do
      assert Hot.build_image_args(@config, build_arg: "A=1", build_arg: "B=2") ==
               @base_args ++ ["--build-arg", "A=1", "--build-arg", "B=2"]
    end

    test "appends --no-cache when cache is disabled" do
      assert Hot.build_image_args(@config, cache: false) == @base_args ++ ["--no-cache"]
    end

    test "appends --buildkit when requested" do
      assert Hot.build_image_args(@config, buildkit: true) == @base_args ++ ["--buildkit"]
    end
  end
end
