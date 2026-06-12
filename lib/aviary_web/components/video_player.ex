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

  def overlay(assigns) do
    ~H"""
    <div
      class="fixed inset-0 z-50 bg-black flex items-center justify-center"
      phx-window-keydown="close_player"
      phx-key="Escape"
    >
      <video
        id={"player-#{@item.id}"}
        phx-hook="HlsPlayer"
        data-src={Aviary.Jellyfin.hls_url(@item.id, @current_user)}
        data-resume-at={@item.resume_seconds || 0}
        controls
        autoplay
        playsinline
        x-webkit-airplay="allow"
        class="w-full h-full max-w-screen max-h-screen object-contain"
      >
      </video>

      <%!--
        Skip controls — Apple TV / Hulu convention: 10s back ("did I
        miss that?"), 30s forward ("this scene's dragging"). Inline
        onclick is fine here: the video id is a Jellyfin GUID so the
        interpolation is safe, and there's only one player overlay
        on screen at a time. Math.min/max protect against scrubbing
        past the ends of the file.
      --%>
      <div class="absolute top-4 left-4 z-10 flex items-center gap-2">
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

      <button
        type="button"
        phx-click="close_player"
        aria-label="Close player"
        class="absolute top-4 right-4 z-10 font-sans text-xs tracking-[0.18em] uppercase font-medium text-white/80 hover:text-white cursor-pointer transition-colors px-4 py-2 rounded-sm bg-black/40 backdrop-blur-sm"
      >
        Close ✕
      </button>
    </div>
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
