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
    // pause (which catches close, seek, system fullscreen exit, etc),
    // plus once on natural end so the server can mark Played without
    // relying on a partial-watch threshold. 1-second floor ignores
    // the initial transient.
    const reportProgress = () => {
      if (video.currentTime > 1) {
        this.pushEvent("report_progress", {
          position: video.currentTime,
          duration: Number.isFinite(video.duration) ? video.duration : null,
        })
      }
    }
    this.progressInterval = setInterval(() => {
      if (!video.paused) reportProgress()
    }, 10000)
    video.addEventListener("pause", reportProgress)
    video.addEventListener("ended", reportProgress)

    // Auto-hide controls after stillness — mirrors native HTML5 video
    // behavior. Any mouse movement or touch shows controls and
    // restarts the 3s hide timer; while paused, controls stay
    // visible. The overlay toggles a data attribute that Tailwind
    // group-data variants consume to fade each control cluster.
    const overlay = video.closest('[id^="player-overlay-"]')
    if (overlay) {
      let hideTimer
      const showControls = () => {
        overlay.dataset.controlsVisible = "true"
        clearTimeout(hideTimer)
        if (!video.paused) {
          hideTimer = setTimeout(() => {
            overlay.dataset.controlsVisible = "false"
          }, 3000)
        }
      }

      overlay.addEventListener("mousemove", showControls)
      overlay.addEventListener("touchstart", showControls)
      video.addEventListener("play", showControls)
      video.addEventListener("pause", () => {
        overlay.dataset.controlsVisible = "true"
        clearTimeout(hideTimer)
      })

      showControls()
      this.controlsHideTimer = hideTimer
    }

    // Skip Intro pill — driven by the Intro Skipper Jellyfin plugin.
    // The button (rendered by the LV) carries data-skip-target=end and
    // expects data-visible toggling based on whether currentTime is
    // inside the intro range. We add a tiny lead-out (3s) before the
    // computed end so the pill disappears before the intro actually
    // ends, preventing a "blink in and immediately out" feel when the
    // user is right at the cutoff.
    const introStart = parseFloat(video.dataset.introStart || "")
    const introEnd = parseFloat(video.dataset.introEnd || "")
    if (Number.isFinite(introStart) && Number.isFinite(introEnd) && introEnd > introStart) {
      const skipButton = document.getElementById(`skip-intro-${video.id.replace("player-", "")}`)
      if (skipButton) {
        const updateSkipVisibility = () => {
          const t = video.currentTime
          const inIntro = t >= introStart && t < introEnd - 3
          skipButton.dataset.visible = inIntro ? "true" : "false"
        }
        video.addEventListener("timeupdate", updateSkipVisibility)
      }
    }

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
    if (this.controlsHideTimer) clearTimeout(this.controlsHideTimer)
    if (this.hls) this.hls.destroy()
  },

  isIOS() {
    return /iPad|iPhone|iPod/.test(navigator.userAgent) ||
      (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1)
  },
}

// Marquee hook — three responsibilities, all driven by the row's
// scroll state:
//
//   1. Restore scrollLeft on mount from sessionStorage, so a row
//      whose user navigated away comes back to the same scroll
//      position. mounted() fires whenever the wrapper enters the
//      DOM, which handles both sync-rendered rows (Home) and
//      rows whose items arrive asynchronously after the initial
//      page-loading-stop event (Discover, Search).
//
//   2. Track whether the row CAN scroll further in either direction
//      and set data-can-scroll-left / data-can-scroll-right on the
//      wrapper accordingly. The marquee component's CSS reads those
//      attributes through tailwind's group-data-[…=true]/marquee:
//      variants and fades in the edge scroll buttons only when more
//      content actually exists in that direction. A row that fits
//      its viewport exactly shows nothing (correct: it's not
//      scrollable; no need to suggest it is).
//
//   3. Wire the edge buttons to scroll the row by ~80% of its visible
//      width when clicked. 80% (not 100%) preserves a strip of
//      overlap on the trailing side so the user can see continuity
//      with where they just were. Smooth scroll by default; honor
//      prefers-reduced-motion by jumping instead.
const Marquee = {
  mounted() {
    const ul = this.el.querySelector("ul")
    if (!ul) return
    this._ul = ul

    // Restore previous scrollLeft, if any.
    const key = ul.dataset.marqueeKey
    if (key) {
      const path = window.location.pathname
      try {
        const saved = JSON.parse(sessionStorage.getItem(SCROLL_STORE_KEY) || "{}")[path]
        const x = saved && saved.rows && saved.rows[key]
        if (typeof x === "number") ul.scrollLeft = x
      } catch {
        // sessionStorage unavailable; the restore is polish, not
        // required behavior. No-op.
      }
    }

    // Edge-button visibility tracking. Use set/remove with an
    // explicit "true" value so the tailwind variant
    // group-data-[can-scroll-X=true] matches on the value rather
    // than mere attribute presence — some tailwind v4 builds compile
    // the two cases differently.
    this._update = () => {
      const canLeft = ul.scrollLeft > 0
      // -1px epsilon absorbs sub-pixel rounding at the exact end of
      // the scroll range so the right button doesn't flicker on the
      // final frame of a fling-scroll.
      const canRight = ul.scrollLeft + ul.clientWidth < ul.scrollWidth - 1
      if (canLeft) {
        this.el.setAttribute("data-can-scroll-left", "true")
      } else {
        this.el.removeAttribute("data-can-scroll-left")
      }
      if (canRight) {
        this.el.setAttribute("data-can-scroll-right", "true")
      } else {
        this.el.removeAttribute("data-can-scroll-right")
      }
    }
    this._update()
    ul.addEventListener("scroll", this._update, { passive: true })

    // Recompute when the row's viewport-sized box changes (window
    // resize, sidebar collapse, etc). ResizeObserver fires AFTER
    // layout, so a synchronous _update here reads correct values.
    this._ro = new ResizeObserver(this._update)
    this._ro.observe(ul)

    // The hard case: when one row's items load (Discover streams a
    // separate async fetch per service), LiveView re-renders the
    // page template and morphdom replaces the <li> children inside
    // EVERY marquee's <ul> — even rows whose logical content didn't
    // change. That fires every row's MutationObserver at the same
    // moment, and a sync scrollWidth read inside the MO callback
    // sees mid-reflow values (or freshly-replaced <img>s the browser
    // hasn't measured yet), decides canRight=false, and snaps every
    // other row's chevron away the instant the slow row's chevron
    // appears.
    //
    // The fix is to never trust a synchronous read taken at a
    // potentially-bad moment. scheduleBackoff queues a series of
    // recomputes at staggered delays after any disruptive event;
    // by 1500ms the browser has definitely settled. Calling it
    // again resets the schedule rather than stacking it, so a
    // burst of mutations doesn't pile up timers.
    this._backoffTimers = []
    const scheduleBackoff = () => {
      this._backoffTimers.forEach(clearTimeout)
      this._backoffTimers = [0, 100, 500, 1500].map((delay) =>
        setTimeout(this._update, delay)
      )
    }

    // Image-load listeners cover the related case where a row's
    // cards arrive but their <img>s haven't decoded yet. Cached
    // images often mark complete=true between morphdom finishing
    // and our MO callback firing, which would otherwise let the
    // load event slip past unobserved — so for complete images we
    // run the backoff immediately rather than waiting on a load
    // event that already fired.
    const watchImage = (img) => {
      if (img.complete) {
        scheduleBackoff()
        return
      }
      img.addEventListener("load", scheduleBackoff, { once: true })
      img.addEventListener("error", scheduleBackoff, { once: true })
    }
    ul.querySelectorAll("img").forEach(watchImage)

    // MO does NOT call _update synchronously — that's the bug we're
    // dodging. It only schedules the backoff and wires up image
    // watchers on any new children.
    this._mo = new MutationObserver((mutations) => {
      scheduleBackoff()
      for (const m of mutations) {
        for (const node of m.addedNodes) {
          if (node instanceof Element) {
            node.querySelectorAll("img").forEach(watchImage)
          }
        }
      }
    })
    this._mo.observe(ul, { childList: true })

    // First-paint race: mount can fire before the browser has run
    // layout for our subtree at all.
    this._raf = requestAnimationFrame(this._update)
    scheduleBackoff()

    // Edge-button click → page-step scroll. behavior=smooth gives a
    // controlled slide; prefers-reduced-motion users get an instant
    // jump instead, because scrollBy({behavior:'smooth'}) ignores the
    // CSS @media query — we have to honor it explicitly here.
    const prefersReducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches
    const behavior = prefersReducedMotion ? "auto" : "smooth"
    this._leftBtn = this.el.querySelector('[data-marquee-scroll="left"]')
    this._rightBtn = this.el.querySelector('[data-marquee-scroll="right"]')
    // Clamp the scroll target explicitly in JS rather than relying on
    // the browser to clamp scrollBy(...) against the row's bounds.
    // Reason: `snap-x snap-mandatory` on the <ul> combined with
    // smooth-scroll on iOS Safari renders an intermediate animation
    // frame past the snap target before snap-correcting back. With
    // 2 thumbnails on a 360px viewport that intermediate frame shows
    // ~one-card-width of blank space on the left during the
    // animation, even though scrollLeft ultimately settles at 0.
    // scrollTo({left: clamped_target}) skips the overshoot entirely.
    const step = () => Math.round(ul.clientWidth * 0.8)
    this._onLeftClick = () => {
      const target = Math.max(0, ul.scrollLeft - step())
      ul.scrollTo({ left: target, behavior })
    }
    this._onRightClick = () => {
      const maxLeft = ul.scrollWidth - ul.clientWidth
      const target = Math.min(maxLeft, ul.scrollLeft + step())
      ul.scrollTo({ left: target, behavior })
    }
    if (this._leftBtn) this._leftBtn.addEventListener("click", this._onLeftClick)
    if (this._rightBtn) this._rightBtn.addEventListener("click", this._onRightClick)
  },

  destroyed() {
    if (this._ro) this._ro.disconnect()
    if (this._mo) this._mo.disconnect()
    if (this._raf) cancelAnimationFrame(this._raf)
    if (this._backoffTimers) this._backoffTimers.forEach(clearTimeout)
    if (this._ul && this._update) {
      this._ul.removeEventListener("scroll", this._update)
    }
    if (this._leftBtn && this._onLeftClick) {
      this._leftBtn.removeEventListener("click", this._onLeftClick)
    }
    if (this._rightBtn && this._onRightClick) {
      this._rightBtn.removeEventListener("click", this._onRightClick)
    }
  },
}

// AutoFocus hook — focuses the element on mount and parks the cursor
// at the end of any pre-filled value (e.g. return-navigation to
// /search with the previous query preserved). Works on desktop.
// Mobile (iOS Safari) won't pop the soft keyboard from this kind of
// programmatic focus — that's an OS-level restriction we couldn't
// get around without a same-page focus gesture; for /search the
// user has to tap the field once after landing.
const AutoFocus = {
  mounted() {
    this.el.focus()
    const len = this.el.value.length
    this.el.setSelectionRange(len, len)
  },
}

// AutoDismissFlash — after the flash mounts, wait long enough for the
// user to read it (info: 4s, error: 6s — errors warrant more time)
// and then fire the flash card's own phx-click. That click is already
// wired to push `lv:clear-flash` AND run the slide-out transition, so
// the auto-dismiss is visually identical to a manual dismiss; we're
// just triggering it on a timer instead of waiting for the user.
//
// Hover pauses the timer — if the user is reading and not in a hurry,
// the flash sticks around until they move the cursor off. Helpful for
// longer error copy. Manual X-click cleanup is handled separately by
// the existing phx-click.
const AutoDismissFlash = {
  mounted() {
    const kind = this.el.id.replace("flash-", "")
    const ms = kind === "error" ? 6000 : 4000
    this.start(ms)
    this.el.addEventListener("mouseenter", () => this.cancel())
    this.el.addEventListener("mouseleave", () => this.start(ms))
  },
  start(ms) {
    this.cancel()
    this.timer = window.setTimeout(() => this.el.click(), ms)
  },
  cancel() {
    if (this.timer) {
      clearTimeout(this.timer)
      this.timer = null
    }
  },
  destroyed() {
    this.cancel()
  },
}

// One-time install hint. Fired exactly once per device when an iOS
// Safari visitor lands on aviary without having added it to the home
// screen yet. Plants the seed; doesn't nag. Source of truth for the
// install steps is the Settings page (rendered via Layouts.install_steps);
// this toast just points them there.
//
// Trigger conditions (ALL must be true):
//   1. <html data-needs-install="true"> — set synchronously in
//      root.html.heex by the iOS-detection script.
//   2. localStorage doesn't carry the "shown" flag yet.
//
// The flash group container is in Layouts.flash_group; we insert a
// hand-rolled card that matches the styling of <.flash> so the toast
// reads as part of the same family. Auto-dismiss + manual click are
// both wired to fade-out + persist.
function maybeShowInstallHint() {
  if (!document.documentElement.getAttribute("data-needs-install")) return
  const HINT_KEY = "aviary:install-hint-shown"
  if (localStorage.getItem(HINT_KEY)) return

  const group = document.getElementById("flash-group")
  if (!group) return

  const toast = document.createElement("div")
  toast.id = "flash-install-hint"
  toast.setAttribute("role", "alert")
  toast.className = [
    "w-80 sm:w-96 bg-surface border border-rule shadow-md rounded-sm cursor-pointer",
    "font-sans text-[0.85rem] text-ink",
    "transition-all duration-300 ease-out",
    "opacity-0 translate-y-2",
  ].join(" ")
  toast.innerHTML = `
    <div class="flex items-start gap-3 px-4 py-3">
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" class="size-4 text-muted shrink-0 mt-0.5">
        <path stroke-linecap="round" stroke-linejoin="round" d="M9 8.25H7.5a2.25 2.25 0 0 0-2.25 2.25v9a2.25 2.25 0 0 0 2.25 2.25h9a2.25 2.25 0 0 0 2.25-2.25v-9a2.25 2.25 0 0 0-2.25-2.25H15M9 12l3 3m0 0 3-3m-3 3V2.25" />
      </svg>
      <div class="flex-1 min-w-0">
        <p class="text-muted">Add this app to your home screen for the best experience. Find the steps in Settings.</p>
      </div>
      <button type="button" aria-label="close" class="shrink-0 -mr-1 -mt-1 p-1 rounded-sm cursor-pointer">
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="size-4 text-muted">
          <path d="M6.28 5.22a.75.75 0 0 0-1.06 1.06L8.94 10l-3.72 3.72a.75.75 0 1 0 1.06 1.06L10 11.06l3.72 3.72a.75.75 0 1 0 1.06-1.06L11.06 10l3.72-3.72a.75.75 0 0 0-1.06-1.06L10 8.94 6.28 5.22z" />
        </svg>
      </button>
    </div>
  `

  const dismiss = () => {
    localStorage.setItem(HINT_KEY, String(Date.now()))
    toast.classList.add("opacity-0", "translate-y-2")
    window.setTimeout(() => toast.remove(), 300)
  }
  toast.addEventListener("click", dismiss)

  group.appendChild(toast)

  // Force a frame so the slide-in transition runs from the initial
  // opacity-0/translate-y-2 to the visible state.
  requestAnimationFrame(() => {
    toast.classList.remove("opacity-0", "translate-y-2")
  })

  // Auto-dismiss. Slightly longer than info flashes (6s vs 4s) so a
  // distracted user has time to read it.
  let timer = window.setTimeout(dismiss, 6000)
  toast.addEventListener("mouseenter", () => {
    if (timer) { clearTimeout(timer); timer = null }
  })
  toast.addEventListener("mouseleave", () => {
    if (!timer) timer = window.setTimeout(dismiss, 6000)
  })
}

// Fire on every full page load (LiveView nav doesn't reload the document,
// but DOMContentLoaded fires once per real navigation). localStorage gate
// inside the function prevents repeats.
window.addEventListener("DOMContentLoaded", maybeShowInstallHint)

// MobileTopBar — controls the iOS-style fade-in of the sticky mobile
// top bar. The bar starts at opacity-0 (hidden, inert). On mount we
// look for an element marked `data-mobile-top-bar-trigger` in the
// page (typically the body title), then watch it with
// IntersectionObserver. When the trigger element scrolls OUT of the
// visible area (above the top 50px of viewport, accounting for the
// bar's own visual height), we toggle `data-show` on the bar — the
// Tailwind variant `data-[show]:opacity-100` then fades it in.
//
// `inert` is toggled alongside so the hidden bar can't trap focus.
//
// Falls back to "always visible" if no trigger exists on the page —
// better than an invisible bar the user can't get to.
const MobileTopBar = {
  mounted() {
    const trigger = document.querySelector("[data-mobile-top-bar-trigger]")
    if (!trigger) {
      // No trigger on this page; just show the bar always.
      this.el.dataset.show = "true"
      this.el.inert = false
      return
    }
    this.el.inert = true
    this._observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          delete this.el.dataset.show
          this.el.inert = true
        } else {
          this.el.dataset.show = "true"
          this.el.inert = false
        }
      },
      // The negative top rootMargin treats the top ~50px of viewport
      // as "outside" — so the trigger is considered intersecting only
      // when it's at least 50px below the top, i.e., not yet covered
      // by the bar. The bar fades in exactly as the trigger title
      // would visually disappear behind it.
      {rootMargin: "-50px 0px 0px 0px", threshold: 0}
    )
    this._observer.observe(trigger)
  },
  destroyed() {
    if (this._observer) this._observer.disconnect()
  },
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, HlsPlayer, Marquee, AutoFocus, MobileTopBar, AutoDismissFlash},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// Scroll restoration across LiveView navigation. The default soft-nav
// re-mounts the destination LV but doesn't restore the source page's
// scroll position on the way back — so a user who scrolled four rows
// down on /discover, scrolled a marquee sideways, clicked a tile, and
// then hit the kicker landed back at the top of the page. We capture
// page scrollY plus every marquee row's scrollLeft on page-loading-start
// (the moment a navigation begins), key it by the path being left, and
// restore on page-loading-stop when the user arrives at a path we have
// state for. Persisted in sessionStorage so it survives the navigation
// but not a tab restart.
const SCROLL_STORE_KEY = "aviary:scroll"

const readScrollStore = () => {
  try {
    return JSON.parse(sessionStorage.getItem(SCROLL_STORE_KEY) || "{}")
  } catch {
    return {}
  }
}

const writeScrollStore = (store) => {
  try {
    sessionStorage.setItem(SCROLL_STORE_KEY, JSON.stringify(store))
  } catch {
    // sessionStorage may be unavailable (private mode, quota); silently
    // skip — scroll-restore is a polish feature, not a hard requirement.
  }
}

window.addEventListener("phx:page-loading-start", () => {
  // Capture state for the page we're leaving — window.location is still
  // the source path at this moment in the navigation lifecycle.
  const path = window.location.pathname
  const rows = {}
  document.querySelectorAll("[data-marquee-key]").forEach((el) => {
    rows[el.dataset.marqueeKey] = el.scrollLeft
  })
  const store = readScrollStore()
  store[path] = {y: window.scrollY, rows}
  writeScrollStore(store)
})

window.addEventListener("phx:page-loading-stop", () => {
  const path = window.location.pathname
  const saved = readScrollStore()[path]
  if (!saved) return
  // Defer to next frame so the LV has actually rendered the page
  // before we try to scroll it. Marquee row scrollLeft is handled
  // by the MarqueeScrollRestore hook directly on each <ul>, so it
  // works even when rows arrive after this handler (async-loaded
  // discover + search rows).
  requestAnimationFrame(() => {
    if (typeof saved.y === "number") window.scrollTo(0, saved.y)
  })
})

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

