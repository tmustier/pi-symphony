defmodule SymphonyElixirWeb.Router do
  @moduledoc """
  Router for Symphony's observability dashboard and API.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

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
    get("/api/v1/state", ObservabilityApiController, :state)
    get("/api/v1/events", ObservabilityApiController, :events)
    get("/api/v1/runs", ObservabilityApiController, :runs)
    get("/api/v1/runs/:issue_identifier/workspace", ObservabilityApiController, :run_workspace)
    get("/api/v1/runs/:issue_identifier/pr", ObservabilityApiController, :run_pr)
    get("/api/v1/runs/:issue_identifier/logs", ObservabilityApiController, :run_logs)
    get("/api/v1/runs/:issue_identifier/events", ObservabilityApiController, :run_events)
    get("/api/v1/runs/:issue_identifier/transitions", ObservabilityApiController, :run_transitions)
    get("/api/v1/runs/:issue_identifier", ObservabilityApiController, :run)

    match(:*, "/", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/events", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/runs", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/runs/:issue_identifier/workspace", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/runs/:issue_identifier/pr", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/runs/:issue_identifier/logs", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/runs/:issue_identifier/events", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/runs/:issue_identifier/transitions", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/runs/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/refresh", ObservabilityApiController, :refresh)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/transcript/:issue_identifier", ObservabilityApiController, :transcript)
    match(:*, "/api/v1/transcript/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/workspaces", ObservabilityApiController, :workspaces)
    post("/api/v1/workspaces/cleanup", ObservabilityApiController, :workspaces_cleanup)
    match(:*, "/api/v1/workspaces", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/workspaces/cleanup", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end
end
