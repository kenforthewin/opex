#!/usr/bin/env elixir

# OpEx Integration Demo
#
# This script demonstrates the full OpEx stack with:
# - Real OpenRouter API calls
# - Stdio MCP server (filesystem)
# - HTTP MCP server (if you have one configured)
# - Custom tools
# - All hook types
#
# Usage:
#   export OPENROUTER_KEY=your-key-here
#   elixir -S mix run scripts/integration_demo.exs
#
# Or from the opex directory:
#   cd lib/opex
#   export OPENROUTER_KEY=your-key-here
#   elixir -S mix run scripts/integration_demo.exs

defmodule IntegrationDemo do
  require Logger

  def run do
    IO.puts("\n=== OpEx Integration Demo ===\n")

    # 1. Get API key
    api_key = System.get_env("OPENROUTER_KEY")
    if is_nil(api_key) do
      IO.puts("Error: OPENROUTER_KEY environment variable not set")
      IO.puts("Usage: OPENROUTER_KEY=your-key elixir -S mix run scripts/integration_demo.exs")
      System.halt(1)
    end

    # 2. Create OpEx client
    IO.puts("📡 Creating OpenRouter client...")
    client = OpEx.Client.new(api_key,
      base_url: "https://openrouter.ai/api/v1",
      app_title: "OpEx Integration Demo"
    )
    IO.puts("✅ Client created\n")

    # 3. Start MCP servers
    IO.puts("🔧 Starting MCP servers...")

    # Start stdio MCP server (filesystem)
    stdio_config = %{
      "command" => "npx",
      "args" => ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
      "env" => []
    }

    IO.puts("  - Starting filesystem MCP server (stdio)...")
    {:ok, stdio_client} = OpEx.MCP.StdioClient.start_link(stdio_config)
    :ok = OpEx.MCP.StdioClient.connect(stdio_client)
    {:ok, stdio_tools} = OpEx.MCP.StdioClient.list_tools(stdio_client)
    IO.puts("    ✅ Connected! Available tools: #{length(stdio_tools)}")
    Enum.each(stdio_tools, fn tool ->
      IO.puts("       - #{tool["name"]}: #{tool["description"]}")
    end)

    # Start HTTP MCP server (GitHub Support Docs Search)
    IO.puts("  - Starting GitHub Support Docs MCP server (HTTP)...")

    # Get GitHub token if available (optional for this endpoint)
    github_token = System.get_env("GITHUB_TOKEN")

    http_config = %{
      "url" => "https://api.githubcopilot.com/mcp/x/github_support_docs_search",
      "auth_token" => github_token || "anonymous"
    }

    http_client = case OpEx.MCP.HttpClient.start_link(http_config) do
      {:ok, client} ->
        case OpEx.MCP.HttpClient.connect(client) do
          :ok ->
            case OpEx.MCP.HttpClient.list_tools(client) do
              {:ok, http_tools} ->
                IO.puts("    ✅ Connected! Available tools: #{length(http_tools)}")
                Enum.each(http_tools, fn tool ->
                  IO.puts("       - #{tool["name"]}: #{tool["description"]}")
                end)
                client
              {:error, reason} ->
                IO.puts("    ⚠️  Failed to list tools: #{inspect(reason)}")
                nil
            end
          {:error, reason} ->
            IO.puts("    ⚠️  Failed to connect: #{inspect(reason)}")
            nil
        end
      {:error, reason} ->
        IO.puts("    ⚠️  Failed to start HTTP MCP client: #{inspect(reason)}")
        nil
    end

    IO.puts("")

    # 4. Define custom tools
    IO.puts("🛠️  Defining custom tools...")
    custom_tools = [
      %{
        "type" => "function",
        "function" => %{
          "name" => "calculate",
          "description" => "Perform basic arithmetic calculations",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "operation" => %{
                "type" => "string",
                "enum" => ["add", "subtract", "multiply", "divide"],
                "description" => "The operation to perform"
              },
              "a" => %{"type" => "number", "description" => "First number"},
              "b" => %{"type" => "number", "description" => "Second number"}
            },
            "required" => ["operation", "a", "b"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "get_timestamp",
          "description" => "Get the current timestamp",
          "parameters" => %{
            "type" => "object",
            "properties" => %{}
          }
        }
      }
    ]
    IO.puts("  ✅ Defined #{length(custom_tools)} custom tools\n")

    # 5. Set up hooks
    IO.puts("🪝 Setting up hooks...\n")

    # Custom tool executor
    custom_tool_executor = fn tool_name, args, _context ->
      IO.puts("  🔨 Executing custom tool: #{tool_name}")
      IO.puts("     Args: #{inspect(args)}")

      case tool_name do
        "calculate" ->
          result = case args["operation"] do
            "add" -> args["a"] + args["b"]
            "subtract" -> args["a"] - args["b"]
            "multiply" -> args["a"] * args["b"]
            "divide" ->
              if args["b"] == 0 do
                {:error, "Division by zero"}
              else
                args["a"] / args["b"]
              end
            _ -> {:error, "Unknown operation"}
          end

          case result do
            {:error, msg} -> {:error, msg}
            value ->
              IO.puts("     ✅ Result: #{value}\n")
              {:ok, %{"result" => value}}
          end

        "get_timestamp" ->
          timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
          IO.puts("     ✅ Timestamp: #{timestamp}\n")
          {:ok, %{"timestamp" => timestamp}}

        _ ->
          {:error, :tool_not_found}
      end
    end

    # Hook for assistant messages
    on_assistant_message = fn message, context ->
      content = Map.get(message, "content", "")
      tool_calls = Map.get(message, "tool_calls", [])

      IO.puts("\n💬 Assistant Message:")
      if content != "" do
        IO.puts("   Content: #{content}")
      end
      if length(tool_calls) > 0 do
        IO.puts("   Tool Calls: #{length(tool_calls)}")
        Enum.each(tool_calls, fn tc ->
          tool_name = get_in(tc, ["function", "name"])
          IO.puts("     - #{tool_name}")
        end)
      end
      IO.puts("")

      {:ok, context}
    end

    # Hook for tool results
    on_tool_result = fn tool_call_id, tool_name, result, context ->
      IO.puts("  📊 Tool Result [#{tool_call_id}]:")
      IO.puts("     Tool: #{tool_name}")

      # Extract readable content from result
      content = case result do
        %{"content" => [%{"text" => text} | _]} -> text
        %{"content" => text} when is_binary(text) -> text
        %{"result" => value} -> inspect(value)
        %{"timestamp" => ts} -> ts
        other -> inspect(other)
      end

      IO.puts("     Result: #{String.slice(content, 0, 100)}#{if String.length(content) > 100, do: "...", else: ""}")
      IO.puts("")

      {:ok, context}
    end

    # 6. Create chat session
    IO.puts("🎭 Creating chat session...")

    mcp_clients = if http_client do
      [{:ok, stdio_client}, {:ok, http_client}]
    else
      [{:ok, stdio_client}]
    end

    session = OpEx.Chat.new(client,
      mcp_clients: mcp_clients,
      custom_tools: custom_tools,
      custom_tool_executor: custom_tool_executor,
      on_assistant_message: on_assistant_message,
      on_tool_result: on_tool_result
    )

    # Verify tools
    all_tools = OpEx.Chat.get_all_tools(session)
    IO.puts("  ✅ Session created with #{length(all_tools)} total tools available\n")

    # 7. Execute conversation
    IO.puts("=" <> String.duplicate("=", 60))
    IO.puts("🚀 Starting conversation...")
    IO.puts("=" <> String.duplicate("=", 60) <> "\n")

    user_prompt = """
    Please help me with these tasks:
    1. Search the GitHub support docs for information about "GitHub Actions workflow syntax"
    2. Create a file at /tmp/opex_demo.txt with the content "OpEx integration test - stdio MCP"
    3. Calculate 42 * 8
    4. Get the current timestamp

    After completing these tasks, summarize what you did and include a brief summary of what you found in the GitHub docs.
    """

    IO.puts("👤 User:")
    IO.puts("   #{String.trim(user_prompt)}\n")

    context = %{demo_run: true, start_time: System.monotonic_time(:millisecond)}

    case OpEx.Chat.chat(session,
      model: "anthropic/claude-haiku-4.5",
      messages: [%{"role" => "user", "content" => user_prompt}],
      system_prompt: "You are a helpful assistant with access to file operations, calculations, and system information. Use the available tools to complete user requests.",
      context: context,
      parallel_tool_calls: true
    ) do
      {:ok, response} ->
        elapsed = System.monotonic_time(:millisecond) - context.start_time

        IO.puts("\n" <> "=" <> String.duplicate("=", 60))
        IO.puts("✅ Conversation completed in #{elapsed}ms")
        IO.puts("=" <> String.duplicate("=", 60) <> "\n")

        final_message = get_in(response, ["choices", Access.at(0), "message", "content"])
        IO.puts("🤖 Final Response:")
        IO.puts("   #{final_message}\n")

        # Show metadata
        if metadata = response["_metadata"] do
          tool_calls_made = metadata["tool_calls_made"] || []
          IO.puts("📈 Metadata:")
          IO.puts("   Total tool calls: #{length(tool_calls_made)}")

          if length(tool_calls_made) > 0 do
            IO.puts("   Tools used:")
            tool_calls_made
            |> Enum.map(fn tc -> get_in(tc, ["function", "name"]) end)
            |> Enum.frequencies()
            |> Enum.each(fn {name, count} ->
              IO.puts("     - #{name}: #{count}x")
            end)
          end
        end

        IO.puts("\n✅ Demo completed successfully!")

      {:error, reason} ->
        IO.puts("\n❌ Error: #{inspect(reason)}")
        System.halt(1)
    end

    # 8. Cleanup
    IO.puts("\n🧹 Cleaning up...")
    OpEx.MCP.StdioClient.stop(stdio_client)
    if http_client, do: OpEx.MCP.HttpClient.stop(http_client)

    IO.puts("✅ Done!\n")
  end
end

# Run the demo
IntegrationDemo.run()
