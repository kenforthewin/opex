defmodule OpEx.MCP.ToolsTest do
  use ExUnit.Case, async: true
  alias OpEx.Test.MCPHelpers

  describe "convert_to_openai_format/1" do
    test "converts MCP tool to OpenAI format with all fields" do
      mcp_tool = MCPHelpers.mcp_tool(
        "read_file",
        "Read a file from filesystem",
        %{
          "path" => %{"type" => "string", "description" => "File path"}
        },
        ["path"]
      )

      result = OpEx.MCP.Tools.convert_to_openai_format(mcp_tool)

      assert result["type"] == "function"
      assert result["function"]["name"] == "read_file"
      assert result["function"]["description"] == "Read a file from filesystem"
      assert result["function"]["parameters"]["type"] == "object"
      assert result["function"]["parameters"]["properties"]["path"]["type"] == "string"
      assert result["function"]["parameters"]["required"] == ["path"]
    end

    test "handles missing required array with empty list" do
      mcp_tool = %{
        "name" => "test_tool",
        "description" => "Test",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{}
        }
      }

      result = OpEx.MCP.Tools.convert_to_openai_format(mcp_tool)

      assert result["function"]["parameters"]["required"] == []
    end

    test "preserves complex nested properties" do
      mcp_tool = MCPHelpers.mcp_tool(
        "complex_tool",
        "Complex tool",
        %{
          "config" => %{
            "type" => "object",
            "properties" => %{
              "nested" => %{"type" => "string"}
            }
          }
        },
        []
      )

      result = OpEx.MCP.Tools.convert_to_openai_format(mcp_tool)

      nested_props = result["function"]["parameters"]["properties"]["config"]["properties"]
      assert nested_props["nested"]["type"] == "string"
    end
  end

  describe "convert_tools_to_openai_format/2" do
    test "converts list of MCP tools" do
      tools = [
        MCPHelpers.mcp_tool("tool1", "First tool"),
        MCPHelpers.mcp_tool("tool2", "Second tool")
      ]

      result = OpEx.MCP.Tools.convert_tools_to_openai_format(tools)

      assert length(result) == 2
      assert Enum.at(result, 0)["function"]["name"] == "tool1"
      assert Enum.at(result, 1)["function"]["name"] == "tool2"
    end

    test "filters rejected tools" do
      tools = [
        MCPHelpers.mcp_tool("keep_me", "Keep this"),
        MCPHelpers.mcp_tool("reject_me", "Reject this"),
        MCPHelpers.mcp_tool("also_keep", "Also keep")
      ]

      result = OpEx.MCP.Tools.convert_tools_to_openai_format(tools, ["reject_me"])

      assert length(result) == 2
      names = Enum.map(result, & &1["function"]["name"])
      assert "keep_me" in names
      assert "also_keep" in names
      refute "reject_me" in names
    end

    test "returns empty list for empty input" do
      assert OpEx.MCP.Tools.convert_tools_to_openai_format([]) == []
    end
  end

  describe "extract_tool_call/1" do
    test "extracts tool name and arguments from valid tool call" do
      tool_call = MCPHelpers.tool_call("call_123", "search", %{"query" => "test"})

      assert {:ok, "search", %{"query" => "test"}} =
        OpEx.MCP.Tools.extract_tool_call(tool_call)
    end

    test "handles empty arguments string" do
      tool_call = %{
        "id" => "call_123",
        "function" => %{
          "name" => "no_args_tool",
          "arguments" => ""
        }
      }

      assert {:ok, "no_args_tool", %{}} =
        OpEx.MCP.Tools.extract_tool_call(tool_call)
    end

    test "returns error for invalid JSON in arguments" do
      tool_call = %{
        "id" => "call_123",
        "function" => %{
          "name" => "bad_tool",
          "arguments" => "{invalid json"
        }
      }

      assert {:error, :invalid_arguments} =
        OpEx.MCP.Tools.extract_tool_call(tool_call)
    end

    test "handles complex nested arguments" do
      args = %{"config" => %{"nested" => %{"deep" => "value"}}}
      tool_call = MCPHelpers.tool_call("call_123", "complex", args)

      assert {:ok, "complex", result_args} =
        OpEx.MCP.Tools.extract_tool_call(tool_call)

      assert get_in(result_args, ["config", "nested", "deep"]) == "value"
    end
  end

  describe "format_tool_result/2" do
    test "formats result with list content as joined text" do
      mcp_result = MCPHelpers.mcp_text_result("Hello world")

      result = OpEx.MCP.Tools.format_tool_result("call_123", mcp_result)

      assert result["role"] == "tool"
      assert result["tool_call_id"] == "call_123"
      assert result["content"] == "Hello world"
    end

    test "formats result with multiple text items" do
      mcp_result = %{
        "content" => [
          %{"type" => "text", "text" => "First"},
          %{"type" => "text", "text" => "Second"}
        ]
      }

      result = OpEx.MCP.Tools.format_tool_result("call_123", mcp_result)

      assert result["content"] == "First\nSecond"
    end

    test "handles string content directly" do
      mcp_result = %{"content" => "Direct string"}

      result = OpEx.MCP.Tools.format_tool_result("call_123", mcp_result)

      assert result["content"] == "Direct string"
    end

    test "JSON encodes non-content results" do
      mcp_result = %{"data" => "value", "count" => 42}

      result = OpEx.MCP.Tools.format_tool_result("call_123", mcp_result)

      decoded = Jason.decode!(result["content"])
      assert decoded["data"] == "value"
      assert decoded["count"] == 42
    end

    test "handles text content without type field" do
      mcp_result = %{
        "content" => [
          %{"text" => "No type field"}
        ]
      }

      result = OpEx.MCP.Tools.format_tool_result("call_123", mcp_result)

      assert result["content"] == "No type field"
    end

    test "handles binary string content in list" do
      mcp_result = %{
        "content" => ["plain", "strings"]
      }

      result = OpEx.MCP.Tools.format_tool_result("call_123", mcp_result)

      # Should JSON encode list items that aren't text objects
      assert result["content"] =~ "plain"
    end
  end
end
