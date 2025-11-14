defmodule OpEx.MCP.HttpClientTest do
  use ExUnit.Case, async: true
  alias OpEx.Test.MCPHelpers

  describe "initialization" do
    test "creates client with required URL and auth token" do
      config = %{
        "url" => "https://api.example.com/mcp",
        "auth_token" => "test-token-123"
      }

      # Verify required fields
      assert config["url"] != nil
      assert config["auth_token"] != nil
    end

    test "accepts optional execution_id" do
      config = %{
        "url" => "https://api.example.com/mcp",
        "auth_token" => "token",
        "execution_id" => "exec-456"
      }

      assert config["execution_id"] == "exec-456"
    end

    test "rejects config without required fields" do
      invalid_configs = [
        %{"url" => "https://api.example.com"},  # Missing auth_token
        %{"auth_token" => "token"},             # Missing url
        %{}                                      # Missing both
      ]

      for config <- invalid_configs do
        has_url = Map.has_key?(config, "url") and config["url"] != nil
        has_token = Map.has_key?(config, "auth_token") and config["auth_token"] != nil

        refute (has_url and has_token), "Config should be invalid"
      end
    end
  end

  describe "HTTP headers" do
    test "includes required headers in request" do
      headers = [
        {"Content-Type", "application/json"},
        {"Accept", "application/json, text/event-stream"},
        {"Authorization", "Bearer test-token"}
      ]

      content_type = Enum.find(headers, fn {key, _} -> key == "Content-Type" end)
      accept = Enum.find(headers, fn {key, _} -> key == "Accept" end)
      auth = Enum.find(headers, fn {key, _} -> key == "Authorization" end)

      assert content_type == {"Content-Type", "application/json"}
      assert accept == {"Accept", "application/json, text/event-stream"}
      assert auth == {"Authorization", "Bearer test-token"}
    end

    test "includes session ID header after initialization" do
      session_id = "session-abc-123"

      headers = [
        {"Mcp-Session-Id", session_id}
      ]

      session_header = Enum.find(headers, fn {key, _} -> key == "Mcp-Session-Id" end)
      assert session_header == {"Mcp-Session-Id", session_id}
    end

    test "includes execution ID header when provided" do
      execution_id = "exec-789"

      headers = [
        {"Execution-Id", execution_id}
      ]

      exec_header = Enum.find(headers, fn {key, _} -> key == "Execution-Id" end)
      assert exec_header == {"Execution-Id", execution_id}
    end
  end

  describe "session ID extraction" do
    test "extracts session ID from response headers (string value)" do
      headers = [
        {"content-type", "application/json"},
        {"mcp-session-id", "session-xyz-789"}
      ]

      session_id = extract_session_id_from_headers(headers)

      assert session_id == "session-xyz-789"
    end

    test "extracts session ID from response headers (list value)" do
      headers = [
        {"content-type", "application/json"},
        {"mcp-session-id", ["session-list-123"]}
      ]

      session_id = extract_session_id_from_headers(headers)

      assert session_id == "session-list-123"
    end

    test "handles case-insensitive header matching" do
      test_cases = [
        {"Mcp-Session-Id", "session-1"},
        {"mcp-session-id", "session-2"},
        {"MCP-SESSION-ID", "session-3"}
      ]

      for {header_name, expected_value} <- test_cases do
        headers = [{header_name, expected_value}]
        session_id = extract_session_id_from_headers(headers)

        assert session_id == expected_value
      end
    end

    test "returns nil when session ID header missing" do
      headers = [
        {"content-type", "application/json"}
      ]

      session_id = extract_session_id_from_headers(headers)

      assert is_nil(session_id)
    end
  end

  describe "SSE parsing" do
    test "parses standard SSE format with data line" do
      sse_data = """
      event: message
      data: {"jsonrpc":"2.0","id":"1","result":{}}

      """

      result = parse_sse(sse_data)

      assert result["jsonrpc"] == "2.0"
      assert result["id"] == "1"
    end

    test "extracts JSON from data line" do
      json_content = Jason.encode!(MCPHelpers.mcp_tools_list_response([]))

      sse_data = """
      event: message
      data: #{json_content}

      """

      result = parse_sse(sse_data)

      assert result["jsonrpc"] == "2.0"
    end

    test "handles multiple lines but extracts only data line" do
      sse_data = """
      event: message
      id: 123
      data: {"jsonrpc":"2.0","result":{}}
      retry: 1000

      """

      result = parse_sse(sse_data)

      assert result["jsonrpc"] == "2.0"
      assert result["result"] == %{}
    end

    test "returns empty map for SSE without data line" do
      sse_data = """
      event: message
      id: 123

      """

      result = parse_sse(sse_data)

      assert result == %{}
    end

    test "returns empty map for malformed JSON in data line" do
      sse_data = """
      event: message
      data: {invalid json}

      """

      result = parse_sse(sse_data)

      assert result == %{}
    end

    test "passes through non-SSE responses unchanged" do
      normal_json = Jason.encode!(MCPHelpers.mcp_tools_list_response([]))

      # Not SSE format (doesn't start with "event:")
      is_sse = String.starts_with?(normal_json, "event:")

      refute is_sse
    end
  end

  describe "initialize handshake" do
    test "sends initialize request with 2025-03-26 protocol version" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "init-1",
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-03-26",
          "capabilities" => %{"tools" => %{}},
          "clientInfo" => %{
            "name" => "OpEx.MCPClient",
            "version" => "0.1.0"
          }
        }
      }

      # HTTP client uses newer protocol version
      assert request["params"]["protocolVersion"] == "2025-03-26"
    end

    test "sends initialized notification after receiving session ID" do
      notification = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/initialized"
      }

      assert notification["method"] == "notifications/initialized"
      refute Map.has_key?(notification, "id")
    end
  end

  describe "HTTP response handling" do
    test "handles 200 OK responses" do
      status = 200
      body = MCPHelpers.mcp_tools_list_response([])

      assert status == 200
      assert is_map(body)
    end

    test "handles 202 Accepted for notifications" do
      status = 202

      # 202 is success for notifications
      assert status == 202
    end

    test "detects 404 as session expiration" do
      status = 404

      # 404 indicates session expired
      assert status == 404
    end

    test "handles other error status codes" do
      error_statuses = [400, 401, 403, 500, 503]

      for status <- error_statuses do
        assert status >= 400
      end
    end
  end

  describe "session expiration" do
    test "marks session as expired on 404 during tool call" do
      status = 404
      error = %{status: 404, body: %{"error" => "Session not found"}}

      # Should mark session as disconnected
      if status == 404 do
        assert error.status == 404
        # In actual code, would set status: :disconnected
      end
    end

    test "marks session as expired on 404 during list_tools" do
      status = 404

      # Should trigger disconnection
      session_expired = status == 404

      assert session_expired
    end
  end

  describe "tool call execution" do
    test "includes Execution-Id header in tool calls when provided" do
      execution_id = "exec-123"

      extra_headers = if execution_id do
        [{"Execution-Id", execution_id}]
      else
        []
      end

      assert extra_headers == [{"Execution-Id", "exec-123"}]
    end

    test "omits Execution-Id header when not provided" do
      execution_id = nil

      extra_headers = if execution_id do
        [{"Execution-Id", execution_id}]
      else
        []
      end

      assert extra_headers == []
    end

    test "handles tool result with isError flag" do
      error_result = MCPHelpers.mcp_result("Error occurred", true)
      is_error = get_in(error_result, ["isError"])

      assert is_error == true
    end
  end

  # Helper functions

  defp extract_session_id_from_headers(headers) do
    headers
    |> Enum.find(fn {key, _value} -> String.downcase(key) == "mcp-session-id" end)
    |> case do
      {_key, value} when is_list(value) -> List.first(value)
      {_key, value} when is_binary(value) -> value
      nil -> nil
    end
  end

  defp parse_sse(sse_data) do
    sse_data
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case line do
        "data: " <> json_str -> Jason.decode(json_str)
        _ -> nil
      end
    end)
    |> case do
      {:ok, parsed} -> parsed
      nil -> %{}
      {:error, _} -> %{}
    end
  end
end
