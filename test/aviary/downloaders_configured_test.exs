defmodule Aviary.DownloadersConfiguredTest do
  use ExUnit.Case, async: false

  for {downloader, address_setting} <- [
        {Aviary.Sonarr, :sonarr_url},
        {Aviary.Radarr, :radarr_url}
      ] do
    describe "#{inspect(downloader)}.configured?/0" do
      test "is true when the server has an address and key for it" do
        assert unquote(downloader).configured?()
      end

      test "is false on a server set up without it" do
        address = Application.get_env(:aviary, unquote(address_setting))
        Application.delete_env(:aviary, unquote(address_setting))
        on_exit(fn -> Application.put_env(:aviary, unquote(address_setting), address) end)

        refute unquote(downloader).configured?()
      end
    end
  end
end
