if Code.ensure_loaded?(Phoenix.Component) do
  defmodule FlyDeploy.Components do
    use Phoenix.Component

    @doc """
    Renders a hidden element that triggers CSS reload when static assets change on hot deploy.

    ## Usage

    With a stylesheet in your root layout <head>:

        <link rel="stylesheet" href={~p"/assets/app.css"} />

    Add to your app layout (or suitable dynamic template):

        <FlyDeploy.Components.hot_reload_css socket={@socket} asset="app.css" />
    """
    attr(:asset, :string, default: "app.css")
    attr(:socket, Phoenix.LiveView.Socket, required: true)

    def hot_reload_css(assigns) do
      ~H"""
      <div
        id="fly-deploy-css-reload-#{@asset}"
        data-manifest={@socket.endpoint.config(:cache_static_manifest_latest)["assets/#{@asset}"]}
        phx-hook=".FlyDeployCSSReload"
        hidden
      />
      <script :type={Phoenix.LiveView.ColocatedHook} name=".FlyDeployCSSReload" runtime>
        {
          mounted() {
            this.manifestWas = this.getManifest()
          },
          updated() {
            let newManifest = this.getManifest()
            if(this.manifestWas === newManifest){ return }
            console.log("reloading updated css")

            document.querySelectorAll('link[rel="stylesheet"]').forEach(link => {
              if(link.href.includes(this.manifestWas)) {
                const url = new URL(link.href)
                url.pathname = "/" + newManifest
                url.search = ""
                link.href = url.href
              }
            })
            this.manifestWas = newManifest
          },

          getManifest(){ return this.el.getAttribute("data-manifest")
        }
      }
      </script>
      """
    end
  end
end
