# Integration test to validate MCP result parsing
# This script tests how OpEx.MCP.Tools.format_tool_result handles different MCP result formats

IO.puts("Testing MCP Result Parsing")
IO.puts("=" <> String.duplicate("=", 60))
IO.puts("")

# Test Case 1: Standard MCP format (wrapped in "content" key)
IO.puts("Test 1: Standard MCP format with content wrapper")
standard_result = %{
  "content" => [
    %{"type" => "text", "text" => "File contents: Hello World"}
  ]
}

formatted = OpEx.MCP.Tools.format_tool_result("call_123", standard_result)
IO.puts("Input:  %{\"content\" => [{\"type\" => \"text\", \"text\" => \"...\"}]}")
IO.puts("Output: #{inspect(formatted["content"])}")
IO.puts("Expected: \"File contents: Hello World\"")
IO.puts("Status: #{if formatted["content"] == "File contents: Hello World", do: "✓ PASS", else: "✗ FAIL"}")
IO.puts("")

# Test Case 2: Direct content array (some MCP servers return this)
IO.puts("Test 2: Direct content array (no wrapper)")
direct_array_result = [
  %{"type" => "text", "text" => "File contents: Hello World"}
]

formatted = OpEx.MCP.Tools.format_tool_result("call_456", direct_array_result)
IO.puts("Input:  [{\"type\" => \"text\", \"text\" => \"...\"}]")
IO.puts("Output: #{inspect(formatted["content"])}")
IO.puts("Expected: \"File contents: Hello World\"")

# Check if it's JSON-encoded (the bug)
is_json_encoded = String.starts_with?(formatted["content"], "[{")
IO.puts("Status: #{if is_json_encoded, do: "✗ FAIL (JSON-encoded!)", else: "✓ PASS"}")
IO.puts("")

# Test Case 3: Multiple content items in direct array
IO.puts("Test 3: Multiple items in direct array")
multi_item_result = [
  %{"type" => "text", "text" => "Line 1"},
  %{"type" => "text", "text" => "Line 2"}
]

formatted = OpEx.MCP.Tools.format_tool_result("call_789", multi_item_result)
IO.puts("Input:  [{\"type\" => \"text\", \"text\" => \"Line 1\"}, {\"type\" => \"text\", \"text\" => \"Line 2\"}]")
IO.puts("Output: #{inspect(formatted["content"])}")
IO.puts("Expected: \"Line 1\\nLine 2\"")

is_json_encoded = String.starts_with?(formatted["content"], "[{")
IO.puts("Status: #{if is_json_encoded, do: "✗ FAIL (JSON-encoded!)", else: "✓ PASS"}")
IO.puts("")

# Test Case 4: Non-MCP array (should be JSON-encoded)
IO.puts("Test 4: Non-MCP array (should be JSON-encoded)")
non_mcp_array = ["plain", "strings", 123]

formatted = OpEx.MCP.Tools.format_tool_result("call_999", non_mcp_array)
IO.puts("Input:  [\"plain\", \"strings\", 123]")
IO.puts("Output: #{inspect(formatted["content"])}")
IO.puts("Expected: JSON-encoded array")

is_json = String.starts_with?(formatted["content"], "[")
IO.puts("Status: #{if is_json, do: "✓ PASS (correctly JSON-encoded)", else: "✗ FAIL"}")
IO.puts("")

IO.puts("=" <> String.duplicate("=", 60))
IO.puts("SUMMARY:")
IO.puts("Test 2 and Test 3 should FAIL with current implementation")
IO.puts("(they get JSON-encoded instead of having text extracted)")
