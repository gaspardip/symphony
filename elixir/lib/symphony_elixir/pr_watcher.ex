defmodule SymphonyElixir.PRWatcher do
  @moduledoc """
  Policy-derived PR watcher posture.

  Phase 2 will add live GitHub review/comment ingestion. For now, this module
  exposes the effective watcher mode so the runtime and operator surfaces can
  explain how PR review automation is expected to behave for the active policy
  pack.
  """

  alias SymphonyElixir.{AuthorProfile, Config, CredentialRegistry, GitHubCLIClient, Observability, PolicyPack}

  @type t :: %{
          enabled: boolean(),
          mode: String.t(),
          posting_allowed: boolean(),
          draft_first_required: boolean(),
          thread_resolution_allowed: boolean(),
          external_comment_mode: String.t(),
          allowed_channels: [String.t()]
        }

  @type feedback_item :: %{
          thread_key: String.t(),
          id: String.t(),
          kind: :comment | :review,
          author: String.t() | nil,
          body: String.t() | nil,
          path: String.t() | nil,
          line: integer() | nil,
          state: String.t() | nil,
          submitted_at: String.t() | nil,
          draft_state: String.t(),
          draft_reply: String.t(),
          resolution_recommendation: String.t()
        }

  @spec status(PolicyPack.t() | String.t() | atom() | nil) :: t()
  def status(pack_or_name \\ nil) do
    pack = PolicyPack.resolve(pack_or_name)
    channels = Map.get(pack, :allowed_external_channels, [])
    pr_channel? = "pull_request" in channels
    posting_allowed = PolicyPack.pr_posting_allowed?(pack)
    draft_first_required = Map.get(pack, :draft_first_required, true)
    thread_resolution_allowed = PolicyPack.thread_resolution_allowed?(pack)
    external_comment_mode = Map.get(pack, :external_comment_mode, "forbidden")

    %{
      enabled: pr_channel? or posting_allowed or external_comment_mode == "draft_only",
      mode: watcher_mode(pack, pr_channel?, posting_allowed, external_comment_mode),
      posting_allowed: posting_allowed,
      draft_first_required: draft_first_required,
      thread_resolution_allowed: thread_resolution_allowed,
      external_comment_mode: external_comment_mode,
      allowed_channels: channels
    }
  end

  @spec review_feedback(Path.t(), keyword()) :: map()
  def review_feedback(workspace, opts \\ []) when is_binary(workspace) do
    pack = PolicyPack.resolve(Keyword.get(opts, :policy_pack))
    watcher = status(pack)
    thread_states = normalize_thread_states(Keyword.get(opts, :thread_states, %{}))
    pr_url = Keyword.get(opts, :pr_url)

    if watcher.enabled do
      github_client = Keyword.get(opts, :github_client, configured_github_client())
      github_opts = Keyword.merge(configured_github_client_opts(), Keyword.get(opts, :github_client_opts, []))

      case review_feedback_for_source(github_client, workspace, pr_url, github_opts) do
        {:ok, feedback} ->
          items = build_feedback_items(feedback, thread_states)
          review_count = Enum.count(items, &(&1.kind == :review))
          comment_count = Enum.count(items, &(&1.kind == :comment))

          Observability.emit([:symphony, :review, :feedback_detected], %{count: length(items)}, %{
            pr_url: Map.get(feedback, :pr_url) || Map.get(feedback, "pr_url"),
            review_count: review_count,
            comment_count: comment_count
          })

          %{
            status: "ok",
            pr_url: Map.get(feedback, :pr_url) || Map.get(feedback, "pr_url"),
            review_decision: Map.get(feedback, :review_decision) || Map.get(feedback, "review_decision"),
            pending_drafts_count: length(items),
            items: items
          }

        {:error, reason} ->
          Observability.emit([:symphony, :review, :feedback_detected], %{count: 0}, %{
            pr_url: pr_url,
            outcome: "error",
            reason: inspect(reason)
          })

          cached_feedback(thread_states, pr_url, reason)
      end
    else
      %{status: "disabled", pending_drafts_count: 0, items: []}
    end
  end

  defp watcher_mode(_pack, false, false, "forbidden"), do: "disabled"
  defp watcher_mode(_pack, _pr_channel?, false, "draft_only"), do: "draft_only"

  defp watcher_mode(pack, _pr_channel?, true, _external_comment_mode) do
    if Map.get(pack, :draft_first_required, true), do: "draft_first", else: "active"
  end

  defp build_feedback_items(feedback, thread_states) do
    review_items =
      feedback
      |> Map.get(:reviews, [])
      |> Enum.filter(&(present?(Map.get(&1, :body)) or present?(Map.get(&1, "body"))))
      |> Enum.map(&review_item(&1, thread_states))

    comment_items =
      feedback
      |> Map.get(:comments, [])
      |> Enum.filter(&(present?(Map.get(&1, :body)) or present?(Map.get(&1, "body"))))
      |> Enum.map(&comment_item(&1, thread_states))

    review_items ++ comment_items
  end

  defp cached_feedback(thread_states, pr_url, reason) when map_size(thread_states) > 0 do
    items =
      thread_states
      |> Enum.map(&cached_item/1)
      |> Enum.sort_by(& &1.thread_key)

    %{
      status: "cached",
      reason: inspect(reason),
      pr_url: normalize_cached_pr_url(pr_url, thread_states),
      pending_drafts_count: length(items),
      items: items
    }
  end

  defp cached_feedback(_thread_states, _pr_url, reason) do
    %{status: "unavailable", reason: inspect(reason), pending_drafts_count: 0, items: []}
  end

  defp cached_item({thread_key, persisted}) do
    kind =
      case String.split(to_string(thread_key), ":", parts: 2) do
        ["review", _] -> :review
        ["comment", _] -> :comment
        _ -> :comment
      end

    id =
      thread_key
      |> to_string()
      |> String.split(":", parts: 2)
      |> List.last()

    %{
      thread_key: to_string(thread_key),
      id: id,
      kind: kind,
      author: nil,
      body: nil,
      path: nil,
      line: nil,
      state: nil,
      submitted_at: nil,
      draft_state: Map.get(persisted, "draft_state", "drafted"),
      draft_reply: Map.get(persisted, "draft_reply"),
      resolution_recommendation: Map.get(persisted, "resolution_recommendation", "keep_open_until_confirmed")
    }
  end

  defp review_item(review, thread_states) do
    body = Map.get(review, :body) || Map.get(review, "body")
    state = Map.get(review, :state) || Map.get(review, "state")
    id = to_string(Map.get(review, :id) || Map.get(review, "id"))
    thread_key = "review:#{id}"
    persisted = Map.get(thread_states, thread_key, %{})

    %{
      thread_key: thread_key,
      id: id,
      kind: :review,
      author: Map.get(review, :author) || Map.get(review, "author"),
      body: body,
      path: nil,
      line: nil,
      state: state,
      submitted_at: Map.get(review, :submitted_at) || Map.get(review, "submitted_at"),
      draft_state: Map.get(persisted, "draft_state", "drafted"),
      draft_reply: Map.get(persisted, "draft_reply", draft_reply(body, state)),
      resolution_recommendation: Map.get(persisted, "resolution_recommendation", resolution_recommendation(body, state))
    }
  end

  defp comment_item(comment, thread_states) do
    body = Map.get(comment, :body) || Map.get(comment, "body")
    id = to_string(Map.get(comment, :id) || Map.get(comment, "id"))
    thread_key = "comment:#{id}"
    persisted = Map.get(thread_states, thread_key, %{})

    %{
      thread_key: thread_key,
      id: id,
      kind: :comment,
      author: Map.get(comment, :author) || Map.get(comment, "author"),
      body: body,
      path: Map.get(comment, :path) || Map.get(comment, "path"),
      line: Map.get(comment, :line) || Map.get(comment, "line"),
      state: nil,
      submitted_at: Map.get(comment, :created_at) || Map.get(comment, "created_at"),
      draft_state: Map.get(persisted, "draft_state", "drafted"),
      draft_reply: Map.get(persisted, "draft_reply", draft_reply(body, nil)),
      resolution_recommendation: Map.get(persisted, "resolution_recommendation", resolution_recommendation(body, nil))
    }
  end

  defp draft_reply(body, state) do
    base =
      cond do
        normalized_state(state) == "changes_requested" ->
          "I agree this needs a follow-up change. I will address it before treating the review as resolved."

        contains_nit?(body) ->
          "I agree with the nit and will adjust it in the follow-up update."

        true ->
          "I reviewed this feedback and will either address it in code or reply with context before resolving it."
      end

    AuthorProfile.summarize(base, :comment)
  end

  defp resolution_recommendation(body, state) do
    cond do
      normalized_state(state) == "changes_requested" -> "keep_open_until_change"
      contains_nit?(body) -> "resolve_after_change"
      true -> "keep_open_until_confirmed"
    end
  end

  defp contains_nit?(body) when is_binary(body) do
    body
    |> String.downcase()
    |> String.contains?("nit")
  end

  defp contains_nit?(_), do: false

  defp normalized_state(nil), do: nil
  defp normalized_state(value), do: value |> to_string() |> String.trim() |> String.downcase()

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  defp configured_github_client do
    Application.get_env(:symphony_elixir, :pr_watcher_github_client, GitHubCLIClient)
  end

  defp configured_github_client_opts do
    Application.get_env(:symphony_elixir, :pr_watcher_github_client_opts, [])
  end

  defp review_feedback_for_source(github_client, workspace, pr_url, github_opts) do
    case github_client.review_feedback(workspace, github_opts) do
      {:ok, feedback} ->
        {:ok, feedback}

      {:error, _reason} = error ->
        if is_binary(pr_url) and pr_url != "" and function_exported?(github_client, :review_feedback_by_pr_url, 2) do
          github_client.review_feedback_by_pr_url(pr_url, github_opts)
        else
          error
        end
    end
  end

  defp normalize_thread_states(states) when is_map(states), do: states
  defp normalize_thread_states(_), do: %{}

  defp normalize_cached_pr_url(pr_url, thread_states) do
    normalize_pr_url(pr_url) ||
      thread_states
      |> Enum.find_value(fn {_thread_key, state} ->
        state
        |> Map.get("posted_reply_url")
        |> normalize_pr_url()
      end)
  end

  defp normalize_pr_url(nil), do: nil

  defp normalize_pr_url(url) when is_binary(url) do
    url
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed |> String.split("#", parts: 2) |> hd()
    end
  end

  defp normalize_pr_url(_), do: nil

  @spec post_approved_drafts(Path.t(), String.t(), map(), keyword()) ::
          {:ok, map(), map()} | {:error, term()}
  def post_approved_drafts(workspace, pr_url, thread_states, opts \\ [])
      when is_binary(workspace) and is_binary(pr_url) and is_map(thread_states) do
    pack = PolicyPack.resolve(Keyword.get(opts, :policy_pack))

    cond do
      not PolicyPack.external_comment_posting_allowed?(pack) ->
        {:error, {:external_comment_posting_forbidden, PolicyPack.name_string(pack)}}

      true ->
        with :ok <- ensure_comment_post_scope(opts),
             {updated_threads, posted_count, skipped_count} <-
               do_post_approved_drafts(
                 workspace,
                 pr_url,
                 thread_states,
                 Keyword.get(opts, :github_client, configured_github_client()),
                 Keyword.merge(configured_github_client_opts(), Keyword.get(opts, :github_client_opts, []))
               ),
             true <- posted_count > 0 do
          {:ok, updated_threads, %{posted_count: posted_count, skipped_count: skipped_count}}
        else
          false -> {:error, :no_postable_review_threads}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp do_post_approved_drafts(workspace, pr_url, thread_states, github_client, github_opts) do
    Enum.reduce(thread_states, {thread_states, 0, 0}, fn {thread_key, thread_state}, {acc, posted, skipped} ->
      draft_state = thread_state |> Map.get("draft_state", "drafted") |> to_string()
      draft_reply = Map.get(thread_state, "draft_reply")

      cond do
        draft_state != "approved_to_post" or not present?(draft_reply) ->
          {acc, posted, skipped}

        String.starts_with?(to_string(thread_key), "comment:") ->
          comment_id =
            thread_key
            |> to_string()
            |> String.split(":", parts: 2)
            |> List.last()

          case github_client.post_review_comment_reply(pr_url, comment_id, draft_reply, github_opts) do
            {:ok, reply} ->
              updated =
                thread_state
                |> Map.put("draft_state", "posted")
                |> Map.put("posted_at", DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601())
                |> Map.put("posted_reply_id", Map.get(reply, :id))
                |> Map.put("posted_reply_url", Map.get(reply, :url))

              {Map.put(acc, thread_key, updated), posted + 1, skipped}

            {:error, _reason} ->
              {acc, posted, skipped + 1}
          end

        true ->
          {acc, posted, skipped + 1}
      end
    end)
  end

  defp ensure_comment_post_scope(opts) do
    CredentialRegistry.allow?(
      "github",
      "comment_post",
      policy_pack: Keyword.get(opts, :policy_pack),
      company_name: Keyword.get(opts, :company_name) || Config.company_name(),
      repo_url: Keyword.get(opts, :repo_url) || Config.company_repo_url()
    )
  end
end
