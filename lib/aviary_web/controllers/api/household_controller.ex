defmodule AviaryWeb.API.HouseholdController do
  @moduledoc """
  Family recommendations for native clients. `index` lists the other
  household members a title can be recommended to; `recommend` records
  a single recommendation from the current user to one of them — the
  same `Aviary.Recommendations.recommend/4` the web detail page uses.
  """
  use AviaryWeb, :controller

  def index(conn, _params) do
    user = conn.assigns.current_user

    members =
      user
      |> Aviary.Jellyfin.list_users()
      |> Enum.reject(&(&1["Id"] == user.id))
      |> Enum.sort_by(&(&1["Name"] || ""))
      |> Enum.map(fn member ->
        %{
          id: member["Id"],
          username: member["Name"],
          primaryImageTag: member["PrimaryImageTag"]
        }
      end)

    json(conn, %{members: members})
  end

  def recommend(conn, %{"id" => id, "kind" => kind, "toUserId" => to_user_id})
      when kind in ["show", "movie"] do
    user = conn.assigns.current_user

    case Aviary.Recommendations.recommend(user.id, to_user_id, to_string(id), kind) do
      {:ok, _} ->
        json(conn, %{ok: true})

      _ ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "recommend_failed"})
    end
  end
end
