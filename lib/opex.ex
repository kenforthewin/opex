defmodule OpEx do
  @moduledoc """
  OpEx - OpenRouter and Model Context Protocol (MCP) client library for Elixir.

  OpEx provides a flexible interface for building AI agents with tool calling capabilities.
  It supports:

  - OpenRouter API integration with automatic retry logic
  - Model Context Protocol (MCP) servers via stdio and HTTP transports
  - Custom tool execution via hooks
  - Flexible chat loop with tool calling support

  ## Quick Start

      # Create an OpenRouter client
      client = OpEx.Client.new(api_key)

      # Start MCP session manager
      {:ok, _pid} = OpEx.MCP.SessionManager.start_link(name: MyApp.MCPManager)

      # Add MCP servers
      {:ok, server_id} = OpEx.MCP.SessionManager.add_server(MyApp.MCPManager, %{
        "command" => "npx",
        "args" => ["-y", "@modelcontextprotocol/server-filesystem"]
      })

      # Create a chat session
      session = OpEx.Chat.new(client,
        mcp_clients: [{:ok, server_id}],
        custom_tool_executor: &MyApp.execute_tool/3
      )

      # Have a conversation
      {:ok, response} = OpEx.Chat.chat(session,
        model: "anthropic/claude-3.5-sonnet",
        messages: [%{"role" => "user", "content" => "List files in /tmp"}],
        system_prompt: "You are a helpful assistant"
      )

  ## Architecture

  - `OpEx.Client` - HTTP client for OpenRouter API
  - `OpEx.Chat` - Chat loop with tool calling and hooks
  - `OpEx.MCP.StdioClient` - MCP client for stdio transport
  - `OpEx.MCP.HttpClient` - MCP client for HTTP transport
  - `OpEx.MCP.SessionManager` - Manages multiple MCP server sessions
  - `OpEx.MCP.Tools` - Utilities for MCP tool format conversion
  """

  @doc """
  Convenience function to create a new OpenRouter client.
  See `OpEx.Client.new/2` for details.
  """
  defdelegate new_client(api_key, opts \\ []), to: OpEx.Client, as: :new

  @doc """
  Convenience function to create a new chat session.
  See `OpEx.Chat.new/2` for details.
  """
  defdelegate new_chat(client, opts \\ []), to: OpEx.Chat, as: :new

  @doc """
  Convenience function to execute a chat conversation.
  See `OpEx.Chat.chat/2` for details.
  """
  defdelegate chat(session, opts), to: OpEx.Chat
end
