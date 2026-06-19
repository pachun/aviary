defmodule AviaryWeb.SettingsLive do
  @moduledoc """
  Account + display preferences for the signed-in user. The masthead's
  gear icon links here. Quiet utility page — same masthead + column
  structure as the rest of the app, no signature design move. Sections
  divided by hairline rule with a small uppercase label on the left
  column (museum-object-label rhythm).

  Sections today:
    - **You** — current username, sign-out button
    - **Display** — theme toggle (light/dark)

  Future additions (locale, playback, notifications) slot into the
  same two-column grid; each gets its own `<section>` with the same
  `border-t border-rule` separator.
  """
  use AviaryWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Settings · Aviary")}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      nav_visibility={@nav_visibility}
    >
      <%!--
        Page header: eyebrow + serif display title. Same rhythm the
        other section pages use (Discover, Library) so this lands as
        "an aviary page" before it lands as "a settings page."
      --%>
      <header class="pt-4 sm:pt-6 pb-12 sm:pb-16">
        <p class="font-sans text-[0.7rem] tracking-[0.18em] uppercase text-muted mb-3">
          Account &amp; preferences
        </p>
        <h1 class="font-display text-5xl sm:text-6xl text-ink">Settings</h1>
      </header>

      <%!--
        Section block. Two-column on sm+: a small uppercase label in
        the left column (180px), content in the right (1fr). On
        mobile both stack; the label sits above the content with its
        own rhythm. `border-t border-rule` on each section gives the
        hairline-divided museum-label look without any heavier chrome.
      --%>
      <section class="grid grid-cols-1 sm:grid-cols-[180px_1fr] gap-y-3 gap-x-10 py-10 border-t border-rule">
        <p class="font-sans text-[0.7rem] tracking-[0.18em] uppercase text-muted">You</p>
        <div class="flex flex-col gap-8">
          <div>
            <p class="font-sans text-[0.7rem] tracking-[0.18em] uppercase text-muted mb-1">
              Signed in as
            </p>
            <p class="font-display text-2xl text-ink">{@current_user.username}</p>
          </div>

          <.form for={%{}} action={~p"/logout"} method="post">
            <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
            <input type="hidden" name="_method" value="delete" />
            <%!--
              Sign out reads as a text link, not a destructive button.
              Same uppercase Instrument Sans + tracked treatment as
              section_link's underline, just no active state. Restraint:
              there is no other "danger" framing — single user, no
              surprise.
            --%>
            <button
              type="submit"
              class="self-start font-sans text-[0.72rem] tracking-[0.18em] uppercase text-ink hover:text-oxblood underline decoration-1 underline-offset-[6px] decoration-rule hover:decoration-oxblood transition-colors duration-200 cursor-pointer"
            >
              Sign out
            </button>
          </.form>
        </div>
      </section>

      <section class="grid grid-cols-1 sm:grid-cols-[180px_1fr] gap-y-3 gap-x-10 py-10 border-t border-rule">
        <p class="font-sans text-[0.7rem] tracking-[0.18em] uppercase text-muted">Display</p>
        <div class="flex flex-col gap-3">
          <p class="font-sans text-[0.7rem] tracking-[0.18em] uppercase text-muted">Theme</p>
          <Layouts.theme_toggle />
        </div>
      </section>
    </Layouts.app>
    """
  end
end
