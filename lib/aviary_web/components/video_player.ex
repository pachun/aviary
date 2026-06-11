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
end
