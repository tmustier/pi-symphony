defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.{Config, Tracker, Workspace}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
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
    active_identifiers = fetch_active_identifiers()

    with {:ok, stale} <- Workspace.stale_workspaces(active_identifiers),
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
    active_identifiers = fetch_active_identifiers()

    case Workspace.stale_workspaces(active_identifiers) do
      {:ok, stale} ->
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

      {:error, reason} ->
        error_response(conn, 500, "cleanup_failed", inspect(reason))
    end
  end

  defp fetch_active_identifiers do
    case Tracker.fetch_candidate_issues() do
      {:ok, issues} ->
        issues
        |> Enum.flat_map(fn
          %Issue{identifier: id} when is_binary(id) ->
            [String.replace(id, ~r/[^a-zA-Z0-9._-]/, "_")]

          _ ->
            []
        end)
        |> Enum.uniq()

      {:error, _reason} ->
        []
    end
  end

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
