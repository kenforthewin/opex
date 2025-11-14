defmodule OpEx.Hooks do
  @moduledoc """
  Documentation for OpEx hooks system.

  Hooks allow you to customize OpEx behavior at key points in the chat loop
  without modifying the library code. This enables integration with your
  application's specific needs (e.g., database persistence, logging, metrics).

  ## Available Hooks

  ### custom_tool_executor

  Called when a custom tool needs to be executed.

  **Signature:** `(tool_name :: String.t(), args :: map(), context :: any()) :: {:ok, result :: any()} | {:error, reason :: any()}`

  **Example:**

      def execute_tool(tool_name, args, context) do
        case tool_name do
          "search_database" ->
            results = MyApp.Database.search(args["query"])
            {:ok, %{"results" => results}}

          "send_email" ->
            MyApp.Email.send(args["to"], args["subject"], args["body"])
            {:ok, %{"status" => "sent"}}

          _ ->
            {:error, :tool_not_found}
        end
      end

      session = OpEx.Chat.new(client, custom_tool_executor: &execute_tool/3)

  ### on_assistant_message

  Called after receiving an assistant message (with or without tool calls).

  **Signature:** `(message :: map(), context :: any()) :: :ok | {:ok, updated_context :: any()}`

  **Example:**

      def save_message(message, context) do
        %{"role" => "assistant", "content" => content} = message
        tool_calls = Map.get(message, "tool_calls", [])

        MyApp.Chat.create_message(%{
          conversation_id: context.conversation_id,
          role: "assistant",
          content: content,
          tool_calls: tool_calls
        })

        :ok
      end

      session = OpEx.Chat.new(client, on_assistant_message: &save_message/2)

  ### on_tool_result

  Called after a tool has been executed and a result is available.

  **Signature:** `(tool_call_id :: String.t(), tool_name :: String.t(), result :: any(), context :: any()) :: :ok | {:ok, updated_context :: any()}`

  **Example:**

      def log_tool_result(tool_call_id, tool_name, result, context) do
        MyApp.ToolLog.create(%{
          conversation_id: context.conversation_id,
          tool_call_id: tool_call_id,
          tool_name: tool_name,
          result: result,
          timestamp: DateTime.utc_now()
        })

        :ok
      end

      session = OpEx.Chat.new(client, on_tool_result: &log_tool_result/4)

  ## Context Management

  The `context` parameter is an arbitrary value that you provide when calling `OpEx.Chat.chat/2`
  and is threaded through all hooks. This allows you to pass application-specific data
  (like user IDs, conversation IDs, etc.) to your hooks.

  Hooks can return `{:ok, updated_context}` to modify the context for subsequent hooks.

  **Example:**

      def track_tool_count(_tool_call_id, _tool_name, _result, context) do
        count = Map.get(context, :tool_count, 0)
        {:ok, Map.put(context, :tool_count, count + 1)}
      end

      {:ok, response} = OpEx.Chat.chat(session,
        model: "anthropic/claude-3.5-sonnet",
        messages: messages,
        context: %{conversation_id: 123, tool_count: 0}
      )

  ## Complete Example

      defmodule MyApp.Agent do
        def run(conversation_id, user_message) do
          # Setup
          client = OpEx.Client.new(api_key())
          {:ok, mcp_pid} = OpEx.MCP.SessionManager.add_server(MyApp.MCPManager, mcp_config())

          # Create session with hooks
          session = OpEx.Chat.new(client,
            mcp_clients: [{:ok, mcp_pid}],
            custom_tools: custom_tools(),
            custom_tool_executor: &execute_custom_tool/3,
            on_assistant_message: &save_assistant_message/2,
            on_tool_result: &save_tool_result/4
          )

          # Execute conversation
          context = %{conversation_id: conversation_id}

          OpEx.Chat.chat(session,
            model: "anthropic/claude-3.5-sonnet",
            messages: [%{"role" => "user", "content" => user_message}],
            system_prompt: "You are a helpful assistant",
            context: context
          )
        end

        defp execute_custom_tool("search", args, _context) do
          results = search_documents(args["query"])
          {:ok, %{"results" => results}}
        end

        defp execute_custom_tool(_, _, _), do: {:error, :tool_not_found}

        defp save_assistant_message(message, context) do
          create_message(context.conversation_id, "assistant", message["content"])
          :ok
        end

        defp save_tool_result(tool_call_id, tool_name, result, context) do
          log_tool_call(context.conversation_id, tool_call_id, tool_name, result)
          :ok
        end
      end
  """
end
