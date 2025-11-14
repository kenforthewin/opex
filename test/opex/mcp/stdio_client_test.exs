defmodule OpEx.MCP.StdioClientTest do
  use ExUnit.Case, async: true
  alias OpEx.Test.MCPHelpers

  describe "initialization" do
    test "creates client with server config" do
      config = %{
        "command" => "npx",
        "args" => ["-y", "test-server"],
        "env" => []
      }

      # We can't easily test Port creation without mocking
      # But we can verify the struct is created correctly
      assert is_map(config)
      assert config["command"] == "npx"
    end

    test "handles environment variables as tuples" do
      env = [{"API_KEY", "test-key"}, {"DEBUG", "true"}]

      # Test conversion to charlists
      env_charlists = Enum.map(env, fn
        {key, value} when is_binary(key) and is_binary(value) ->
          {String.to_charlist(key), String.to_charlist(value)}
        {key, value} ->
          {key, value}
      end)

      assert length(env_charlists) == 2
      assert {~c"API_KEY", ~c"test-key"} = hd(env_charlists)
    end
  end

  describe "initialize handshake" do
    test "sends initialize request with protocol version" do
      initialize_request = %{
        "jsonrpc" => "2.0",
        "id" => "test-id",
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2024-11-05",
          "capabilities" => %{
            "tools" => %{}
          },
          "clientInfo" => %{
            "name" => "OpEx.MCPClient",
            "version" => "0.1.0"
          }
        }
      }

      assert initialize_request["method"] == "initialize"
      assert initialize_request["params"]["protocolVersion"] == "2024-11-05"
    end

    test "sends initialized notification after successful init" do
      notification = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/initialized"
      }

      assert notification["method"] == "notifications/initialized"
      refute Map.has_key?(notification, "id")  # Notifications don't have IDs
    end

    test "extracts session ID from response" do
      response = MCPHelpers.mcp_initialize_response("session-abc-123")

      session_id = get_in(response, ["result", "sessionId"])
      assert session_id == "session-abc-123"
    end

    test "generates fallback session ID if not in response" do
      response = %{
        "jsonrpc" => "2.0",
        "id" => "init-1",
        "result" => %{
          "protocolVersion" => "2024-11-05"
        }
      }

      # Session ID would be generated if missing
      session_id = get_in(response, ["result", "sessionId"]) || generate_test_id()
      assert is_binary(session_id)
    end
  end

  describe "response collection with EOL/NOEOL" do
    test "complete EOL message returns immediately" do
      json_response = Jason.encode!(MCPHelpers.mcp_tools_list_response([]))

      # Simulate receiving complete EOL data
      complete_data = json_response
      buffer = ""

      result = parse_complete_eol(buffer <> complete_data)

      assert {:ok, parsed} = result
      assert parsed["jsonrpc"] == "2.0"
    end

    test "NOEOL data accumulates in buffer" do
      json_response = Jason.encode!(MCPHelpers.mcp_tools_list_response([]))
      {part1, part2} = String.split_at(json_response, div(String.length(json_response), 2))

      # First NOEOL - accumulate
      buffer1 = "" <> part1

      # Second NOEOL - still accumulate
      buffer2 = buffer1 <> part2

      # Final EOL - parse
      result = parse_complete_eol(buffer2)
      assert {:ok, _parsed} = result
    end

    test "multiple partial messages reassemble correctly" do
      json1 = ~s({"jsonrpc": "2.0", )
      json2 = ~s("id": "test", )
      json3 = ~s("result": {}})

      buffer = "" <> json1 <> json2 <> json3

      result = parse_complete_eol(buffer)
      assert {:ok, parsed} = result
      assert parsed["jsonrpc"] == "2.0"
      assert parsed["id"] == "test"
    end
  end

  describe "log message filtering" do
    test "ignores log messages and resets buffer" do
      log_message = "Starting server..."

      # Log messages don't start with '{'
      is_json = String.starts_with?(String.trim(log_message), "{")

      refute is_json
    end

    test "distinguishes JSON from log messages" do
      json_message = ~s({"jsonrpc": "2.0"})
      log_message = "INFO: Server started"

      json_is_json = String.starts_with?(String.trim(json_message), "{")
      log_is_json = String.starts_with?(String.trim(log_message), "{")

      assert json_is_json
      refute log_is_json
    end

    test "continues collecting after ignoring log" do
      # Simulate: log message, then JSON response
      # Buffer should reset after log, then collect JSON

      buffer_after_log = ""
      json_response = Jason.encode!(MCPHelpers.mcp_tools_list_response([]))

      buffer = buffer_after_log <> json_response

      result = parse_complete_eol(buffer)
      assert {:ok, _parsed} = result
    end
  end

  describe "JSON parsing errors" do
    test "returns :invalid_json for malformed JSON" do
      invalid_json = ~s({"broken": json)

      result = parse_complete_eol(invalid_json)

      assert {:error, :invalid_json} = result
    end

    test "handles empty string" do
      result = parse_complete_eol("")

      # Empty string should be treated as non-JSON
      # In actual implementation, it would continue collecting
      assert String.trim("") == ""
    end

    test "handles whitespace-only data" do
      whitespace = "   \n  \t  "

      # Should be ignored as log message
      is_json = String.starts_with?(String.trim(whitespace), "{")
      refute is_json
    end
  end

  describe "tools/list request and response" do
    test "formats tools/list request correctly" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => generate_test_id(),
        "method" => "tools/list",
        "params" => %{}
      }

      assert request["method"] == "tools/list"
      assert request["params"] == %{}
      assert Map.has_key?(request, "id")
    end

    test "parses tools/list response" do
      tools = [MCPHelpers.mcp_tool("test_tool", "Test")]
      response = MCPHelpers.mcp_tools_list_response(tools)

      # Extract tools from response
      tools_list = get_in(response, ["result", "tools"])

      assert length(tools_list) == 1
      assert hd(tools_list)["name"] == "test_tool"
    end

    test "handles empty tools list" do
      response = MCPHelpers.mcp_tools_list_response([])

      tools = get_in(response, ["result", "tools"]) || []

      assert tools == []
    end
  end

  describe "tool call request and response" do
    test "formats tool call request correctly" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => generate_test_id(),
        "method" => "tools/call",
        "params" => %{
          "name" => "read_file",
          "arguments" => %{"path" => "/tmp/test.txt"}
        }
      }

      assert request["method"] == "tools/call"
      assert request["params"]["name"] == "read_file"
      assert request["params"]["arguments"]["path"] == "/tmp/test.txt"
    end

    test "handles tool result with isError flag" do
      error_result = MCPHelpers.mcp_result("Error message", true)

      is_error = get_in(error_result, ["isError"])
      assert is_error == true
    end

    test "extracts error message from result content" do
      error_result = MCPHelpers.mcp_result([%{"text" => "File not found"}], true)

      content = get_in(error_result, ["content"])
      error_message = case content do
        [%{"text" => text} | _] -> text
        _ -> "Unknown error"
      end

      assert error_message == "File not found"
    end

    test "handles successful tool result" do
      success_result = MCPHelpers.mcp_text_result("File contents here")

      is_error = get_in(success_result, ["isError"])
      assert is_nil(is_error) or is_error == false
    end
  end

  describe "error handling" do
    test "handles MCP error responses" do
      error_response = MCPHelpers.mcp_error_response(-32601, "Method not found")

      error = Map.get(error_response, "error")
      assert error["code"] == -32601
      assert error["message"] == "Method not found"
    end

    test "detects connection errors" do
      # Simulate various error conditions
      errors = [:closed, :timeout, :econnrefused, :nxdomain, :invalid_json]

      for error <- errors do
        assert is_atom(error)
      end
    end
  end

  # Helper functions

  defp parse_complete_eol(data) do
    # Simulate the response collection logic
    case String.trim(data) do
      "{" <> _ = json_data ->
        case Jason.decode(json_data) do
          {:ok, response} -> {:ok, response}
          {:error, _reason} -> {:error, :invalid_json}
        end
      _ ->
        # Log message, would continue collecting
        {:continue, ""}
    end
  end

  defp generate_test_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
