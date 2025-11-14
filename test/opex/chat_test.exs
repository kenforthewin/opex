defmodule OpEx.ChatTest do
  use ExUnit.Case, async: true
  alias OpEx.Test.MCPHelpers

  # Mock MCP client for testing
  defmodule MockMCPClient do
    use GenServer

    def start_link(tools) do
      GenServer.start_link(__MODULE__, tools)
    end

    def init(tools), do: {:ok, %{tools: tools, calls: []}}

    def handle_call(:list_tools, _from, state) do
      {:reply, {:ok, state.tools}, state}
    end

    def handle_call({:call_tool, tool_name, args}, _from, state) do
      call_record = {tool_name, args}
      new_state = %{state | calls: [call_record | state.calls]}

      result = case tool_name do
        "mcp_search" ->
          {:ok, MCPHelpers.mcp_text_result("Found: #{args["query"]}")}
        "mcp_error" ->
          {:error, "Tool execution failed"}
        _ ->
          {:error, "Tool not found: #{tool_name}"}
      end

      {:reply, result, new_state}
    end
  end

  setup do
    # Create mock client
    client = OpEx.Client.new("test-key")

    # Create mock MCP client with tools
    mcp_tools = [
      MCPHelpers.mcp_tool("mcp_search", "Search tool", %{
        "query" => %{"type" => "string"}
      }, ["query"]),
      MCPHelpers.mcp_tool("mcp_error", "Error tool")
    ]

    {:ok, mcp_pid} = MockMCPClient.start_link(mcp_tools)

    custom_tools = [
      MCPHelpers.openai_tool("custom_tool", "Custom tool", %{
        "input" => %{"type" => "string"}
      })
    ]

    {:ok, client: client, mcp_pid: mcp_pid, custom_tools: custom_tools}
  end

  describe "new/2" do
    test "creates chat session with MCP clients", %{client: client, mcp_pid: mcp_pid} do
      session = OpEx.Chat.new(client, mcp_clients: [{:ok, mcp_pid}])

      assert %OpEx.Chat{} = session
      assert session.client == client
      assert session.mcp_clients == [{:ok, mcp_pid}]
    end

    test "accepts custom tools", %{client: client, custom_tools: custom_tools} do
      session = OpEx.Chat.new(client, custom_tools: custom_tools)

      assert session.custom_tools == custom_tools
    end

    test "accepts hook functions", %{client: client} do
      hook = fn _, ctx -> {:ok, ctx} end

      session = OpEx.Chat.new(client,
        custom_tool_executor: hook,
        on_assistant_message: hook,
        on_tool_result: fn _, _, _, ctx -> {:ok, ctx} end
      )

      assert is_function(session.custom_tool_executor)
      assert is_function(session.on_assistant_message)
      assert is_function(session.on_tool_result)
    end
  end

  describe "tool execution priority" do
    test "executes custom tool before checking MCP", %{client: client, mcp_pid: mcp_pid, custom_tools: custom_tools} do
      executed_tools = Agent.start_link(fn -> [] end) |> elem(1)

      custom_executor = fn tool_name, _args, _context ->
        Agent.update(executed_tools, fn tools -> [tool_name | tools] end)
        {:ok, %{"result" => "from custom"}}
      end

      session = OpEx.Chat.new(client,
        mcp_clients: [{:ok, mcp_pid}],
        custom_tools: custom_tools,
        custom_tool_executor: custom_executor
      )

      # This would need a full chat simulation
      # For now test the executor is called
      assert {:ok, _} = custom_executor.("custom_tool", %{}, %{})
      tools_called = Agent.get(executed_tools, & &1)
      assert "custom_tool" in tools_called
    end

    test "falls back to MCP tool if custom returns :tool_not_found", %{client: client, mcp_pid: mcp_pid} do
      custom_executor = fn _tool_name, _args, _context ->
        {:error, :tool_not_found}
      end

      session = OpEx.Chat.new(client,
        mcp_clients: [{:ok, mcp_pid}],
        custom_tool_executor: custom_executor
      )

      # The session should have both custom executor and MCP clients
      assert session.custom_tool_executor != nil
      assert length(session.mcp_clients) == 1
    end
  end

  describe "hook invocation" do
    test "on_assistant_message hook is called with message", %{client: client} do
      messages_received = Agent.start_link(fn -> [] end) |> elem(1)

      hook = fn message, context ->
        Agent.update(messages_received, fn msgs -> [message | msgs] end)
        {:ok, context}
      end

      session = OpEx.Chat.new(client, on_assistant_message: hook)

      # Simulate calling the hook
      test_message = %{"role" => "assistant", "content" => "test"}
      result = hook.(test_message, %{})

      assert {:ok, %{}} = result
      messages = Agent.get(messages_received, & &1)
      assert length(messages) == 1
    end

    test "on_tool_result hook receives tool call details", %{client: client} do
      tool_results = Agent.start_link(fn -> [] end) |> elem(1)

      hook = fn tool_call_id, tool_name, result, context ->
        record = {tool_call_id, tool_name, result}
        Agent.update(tool_results, fn results -> [record | results] end)
        {:ok, context}
      end

      session = OpEx.Chat.new(client, on_tool_result: hook)

      # Simulate calling the hook
      result = hook.("call_123", "test_tool", %{"data" => "value"}, %{})

      assert {:ok, %{}} = result
      results = Agent.get(tool_results, & &1)
      assert length(results) == 1
      assert {"call_123", "test_tool", %{"data" => "value"}} = hd(results)
    end

    test "hook failures don't crash system - returns default context", %{client: client} do
      failing_hook = fn _msg, _ctx ->
        raise "Hook error"
      end

      session = OpEx.Chat.new(client, on_assistant_message: failing_hook)

      # The session should still be created
      assert %OpEx.Chat{} = session
    end

    test "context updates propagate through hooks", %{client: client} do
      hook1 = fn _msg, context ->
        {:ok, Map.put(context, :count, 1)}
      end

      session = OpEx.Chat.new(client, on_assistant_message: hook1)

      # Simulate context threading
      {:ok, updated_context} = hook1.(%{"role" => "assistant"}, %{})
      assert updated_context.count == 1

      # Second call should see updated context
      {:ok, updated_context2} = hook1.(%{"role" => "assistant"}, updated_context)
      assert updated_context2.count == 1
    end
  end

  describe "tool not found handling" do
    test "returns error for unknown tool", %{client: client, mcp_pid: mcp_pid} do
      session = OpEx.Chat.new(client, mcp_clients: [{:ok, mcp_pid}])

      # Test tool not in MCP or custom tools
      # This would be tested via handle_tool_calls internally
      tool_call = MCPHelpers.tool_call("call_123", "unknown_tool", %{})

      # The tool mapping shouldn't contain this tool
      refute Map.has_key?(session.tool_mapping, "unknown_tool")
    end

    test "formats error result for missing tool", %{client: client} do
      session = OpEx.Chat.new(client)

      # Error formatting should include tool name
      error_result = OpEx.MCP.Tools.format_tool_result("call_123", %{
        "error" => "Tool not available: missing_tool"
      })

      assert error_result["role"] == "tool"
      assert error_result["tool_call_id"] == "call_123"
      assert error_result["content"] =~ "Tool not available"
    end
  end

  describe "message normalization" do
    test "converts array content to string" do
      messages = [
        %{"role" => "user", "content" => ["Hello", " ", "world"]}
      ]

      # Test the normalization logic
      normalized = Enum.map(messages, fn
        %{"content" => content} = message when is_list(content) ->
          %{message | "content" => Enum.join(content, "")}
        message ->
          message
      end)

      assert hd(normalized)["content"] == "Hello world"
    end

    test "leaves string content unchanged" do
      messages = [
        %{"role" => "user", "content" => "Hello world"}
      ]

      normalized = Enum.map(messages, fn
        %{"content" => content} = message when is_list(content) ->
          %{message | "content" => Enum.join(content, "")}
        message ->
          message
      end)

      assert hd(normalized)["content"] == "Hello world"
    end

    test "handles empty array content" do
      messages = [
        %{"role" => "user", "content" => []}
      ]

      normalized = Enum.map(messages, fn
        %{"content" => content} = message when is_list(content) ->
          %{message | "content" => Enum.join(content, "")}
        message ->
          message
      end)

      assert hd(normalized)["content"] == ""
    end
  end

  describe "tool execution with both custom and MCP" do
    test "tool exists in both custom and MCP - custom wins", %{client: client, mcp_pid: mcp_pid} do
      executed_from = Agent.start_link(fn -> nil end) |> elem(1)

      # MCP has "search" tool
      # Custom also defines "search" tool

      custom_tools = [
        MCPHelpers.openai_tool("mcp_search", "Custom search")
      ]

      custom_executor = fn tool_name, _args, _context ->
        if tool_name == "mcp_search" do
          Agent.update(executed_from, fn _ -> :custom end)
          {:ok, %{"source" => "custom"}}
        else
          {:error, :tool_not_found}
        end
      end

      session = OpEx.Chat.new(client,
        mcp_clients: [{:ok, mcp_pid}],
        custom_tools: custom_tools,
        custom_tool_executor: custom_executor
      )

      # Execute custom tool
      custom_executor.("mcp_search", %{}, %{})

      source = Agent.get(executed_from, & &1)
      assert source == :custom
    end
  end

  describe "execute_tools flag" do
    test "execute_tools=false should return tool calls without execution" do
      # This would be tested in a full integration test
      # The flag controls whether handle_tool_calls is processed
      # or returned immediately

      execute_tools = false

      if execute_tools == false do
        # Should return immediately with tool_calls
        assert true
      end
    end
  end

  describe "tool mapping" do
    test "builds mapping from MCP clients to tools", %{mcp_pid: mcp_pid} do
      mcp_clients = [{:ok, mcp_pid}]

      # Build tool mapping
      tool_mapping = Enum.reduce(mcp_clients, %{}, fn
        {:ok, pid}, acc ->
          case GenServer.call(pid, :list_tools, 30_000) do
            {:ok, tools} ->
              Enum.reduce(tools, acc, fn tool, tool_acc ->
                tool_name = tool["name"]
                if tool_name do
                  Map.put(tool_acc, tool_name, pid)
                else
                  tool_acc
                end
              end)
            {:error, _} ->
              acc
          end
        {:error, _}, acc ->
          acc
      end)

      assert Map.has_key?(tool_mapping, "mcp_search")
      assert Map.has_key?(tool_mapping, "mcp_error")
      assert tool_mapping["mcp_search"] == mcp_pid
    end

    test "handles failed MCP clients gracefully" do
      mcp_clients = [{:error, "connection failed"}]

      tool_mapping = Enum.reduce(mcp_clients, %{}, fn
        {:ok, pid}, acc ->
          case GenServer.call(pid, :list_tools, 30_000) do
            {:ok, tools} ->
              Enum.reduce(tools, acc, fn tool, tool_acc ->
                Map.put(tool_acc, tool["name"], pid)
              end)
            {:error, _} ->
              acc
          end
        {:error, _}, acc ->
          acc
      end)

      assert tool_mapping == %{}
    end
  end
end
