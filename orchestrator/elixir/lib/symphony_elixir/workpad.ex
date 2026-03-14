defmodule SymphonyElixir.Workpad do
  @moduledoc """
  Canonical Symphony workpad comment read/write helpers.
  """

  alias SymphonyElixir.{Config, OrchestrationPolicy, Tracker}
  alias SymphonyElixir.Linear.Issue

  @schema_version 1
  @summary_start "<!-- symphony-summary:start -->"
  @summary_end "<!-- symphony-summary:end -->"
  @recovery_start "<!-- symphony-recovery:start -->"
  @recovery_end "<!-- symphony-recovery:end -->"

  @type sync_result :: {:ok, Issue.t()} | {:error, term()}

  @doc false
  @spec sync_for_test(Issue.t(), map(), keyword()) :: sync_result()
  def sync_for_test(issue, updates \\ %{}, opts \\ []), do: sync(issue, updates, opts)

  @spec sync(Issue.t(), map(), keyword()) :: sync_result()
  def sync(%Issue{} = issue, updates \\ %{}, opts \\ []) when is_map(updates) and is_list(opts) do
    settings = Keyword.get(opts, :settings, Config.settings!())
    tracker_module = Keyword.get(opts, :tracker_module, Tracker)
    now = Keyword.get(opts, :now, DateTime.utc_now() |> DateTime.truncate(:second))
    runtime = OrchestrationPolicy.issue_runtime(issue, settings)
    marker = fetch_value(runtime.workpad, :marker) || OrchestrationPolicy.default_workpad_marker()
    matching_comments = matching_workpad_comments(issue, marker)
    current_metadata = normalize_map(fetch_value(runtime.workpad, :metadata))
    metadata = build_metadata(issue, runtime, current_metadata, updates, now, settings)

    case apply_comment_updates(issue, matching_comments, metadata, runtime, updates, marker, now, tracker_module) do
      {:ok, comments} -> {:ok, %{issue | comments: comments}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_comment_updates(issue, [], metadata, _runtime, _updates, marker, now, tracker_module) do
    body = build_normal_body(marker, metadata, nil)

    with :ok <- tracker_module.create_comment(issue.id, body) do
      {:ok, issue.comments ++ [%{id: nil, body: body, updated_at: now}]}
    end
  end

  defp apply_comment_updates(issue, [comment], metadata, runtime, _updates, marker, now, tracker_module) do
    existing_body = comment_body(comment)
    metadata_status = fetch_value(runtime.workpad, :metadata_status)

    body =
      case metadata_status do
        "malformed_metadata" ->
          build_recovery_body(marker, metadata, existing_body, now, %{reason: :malformed_metadata})

        _ ->
          build_normal_body(marker, metadata, existing_body)
      end

    maybe_update_comment(issue.comments, comment, body, now, tracker_module)
  end

  defp apply_comment_updates(
         issue,
         [latest_comment | archived_comments],
         metadata,
         _runtime,
         _updates,
         marker,
         now,
         tracker_module
       ) do
    latest_body =
      build_recovery_body(marker, metadata, comment_body(latest_comment), now, %{
        reason: :ambiguous_workpad,
        duplicate_comment_ids: Enum.map(archived_comments, &comment_id/1)
      })

    case maybe_update_comment(issue.comments, latest_comment, latest_body, now, tracker_module) do
      {:ok, updated_comments} ->
        archive_duplicate_comments(
          updated_comments,
          latest_comment,
          archived_comments,
          marker,
          now,
          tracker_module
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_update_comment(comments, comment, body, now, tracker_module) do
    if comment_body(comment) == body do
      {:ok, comments}
    else
      update_existing_comment(comments, comment_id(comment), body, now, tracker_module)
    end
  end

  defp update_existing_comment(comments, comment_id, body, now, tracker_module)
       when is_binary(comment_id) do
    case tracker_module.update_comment(comment_id, body) do
      :ok -> {:ok, replace_comment_body(comments, comment_id, body, now)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_existing_comment(_comments, _comment_id, _body, _now, _tracker_module) do
    {:error, :missing_workpad_comment_id}
  end

  defp archive_duplicate_comments(comments, _latest_comment, [], _marker, _now, _tracker_module), do: {:ok, comments}

  defp archive_duplicate_comments(comments, latest_comment, [comment | rest], marker, now, tracker_module) do
    archived_body = archive_comment_body(comment_body(comment), marker, now, comment_id(latest_comment))

    with {:ok, updated_comments} <- maybe_update_comment(comments, comment, archived_body, now, tracker_module) do
      archive_duplicate_comments(updated_comments, latest_comment, rest, marker, now, tracker_module)
    end
  end

  defp build_metadata(issue, runtime, current_metadata, updates, now, settings) do
    target_phase =
      update_string(updates, :phase) ||
        fetch_nested_string(current_metadata, ["phase"]) ||
        runtime.phase || settings.orchestration.default_phase

    waiting_reason = select_waiting_reason(target_phase, runtime, current_metadata, updates)
    observation_gates = observation_gates(runtime, current_metadata, updates)

    %{
      "schema_version" => @schema_version,
      "owned" => select_owned(runtime, current_metadata, updates, settings),
      "phase" => target_phase,
      "rework_cycles" => select_rework_cycles(current_metadata, updates),
      "branch" => select_branch(issue, current_metadata, updates),
      "pr" => merge_section(current_metadata, updates, :pr, default_pr_metadata()),
      "review" => merge_section(current_metadata, updates, :review, default_review_metadata()),
      "merge" => merge_section(current_metadata, updates, :merge, default_merge_metadata()),
      "waiting" => waiting_metadata(waiting_reason, current_metadata, now),
      "observation" => observation_metadata(runtime, current_metadata, updates, now, settings, observation_gates),
      "validation" => merge_section(current_metadata, updates, :validation, %{})
    }
    |> remove_empty_validation()
  end

  defp select_waiting_reason(target_phase, runtime, current_metadata, updates) do
    candidate =
      update_string(updates, :waiting_reason) ||
        runtime.waiting_reason ||
        fetch_nested_string(current_metadata, ["waiting", "reason"])

    if passive_phase?(target_phase), do: candidate, else: nil
  end

  defp select_owned(runtime, current_metadata, updates, _settings) do
    case Map.get(updates, :owned) do
      value when is_boolean(value) ->
        value

      _ ->
        required_label = fetch_value(runtime.ownership, :required_label)

        cond do
          is_boolean(current_metadata["owned"]) ->
            current_metadata["owned"]

          is_binary(required_label) ->
            fetch_value(runtime.ownership, :label_present) == true

          true ->
            true
        end
    end
  end

  defp select_rework_cycles(current_metadata, updates) do
    case Map.get(updates, :rework_cycles) do
      value when is_integer(value) and value >= 0 -> value
      _ -> fetch_nested_integer(current_metadata, ["rework_cycles"]) || 0
    end
  end

  defp select_branch(issue, current_metadata, updates) do
    update_string(updates, :branch) ||
      fetch_nested_string(current_metadata, ["branch"]) ||
      normalize_optional_string(issue.branch_name)
  end

  defp waiting_metadata(nil, _current_metadata, _now) do
    %{"reason" => nil, "since" => nil}
  end

  defp waiting_metadata(reason, current_metadata, now) when is_binary(reason) do
    current_reason = fetch_nested_string(current_metadata, ["waiting", "reason"])
    current_since = fetch_nested_string(current_metadata, ["waiting", "since"])

    %{
      "reason" => reason,
      "since" => if(current_reason == reason, do: current_since, else: DateTime.to_iso8601(now))
    }
  end

  defp observation_metadata(runtime, current_metadata, updates, now, settings, observation_gates) do
    existing = normalize_map(current_metadata["observation"])

    %{
      "last_observed_at" => DateTime.to_iso8601(now),
      "next_intended_action" => update_string(updates, :next_intended_action) || existing["next_intended_action"] || runtime.next_intended_action,
      "rollout_mode" => settings.rollout.mode,
      "gates" => observation_gates
    }
  end

  defp observation_gates(runtime, current_metadata, updates) do
    existing =
      current_metadata
      |> normalize_map()
      |> Map.get("observation", %{})
      |> normalize_map()
      |> Map.get("gates", %{})
      |> normalize_map()

    current = normalize_map(Map.get(updates, :observation_gates, %{}))

    default_gates = %{
      "ownership" => if(fetch_value(runtime.ownership, :allowed) == true, do: "pass", else: "fail"),
      "kill_switch" => if(fetch_value(runtime.kill_switch, :active) == true, do: "active", else: "pass"),
      "dispatch" => if(runtime.dispatch_allowed, do: "pass", else: "blocked")
    }

    default_gates
    |> Map.merge(existing)
    |> Map.merge(current)
  end

  defp build_normal_body(marker, metadata, existing_body) do
    preserved_tail = preserved_tail(existing_body, marker)

    [
      marker,
      "",
      "```yaml",
      render_yaml_document(%{"symphony" => metadata}),
      "```",
      "",
      render_summary_block(metadata),
      preserved_tail
    ]
    |> Enum.reject(&blank_section?/1)
    |> Enum.join("\n")
    |> String.trim_trailing()
  end

  defp build_recovery_body(marker, metadata, previous_body, now, recovery) do
    [
      build_normal_body(marker, metadata, nil),
      "",
      render_recovery_block(previous_body, now, recovery)
    ]
    |> Enum.reject(&blank_section?/1)
    |> Enum.join("\n")
    |> String.trim_trailing()
  end

  defp render_summary_block(metadata) do
    phase = metadata["phase"] || "unknown"
    branch = metadata["branch"] || "unavailable"
    pr = normalize_map(metadata["pr"])
    waiting = normalize_map(metadata["waiting"])
    observation = normalize_map(metadata["observation"])

    [
      @summary_start,
      "- phase: #{phase}",
      "- branch: #{branch}",
      "- pr: #{pr_summary(pr)}",
      maybe_summary_line("waiting_reason", waiting["reason"]),
      maybe_summary_line("next_intended_action", observation["next_intended_action"]),
      maybe_summary_line("observed_at", observation["last_observed_at"]),
      @summary_end
    ]
    |> Enum.reject(&blank_section?/1)
    |> Enum.join("\n")
  end

  defp render_recovery_block(previous_body, now, recovery) do
    [
      @recovery_start,
      recovery_message(recovery, now),
      duplicate_comment_summary(recovery),
      "",
      "<details>",
      "<summary>Previous content preserved during recovery</summary>",
      "",
      "```md",
      sanitize_preserved_body(previous_body || ""),
      "```",
      "",
      "</details>",
      @recovery_end
    ]
    |> Enum.reject(&blank_section?/1)
    |> Enum.join("\n")
  end

  defp archive_comment_body(previous_body, marker, now, latest_comment_id) do
    [
      "## Archived Symphony Workpad",
      "",
      "This duplicate Symphony workpad comment was archived during recovery at #{DateTime.to_iso8601(now)}.",
      maybe_archive_target(latest_comment_id),
      "",
      "<details>",
      "<summary>Archived duplicate content</summary>",
      "",
      "```md",
      sanitize_preserved_body(previous_body || "")
      |> String.replace(marker, "## Archived Symphony Workpad (preserved raw)"),
      "```",
      "",
      "</details>"
    ]
    |> Enum.reject(&blank_section?/1)
    |> Enum.join("\n")
  end

  defp recovery_message(%{reason: :ambiguous_workpad}, now) do
    "Recovered canonical Symphony workpad metadata at #{DateTime.to_iso8601(now)} because multiple workpad comments matched the marker."
  end

  defp recovery_message(%{reason: :malformed_metadata}, now) do
    "Recovered canonical Symphony workpad metadata at #{DateTime.to_iso8601(now)} because the existing metadata block could not be parsed."
  end

  defp duplicate_comment_summary(%{duplicate_comment_ids: ids}) when is_list(ids) and ids != [] do
    "Archived duplicate comment ids: #{Enum.reject(ids, &is_nil/1) |> Enum.join(", ")}"
  end

  defp duplicate_comment_summary(_recovery), do: nil

  defp maybe_archive_target(nil), do: nil
  defp maybe_archive_target(comment_id), do: "Canonical workpad comment id: #{comment_id}"

  defp pr_summary(pr) do
    number = pr["number"]
    url = pr["url"]

    cond do
      is_integer(number) and is_binary(url) -> "##{number} (#{url})"
      is_binary(url) -> url
      true -> "none"
    end
  end

  defp maybe_summary_line(_label, nil), do: nil
  defp maybe_summary_line(label, value), do: "- #{label}: #{value}"

  defp preserved_tail(nil, _marker), do: nil

  defp preserved_tail(body, marker) when is_binary(body) do
    escaped_marker = Regex.escape(marker)

    body
    |> String.replace(~r/^\s*#{escaped_marker}\s*\n*/m, "", global: false)
    |> String.replace(~r/^```yaml\s*\n.*?\n```\s*\n*/ms, "", global: false)
    |> remove_generated_block(@summary_start, @summary_end)
    |> remove_generated_block(@recovery_start, @recovery_end)
    |> String.trim()
    |> normalize_optional_string()
  end

  defp remove_generated_block(body, start_marker, end_marker) when is_binary(body) do
    escaped_start = Regex.escape(start_marker)
    escaped_end = Regex.escape(end_marker)

    String.replace(body, ~r/#{escaped_start}.*?#{escaped_end}\s*/ms, "")
  end

  defp render_yaml_document(document) when is_map(document) do
    document
    |> yaml_lines(0)
    |> Enum.join("\n")
  end

  defp yaml_lines(value, indent) when is_map(value) do
    value
    |> ordered_entries()
    |> Enum.flat_map(fn {key, nested_value} ->
      yaml_entry_lines(to_string(key), nested_value, indent)
    end)
  end

  defp yaml_lines(value, indent) when is_list(value) do
    Enum.flat_map(value, fn item ->
      yaml_list_item_lines(item, indent)
    end)
  end

  defp yaml_entry_lines(key, value, indent) when is_map(value) do
    ["#{spaces(indent)}#{key}:"] ++ yaml_lines(value, indent + 2)
  end

  defp yaml_entry_lines(key, value, indent) when is_list(value) do
    ["#{spaces(indent)}#{key}:"] ++ yaml_lines(value, indent + 2)
  end

  defp yaml_entry_lines(key, value, indent) when is_binary(value) do
    if String.contains?(value, "\n") do
      (["#{spaces(indent)}#{key}: |"] ++
         String.split(value, "\n", trim: false))
      |> Enum.map(&"#{spaces(indent + 2)}#{&1}")
    else
      ["#{spaces(indent)}#{key}: #{yaml_scalar(value)}"]
    end
  end

  defp yaml_entry_lines(key, value, indent) do
    ["#{spaces(indent)}#{key}: #{yaml_scalar(value)}"]
  end

  defp yaml_list_item_lines(value, indent) when is_map(value) do
    case ordered_entries(value) do
      [] ->
        ["#{spaces(indent)}- {}"]

      [{first_key, first_value} | rest] ->
        first_lines = yaml_entry_lines(to_string(first_key), first_value, indent + 2)
        [first_line | remaining_first_lines] = first_lines

        rest_lines =
          Enum.flat_map(rest, fn {key, nested_value} ->
            yaml_entry_lines(to_string(key), nested_value, indent + 2)
          end)

        [
          "#{spaces(indent)}- #{String.trim_leading(first_line, spaces(indent + 2))}"
          | remaining_first_lines ++ rest_lines
        ]
    end
  end

  defp yaml_list_item_lines(value, indent) when is_list(value) do
    ["#{spaces(indent)}-"] ++ yaml_lines(value, indent + 2)
  end

  defp yaml_list_item_lines(value, indent) when is_binary(value) do
    if String.contains?(value, "\n") do
      (["#{spaces(indent)}- |"] ++
         String.split(value, "\n", trim: false))
      |> Enum.map(&"#{spaces(indent + 2)}#{&1}")
    else
      ["#{spaces(indent)}- #{yaml_scalar(value)}"]
    end
  end

  defp yaml_list_item_lines(value, indent) do
    ["#{spaces(indent)}- #{yaml_scalar(value)}"]
  end

  defp yaml_scalar(nil), do: "null"
  defp yaml_scalar(true), do: "true"
  defp yaml_scalar(false), do: "false"
  defp yaml_scalar(value) when is_integer(value), do: Integer.to_string(value)
  defp yaml_scalar(value) when is_float(value), do: :erlang.float_to_binary(value, [:compact])
  defp yaml_scalar(value) when is_binary(value), do: Jason.encode!(value)
  defp yaml_scalar(value), do: Jason.encode!(to_string(value))

  defp ordered_entries(map) when is_map(map) do
    preferred_order = %{
      "symphony" => 0,
      "schema_version" => 0,
      "owned" => 1,
      "phase" => 2,
      "rework_cycles" => 3,
      "branch" => 4,
      "pr" => 5,
      "review" => 6,
      "merge" => 7,
      "waiting" => 8,
      "observation" => 9,
      "validation" => 10,
      "number" => 0,
      "url" => 1,
      "head_sha" => 2,
      "comment_id" => 0,
      "passes_completed" => 1,
      "last_reviewed_head_sha" => 2,
      "last_fixed_head_sha" => 3,
      "last_attempted_head_sha" => 0,
      "reason" => 0,
      "since" => 1,
      "last_observed_at" => 0,
      "next_intended_action" => 1,
      "rollout_mode" => 2,
      "gates" => 3,
      "summary" => 0
    }

    Enum.sort_by(map, fn {key, _value} -> {Map.get(preferred_order, to_string(key), 999), to_string(key)} end)
  end

  defp default_pr_metadata do
    %{"number" => nil, "url" => nil, "head_sha" => nil}
  end

  defp default_review_metadata do
    %{
      "comment_id" => nil,
      "passes_completed" => 0,
      "last_reviewed_head_sha" => nil,
      "last_fixed_head_sha" => nil
    }
  end

  defp default_merge_metadata do
    %{"last_attempted_head_sha" => nil}
  end

  defp merge_section(current_metadata, updates, section_key, defaults) do
    current = normalize_map(current_metadata[to_string(section_key)])
    incoming = normalize_map(Map.get(updates, section_key, %{}))

    defaults
    |> Map.merge(current)
    |> Map.merge(incoming)
  end

  defp remove_empty_validation(metadata) do
    validation = normalize_map(metadata["validation"])

    if validation == %{} do
      Map.delete(metadata, "validation")
    else
      metadata
    end
  end

  defp matching_workpad_comments(%Issue{comments: comments}, marker) when is_list(comments) do
    comments
    |> Enum.filter(fn comment ->
      comment
      |> comment_body()
      |> workpad_heading_present?(marker)
    end)
    |> Enum.sort_by(&(comment_updated_at(&1) |> normalize_comment_timestamp()), :desc)
  end

  defp workpad_heading_present?(body, marker) when is_binary(body) and is_binary(marker) do
    Regex.match?(~r/^\s*#{Regex.escape(marker)}\s*$/m, body)
  end

  defp workpad_heading_present?(_body, _marker), do: false

  defp replace_comment_body(comments, comment_id, body, now) when is_list(comments) do
    Enum.map(comments, fn
      %{id: ^comment_id} = comment -> Map.merge(comment, %{body: body, updated_at: now})
      comment -> comment
    end)
  end

  defp fetch_nested_string(map, [key | rest]) when is_map(map) do
    value = Map.get(map, key)

    case rest do
      [] -> normalize_optional_string(value)
      _ -> fetch_nested_string(normalize_map(value), rest)
    end
  end

  defp fetch_nested_string(_map, _path), do: nil

  defp fetch_nested_integer(map, [key | rest]) when is_map(map) do
    value = Map.get(map, key)

    case rest do
      [] -> if(is_integer(value), do: value, else: nil)
      _ -> fetch_nested_integer(normalize_map(value), rest)
    end
  end

  defp fetch_nested_integer(_map, _path), do: nil

  defp update_string(updates, key) when is_map(updates), do: normalize_optional_string(Map.get(updates, key))

  defp passive_phase?(phase) when is_binary(phase) do
    phase in OrchestrationPolicy.passive_default_phases() or phase == "blocked"
  end

  defp passive_phase?(_phase), do: false

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

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_optional_string(_value), do: nil

  defp comment_id(comment), do: fetch_value(comment, :id)
  defp comment_body(comment), do: fetch_value(comment, :body) || ""
  defp comment_updated_at(comment), do: fetch_value(comment, :updated_at)

  defp fetch_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp fetch_value(_map, _key), do: nil

  defp normalize_comment_timestamp(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)

  defp normalize_comment_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :microsecond)
      _ -> 0
    end
  end

  defp normalize_comment_timestamp(_value), do: 0

  defp sanitize_preserved_body(body) when is_binary(body) do
    body
    |> String.replace("```", "'''")
    |> String.trim_trailing()
  end

  defp sanitize_preserved_body(_body), do: ""

  defp spaces(count) when is_integer(count) and count >= 0, do: String.duplicate(" ", count)

  defp blank_section?(nil), do: true
  defp blank_section?(""), do: true
  defp blank_section?(_value), do: false
end
