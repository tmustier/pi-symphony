defmodule SymphonyElixir.PiAnalytics do
  @moduledoc """
  Local-first append-only analytics ledger for Symphony worker attempts.

  Each emitted `symphony_run` record is always written to a logs-root-local
  JSONL extract when analytics are enabled. The same record can also be mirrored
  to a home-scoped ledger for cross-project aggregation.
  """

  require Logger

  alias SymphonyElixir.{Config, LogFile, Workflow}

  @schema_version "pi-analytics/v1"
  @enabled_env "PI_ANALYTICS_ENABLED"
  @home_mirror_env "PI_ANALYTICS_MIRROR_HOME"
  @local_dir_env "PI_ANALYTICS_LOCAL_DIR"
  @home_root_env "PI_ANALYTICS_LEDGER_ROOT"

  @type record_status :: String.t()

  @spec emit_symphony_run(map(), keyword()) :: :ok
  def emit_symphony_run(running_entry, opts \\ []) when is_map(running_entry) and is_list(opts) do
    if enabled?() do
      now = Keyword.get(opts, :now, DateTime.utc_now() |> DateTime.truncate(:second))
      record = build_record(running_entry, opts, now)
      local_path = local_events_path(now)

      write_record(local_path, record, :local)
      maybe_mirror_to_home(local_path, record, now)
    end

    :ok
  end

  defp maybe_mirror_to_home(local_path, record, now) do
    if home_mirror_enabled?() do
      home_path = home_events_path(now)

      if Path.expand(home_path) != Path.expand(local_path) do
        write_record(home_path, record, :home)
      end
    end
  end

  @spec enabled?() :: boolean()
  def enabled? do
    System.get_env(@enabled_env, "1") != "0"
  end

  @spec home_mirror_enabled?() :: boolean()
  def home_mirror_enabled? do
    System.get_env(@home_mirror_env, "1") != "0"
  end

  @spec local_directory() :: Path.t()
  def local_directory do
    case System.get_env(@local_dir_env) do
      value when is_binary(value) and value != "" -> Path.expand(value)
      _ -> Path.join(logs_root(), "pi-analytics")
    end
  end

  @spec home_ledger_root() :: Path.t()
  def home_ledger_root do
    case System.get_env(@home_root_env) do
      value when is_binary(value) and value != "" -> Path.expand(value)
      _ -> Path.join(System.user_home!(), ".pi/analytics")
    end
  end

  defp build_record(running_entry, opts, now) do
    settings = Config.settings!()
    issue = Map.get(running_entry, :issue, %{})
    workflow_path = Workflow.workflow_file_path() |> Path.expand()
    repo_root = Path.dirname(workflow_path)
    workspace_path = workspace_path(running_entry, issue, settings)
    role = Keyword.get(opts, :role, "worker")
    status = Keyword.get(opts, :status, "success")
    note = Keyword.get(opts, :notes)
    extra_metrics = Keyword.get(opts, :metrics, %{})
    started_at = started_at(running_entry, now)
    issue_identifier = issue_identifier(issue, running_entry)
    pi_model = settings.pi.model

    %{
      "schema_version" => @schema_version,
      "record_type" => "symphony_run",
      "run_id" => run_id(issue_identifier, role),
      "emitted_at" => iso8601(now),
      "started_at" => iso8601(started_at),
      "ended_at" => iso8601(now),
      "repo_root" => repo_root,
      "cwd" => workspace_path,
      "workspace_path" => workspace_path,
      "issue_key" => issue_identifier,
      "role" => role,
      "phase" => orchestration_phase(running_entry, issue, settings),
      "status" => status,
      "team_key" => present_string(settings.tracker.team_key),
      "linear_project" => present_string(settings.tracker.project_slug),
      "workflow_path" => workflow_path,
      "workflow_hash" => sha256_file(workflow_path),
      "branch" => present_string(Map.get(issue, :branch_name)),
      "artifacts_root" => present_string(Map.get(running_entry, :proof_dir)),
      "session_id" => present_string(Map.get(running_entry, :session_id)),
      "session_path" => present_string(Map.get(running_entry, :session_file)),
      "provider" => model_provider(pi_model),
      "model" => model_name(pi_model),
      "thinking_level" => present_string(settings.pi.thinking_level),
      "cost_method" => "unknown",
      "notes" => present_string(note),
      "host" => hostname(),
      "user" => username(),
      "metrics" =>
        metrics(running_entry, issue, started_at, now)
        |> Map.merge(normalize_metrics(extra_metrics))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp metrics(running_entry, issue, started_at, now) do
    %{
      "worker_input_tokens" => integer_metric(Map.get(running_entry, :worker_input_tokens)),
      "worker_output_tokens" => integer_metric(Map.get(running_entry, :worker_output_tokens)),
      "worker_total_tokens" => integer_metric(Map.get(running_entry, :worker_total_tokens)),
      "turn_count" => integer_metric(Map.get(running_entry, :turn_count)),
      "retry_attempt" => integer_metric(Map.get(running_entry, :retry_attempt)),
      "runtime_seconds" => max(0, DateTime.diff(now, started_at, :second)),
      "worker_host" => worker_host_metric(Map.get(running_entry, :worker_host)),
      "issue_state" => present_string(Map.get(issue, :state)),
      "proof_events_path" => present_string(Map.get(running_entry, :proof_events_path)),
      "proof_summary_path" => present_string(Map.get(running_entry, :proof_summary_path))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp write_record(path, record, destination) do
    encoded = Jason.encode!(record)

    case File.mkdir_p(Path.dirname(path)) do
      :ok ->
        case File.write(path, encoded <> "\n", [:append]) do
          :ok -> :ok
          {:error, reason} -> log_write_failure(destination, path, reason)
        end

      {:error, reason} ->
        log_write_failure(destination, path, reason)
    end
  end

  defp log_write_failure(destination, path, reason) do
    Logger.warning("Pi analytics #{destination} append failed path=#{path} reason=#{inspect(reason)}")

    :ok
  end

  defp local_events_path(now) do
    Path.join(local_directory(), ledger_file_name(now))
  end

  defp home_events_path(now) do
    Path.join([home_ledger_root(), "events", ledger_file_name(now)])
  end

  defp ledger_file_name(now) do
    iso8601(now)
    |> String.split("T", parts: 2)
    |> List.first()
    |> Kernel.<>(".jsonl")
  end

  defp logs_root do
    log_file =
      Application.get_env(:symphony_elixir, :log_file, LogFile.default_log_file())
      |> Path.expand()

    log_dir = Path.dirname(log_file)

    if Path.basename(log_dir) == "log" do
      Path.dirname(log_dir)
    else
      log_dir
    end
  end

  defp issue_identifier(issue, running_entry) do
    present_string(Map.get(issue, :identifier)) ||
      present_string(Map.get(running_entry, :identifier)) ||
      "unknown-issue"
  end

  defp orchestration_phase(running_entry, issue, settings) do
    present_string(Map.get(running_entry, :orchestration_phase)) ||
      present_string(Map.get(issue, :state)) ||
      present_string(settings.orchestration.default_phase) ||
      "implementing"
  end

  defp started_at(running_entry, now) do
    case Map.get(running_entry, :started_at) do
      %DateTime{} = started_at -> started_at
      _ -> now
    end
  end

  defp workspace_path(running_entry, issue, settings) do
    present_string(Map.get(running_entry, :workspace_path)) ||
      Path.join(settings.workspace.root, safe_identifier(Map.get(issue, :identifier)))
  end

  defp safe_identifier(identifier) when is_binary(identifier) and identifier != "" do
    String.replace(identifier, ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp safe_identifier(_identifier), do: "unknown-issue"

  defp run_id(issue_identifier, role) do
    unique = System.unique_integer([:positive, :monotonic])
    "symphony_#{safe_identifier(issue_identifier)}_#{safe_identifier(role)}_#{unique}"
  end

  defp model_provider(%{provider: provider}) when is_binary(provider) and provider != "", do: provider
  defp model_provider(_model), do: nil

  defp model_name(%{provider: provider, model_id: model_id})
       when is_binary(provider) and provider != "" and is_binary(model_id) and model_id != "" do
    provider <> "/" <> model_id
  end

  defp model_name(%{model_id: model_id}) when is_binary(model_id) and model_id != "", do: model_id
  defp model_name(_model), do: nil

  defp sha256_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} -> "sha256:" <> Base.encode16(:crypto.hash(:sha256, contents), case: :lower)
      {:error, _reason} -> nil
    end
  end

  defp normalize_metrics(metrics) when is_map(metrics) do
    metrics
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      case scalar_metric(value) do
        nil -> acc
        scalar -> Map.put(acc, to_string(key), scalar)
      end
    end)
  end

  defp normalize_metrics(_metrics), do: %{}

  defp scalar_metric(value) when is_binary(value), do: value
  defp scalar_metric(value) when is_boolean(value), do: value
  defp scalar_metric(value) when is_integer(value), do: value
  defp scalar_metric(value) when is_float(value), do: value
  defp scalar_metric(nil), do: nil
  defp scalar_metric(value) when is_atom(value), do: Atom.to_string(value)
  defp scalar_metric(value), do: inspect(value)

  defp integer_metric(value) when is_integer(value), do: value
  defp integer_metric(_value), do: 0

  defp worker_host_metric(nil), do: "local"
  defp worker_host_metric(worker_host) when is_binary(worker_host) and worker_host != "", do: worker_host
  defp worker_host_metric(_worker_host), do: "local"

  defp present_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp present_string(_value), do: nil

  defp hostname do
    {:ok, name} = :inet.gethostname()
    to_string(name)
  end

  defp username do
    present_string(System.get_env("USER")) || present_string(System.get_env("LOGNAME"))
  end

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
