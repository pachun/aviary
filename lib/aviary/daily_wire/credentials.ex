defmodule Aviary.DailyWire.Credentials do
  use GenServer

  @client_id "FCgw3nA6cxkcXLVseAQvCSVBrymwvfpE"
  @renew_before_seconds 86_400
  @check_interval_ms :timer.hours(1)
  @request_timeout_ms 15_000
  @call_timeout_ms 20_000

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  def access_token, do: GenServer.call(__MODULE__, :access_token, @call_timeout_ms)

  def allowed?(%{id: id}) do
    case read() do
      {:ok, %{"allowed_user_ids" => ids}} when is_list(ids) -> id in ids or "*" in ids
      _ -> false
    end
  end

  def allowed?(_), do: false

  def read do
    with path when is_binary(path) <- path(),
         {:ok, contents} <- File.read(path),
         {:ok, %{"refresh_token" => refresh_token} = tokens} <- Jason.decode(contents),
         true <- is_binary(refresh_token) and refresh_token != "" do
      {:ok, tokens}
    else
      _ -> {:error, :not_connected}
    end
  end

  @impl true
  def init(_options) do
    schedule_check()
    {:ok, nil}
  end

  @impl true
  def handle_call(:access_token, _from, state), do: {:reply, current_token(), state}

  @impl true
  def handle_info(:renew, state) do
    current_token()
    schedule_check()
    {:noreply, state}
  end

  defp current_token do
    with {:ok, tokens} <- read() do
      now = System.system_time(:second)

      if is_binary(tokens["access_token"]) and
           is_integer(tokens["expires_at"]) and tokens["expires_at"] > now + @renew_before_seconds do
        {:ok, tokens["access_token"]}
      else
        renew(tokens)
      end
    end
  end

  defp renew(tokens) do
    options = [
      form: [
        client_id: @client_id,
        grant_type: "refresh_token",
        refresh_token: tokens["refresh_token"]
      ],
      retry: false,
      redirect: false,
      receive_timeout: @request_timeout_ms
    ]

    result =
      Req.post(
        "https://authorize.dailywire.com/oauth/token",
        Keyword.merge(options, Application.get_env(:aviary, :daily_wire_req_options, []))
      )

    case result do
      {:ok,
       %Req.Response{
         status: 200,
         body: %{"access_token" => token, "expires_in" => lifetime} = renewed
       }}
      when is_binary(token) and is_integer(lifetime) and lifetime > 0 ->
        refreshed =
          tokens
          |> Map.merge(
            Map.take(renewed, ["access_token", "refresh_token", "scope", "token_type"])
          )
          |> Map.put("expires_at", System.system_time(:second) + lifetime)

        case persist(refreshed) do
          :ok -> {:ok, token}
          _ -> {:error, :storage_unavailable}
        end

      {:ok, %Req.Response{body: %{"error" => "invalid_grant"}}} ->
        {:error, :reconnect}

      _ ->
        {:error, :unavailable}
    end
  end

  defp persist(tokens) do
    temporary = path() <> ".#{System.unique_integer([:positive])}.new"

    case File.open(temporary, [:write, :exclusive]) do
      {:ok, file} ->
        result =
          with :ok <- File.chmod(temporary, 0o600),
               :ok <- IO.binwrite(file, Jason.encode!(tokens)),
               :ok <- :file.sync(file),
               :ok <- File.close(file) do
            File.rename(temporary, path())
          end

        if result != :ok do
          File.close(file)
          File.rm(temporary)
        end

        result

      _ ->
        {:error, :storage_unavailable}
    end
  end

  defp path, do: Application.get_env(:aviary, :daily_wire_token_file)
  defp schedule_check, do: Process.send_after(self(), :renew, @check_interval_ms)
end
