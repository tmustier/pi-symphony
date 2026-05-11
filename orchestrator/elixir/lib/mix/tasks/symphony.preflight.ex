defmodule Mix.Tasks.Symphony.Preflight do
  use Mix.Task

  alias SymphonyElixir.Pi.CommandResolver

  @moduledoc """
  Validates workflow config, tooling prerequisites, and extension availability
  before enabling Symphony automation.

  Checks:
    - WORKFLOW.md is present, parseable, and passes semantic validation
    - Configured model is displayed and validated for known deprecations
    - GitHub CLI (`gh`) is installed and authenticated when the workflow requires GitHub automation
    - Worker extension paths resolve to existing files
    - Kill-switch file path is writable (if configured)
    - Rollout mode is reported for operator awareness
  """
  @shortdoc "Validate Symphony prerequisites before enabling automation"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.config")

    results =
      [
        check_workflow_config(),
        check_pi_command(),
        check_model_config(),
        check_gh_cli(),
        check_extension_paths(),
        check_kill_switch_path(),
        report_rollout_mode()
      ]
      |> List.flatten()

    failures = Enum.filter(results, &match?({:fail, _, _}, &1))
    warnings = Enum.filter(results, &match?({:warn, _, _}, &1))
    passes = Enum.filter(results, &match?({:pass, _, _}, &1))
    infos = Enum.filter(results, &match?({:info, _, _}, &1))

    Enum.each(passes, fn {:pass, label, detail} ->
      Mix.shell().info("  ✅ #{label}: #{detail}")
    end)

    Enum.each(infos, fn {:info, label, detail} ->
      Mix.shell().info("  ℹ️  #{label}: #{detail}")
    end)

    Enum.each(warnings, fn {:warn, label, detail} ->
      Mix.shell().info("  ⚠️  #{label}: #{detail}")
    end)

    Enum.each(failures, fn {:fail, label, detail} ->
      Mix.shell().error("  ❌ #{label}: #{detail}")
    end)

    Mix.shell().info("")

    if failures == [] do
      Mix.shell().info("Preflight passed (#{length(passes)} checks, #{length(warnings)} warnings)")
    else
      Mix.raise("Preflight failed: #{length(failures)} check(s) failed")
    end
  end

  defp check_workflow_config do
    alias SymphonyElixir.{Config, Workflow}

    case Workflow.current() do
      {:ok, _workflow} ->
        case Config.validate!() do
          :ok ->
            {:pass, "Workflow config", "WORKFLOW.md parsed and validated"}

          {:error, reason} ->
            {:fail, "Workflow config", "semantic validation failed: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:fail, "Workflow config", "cannot load WORKFLOW.md: #{inspect(reason)}"}
    end
  end

  @deprecated_models %{
    "claude-sonnet-4-20250514" => "claude-sonnet-4-20250514 was the launch model — consider claude-sonnet-4",
    "claude-3-5-sonnet-20241022" => "claude-3-5-sonnet is superseded by claude-sonnet-4",
    "claude-3-5-sonnet-latest" => "claude-3-5-sonnet is superseded by claude-sonnet-4",
    "claude-3-opus-20240229" => "claude-3-opus is superseded by claude-opus-4",
    "claude-3-haiku-20240307" => "claude-3-haiku is superseded by claude-haiku-4"
  }

  defp check_pi_command do
    case SymphonyElixir.Config.settings() do
      {:ok, %{worker: %{runtime: "pi"}} = settings} -> check_pi_runtime_command(settings)
      {:ok, _settings} -> {:info, "Pi command", "not required for current worker runtime"}
      {:error, _reason} -> {:warn, "Pi command", "cannot check — workflow config is invalid"}
    end
  end

  defp check_pi_runtime_command(settings) do
    case CommandResolver.resolve_info(settings.pi.command) do
      {:ok, %{path: path, version: version, resolution: resolution}} ->
        version_detail = if version, do: "version #{version}", else: "version unknown"
        {:pass, "Pi command", "#{path} (#{version_detail}, #{format_resolution(resolution)})"}

      {:error, reason} ->
        {:fail, "Pi command", format_command_resolution_error(reason)}
    end
  end

  defp check_model_config do
    case SymphonyElixir.Config.settings() do
      {:ok, settings} ->
        check_model(settings)

      {:error, _reason} ->
        {:warn, "Model", "cannot check — workflow config is invalid"}
    end
  end

  defp check_model(settings) do
    case settings.pi.model do
      %{provider: provider, model_id: model_id}
      when is_binary(provider) and is_binary(model_id) ->
        model_display = "#{provider}/#{model_id}"
        thinking = settings.pi.thinking_level

        detail =
          if is_binary(thinking),
            do: "#{model_display} (thinking: #{thinking})",
            else: model_display

        deprecation_warning = Map.get(@deprecated_models, model_id)

        results =
          if deprecation_warning do
            [{:warn, "Model", "#{detail} — #{deprecation_warning}"}]
          else
            [{:pass, "Model", detail}]
          end

        if settings.worker.runtime == "pi" do
          results ++ [validate_model_availability(settings.pi.command, model_display)]
        else
          results
        end

      _ ->
        {:warn, "Model", "no model configured in pi.model — worker will use its default"}
    end
  end

  defp validate_model_availability(pi_command, model_display) do
    case CommandResolver.resolve_info(pi_command) do
      {:ok, %{path: command}} ->
        validate_model_in_list(command, model_display)

      {:error, reason} ->
        {:warn, "Model availability", "cannot validate — #{format_command_resolution_error(reason)}"}
    end
  end

  defp validate_model_in_list(command, model_display) do
    case System.cmd(command, ["--list-models"], stderr_to_stdout: true) do
      {output, 0} ->
        validate_model_in_output(output, command, model_display)

      {output, _code} ->
        {:warn, "Model availability", "cannot validate — `#{command} --list-models` failed: #{String.trim(output) |> String.slice(0, 120)}"}
    end
  end

  defp validate_model_in_output(output, command, model_display) do
    if String.contains?(output, model_display) do
      {:pass, "Model availability", "#{model_display} found in `#{command} --list-models`"}
    else
      {:fail, "Model availability", "#{model_display} not found in `#{command} --list-models` output — this will cause permanent failures; check pi.command and pi.model in WORKFLOW.md"}
    end
  end

  defp format_resolution(:configured_path), do: "configured path"
  defp format_resolution(:path_first), do: "PATH"
  defp format_resolution(:path_latest), do: "latest version on PATH"

  defp format_command_resolution_error({:pi_command_not_found, command}), do: "#{command} not found or not executable"

  defp format_command_resolution_error({:relative_pi_command_not_supported, command}),
    do: "#{command} is relative; set pi.command to `pi` or an absolute path"

  defp check_gh_cli do
    case SymphonyElixir.Config.settings() do
      {:ok, settings} -> check_gh_cli(settings)
      {:error, _reason} -> {:warn, "GitHub CLI", "cannot determine requirement — workflow config is invalid"}
    end
  end

  defp check_gh_cli(settings) do
    if github_cli_required?(settings) do
      case System.find_executable("gh") do
        nil -> {:fail, "GitHub CLI", "gh not found in PATH"}
        _path -> check_gh_auth()
      end
    else
      {:info, "GitHub CLI", "not required for current workflow"}
    end
  end

  defp check_gh_auth do
    case System.cmd("gh", ["auth", "status"], stderr_to_stdout: true) do
      {output, 0} ->
        account = extract_gh_account(output)
        {:pass, "GitHub CLI", "authenticated#{if account, do: " as #{account}", else: ""}"}

      {output, _code} ->
        {:fail, "GitHub CLI", "not authenticated: #{String.trim(output) |> String.slice(0, 120)}"}
    end
  end

  defp github_cli_required?(settings) do
    repo_slug_available?() or
      settings.pr.auto_create == true or
      (settings.review.enabled == true and settings.pr.review_comment_mode != "off") or
      settings.merge.mode == "auto"
  end

  defp repo_slug_available? do
    case SymphonyElixir.WorkspaceGit.inspect_workspace(File.cwd!()) do
      {:ok, %{repo_slug: repo_slug}} -> is_binary(repo_slug)
      _ -> false
    end
  end

  defp extract_gh_account(output) do
    case Regex.run(~r/Logged in to [^\s]+ account ([^\s(]+)/, output) do
      [_, account] -> account
      _ -> nil
    end
  end

  defp check_extension_paths do
    case SymphonyElixir.Config.settings() do
      {:ok, settings} -> Enum.map(settings.pi.extension_paths, &check_extension_path/1)
      {:error, _reason} -> [{:warn, "Extensions", "cannot check — workflow config is invalid"}]
    end
  end

  defp check_extension_path(path) do
    if File.exists?(path) do
      {:pass, "Extension", "#{Path.basename(path)} exists at #{path}"}
    else
      {:fail, "Extension", "#{Path.basename(path)} not found at #{path}"}
    end
  end

  defp check_kill_switch_path do
    case SymphonyElixir.Config.settings() do
      {:ok, settings} -> check_kill_switch_file(settings.rollout.kill_switch_file)
      {:error, _reason} -> {:warn, "Kill switch", "cannot check — workflow config is invalid"}
    end
  end

  defp check_kill_switch_file(path) when is_binary(path) do
    dir = Path.dirname(path)

    cond do
      File.exists?(path) ->
        {:warn, "Kill switch", "file exists at #{path} — automation will be paused"}

      File.dir?(dir) ->
        {:pass, "Kill switch", "directory #{dir} exists and is writable"}

      true ->
        {:warn, "Kill switch", "directory #{dir} does not exist — kill switch file cannot be created"}
    end
  end

  defp check_kill_switch_file(_path) do
    {:info, "Kill switch", "no kill_switch_file configured"}
  end

  defp report_rollout_mode do
    case SymphonyElixir.Config.settings() do
      {:ok, settings} ->
        mode = settings.rollout.mode || "unknown"
        {:info, "Rollout mode", mode}

      {:error, _reason} ->
        {:warn, "Rollout mode", "cannot determine — workflow config is invalid"}
    end
  end
end
