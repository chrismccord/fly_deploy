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

    test "forwards depot as --depot=<value>" do
      assert Hot.build_image_args(@config, depot: false) == @base_args ++ ["--depot=false"]
      assert Hot.build_image_args(@config, depot: true) == @base_args ++ ["--depot=true"]
    end

    test "omits --depot when not given" do
      refute Enum.any?(Hot.build_image_args(@config, []), &String.starts_with?(&1, "--depot"))
    end
  end

  describe "parse_opts!/1" do
    test "parses known switches" do
      assert Hot.parse_opts!(["--dry-run", "--config", "fly-staging.toml"]) ==
               [dry_run: true, config: "fly-staging.toml"]
    end

    test "raises on unknown switches" do
      assert_raise OptionParser.ParseError, fn -> Hot.parse_opts!(["--bogus"]) end
    end

    test "raises on unexpected positional arguments" do
      assert_raise Mix.Error, fn -> Hot.parse_opts!(["no-depot"]) end
    end

    test "parses --no-depot as depot: false" do
      assert Hot.parse_opts!(["--no-depot"]) == [depot: false]
    end

    test "parses bare --depot as depot: true, matching flyctl" do
      assert Hot.parse_opts!(["--depot"]) == [depot: true]
    end

    test "parses the flyctl spelling --depot=false" do
      assert Hot.parse_opts!(["--depot=false"]) == [depot: false]
    end
  end
end
