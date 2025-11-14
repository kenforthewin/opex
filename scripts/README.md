# OpEx Integration Demo Scripts

## integration_demo.exs

A comprehensive integration test that exercises the full OpEx stack with real API calls and MCP servers.

### What It Tests

**Real Components:**
- ✅ OpenRouter API (actual HTTP requests to Claude)
- ✅ Stdio MCP server (@modelcontextprotocol/server-filesystem)
- ✅ HTTP MCP server (GitHub Support Docs Search)
- ✅ Custom tool execution (calculator, timestamp)
- ✅ All three hook types (on_assistant_message, on_tool_result, custom_tool_executor)
- ✅ Complete multi-turn conversation with tool calling

**No Mocks:**
- Real LLM API calls
- Real MCP server processes via stdio
- Real tool execution with actual side effects

### Prerequisites

1. **OpenRouter API Key**
   ```bash
   export OPENROUTER_KEY=your-key-here
   ```

2. **Node.js/npx** (for MCP filesystem server)
   ```bash
   npx --version  # Should work
   ```

3. **Optional: GitHub Token**
   ```bash
   export GITHUB_TOKEN=ghp_...  # Optional, for GitHub MCP server
   ```
   - Not required for the GitHub Support Docs search endpoint
   - Will default to "anonymous" if not provided

4. **Optional: Local OpenRouter Proxy**
   - The script defaults to `http://localhost:4001/v1`
   - Change `base_url` in the script if using direct API

### Running the Demo

From the Matic project root:

```bash
export OPENROUTER_KEY=sk-or-v1-...
elixir -S mix run lib/opex/scripts/integration_demo.exs
```

Or from the opex directory:

```bash
cd lib/opex
export OPENROUTER_KEY=sk-or-v1-...
elixir -S mix run scripts/integration_demo.exs
```

### What It Does

The script will:

1. **Setup**
   - Create OpEx.Client with real API key
   - Start filesystem MCP server (stdio) at /tmp
   - Start GitHub Support Docs MCP server (HTTP)
   - Define custom calculator and timestamp tools
   - Configure hooks with console logging

2. **Execute Conversation**
   - Send user prompt asking to:
     - Search GitHub docs via HTTP MCP
     - Create a file via stdio MCP
     - Perform calculation via custom tool
     - Get timestamp via custom tool
   - Agent will call multiple tools across both transports
   - Hooks will log each step

3. **Display Results**
   - Show all assistant messages
   - Show all tool calls and results
   - Display final response
   - Show metadata (tool usage stats)

### Expected Output

```
=== OpEx Integration Demo ===

📡 Creating OpenRouter client...
✅ Client created

🔧 Starting MCP servers...
  - Starting filesystem MCP server (stdio)...
    ✅ Connected! Available tools: 3
       - read_file: Read file contents
       - write_file: Write content to a file
       - list_directory: List directory contents
  - Starting GitHub Support Docs MCP server (HTTP)...
    ✅ Connected! Available tools: 1
       - search_github_support_docs: Search GitHub documentation

🛠️  Defining custom tools...
  ✅ Defined 2 custom tools

🪝 Setting up hooks...

🎭 Creating chat session...
  ✅ Session created with 6 total tools available

============================================================
🚀 Starting conversation...
============================================================

👤 User:
   Please help me with these tasks:
   1. Search the GitHub support docs for "GitHub Actions workflow syntax"
   2. Create a file at /tmp/opex_demo.txt...
   3. Calculate 42 * 8
   4. Get the current timestamp

💬 Assistant Message:
   Content: I'll help you with those tasks.
   Tool Calls: 4
     - search_github_support_docs
     - write_file
     - calculate
     - get_timestamp

  🔨 Executing custom tool: calculate
     Args: %{"a" => 42, "b" => 8, "operation" => "multiply"}
     ✅ Result: 336

  🔨 Executing custom tool: get_timestamp
     Args: %{}
     ✅ Timestamp: 2024-11-14T20:15:30.123Z

  📊 Tool Result [call_1]:
     Tool: search_github_support_docs
     Result: Found documentation about GitHub Actions workflow syntax...

  📊 Tool Result [call_2]:
     Tool: write_file
     Result: Successfully wrote to /tmp/opex_demo.txt

  📊 Tool Result [call_3]:
     Tool: calculate
     Result: 336

  📊 Tool Result [call_4]:
     Tool: get_timestamp
     Result: 2024-11-14T20:15:30.123Z

💬 Assistant Message:
   Content: I've completed all four tasks:
   1. Searched GitHub docs and found workflow syntax documentation
   2. Created file at /tmp/opex_demo.txt with the content...
   3. Calculated 42 × 8 = 336
   4. Current timestamp is 2024-11-14T20:15:30.123Z

============================================================
✅ Conversation completed in 3421ms
============================================================

🤖 Final Response:
   I've completed all three tasks:...

📈 Metadata:
   Total tool calls: 4
   Tools used:
     - search_github_support_docs: 1x
     - write_file: 1x
     - calculate: 1x
     - get_timestamp: 1x

✅ Demo completed successfully!

🧹 Cleaning up...
✅ Done!
```

### Customization

**Change the MCP server:**

```elixir
# Use fetch server instead
stdio_config = %{
  "command" => "uvx",
  "args" => ["mcp-server-fetch"],
  "env" => []
}
```

**Change HTTP MCP server:**

The script uses GitHub Support Docs by default. To use a different HTTP MCP:

```elixir
# Change from GitHub to your own MCP server
http_config = %{
  "url" => "https://your-mcp-server.com/mcp",
  "auth_token" => System.get_env("YOUR_TOKEN") || "token"
}
```

Other public HTTP MCP endpoints you can try:
- Brave Search: Requires MCP server running locally
- Custom endpoints: Any server implementing MCP HTTP protocol

**Change the model:**

```elixir
OpEx.Chat.chat(session,
  model: "openai/gpt-4",  # or any OpenRouter model
  ...
)
```

**Modify the prompt:**

```elixir
user_prompt = """
Your custom test scenario here
"""
```

### Troubleshooting

**Error: OPENROUTER_KEY not set**
- Make sure to export the environment variable before running

**Error: MCP server failed to start**
- Check that npx is installed: `npx --version`
- Try running the MCP server manually: `npx -y @modelcontextprotocol/server-filesystem /tmp`

**Error: Connection refused to localhost:4001**
- Either start your local OpenRouter proxy
- Or change `base_url` to `"https://openrouter.ai/api/v1"`

**Error: Permission denied writing to /tmp**
- Change the filesystem path in the stdio_config
- Or use a different directory you have write access to

**Warning: HTTP MCP failed to connect**
- The GitHub Support Docs endpoint may be down or require authentication
- The script will continue with just stdio MCP and custom tools
- Check network connectivity and firewall settings

### Cost

This demo makes real API calls to Claude 3.5 Sonnet. Typical cost:
- ~2-4 API calls per run (initial + tool results + final response)
- ~1000-2000 tokens per run (with 4 tools and GitHub search results)
- Cost: ~$0.02-0.04 per run

To minimize costs during testing:
- Use a cheaper model like `anthropic/claude-3-haiku`
- Limit the prompt length
- Run less frequently

---

## cli_chat_docker.exs

An interactive CLI chat loop demonstrating OpEx integration with docker-mcp for agentic development workflows.

### What It Demonstrates

**Real Components:**
- ✅ Interactive chat loop with conversation history
- ✅ OpEx.Client for OpenRouter API
- ✅ OpEx.MCP.HttpClient for docker-mcp
- ✅ Real-time tool execution feedback
- ✅ Persistent conversation across multiple turns
- ✅ Clean conversation management

**Use Case:**
- CLI-based AI assistant with development tools
- File operations, shell commands, git integration
- Perfect for quick prototyping and testing

### Prerequisites

1. **OpenRouter API Key**
   ```bash
   export OPENROUTER_KEY=sk-or-v1-...
   ```

2. **Docker-MCP Server**
   - Running docker-mcp server (HTTP-based MCP)
   ```bash
   export DOCKER_MCP_URL=http://localhost:30000  # Default
   export DOCKER_MCP_TOKEN=your-token-here
   ```

   To start docker-mcp:
   ```bash
   # Check if docker-mcp is running
   docker ps | grep docker-mcp

   # Get authentication token from logs
   docker logs docker-mcp | grep "Bearer"
   ```

3. **Optional: Model Selection**
   ```bash
   export MODEL=anthropic/claude-3.5-sonnet  # Default
   ```

### Running the CLI

From Matic project root:
```bash
export OPENROUTER_KEY=sk-or-v1-...
export DOCKER_MCP_TOKEN=your-token
elixir -S mix run lib/opex/scripts/cli_chat_docker.exs
```

Or from opex directory:
```bash
cd lib/opex
export OPENROUTER_KEY=sk-or-v1-...
export DOCKER_MCP_TOKEN=your-token
elixir -S mix run scripts/cli_chat_docker.exs
```

### Example Session

```
============================================================
OpEx CLI Chat with Docker-MCP
============================================================

Initializing OpenRouter client...
Connecting to docker-mcp at http://localhost:30000...
Fetching available tools...

Available Docker-MCP tools (5):
  • read_file: Read file contents
  • write_file: Write content to a file
  • execute_command: Execute shell command
  • list_directory: List directory contents
  • git_status: Get git repository status

Ready! Start chatting (type 'exit' or 'quit' to end)

You: What files are in the current directory?

[Executing 1 tool(s)...]
  ✓ list_directory
```