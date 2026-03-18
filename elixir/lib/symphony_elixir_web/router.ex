defmodule SymphonyElixirWeb.Router do
  @moduledoc """
  Router for Symphony's observability dashboard and API.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

  @metrics_path Application.compile_env(:symphony_elixir, [:observability, :metrics_path], "/metrics")

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {SymphonyElixirWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", SymphonyElixirWeb do
    get("/dashboard.css", StaticAssetController, :dashboard_css)
    get("/vendor/phoenix_html/phoenix_html.js", StaticAssetController, :phoenix_html_js)
    get("/vendor/phoenix/phoenix.js", StaticAssetController, :phoenix_js)
    get("/vendor/phoenix_live_view/phoenix_live_view.js", StaticAssetController, :phoenix_live_view_js)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:browser)

    live("/", DashboardLive, :index)
  end

  scope "/", SymphonyElixirWeb do
    post("/api/webhooks/linear", LinearWebhookController, :create)
    match(:*, "/api/webhooks/linear", ObservabilityApiController, :method_not_allowed)
    post("/api/webhooks/github", GitHubWebhookController, :create)
    match(:*, "/api/webhooks/github", ObservabilityApiController, :method_not_allowed)
    get(@metrics_path, ObservabilityApiController, :metrics)
    match(:*, @metrics_path, ObservabilityApiController, :method_not_allowed)
    get("/api/v1/state", ObservabilityApiController, :state)
    get("/api/v1/portfolio", ObservabilityApiController, :portfolio)
    post("/api/v1/runner/actions/:action", ObservabilityApiController, :runner_control)
    match(:*, "/api/v1/runner/actions/:action", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/manual-runs", ObservabilityApiController, :manual_run)
    match(:*, "/api/v1/manual-runs", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/reports/delivery", ObservabilityApiController, :delivery_report)
    match(:*, "/api/v1/reports/delivery", ObservabilityApiController, :method_not_allowed)

    match(:*, "/", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/portfolio", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/refresh", ObservabilityApiController, :refresh)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/:issue_identifier/actions/:action", ObservabilityApiController, :control)
    match(:*, "/api/v1/:issue_identifier/actions/:action", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end
end
