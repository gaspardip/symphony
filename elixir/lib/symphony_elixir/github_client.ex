defmodule SymphonyElixir.GitHubClient do
  @moduledoc """
  Behaviour for runtime-owned GitHub pull request operations.
  """

  @callback existing_pull_request(Path.t(), keyword()) ::
              {:ok, %{url: String.t(), state: String.t() | nil}} | {:error, term()}
  @callback edit_pull_request(Path.t(), String.t(), Path.t(), keyword()) ::
              {:ok, %{url: String.t(), state: String.t() | nil, output: String.t()}} | {:error, term()}
  @callback create_pull_request(Path.t(), String.t(), String.t(), String.t(), Path.t(), keyword()) ::
              {:ok, %{url: String.t(), state: String.t() | nil}} | {:error, term()}
  @callback merge_pull_request(Path.t(), keyword()) ::
              {:ok, %{merged: boolean(), url: String.t() | nil, output: String.t(), status: atom()}} | {:error, term()}
  @callback review_feedback(Path.t(), keyword()) ::
              {:ok,
               %{
                 pr_url: String.t() | nil,
                 review_decision: String.t() | nil,
                 reviews: [map()],
                 comments: [map()]
               }}
              | {:error, term()}
  @callback review_feedback_by_pr_url(String.t(), keyword()) ::
              {:ok,
               %{
                 pr_url: String.t() | nil,
                 review_decision: String.t() | nil,
                 reviews: [map()],
                 comments: [map()]
               }}
              | {:error, term()}
  @optional_callbacks review_feedback_by_pr_url: 2
  @callback persist_pr_url(Path.t(), String.t() | nil, String.t(), keyword()) :: :ok
  @callback post_review_comment_reply(String.t(), String.t(), String.t(), keyword()) ::
              {:ok, %{id: String.t() | nil, url: String.t() | nil, output: String.t() | nil}}
              | {:error, term()}
end
