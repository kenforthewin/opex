defmodule OpEx.Test.MCPHelpers do
  @moduledoc """
  Test helpers for MCP protocol responses and tool definitions.
  """

  @doc """
  Creates a mock MCP tool definition.
  """
  def mcp_tool(name, description \\ "A test tool", properties \\ %{}, required \\ []) do
    %{
      "name" => name,
      "description" => description,
      "inputSchema" => %{
        "type" => "object",
        "properties" => properties,
        "required" => required
      }
    }
  end

  @doc """
  Creates an OpenAI-formatted tool definition.
  """
  def openai_tool(name, description \\ "A test tool", properties \\ %{}, required \\ []) do
    %{
      "type" => "function",
      "function" => %{
        "name" => name,
        "description" => description,
        "parameters" => %{
          "type" => "object",
          "properties" => properties,
          "required" => required
        }
      }
    }
  end

  @doc """
  Creates a mock tool call in OpenAI format.
  """
  def tool_call(id, name, args \\ %{}) do
    %{
      "id" => id,
      "type" => "function",
      "function" => %{
        "name" => name,
        "arguments" => Jason.encode!(args)
      }
    }
  end

  @doc """
  Creates a mock MCP tool result.
  """
  def mcp_result(content, is_error \\ false) do
    base = %{"content" => content}
    if is_error do
      Map.put(base, "isError", true)
    else
      base
    end
  end

  @doc """
  Creates a mock MCP tool result with text content.
  """
  def mcp_text_result(text) do
    %{
      "content" => [
        %{"type" => "text", "text" => text}
      ]
    }
  end

  @doc """
  Creates an MCP initialize response.
  """
  def mcp_initialize_response(session_id \\ "test-session-123") do
    %{
      "jsonrpc" => "2.0",
      "id" => "init-1",
      "result" => %{
        "protocolVersion" => "2024-11-05",
        "capabilities" => %{
          "tools" => %{}
        },
        "serverInfo" => %{
          "name" => "test-server",
          "version" => "1.0.0"
        },
        "sessionId" => session_id
      }
    }
  end

  @doc """
  Creates an MCP tools/list response.
  """
  def mcp_tools_list_response(tools) do
    %{
      "jsonrpc" => "2.0",
      "id" => "tools-1",
      "result" => %{
        "tools" => tools
      }
    }
  end

  @doc """
  Creates an MCP tool call response.
  """
  def mcp_tool_call_response(content) do
    %{
      "jsonrpc" => "2.0",
      "id" => "call-1",
      "result" => content
    }
  end

  @doc """
  Creates an MCP error response.
  """
  def mcp_error_response(code, message) do
    %{
      "jsonrpc" => "2.0",
      "id" => "error-1",
      "error" => %{
        "code" => code,
        "message" => message
      }
    }
  end

  @doc """
  Creates an OpenRouter chat completion response.
  """
  def openrouter_response(content, tool_calls \\ []) do
    message = %{
      "role" => "assistant",
      "content" => content
    }

    message = if tool_calls != [] do
      Map.put(message, "tool_calls", tool_calls)
    else
      message
    end

    %{
      "id" => "chatcmpl-123",
      "object" => "chat.completion",
      "created" => 1234567890,
      "model" => "anthropic/claude-3.5-sonnet",
      "choices" => [
        %{
          "index" => 0,
          "message" => message,
          "finish_reason" => "stop"
        }
      ]
    }
  end

  @doc """
  Creates an OpenRouter error response.
  """
  def openrouter_error_response(status, message) do
    %{
      "error" => %{
        "message" => message,
        "type" => "invalid_request_error",
        "code" => status
      }
    }
  end

  @doc """
  Creates an OpenRouter response with embedded error in choices.
  """
  def openrouter_embedded_error(code, message) do
    %{
      "id" => "chatcmpl-123",
      "object" => "chat.completion",
      "created" => 1234567890,
      "model" => "anthropic/claude-3.5-sonnet",
      "choices" => [
        %{
          "index" => 0,
          "error" => %{
            "code" => code,
            "message" => message
          }
        }
      ]
    }
  end
end
