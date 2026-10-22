defmodule Aviary.StubbedServices do
  @moduledoc """
  Points Sonarr, SABnzbd and Jellyfin at their `Req.Test` stubs for the
  whole test run. `config/runtime.exs` reads their addresses from the
  environment on every boot, test included, so this has to happen after
  it runs rather than in `config/test.exs`.
  """

  def point_at_stubs do
    Application.put_env(:aviary, :sonarr_url, "http://sonarr.test")
    Application.put_env(:aviary, :sonarr_api_key, "sonarr-test-key")
    Application.put_env(:aviary, :sabnzbd_url, "http://sabnzbd.test")
    Application.put_env(:aviary, :sabnzbd_api_key, "sabnzbd-test-key")
    Application.put_env(:aviary, :jellyfin_url, "http://jellyfin.test")
    Application.put_env(:aviary, :jellyfin_api_key, "jellyfin-test-key")
  end
end
