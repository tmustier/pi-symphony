defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Real-time monitoring dashboard for Symphony orchestration.

  Renders a dark-theme monitoring UI backed by Phoenix LiveView with:
  - System-level metrics ribbon (agents, tokens, runtime)
  - Tabbed views: Overview, Sessions, Dependencies, Events
  - Clickable issue detail panel (worker, tokens, retry, orchestration)
  - Dependency tree visualization (SVG with topological layout)
  - Live event stream aggregated from active workers
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  # ─── Mount ──────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())
      |> assign(:active_tab, "overview")
      |> assign(:selected_issue, nil)

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  # ─── Events ─────────────────────────────────────────

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket)
      when tab in ["overview", "sessions", "dependencies", "events"] do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  def handle_event("select_issue", %{"id" => identifier}, socket) do
    {:noreply, assign(socket, :selected_issue, identifier)}
  end

  def handle_event("close_detail", _params, socket) do
    {:noreply, assign(socket, :selected_issue, nil)}
  end

  # ─── Info ───────────────────────────────────────────

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  # ─── Render ─────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- Top Bar --%>
    <nav class="top-bar">
      <div class="top-bar-inner">
        <div class="logo-group">
          <div class="logo-mark">
            <svg viewBox="0 0 24 24"><path d="M13 3L4 14h7l-2 7 9-11h-7l2-7z" /></svg>
          </div>
          <span class="logo-text">Symphony <span>Monitor</span></span>
        </div>

        <%= if @payload[:error] do %>
          <span class="status-pill status-pill-offline">
            <span class="pulse-dot"></span>
            Error
          </span>
        <% else %>
          <div class="metric-ribbon">
            <div class="ribbon-metric">
              <span class="ribbon-metric-label">Agents</span>
              <span class="ribbon-metric-value accent numeric"><%= @payload.counts.running %></span>
            </div>
            <div class="ribbon-metric">
              <span class="ribbon-metric-label">Retrying</span>
              <span class="ribbon-metric-value numeric"><%= @payload.counts.retrying %></span>
            </div>
            <div class="ribbon-metric">
              <span class="ribbon-metric-label">Tracked</span>
              <span class="ribbon-metric-value numeric"><%= @payload.counts.tracked %></span>
            </div>
            <div class="ribbon-metric">
              <span class="ribbon-metric-label">Tokens</span>
              <span class="ribbon-metric-value numeric"><%= format_int(worker_totals(@payload).total_tokens) %></span>
            </div>
            <div class="ribbon-metric">
              <span class="ribbon-metric-label">Runtime</span>
              <span class="ribbon-metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></span>
            </div>
          </div>
        <% end %>

        <span class="status-pill status-pill-live">
          <span class="pulse-dot"></span>
          Live
        </span>
        <span class="status-pill status-pill-offline">
          <span class="pulse-dot"></span>
          Offline
        </span>
      </div>
    </nav>

    <%= if @payload[:error] do %>
      <div class="error-card">
        <h2>Snapshot unavailable</h2>
        <p><strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %></p>
      </div>
    <% else %>
      <%!-- Tab Navigation --%>
      <div class="tab-bar">
        <button
          class={"tab-btn #{if @active_tab == "overview", do: "active"}"}
          phx-click="switch_tab"
          phx-value-tab="overview"
        >
          Overview
        </button>
        <button
          class={"tab-btn #{if @active_tab == "sessions", do: "active"}"}
          phx-click="switch_tab"
          phx-value-tab="sessions"
        >
          Sessions
          <span class="tab-count"><%= length(@payload.running) + length(@payload.retrying) %></span>
        </button>
        <button
          class={"tab-btn #{if @active_tab == "dependencies", do: "active"}"}
          phx-click="switch_tab"
          phx-value-tab="dependencies"
        >
          Dependencies
          <span class="tab-count"><%= length(@payload.tracked || []) %></span>
        </button>
        <button
          class={"tab-btn #{if @active_tab == "events", do: "active"}"}
          phx-click="switch_tab"
          phx-value-tab="events"
        >
          Events
        </button>
      </div>

      <%!-- Issue Detail Panel (shown when an issue is selected) --%>
      <%= if @selected_issue do %>
        <.issue_detail_panel
          identifier={@selected_issue}
          payload={@payload}
          now={@now}
        />
      <% end %>

      <%!-- Tab: Overview --%>
      <%= if @active_tab == "overview" do %>
        <.tab_overview payload={@payload} now={@now} />
      <% end %>

      <%!-- Tab: Sessions --%>
      <%= if @active_tab == "sessions" do %>
        <.tab_sessions payload={@payload} now={@now} />
      <% end %>

      <%!-- Tab: Dependencies --%>
      <%= if @active_tab == "dependencies" do %>
        <.tab_dependencies payload={@payload} />
      <% end %>

      <%!-- Tab: Events --%>
      <%= if @active_tab == "events" do %>
        <.tab_events payload={@payload} now={@now} />
      <% end %>
    <% end %>
    """
  end

  # ─── Tab: Overview ─────────────────────────────────

  defp tab_overview(assigns) do
    ~H"""
    <%!-- Metric Cards --%>
    <div class="metric-grid">
      <div class="metric-card">
        <p class="metric-label">Running</p>
        <p class="metric-value color-running numeric"><%= @payload.counts.running %></p>
        <p class="metric-detail">Active worker sessions</p>
      </div>

      <div class="metric-card">
        <p class="metric-label">Retrying</p>
        <p class="metric-value color-retrying numeric"><%= @payload.counts.retrying %></p>
        <p class="metric-detail">Waiting for retry window</p>
      </div>

      <div class="metric-card">
        <p class="metric-label">Total Tokens</p>
        <p class="metric-value numeric"><%= format_int(worker_totals(@payload).total_tokens) %></p>
        <p class="metric-detail numeric">
          In <%= format_int(worker_totals(@payload).input_tokens) %> ·
          Out <%= format_int(worker_totals(@payload).output_tokens) %>
        </p>
      </div>

      <div class="metric-card">
        <p class="metric-label">Runtime</p>
        <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
        <p class="metric-detail">Total across all sessions</p>
      </div>

      <div class="metric-card">
        <p class="metric-label">Tracked</p>
        <p class="metric-value numeric"><%= @payload.counts.tracked %></p>
        <p class="metric-detail">Issues under orchestration</p>
      </div>

      <div class="metric-card">
        <p class="metric-label">Merge Queue</p>
        <p class="metric-value numeric"><%= @payload.counts.merge_queued %></p>
        <p class="metric-detail">Awaiting merge</p>
      </div>
    </div>

    <%!-- Rate Limits --%>
    <div class="section">
      <div class="section-head">
        <h2 class="section-title">Rate Limits</h2>
      </div>
      <.rate_limits_display rate_limits={@payload.rate_limits} />
    </div>

    <%!-- Running Sessions Summary --%>
    <%= if @payload.running != [] do %>
      <div class="section">
        <div class="section-head">
          <h2 class="section-title">
            Active Agents
            <span class="count-badge"><%= length(@payload.running) %></span>
          </h2>
        </div>
        <div class="table-wrap">
          <.running_table entries={@payload.running} now={@now} />
        </div>
      </div>
    <% end %>

    <%!-- Retry Queue Summary --%>
    <%= if @payload.retrying != [] do %>
      <div class="section">
        <div class="section-head">
          <h2 class="section-title">
            Retry Queue
            <span class="count-badge"><%= length(@payload.retrying) %></span>
          </h2>
        </div>
        <div class="table-wrap">
          <.retry_table entries={@payload.retrying} />
        </div>
      </div>
    <% end %>

    <%!-- Merge Queue --%>
    <.merge_queue_section merge={@payload.merge} />
    """
  end

  # ─── Tab: Sessions ─────────────────────────────────

  defp tab_sessions(assigns) do
    ~H"""
    <%!-- Running Sessions --%>
    <div class="section">
      <div class="section-head">
        <h2 class="section-title">
          Running Sessions
          <span class="count-badge"><%= length(@payload.running) %></span>
        </h2>
      </div>
      <%= if @payload.running == [] do %>
        <div class="empty-state">
          <div class="empty-state-icon">◇</div>
          No active sessions
        </div>
      <% else %>
        <div class="table-wrap">
          <.running_table entries={@payload.running} now={@now} />
        </div>
      <% end %>
    </div>

    <%!-- Retry Queue --%>
    <div class="section">
      <div class="section-head">
        <h2 class="section-title">
          Retry Queue
          <span class="count-badge"><%= length(@payload.retrying) %></span>
        </h2>
      </div>
      <%= if @payload.retrying == [] do %>
        <div class="empty-state">
          <div class="empty-state-icon">↻</div>
          No queued retries
        </div>
      <% else %>
        <div class="table-wrap">
          <.retry_table entries={@payload.retrying} />
        </div>
      <% end %>
    </div>

    <%!-- Tracked Issues --%>
    <div class="section">
      <div class="section-head">
        <h2 class="section-title">
          Tracked Issues
          <span class="count-badge"><%= length(@payload.tracked || []) %></span>
        </h2>
      </div>
      <%= if (@payload.tracked || []) == [] do %>
        <div class="empty-state">
          <div class="empty-state-icon">◌</div>
          No tracked issues
        </div>
      <% else %>
        <div class="table-wrap">
          <.tracked_table entries={@payload.tracked} />
        </div>
      <% end %>
    </div>
    """
  end

  # ─── Tab: Dependencies ─────────────────────────────

  defp tab_dependencies(assigns) do
    graph = build_dependency_graph(assigns.payload.tracked || [])
    assigns = assign(assigns, :graph, graph)

    ~H"""
    <div class="section">
      <div class="section-head">
        <h2 class="section-title">
          Dependency Graph
          <span class="count-badge"><%= length(@payload.tracked || []) %> issues</span>
        </h2>
        <p class="section-subtitle">Visual map of issue dependencies and orchestration flow</p>
      </div>
      <div class="dep-graph-container">
        <%= if @graph.nodes == [] do %>
          <div class="empty-state">
            <div class="empty-state-icon">⬡</div>
            No tracked issues to visualize
          </div>
        <% else %>
          <.dependency_svg graph={@graph} />
        <% end %>
      </div>
    </div>

    <%!-- Tracked Issues Table (below graph) --%>
    <%= if (@payload.tracked || []) != [] do %>
      <div class="section">
        <div class="section-head">
          <h2 class="section-title">All Tracked Issues</h2>
        </div>
        <div class="table-wrap">
          <.tracked_table entries={@payload.tracked} />
        </div>
      </div>
    <% end %>
    """
  end

  # ─── Tab: Events ───────────────────────────────────

  defp tab_events(assigns) do
    events = build_event_stream(assigns.payload, assigns.now)
    assigns = assign(assigns, :events, events)

    ~H"""
    <div class="section">
      <div class="section-head">
        <h2 class="section-title">
          Live Event Stream
          <span class="count-badge"><%= length(@events) %> events</span>
        </h2>
        <p class="section-subtitle">Recent worker activity across all sessions</p>
      </div>
      <div class="event-stream">
        <%= if @events == [] do %>
          <div class="empty-state">
            <div class="empty-state-icon">⚡</div>
            No recent events
          </div>
        <% else %>
          <div :for={event <- @events} class="event-stream-item">
            <span class="event-time mono"><%= event.time %></span>
            <span class="event-issue"><%= event.issue %></span>
            <span class="event-type mono"><%= event.type %></span>
            <span class="event-body"><%= event.message %></span>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # ─── Component: Running Table ──────────────────────

  defp running_table(assigns) do
    ~H"""
    <table class="data-table">
      <thead>
        <tr>
          <th style="width: 4rem;">Status</th>
          <th style="width: 7rem;">Issue</th>
          <th style="width: 7rem;">State</th>
          <th style="width: 6.5rem;">Runtime</th>
          <th>Worker Update</th>
          <th style="width: 8rem;">Tokens</th>
          <th style="width: 6rem;">Session</th>
        </tr>
      </thead>
      <tbody>
        <tr
          :for={entry <- @entries}
          class="clickable"
          phx-click="select_issue"
          phx-value-id={entry.issue_identifier}
        >
          <td>
            <div class="agent-indicator">
              <span class={"agent-dot #{agent_dot_class(entry.state)}"}></span>
            </div>
          </td>
          <td>
            <span class="issue-id"><%= entry.issue_identifier %></span>
          </td>
          <td>
            <span class={state_badge_class(entry.state)}>
              <%= entry.state %>
            </span>
          </td>
          <td class="numeric">
            <%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %>
          </td>
          <td>
            <div class="event-text">
              <span class="event-message" title={entry.last_message || to_string(entry.last_event || "n/a")}>
                <%= entry.last_message || to_string(entry.last_event || "n/a") %>
              </span>
              <span class="event-meta">
                <%= entry.last_event || "n/a" %>
                <%= if entry.last_event_at do %>
                  · <span class="mono"><%= entry.last_event_at %></span>
                <% end %>
              </span>
            </div>
          </td>
          <td>
            <div class="token-display">
              <span class="token-total numeric"><%= format_int(entry.tokens.total_tokens) %></span>
              <span class="token-breakdown numeric">
                <%= format_int(entry.tokens.input_tokens) %> / <%= format_int(entry.tokens.output_tokens) %>
              </span>
            </div>
          </td>
          <td>
            <%= if entry.session_id do %>
              <button
                type="button"
                class="session-btn"
                data-label="Copy"
                data-copy={entry.session_id}
                onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = '✓'; clearTimeout(this._t); this._t = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
              >
                Copy
              </button>
            <% else %>
              <span class="text-dim">—</span>
            <% end %>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  # ─── Component: Retry Table ────────────────────────

  defp retry_table(assigns) do
    ~H"""
    <table class="data-table">
      <thead>
        <tr>
          <th style="width: 4rem;">Status</th>
          <th style="width: 7rem;">Issue</th>
          <th style="width: 5rem;">Attempt</th>
          <th style="width: 10rem;">Due At</th>
          <th>Error</th>
        </tr>
      </thead>
      <tbody>
        <tr
          :for={entry <- @entries}
          class="clickable"
          phx-click="select_issue"
          phx-value-id={entry.issue_identifier}
        >
          <td>
            <div class="agent-indicator">
              <span class="agent-dot agent-dot-retrying"></span>
            </div>
          </td>
          <td><span class="issue-id"><%= entry.issue_identifier %></span></td>
          <td class="numeric"><%= entry.attempt %></td>
          <td class="mono"><%= entry.due_at || "n/a" %></td>
          <td class="text-muted"><%= entry.error || "n/a" %></td>
        </tr>
      </tbody>
    </table>
    """
  end

  # ─── Component: Tracked Table ──────────────────────

  defp tracked_table(assigns) do
    ~H"""
    <table class="data-table">
      <thead>
        <tr>
          <th style="width: 7rem;">Issue</th>
          <th style="width: 7rem;">State</th>
          <th style="width: 7rem;">Phase</th>
          <th style="width: 12rem;">Dependencies</th>
          <th>Waiting</th>
          <th style="width: 10rem;">Next Action</th>
        </tr>
      </thead>
      <tbody>
        <tr
          :for={entry <- @entries}
          class="clickable"
          phx-click="select_issue"
          phx-value-id={entry.issue_identifier}
        >
          <td><span class="issue-id"><%= entry.issue_identifier %></span></td>
          <td>
            <span class={state_badge_class(entry.state)}>
              <%= entry.state %>
            </span>
          </td>
          <td>
            <span class={phase_badge_class(entry.phase)}>
              <%= entry.phase || "unknown" %>
            </span>
          </td>
          <td>
            <div class="flex-col gap-xs">
              <%= if (entry.blocked_by || []) != [] do %>
                <span class="text-muted" style="font-size: 0.75rem">← <%= dep_identifiers(entry.blocked_by) %></span>
              <% end %>
              <%= if (entry.blocks || []) != [] do %>
                <span class="text-muted" style="font-size: 0.75rem">→ <%= dep_identifiers(entry.blocks) %></span>
              <% end %>
              <%= if (entry.blocked_by || []) == [] and (entry.blocks || []) == [] do %>
                <span class="text-dim">—</span>
              <% end %>
            </div>
          </td>
          <td>
            <%= if entry.waiting_reason do %>
              <span class="text-muted" style="font-size: 0.75rem"><%= entry.waiting_reason %></span>
              <%= if waiting_duration(entry) do %>
                <br /><span class="text-dim mono" style="font-size: 0.6875rem"><%= waiting_duration(entry) %></span>
              <% end %>
            <% else %>
              <span class="text-dim">—</span>
            <% end %>
          </td>
          <td><span class="text-muted" style="font-size: 0.75rem"><%= entry.next_intended_action || "—" %></span></td>
        </tr>
      </tbody>
    </table>
    """
  end

  # ─── Component: Issue Detail Panel ─────────────────

  defp issue_detail_panel(assigns) do
    running = Enum.find(assigns.payload.running, &(&1.issue_identifier == assigns.identifier))
    retry = Enum.find(assigns.payload.retrying, &(&1.issue_identifier == assigns.identifier))
    tracked = Enum.find(assigns.payload.tracked || [], &(&1.issue_identifier == assigns.identifier))

    assigns =
      assigns
      |> assign(:running, running)
      |> assign(:retry, retry)
      |> assign(:tracked, tracked)

    ~H"""
    <div class="detail-panel">
      <div class="detail-header">
        <div class="detail-header-left">
          <%= if @running do %>
            <span class="agent-dot agent-dot-running"></span>
          <% else %>
            <%= if @retry do %>
              <span class="agent-dot agent-dot-retrying"></span>
            <% else %>
              <span class="agent-dot agent-dot-idle"></span>
            <% end %>
          <% end %>
          <span class="issue-id" style="font-size: 1rem"><%= @identifier %></span>
          <span class={issue_status_badge(@running, @retry, @tracked)}>
            <%= issue_status_label(@running, @retry, @tracked) %>
          </span>
        </div>
        <button class="detail-close-btn" phx-click="close_detail">✕</button>
      </div>

      <div class="detail-body">
        <%!-- Worker Info --%>
        <div class="detail-section">
          <p class="detail-section-title">Worker</p>
          <div class="detail-kv">
            <%= if @running do %>
              <div class="detail-kv-row">
                <span class="detail-kv-key">State</span>
                <span class="detail-kv-val"><%= @running.state %></span>
              </div>
              <div class="detail-kv-row">
                <span class="detail-kv-key">Session</span>
                <span class="detail-kv-val mono"><%= @running.session_id || "n/a" %></span>
              </div>
              <div class="detail-kv-row">
                <span class="detail-kv-key">Runtime</span>
                <span class="detail-kv-val numeric"><%= format_runtime_and_turns(@running.started_at, @running.turn_count, @now) %></span>
              </div>
              <div class="detail-kv-row">
                <span class="detail-kv-key">Last Event</span>
                <span class="detail-kv-val"><%= @running.last_message || to_string(@running.last_event || "n/a") %></span>
              </div>
            <% else %>
              <div class="detail-kv-row">
                <span class="detail-kv-key">Status</span>
                <span class="detail-kv-val text-dim">Not running</span>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Tokens --%>
        <div class="detail-section">
          <p class="detail-section-title">Tokens</p>
          <div class="detail-kv">
            <%= if @running do %>
              <div class="detail-kv-row">
                <span class="detail-kv-key">Total</span>
                <span class="detail-kv-val numeric"><%= format_int(@running.tokens.total_tokens) %></span>
              </div>
              <div class="detail-kv-row">
                <span class="detail-kv-key">Input</span>
                <span class="detail-kv-val numeric"><%= format_int(@running.tokens.input_tokens) %></span>
              </div>
              <div class="detail-kv-row">
                <span class="detail-kv-key">Output</span>
                <span class="detail-kv-val numeric"><%= format_int(@running.tokens.output_tokens) %></span>
              </div>
            <% else %>
              <div class="detail-kv-row">
                <span class="detail-kv-key">—</span>
                <span class="detail-kv-val text-dim">No active session</span>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Retry Info --%>
        <div class="detail-section">
          <p class="detail-section-title">Retries</p>
          <div class="detail-kv">
            <%= if @retry do %>
              <div class="detail-kv-row">
                <span class="detail-kv-key">Attempt</span>
                <span class="detail-kv-val numeric"><%= @retry.attempt %></span>
              </div>
              <div class="detail-kv-row">
                <span class="detail-kv-key">Due At</span>
                <span class="detail-kv-val mono"><%= @retry.due_at || "n/a" %></span>
              </div>
              <div class="detail-kv-row">
                <span class="detail-kv-key">Error</span>
                <span class="detail-kv-val"><%= @retry.error || "n/a" %></span>
              </div>
            <% else %>
              <div class="detail-kv-row">
                <span class="detail-kv-key">—</span>
                <span class="detail-kv-val text-dim">No pending retries</span>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Orchestration / Phase --%>
        <div class="detail-section">
          <p class="detail-section-title">Orchestration</p>
          <div class="detail-kv">
            <%= if @tracked do %>
              <div class="detail-kv-row">
                <span class="detail-kv-key">Phase</span>
                <span class="detail-kv-val">
                  <span class={phase_badge_class(@tracked.phase)}><%= @tracked.phase || "unknown" %></span>
                </span>
              </div>
              <div class="detail-kv-row">
                <span class="detail-kv-key">Waiting</span>
                <span class="detail-kv-val"><%= @tracked.waiting_reason || "—" %></span>
              </div>
              <div class="detail-kv-row">
                <span class="detail-kv-key">Next Action</span>
                <span class="detail-kv-val"><%= @tracked.next_intended_action || "—" %></span>
              </div>
              <div class="detail-kv-row">
                <span class="detail-kv-key">Dependencies</span>
                <span class="detail-kv-val">
                  <%= if ((@tracked.blocked_by || []) ++ (@tracked.blocks || [])) != [] do %>
                    ← <%= dep_identifiers(@tracked.blocked_by || []) %>
                    → <%= dep_identifiers(@tracked.blocks || []) %>
                  <% else %>
                    None
                  <% end %>
                </span>
              </div>
            <% else %>
              <div class="detail-kv-row">
                <span class="detail-kv-key">—</span>
                <span class="detail-kv-val text-dim">Not tracked</span>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Session Files / Proof --%>
        <div class="detail-section" style="grid-column: 1 / -1">
          <p class="detail-section-title">Session &amp; Proof</p>
          <div class="detail-kv">
            <%= if @running do %>
              <div :if={Map.get(@running, :session_file)} class="detail-kv-row">
                <span class="detail-kv-key">Session File</span>
                <span class="detail-kv-val mono" style="font-size: 0.6875rem"><%= basename(Map.get(@running, :session_file)) %></span>
              </div>
              <div :if={proof_summary_name(@running)} class="detail-kv-row">
                <span class="detail-kv-key">Proof</span>
                <span class="detail-kv-val mono" style="font-size: 0.6875rem"><%= proof_summary_name(@running) %></span>
              </div>
            <% end %>
            <div class="detail-kv-row">
              <span class="detail-kv-key">JSON Detail</span>
              <span class="detail-kv-val">
                <a href={"/api/v1/#{@identifier}"} style="font-size: 0.75rem">/api/v1/<%= @identifier %></a>
              </span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ─── Component: Rate Limits ────────────────────────

  defp rate_limits_display(assigns) do
    ~H"""
    <%= if @rate_limits do %>
      <div class="rate-limits-grid">
        <div :if={is_map(@rate_limits)} class="rate-limit-item">
          <p class="rate-limit-label">Limit ID</p>
          <p class="rate-limit-value"><%= rate_limit_id(@rate_limits) %></p>
        </div>
        <div :if={rate_limit_bucket(@rate_limits, "primary")} class="rate-limit-item">
          <p class="rate-limit-label">Primary</p>
          <p class="rate-limit-value"><%= format_rate_bucket(rate_limit_bucket(@rate_limits, "primary")) %></p>
          <p class="rate-limit-detail"><%= format_rate_reset(rate_limit_bucket(@rate_limits, "primary")) %></p>
        </div>
        <div :if={rate_limit_bucket(@rate_limits, "secondary")} class="rate-limit-item">
          <p class="rate-limit-label">Secondary</p>
          <p class="rate-limit-value"><%= format_rate_bucket(rate_limit_bucket(@rate_limits, "secondary")) %></p>
          <p class="rate-limit-detail"><%= format_rate_reset(rate_limit_bucket(@rate_limits, "secondary")) %></p>
        </div>
        <div :if={rate_limit_credits(@rate_limits)} class="rate-limit-item">
          <p class="rate-limit-label">Credits</p>
          <p class="rate-limit-value"><%= format_credits(rate_limit_credits(@rate_limits)) %></p>
        </div>
      </div>
    <% else %>
      <div class="empty-state">
        <div class="empty-state-icon">◇</div>
        Rate limit data unavailable
      </div>
    <% end %>
    """
  end

  # ─── Component: Merge Queue ────────────────────────

  defp merge_queue_section(assigns) do
    ~H"""
    <div class="section">
      <div class="section-head">
        <h2 class="section-title">
          Merge Queue
          <span class="count-badge"><%= length((@merge || %{}) |> Map.get(:queued, [])) %></span>
        </h2>
      </div>
      <%= if merge_in_progress?(@merge) do %>
        <div class="merge-status">
          <span class="merge-icon text-running">⇅</span>
          <span class="text-running" style="font-size: 0.8125rem; font-weight: 600">
            Merging <%= @merge.in_progress_issue_identifier %>
          </span>
        </div>
      <% end %>
      <%= if merge_queue_entries(@merge) != [] do %>
        <div class="table-wrap">
          <table class="data-table">
            <thead>
              <tr>
                <th>Issue</th>
                <th>PR</th>
                <th>Priority</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={entry <- merge_queue_entries(@merge)}>
                <td><span class="issue-id"><%= entry.issue_identifier || "unknown" %></span></td>
                <td class="mono"><%= if entry.pr_number, do: "##{entry.pr_number}", else: "n/a" %></td>
                <td>P<%= entry.priority || 5 %></td>
              </tr>
            </tbody>
          </table>
        </div>
      <% else %>
        <%= unless merge_in_progress?(@merge) do %>
          <div class="empty-state">
            <div class="empty-state-icon">⇅</div>
            No queued merges
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  # ─── Component: Dependency SVG ─────────────────────

  defp dependency_svg(assigns) do
    %{nodes: nodes, edges: edges, width: width, height: height} = assigns.graph

    assigns =
      assigns
      |> assign(:nodes, nodes)
      |> assign(:edges, edges)
      |> assign(:svg_width, width)
      |> assign(:svg_height, height)

    ~H"""
    <svg
      class="dep-graph"
      viewBox={"0 0 #{@svg_width} #{@svg_height}"}
      width={@svg_width}
      height={@svg_height}
    >
      <defs>
        <marker id="arrowhead" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
          <polygon points="0 0, 8 3, 0 6" class="dep-edge-arrow" />
        </marker>
      </defs>

      <%!-- Edges --%>
      <line
        :for={edge <- @edges}
        x1={edge.x1}
        y1={edge.y1}
        x2={edge.x2}
        y2={edge.y2}
        class="dep-edge"
        marker-end="url(#arrowhead)"
      />

      <%!-- Nodes --%>
      <g
        :for={node <- @nodes}
        class={"dep-node #{dep_node_class(node.status)}"}
        phx-click="select_issue"
        phx-value-id={node.id}
        style="cursor: pointer"
      >
        <rect x={node.x} y={node.y} width={node.w} height={node.h} />
        <text x={node.x + node.w / 2} y={node.y + 20} text-anchor="middle">
          <%= node.id %>
        </text>
        <text
          x={node.x + node.w / 2}
          y={node.y + 34}
          text-anchor="middle"
          class="dep-node-phase"
        >
          <%= node.phase %>
        </text>
      </g>
    </svg>
    """
  end

  # ═══════════════════════════════════════════════════
  # Private helpers
  # ═══════════════════════════════════════════════════

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  # ─── Formatting Helpers ────────────────────────────

  defp worker_totals(payload) do
    payload[:worker_totals] ||
      %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
  end

  defp completed_runtime_seconds(payload) do
    worker_totals(payload).seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole = max(trunc(seconds), 0)
    mins = div(whole, 60)
    secs = rem(whole, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now),
    do: DateTime.diff(now, started_at, :second)

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp basename(path) when is_binary(path), do: Path.basename(path)
  defp basename(_path), do: nil

  defp proof_summary_name(entry) when is_map(entry) do
    entry
    |> Map.get(:proof)
    |> case do
      %{} = proof -> basename(proof[:summary_path] || proof["summary_path"])
      _ -> nil
    end
  end

  defp proof_summary_name(_entry), do: nil

  # ─── Badge Helpers ─────────────────────────────────

  defp state_badge_class(state) do
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "badge badge-running"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "badge badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "badge badge-retrying"
      String.contains?(normalized, ["review", "merge"]) -> "badge badge-merged"
      true -> "badge badge-neutral"
    end
  end

  defp phase_badge_class(phase) do
    normalized = phase |> to_string() |> String.downcase()

    cond do
      normalized in ["blocked"] -> "badge badge-danger"
      normalized in ["rework"] -> "badge badge-retrying"
      String.contains?(normalized, ["waiting", "ready_to_merge"]) -> "badge badge-info"
      normalized in ["implementing", "reviewing"] -> "badge badge-running"
      normalized in ["merging"] -> "badge badge-merged"
      true -> "badge badge-neutral"
    end
  end

  defp agent_dot_class(state) do
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "agent-dot-running"
      String.contains?(normalized, ["retry", "backoff"]) -> "agent-dot-retrying"
      String.contains?(normalized, ["error", "failed"]) -> "agent-dot-error"
      true -> "agent-dot-idle"
    end
  end

  defp issue_status_badge(running, _retry, _tracked) when not is_nil(running), do: "badge badge-running"
  defp issue_status_badge(_running, retry, _tracked) when not is_nil(retry), do: "badge badge-retrying"
  defp issue_status_badge(_running, _retry, _tracked), do: "badge badge-neutral"

  defp issue_status_label(running, _retry, _tracked) when not is_nil(running), do: "Running"
  defp issue_status_label(_running, retry, _tracked) when not is_nil(retry), do: "Retrying"
  defp issue_status_label(_running, _retry, tracked) when not is_nil(tracked), do: "Tracked"
  defp issue_status_label(_running, _retry, _tracked), do: "Unknown"

  # ─── Dependency Helpers ────────────────────────────

  defp dep_identifiers(relations) when is_list(relations) do
    Enum.map_join(relations, ", ", fn
      %{identifier: id} when is_binary(id) -> id
      _ -> "?"
    end)
  end

  defp dep_identifiers(_), do: ""

  defp waiting_duration(entry) do
    case parse_iso(entry[:waiting_since]) do
      {:ok, since} ->
        seconds = DateTime.diff(DateTime.utc_now(), since, :second)
        format_wait_duration(seconds)

      _ ->
        nil
    end
  end

  defp parse_iso(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> nil
    end
  end

  defp parse_iso(_), do: nil

  defp format_wait_duration(seconds) when is_integer(seconds) and seconds >= 0 do
    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m"
      seconds < 86_400 -> "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"
      true -> "#{div(seconds, 86_400)}d #{div(rem(seconds, 86_400), 3600)}h"
    end
  end

  defp format_wait_duration(_), do: nil

  # ─── Rate Limit Helpers ────────────────────────────

  defp rate_limit_id(rate_limits) when is_map(rate_limits) do
    Map.get(rate_limits, :limit_id) || Map.get(rate_limits, "limit_id") || "unknown"
  end

  defp rate_limit_bucket(rate_limits, key) when is_map(rate_limits) do
    Map.get(rate_limits, String.to_existing_atom(key)) || Map.get(rate_limits, key)
  rescue
    ArgumentError -> Map.get(rate_limits, key)
  end

  defp rate_limit_bucket(_, _), do: nil

  defp rate_limit_credits(rate_limits) when is_map(rate_limits) do
    Map.get(rate_limits, :credits) || Map.get(rate_limits, "credits")
  end

  defp rate_limit_credits(_), do: nil

  defp format_rate_bucket(nil), do: "n/a"

  defp format_rate_bucket(bucket) when is_map(bucket) do
    remaining = Map.get(bucket, :remaining) || Map.get(bucket, "remaining")
    limit = Map.get(bucket, :limit) || Map.get(bucket, "limit")

    if is_integer(remaining) and is_integer(limit) do
      "#{format_int(remaining)} / #{format_int(limit)}"
    else
      "n/a"
    end
  end

  defp format_rate_bucket(_), do: "n/a"

  defp format_rate_reset(bucket) when is_map(bucket) do
    reset =
      Map.get(bucket, :reset_in_seconds) || Map.get(bucket, "reset_in_seconds") ||
        Map.get(bucket, :resetInSeconds) || Map.get(bucket, "resetInSeconds")

    if is_integer(reset), do: "Resets in #{reset}s", else: ""
  end

  defp format_rate_reset(_), do: ""

  defp format_credits(nil), do: "n/a"

  defp format_credits(credits) when is_map(credits) do
    unlimited = Map.get(credits, :unlimited) || Map.get(credits, "unlimited")
    has_credits = Map.get(credits, :has_credits) || Map.get(credits, "has_credits")
    balance = Map.get(credits, :balance) || Map.get(credits, "balance")

    cond do
      unlimited == true -> "Unlimited"
      has_credits == true and is_number(balance) -> "#{Float.round(balance * 1.0, 2)}"
      has_credits == true -> "Available"
      true -> "None"
    end
  end

  defp format_credits(_), do: "n/a"

  # ─── Merge Queue Helpers ───────────────────────────

  defp merge_in_progress?(%{in_progress_issue_identifier: id}) when is_binary(id) and id != "", do: true
  defp merge_in_progress?(_), do: false

  defp merge_queue_entries(%{queued: queued}) when is_list(queued), do: queued
  defp merge_queue_entries(_), do: []

  # ─── Dependency Graph Builder ──────────────────────

  @node_w 120
  @node_h 44
  @node_pad_x 30
  @node_pad_y 50
  @graph_pad 20

  defp build_dependency_graph([]), do: %{nodes: [], edges: [], width: 0, height: 0}

  defp build_dependency_graph(tracked) do
    id_set = MapSet.new(tracked, & &1.issue_identifier)
    layers = assign_layers(tracked, id_set)
    max_layer = layers |> Map.values() |> Enum.max(fn -> 0 end)
    by_layer = group_by_layer(layers, max_layer)
    max_per_layer = by_layer |> Map.values() |> Enum.map(&length/1) |> Enum.max(fn -> 1 end)
    entry_map = Map.new(tracked, &{&1.issue_identifier, &1})

    nodes = position_graph_nodes(by_layer, max_layer, max_per_layer, entry_map)
    node_map = Map.new(nodes, &{&1.id, &1})
    edges = build_graph_edges(tracked, node_map, id_set)

    width = max_per_layer * (@node_w + @node_pad_x) + @graph_pad * 2
    height = (max_layer + 1) * (@node_h + @node_pad_y) + @graph_pad * 2

    %{nodes: nodes, edges: edges, width: max(width, 200), height: max(height, 100)}
  end

  defp group_by_layer(layers, max_layer) do
    Enum.reduce(0..max_layer, %{}, fn layer, acc ->
      ids = for {id, l} <- layers, l == layer, do: id
      Map.put(acc, layer, Enum.sort(ids))
    end)
  end

  defp position_graph_nodes(by_layer, max_layer, max_per_layer, entry_map) do
    Enum.flat_map(0..max_layer, fn layer ->
      ids = Map.get(by_layer, layer, [])
      count = length(ids)
      offset = div((max_per_layer - count) * (@node_w + @node_pad_x), 2)

      ids
      |> Enum.with_index()
      |> Enum.map(fn {id, idx} ->
        entry = Map.get(entry_map, id)
        graph_node(id, entry, idx, layer, offset)
      end)
    end)
  end

  defp graph_node(id, entry, idx, layer, offset) do
    %{
      id: id,
      x: @graph_pad + idx * (@node_w + @node_pad_x) + offset,
      y: @graph_pad + layer * (@node_h + @node_pad_y),
      w: @node_w,
      h: @node_h,
      phase: (entry && entry.phase) || "unknown",
      status: dep_node_status(entry)
    }
  end

  defp build_graph_edges(tracked, node_map, id_set) do
    Enum.flat_map(tracked, fn entry ->
      target = Map.get(node_map, entry.issue_identifier)
      dep_ids = extract_dep_ids(entry.blocked_by, id_set)
      build_edges_for_target(dep_ids, target, node_map)
    end)
  end

  defp extract_dep_ids(nil, _id_set), do: []

  defp extract_dep_ids(blocked_by, id_set) do
    blocked_by
    |> Enum.map(fn
      %{identifier: id} when is_binary(id) -> id
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&MapSet.member?(id_set, &1))
  end

  defp build_edges_for_target(_dep_ids, nil, _node_map), do: []

  defp build_edges_for_target(dep_ids, target, node_map) do
    dep_ids
    |> Enum.map(&edge_from_source(Map.get(node_map, &1), target))
    |> Enum.reject(&is_nil/1)
  end

  defp edge_from_source(nil, _target), do: nil

  defp edge_from_source(source, target) do
    %{
      x1: source.x + div(source.w, 2),
      y1: source.y + source.h,
      x2: target.x + div(target.w, 2),
      y2: target.y
    }
  end

  defp assign_layers(tracked, id_set) do
    deps = build_dependency_map(tracked, id_set)

    Enum.reduce(id_set, %{}, fn id, layers ->
      compute_layer(id, deps, layers, %{})
    end)
  end

  defp build_dependency_map(tracked, id_set) do
    Map.new(tracked, fn entry ->
      {entry.issue_identifier, extract_dep_ids(entry.blocked_by, id_set)}
    end)
  end

  defp compute_layer(id, deps, layers, visiting) do
    cond do
      Map.has_key?(layers, id) ->
        layers

      Map.has_key?(visiting, id) ->
        Map.put(layers, id, 0)

      true ->
        compute_layer_from_deps(id, deps, layers, visiting)
    end
  end

  defp compute_layer_from_deps(id, deps, layers, visiting) do
    visiting = Map.put(visiting, id, true)
    dep_ids = Map.get(deps, id, [])

    layers =
      Enum.reduce(dep_ids, layers, fn dep_id, acc ->
        compute_layer(dep_id, deps, acc, visiting)
      end)

    max_dep_layer =
      dep_ids
      |> Enum.map(&Map.get(layers, &1, 0))
      |> Enum.max(fn -> -1 end)

    Map.put(layers, id, max_dep_layer + 1)
  end

  defp dep_node_status(nil), do: "idle"

  defp dep_node_status(entry) do
    phase = (entry.phase || "") |> to_string() |> String.downcase()
    state = (entry.state || "") |> to_string() |> String.downcase()

    cond do
      phase == "blocked" -> "blocked"
      String.contains?(state, "done") -> "done"
      String.contains?(phase, "waiting") -> "waiting"
      String.contains?(state, ["progress", "running"]) -> "running"
      true -> "idle"
    end
  end

  defp dep_node_class("running"), do: "dep-node-running"
  defp dep_node_class("blocked"), do: "dep-node-blocked"
  defp dep_node_class("retrying"), do: "dep-node-retrying"
  defp dep_node_class("waiting"), do: "dep-node-waiting"
  defp dep_node_class("done"), do: "dep-node-done"
  defp dep_node_class(_), do: "dep-node-idle"

  # ─── Event Stream Builder ─────────────────────────

  defp build_event_stream(payload, now) do
    running_events =
      payload.running
      |> Enum.map(fn entry ->
        %{
          time: format_event_time(entry.last_event_at, now),
          issue: entry.issue_identifier,
          type: to_string(entry.last_event || "unknown"),
          message: entry.last_message || "—",
          sort_key: entry.last_event_at
        }
      end)
      |> Enum.reject(&is_nil(&1.sort_key))

    retry_events =
      payload.retrying
      |> Enum.map(fn entry ->
        %{
          time: entry.due_at || "—",
          issue: entry.issue_identifier,
          type: "retry_queued",
          message: "Attempt #{entry.attempt}: #{entry.error || "scheduled"}",
          sort_key: entry.due_at
        }
      end)

    (running_events ++ retry_events)
    |> Enum.sort_by(& &1.sort_key, :desc)
  end

  defp format_event_time(nil, _now), do: "—"

  defp format_event_time(iso_string, _now) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} ->
        dt
        |> DateTime.truncate(:second)
        |> Calendar.strftime("%H:%M:%S")

      _ ->
        iso_string
    end
  end

  defp format_event_time(_, _), do: "—"
end
