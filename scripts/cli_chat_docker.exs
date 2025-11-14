#!/usr/bin/env elixir

# OpEx CLI Chat Loop with Docker-MCP
#
# Interactive chat loop demonstrating:
# - OpEx.Client for OpenRouter
# - OpEx.MCP.HttpClient for docker-mcp
# - Real-time interactive conversation
# - Tool calling with docker-mcp tools
# - Conversation history management
#
# Usage:
#   export OPENROUTER_KEY=your-key-here
#   export DOCKER_MCP_URL=http://localhost:30000
#   export DOCKER_MCP_TOKEN=your-token-here
#   elixir -S mix run scripts/cli_chat_docker.exs

defmodule CLIChatDocker do
  require Logger

  def run do
    print_header()
    config = load_config()

    IO.puts("Initializing OpenRouter client...")
    client = create_openrouter_client(config)

    IO.puts("Connecting to docker-mcp at #{config.docker_mcp_url}...")
    {:ok, mcp_client} = start_docker_mcp(config)
    :ok = connect_docker_mcp(mcp_client)

    IO.puts("Fetching available tools...")
    tools = list_docker_tools(mcp_client)
    print_tools(tools)

    IO.puts("Creating chat session...")
    session = create_chat_session(client, mcp_client)

    IO.puts("\nReady! Start chatting (type 'exit' or 'quit' to end)\n")

    conversation_history = []
    chat_loop(session, conversation_history, config)

    cleanup(mcp_client)
  end

  # Configuration
  defp load_config do
    %{
      openrouter_key: get_required_env("OPENROUTER_KEY"),
      docker_mcp_url: get_env_with_default("DOCKER_MCP_URL", "http://localhost:30000"),
      docker_mcp_token: get_required_env("DOCKER_MCP_TOKEN"),
      model: get_env_with_default("MODEL", "anthropic/claude-haiku-4.5")
    }
  end

  # OpenRouter Client
  defp create_openrouter_client(config) do
    OpEx.Client.new(config.openrouter_key,
      base_url: "https://openrouter.ai/api/v1",
      app_title: "OpEx CLI Chat with Docker-MCP"
    )
  end

  # Docker-MCP Setup
  defp start_docker_mcp(config) do
    mcp_config = %{
      "url" => config.docker_mcp_url,
      "auth_token" => config.docker_mcp_token,
      "execution_id" => generate_execution_id()
    }

    OpEx.MCP.HttpClient.start_link(mcp_config)
  end

  defp connect_docker_mcp(mcp_client) do
    OpEx.MCP.HttpClient.connect(mcp_client)
  end

  defp list_docker_tools(mcp_client) do
    {:ok, tools} = OpEx.MCP.HttpClient.list_tools(mcp_client)
    tools
  end

  # Chat Session
  defp create_chat_session(client, mcp_client) do
    OpEx.Chat.new(client,
      mcp_clients: [{:ok, mcp_client}],
      on_assistant_message: &log_assistant_message/2,
      on_tool_result: &log_tool_result/4
    )
  end

  # Interactive Loop
  defp chat_loop(session, history, config) do
    user_input = read_user_input()

    case user_input do
      :exit ->
        IO.puts("\nGoodbye!")

      "" ->
        chat_loop(session, history, config)

      input ->
        # Add user message to history
        user_message = %{"role" => "user", "content" => input}
        updated_history = history ++ [user_message]

        # Send to LLM
        case OpEx.Chat.chat(session,
          model: config.model,
          messages: updated_history,
          system_prompt: build_system_prompt(),
          context: %{timestamp: DateTime.utc_now()}
        ) do
          {:ok, response} ->
            # Extract assistant message and add to history
            assistant_message = get_in(response, ["choices", Access.at(0), "message"])
            final_history = updated_history ++ [assistant_message]

            # Display response
            display_assistant_response(assistant_message)

            # Continue loop
            chat_loop(session, final_history, config)

          {:error, reason} ->
            IO.puts("\nError: #{inspect(reason)}")
            chat_loop(session, history, config)
        end
    end
  end

  # Input/Output
  defp read_user_input do
    IO.write("\nYou: ")
    case IO.gets("") do
      :eof -> :exit
      {:error, _} -> :exit
      input ->
        trimmed = String.trim(input)
        if trimmed in ["exit", "quit", "/exit", "/quit"], do: :exit, else: trimmed
    end
  end

  defp display_assistant_response(message) do
    content = Map.get(message, "content", "")
    IO.puts("\nAssistant: #{content}")
  end

  # Hooks
  defp log_assistant_message(message, context) do
    tool_calls = Map.get(message, "tool_calls", [])
    if length(tool_calls) > 0 do
      IO.puts("\n[Executing #{length(tool_calls)} tool(s)...]")
    end
    {:ok, context}
  end

  defp log_tool_result(_tool_call_id, tool_name, _result, context) do
    IO.puts("  ✓ #{tool_name}")
    {:ok, context}
  end

  # Utilities
  defp build_system_prompt do
    """
    You are a helpful AI assistant with access to Docker-based development tools.
    You can read and write files, execute shell commands, and work with git repositories.

    Use the available tools to help users with their requests.
    Be concise but informative in your responses.
    """
  end

  defp get_required_env(key) do
    case System.get_env(key) do
      nil ->
        IO.puts("Error: #{key} environment variable not set")
        IO.puts("\nUsage:")
        IO.puts("  export OPENROUTER_KEY=your-key-here")
        IO.puts("  export DOCKER_MCP_TOKEN=your-token-here")
        IO.puts("  elixir -S mix run scripts/cli_chat_docker.exs")
        System.halt(1)
      value -> value
    end
  end

  defp get_env_with_default(key, default) do
    System.get_env(key, default)
  end

  defp generate_execution_id do
    "cli-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end

  defp print_header do
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("OpEx CLI Chat with Docker-MCP")
    IO.puts(String.duplicate("=", 60) <> "\n")
  end

  defp print_tools(tools) do
    IO.puts("\nAvailable Docker-MCP tools (#{length(tools)}):")
    Enum.each(tools, fn tool ->
      name = tool["name"]
      description = tool["description"] || "No description"
      IO.puts("  • #{name}: #{description}")
    end)
  end

  defp cleanup(mcp_client) do
    IO.puts("\nCleaning up...")
    OpEx.MCP.HttpClient.stop(mcp_client)
    IO.puts("Done!")
  end
end

# Run the CLI
CLIChatDocker.run()
