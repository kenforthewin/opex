# OpEx

![Hex.pm Version](https://img.shields.io/hexpm/v/opex)

An agentic LLM toolkit for Elixir.

## Overview

- **OpenAI-compatible API Client**: HTTP client with automatic retry logic and error handling
- **MCP Support**: Full support for Model Context Protocol servers via stdio and HTTP transports
- **Flexible Chat Loop**: Tool calling with customizable hooks for integration
- **Session Management**: Automatic health monitoring and reconnection for MCP servers

## Architecture

### Core Modules

- **`OpEx.Client`** - HTTP client for OpenAI-compatible API with exponential backoff retry logic
- **`OpEx.Chat`** - Chat conversation loop with tool calling and hook support
- **`OpEx.MCP.StdioClient`** - MCP client for stdio transport (local process spawning)
- **`OpEx.MCP.HttpClient`** - MCP client for HTTP transport (remote MCP servers)
- **`OpEx.MCP.SessionManager`** - Manages multiple MCP server sessions with health checks
- **`OpEx.MCP.Tools`** - Utilities for converting between MCP and OpenAI tool formats

### Hooks System

OpEx uses a hooks-based architecture to avoid hard-coded dependencies. You can customize behavior via:

- **`custom_tool_executor`** - Execute application-specific tools
- **`on_assistant_message`** - Handle assistant messages (e.g., save to database)
- **`on_tool_result`** - Handle tool results (e.g., logging, metrics)

See `OpEx.Hooks` for detailed documentation.

## Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:opex, "~> 0.1.0"}
  ]
end
```

## Quick Start

```elixir
# 1. Create OpenRouter client
client = OpEx.Client.new(System.get_env("OPENROUTER_KEY"))

# 2. Start MCP session manager
{:ok, _pid} = OpEx.MCP.SessionManager.start_link(name: MyApp.MCPManager)

# 3. Add MCP servers
{:ok, server_id} = OpEx.MCP.SessionManager.add_server(MyApp.MCPManager, %{
  "command" => "npx",
  "args" => ["-y", "@modelcontextprotocol/server-filesystem"],
  "env" => []
})

# 4. Create chat session with hooks
session = OpEx.Chat.new(client,
  mcp_clients: [{:ok, server_id}],
  custom_tool_executor: &MyApp.execute_custom_tool/3,
  on_assistant_message: &MyApp.save_message/2
)

# 5. Have a conversation
{:ok, response} = OpEx.Chat.chat(session,
  model: "anthropic/claude-3.5-sonnet",
  messages: [%{"role" => "user", "content" => "List files in /tmp"}],
  system_prompt: "You are a helpful assistant",
  context: %{conversation_id: 123}
)
```

## MCP Server Examples

### Stdio Transport (Local)

```elixir
# Filesystem server
%{
  "command" => "npx",
  "args" => ["-y", "@modelcontextprotocol/server-filesystem"],
  "env" => []
}

# Brave Search server
%{
  "command" => "npx",
  "args" => ["-y", "@modelcontextprotocol/server-brave-search"],
  "env" => [{"BRAVE_API_KEY", api_key}]
}
```

### HTTP Transport (Remote)

```elixir
%{
  "url" => "https://api.example.com/mcp",
  "auth_token" => "your-token",
  "execution_id" => "exec-123"  # Optional
}
```

## Custom Tools

Define custom tools and provide an executor function:

```elixir
custom_tools = [
  %{
    "type" => "function",
    "function" => %{
      "name" => "search_database",
      "description" => "Search the internal database",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string", "description" => "Search query"}
        },
        "required" => ["query"]
      }
    }
  }
]

def execute_custom_tool("search_database", args, _context) do
  results = MyApp.Database.search(args["query"])
  {:ok, %{"results" => results}}
end

def execute_custom_tool(_, _, _), do: {:error, :tool_not_found}

session = OpEx.Chat.new(client,
  custom_tools: custom_tools,
  custom_tool_executor: &execute_custom_tool/3
)
```

## Configuration

### OpenRouter Client Options

```elixir
client = OpEx.Client.new(api_key,
  base_url: "https://openrouter.ai/api/v1",  # Default
  user_agent: "my-app/1.0.0",
  app_title: "My Application"  # For X-Title header
)
```

### Chat Options

```elixir
OpEx.Chat.chat(session,
  model: "anthropic/claude-haiku-4.5",  # Required
  messages: messages,                     # Required
  system_prompt: "You are helpful",       # Optional
  execute_tools: true,                    # Auto-execute tools (default: true)
  context: %{}                            # Passed to all hooks (default: %{})
)
```

## Error Handling

OpEx automatically retries transient errors:

- **HTTP 429**: Rate limits (retry with 5s+ backoff)
- **HTTP 500-504, 508**: Server errors (retry with 2s+ backoff)
- **Transport errors**: Closed connections, timeouts (retry with 1s+ backoff)

Maximum 3 retries with exponential backoff.

## Future Enhancements

Potential additions for OpEx:

- [ ] Streaming support (SSE from OpenRouter)
- [ ] Telemetry events
- [ ] Supervision tree helpers

## License

MIT
