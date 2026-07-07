defmodule AviaryWeb.SonarrWebhookController do
  @moduledoc """
  Receives Sonarr Connect webhook events and reacts.

  Every reaction kicks `Aviary.Reconcile`, which both clears
  import-blocked downloads and re-searches aired-but-not-grabbed
  episodes. The events that trigger it:

    - "Health Restored" — a previously-unhealthy Sonarr state (e.g.
      qBittorrent unreachable) recovered; grabs it tried while down
      can now succeed if we re-fire them.
    - "Application Update" — Sonarr restarted; anything dropped
      mid-grab is worth re-firing.
    - "Manual Interaction Required" — a completed download Sonarr
      won't auto-import (e.g. it could only match the series by id);
      the reconcile clears it if the files parse cleanly.

  Authentication: a shared secret in the `x-aviary-secret` header,
  matched against `:aviary, :sonarr_webhook_secret` from runtime
  config. configure.sh generates and persists this secret alongside
  SECRET_KEY_BASE, then registers a Webhook notification in Sonarr
  pointing at this endpoint with the same secret in custom headers.
  Mismatched secret returns 401.

  The "On Test" event Sonarr fires from its admin UI is acknowledged
  with a 200 so the test button in Sonarr's Connect settings stays
  green.
  """
  use AviaryWeb, :controller

  require Logger

  def receive(conn, params) do
    if authorized?(conn) do
      handle_event(params)
      send_resp(conn, 200, "")
    else
      Logger.warning("sonarr_webhook unauthorized")
      send_resp(conn, 401, "")
    end
  end

  # Sonarr sends `eventType: "HealthRestored"`, `"Health"`, `"Test"`,
  # `"Grab"`, `"Download"`, etc. The interesting ones for re-firing
  # stuck searches are HealthRestored (the recovery edge) and
  # ApplicationUpdate (Sonarr restarted, who knows what got dropped
  # mid-grab). Treat both as "run reconcile."
  defp handle_event(%{"eventType" => "Test"}) do
    Logger.info("sonarr_webhook test event")
    :ok
  end

  defp handle_event(%{"eventType" => evt} = params)
       when evt in ["HealthRestored", "ApplicationUpdate", "ManualInteractionRequired"] do
    Logger.info("sonarr_webhook eventType=#{evt} — kicking Reconcile")

    # Run async — Sonarr expects a quick 200 from the webhook, and
    # the reconcile may take several seconds (one Sonarr round-trip
    # per page of /wanted/missing, then N EpisodeSearch posts).
    Task.start(fn ->
      try do
        Aviary.Reconcile.run()
      rescue
        e -> Logger.warning("sonarr_webhook reconcile raised: #{inspect(e)}")
      end
    end)

    if message = get_in(params, ["message"]) do
      Logger.info("sonarr_webhook health detail: #{message}")
    end

    :ok
  end

  defp handle_event(%{"eventType" => evt}) do
    # Other event types (Grab, Download, Rename, etc.) are not
    # actionable here but logged at debug so we can see what's
    # flowing in if we want to add handlers later.
    Logger.debug("sonarr_webhook eventType=#{evt} (no handler)")
    :ok
  end

  defp handle_event(other) do
    Logger.debug("sonarr_webhook malformed payload: #{inspect(other) |> String.slice(0, 200)}")
    :ok
  end

  defp authorized?(conn) do
    case Application.get_env(:aviary, :sonarr_webhook_secret) do
      nil ->
        # No secret configured — accept anything (suitable for dev /
        # initial setup before configure.sh has generated the secret).
        true

      "" ->
        true

      expected ->
        case get_req_header(conn, "x-aviary-secret") do
          [^expected | _] -> true
          _ -> false
        end
    end
  end
end
