defmodule OpEx.MCP.SessionManager do
  @moduledoc """
  Manages multiple MCP client sessions with automatic reconnection and health monitoring.
  Supports both stdio and HTTP transports.
  """

  use GenServer
  require Logger

  defstruct [:sessions, :configs, :health_check_interval]

  # 5 minutes
  @default_health_check_interval 300_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Adds a new MCP server configuration and starts the client.
  """
  def add_server(server_name \\ __MODULE__, server_config, opts \\ []) do
    GenServer.call(server_name, {:add_server, server_config, opts})
  end

  @doc """
  Removes an MCP server and stops its client.
  """
  def remove_server(server_name \\ __MODULE__, server_id) do
    GenServer.call(server_name, {:remove_server, server_id})
  end

  @doc """
  Lists all active MCP sessions with their status.
  """
  def list_sessions(server_name \\ __MODULE__) do
    GenServer.call(server_name, :list_sessions)
  end

  @doc """
  Gets all available tools from all active MCP sessions.
  """
  def get_all_tools(server_name \\ __MODULE__) do
    GenServer.call(server_name, :get_all_tools)
  end

  @doc """
  Executes a tool call on the appropriate MCP server.
  """
  def call_tool(server_name \\ __MODULE__, tool_name, args) do
    GenServer.call(server_name, {:call_tool, tool_name, args}, 30_000)
  end

  @doc """
  Performs a health check on all sessions.
  """
  def health_check(server_name \\ __MODULE__) do
    GenServer.call(server_name, :health_check)
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    health_check_interval = Keyword.get(opts, :health_check_interval, @default_health_check_interval)

    state = %__MODULE__{
      sessions: %{},
      configs: %{},
      health_check_interval: health_check_interval
    }

    # Schedule health checks
    Process.send_after(self(), :health_check, health_check_interval)

    {:ok, state}
  end

  @impl true
  def handle_call({:add_server, server_config, _opts}, _from, state) do
    server_id = generate_server_id(server_config)

    case start_mcp_client(server_config) do
      {:ok, pid, client_module} ->
        new_sessions =
          Map.put(state.sessions, server_id, %{
            pid: pid,
            client_module: client_module,
            status: :connected,
            tools: [],
            last_health_check: System.monotonic_time(:millisecond)
          })

        new_configs = Map.put(state.configs, server_id, server_config)

        # Load tools for this session
        case client_module.list_tools(pid) do
          {:ok, tools} ->
            updated_sessions = put_in(new_sessions[server_id].tools, tools)
            new_state = %{state | sessions: updated_sessions, configs: new_configs}
            {:reply, {:ok, server_id}, new_state}

          {:error, reason} ->
            Logger.warning("Failed to load tools for MCP server #{server_id}: #{inspect(reason)}")
            new_state = %{state | sessions: new_sessions, configs: new_configs}
            {:reply, {:ok, server_id}, new_state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:remove_server, server_id}, _from, state) do
    case Map.get(state.sessions, server_id) do
      %{pid: pid, client_module: client_module} ->
        client_module.stop(pid)
        new_sessions = Map.delete(state.sessions, server_id)
        new_configs = Map.delete(state.configs, server_id)
        new_state = %{state | sessions: new_sessions, configs: new_configs}
        {:reply, :ok, new_state}

      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:list_sessions, _from, state) do
    sessions_info =
      Enum.map(state.sessions, fn {server_id, session} ->
        %{
          id: server_id,
          status: session.status,
          tools_count: length(session.tools),
          last_health_check: session.last_health_check
        }
      end)

    {:reply, sessions_info, state}
  end

  @impl true
  def handle_call(:get_all_tools, _from, state) do
    all_tools =
      state.sessions
      |> Enum.flat_map(fn {_id, session} ->
        if session.status == :connected do
          OpEx.MCP.Tools.convert_tools_to_openai_format(session.tools)
        else
          []
        end
      end)

    {:reply, all_tools, state}
  end

  @impl true
  def handle_call(:list_tools, _from, state) do
    # Return raw MCP tools (not OpenAI format) from all connected sessions
    # This is used by Chat's build_tool_mapping
    raw_tools =
      state.sessions
      |> Enum.flat_map(fn {_id, session} ->
        if session.status == :connected do
          session.tools
        else
          []
        end
      end)

    {:reply, {:ok, raw_tools}, state}
  end

  @impl true
  def handle_call({:call_tool, tool_name, args}, _from, state) do
    # Filter sessions to only those that have the requested tool
    sessions_with_tool =
      state.sessions
      |> Enum.filter(fn {_id, session} ->
        session.status == :connected &&
          Enum.any?(session.tools, fn tool -> tool["name"] == tool_name end)
      end)

    # If no sessions have this tool, return error immediately
    if Enum.empty?(sessions_with_tool) do
      {:reply, {:error, "Tool not found: #{tool_name}"}, state}
    else
      {result, updated_sessions} =
        sessions_with_tool
        |> Enum.reduce_while({nil, state.sessions}, fn {id, session}, {_acc_result, acc_sessions} ->
          case session.client_module.call_tool(session.pid, tool_name, args) do
            {:ok, result} ->
              {:halt, {{:ok, result}, acc_sessions}}

            {:error, :tool_not_found} ->
              # This shouldn't happen since we filtered, but handle it anyway
              {:cont, {nil, acc_sessions}}

            {:error, :server_crashed} ->
              # Server crashed, mark as disconnected and attempt immediate recovery
              Logger.warning("MCP server crashed during tool call, attempting immediate recovery")
              updated_session = %{session | status: :disconnected}
              new_sessions = Map.put(acc_sessions, id, updated_session)

              # Attempt immediate reconnection
              case attempt_reconnection(id, state.configs[id]) do
                {:ok, new_pid, client_module} ->
                  recovered_session = %{
                    updated_session
                    | pid: new_pid,
                      client_module: client_module,
                      status: :connected
                  }

                  final_sessions = Map.put(new_sessions, id, recovered_session)

                  # Retry the tool call on the recovered session
                  case client_module.call_tool(new_pid, tool_name, args) do
                    {:ok, result} -> {:halt, {{:ok, result}, final_sessions}}
                    {:error, _} -> {:cont, {nil, final_sessions}}
                  end

                {:error, _reason} ->
                  {:cont, {nil, new_sessions}}
              end

            {:error, :operation_timeout} ->
              # Operation took too long but server is likely still responsive
              Logger.warning("MCP tool operation timed out after 5 minutes: #{tool_name}")
              {:halt, {{:error, :operation_timeout}, acc_sessions}}

            {:error, reason} ->
              {:halt, {{:error, reason}, acc_sessions}}
          end
        end)

      new_state = %{state | sessions: updated_sessions}

      case result do
        nil -> {:reply, {:error, "Tool not found: #{tool_name}"}, new_state}
        result -> {:reply, result, new_state}
      end
    end
  end

  @impl true
  def handle_call(:health_check, _from, state) do
    {updated_sessions, health_status} = perform_health_check(state.sessions, state.configs)
    new_state = %{state | sessions: updated_sessions}
    {:reply, health_status, new_state}
  end

  @impl true
  def handle_info(:health_check, state) do
    {updated_sessions, _health_status} = perform_health_check(state.sessions, state.configs)
    new_state = %{state | sessions: updated_sessions}

    # Schedule next health check
    Process.send_after(self(), :health_check, state.health_check_interval)

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    Logger.warning("MCP client process died: #{inspect(reason)}")

    # Find and mark the session as disconnected
    updated_sessions =
      Enum.reduce(state.sessions, state.sessions, fn {id, session}, acc ->
        if session.pid == pid do
          Map.put(acc, id, %{session | status: :disconnected, pid: nil})
        else
          acc
        end
      end)

    new_state = %{state | sessions: updated_sessions}
    {:noreply, new_state}
  end

  # Private functions

  defp start_mcp_client(server_config) do
    # Determine client type from config
    {client_module, config} =
      case server_config do
        %{"url" => _} ->
          {OpEx.MCP.HttpClient, server_config}

        _ ->
          {OpEx.MCP.StdioClient, server_config}
      end

    case client_module.start_link(config) do
      {:ok, pid} ->
        Process.monitor(pid)

        case client_module.connect(pid) do
          :ok ->
            {:ok, pid, client_module}

          {:error, reason} ->
            client_module.stop(pid)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp generate_server_id(server_config) do
    # Normalize config for JSON encoding (convert env tuples to lists)
    normalized_config = normalize_config_for_json(server_config)
    config_string = Jason.encode!(normalized_config)

    :crypto.hash(:sha256, config_string)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 8)
  end

  defp normalize_config_for_json(config) when is_map(config) do
    Map.update(config, "env", [], fn env ->
      Enum.map(env, fn
        {key, value} -> [key, value]
        other -> other
      end)
    end)
  end

  defp perform_health_check(sessions, configs) do
    current_time = System.monotonic_time(:millisecond)

    {updated_sessions, health_status} =
      Enum.reduce(sessions, {%{}, %{}}, fn {id, session}, {acc_sessions, acc_health} ->
        {updated_session, health} = check_session_health(session, configs[id], current_time)

        {
          Map.put(acc_sessions, id, updated_session),
          Map.put(acc_health, id, health)
        }
      end)

    {updated_sessions, health_status}
  end

  defp check_session_health(
         %{status: :connected, pid: pid, client_module: client_module} = session,
         _config,
         current_time
       ) do
    case client_module.list_tools(pid) do
      {:ok, tools} ->
        updated_session = %{session | tools: tools, last_health_check: current_time, status: :connected}
        {updated_session, :healthy}

      {:error, reason} ->
        Logger.warning("Health check failed for MCP session: #{inspect(reason)}")
        updated_session = %{session | status: :disconnected, last_health_check: current_time}
        {updated_session, :unhealthy}
    end
  end

  defp check_session_health(%{status: :disconnected} = session, config, current_time) do
    # Attempt to reconnect
    case start_mcp_client(config) do
      {:ok, pid, client_module} ->
        updated_session = %{
          session
          | pid: pid,
            client_module: client_module,
            status: :connected,
            last_health_check: current_time
        }

        {updated_session, :reconnected}

      {:error, _reason} ->
        updated_session = %{session | last_health_check: current_time}
        {updated_session, :failed_reconnect}
    end
  end

  defp attempt_reconnection(_session_id, config) do
    case start_mcp_client(config) do
      {:ok, pid, client_module} -> {:ok, pid, client_module}
      {:error, reason} -> {:error, reason}
    end
  end
end
