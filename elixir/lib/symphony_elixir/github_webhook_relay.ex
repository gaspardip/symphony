defmodule SymphonyElixir.GitHubWebhookRelay do
  @moduledoc """
  Relays verified GitHub review webhooks from stable ingress to sibling runners.
  """

  alias SymphonyElixir.{Config, RunnerRuntime}

  @forwarded_header "x-symphony-forwarded-by"
  @forwardable_headers ~w(content-type x-github-event x-github-delivery x-hub-signature-256)

  @type relay_result :: %{
          attempted: non_neg_integer(),
          forwarded: [String.t()],
          failed: [%{url: String.t(), reason: term()}]
        }

  @spec forward_verified_webhook([{binary(), binary()}], binary()) :: relay_result()
  def forward_verified_webhook(headers, raw_body)
      when is_list(headers) and is_binary(raw_body) do
    cond do
      Config.runner_channel() != "stable" ->
        %{attempted: 0, forwarded: [], failed: []}

      forwarded_request?(headers) ->
        %{attempted: 0, forwarded: [], failed: []}

      true ->
        urls = relay_urls()

        {forwarded, failed} =
          Enum.reduce(urls, {[], []}, fn url, {forwarded_acc, failed_acc} ->
            case relay_client().(relay_webhook_url(url), relay_headers(headers), raw_body) do
              :ok ->
                {[url | forwarded_acc], failed_acc}

              {:ok, status} when status in 200..299 ->
                {[url | forwarded_acc], failed_acc}

              {:error, reason} ->
                {forwarded_acc, [%{url: url, reason: reason} | failed_acc]}

              other ->
                {forwarded_acc, [%{url: url, reason: other} | failed_acc]}
            end
          end)

        %{
          attempted: length(urls),
          forwarded: Enum.reverse(forwarded),
          failed: Enum.reverse(failed)
        }
    end
  end

  def forward_verified_webhook(_headers, _raw_body), do: %{attempted: 0, forwarded: [], failed: []}

  defp relay_urls do
    self_urls = self_urls()

    Config.portfolio_instances()
    |> Enum.map(fn instance -> Map.get(instance, :url) || Map.get(instance, "url") end)
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reject(&MapSet.member?(self_urls, &1))
    |> Enum.uniq()
  end

  defp self_urls do
    host = Config.server_host()
    port = Config.server_port()

    MapSet.new([
      "http://#{host}:#{port}",
      "http://#{String.trim(host)}:#{port}/",
      "https://#{host}:#{port}",
      "https://#{String.trim(host)}:#{port}/"
    ])
  end

  defp forwarded_request?(headers) when is_list(headers) do
    Enum.any?(headers, fn
      {name, value}
      when is_binary(name) and is_binary(value) ->
        String.downcase(name) == @forwarded_header and String.trim(value) != ""

      _ ->
        false
    end)
  end

  defp relay_headers(headers) when is_list(headers) do
    base_headers =
      headers
      |> Enum.filter(fn
        {name, value} when is_binary(name) and is_binary(value) ->
          String.downcase(name) in @forwardable_headers

        _ ->
          false
      end)
      |> Enum.map(fn {name, value} -> {String.downcase(name), value} end)

    [{@forwarded_header, RunnerRuntime.instance_id()} | base_headers]
  end

  defp relay_webhook_url(base_url) when is_binary(base_url) do
    String.trim_trailing(base_url, "/") <> "/api/webhooks/github"
  end

  defp relay_client do
    Application.get_env(:symphony_elixir, :github_webhook_relay_client, &default_relay_client/3)
  end

  defp default_relay_client(url, headers, raw_body)
       when is_binary(url) and is_list(headers) and is_binary(raw_body) do
    case Req.post(url, headers: headers, body: raw_body) do
      {:ok, %Req.Response{status: status}} -> {:ok, status}
      {:error, reason} -> {:error, reason}
    end
  end
end
