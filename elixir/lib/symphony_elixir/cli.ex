defmodule SymphonyElixir.CLI do
  @moduledoc """
  Escript entrypoint for running Symphony with an explicit WORKFLOW.md path.
  """

  alias SymphonyElixir.LogFile

  @acknowledgement_switch :i_understand_that_this_will_be_running_without_the_usual_guardrails
  @switches [{@acknowledgement_switch, :boolean}, logs_root: :string, port: :integer]
  @manual_switches [server: :string]
  @default_manual_server "http://127.0.0.1:4040"

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type deps :: %{
          file_regular?: (String.t() -> boolean()),
          load_json_file: (String.t() -> {:ok, map()} | {:error, term()}),
          submit_manual_issue: (String.t(), map() -> {:ok, map()} | {:error, term()}),
          set_workflow_file_path: (String.t() -> :ok | {:error, term()}),
          set_logs_root: (String.t() -> :ok | {:error, term()}),
          set_server_port_override: (non_neg_integer() | nil -> :ok | {:error, term()}),
          ensure_all_started: (-> ensure_started_result())
        }

  @spec main([String.t()]) :: no_return()
  def main(args) do
    case run_main(args, runtime_deps(), &wait_for_shutdown/0, fn message ->
           IO.puts(:stderr, message)
           System.halt(1)
         end) do
      %{} = payload ->
        IO.puts(Jason.encode!(payload))
        System.halt(0)

      _other ->
        System.halt(0)
    end
  end

  @spec evaluate([String.t()], deps()) :: :ok | {:error, String.t()}
  def evaluate(args, deps \\ runtime_deps()) do
    case args do
      ["manual", "submit" | rest] ->
        evaluate_manual_submit(rest, deps)

      _ ->
        case OptionParser.parse(args, strict: @switches) do
          {opts, [], []} ->
            with :ok <- require_guardrails_acknowledgement(opts),
                 :ok <- maybe_set_logs_root(opts, deps),
                 :ok <- maybe_set_server_port(opts, deps) do
              run(Path.expand("WORKFLOW.md"), deps)
            end

          {opts, [workflow_path], []} ->
            with :ok <- require_guardrails_acknowledgement(opts),
                 :ok <- maybe_set_logs_root(opts, deps),
                 :ok <- maybe_set_server_port(opts, deps) do
              run(workflow_path, deps)
            end

          _ ->
            {:error, usage_message()}
        end
    end
  end

  @spec evaluate_manual_submit([String.t()], deps()) :: {:ok, map()} | {:error, String.t()}
  def evaluate_manual_submit(args, deps) do
    case OptionParser.parse(args, strict: @manual_switches) do
      {opts, [spec_path], []} ->
        server_url = Keyword.get(opts, :server, @default_manual_server)

        with {:ok, payload} <- deps.load_json_file.(Path.expand(spec_path)),
             {:ok, response} <- deps.submit_manual_issue.(server_url, payload) do
          {:ok, response}
        else
          {:error, reason} -> {:error, manual_submit_error(reason)}
        end

      _ ->
        {:error, manual_usage_message()}
    end
  end

  @spec run(String.t(), deps()) :: :ok | {:error, String.t()}
  def run(workflow_path, deps) do
    expanded_path = Path.expand(workflow_path)

    if deps.file_regular?.(expanded_path) do
      :ok = deps.set_workflow_file_path.(expanded_path)

      case deps.ensure_all_started.() do
        {:ok, _started_apps} ->
          :ok

        {:error, reason} ->
          {:error, "Failed to start Symphony with workflow #{expanded_path}: #{inspect(reason)}"}
      end
    else
      {:error, "Workflow file not found: #{expanded_path}"}
    end
  end

  @doc false
  @spec main_result_for_test([String.t()], deps(), (-> term())) :: :ok | {:error, String.t()} | term()
  def main_result_for_test(args, deps \\ runtime_deps(), wait_fun \\ fn -> :ok end) do
    run_main(args, deps, wait_fun, fn message -> {:error, message} end)
  end

  @doc false
  @spec wait_for_shutdown_result_for_test(GenServer.name() | pid(), (pid() -> term()) | nil) ::
          {:ok, :normal} | {:error, term()}
  def wait_for_shutdown_result_for_test(
        supervisor \\ SymphonyElixir.Supervisor,
        on_monitor \\ nil
      ) do
    wait_for_shutdown_result(supervisor, on_monitor)
  end

  @spec usage_message() :: String.t()
  defp usage_message do
    "Usage: symphony [--logs-root <path>] [--port <port>] [path-to-WORKFLOW.md]"
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      file_regular?: &File.regular?/1,
      load_json_file: &load_json_file/1,
      submit_manual_issue: &submit_manual_issue_http/2,
      set_workflow_file_path: &SymphonyElixir.Workflow.set_workflow_file_path/1,
      set_logs_root: &set_logs_root/1,
      set_server_port_override: &set_server_port_override/1,
      ensure_all_started: fn -> Application.ensure_all_started(:symphony_elixir) end
    }
  end

  defp maybe_set_logs_root(opts, deps) do
    case Keyword.get_values(opts, :logs_root) do
      [] ->
        :ok

      values ->
        logs_root = values |> List.last() |> String.trim()

        if logs_root == "" do
          {:error, usage_message()}
        else
          :ok = deps.set_logs_root.(Path.expand(logs_root))
        end
    end
  end

  defp require_guardrails_acknowledgement(opts) do
    if Keyword.get(opts, @acknowledgement_switch, false) do
      :ok
    else
      {:error, acknowledgement_banner()}
    end
  end

  @spec acknowledgement_banner() :: String.t()
  defp acknowledgement_banner do
    lines = [
      "This Symphony implementation is a low key engineering preview.",
      "Codex will run without any guardrails.",
      "SymphonyElixir is not a supported product and is presented as-is.",
      "To proceed, start with `--i-understand-that-this-will-be-running-without-the-usual-guardrails` CLI argument"
    ]

    width = Enum.max(Enum.map(lines, &String.length/1))
    border = String.duplicate("─", width + 2)
    top = "╭" <> border <> "╮"
    bottom = "╰" <> border <> "╯"
    spacer = "│ " <> String.duplicate(" ", width) <> " │"

    content =
      [
        top,
        spacer
        | Enum.map(lines, fn line ->
            "│ " <> String.pad_trailing(line, width) <> " │"
          end)
      ] ++ [spacer, bottom]

    [
      IO.ANSI.red(),
      IO.ANSI.bright(),
      Enum.join(content, "\n"),
      IO.ANSI.reset()
    ]
    |> IO.iodata_to_binary()
  end

  defp set_logs_root(logs_root) do
    Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(logs_root))
    :ok
  end

  defp maybe_set_server_port(opts, deps) do
    case Keyword.get_values(opts, :port) do
      [] ->
        :ok

      values ->
        port = List.last(values)

        if is_integer(port) and port >= 0 do
          :ok = deps.set_server_port_override.(port)
        else
          {:error, usage_message()}
        end
    end
  end

  defp set_server_port_override(port) when is_integer(port) and port >= 0 do
    Application.put_env(:symphony_elixir, :server_port_override, port)
    :ok
  end

  defp run_main(args, deps, wait_fun, error_handler)
       when is_list(args) and is_map(deps) and is_function(wait_fun, 0) and is_function(error_handler, 1) do
    case evaluate(args, deps) do
      :ok -> wait_fun.()
      {:ok, payload} -> payload
      {:error, message} -> error_handler.(message)
    end
  end

  defp manual_usage_message do
    "Usage: symphony manual submit /path/to/issue.json [--server <url>]"
  end

  defp manual_submit_error(reason) when is_binary(reason), do: reason
  defp manual_submit_error(reason), do: "Manual submission failed: #{inspect(reason)}"

  defp load_json_file(path) when is_binary(path) do
    with {:ok, payload} <- File.read(path),
         {:ok, decoded} <- Jason.decode(payload),
         true <- is_map(decoded) or {:error, :invalid_json_payload} do
      {:ok, decoded}
    else
      false -> {:error, :invalid_json_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp submit_manual_issue_http(server_url, payload)
       when is_binary(server_url) and is_map(payload) do
    with {:ok, _started} <- Application.ensure_all_started(:req) do
      do_submit_manual_issue_http(server_url, payload)
    end
  end

  defp do_submit_manual_issue_http(server_url, payload)
       when is_binary(server_url) and is_map(payload) do
    url = String.trim_trailing(server_url, "/") <> "/api/v1/manual-runs"

    case Req.post(url: url, json: payload) do
      {:ok, %Req.Response{status: status, body: body}}
      when status in 200..299 and is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{body: %{"error" => %{"message" => message}}}} ->
        {:error, message}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec wait_for_shutdown() :: no_return()
  defp wait_for_shutdown do
    case wait_for_shutdown_result(SymphonyElixir.Supervisor, nil) do
      {:error, :not_running} ->
        if symphony_application_running?() do
          IO.puts(:stderr, "Symphony supervisor is not running")
          System.halt(1)
        else
          System.halt(0)
        end

      {:ok, :normal} ->
        System.halt(0)

      {:error, _reason} ->
        System.halt(1)
    end
  end

  defp wait_for_shutdown_result(supervisor, on_monitor) do
    case supervisor_pid(supervisor) do
      nil ->
        {:error, :not_running}

      pid ->
        ref = Process.monitor(pid)
        if is_function(on_monitor, 1), do: on_monitor.(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} ->
            case reason do
              :normal -> {:ok, :normal}
              _ -> {:error, reason}
            end
        end
    end
  end

  defp supervisor_pid(supervisor) when is_pid(supervisor), do: supervisor
  defp supervisor_pid(supervisor), do: Process.whereis(supervisor)

  defp symphony_application_running? do
    Enum.any?(Application.started_applications(), fn
      {:symphony_elixir, _, _} -> true
      _ -> false
    end)
  end
end
