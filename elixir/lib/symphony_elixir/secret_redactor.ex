defmodule SymphonyElixir.SecretRedactor do
  @moduledoc """
  Redacts explicitly identified secrets from an evidence envelope before serialization.

  Sensitive keys and bounded Bearer/Basic or key=value text identify values;
  copies of those values are removed throughout the same envelope. This does
  not discover arbitrary unlabeled secrets or read the process environment.
  """

  @redacted "[REDACTED]"
  @sensitive_keys ~w(apikey apitoken accesstoken refreshtoken idtoken token password passwd secret clientsecret authorization proxyauthorization cookie setcookie privatekey credential credentials githubtoken)
  @sensitive_suffixes ~w(apikey apitoken accesstoken refreshtoken clientsecret password privatekey)
  @auth_token ~r/\b(?:Bearer|Basic)[ \t]+([A-Za-z0-9._~+\/=\-]+)/i
  @assignment ~r/(?<![\w-])["']?([A-Za-z][A-Za-z0-9_-]*)["']?[ \t]*[=:][ \t]*(?:"([^"\r\n]*)"|'([^'\r\n]*)'|([^\s,;{}\[\]"']+))/

  @spec redact(term()) :: term()
  def redact(envelope) do
    values =
      envelope
      |> collect_values()
      |> Enum.reject(&(&1 in ["", @redacted]))
      |> Enum.uniq()
      |> Enum.sort_by(&byte_size/1, :desc)

    replace_values(envelope, values)
  end

  defp sensitive_key?(key) when is_atom(key), do: sensitive_key?(Atom.to_string(key))

  defp sensitive_key?(key) when is_binary(key) do
    key = key |> String.downcase() |> String.replace(["_", "-", " "], "")
    key in @sensitive_keys or String.ends_with?(key, @sensitive_suffixes)
  end

  defp sensitive_key?(_key), do: false

  defp collect_values(value) when is_map(value) do
    Enum.flat_map(Map.to_list(value), fn {key, value} -> collect_pair(key, value) end)
  end

  defp collect_values({key, value}), do: collect_pair(key, value)
  defp collect_values(value) when is_tuple(value), do: value |> Tuple.to_list() |> collect_values()

  defp collect_values(value) when is_list(value) do
    if unicode_charlist?(value), do: value |> List.to_string() |> text_values(), else: flat_map_list(value, &collect_values/1)
  end

  defp collect_values(value) when is_binary(value), do: text_values(value)
  defp collect_values(_value), do: []

  defp collect_pair(key, value) do
    identified = if sensitive_key?(key), do: sensitive_values(value), else: []
    identified ++ collect_values(value)
  end

  defp sensitive_values(value) when is_binary(value), do: [value]
  defp sensitive_values(value) when is_map(value), do: value |> Map.values() |> Enum.flat_map(&sensitive_values/1)
  defp sensitive_values(value) when is_tuple(value), do: value |> Tuple.to_list() |> sensitive_values()

  defp sensitive_values(value) when is_list(value) do
    if unicode_charlist?(value), do: [List.to_string(value)], else: flat_map_list(value, &sensitive_values/1)
  end

  defp sensitive_values(_value), do: []

  defp text_values(value) do
    auth_values = Enum.map(Regex.scan(@auth_token, value, capture: :all_but_first), &hd/1)

    assignment_values =
      @assignment
      |> Regex.scan(value, capture: :all_but_first)
      |> Enum.flat_map(fn [key | captures] ->
        secret = Enum.find(captures, &(&1 != ""))

        if sensitive_key?(key) and secret not in [nil, "", @redacted, "Bearer", "Basic"] do
          [secret]
        else
          []
        end
      end)

    auth_values ++ assignment_values
  end

  defp replace_values(value, values) when is_map(value) do
    Map.new(Map.to_list(value), fn {key, value} ->
      {key, if(sensitive_key?(key), do: mask(value), else: replace_values(value, values))}
    end)
  end

  defp replace_values({key, value}, values) do
    {key, if(sensitive_key?(key), do: mask(value), else: replace_values(value, values))}
  end

  defp replace_values(value, values) when is_tuple(value) do
    value |> Tuple.to_list() |> Enum.map(&replace_values(&1, values)) |> List.to_tuple()
  end

  defp replace_values(value, values) when is_list(value) do
    if unicode_charlist?(value) do
      value |> List.to_string() |> replace_text(values) |> String.to_charlist()
    else
      map_list(value, &replace_values(&1, values))
    end
  end

  defp replace_values(value, values) when is_binary(value), do: replace_text(value, values)
  defp replace_values(value, _values), do: value

  defp replace_text(value, []), do: value
  defp replace_text(value, values), do: String.replace(value, values, @redacted)

  defp mask(nil), do: nil
  defp mask([]), do: []
  defp mask(value) when is_map(value), do: Map.new(Map.to_list(value), fn {key, value} -> {key, mask(value)} end)
  defp mask(value) when is_tuple(value), do: value |> Tuple.to_list() |> Enum.map(&mask/1) |> List.to_tuple()

  defp mask(value) when is_list(value) do
    if unicode_charlist?(value), do: String.to_charlist(@redacted), else: map_list(value, &mask/1)
  end

  defp mask(_value), do: @redacted

  defp unicode_charlist?([]), do: true

  defp unicode_charlist?([codepoint | rest])
       when is_integer(codepoint) and codepoint >= 0 and codepoint <= 0x10FFFF and
              not (codepoint >= 0xD800 and codepoint <= 0xDFFF),
       do: unicode_charlist?(rest)

  defp unicode_charlist?(_value), do: false

  # OTP logger reports contain valid chardata with binary tails, such as [10 | "details"].
  defp flat_map_list([], _fun), do: []
  defp flat_map_list([head | tail], fun), do: fun.(head) ++ flat_map_list(tail, fun)
  defp flat_map_list(tail, fun), do: fun.(tail)

  defp map_list([], _fun), do: []
  defp map_list([head | tail], fun), do: [fun.(head) | map_list(tail, fun)]
  defp map_list(tail, fun), do: fun.(tail)
end
