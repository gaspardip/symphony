defmodule SymphonyElixir.CredentialRegistry do
  @moduledoc """
  Local-first credential scope registry for company/repo constrained operations.
  """

  alias SymphonyElixir.{Config, PolicyPack}

  @write_like_operations MapSet.new([
                          "write",
                          "pr_write",
                          "merge",
                          "comment_post",
                          "thread_resolve",
                          "deploy_preview",
                          "deploy_production",
                          "deploy_rollback"
                        ])

  @spec allow?(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def allow?(provider, operation, opts \\ [])
      when is_binary(provider) and is_binary(operation) and is_list(opts) do
    pack = resolve_policy_pack(opts)

    case load_registry() do
      {:ok, nil} ->
        default_allowance(pack, provider, operation)

      {:ok, registry} ->
        repo_url = Keyword.get(opts, :repo_url) || Config.company_repo_url()
        company_name = Keyword.get(opts, :company_name) || Config.company_name()

        case allowed?(registry, provider, operation, repo_url, company_name) do
          true -> :ok
          false -> {:error, {:credential_scope_forbidden, provider, operation}}
        end

      {:error, _reason} ->
        default_allowance(pack, provider, operation)
    end
  end

  @spec load_registry() :: {:ok, map() | nil} | {:error, term()}
  def load_registry do
    case Config.credential_registry_path() do
      nil ->
        {:ok, nil}

      path ->
        if File.exists?(path) do
          with {:ok, payload} <- File.read(path),
               {:ok, decoded} <- Jason.decode(payload) do
            {:ok, decoded}
          end
        else
          {:ok, nil}
        end
    end
  end

  defp allowed?(registry, provider, operation, repo_url, company_name) do
    repo_rule =
      registry
      |> Map.get("repos", %{})
      |> maybe_fetch(repo_url)

    company_rule =
      registry
      |> Map.get("companies", %{})
      |> maybe_fetch(company_name)

    cond do
      match?({:allow, _}, operation_decision(repo_rule, provider, operation)) ->
        true

      match?({:deny, _}, operation_decision(repo_rule, provider, operation)) ->
        false

      match?({:allow, _}, operation_decision(company_rule, provider, operation)) ->
        true

      match?({:deny, _}, operation_decision(company_rule, provider, operation)) ->
        false

      true ->
        true
    end
  end

  defp operation_decision(nil, _provider, _operation), do: :no_rule

  defp operation_decision(rule_scope, provider, operation) when is_map(rule_scope) do
    provider_scope =
      rule_scope
      |> Map.get("providers", %{})
      |> Map.get(provider)

    cond do
      not is_map(provider_scope) ->
        :no_rule

      operation in List.wrap(Map.get(provider_scope, "forbidden_operations", [])) ->
        {:deny, provider_scope}

      operation in List.wrap(Map.get(provider_scope, "allowed_operations", [])) ->
        {:allow, provider_scope}

      Map.get(provider_scope, "default") == "deny" ->
        {:deny, provider_scope}

      true ->
        :no_rule
    end
  end

  defp maybe_fetch(_scope, nil), do: nil
  defp maybe_fetch(scope, key) when is_map(scope), do: Map.get(scope, key)
  defp maybe_fetch(_scope, _key), do: nil

  defp resolve_policy_pack(opts) do
    opts
    |> Keyword.get(:policy_pack, Config.policy_pack_name())
    |> PolicyPack.resolve()
  end

  defp default_allowance(pack, provider, operation) do
    if contractor_write_without_registry?(pack, operation) do
      {:error, {:credential_scope_forbidden, provider, operation}}
    else
      :ok
    end
  end

  defp contractor_write_without_registry?(pack, operation) do
    PolicyPack.contractor_mode?(pack) and MapSet.member?(@write_like_operations, operation)
  end
end
