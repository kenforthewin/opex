defmodule OpEx.MCP.HttpClient do
  @moduledoc """
  MCP (Model Context Protocol) HTTP client following the 2025-03-26 specification.
  Supports streamable HTTP transport with session management and custom headers.
  """

  use GenServer
  require Logger

  defstruct [
    :base_url,
    :auth_token,
    :execution_id,
    :session_id,
    :req_client,
    :tools,
    :status,
    :server_config
  ]

  @doc """
  Starts an MCP HTTP client with the given server configuration.

  ## Server Config

  * `:url` - The HTTP endpoint URL (e.g., "http://localhost:3000/mcp")
  * `:auth_token` - Bearer token for Authorization header
  * `:execution_id` - Execution ID to include in Execution-Id header (optional)
  """
  def start_link(server_config, opts \\ []) do
    GenServer.start_link(__MODULE__, server_config, opts)
  end

  @doc """
  Connects to the MCP server and initializes the session.
  """
  def connect(pid) do
    GenServer.call(pid, :connect, 30_000)
  end

  @doc """
  Lists available tools from the MCP server.
  """
  def list_tools(pid) do
    GenServer.call(pid, :list_tools, 30_000)
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
    base_url = server_config["url"]
    auth_token = server_config["auth_token"]
    execution_id = server_config["execution_id"]

    if is_nil(base_url) || is_nil(auth_token) do
      {:stop, "HTTP MCP client requires 'url' and 'auth_token' in config"}
    else
      # Initialize Req client
      req_client = Req.new(base_url: base_url, receive_timeout: 300_000)

      state = %__MODULE__{
        base_url: base_url,
        auth_token: auth_token,
        execution_id: execution_id,
        session_id: nil,
        req_client: req_client,
        tools: [],
        status: :disconnected,
        server_config: server_config
      }

      {:ok, state}
    end
  end

  @impl true
  def handle_call(:connect, _from, state) do
    # Send initialize request
    request = %{
      "jsonrpc" => "2.0",
      "id" => generate_id(),
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-03-26",
        "capabilities" => %{"tools" => %{}},
        "clientInfo" => %{
          "name" => "OpEx.MCPClient",
          "version" => "0.1.0"
        }
      }
    }

    Logger.info("🔌 Connecting to HTTP MCP server: #{state.base_url}")

    case send_request(state, request) do
      {:ok, _response, response_headers} ->
        # Extract session ID from Mcp-Session-Id header
        session_id = extract_session_id(response_headers)

        if session_id do
          Logger.info("✅ Received session ID: #{session_id}")

          # Send initialized notification
          notification = %{
            "jsonrpc" => "2.0",
            "method" => "notifications/initialized"
          }

          new_state = %{state | session_id: session_id, status: :connected}

          case send_notification(new_state, notification) do
            :ok ->
              Logger.info("✅ Connected to HTTP MCP server")
              {:reply, :ok, new_state}

            {:error, reason} ->
              Logger.error("❌ Failed to send initialized notification: #{inspect(reason)}")
              {:reply, {:error, reason}, state}
          end
        else
          Logger.error("❌ No session ID in response headers")
          {:reply, {:error, "No session ID received from server"}, state}
        end

      {:error, reason} ->
        Logger.error("❌ Failed to connect: #{inspect(reason)}")
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

    Logger.debug("Listing tools from HTTP MCP server")

    case send_request(state, request) do
      {:ok, response, _headers} ->
        case Map.get(response, "error") do
          nil ->
            tools = get_in(response, ["result", "tools"]) || []
            Logger.debug("Received #{length(tools)} tools from HTTP MCP server")
            new_state = %{state | tools: tools}
            {:reply, {:ok, tools}, new_state}

          error ->
            Logger.warning("MCP server returned error for tools/list: #{inspect(error)}")
            {:reply, {:error, error}, state}
        end

      {:error, %{status: 404}} ->
        # Session expired
        Logger.warning("Session expired (404), marking as disconnected")
        {:reply, {:error, :session_expired}, %{state | status: :disconnected, session_id: nil}}

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
    request = %{
      "jsonrpc" => "2.0",
      "id" => generate_id(),
      "method" => "tools/call",
      "params" => %{
        "name" => tool_name,
        "arguments" => args
      }
    }

    # Add Execution-Id header if we have one
    extra_headers = if state.execution_id do
      [{"Execution-Id", state.execution_id}]
    else
      []
    end

    Logger.debug("Calling tool #{tool_name} on HTTP MCP server")

    case send_request(state, request, extra_headers) do
      {:ok, response, _headers} ->
        case Map.get(response, "error") do
          nil ->
            result = get_in(response, ["result"])

            # Check if the result contains an isError flag (same logic as stdio client)
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

      {:error, %{status: 404}} ->
        # Session expired
        Logger.warning("Session expired (404) during tool call, reconnecting required")
        {:reply, {:error, :session_expired}, %{state | status: :disconnected, session_id: nil}}

      {:error, reason} ->
        Logger.warning("Tool call failed: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:call_tool, _tool_name, _args}, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  # Private functions

  defp send_request(state, json_rpc_request, extra_headers \\ []) do
    base_headers = [
      {"Content-Type", "application/json"},
      {"Accept", "application/json, text/event-stream"},
      {"Authorization", "Bearer #{state.auth_token}"}
    ]

    # Add session ID if we have one
    session_headers = if state.session_id do
      [{"Mcp-Session-Id", state.session_id}]
    else
      []
    end

    all_headers = base_headers ++ session_headers ++ extra_headers

    Logger.debug("Sending HTTP MCP request: #{inspect(json_rpc_request)}")

    case Req.post(state.req_client,
      json: json_rpc_request,
      headers: all_headers
    ) do
      {:ok, %{status: 200, body: body, headers: headers}} ->
        Logger.debug("Received 200 OK response")

        # Handle SSE format if body is a string starting with "event:"
        parsed_body = case body do
          "event: " <> _ = sse_data ->
            parse_sse_response(sse_data)
          _ ->
            body
        end

        {:ok, parsed_body, headers}

      {:ok, %{status: 202}} ->
        # Accepted (notification response)
        Logger.debug("Received 202 Accepted")
        {:ok, %{}, []}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Received HTTP #{status}: #{inspect(body)}")
        {:error, %{status: status, body: body}}

      {:error, reason} ->
        Logger.error("HTTP request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp send_notification(state, notification) do
    base_headers = [
      {"Content-Type", "application/json"},
      {"Accept", "application/json, text/event-stream"},
      {"Authorization", "Bearer #{state.auth_token}"}
    ]

    # Add session ID if we have one
    session_headers = if state.session_id do
      [{"Mcp-Session-Id", state.session_id}]
    else
      []
    end

    all_headers = base_headers ++ session_headers

    Logger.debug("Sending HTTP MCP notification: #{inspect(notification)}")

    case Req.post(state.req_client,
      json: notification,
      headers: all_headers
    ) do
      {:ok, %{status: 202}} ->
        Logger.debug("Notification accepted (202)")
        :ok

      {:ok, %{status: 200}} ->
        Logger.debug("Notification acknowledged (200)")
        :ok

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Notification failed with HTTP #{status}: #{inspect(body)}")
        {:error, %{status: status, body: body}}

      {:error, reason} ->
        Logger.error("Notification HTTP request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp extract_session_id(headers) do
    headers
    |> Enum.find(fn {key, _value} -> String.downcase(key) == "mcp-session-id" end)
    |> case do
      {_key, value} when is_list(value) -> List.first(value)
      {_key, value} when is_binary(value) -> value
      nil -> nil
    end
  end

  defp parse_sse_response(sse_data) do
    # Parse Server-Sent Events format:
    # event: message
    # data: {"jsonrpc":"2.0",...}
    #
    # Extract the data line and parse as JSON
    sse_data
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case line do
        "data: " <> json_str -> Jason.decode(json_str)
        _ -> nil
      end
    end)
    |> case do
      {:ok, parsed} -> parsed
      nil -> %{}  # Return empty map if no data line found
      {:error, _} -> %{}  # Return empty map if JSON parsing failed
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
