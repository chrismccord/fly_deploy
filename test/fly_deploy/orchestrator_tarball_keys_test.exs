defmodule FlyDeploy.OrchestratorTarballKeysTest do
  use ExUnit.Case, async: true

  alias FlyDeploy.Orchestrator

  describe "tarball_object_key/4" do
    test "gives two deploys of the same mix version distinct keys" do
      first =
        Orchestrator.tarball_object_key(:my_app, "0.1.0", "01KEW7VFV2K1D4NA9GKZYMFW3R", "hot")

      second =
        Orchestrator.tarball_object_key(:my_app, "0.1.0", "01KEW8ABCDEFGHJKMNPQRSTVWX", "hot")

      assert first == "releases/my_app-0.1.0-01KEW7VFV2K1D4NA9GKZYMFW3R.tar.gz"
      assert second == "releases/my_app-0.1.0-01KEW8ABCDEFGHJKMNPQRSTVWX.tar.gz"
    end

    test "keeps blue-green tarballs in a separate key from hot tarballs" do
      assert Orchestrator.tarball_object_key(:my_app, "0.1.0", "ABC", "blue_green") ==
               "releases/my_app-0.1.0-ABC-blue_green.tar.gz"
    end
  end

  describe "stale_tarball_keys/4" do
    @hot_old "releases/my_app-0.1.0-HOT1.tar.gz"
    @hot "releases/my_app-0.1.0-HOT2.tar.gz"
    @legacy_hot "releases/my_app-0.1.0.tar.gz"
    @bg_old "releases/my_app-0.1.0-BG0-blue_green.tar.gz"
    @bg "releases/my_app-0.1.0-BG1-blue_green.tar.gz"

    @keys [@legacy_hot, @hot_old, @hot, @bg_old, @bg]
    @state %{
      "hot_upgrade" => %{"tarball_url" => "https://t3.storage.dev/bucket/" <> @hot},
      "blue_green_upgrade" => %{"tarball_url" => "https://t3.storage.dev/bucket/" <> @bg}
    }

    test "a hot deploy sweeps only unreferenced hot tarballs, including the legacy key" do
      assert Orchestrator.stale_tarball_keys(@keys, :my_app, "hot", @state) ==
               [@legacy_hot, @hot_old]
    end

    test "a blue-green deploy sweeps only unreferenced blue-green tarballs" do
      assert Orchestrator.stale_tarball_keys(@keys, :my_app, "blue_green", @state) == [@bg_old]
    end

    test "a hot deploy keeps blue-green tarballs even when current.json lost the field" do
      state = %{"hot_upgrade" => @state["hot_upgrade"]}

      assert Orchestrator.stale_tarball_keys(@keys, :my_app, "hot", state) ==
               [@legacy_hot, @hot_old]
    end

    test "with no referenced tarball, every tarball of that kind is stale" do
      assert Orchestrator.stale_tarball_keys(@keys, :my_app, "hot", %{"hot_upgrade" => nil}) ==
               [@legacy_hot, @hot_old, @hot]
    end

    test "never touches metadata, locks, results, or another app's tarballs" do
      keys = [
        "releases/my_app-current.json",
        "releases/my_app-deploy.lock",
        "releases/my_app-results/HOT1/machine1.json",
        "releases/my_app_two-0.1.0-X.tar.gz",
        "releases/other-0.1.0-X.tar.gz"
      ]

      assert Orchestrator.stale_tarball_keys(keys, :my_app, "hot", %{}) == []
    end
  end
end
