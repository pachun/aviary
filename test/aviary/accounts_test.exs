defmodule Aviary.AccountsTest do
  use ExUnit.Case, async: false

  alias Aviary.{Accounts, Jellyfin, Library, Radarr, Repo, Sonarr}
  alias Aviary.Deletions.PendingDeletion

  @nick_id String.duplicate("a", 32)
  @jay_id String.duplicate("b", 32)
  @mary_id String.duplicate("c", 32)

  @nick %{id: @nick_id, username: "nick", token: "nick-token"}
  @jay %{id: @jay_id, username: "jay", token: "jay-token"}

  setup do
    Repo.delete_all(Library.Entry)
    Repo.delete_all(PendingDeletion)
    Aviary.Cache.invalidate(:sonarr_series_list)
    Aviary.Cache.invalidate(:radarr_movie_list)

    stub_jellyfin([
      account(@nick_id, "nick", administrator: true),
      account(@jay_id, "jay"),
      account(@mary_id, "mary")
    ])

    :ok
  end

  describe "someone who isn't the Jellyfin administrator" do
    test "can't see, add, change or remove accounts" do
      assert Accounts.manager?(@jay) == false
      assert Accounts.list(@jay) == {:error, :not_allowed}
      assert Accounts.add(@jay, "bea", "secret") == {:error, :not_allowed}
      assert Accounts.rename(@jay, @mary_id, "maria") == {:error, :not_allowed}
      assert Accounts.change_password(@jay, @mary_id, "secret") == {:error, :not_allowed}
      assert Accounts.remove(@jay, @mary_id) == {:error, :not_allowed}

      refute_received {:jellyfin, _, _}
      assert usernames() == ["jay", "mary", "nick"]
    end

    test "is nobody when aviary has no Jellyfin API key" do
      key = Application.get_env(:aviary, :jellyfin_api_key)
      Application.put_env(:aviary, :jellyfin_api_key, nil)
      on_exit(fn -> Application.put_env(:aviary, :jellyfin_api_key, key) end)

      assert Accounts.manager?(@nick) == false
    end
  end

  describe "the Jellyfin administrator" do
    test "sees every account, alphabetically" do
      assert Accounts.manager?(@nick)

      assert {:ok,
              [
                %{id: @jay_id, username: "jay", manager?: false},
                %{id: @mary_id, username: "mary", manager?: false},
                %{id: @nick_id, username: "nick", manager?: true}
              ]} = Accounts.list(@nick)
    end

    test "adds an account set up like the rest of the household" do
      assert {:ok, %{username: "bea", manager?: false}} = Accounts.add(@nick, " bea ", "secret")

      assert_received {:jellyfin, :created, %{"Name" => "bea", "Password" => "secret"}}
      assert_received {:jellyfin, :policy, %{"IsHidden" => true, "EnableAllFolders" => true}}

      assert_received {:jellyfin, :configuration,
                       %{"AudioLanguagePreference" => "eng", "PlayDefaultAudioTrack" => false}}

      assert usernames() == ["bea", "jay", "mary", "nick"]
    end

    test "can't add a username someone already has, or a blank one, or a blank password" do
      assert Accounts.add(@nick, "Jay", "secret") == {:error, :username_taken}
      assert Accounts.add(@nick, "  ", "secret") == {:error, :username_missing}
      assert Accounts.add(@nick, "bea", "") == {:error, :password_missing}

      refute_received {:jellyfin, :created, _}
    end

    test "leaves no half-made account behind when Jellyfin can't finish setting it up" do
      stub_jellyfin([account(@nick_id, "nick", administrator: true)], failing: :policy)

      assert Accounts.add(@nick, "bea", "secret") == {:error, :unreachable}
      assert usernames() == ["nick"]
    end

    test "renames an account" do
      assert Accounts.rename(@nick, @jay_id, "jason") == :ok
      assert usernames() == ["jason", "mary", "nick"]
    end

    test "can't rename an account to a username someone else has" do
      assert Accounts.rename(@nick, @jay_id, "MARY") == {:error, :username_taken}
      assert Accounts.rename(@nick, @jay_id, "Jay") == :ok
    end

    test "changes a password without knowing the current one" do
      assert Accounts.change_password(@nick, @jay_id, "new-secret") == :ok
      assert_received {:jellyfin, :password, @jay_id, %{"NewPw" => "new-secret"}}

      assert Accounts.change_password(@nick, @jay_id, "") == {:error, :password_missing}
    end

    test "removes an account, and what only they had is deleted after the grace period" do
      Library.add(@jay_id, "100")
      Library.add(@jay_id, "200")
      Library.add(@jay_id, "300")
      Library.add(@mary_id, "300")
      stub_sonarr(series: [%{"id" => 1, "tmdbId" => 100}, %{"id" => 3, "tmdbId" => 300}])
      stub_radarr(movies: [%{"id" => 2, "tmdbId" => 200}])

      assert Accounts.remove(@nick, @jay_id) == :ok

      assert usernames() == ["mary", "nick"]
      assert Library.list_tmdb_ids(@jay_id) == []
      assert Library.list_tmdb_ids(@mary_id) == ["300"]

      assert Repo.all(PendingDeletion) |> Enum.map(&{&1.tmdb_id, &1.kind}) |> Enum.sort() ==
               [{"100", "show"}, {"200", "movie"}]
    end

    test "can't remove themselves or another administrator" do
      stub_jellyfin([
        account(@nick_id, "nick", administrator: true),
        account("root-id", "root", administrator: true)
      ])

      assert Accounts.remove(@nick, @nick_id) == {:error, :cannot_remove_yourself}
      assert Accounts.remove(@nick, "root-id") == {:error, :cannot_remove_manager}
      assert usernames() == ["nick", "root"]
    end
  end

  defp account(id, username, options \\ []) do
    %{
      "Id" => id,
      "Name" => username,
      "Policy" => %{
        "IsAdministrator" => Keyword.get(options, :administrator, false),
        "IsHidden" => false
      },
      "Configuration" => %{"PlayDefaultAudioTrack" => true}
    }
  end

  defp usernames do
    {:ok, accounts} = Jellyfin.accounts(Jellyfin.server_auth())
    accounts |> Enum.map(& &1["Name"]) |> Enum.sort()
  end

  defp stub_jellyfin(accounts, options \\ []) do
    test = self()
    failing = Keyword.get(options, :failing)
    household = start_supervised!({Agent, fn -> accounts end}, id: make_ref())

    Req.Test.stub(Jellyfin, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      administrator_key? = Plug.Conn.get_req_header(conn, "x-emby-token") == ["jellyfin-test-key"]

      case {administrator_key?, conn.method, conn.request_path} do
        {false, _, _} ->
          Plug.Conn.send_resp(conn, 403, "")

        {true, "GET", "/Users"} ->
          Req.Test.json(conn, Agent.get(household, & &1))

        {true, "GET", "/Users/" <> id} ->
          case Agent.get(household, &Enum.find(&1, fn account -> account["Id"] == id end)) do
            nil -> Plug.Conn.send_resp(conn, 404, "")
            found -> Req.Test.json(conn, found)
          end

        {true, "POST", "/Users/New"} ->
          body = read_json(conn)
          send(test, {:jellyfin, :created, body})
          created = account(body["Name"] <> "-id", body["Name"])
          Agent.update(household, &[created | &1])
          Req.Test.json(conn, created)

        {true, "POST", "/Users/Password"} ->
          send(test, {:jellyfin, :password, conn.query_params["userId"], read_json(conn)})
          Plug.Conn.send_resp(conn, 204, "")

        {true, "POST", "/Users/Configuration"} ->
          send(test, {:jellyfin, :configuration, read_json(conn)})
          Plug.Conn.send_resp(conn, 204, "")

        {true, "POST", "/Users"} ->
          renamed = read_json(conn)
          send(test, {:jellyfin, :updated, renamed})

          Agent.update(household, fn accounts ->
            Enum.map(
              accounts,
              &if(&1["Id"] == conn.query_params["userId"], do: renamed, else: &1)
            )
          end)

          Plug.Conn.send_resp(conn, 204, "")

        {true, "POST", "/Users/" <> _id_and_policy} when failing == :policy ->
          Plug.Conn.send_resp(conn, 500, "")

        {true, "POST", "/Users/" <> _id_and_policy} ->
          send(test, {:jellyfin, :policy, read_json(conn)})
          Plug.Conn.send_resp(conn, 204, "")

        {true, "DELETE", "/Users/" <> id} ->
          send(test, {:jellyfin, :deleted, id})
          Agent.update(household, &Enum.reject(&1, fn account -> account["Id"] == id end))
          Plug.Conn.send_resp(conn, 204, "")
      end
    end)
  end

  defp stub_sonarr(series: series) do
    Req.Test.stub(Sonarr, fn conn ->
      case conn.request_path do
        "/api/v3/series" -> Req.Test.json(conn, series)
        "/api/v3/history" -> Req.Test.json(conn, %{"records" => []})
      end
    end)
  end

  defp stub_radarr(movies: movies) do
    Req.Test.stub(Radarr, fn conn ->
      case conn.request_path do
        "/api/v3/movie" -> Req.Test.json(conn, movies)
        "/api/v3/history" <> _ -> Req.Test.json(conn, %{"records" => []})
      end
    end)
  end

  defp read_json(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    Jason.decode!(body)
  end
end
