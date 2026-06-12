defmodule Aviary.TmdbImageCache do
  @moduledoc """
  Disk-cached proxy for TMDB image CDN. First fetch of an
  `(size, path)` pair hits `image.tmdb.org` and writes the bytes to
  disk; every subsequent fetch reads from disk and pays only local
  IO. The cache directory is configurable via
  `:aviary, :tmdb_image_cache_dir` and defaults to a subdirectory of
  `System.tmp_dir!/0`.

  Sizes are validated against TMDB's documented thumbnail sizes —
  the route is open to anyone authenticated, so accepting an
  arbitrary `:size` would let a caller force expensive transcodes
  upstream. The path is validated to be a simple filename with no
  separators to prevent traversal into the disk cache directory.

  Returns `{:ok, body, content_type}` on success. The content type
  is inferred from the file extension; TMDB serves jpegs and pngs
  exclusively. Returns `{:error, :bad_size | :bad_path}` for
  validation failures and `:error` for upstream/network failures.
  """
  require Logger

  @allowed_sizes ~w(w92 w154 w185 w300 w342 w500 w780 original)

  def fetch(size, path) do
    with :ok <- validate_size(size),
         :ok <- validate_path(path) do
      do_fetch(size, path)
    end
  end

  defp validate_size(size) when size in @allowed_sizes, do: :ok
  defp validate_size(_), do: {:error, :bad_size}

  # Filenames only — no path separators, no leading dots. TMDB paths
  # are flat (e.g. `abc123.jpg`), so this is what real input looks
  # like, and it sidesteps any traversal risk into the cache dir.
  defp validate_path(path) do
    if String.match?(path, ~r/\A[A-Za-z0-9._-]+\.(jpg|jpeg|png|webp)\z/i),
      do: :ok,
      else: {:error, :bad_path}
  end

  defp do_fetch(size, path) do
    cache_file = Path.join([cache_dir(), size, path])

    case File.read(cache_file) do
      {:ok, body} ->
        {:ok, body, content_type_for(path)}

      _ ->
        fetch_and_cache(size, path, cache_file)
    end
  end

  defp fetch_and_cache(size, path, cache_file) do
    url = "https://image.tmdb.org/t/p/#{size}/#{path}"

    case Req.get(url, receive_timeout: 10_000, retry: false) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        Task.start(fn ->
          try do
            File.mkdir_p!(Path.dirname(cache_file))
            File.write!(cache_file, body)
          rescue
            e ->
              Logger.warning("tmdb_image_cache write failed path=#{cache_file} error=#{inspect(e)}")
          end
        end)

        {:ok, body, content_type_for(path)}

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp content_type_for(path) do
    case path |> Path.extname() |> String.downcase() do
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".png" -> "image/png"
      ".webp" -> "image/webp"
      _ -> "application/octet-stream"
    end
  end

  defp cache_dir do
    Application.get_env(:aviary, :tmdb_image_cache_dir) ||
      Path.join(System.tmp_dir!(), "aviary-tmdb-cache")
  end
end
