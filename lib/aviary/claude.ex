defmodule Aviary.Claude do
  @moduledoc """
  Asks Claude one question and gets back an answer in a fixed shape.
  Used where judgment about titles matters more than viewing data, such
  as choosing what a show or movie is like.

  Without an API key every call is `:error`, so callers fall back to
  whatever they did before Claude.
  """

  require Logger

  @url "https://api.anthropic.com/v1/messages"
  @api_version "2026-10-21"
  @server_side_fallback_beta "server-side-fallback-2026-07-01"
  @model "claude-opus-5-5"
  @effort "low"
  @most_output_tokens 16_000
  @answer_timeout_ms 90_000

  @doc """
  Claude's answer to `question` as a decoded map matching `schema`, or
  `:error`. `instructions` are the same for every question of a kind,
  so they are marked for prompt caching.
  """
  def answer(instructions, question, schema)
      when is_binary(instructions) and is_binary(question) and is_map(schema) do
    with key when is_binary(key) and key != "" <- api_key(),
         {:ok, %Req.Response{status: 200, body: body}} <-
           Req.post(@url, request_options(key, instructions, question, schema)),
         {:ok, answer} <- decoded_answer(body) do
      {:ok, answer}
    else
      nil ->
        :error

      "" ->
        :error

      other ->
        Logger.warning("Claude gave no usable answer: #{describe(other)}")
        :error
    end
  rescue
    error ->
      Logger.warning("Claude request failed: #{Exception.message(error)}")
      :error
  end

  def configured?, do: api_key() not in [nil, ""]

  defp request_options(key, instructions, question, schema) do
    [
      headers: [
        {"x-api-key", key},
        {"anthropic-version", @api_version},
        {"anthropic-beta", @server_side_fallback_beta}
      ],
      json: %{
        model: @model,
        max_tokens: @most_output_tokens,
        fallbacks: "default",
        output_config: %{
          effort: @effort,
          format: %{type: "json_schema", schema: schema}
        },
        system: [
          %{type: "text", text: instructions, cache_control: %{type: "ephemeral"}}
        ],
        messages: [%{role: "user", content: question}]
      },
      receive_timeout: @answer_timeout_ms,
      retry: false
    ]
    |> Keyword.merge(Application.get_env(:aviary, :claude_req_options, []))
  end

  defp decoded_answer(%{"stop_reason" => "end_turn", "content" => content})
       when is_list(content) do
    content
    |> Enum.find_value(fn
      %{"type" => "text", "text" => text} -> text
      _ -> nil
    end)
    |> case do
      nil -> :no_text
      text -> Jason.decode(text)
    end
  end

  defp decoded_answer(%{"stop_reason" => reason}), do: {:stopped, reason}
  defp decoded_answer(_), do: :unexpected_body

  defp describe({:ok, %Req.Response{status: status, body: body}}),
    do: "HTTP #{status} #{inspect(body, limit: 20, printable_limit: 300)}"

  defp describe(other), do: inspect(other, limit: 20, printable_limit: 300)

  defp api_key, do: Application.get_env(:aviary, :anthropic_api_key)
end
