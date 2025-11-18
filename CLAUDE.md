# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

OpEx is an Elixir library for building LLM-powered agents with tool calling support. It provides:
- OpenRouter API client with retry logic
- Full MCP (Model Context Protocol) support for both stdio and HTTP transports
- Flexible chat loop with customizable hooks
- Session management with automatic health monitoring and reconnection

## Development Commands

### Testing
```bash
# Run all tests
mix test

# Run specific test file
mix test test/opex/chat_test.exs

# Run specific test by line number
mix test test/opex/chat_test.exs:42
```

### Building and Formatting
```bash
# Compile the project
mix compile

# Format code
mix format

# Get dependencies
mix deps.get
```

### Running Example Scripts
```bash
# Integration demo (requires OPENROUTER_KEY)
export OPENROUTER_KEY=sk-or-v1-...
mix run scripts/integration_demo.exs

# Interactive CLI with docker-mcp (requires OPENROUTER_KEY and DOCKER_MCP_TOKEN)
export OPENROUTER_KEY=sk-or-v1-...
export DOCKER_MCP_TOKEN=your-token
mix run scripts/cli_chat_docker.exs
```

## Architecture

### Core Architecture Flow

1. **Client Layer** (`OpEx.Client`): HTTP client for OpenRouter API
   - Exponential backoff retry logic for transient errors (429, 500-504, 508)
   - Transport error handling (closed connections, timeouts)
   - Maximum 3 retries with status-specific delays

2. **Chat Loop** (`OpEx.Chat`): Main conversation orchestrator
   - Receives messages, system prompt, model, and context
   - Calls LLM API with available tools
   - Detects tool calls in responses
   - Executes tools (MCP or custom) and continues conversation recursively
   - Returns final response with metadata about all tool calls made

3. **Tool Execution**: Two parallel systems
   - **MCP Tools**: Via stdio or HTTP MCP servers, routed through tool_mapping
   - **Custom Tools**: Via custom_tool_executor hook function

4. **Session Management** (`OpEx.MCP.SessionManager`): Multi-server orchestration
   - Manages multiple MCP server sessions (stdio and HTTP)
   - Health checks every 5 minutes with automatic reconnection
   - Immediate recovery on server crash during tool execution
   - Process monitoring with {:DOWN} message handling

### MCP Transport Implementation

**Stdio Transport** (`OpEx.MCP.StdioClient`):
- Spawns local processes (e.g., npx MCP servers)
- JSON-RPC 2.0 over stdin/stdout
- Used for: filesystem, brave-search, etc.

**HTTP Transport** (`OpEx.MCP.HttpClient`):
- REST API for remote MCP servers
- Requires URL, auth token, optional execution_id
- Used for: docker-mcp, GitHub docs search, etc.

Both implement the same GenServer interface:
- `:connect` - Initialize session
- `:list_tools` - Get available tools
- `{:call_tool, name, args}` - Execute tool

### Hooks System

OpEx uses a hooks-based architecture to avoid coupling. All hooks are optional functions passed during session creation.

**Hook Execution Order**:
1. LLM responds with tool_calls → `on_assistant_message` called FIRST (creates DB records)
2. Each tool executes → `on_tool_result` called (updates DB records)
3. Recursive call continues → `on_assistant_message` for each new assistant message

**Hook Signatures**:
- `custom_tool_executor: (tool_name, args, context) -> {:ok, result} | {:error, reason}`
- `on_assistant_message: (message, context) -> :ok | {:ok, updated_context} | :stop | {:stop, updated_context}`
- `on_tool_result: (tool_call_id, tool_name, result, context) -> :ok | {:ok, updated_context} | :stop | {:stop, updated_context}`

**Context Threading**: Context is arbitrary data (typically `%{conversation_id: ...}`) passed through all hooks. Hooks can return `{:ok, new_context}` to update it for subsequent hooks.

**Stopping Tool Execution**: The `on_tool_result` hook can return `:stop` or `{:stop, context}` to immediately halt the tool execution loop. When this happens:
- No further tools in the current batch are executed
- No additional LLM calls are made
- The response includes `_metadata.stopped_by_hook = true`
- Useful for implementing rate limits, cost controls, or error handling

### Tool Mapping and Routing

`OpEx.Chat.new/2` builds a `tool_mapping: %{"tool_name" => pid}` at initialization by calling `:list_tools` on each MCP client. During execution:
1. Check if tool is in `custom_tools` → call `custom_tool_executor`
2. If not found, check `tool_mapping` → call MCP client via GenServer
3. If neither, return error

### Error Handling Patterns

**Client Retry Logic** (lib/opex/client.ex:140-186):
- HTTP 429: 5s base delay with exponential backoff
- HTTP 500-504, 508: 2s base delay with exponential backoff
- Transport errors (:closed, :timeout, :econnrefused): 1s base delay
- Embedded errors in response body: Extract and convert to retryable format (502 → 429 for rate limits)

**Session Manager Recovery** (lib/opex/mcp/session_manager.ex:198-218):
- On `:server_crashed` error during tool call: Mark disconnected, attempt immediate reconnection, retry tool call
- On health check failure: Mark disconnected, retry on next health check (5 min interval)
- On {:DOWN} message: Mark session disconnected, reconnection happens on next health check

**Chat Loop Recursion** (lib/opex/chat.ex:303-351):
- Calls LLM → executes tools → calls LLM again with tool results → repeats until no more tool_calls
- Accumulates all tool_calls across turns for metadata
- Each recursive call maintains updated context from hooks

## Key Implementation Details

### Message Normalization
`OpEx.Chat` normalizes content arrays to strings (lib/opex/chat.ex:171-180). If a message has `content: ["text1", "text2"]`, it gets joined to `content: "text1text2"` before sending to API.

### Tool Call Normalization
The assistant message with tool_calls MUST include an "arguments" field (even if empty string) for OpenRouter API compatibility (lib/opex/chat.ex:266-271).

### Temperature Parameter
Temperature is optional in `OpEx.Chat.chat/2` and defaults to API's default (1.0) if not provided. It's threaded through recursive calls (lib/opex/chat.ex:68, 94-99, 310-314).

### Rejected Tools
`OpEx.Chat` supports `rejected_tools` option to exclude specific MCP tools by name (lib/opex/chat.ex:41). Useful for removing tools you don't want the LLM to see.

### Session Manager Server ID
Server IDs are generated by hashing the normalized config (lib/opex/mcp/session_manager.ex:301-308). Env vars are converted from tuples to lists for JSON encoding consistency.

## Testing Patterns

Tests use real GenServer processes but mock external dependencies:
- MCP clients: Use test helpers that return canned responses
- HTTP API: Some tests use real OpenRouter API (integration tests), others mock
- See `test/opex/chat_test.exs` for examples of setting up test MCP clients

When writing tests:
1. Start necessary GenServers in test setup
2. Pass test PIDs to `OpEx.Chat.new/2` as `mcp_clients: [{:ok, pid}]`
3. Use hooks to capture side effects for assertions
4. Clean up GenServers in `on_exit` callbacks
