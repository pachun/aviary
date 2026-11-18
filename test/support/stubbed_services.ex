defmodule Aviary.StubbedServices do
  @moduledoc """
  Points Sonarr, SABnzbd, Jellyfin and Jellyseerr at their `Req.Test`
  stubs for the whole test run. `config/runtime.exs` reads their
  addresses from the environment on every boot, test included, so this
  has to happen after it runs rather than in `config/test.exs`.
  """

  def point_at_stubs do
    Application.put_env(:aviary, :sonarr_url, "http://sonarr.test")
    Application.put_env(:aviary, :sonarr_api_key, "sonarr-test-key")
    Application.put_env(:aviary, :radarr_url, "http://radarr.test")
    Application.put_env(:aviary, :radarr_api_key, "radarr-test-key")
    Application.put_env(:aviary, :sabnzbd_url, "http://sabnzbd.test")
    Application.put_env(:aviary, :sabnzbd_api_key, "sabnzbd-test-key")
    Application.put_env(:aviary, :jellyfin_url, "http://jellyfin.test")
    Application.put_env(:aviary, :jellyfin_api_key, "jellyfin-test-key")
    Application.put_env(:aviary, :jellyseerr_url, "http://jellyseerr.test")
    Application.put_env(:aviary, :jellyseerr_api_key, "jellyseerr-test-key")
    Application.put_env(:aviary, :anthropic_api_key, "claude-test-key")
  end
end
