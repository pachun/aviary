defmodule Aviary.Sabnzbd do
  @moduledoc """
  The one thing aviary asks of SABnzbd directly: move a download to
  the front of its queue. Sonarr hands every grab over at the same
  priority, so without this the episode someone is waiting to watch
  lines up behind whatever the household already had queued.
  """
  require Logger

  @force_priority 2

  @doc """
  Starts the download with this SABnzbd job id right away, ahead of
  everything else in the queue. `:ok` once SABnzbd accepted it,
  `:error` when it didn't or SABnzbd isn't configured.
  """
  def move_to_front(nzo_id) do
    with {:ok, url, key} <- config(),
         {:ok, %Req.Response{status: 200, body: %{"status" => true}}} <-
           Req.get(
             [
               url: url <> "/api",
               params: [
                 mode: "queue",
                 name: "priority",
                 value: nzo_id,
                 value2: @force_priority,
                 apikey: key,
                 output: "json"
               ],
               receive_timeout: 10_000,
               retry: false
             ]
             |> Keyword.merge(Application.get_env(:aviary, :sabnzbd_req_options, []))
           ) do
      :ok
    else
      :unconfigured ->
        :error

      other ->
        Logger.warning("sabnzbd could not move #{nzo_id} to the front: #{inspect(other)}")
        :error
    end
  rescue
    e ->
      Logger.warning("sabnzbd request raised: #{inspect(e)}")
      :error
  end

  defp config do
    url = Application.get_env(:aviary, :sabnzbd_url)
    key = Application.get_env(:aviary, :sabnzbd_api_key)

    if url in [nil, ""] or key in [nil, ""],
      do: :unconfigured,
      else: {:ok, String.trim_trailing(url, "/"), key}
  end
end
