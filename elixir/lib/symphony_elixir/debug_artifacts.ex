defmodule SymphonyElixir.DebugArtifacts do
  @moduledoc """
  Bounded local storage for raw debug artifacts referenced from normal telemetry.
  """

  alias SymphonyElixir.Config

  @type artifact_ref :: %{
          artifact_id: String.t(),
          kind: String.t(),
          path: String.t(),
          manifest_path: String.t(),
          sha256: String.t(),
          bytes: non_neg_integer(),
          truncated: boolean()
        }

  @spec store(String.t(), iodata() | map(), map()) :: {:ok, artifact_ref()} | {:error, term()}
  def store(kind, payload, metadata \\ %{}) when is_binary(kind) and is_map(metadata) do
    if Config.observability_debug_artifacts_enabled?() do
      serialized = serialize_payload(payload)
      bounded = bound_content(serialized)
      sha256 = :crypto.hash(:sha256, bounded.data) |> Base.encode16(case: :lower)
      artifact_id = "dbg_" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
      day = Date.utc_today() |> Date.to_iso8601()
      root = Config.observability_debug_artifact_root()
      directory = Path.join(root, day)
      payload_path = Path.join(directory, artifact_id <> ".txt.gz")
      manifest_path = Path.join(directory, artifact_id <> ".json")

      manifest = %{
        artifact_id: artifact_id,
        kind: kind,
        sha256: sha256,
        bytes: byte_size(bounded.data),
        truncated: bounded.truncated?,
        stored_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        metadata: metadata
      }

      with :ok <- File.mkdir_p(directory),
           {:ok, encoded_manifest} <- Jason.encode(manifest),
           :ok <- File.write(payload_path, :zlib.gzip(bounded.data)),
           :ok <- File.write(manifest_path, encoded_manifest) do
        {:ok,
         %{
           artifact_id: artifact_id,
           kind: kind,
           path: payload_path,
           manifest_path: manifest_path,
           sha256: sha256,
           bytes: byte_size(bounded.data),
           truncated: bounded.truncated?
         }}
      else
        error -> normalize_store_error(error)
      end
    else
      {:error, :disabled}
    end
  end

  @spec store_failure(String.t(), iodata() | map(), map()) ::
          {:ok, artifact_ref()} | {:error, term()}
  def store_failure(kind, payload, metadata \\ %{}) when is_binary(kind) and is_map(metadata) do
    if Config.observability_debug_capture_on_failure?() do
      store(kind, payload, metadata)
    else
      {:error, :failure_capture_disabled}
    end
  end

  defp serialize_payload(payload) when is_binary(payload), do: payload
  defp serialize_payload(payload) when is_list(payload), do: IO.iodata_to_binary(payload)

  defp serialize_payload(payload) when is_map(payload) do
    case Jason.encode(payload) do
      {:ok, json} -> json
      {:error, _reason} -> inspect(payload, pretty: true, limit: :infinity)
    end
  end

  defp serialize_payload(payload), do: inspect(payload, pretty: true, limit: :infinity)

  defp normalize_store_error({:error, reason}), do: {:error, reason}

  defp bound_content(data) when is_binary(data) do
    max_bytes = Config.observability_debug_artifact_max_bytes()
    tail_bytes = min(Config.observability_debug_artifact_tail_bytes(), max_bytes)

    if byte_size(data) <= max_bytes do
      %{data: data, truncated?: false}
    else
      dropped_bytes = byte_size(data) - tail_bytes
      suffix = binary_part(data, byte_size(data), -tail_bytes)
      prefix = "[truncated #{dropped_bytes} bytes]\n"
      bounded = prefix <> suffix

      %{
        data:
          binary_part(
            bounded,
            max(byte_size(bounded) - max_bytes, 0),
            min(byte_size(bounded), max_bytes)
          ),
        truncated?: true
      }
    end
  end
end
