defmodule AviaryWeb.Components.VideoPlayer do
  @moduledoc """
  Full-viewport video player overlay, reused by movies and shows detail
  pages. The parent LiveView owns the `:playing_item` assign (nil when
  the player is closed) and handles `close_player` + `report_progress`
  events.
  """
  use Phoenix.Component

  attr :item, :map, required: true, doc: "%{id, resume_seconds}"
  attr :current_user, :map, required: true
  attr :title, :string, required: true, doc: "label for the iframe title attr"

  attr :segments, :any,
    default: nil,
    doc:
      "Intro Skipper plugin segments, e.g. %{introduction: %{start: 5.0, end: 87.0}}. Nil when plugin not installed or no data for this item."

  attr :subtitles, :list,
    default: [],
    doc:
      "Subtitle tracks `[%{index, lang, label, default}]` — rendered as <track> elements inside <video>; native CC menu picks them up."

  attr :audio_stream_index, :any,
    default: nil,
    doc:
      "Locks Jellyfin to a specific audio track in the HLS master playlist. nil lets Jellyfin pick its own default. Used to skip the Audio Description track that ships with Apple TV+ content."

  def overlay(assigns) do
    intro = get_in(assigns, [:segments, :introduction])
    assigns = assign(assigns, :intro, intro)

    ~H"""
    <%!--
      Stable container id so the Fullscreen button can target it
      via getElementById. We fullscreen the container rather than
      the video element so the skip controls + close button stay
      visible — fullscreening just the video would hide every other
      DOM element on the page.

      The `group` class + `data-controls-visible` attribute drive an
      auto-hide pattern matching native HTML5 video controls: any
      mouse movement sets the attribute true, 3s of stillness sets it
      false. Control buttons fade based on the parent attribute via
      `group-data-[controls-visible=false]:*` Tailwind selectors.
      Cursor also hides when controls hide for the polish.
    --%>
    <div
      id={"player-overlay-#{@item.id}"}
      data-controls-visible="true"
      class="group fixed inset-0 z-50 bg-black flex items-center justify-center data-[controls-visible=false]:cursor-none"
      phx-window-keydown="close_player"
      phx-key="Escape"
    >
      <video
        id={"player-#{@item.id}"}
        phx-hook="HlsPlayer"
        data-src={Aviary.Jellyfin.hls_url(@item.id, @current_user, @audio_stream_index)}
        data-resume-at={@item.resume_seconds || 0}
        data-intro-start={@intro && @intro.start}
        data-intro-end={@intro && @intro.end}
        controls
        controlslist="nofullscreen"
        autoplay
        playsinline
        crossorigin="anonymous"
        x-webkit-airplay="allow"
        class="w-full h-full max-w-screen max-h-screen object-contain"
      >
        <track
          :for={s <- @subtitles}
          src={Aviary.Jellyfin.subtitle_url(@item.id, s.index, @current_user)}
          kind="subtitles"
          srclang={s.lang}
          label={s.label}
          default={s.default}
        />
      </video>

      <%!--
        Skip Intro pill — JS hook toggles its data-visible attribute
        based on currentTime falling inside [intro.start, intro.end].
        The CSS opacity transition gives a soft fade so it doesn't
        snap in/out distractingly. Bottom-right placement sits clear
        of the native player chrome on the bottom-center.
      --%>
      <button
        :if={@intro}
        type="button"
        id={"skip-intro-#{@item.id}"}
        data-visible="false"
        data-skip-target={@intro.end}
        data-player-id={"player-#{@item.id}"}
        aria-label="Skip intro"
        class="absolute bottom-24 right-8 z-10 font-sans text-xs tracking-[0.18em] uppercase font-medium text-white px-5 py-3 rounded-sm bg-oxblood/90 backdrop-blur-sm hover:bg-oxblood cursor-pointer transition-opacity duration-300 opacity-0 pointer-events-none data-[visible=true]:opacity-100 data-[visible=true]:pointer-events-auto group-data-[controls-visible=false]:opacity-0 group-data-[controls-visible=false]:pointer-events-none"
        onclick="const v = document.getElementById(this.dataset.playerId); if (v) v.currentTime = parseFloat(this.dataset.skipTarget);"
      >
        Skip Intro
      </button>

      <%!--
        Skip controls — Apple TV / Hulu convention: 10s back ("did I
        miss that?"), 30s forward ("this scene's dragging"). Inline
        onclick is fine here: the video id is a Jellyfin GUID so the
        interpolation is safe, and there's only one player overlay
        on screen at a time. Math.min/max protect against scrubbing
        past the ends of the file.
      --%>
      <div class="absolute top-4 left-4 z-10 flex items-center gap-2 transition-opacity duration-300 group-data-[controls-visible=false]:opacity-0 group-data-[controls-visible=false]:pointer-events-none">
        <button
          type="button"
          onclick={skip_js(@item.id, -10)}
          aria-label="Skip back 10 seconds"
          class={skip_button_class()}
        >
          ← 10
        </button>
        <button
          type="button"
          onclick={skip_js(@item.id, 30)}
          aria-label="Skip forward 30 seconds"
          class={skip_button_class()}
        >
          30 →
        </button>
      </div>

      <%!--
        Top-right cluster: meta controls (fullscreen + close), grouped
        so they read as a pair. Fullscreen targets the OVERLAY div, not
        the video — fullscreening just the video element hides every
        sibling, killing the skip controls. controlsList="nofullscreen"
        on the video hides the native fullscreen button on Chromium so
        the user has one obvious entry point.
      --%>
      <div class="absolute top-4 right-4 z-10 flex items-center gap-2 transition-opacity duration-300 group-data-[controls-visible=false]:opacity-0 group-data-[controls-visible=false]:pointer-events-none">
        <button
          type="button"
          onclick={fullscreen_js(@item.id)}
          aria-label="Toggle fullscreen"
          class="font-sans text-xs tracking-[0.18em] uppercase font-medium text-white/80 hover:text-white cursor-pointer transition-colors px-4 py-2 rounded-sm bg-black/40 backdrop-blur-sm"
        >
          Fullscreen ⛶
        </button>
        <button
          type="button"
          phx-click="close_player"
          aria-label="Close player"
          class="font-sans text-xs tracking-[0.18em] uppercase font-medium text-white/80 hover:text-white cursor-pointer transition-colors px-4 py-2 rounded-sm bg-black/40 backdrop-blur-sm"
        >
          Close ✕
        </button>
      </div>
    </div>
    """
  end

  defp fullscreen_js(item_id) do
    """
    if (document.fullscreenElement) {
      document.exitFullscreen();
    } else {
      const c = document.getElementById('player-overlay-#{item_id}');
      if (c && c.requestFullscreen) c.requestFullscreen();
    }
    """
  end

  defp skip_js(item_id, seconds) when seconds < 0 do
    "const v = document.getElementById('player-#{item_id}');" <>
      "v.currentTime = Math.max(0, v.currentTime - #{-seconds});"
  end

  defp skip_js(item_id, seconds) do
    "const v = document.getElementById('player-#{item_id}');" <>
      "v.currentTime = Math.min(v.duration || Infinity, v.currentTime + #{seconds});"
  end

  defp skip_button_class do
    "font-sans text-xs tracking-[0.18em] uppercase font-medium text-white/80 hover:text-white cursor-pointer transition-colors px-4 py-2 rounded-sm bg-black/40 backdrop-blur-sm tabular-nums"
  end
end
