defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.{Config, OrchestrationPolicy, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    template =
      Workflow.current()
      |> prompt_template!()
      |> parse_template!()

    settings = Config.settings!()

    rendered =
      template
      |> Solid.render!(
        %{
          "attempt" => Keyword.get(opts, :attempt),
          "issue" => issue_prompt_map(issue, settings),
          "policy" => Config.prompt_policy()
        },
        @render_opts
      )
      |> IO.iodata_to_binary()

    maybe_prepend_conflict_instructions(rendered, issue, settings)
  end

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp issue_prompt_map(issue, settings) do
    issue
    |> Map.from_struct()
    |> Map.put(:symphony, OrchestrationPolicy.issue_runtime(issue, settings))
    |> to_solid_map()
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp merge_conflict_instructions(base_branch) do
    """
    ## URGENT: Merge Conflict Resolution Required

    The branch for this issue has merge conflicts with the base branch and cannot be merged.
    A sibling PR was merged into `#{base_branch}` while this branch was being worked on.

    Steps:
    1. `git fetch origin`
    2. `git rebase origin/#{base_branch}`
    3. Resolve any conflicts — prefer the incoming #{base_branch} changes for generated files, fixture data,
       and lock files; prefer your implementation changes for logic and types
    4. Run the project's validation/test suite to confirm the rebase is clean
    5. `git push --force-with-lease`

    Do NOT create a new PR — the existing PR will update automatically when you push.
    Focus only on resolving the conflicts and validating the result.
    """
  end

  defp maybe_prepend_conflict_instructions(prompt, issue, settings) do
    runtime = OrchestrationPolicy.issue_runtime(issue, settings)
    observation = runtime.workpad.observation
    mergeability = Map.get(observation, "gates", %{}) |> Map.get("mergeability")

    if runtime.phase == "rework" and mergeability == "conflict" do
      merge_conflict_instructions(settings.pr.base_branch) <> "\n" <> prompt
    else
      prompt
    end
  end

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end
end
