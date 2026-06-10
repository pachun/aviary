// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/aviary"
import topbar from "../vendor/topbar"

// HLS playback hook. Safari (incl. iOS) plays HLS natively — just set
// the src and the browser handles the rest, including AirPlay button
// rendering when AirPlay devices are present on the network. Every
// other browser needs HLS.js to consume the manifest and feed MSE.
//
// On iOS specifically, we trigger the system video player via
// webkitEnterFullScreen() rather than relying on the inline HTML5
// controls. The system player gives us:
//   * Safe-area-aware controls (no clipping behind rounded corners)
//   * Native AirPlay picker
//   * Picture-in-picture
//   * The same UI as Apple TV+/Safari, so it feels native
// When the user dismisses it (Done button or swipe), we push a
// close_player event back to LiveView to tear the overlay down.
//
// The HLS instance is destroyed on hook teardown so closing the player
// stops the stream and releases the bandwidth.
const HlsPlayer = {
  mounted() {
    const video = this.el
    const src = video.dataset.src
    const resumeAt = parseFloat(video.dataset.resumeAt || "0")

    if (video.canPlayType("application/vnd.apple.mpegurl")) {
      video.src = src
    } else if (window.Hls && window.Hls.isSupported()) {
      const hls = new window.Hls()
      hls.loadSource(src)
      hls.attachMedia(video)
      this.hls = hls
    } else {
      video.src = src
    }

    // Seek to the saved resume position once the video has enough
    // metadata to know its duration / seekable ranges.
    if (resumeAt > 0) {
      const seekToResume = () => {
        try { video.currentTime = resumeAt } catch (e) { /* ignore */ }
      }
      if (video.readyState >= 1) {
        seekToResume()
      } else {
        video.addEventListener("loadedmetadata", seekToResume, {once: true})
      }
    }

    // Progress reporting: every 10 seconds while playing, plus on each
    // pause (which catches close, seek, system fullscreen exit, etc).
    // 1-second floor to ignore the initial transient.
    const reportProgress = () => {
      if (video.currentTime > 1) {
        this.pushEvent("report_progress", {position: video.currentTime})
      }
    }
    this.progressInterval = setInterval(() => {
      if (!video.paused) reportProgress()
    }, 10000)
    video.addEventListener("pause", reportProgress)

    if (this.isIOS() && video.webkitEnterFullScreen) {
      const enterNativeFullscreen = () => {
        try {
          video.webkitEnterFullScreen()
        } catch (e) {
          console.warn("iOS native fullscreen unavailable:", e)
        }
      }

      if (video.readyState >= 1) {
        enterNativeFullscreen()
      } else {
        video.addEventListener("loadedmetadata", enterNativeFullscreen, {once: true})
      }

      video.addEventListener("webkitendfullscreen", () => {
        this.pushEvent("close_player", {})
      })
    }
  },

  destroyed() {
    if (this.progressInterval) clearInterval(this.progressInterval)
    if (this.hls) this.hls.destroy()
  },

  isIOS() {
    return /iPad|iPhone|iPod/.test(navigator.userAgent) ||
      (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1)
  },
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, HlsPlayer},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

