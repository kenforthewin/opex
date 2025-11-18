# Test script to demonstrate configurable tool result role

IO.puts("Testing Configurable Tool Result Role")
IO.puts("=" <> String.duplicate("=", 60))
IO.puts("")

# Test 1: Default role (should be "tool")
IO.puts("Test 1: Default role (should be 'tool')")
mcp_result = %{"content" => [%{"type" => "text", "text" => "Hello"}]}
formatted = OpEx.MCP.Tools.format_tool_result("call_123", mcp_result)

IO.puts("Role: #{inspect(formatted["role"])}")
IO.puts("Has tool_call_id: #{Map.has_key?(formatted, "tool_call_id")}")
IO.puts("Status: #{if formatted["role"] == "tool" and Map.has_key?(formatted, "tool_call_id"), do: "✓ PASS", else: "✗ FAIL"}")
IO.puts("")

# Test 2: Explicit "tool" role
IO.puts("Test 2: Explicit 'tool' role")
formatted = OpEx.MCP.Tools.format_tool_result("call_456", mcp_result, "tool")

IO.puts("Role: #{inspect(formatted["role"])}")
IO.puts("Has tool_call_id: #{Map.has_key?(formatted, "tool_call_id")}")
IO.puts("Status: #{if formatted["role"] == "tool" and Map.has_key?(formatted, "tool_call_id"), do: "✓ PASS", else: "✗ FAIL"}")
IO.puts("")

# Test 3: "user" role (for MCP compatibility)
IO.puts("Test 3: 'user' role (for MCP compatibility)")
formatted = OpEx.MCP.Tools.format_tool_result("call_789", mcp_result, "user")

IO.puts("Role: #{inspect(formatted["role"])}")
IO.puts("Has tool_call_id: #{Map.has_key?(formatted, "tool_call_id")}")
IO.puts("Status: #{if formatted["role"] == "user" and not Map.has_key?(formatted, "tool_call_id"), do: "✓ PASS", else: "✗ FAIL"}")
IO.puts("")

IO.puts("=" <> String.duplicate("=", 60))
IO.puts("SUMMARY:")
IO.puts("- Default role: 'tool' with tool_call_id")
IO.puts("- Configurable to 'user' for MCP TypeScript compatibility")
IO.puts("- When role is 'user', tool_call_id is omitted")
