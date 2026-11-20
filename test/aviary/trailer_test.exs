defmodule Aviary.TrailerTest do
  use ExUnit.Case, async: false

  alias Aviary.Trailer

  @trailer "https://www.youtube.com/watch?v=HOfdboHvshg"

  defp turn_trailers_off do
    Application.put_env(:aviary, :trailers, false)
    on_exit(fn -> Application.delete_env(:aviary, :trailers) end)
  end

  test "a title keeps its trailer link on a server that offers trailers" do
    assert Trailer.link(@trailer) == @trailer
  end

  test "a title has no trailer link on a server set up without trailers" do
    turn_trailers_off()

    assert Trailer.link(@trailer) == nil
  end

  test "a server set up without trailers resolves no trailer stream" do
    turn_trailers_off()

    assert Trailer.stream_url(@trailer) == :error
  end
end
