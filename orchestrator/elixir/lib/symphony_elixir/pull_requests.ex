defmodule SymphonyElixir.PullRequests do
  @moduledoc """
  Resolves and publishes branch pull requests through the GitHub CLI.
  """

  alias SymphonyElixir.{Config, Linear.Issue}

  @type pr_result :: {:ok, map()} | {:skip, map()} | {:error, term()}
  @type pr_state_result :: {:ok, map()} | {:skip, map()} | {:error, term()}
  @type review_comment_result :: {:ok, map()} | {:skip, map()} | {:error, term()}

  @doc false
  @spec resolve_or_create_for_test(Issue.t(), map(), keyword()) :: pr_result()
  def resolve_or_create_for_test(issue, git_state, opts \\ []), do: resolve_or_create(issue, git_state, opts)

  @doc false
  @spec inspect_state_for_test(map(), keyword()) :: pr_state_result()
  def inspect_state_for_test(pr_context, opts \\ []), do: inspect_state(pr_context, opts)

  @doc false
  @spec upsert_review_comment_for_test(map(), String.t(), keyword()) :: review_comment_result()
  def upsert_review_comment_for_test(pr_context, body, opts \\ []), do: upsert_review_comment(pr_context, body, opts)

  @spec resolve_or_create(Issue.t(), map(), keyword()) :: pr_result()
  def resolve_or_create(%Issue{} = issue, git_state, opts \\ []) when is_map(git_state) and is_list(opts) do
    settings = Keyword.get(opts, :settings, Config.settings!())
    runner = Keyword.get(opts, :runner, command_runner())
    context = branch_context(issue, git_state, settings, opts)

    cond do
      is_nil(context.repo_slug) ->
        {:skip, %{reason: :missing_repo_slug, branch: context.branch, next_intended_action: "record_repo_context"}}

      is_nil(context.branch) ->
        {:skip, %{reason: :missing_branch, next_intended_action: "record_branch_context"}}

      true ->
        with {:ok, prs} <- list_branch_pull_requests(context.repo_slug, context.branch, context.base_branch, runner) do
          resolve_from_existing_prs(issue, context, prs, settings, runner)
        end
    end
  end

  @spec inspect_state(map(), keyword()) :: pr_state_result()
  def inspect_state(pr_context, opts \\ []) when is_map(pr_context) and is_list(opts) do
    settings = Keyword.get(opts, :settings, Config.settings!())
    runner = Keyword.get(opts, :runner, command_runner())
    context = inspect_pr_context(pr_context, settings, opts)

    case inspect_pr_skip_result(context) do
      nil ->
        inspect_pull_request_state(context, runner)

      result ->
        {:skip, result}
    end
  end

  @spec upsert_review_comment(map(), String.t(), keyword()) :: review_comment_result()
  def upsert_review_comment(pr_context, body, opts \\ []) when is_map(pr_context) and is_binary(body) and is_list(opts) do
    settings = Keyword.get(opts, :settings, Config.settings!())
    runner = Keyword.get(opts, :runner, command_runner())
    context = review_comment_context(pr_context, settings, opts)
    normalized_body = normalize_review_comment_body(body, context.marker)

    case review_comment_skip_result(context, settings, normalized_body) do
      nil ->
        if settings.pr.review_comment_mode == "create" do
          create_review_comment(context, normalized_body, runner)
        else
          upsert_review_comment_body(context, normalized_body, runner)
        end

      result ->
        {:skip, result}
    end
  end

  defp review_comment_skip_result(context, settings, normalized_body) do
    review_comment_mode_skip(settings) ||
      review_comment_mutation_skip(settings) ||
      review_comment_context_skip(context) ||
      review_comment_body_skip(normalized_body)
  end

  defp review_comment_mode_skip(settings) do
    if settings.pr.review_comment_mode == "off" do
      %{reason: :review_comment_mode_off, next_intended_action: "enable_review_comment_mode"}
    end
  end

  defp review_comment_mutation_skip(settings) do
    if settings.rollout.mode not in ["mutate", "merge"] do
      %{reason: :observe_only, next_intended_action: "upsert_review_comment_when_mutations_enabled"}
    end
  end

  defp review_comment_context_skip(context) do
    cond do
      is_nil(context.repo_slug) ->
        %{reason: :missing_repo_slug, next_intended_action: "record_repo_context"}

      is_nil(context.pr_number) ->
        %{reason: :missing_pr_number, next_intended_action: "record_pr_context"}

      true ->
        nil
    end
  end

  defp review_comment_body_skip(nil) do
    %{reason: :missing_review_body, next_intended_action: "persist_review_artifact"}
  end

  defp review_comment_body_skip(_normalized_body), do: nil

  defp resolve_from_existing_prs(issue, context, prs, settings, runner) do
    open_pr = Enum.find(prs, &(&1.state == "OPEN"))
    closed_pr = Enum.find(prs, &(&1.state in ["CLOSED", "MERGED"]))
    allow_mutation? = settings.rollout.mode in ["mutate", "merge"]

    with :continue <- maybe_return_open_pr(open_pr, context, settings, allow_mutation?, runner),
         :continue <- maybe_skip_pr_creation(closed_pr, context, settings, allow_mutation?),
         :continue <- maybe_reopen_closed_pr(closed_pr, context, settings, runner) do
      create_new_pull_request(issue, context, settings, runner)
    else
      {:ok, _result} = result -> result
      {:skip, _details} = result -> result
      {:error, _reason} = result -> result
    end
  end

  defp maybe_return_open_pr(nil, _context, _settings, _allow_mutation, _runner), do: :continue

  defp maybe_return_open_pr(open_pr, context, settings, allow_mutation?, runner) when is_map(open_pr) do
    case maybe_ensure_required_labels(open_pr, context.repo_slug, settings, allow_mutation?, runner) do
      :ok -> {:ok, pr_success(open_pr, context, :reused)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_skip_pr_creation(closed_pr, context, _settings, false) do
    {:skip, skip_result(:observe_only, context, "create_pr_when_mutations_enabled", closed_pr)}
  end

  defp maybe_skip_pr_creation(closed_pr, context, settings, true) do
    case skip_pr_creation_result(closed_pr, context, settings) do
      nil -> :continue
      result -> {:skip, result}
    end
  end

  defp skip_pr_creation_result(closed_pr, context, settings) do
    auto_create_skip(closed_pr, context, settings) ||
      closed_pr_policy_skip(closed_pr, context, settings) ||
      remote_branch_skip(closed_pr, context)
  end

  defp auto_create_skip(closed_pr, context, settings) do
    if settings.pr.auto_create != true do
      skip_result(:auto_create_disabled, context, "create_pr_when_policy_allows", closed_pr)
    end
  end

  defp closed_pr_policy_skip(nil, _context, _settings), do: nil

  defp closed_pr_policy_skip(closed_pr, context, settings) do
    case {settings.pr.closed_pr_policy, closed_pr.state} do
      {"stop", _state} ->
        skip_result(:closed_pr_policy_stop, context, "resolve_closed_pr_policy", closed_pr)

      {"new_branch", _state} ->
        skip_result(:new_branch_required, context, "push_new_branch_for_followup", closed_pr)

      {"reopen", "MERGED"} ->
        skip_result(:merged_pr_cannot_reopen, context, "push_new_branch_for_followup", closed_pr)

      _ ->
        nil
    end
  end

  defp remote_branch_skip(closed_pr, context) do
    if context.remote_branch_published != true do
      skip_result(:remote_branch_missing, context, "push_branch_to_origin", closed_pr)
    end
  end

  defp maybe_reopen_closed_pr(closed_pr, context, settings, runner) when is_map(closed_pr) do
    if settings.pr.closed_pr_policy == "reopen" and closed_pr.state == "CLOSED" do
      reopen_closed_pr(closed_pr, context, settings, runner)
    else
      :continue
    end
  end

  defp maybe_reopen_closed_pr(_closed_pr, _context, _settings, _runner), do: :continue

  defp reopen_closed_pr(closed_pr, context, settings, runner) do
    with :ok <- reopen_pull_request(closed_pr.number, context.repo_slug, runner),
         {:ok, prs_after_reopen} <-
           list_branch_pull_requests(context.repo_slug, context.branch, context.base_branch, runner),
         %{} = reopened_pr <- Enum.find(prs_after_reopen, &(&1.state == "OPEN")),
         :ok <- maybe_ensure_required_labels(reopened_pr, context.repo_slug, settings, true, runner) do
      {:ok, pr_success(reopened_pr, context, :reopened)}
    else
      nil -> {:error, :reopened_pr_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_new_pull_request(issue, context, settings, runner) do
    with :ok <- create_pull_request(issue, context, settings, runner),
         {:ok, prs_after_create} <-
           list_branch_pull_requests(context.repo_slug, context.branch, context.base_branch, runner),
         %{} = created_pr <- Enum.find(prs_after_create, &(&1.state == "OPEN")),
         :ok <- maybe_ensure_required_labels(created_pr, context.repo_slug, settings, true, runner) do
      {:ok, pr_success(created_pr, context, :created)}
    else
      nil -> {:error, :created_pr_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp inspect_pr_skip_result(context) do
    cond do
      is_nil(context.repo_slug) ->
        %{reason: :missing_repo_slug, next_intended_action: "record_repo_context"}

      is_nil(context.pr_number) ->
        %{reason: :missing_pr_number, next_intended_action: "record_pr_context"}

      true ->
        nil
    end
  end

  defp inspect_pull_request_state(context, runner) do
    args = [
      "pr",
      "view",
      Integer.to_string(context.pr_number),
      "--repo",
      context.repo_slug,
      "--json",
      "number,url,state,isDraft,headRefName,headRefOid,baseRefName,mergeStateStatus,mergeable,reviewDecision,statusCheckRollup"
    ]

    with {:ok, output} <- runner.("gh", args, []),
         {:ok, pr} <- Jason.decode(output) do
      {:ok, normalize_inspected_pull_request(pr)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_pr_view_response}
    end
  end

  defp upsert_review_comment_body(context, body, runner) do
    with {:ok, existing_comment} <- find_existing_review_comment(context, runner) do
      case existing_comment do
        %{} = comment -> update_review_comment(comment.id, context, body, runner)
        nil -> create_review_comment(context, body, runner)
      end
    end
  end

  defp create_review_comment(context, body, runner) do
    with {:ok, comment} <- create_issue_comment(context.repo_slug, context.pr_number, body, runner) do
      {:ok, %{action: :created, comment_id: comment.id, url: comment.url, body: comment.body}}
    end
  end

  defp update_review_comment(comment_id, context, body, runner) do
    with {:ok, comment} <- update_issue_comment(context.repo_slug, comment_id, body, runner) do
      {:ok, %{action: :updated, comment_id: comment.id, url: comment.url, body: comment.body}}
    end
  end

  defp find_existing_review_comment(context, runner) do
    with {:ok, direct_match} <- fetch_issue_comment_by_id(context, runner),
         {:ok, marker_match} <- fetch_issue_comment_by_marker(context, runner, direct_match) do
      {:ok, direct_match || marker_match}
    end
  end

  defp fetch_issue_comment_by_id(%{comment_id: comment_id} = context, runner) when is_integer(comment_id) do
    case fetch_issue_comment(context.repo_slug, comment_id, runner) do
      {:ok, comment} -> {:ok, comment}
      {:error, reason} when reason in [:issue_comment_not_found, {404, ""}] -> {:ok, nil}
      {:error, {404, _output}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_issue_comment_by_id(_context, _runner), do: {:ok, nil}

  defp fetch_issue_comment_by_marker(_context, _runner, %{} = direct_match), do: {:ok, direct_match}

  defp fetch_issue_comment_by_marker(context, runner, _direct_match) do
    with {:ok, comments} <- list_issue_comments(context.repo_slug, context.pr_number, runner) do
      {:ok,
       Enum.find(comments, fn comment ->
         is_binary(comment.body) and String.contains?(comment.body, context.marker)
       end)}
    end
  end

  defp fetch_issue_comment(repo_slug, comment_id, runner)
       when is_binary(repo_slug) and is_integer(comment_id) and is_function(runner, 3) do
    args = ["api", "repos/#{repo_slug}/issues/comments/#{comment_id}"]

    with {:ok, output} <- runner.("gh", args, []),
         {:ok, comment} <- Jason.decode(output) do
      {:ok, normalize_issue_comment(comment)}
    else
      {:error, {404, _output}} -> {:error, :issue_comment_not_found}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_issue_comment_response}
    end
  end

  defp list_issue_comments(repo_slug, pr_number, runner)
       when is_binary(repo_slug) and is_integer(pr_number) and is_function(runner, 3) do
    fetch_issue_comment_pages(repo_slug, pr_number, 1, [], runner)
  end

  defp fetch_issue_comment_pages(repo_slug, pr_number, page, acc, runner)
       when is_binary(repo_slug) and is_integer(pr_number) and is_integer(page) and is_list(acc) and
              is_function(runner, 3) do
    with {:ok, comments} <- fetch_issue_comment_page(repo_slug, pr_number, page, runner) do
      next_acc = acc ++ comments

      if length(comments) < 100 do
        {:ok, next_acc}
      else
        fetch_issue_comment_pages(repo_slug, pr_number, page + 1, next_acc, runner)
      end
    end
  end

  defp fetch_issue_comment_page(repo_slug, pr_number, page, runner)
       when is_binary(repo_slug) and is_integer(pr_number) and is_integer(page) and is_function(runner, 3) do
    args = ["api", "repos/#{repo_slug}/issues/#{pr_number}/comments?per_page=100&page=#{page}"]

    with {:ok, output} <- runner.("gh", args, []),
         {:ok, comments} <- Jason.decode(output) do
      {:ok, Enum.map(comments, &normalize_issue_comment/1)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_issue_comment_list_response}
    end
  end

  defp create_issue_comment(repo_slug, pr_number, body, runner)
       when is_binary(repo_slug) and is_integer(pr_number) and is_binary(body) and is_function(runner, 3) do
    args = ["api", "repos/#{repo_slug}/issues/#{pr_number}/comments", "--method", "POST", "-f", "body=#{body}"]

    with {:ok, output} <- runner.("gh", args, []),
         {:ok, comment} <- Jason.decode(output) do
      {:ok, normalize_issue_comment(comment)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_issue_comment_response}
    end
  end

  defp update_issue_comment(repo_slug, comment_id, body, runner)
       when is_binary(repo_slug) and is_integer(comment_id) and is_binary(body) and is_function(runner, 3) do
    args = ["api", "repos/#{repo_slug}/issues/comments/#{comment_id}", "--method", "PATCH", "-f", "body=#{body}"]

    with {:ok, output} <- runner.("gh", args, []),
         {:ok, comment} <- Jason.decode(output) do
      {:ok, normalize_issue_comment(comment)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_issue_comment_response}
    end
  end

  defp skip_result(reason, context, next_intended_action, pr) do
    %{
      reason: reason,
      branch: context.branch,
      repo_slug: context.repo_slug,
      next_intended_action: next_intended_action,
      pr: pr
    }
  end

  defp branch_context(issue, git_state, settings, opts) do
    %{
      branch: pick_optional_string([Map.get(git_state, :branch), issue.branch_name]),
      head_sha: pick_optional_string([Map.get(git_state, :head_sha)]),
      repo_slug: pick_optional_string([Keyword.get(opts, :repo_slug), Map.get(git_state, :repo_slug)]),
      base_branch: settings.pr.base_branch,
      remote_branch_published: Map.get(git_state, :remote_branch_published) == true
    }
  end

  defp inspect_pr_context(pr_context, settings, opts) do
    url = pick_optional_string([Map.get(pr_context, :url), Map.get(pr_context, "url")])

    %{
      pr_number: normalize_optional_integer(Map.get(pr_context, :number) || Map.get(pr_context, "number")),
      repo_slug:
        pick_optional_string([
          Keyword.get(opts, :repo_slug),
          Map.get(pr_context, :repo_slug),
          Map.get(pr_context, "repo_slug"),
          repo_slug_from_pr_url(url)
        ]),
      url: url,
      marker: pick_optional_string([settings.pr.review_comment_marker]) || "<!-- symphony-review -->"
    }
  end

  defp review_comment_context(pr_context, settings, opts) do
    inspect_context = inspect_pr_context(pr_context, settings, opts)

    %{
      pr_number: inspect_context.pr_number,
      repo_slug: inspect_context.repo_slug,
      url: inspect_context.url,
      comment_id: normalize_optional_integer(Keyword.get(opts, :comment_id) || Map.get(pr_context, :comment_id) || Map.get(pr_context, "comment_id")),
      marker: inspect_context.marker
    }
  end

  defp pr_success(pr, context, action) do
    %{
      action: action,
      branch: context.branch,
      repo_slug: context.repo_slug,
      base_branch: Map.get(pr, :base_branch) || context.base_branch,
      number: pr.number,
      url: pr.url,
      state: pr.state,
      head_sha: Map.get(pr, :head_sha) || context.head_sha
    }
  end

  defp list_branch_pull_requests(repo_slug, branch, base_branch, runner)
       when is_binary(repo_slug) and is_binary(branch) and is_binary(base_branch) and
              is_function(runner, 3) do
    args = [
      "pr",
      "list",
      "--repo",
      repo_slug,
      "--head",
      branch,
      "--base",
      base_branch,
      "--state",
      "all",
      "--json",
      "number,url,state,isDraft,headRefName,headRefOid,baseRefName"
    ]

    with {:ok, output} <- runner.("gh", args, []),
         {:ok, prs} <- Jason.decode(output) do
      {:ok, Enum.map(prs, &normalize_pull_request/1)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_pr_list_response}
    end
  end

  defp reopen_pull_request(pr_number, repo_slug, runner)
       when is_integer(pr_number) and is_binary(repo_slug) and is_function(runner, 3) do
    case runner.("gh", ["pr", "reopen", Integer.to_string(pr_number), "--repo", repo_slug], []) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_pull_request(issue, context, settings, runner) when is_function(runner, 3) do
    args = [
      "pr",
      "create",
      "--repo",
      context.repo_slug,
      "--head",
      context.branch,
      "--base",
      context.base_branch,
      "--title",
      pull_request_title(issue),
      "--body",
      pull_request_body(issue, context, settings)
    ]

    case runner.("gh", args, []) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_ensure_required_labels(_pr, _repo_slug, settings, false, _runner)
       when is_list(settings.pr.required_labels),
       do: :ok

  defp maybe_ensure_required_labels(pr, repo_slug, settings, true, runner) when is_function(runner, 3) do
    required_labels = Enum.filter(settings.pr.required_labels, &is_binary/1)

    Enum.reduce_while(required_labels, :ok, fn label, :ok ->
      case runner.("gh", ["pr", "edit", Integer.to_string(pr.number), "--repo", repo_slug, "--add-label", label], []) do
        {:ok, _output} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_pull_request(%{} = pr) do
    %{
      number: pr["number"],
      url: pr["url"],
      state: pr["state"],
      draft?: pr["isDraft"] == true,
      head_branch: pr["headRefName"],
      head_sha: pr["headRefOid"],
      base_branch: pr["baseRefName"]
    }
  end

  defp normalize_inspected_pull_request(%{} = pr) do
    checks = normalize_status_check_rollup(pr["statusCheckRollup"])

    %{
      number: pr["number"],
      url: pr["url"],
      state: pr["state"],
      draft?: pr["isDraft"] == true,
      head_branch: pr["headRefName"],
      head_sha: pr["headRefOid"],
      base_branch: pr["baseRefName"],
      merge_state_status: pick_optional_string([pr["mergeStateStatus"]]),
      mergeable: pick_optional_string([pr["mergeable"]]),
      review_decision: pick_optional_string([pr["reviewDecision"]]),
      checks: checks
    }
  end

  defp normalize_status_check_rollup(status_check_rollup) when is_list(status_check_rollup) do
    counts =
      Enum.reduce(status_check_rollup, %{total: 0, passing: 0, pending: 0, failing: 0}, fn item, acc ->
        case classify_status_check(item) do
          :passing -> %{acc | total: acc.total + 1, passing: acc.passing + 1}
          :pending -> %{acc | total: acc.total + 1, pending: acc.pending + 1}
          :failing -> %{acc | total: acc.total + 1, failing: acc.failing + 1}
        end
      end)

    state =
      cond do
        counts.failing > 0 -> "fail"
        counts.pending > 0 -> "pending"
        true -> "pass"
      end

    Map.put(counts, :state, state)
  end

  defp normalize_status_check_rollup(_status_check_rollup) do
    %{total: 0, passing: 0, pending: 0, failing: 0, state: "pass"}
  end

  defp classify_status_check(%{} = item) do
    status = pick_optional_string([item["status"], item["state"]]) |> to_status_token()
    conclusion = pick_optional_string([item["conclusion"]]) |> to_status_token()

    cond do
      status in ["QUEUED", "IN_PROGRESS", "PENDING", "REQUESTED", "EXPECTED", "WAITING"] ->
        :pending

      conclusion in ["SUCCESS", "NEUTRAL", "SKIPPED"] ->
        :passing

      conclusion in ["FAILURE", "TIMED_OUT", "CANCELLED", "STARTUP_FAILURE", "STALE", "ACTION_REQUIRED", "ERROR"] ->
        :failing

      status in ["SUCCESS", "NEUTRAL", "SKIPPED"] ->
        :passing

      status in ["FAILURE", "ERROR"] ->
        :failing

      status == "COMPLETED" and conclusion == nil ->
        :pending

      true ->
        :pending
    end
  end

  defp classify_status_check(_item), do: :pending

  defp to_status_token(nil), do: nil
  defp to_status_token(value) when is_binary(value), do: String.upcase(String.trim(value))
  defp to_status_token(_value), do: nil

  defp normalize_issue_comment(%{} = comment) do
    %{
      id: normalize_optional_integer(comment["id"]),
      url: comment["html_url"] || comment["url"],
      body: comment["body"]
    }
  end

  defp normalize_review_comment_body(body, marker) when is_binary(body) and is_binary(marker) do
    case String.trim(body) do
      "" ->
        nil

      normalized_body ->
        if String.contains?(normalized_body, marker) do
          normalized_body
        else
          [marker, "", normalized_body] |> Enum.join("\n")
        end
    end
  end

  defp pull_request_title(%Issue{identifier: identifier, title: title}) do
    [pick_optional_string([identifier]), pick_optional_string([title])]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(": ")
    |> case do
      "" -> "Symphony change"
      value -> value
    end
  end

  defp pull_request_body(issue, context, settings) do
    issue_url = pick_optional_string([issue.url]) || "Unavailable"
    rollout_mode = settings.rollout.mode

    """
    Automated Symphony PR for #{issue.identifier || "unknown issue"}.

    Tracker issue: #{issue_url}
    Source branch: #{context.branch}
    Base branch: #{context.base_branch}
    Rollout mode: #{rollout_mode}
    """
    |> String.trim()
  end

  defp command_runner do
    Application.get_env(:symphony_elixir, :github_command_runner, &default_command_runner/3)
  end

  defp default_command_runner(command, args, opts) do
    stderr_to_stdout = Keyword.get(opts, :stderr_to_stdout, true)

    case System.find_executable(command) do
      nil ->
        {:error, {command, :enoent}}

      executable ->
        case System.cmd(executable, args, stderr_to_stdout: stderr_to_stdout) do
          {output, 0} -> {:ok, output}
          {output, status} -> {:error, {status, output}}
        end
    end
  end

  defp normalize_optional_integer(value) when is_integer(value), do: value

  defp normalize_optional_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp normalize_optional_integer(_value), do: nil

  defp repo_slug_from_pr_url(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{host: host, path: path} when host in ["github.com", "www.github.com"] and is_binary(path) ->
        case String.split(String.trim_leading(path, "/"), "/", trim: true) do
          [owner, repo, "pull", _number | _rest] -> "#{owner}/#{repo}"
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp repo_slug_from_pr_url(_url), do: nil

  defp pick_optional_string(values) when is_list(values) do
    Enum.find_value(values, fn
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          normalized -> normalized
        end

      _ ->
        nil
    end)
  end
end
