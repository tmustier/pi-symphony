defmodule SymphonyElixir.OrchestrationPolicy do
  @moduledoc """
  Runtime helpers for orchestration policy, workpad metadata parsing, and
  dispatch/continuation gating.
  """

  alias SymphonyElixir.Linear.Issue

  @phase_values [
    "implementing",
    "reviewing",
    "waiting_for_checks",
    "waiting_for_human",
    "rework",
    "blocked",
    "ready_to_merge",
    "merging"
  ]
  @passive_default_phases ["waiting_for_checks", "waiting_for_human", "blocked"]
  @rollout_modes ["observe", "mutate", "merge"]
  @review_output_formats ["structured_markdown_v1"]
  @review_comment_modes ["off", "create", "upsert"]
  @pr_closed_policies ["new_branch", "reopen", "stop"]
  @merge_modes ["disabled", "auto"]
  @merge_methods ["merge", "squash", "rebase"]
  @waiting_reason_values [
    "checks_pending",
    "human_approval_required",
    "metadata_recovery_required",
    "missing_context",
    "missing_auth",
    "tool_unavailable",
    "mergeability_changed",
    "rework_limit_exceeded",
    "kill_switch_active",
    "observe_only"
  ]
  @default_workpad_marker "## Symphony Workpad"

  @type runtime_map :: %{
          phase: String.t(),
          phase_source: String.t(),
          passive_phase: boolean(),
          rollout_mode: String.t() | nil,
          dispatch_allowed: boolean(),
          waiting_reason: String.t() | nil,
          next_intended_action: String.t(),
          ownership: map(),
          kill_switch: map(),
          workpad: map()
        }

  @spec phase_values() :: [String.t()]
  def phase_values, do: @phase_values

  @spec passive_default_phases() :: [String.t()]
  def passive_default_phases, do: @passive_default_phases

  @spec rollout_modes() :: [String.t()]
  def rollout_modes, do: @rollout_modes

  @spec review_output_formats() :: [String.t()]
  def review_output_formats, do: @review_output_formats

  @spec review_comment_modes() :: [String.t()]
  def review_comment_modes, do: @review_comment_modes

  @spec closed_pr_policies() :: [String.t()]
  def closed_pr_policies, do: @pr_closed_policies

  @spec merge_modes() :: [String.t()]
  def merge_modes, do: @merge_modes

  @spec merge_methods() :: [String.t()]
  def merge_methods, do: @merge_methods

  @spec waiting_reason_values() :: [String.t()]
  def waiting_reason_values, do: @waiting_reason_values

  @spec default_workpad_marker() :: String.t()
  def default_workpad_marker, do: @default_workpad_marker

  @spec issue_runtime(Issue.t(), map()) :: runtime_map()
  def issue_runtime(%Issue{} = issue, settings) when is_map(settings) do
    marker = configured_workpad_marker(settings)
    workpad = workpad_state(issue, marker, settings)
    ownership = ownership_state(issue, settings, workpad)
    kill_switch = kill_switch_state(issue, settings)
    passive_phase = workpad.phase in settings.orchestration.passive_phases
    base_dispatch_allowed = ownership.allowed and not kill_switch.active
    dispatch_allowed = base_dispatch_allowed and not passive_phase

    %{
      phase: workpad.phase,
      phase_source: workpad.phase_source,
      passive_phase: passive_phase,
      rollout_mode: settings.rollout.mode,
      dispatch_allowed: dispatch_allowed,
      waiting_reason:
        workpad.waiting_reason ||
          default_waiting_reason(passive_phase, settings.rollout.mode, ownership, kill_switch),
      next_intended_action:
        preferred_next_intended_action(
          workpad.observation,
          passive_phase,
          base_dispatch_allowed,
          dispatch_allowed,
          settings.rollout.mode,
          ownership,
          kill_switch
        ),
      ownership: ownership,
      kill_switch: kill_switch,
      workpad: workpad
    }
  end

  @spec continuation_allowed?(Issue.t(), map()) :: boolean()
  def continuation_allowed?(%Issue{} = issue, settings) when is_map(settings) do
    runtime = issue_runtime(issue, settings)
    runtime.dispatch_allowed and not runtime.passive_phase
  end

  @spec tracked_issue(Issue.t(), map()) :: map()
  def tracked_issue(%Issue{} = issue, settings) when is_map(settings) do
    runtime = issue_runtime(issue, settings)

    %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      state: issue.state,
      labels: issue.labels,
      phase: runtime.phase,
      phase_source: runtime.phase_source,
      passive_phase: runtime.passive_phase,
      rollout_mode: runtime.rollout_mode,
      dispatch_allowed: runtime.dispatch_allowed,
      waiting_reason: runtime.waiting_reason,
      next_intended_action: runtime.next_intended_action,
      ownership: runtime.ownership,
      kill_switch: runtime.kill_switch,
      workpad: runtime.workpad
    }
  end

  defp configured_workpad_marker(%{orchestration: %{ownership: %{required_workpad_marker: marker}}}) do
    normalize_optional_string(marker) || @default_workpad_marker
  end

  defp workpad_state(issue, marker, settings) do
    default_phase = settings.orchestration.default_phase

    case matching_workpad_comments(issue, marker) do
      [] ->
        %{
          marker: marker,
          marker_found: false,
          comment_id: nil,
          matched_comment_ids: [],
          metadata_status: "missing_workpad",
          phase: default_phase,
          phase_source: "default",
          waiting_reason: nil,
          metadata: nil,
          observation: %{}
        }

      [comment] ->
        comment_id = comment_field(comment, :id)
        body = comment_field(comment, :body)

        case parse_workpad_metadata(body, marker) do
          {:ok, metadata} ->
            symphony = metadata["symphony"]
            phase = parse_phase(symphony["phase"], default_phase)

            %{
              marker: marker,
              marker_found: true,
              comment_id: comment_id,
              matched_comment_ids: [comment_id],
              metadata_status: "ok",
              phase: phase,
              phase_source: if(phase == default_phase and is_nil(symphony["phase"]), do: "default", else: "workpad"),
              waiting_reason: normalize_waiting_reason(get_in(symphony, ["waiting", "reason"])),
              metadata: symphony,
              observation: normalize_map(get_in(symphony, ["observation"]))
            }

          {:missing_metadata, _body} ->
            %{
              marker: marker,
              marker_found: true,
              comment_id: comment_id,
              matched_comment_ids: [comment_id],
              metadata_status: "missing_metadata",
              phase: default_phase,
              phase_source: "default",
              waiting_reason: nil,
              metadata: nil,
              observation: %{}
            }

          {:malformed_metadata, _body} ->
            %{
              marker: marker,
              marker_found: true,
              comment_id: comment_id,
              matched_comment_ids: [comment_id],
              metadata_status: "malformed_metadata",
              phase: "blocked",
              phase_source: "recovery",
              waiting_reason: "metadata_recovery_required",
              metadata: nil,
              observation: %{}
            }
        end

      comments ->
        %{
          marker: marker,
          marker_found: true,
          comment_id: nil,
          matched_comment_ids: Enum.map(comments, &comment_field(&1, :id)),
          metadata_status: "ambiguous_workpad",
          phase: "blocked",
          phase_source: "recovery",
          waiting_reason: "metadata_recovery_required",
          metadata: nil,
          observation: %{}
        }
    end
  end

  defp ownership_state(issue, settings, workpad) do
    required_label = normalize_optional_string(settings.orchestration.ownership.required_label)
    required_workpad_marker = normalize_optional_string(settings.orchestration.ownership.required_workpad_marker)
    label_present = label_present?(issue, required_label)
    workpad_present = if(is_binary(required_workpad_marker), do: workpad.marker_found, else: true)

    %{
      required_label: required_label,
      required_workpad_marker: required_workpad_marker,
      label_present: label_present,
      workpad_present: workpad_present,
      allowed: label_present and workpad_present
    }
  end

  defp kill_switch_state(issue, settings) do
    configured_label = normalize_optional_string(settings.rollout.kill_switch_label)
    configured_file = normalize_optional_string(settings.rollout.kill_switch_file)
    label_active = if(is_binary(configured_label), do: label_present?(issue, configured_label), else: false)
    file_active = is_binary(configured_file) and File.exists?(configured_file)

    %{
      configured_label: configured_label,
      configured_file: configured_file,
      label_active: label_active,
      file_active: file_active,
      active: label_active or file_active
    }
  end

  defp label_present?(_issue, nil), do: true

  defp label_present?(%Issue{labels: labels}, required_label) when is_list(labels) do
    required_label = normalize_label(required_label)

    Enum.any?(labels, fn label -> normalize_label(label) == required_label end)
  end

  defp label_present?(_issue, _required_label), do: false

  defp matching_workpad_comments(%Issue{comments: comments}, marker) when is_list(comments) do
    comments
    |> Enum.filter(fn comment ->
      body = comment_field(comment, :body)
      workpad_heading_present?(body, marker)
    end)
    |> Enum.sort_by(
      fn comment ->
        comment
        |> comment_field(:updated_at)
        |> normalize_comment_timestamp()
      end,
      :desc
    )
  end

  defp matching_workpad_comments(_issue, _marker), do: []

  defp workpad_heading_present?(body, marker) when is_binary(body) and is_binary(marker) do
    Regex.match?(~r/^\s*#{Regex.escape(marker)}\s*$/m, body)
  end

  defp workpad_heading_present?(_body, _marker), do: false

  defp normalize_comment_timestamp(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)

  defp normalize_comment_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :microsecond)
      _ -> 0
    end
  end

  defp normalize_comment_timestamp(_value), do: 0

  defp parse_workpad_metadata(body, marker) when is_binary(body) and is_binary(marker) do
    case extract_yaml_block(body, marker) do
      nil ->
        {:missing_metadata, body}

      yaml_block ->
        yaml_block
        |> YamlElixir.read_from_string()
        |> validate_workpad_metadata(body)
    end
  end

  defp validate_workpad_metadata({:ok, %{} = metadata}, _body) do
    metadata = normalize_map(metadata)

    if match?(%{"symphony" => %{}}, metadata) do
      {:ok, metadata}
    else
      {:malformed_metadata, metadata}
    end
  end

  defp validate_workpad_metadata(_result, body), do: {:malformed_metadata, body}

  defp extract_yaml_block(body, marker) do
    escaped_marker = Regex.escape(marker)

    case Regex.run(~r/#{escaped_marker}\s*(?:\R\s*)*```yaml\s*\R(?<yaml>.*?)\R```/ms, body, capture: :all_names) do
      [yaml_block] -> yaml_block
      _ -> nil
    end
  end

  defp parse_phase(nil, default_phase), do: default_phase

  defp parse_phase(phase, _default_phase) do
    normalized_phase = normalize_optional_string(phase)

    if normalized_phase in @phase_values do
      normalized_phase
    else
      "blocked"
    end
  end

  defp normalize_waiting_reason(reason) do
    normalized_reason = normalize_optional_string(reason)

    if normalized_reason in @waiting_reason_values do
      normalized_reason
    else
      nil
    end
  end

  defp preferred_next_intended_action(observation, passive_phase, base_dispatch_allowed, dispatch_allowed, rollout_mode, ownership, kill_switch) do
    computed =
      next_intended_action(
        passive_phase,
        base_dispatch_allowed,
        dispatch_allowed,
        rollout_mode,
        ownership,
        kill_switch
      )

    if base_dispatch_allowed and passive_phase do
      fetch_value(observation, :next_intended_action) || computed
    else
      computed
    end
  end

  defp next_intended_action(_passive_phase, false, _dispatch_allowed, _rollout_mode, ownership, kill_switch) do
    cond do
      not ownership.allowed -> "await_ownership"
      kill_switch.active -> "automation_paused"
      true -> "idle"
    end
  end

  defp next_intended_action(true, true, false, _rollout_mode, _ownership, _kill_switch), do: "poll_on_next_cycle"
  defp next_intended_action(false, true, true, "observe", _ownership, _kill_switch), do: "observe_only"
  defp next_intended_action(false, true, true, _rollout_mode, _ownership, _kill_switch), do: "dispatch_worker"

  defp default_waiting_reason(_passive_phase, _rollout_mode, _ownership, %{active: true}),
    do: "kill_switch_active"

  defp default_waiting_reason(_passive_phase, _rollout_mode, %{allowed: false}, _kill_switch), do: nil
  defp default_waiting_reason(true, "observe", _ownership, _kill_switch), do: "observe_only"
  defp default_waiting_reason(true, _rollout_mode, _ownership, _kill_switch), do: nil
  defp default_waiting_reason(false, "observe", _ownership, _kill_switch), do: "observe_only"
  defp default_waiting_reason(_passive_phase, _rollout_mode, _ownership, _kill_switch), do: nil

  defp fetch_value(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp fetch_value(_map, _key), do: nil

  defp comment_field(comment, field) when is_map(comment) and is_atom(field) do
    Map.get(comment, field) || Map.get(comment, Atom.to_string(field))
  end

  defp normalize_map(nil), do: %{}

  defp normalize_map(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested_value}, acc ->
      Map.put(acc, normalize_key(key), normalize_map_value(nested_value))
    end)
  end

  defp normalize_map(_value), do: %{}

  defp normalize_map_value(value) when is_map(value), do: normalize_map(value)
  defp normalize_map_value(value) when is_list(value), do: Enum.map(value, &normalize_map_value/1)
  defp normalize_map_value(value), do: value

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp normalize_label(value) do
    value
    |> normalize_optional_string()
    |> case do
      nil -> nil
      normalized -> String.downcase(normalized)
    end
  end

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_optional_string(_value), do: nil
end
