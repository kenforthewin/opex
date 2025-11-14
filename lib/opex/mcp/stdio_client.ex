defmodule OpEx.MCP.StdioClient do
  @moduledoc """
  MCP (Model Context Protocol) client for interacting with MCP servers via stdio.
  Provides functionality to connect to MCP servers, execute tools, and manage sessions.
  """

  use GenServer
  require Logger

  defstruct [:server_config, :port, :session_id, :tools, :status]

  @doc """
  Starts an MCP client with the given server configuration.

  ## Server Config

  * `:command` - The command to run the MCP server
  * `:args` - List of arguments for the command
  * `:env` - Environment variables (optional)
  """
  def start_link(server_config, opts \\ []) do
    GenServer.start_link(__MODULE__, server_config, opts)
  end

  @doc """
  Connects to the MCP server and initializes the session.
  """
  def connect(pid) do
    GenServer.call(pid, :connect, 10_000)
  end

  @doc """
  Lists available tools from the MCP server.
  """
  def list_tools(pid) do
    GenServer.call(pid, :list_tools)
  end

  @doc """
  Calls a tool on the MCP server with the given arguments.
  """
  def call_tool(pid, tool_name, args) do
    GenServer.call(pid, {:call_tool, tool_name, args}, 300_000)
  end

  @doc """
  Stops the MCP client and cleans up resources.
  """
  def stop(pid) do
    GenServer.stop(pid)
  end

  # GenServer callbacks

  @impl true
  def init(server_config) do
    state = %__MODULE__{
      server_config: server_config,
      port: nil,
      session_id: nil,
      tools: [],
      status: :disconnected
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:connect, _from, state) do
    case start_mcp_server(state.server_config) do
      {:ok, port} ->
        case initialize_session(port) do
          {:ok, session_id} ->
            new_state = %{state | port: port, session_id: session_id, status: :connected}
            {:reply, :ok, new_state}

          {:error, reason} ->
            Port.close(port)
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:list_tools, _from, %{status: :connected} = state) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => generate_id(),
      "method" => "tools/list",
      "params" => %{}
    }

    Logger.debug("Sending tools/list request: #{inspect(request)}")

    case send_mcp_request(state.port, request) do
      {:ok, response} ->
        Logger.debug("Received tools/list response: #{inspect(response)}")
        case Map.get(response, "error") do
          nil ->
            tools = get_in(response, ["result", "tools"]) || []
            Logger.debug("Extracted tools: #{inspect(tools)}")
            new_state = %{state | tools: tools}
            {:reply, {:ok, tools}, new_state}

          error ->
            Logger.warning("MCP server returned error for tools/list: #{inspect(error)}")
            {:reply, {:error, error}, state}
        end

      {:error, reason} ->
        Logger.warning("Failed to list tools: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:list_tools, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  @impl true
  def handle_call({:call_tool, tool_name, args}, _from, %{status: :connected} = state) do
    case send_mcp_request(state.port, %{
      "jsonrpc" => "2.0",
      "id" => generate_id(),
      "method" => "tools/call",
      "params" => %{
        "name" => tool_name,
        "arguments" => args
      }
    }) do
      {:ok, response} ->
        case Map.get(response, "error") do
          nil ->
            result = get_in(response, ["result"])
            # Check if the result contains an isError flag
            case get_in(result, ["isError"]) do
              true ->
                # Extract error message from content
                error_message = case get_in(result, ["content"]) do
                  [%{"text" => text} | _] -> text
                  content when is_binary(content) -> content
                  _ -> "Tool execution failed"
                end
                {:reply, {:error, error_message}, state}

              _ ->
                {:reply, {:ok, result}, state}
            end

          error ->
            {:reply, {:error, error}, state}
        end

      {:error, :timeout} ->
        # 5-minute timeout suggests operation was too slow, not necessarily a crash
        # Keep connection alive but return timeout error
        Logger.warning("MCP tool call timed out after 5 minutes: #{tool_name}")
        {:reply, {:error, :operation_timeout}, state}

      {:error, reason} ->
        # Check if this is a connection error that suggests server crash
        case reason do
          :invalid_json ->
            new_state = %{state | status: :disconnected}
            {:reply, {:error, :server_crashed}, new_state}
          _ ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:call_tool, _tool_name, _args}, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, data}}}, %{port: port} = state) do
    case Jason.decode(data) do
      {:ok, response} ->
        Logger.debug("Received MCP response: #{inspect(response)}")
        # Handle async responses if needed
        {:noreply, state}

      {:error, _} ->
        Logger.warning("Failed to decode MCP response: #{inspect(data)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, response} ->
        Logger.debug("Received MCP response: #{inspect(response)}")
        # Handle async responses if needed
        {:noreply, state}

      {:error, _} ->
        Logger.warning("Failed to decode MCP response: #{inspect(data)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    Logger.warning("MCP server exited: #{inspect(reason)}")
    new_state = %{state | port: nil, session_id: nil, status: :disconnected}
    {:noreply, new_state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{port: port} = _state) when is_port(port) do
    case Port.info(port) do
      nil ->
        :ok
      _ ->
        Port.close(port)
    end
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # Private functions

  defp start_mcp_server(config) do
    command = config["command"]
    args = config["args"] || []
    env = config["env"] || []

    # Convert env tuples from {String, String} to {charlist, charlist} for Port.open
    env_charlists = Enum.map(env, fn
      {key, value} when is_binary(key) and is_binary(value) ->
        {String.to_charlist(key), String.to_charlist(value)}
      {key, value} ->
        {key, value}
    end)

    port_opts = [
      :binary,
      :exit_status,
      {:line, 8192},  # Increased line buffer size
      {:env, env_charlists}
    ]

    try do
      port = Port.open({:spawn_executable, System.find_executable(command)},
                      [{:args, args} | port_opts])
      {:ok, port}
    rescue
      error ->
        {:error, "Failed to start MCP server: #{inspect(error)}"}
    end
  end

  defp initialize_session(port) do
    initialize_request = %{
      "jsonrpc" => "2.0",
      "id" => generate_id(),
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2024-11-05",
        "capabilities" => %{
          "tools" => %{}
        },
        "clientInfo" => %{
          "name" => "OpEx.MCPClient",
          "version" => "0.1.0"
        }
      }
    }

    case send_mcp_request(port, initialize_request) do
      {:ok, response} ->
        case Map.get(response, "error") do
          nil ->
            # Send the required 'initialized' notification after successful initialize
            initialized_notification = %{
              "jsonrpc" => "2.0",
              "method" => "notifications/initialized"
            }

            # Send notification (no response expected)
            json_notification = Jason.encode!(initialized_notification)
            Logger.debug("Sending initialized notification: #{json_notification}")
            Port.command(port, json_notification <> "\n")

            # Wait a moment for the server to process the initialized notification
            Process.sleep(100)

            session_id = get_in(response, ["result", "sessionId"]) || generate_id()
            {:ok, session_id}

          error ->
            {:error, error}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_mcp_request(port, request) do
    json_request = Jason.encode!(request)
    Logger.debug("Sending MCP request: #{json_request}")
    Port.command(port, json_request <> "\n")

    collect_response(port, "")
  end

  defp collect_response(port, buffer) do
    receive do
      {^port, {:data, {:eol, data}}} ->
        complete_data = buffer <> data
        Logger.debug("Received complete EOL data: #{inspect(complete_data)}")

        # Check if this looks like a JSON-RPC message
        case String.trim(complete_data) do
          "{" <> _ = json_data ->
            case Jason.decode(json_data) do
              {:ok, response} -> {:ok, response}
              {:error, reason} ->
                Logger.warning("Failed to decode JSON (EOL): #{inspect(json_data)}, reason: #{inspect(reason)}")
                {:error, :invalid_json}
            end

          log_message ->
            # This is a log message, not JSON-RPC, continue collecting
            Logger.debug("Ignoring log message: #{inspect(log_message)}")
            collect_response(port, "")
        end

      {^port, {:data, {:noeol, data}}} ->
        Logger.debug("Received partial data: #{inspect(data)}")
        collect_response(port, buffer <> data)

      {^port, {:data, data}} when is_binary(data) ->
        complete_data = buffer <> data
        Logger.debug("Received complete binary data: #{inspect(complete_data)}")

        # Check if this looks like a JSON-RPC message
        case String.trim(complete_data) do
          "{" <> _ = json_data ->
            case Jason.decode(json_data) do
              {:ok, response} -> {:ok, response}
              {:error, reason} ->
                Logger.warning("Failed to decode JSON (binary): #{inspect(json_data)}, reason: #{inspect(reason)}")
                {:error, :invalid_json}
            end

          log_message ->
            # This is a log message, not JSON-RPC, continue collecting
            Logger.debug("Ignoring log message: #{inspect(log_message)}")
            collect_response(port, "")
        end
    after
      300_000 ->
        {:error, :timeout}
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
