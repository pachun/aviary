defmodule Aviary.Sabnzbd do
  @moduledoc """
  Live download progress and queue priority from SABnzbd. Sonarr treats
  availability checks as downloads, so progress needs the original phase.
  The same applies to Radarr.
  """
  require Logger

  @force_priority 2
  @queue_timeout_ms 5_000

  def refresh_progress([]), do: []

  def refresh_progress(records) do
    with {:ok, url, key} <- config(),
         {:ok, %Req.Response{status: 200, body: %{"queue" => %{"slots" => slots}}}} <-
           Req.get(
             [
               url: url <> "/api",
               params: [mode: "queue", apikey: key, output: "json"],
               receive_timeout: @queue_timeout_ms,
               retry: false
             ]
             |> Keyword.merge(Application.get_env(:aviary, :sabnzbd_req_options, []))
           ) do
      Enum.map(records, fn record ->
        case Enum.find(slots, &(&1["nzo_id"] == record["downloadId"])) do
          %{"status" => "Checking"} ->
            Map.put(record, :download_state, :searching)

          %{"status" => "Downloading", "percentage" => "100"} ->
            Map.put(record, :download_state, :verifying)

          %{"status" => "Downloading", "percentage" => percent} ->
            Map.put(record, :download_state, {:downloading, String.to_integer(percent)})

          _ ->
            record
        end
      end)
    else
      _ -> records
    end
  end

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
