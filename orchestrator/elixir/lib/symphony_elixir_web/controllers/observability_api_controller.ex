defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.{Config, Orchestrator, Workspace}
  alias SymphonyElixir.Observability.{ArtifactReader, EventStore, PhaseTransition, PrStatus, RunSnapshot, WorkspaceStatus}
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec events(Conn.t(), map()) :: Conn.t()
  def events(conn, params) do
    opts = event_query_opts(params)
    page = EventStore.list(opts)

    json(conn, %{
      events: page.events,
      page_info: page.page_info
    })
  end

  @spec runs(Conn.t(), map()) :: Conn.t()
  def runs(conn, params) do
    json(conn, RunSnapshot.list_payload(orchestrator(), snapshot_timeout_ms(), params))
  end

  @spec run(Conn.t(), map()) :: Conn.t()
  def run(conn, %{"issue_identifier" => issue_identifier}) do
    case RunSnapshot.detail_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} -> json(conn, payload)
      {:error, reason} -> run_lookup_error(conn, reason)
    end
  end

  @spec run_workspace(Conn.t(), map()) :: Conn.t()
  def run_workspace(conn, %{"issue_identifier" => issue_identifier}) do
    with {:ok, run} <- lookup_run(issue_identifier) do
      json(conn, WorkspaceStatus.payload(run))
    else
      {:error, reason} -> run_lookup_error(conn, reason)
    end
  end

  @spec run_pr(Conn.t(), map()) :: Conn.t()
  def run_pr(conn, %{"issue_identifier" => issue_identifier} = params) do
    refresh? = Map.get(params, "refresh") in ["true", true]

    with {:ok, run} <- lookup_run(issue_identifier) do
      if refresh? do
        case PrStatus.live_payload(run) do
          {:ok, payload} -> json(conn, payload)
          {:skip, reason} -> pr_refresh_skip(conn, reason)
          {:error, reason} -> pr_refresh_error(conn, reason)
        end
      else
        json(conn, PrStatus.cached_payload(run))
      end
    else
      {:error, reason} -> run_lookup_error(conn, reason)
    end
  end

  @spec run_logs(Conn.t(), map()) :: Conn.t()
  def run_logs(conn, %{"issue_identifier" => issue_identifier} = params) do
    with {:ok, run} <- lookup_run(issue_identifier),
         {:ok, payload} <- ArtifactReader.read(run, params) do
      json(conn, payload)
    else
      {:error, reason} -> artifact_or_run_error(conn, reason)
    end
  end

  @spec run_events(Conn.t(), map()) :: Conn.t()
  def run_events(conn, %{"issue_identifier" => issue_identifier} = params) do
    opts = event_query_opts(params)
    page = EventStore.list_for_issue(issue_identifier, opts)

    json(conn, %{
      issue_identifier: issue_identifier,
      events: page.events,
      page_info: page.page_info
    })
  end

  @spec run_transitions(Conn.t(), map()) :: Conn.t()
  def run_transitions(conn, %{"issue_identifier" => issue_identifier} = params) do
    opts =
      params
      |> event_query_opts()
      |> Keyword.put(:type, "phase")

    page = EventStore.list_for_issue(issue_identifier, opts)

    json(conn, %{
      issue_identifier: issue_identifier,
      transitions: Enum.map(page.events, &PhaseTransition.transition_payload/1),
      page_info: page.page_info
    })
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

  @spec transcript(Conn.t(), map()) :: Conn.t()
  def transcript(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.transcript_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")

      {:error, :no_session_file} ->
        error_response(conn, 404, "no_session_file", "No session file available for this issue")

      {:error, :snapshot_timeout} ->
        error_response(conn, 503, "snapshot_timeout", "Snapshot timed out")

      {:error, :snapshot_unavailable} ->
        error_response(conn, 503, "snapshot_unavailable", "Snapshot unavailable")

      {:error, :unsafe_path} ->
        error_response(conn, 403, "unsafe_path", "Artifact path is outside allowed roots")

      {:error, :not_regular_file} ->
        error_response(conn, 400, "not_regular_file", "Artifact path is not a regular file")

      {:error, :read_failed} ->
        error_response(conn, 404, "read_failed", "Artifact could not be read")
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

  @spec workspaces(Conn.t(), map()) :: Conn.t()
  def workspaces(conn, _params) do
    case build_workspace_listing() do
      {:ok, entries, stale_count} ->
        json(conn, %{workspaces: entries, total: length(entries), stale_count: stale_count})

      {:error, reason} ->
        error_response(conn, 500, "workspace_list_failed", inspect(reason))
    end
  end

  defp build_workspace_listing do
    with {:ok, active_identifiers} <- fetch_active_identifiers(),
         {:ok, stale} <- Workspace.stale_workspaces(active_identifiers),
         {:ok, all} <- Workspace.list_workspaces() do
      stale_set = stale |> Enum.map(& &1.identifier) |> MapSet.new()

      entries =
        Enum.map(all, fn entry ->
          stale_entry = Enum.find(stale, &(&1.identifier == entry.identifier))

          %{
            identifier: entry.identifier,
            path: entry.path,
            stale: MapSet.member?(stale_set, entry.identifier),
            age_hours: if(stale_entry, do: Float.round(stale_entry.age_hours, 1), else: nil)
          }
        end)

      {:ok, entries, length(stale)}
    end
  end

  @spec workspaces_cleanup(Conn.t(), map()) :: Conn.t()
  def workspaces_cleanup(conn, params) do
    dry_run = Map.get(params, "dry_run", false)
    retention_hours = parse_retention_hours(params)

    with {:ok, active_identifiers} <- fetch_active_identifiers(),
         {:ok, stale} <- Workspace.stale_workspaces(active_identifiers) do
      {to_remove, to_retain} = partition_by_retention(stale, retention_hours)

      if dry_run do
        json(conn, %{
          dry_run: true,
          would_remove: Enum.map(to_remove, &format_workspace_entry/1),
          would_retain: Enum.map(to_retain, &format_workspace_entry/1)
        })
      else
        Enum.each(to_remove, &Workspace.remove(&1.path, nil))

        conn
        |> put_status(200)
        |> json(%{
          removed: Enum.map(to_remove, &format_workspace_entry/1),
          retained: Enum.map(to_retain, &format_workspace_entry/1)
        })
      end
    else
      {:error, reason} ->
        error_response(conn, 503, "cleanup_failed", "Workspace cleanup could not determine active workspaces: #{inspect(reason)}")
    end
  end

  defp fetch_active_identifiers do
    case Orchestrator.snapshot(orchestrator(), snapshot_timeout_ms()) do
      %{} = snapshot ->
        identifiers =
          []
          |> Kernel.++(snapshot |> Map.get(:running, []) |> Enum.map(&field_value(&1, :identifier)))
          |> Kernel.++(snapshot |> Map.get(:retrying, []) |> Enum.map(&field_value(&1, :identifier)))
          |> Kernel.++(snapshot |> Map.get(:tracked, []) |> Enum.map(&field_value(&1, :issue_identifier)))
          |> Enum.filter(&is_binary/1)
          |> Enum.map(&String.replace(&1, ~r/[^a-zA-Z0-9._-]/, "_"))
          |> Enum.uniq()

        {:ok, identifiers}

      :timeout ->
        {:error, :snapshot_timeout}

      :unavailable ->
        {:error, :snapshot_unavailable}
    end
  end

  defp field_value(map, key) when is_map(map) and is_atom(key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp field_value(_map, _key), do: nil

  defp parse_retention_hours(%{"retention_hours" => hours}) when is_number(hours) and hours > 0, do: hours

  defp parse_retention_hours(%{"retention_hours" => hours}) when is_binary(hours) do
    case Float.parse(hours) do
      {value, _rest} when value > 0 -> value
      _ -> Config.settings!().workspace.retention_hours
    end
  end

  defp parse_retention_hours(_params), do: Config.settings!().workspace.retention_hours

  defp partition_by_retention(stale, nil), do: {stale, []}
  defp partition_by_retention(stale, hours) when is_number(hours) and hours <= 0, do: {stale, []}

  defp partition_by_retention(stale, hours) when is_number(hours) do
    Enum.split_with(stale, fn entry -> entry.age_hours >= hours end)
  end

  defp format_workspace_entry(entry) do
    %{
      identifier: entry.identifier,
      path: entry.path,
      age_hours: Float.round(entry.age_hours, 1)
    }
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp lookup_run(issue_identifier) do
    RunSnapshot.lookup_run(issue_identifier, orchestrator(), snapshot_timeout_ms())
  end

  defp artifact_or_run_error(conn, :issue_not_found), do: run_lookup_error(conn, :issue_not_found)
  defp artifact_or_run_error(conn, :snapshot_timeout), do: run_lookup_error(conn, :snapshot_timeout)
  defp artifact_or_run_error(conn, :snapshot_unavailable), do: run_lookup_error(conn, :snapshot_unavailable)
  defp artifact_or_run_error(conn, :invalid_kind), do: error_response(conn, 400, "invalid_kind", "Invalid log kind")
  defp artifact_or_run_error(conn, :no_artifact_path), do: error_response(conn, 404, "no_artifact_path", "No artifact path is available for this run/kind")
  defp artifact_or_run_error(conn, :unsafe_path), do: error_response(conn, 403, "unsafe_path", "Artifact path is outside allowed roots")
  defp artifact_or_run_error(conn, :not_regular_file), do: error_response(conn, 400, "not_regular_file", "Artifact path is not a regular file")
  defp artifact_or_run_error(conn, :read_failed), do: error_response(conn, 404, "read_failed", "Artifact could not be read")

  defp run_lookup_error(conn, :issue_not_found), do: error_response(conn, 404, "issue_not_found", "Issue not found")
  defp run_lookup_error(conn, :snapshot_timeout), do: error_response(conn, 503, "snapshot_timeout", "Snapshot timed out")
  defp run_lookup_error(conn, :snapshot_unavailable), do: error_response(conn, 503, "snapshot_unavailable", "Snapshot unavailable")

  defp pr_refresh_skip(conn, reason) do
    error_response(conn, 422, "pr_refresh_skipped", "Live PR refresh skipped: #{inspect(reason)}")
  end

  defp pr_refresh_error(conn, :timeout), do: error_response(conn, 504, "pr_refresh_timeout", "Live PR refresh timed out")
  defp pr_refresh_error(conn, reason), do: error_response(conn, 502, "pr_refresh_failed", pr_refresh_error_message(reason))

  defp pr_refresh_error_message({status, _output}) when is_integer(status),
    do: "Live PR refresh failed: gh exited with status #{status}"

  defp pr_refresh_error_message({command, :enoent}) when is_binary(command),
    do: "Live PR refresh failed: command not found: #{command}"

  defp pr_refresh_error_message(%Jason.DecodeError{}),
    do: "Live PR refresh failed: invalid GitHub response JSON"

  defp pr_refresh_error_message(reason) do
    reason
    |> inspect(limit: 5, printable_limit: 240)
    |> String.slice(0, 240)
    |> then(&"Live PR refresh failed: #{&1}")
  end

  defp event_query_opts(params) do
    [
      cursor: Map.get(params, "cursor"),
      limit: Map.get(params, "limit"),
      type: Map.get(params, "type"),
      direction: Map.get(params, "direction", "forward")
    ]
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
