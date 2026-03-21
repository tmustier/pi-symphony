defmodule Mix.Tasks.Workspace.Cleanup do
  use Mix.Task

  @shortdoc "Remove stale workspace directories not associated with active issues"

  @moduledoc """
  Removes workspace directories that are not associated with any active Linear issue.

  ## Usage

      mix workspace.cleanup
      mix workspace.cleanup --dry-run
      mix workspace.cleanup --retention-hours 24
      mix workspace.cleanup --all

  ## Options

    * `--dry-run` — list stale workspaces without removing them
    * `--retention-hours <hours>` — only remove workspaces older than the given threshold
    * `--all` — remove all workspace directories regardless of issue status
    * `--json` — output results as JSON for machine consumption

  ## Output format (JSON)

      {
        "removed": [{"identifier": "SYM-10", "path": "/...", "age_hours": 48.2}],
        "retained": [{"identifier": "SYM-11", "path": "/...", "age_hours": 2.1}],
        "errors": []
      }
  """

  alias SymphonyElixir.{Config, Tracker, Workspace}
  alias SymphonyElixir.Linear.Issue

  @switches [
    dry_run: :boolean,
    retention_hours: :float,
    all: :boolean,
    json: :boolean,
    help: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches, aliases: [h: :help])

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      true ->
        {:ok, _apps} = Application.ensure_all_started(:symphony_elixir)
        execute(opts)
    end
  end

  defp execute(opts) do
    json? = Keyword.get(opts, :json, false)
    dry_run? = Keyword.get(opts, :dry_run, false)
    all? = Keyword.get(opts, :all, false)
    retention_hours = Keyword.get(opts, :retention_hours) || Config.settings!().workspace.retention_hours

    active_identifiers =
      if all? do
        MapSet.new()
      else
        fetch_active_identifiers()
      end

    case Workspace.stale_workspaces(active_identifiers) do
      {:ok, stale} ->
        {to_remove, to_retain} = partition_by_retention(stale, retention_hours)

        if dry_run? do
          output_dry_run(to_remove, to_retain, json?)
        else
          removed = remove_workspaces(to_remove)
          output_result(removed, to_retain, json?)
        end

      {:error, reason} ->
        output_error(reason, json?)
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
        |> MapSet.new()

      {:error, _reason} ->
        MapSet.new()
    end
  end

  defp partition_by_retention(stale, nil), do: {stale, []}
  defp partition_by_retention(stale, hours) when is_number(hours) and hours <= 0, do: {stale, []}

  defp partition_by_retention(stale, hours) when is_number(hours) do
    Enum.split_with(stale, fn entry -> entry.age_hours >= hours end)
  end

  defp remove_workspaces(workspaces) do
    Enum.map(workspaces, fn entry ->
      case Workspace.remove(entry.path) do
        {:ok, _files} ->
          entry

        {:error, reason, _output} ->
          Mix.shell().error("Failed to remove #{entry.path}: #{inspect(reason)}")
          entry
      end
    end)
  end

  defp output_dry_run(to_remove, to_retain, true) do
    payload = %{
      dry_run: true,
      would_remove: Enum.map(to_remove, &workspace_entry/1),
      would_retain: Enum.map(to_retain, &workspace_entry/1),
      errors: []
    }

    Mix.shell().info(Jason.encode!(payload, pretty: true))
  end

  defp output_dry_run(to_remove, to_retain, false) do
    if to_remove == [] do
      Mix.shell().info("No stale workspaces to clean up.")
    else
      Mix.shell().info("Would remove #{length(to_remove)} workspace(s):")

      Enum.each(to_remove, fn entry ->
        Mix.shell().info("  #{entry.identifier} (#{Float.round(entry.age_hours, 1)}h old) — #{entry.path}")
      end)
    end

    if to_retain != [] do
      Mix.shell().info("\nRetaining #{length(to_retain)} workspace(s) below retention threshold.")
    end
  end

  defp output_result(removed, retained, true) do
    payload = %{
      removed: Enum.map(removed, &workspace_entry/1),
      retained: Enum.map(retained, &workspace_entry/1),
      errors: []
    }

    Mix.shell().info(Jason.encode!(payload, pretty: true))
  end

  defp output_result(removed, retained, false) do
    if removed == [] do
      Mix.shell().info("No stale workspaces removed.")
    else
      Mix.shell().info("Removed #{length(removed)} workspace(s):")

      Enum.each(removed, fn entry ->
        Mix.shell().info("  #{entry.identifier} (#{Float.round(entry.age_hours, 1)}h old)")
      end)
    end

    if retained != [] do
      Mix.shell().info("Retained #{length(retained)} workspace(s) below retention threshold.")
    end
  end

  defp output_error(reason, true) do
    payload = %{
      removed: [],
      retained: [],
      errors: [%{code: "cleanup_failed", message: inspect(reason), retryable: true}]
    }

    Mix.shell().info(Jason.encode!(payload, pretty: true))
  end

  defp output_error(reason, false) do
    Mix.shell().error("Workspace cleanup failed: #{inspect(reason)}")
  end

  defp workspace_entry(entry) do
    %{
      identifier: entry.identifier,
      path: entry.path,
      age_hours: Float.round(entry.age_hours, 1)
    }
  end
end
