defmodule SymphonyElixir.Util do
  @moduledoc false

  @spec normalize_state(term()) :: String.t()
  def normalize_state(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  def normalize_state(_value), do: ""

  @spec now_iso8601() :: String.t()
  def now_iso8601, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  @spec issue_log_context(%{id: term(), identifier: term()}) :: String.t()
  def issue_log_context(%{id: id, identifier: identifier}) do
    "issue_id=#{id} issue_identifier=#{identifier}"
  end

  @spec truthy?(term()) :: boolean()
  def truthy?(value), do: value in [true, "true", 1, "1"]

  @spec generate_id(String.t()) :: String.t()
  def generate_id(prefix), do: prefix <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
end
