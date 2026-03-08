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
  @callback persist_pr_url(Path.t(), String.t() | nil, String.t(), keyword()) :: :ok
end
