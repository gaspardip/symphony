defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Observability.Metrics
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec delivery_report(Conn.t(), map()) :: Conn.t()
  def delivery_report(conn, _params) do
    json(conn, Presenter.delivery_report_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec portfolio(Conn.t(), map()) :: Conn.t()
  def portfolio(conn, _params) do
    json(conn, Presenter.portfolio_payload())
  end

  @spec metrics(Conn.t(), map()) :: Conn.t()
  def metrics(conn, _params) do
    case safe_metrics_scrape() do
      {:ok, metrics} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, metrics)

      {:error, :unavailable} ->
        error_response(conn, 503, "metrics_unavailable", "Metrics collector is unavailable")
    end
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec manual_run(Conn.t(), map()) :: Conn.t()
  def manual_run(conn, params) when is_map(params) do
    case SymphonyElixir.Orchestrator.submit_manual_issue(orchestrator(), params) do
      :unavailable ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")

      %{ok: true} = payload ->
        conn
        |> put_status(202)
        |> json(payload)

      %{ok: false, error: error} ->
        error_response(conn, 400, "manual_issue_rejected", to_string(error))
    end
  end

  @spec control(Conn.t(), map()) :: Conn.t()
  def control(conn, %{"issue_identifier" => issue_identifier, "action" => action} = params) do
    case Presenter.control_payload(action, issue_identifier, params, orchestrator()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :unknown_action} ->
        error_response(conn, 400, "unknown_action", "Unknown control action")

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec runner_control(Conn.t(), map()) :: Conn.t()
  def runner_control(conn, %{"action" => action} = params) do
    case Presenter.runner_control_payload(action, params) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :unknown_action} ->
        error_response(conn, 400, "unknown_action", "Unknown runner action")

      {:error, {:invalid_params, message}} ->
        error_response(conn, 400, "invalid_params", message)

      {:error, %{error: "script_missing", message: message}} ->
        error_response(conn, 503, "runner_script_missing", message)

      {:error, %{error: "command_failed", message: message} = payload} ->
        conn
        |> put_status(409)
        |> json(payload |> Map.put(:error, %{code: "runner_command_failed", message: message}))

      {:error, reason} ->
        error_response(conn, 500, "runner_action_failed", inspect(reason))
    end
  end

  @spec health(Conn.t(), map()) :: Conn.t()
  def health(conn, _params) do
    json(conn, %{
      status: "ok",
      timestamp: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      version: SymphonyElixir.RunnerRuntime.runtime_version()
    })
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp safe_metrics_scrape do
    {:ok, Metrics.scrape()}
  rescue
    UndefinedFunctionError -> {:error, :unavailable}
    ErlangError -> {:error, :unavailable}
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
