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

    ## Content-Security-Policy

    This registers a [runtime colocated hook](`Phoenix.LiveView.ColocatedHook`),
    which renders an inline `<script>`. Under a strict CSP (a `script-src` without
    `'unsafe-inline'`) that script is blocked unless it carries the page's nonce.
    Pass it via the `:nonce` attribute:

        <FlyDeploy.Components.hot_reload_css socket={@socket} nonce={@csp_nonce} />

    where `@csp_nonce` is the same nonce emitted in the `Content-Security-Policy`
    response header for the request.
    """
    attr(:asset, :string, default: "app.css")
    attr(:socket, Phoenix.LiveView.Socket, required: true)

    attr(:nonce, :string,
      default: nil,
      doc:
        "CSP nonce for the inline runtime-hook script. Required under a strict `script-src` (no `'unsafe-inline'`); omit otherwise."
    )

    def hot_reload_css(assigns) do
      ~H"""
      <div
        id={"fly-deploy-css-reload-#{@asset}"}
        data-manifest={@socket.endpoint.config(:cache_static_manifest_latest)["assets/#{@asset}"]}
        phx-hook=".FlyDeployCSSReload"
        hidden
      />
      <script :type={Phoenix.LiveView.ColocatedHook} name=".FlyDeployCSSReload" runtime nonce={@nonce}>
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
