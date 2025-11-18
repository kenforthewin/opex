defmodule OpEx.Chat do
  @moduledoc """
  Chat interface with tool calling support and customizable hooks.

  This module provides a flexible chat loop that can be customized via hooks for:
  - Custom tool execution
  - Message persistence
  - Tool result handling

  MCP tools are handled automatically via the provided MCP client PIDs.
  """

  require Logger

  defstruct [
    :client,
    :mcp_clients,
    :custom_tools,
    :rejected_tools,
    :tool_mapping,
    :custom_tool_executor,
    :on_assistant_message,
    :on_tool_result
  ]

  @doc """
  Creates a new chat session.

  ## Options

  * `:mcp_clients` - List of `{:ok, pid}` or `{:error, reason}` tuples for MCP clients
  * `:custom_tools` - List of custom tool definitions in OpenAI format
  * `:rejected_tools` - List of tool names to exclude from MCP tools
  * `:custom_tool_executor` - Function `(tool_name, args, context) -> {:ok, result} | {:error, reason}`
  * `:on_assistant_message` - Hook `(message, context) -> :ok | {:ok, context}`
  * `:on_tool_result` - Hook `(tool_call_id, tool_name, result, context) -> :ok | {:ok, context}`
  """
  def new(client, opts \\ []) do
    mcp_clients = Keyword.get(opts, :mcp_clients, [])
    custom_tools = Keyword.get(opts, :custom_tools, [])
    rejected_tools = Keyword.get(opts, :rejected_tools, [])

    tool_mapping = build_tool_mapping(mcp_clients)

    %__MODULE__{
      client: client,
      mcp_clients: mcp_clients,
      custom_tools: custom_tools,
      rejected_tools: rejected_tools,
      tool_mapping: tool_mapping,
      custom_tool_executor: Keyword.get(opts, :custom_tool_executor),
      on_assistant_message: Keyword.get(opts, :on_assistant_message),
      on_tool_result: Keyword.get(opts, :on_tool_result)
    }
  end

  @doc """
  Executes a chat conversation with tool calling support.

  ## Options

  * `:model` - Model to use (required)
  * `:messages` - List of messages (required)
  * `:system_prompt` - System prompt (optional)
  * `:execute_tools` - Whether to execute tools automatically (default: true)
  * `:context` - Arbitrary context passed to hooks (default: %{})
  * `:temperature` - Controls randomness (0.0-2.0, optional, defaults to API default of 1.0)
  * `:parallel_tool_calls` - Whether to allow parallel tool calls (boolean, optional)
  """
  def chat(%__MODULE__{} = session, opts) do
    model = Keyword.fetch!(opts, :model)
    messages = Keyword.fetch!(opts, :messages)
    system_prompt = Keyword.get(opts, :system_prompt, "")
    execute_tools = Keyword.get(opts, :execute_tools, true)
    context = Keyword.get(opts, :context, %{})
    temperature = Keyword.get(opts, :temperature)
    parallel_tool_calls = Keyword.get(opts, :parallel_tool_calls)

    # Normalize messages
    normalized_messages = normalize_message_content(messages)

    # Build full message list with system prompt if provided
    full_messages =
      if system_prompt != "" do
        [%{"role" => "system", "content" => system_prompt} | normalized_messages]
      else
        normalized_messages
      end

    available_tools = get_all_tools(session)

    body = %{
      messages: full_messages,
      model: model
    }

    # Add temperature if provided
    body =
      if temperature do
        Map.put(body, :temperature, temperature)
      else
        body
      end

    # Add parallel_tool_calls if provided
    body =
      if parallel_tool_calls != nil do
        Map.put(body, :parallel_tool_calls, parallel_tool_calls)
      else
        body
      end

    # Only include tools if we have any
    body =
      if available_tools != [] do
        Map.put(body, :tools, available_tools)
      else
        body
      end

    Logger.info("Starting chat request to model: #{model}")

    case OpEx.Client.chat_completion(session.client, body) do
      {:ok, %{"choices" => [%{"message" => message}]} = response} ->
        # Check for tool calls
        tool_calls = Map.get(message, "tool_calls", [])

        if execute_tools == false and length(tool_calls) > 0 do
          Logger.info("Tool execution disabled - returning #{length(tool_calls)} tool calls to caller")
          {:ok, response}
        else
          # Call on_assistant_message hook FIRST to create DB records
          context = call_hook(session.on_assistant_message, [message, context], context)

          # Execute tools if present (on_tool_result will update existing DB records)
          case handle_tool_calls(session, message, context) do
            {:ok, updated_messages, updated_context} ->
              # Continue conversation with tool results
              case continue_chat_recursive(
                     session,
                     full_messages ++ updated_messages,
                     available_tools,
                     [],
                     model,
                     updated_context,
                     temperature,
                     parallel_tool_calls
                   ) do
                {:ok, final_response, all_tool_calls} ->
                  # Add metadata about all tool calls
                  initial_tool_calls = Map.get(message, "tool_calls", [])
                  all_calls = initial_tool_calls ++ all_tool_calls
                  enhanced_response = Map.put(final_response, "_metadata", %{"tool_calls_made" => all_calls})
                  {:ok, enhanced_response}

                error ->
                  error
              end

            :no_tool_calls ->
              # No tool calls, return response immediately
              call_hook(session.on_assistant_message, [message, context], context)
              {:ok, response}
          end
        end

      {:error, reason} ->
        Logger.error("Chat request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Gets all available tools (MCP + custom) for this chat session.
  Useful for debugging and testing.
  """
  def get_all_tools(%__MODULE__{} = session) do
    mcp_tools = get_mcp_tools(session.mcp_clients, session.rejected_tools)
    mcp_tools ++ session.custom_tools
  end

  # Private functions

  defp normalize_message_content(messages) when is_list(messages) do
    Enum.map(messages, fn
      %{"content" => content} = message when is_list(content) ->
        normalized_content = Enum.join(content, "")
        %{message | "content" => normalized_content}

      message ->
        message
    end)
  end

  defp get_mcp_tools(mcp_clients, rejected_tools) do
    mcp_clients
    |> Enum.flat_map(fn
      {:ok, pid} ->
        case GenServer.call(pid, :list_tools, 30_000) do
          {:ok, tools} -> OpEx.MCP.Tools.convert_tools_to_openai_format(tools, rejected_tools)
          {:error, _} -> []
        end

      {:error, _} ->
        []
    end)
  end

  defp build_tool_mapping(mcp_clients) do
    mcp_clients
    |> Enum.reduce(%{}, fn
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
  end

  defp handle_tool_calls(%__MODULE__{} = session, %{"tool_calls" => tool_calls} = message, context) do
    {tool_results, final_context} =
      Enum.map_reduce(tool_calls, context, fn tool_call, acc_context ->
        case OpEx.MCP.Tools.extract_tool_call(tool_call) do
          {:ok, tool_name, args} ->
            # Check if tool exists
            is_custom_tool =
              Enum.any?(session.custom_tools, fn tool ->
                get_in(tool, ["function", "name"]) == tool_name
              end)

            is_mcp_tool = Map.has_key?(session.tool_mapping, tool_name)

            if is_custom_tool || is_mcp_tool do
              # Try custom tool first, then MCP tool
              {result, new_context} =
                case execute_custom_tool(session, tool_name, args, acc_context) do
                  {:ok, result} ->
                    {result, acc_context}

                  {:error, :tool_not_found} ->
                    case execute_mcp_tool(session, tool_name, args) do
                      {:ok, result} ->
                        {result, acc_context}

                      {:error, reason} ->
                        {%{"error" => reason}, acc_context}
                    end
                end

              # Call on_tool_result hook
              new_context =
                call_hook(session.on_tool_result, [tool_call["id"], tool_name, result, new_context], new_context)

              formatted_result = OpEx.MCP.Tools.format_tool_result(tool_call["id"], result)
              {formatted_result, new_context}
            else
              # Tool not found
              Logger.warning("Tool '#{tool_name}' not found in available tools")

              error_result =
                OpEx.MCP.Tools.format_tool_result(tool_call["id"], %{"error" => "Tool not available: #{tool_name}"})

              {error_result, acc_context}
            end

          {:error, reason} ->
            Logger.error("Tool execution failed: #{inspect(reason)}")
            error_result = OpEx.MCP.Tools.format_tool_result(tool_call["id"], %{"error" => reason})
            {error_result, acc_context}
        end
      end)

    # Normalize tool_calls to ensure arguments field is always present
    normalized_tool_calls =
      Enum.map(tool_calls, fn tool_call ->
        function = tool_call["function"]
        normalized_function = Map.put_new(function, "arguments", "{}")
        Map.put(tool_call, "function", normalized_function)
      end)

    assistant_message = %{
      "role" => "assistant",
      "content" => Map.get(message, "content") || "",
      "tool_calls" => normalized_tool_calls
    }

    {:ok, [assistant_message | tool_results], final_context}
  end

  defp handle_tool_calls(_session, _message, _context), do: :no_tool_calls

  defp execute_custom_tool(%__MODULE__{custom_tool_executor: nil}, _tool_name, _args, _context) do
    {:error, :tool_not_found}
  end

  defp execute_custom_tool(%__MODULE__{custom_tool_executor: executor}, tool_name, args, context) do
    # Check if tool is in custom_tools list
    executor.(tool_name, args, context)
  end

  defp execute_mcp_tool(%__MODULE__{tool_mapping: tool_mapping}, tool_name, args) do
    case Map.get(tool_mapping, tool_name) do
      nil ->
        {:error, "Tool not found: #{tool_name}"}

      pid ->
        GenServer.call(pid, {:call_tool, tool_name, args}, 300_000)
    end
  end

  defp continue_chat_recursive(
         %__MODULE__{} = session,
         messages,
         tools,
         accumulated_tool_calls,
         model,
         context,
         temperature,
         parallel_tool_calls
       ) do
    body = %{
      messages: messages,
      model: model
    }

    # Add temperature if provided
    body =
      if temperature do
        Map.put(body, :temperature, temperature)
      else
        body
      end

    # Add parallel_tool_calls if provided
    body =
      if parallel_tool_calls != nil do
        Map.put(body, :parallel_tool_calls, parallel_tool_calls)
      else
        body
      end

    body =
      if tools != [] do
        Map.put(body, :tools, tools)
      else
        body
      end

    case OpEx.Client.chat_completion(session.client, body) do
      {:ok, %{"choices" => [%{"message" => message}]} = response} ->
        # Call on_assistant_message hook FIRST to create DB records
        context = call_hook(session.on_assistant_message, [message, context], context)

        case handle_tool_calls(session, message, context) do
          {:ok, new_tool_messages, new_context} ->
            # More tool calls detected
            new_tool_calls = Map.get(message, "tool_calls", [])

            continue_chat_recursive(
              session,
              messages ++ new_tool_messages,
              tools,
              accumulated_tool_calls ++ new_tool_calls,
              model,
              new_context,
              temperature,
              parallel_tool_calls
            )

          :no_tool_calls ->
            # No more tool calls, this is the final response
            call_hook(session.on_assistant_message, [message, context], context)
            {:ok, response, accumulated_tool_calls}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call_hook(nil, _args, default_context), do: default_context

  defp call_hook(hook, args, default_context) when is_function(hook) do
    case apply(hook, args) do
      :ok -> default_context
      {:ok, new_context} -> new_context
      _ -> default_context
    end
  end
end
