defmodule OpEx.MCP.Tools do
  @moduledoc """
  Utilities for working with MCP tools and converting them to OpenAI format.
  """

  @doc """
  Converts an MCP tool definition to OpenAI-compatible tool format.

  ## Examples

      iex> mcp_tool = %{
      ...>   "name" => "read_file",
      ...>   "description" => "Read a file from the filesystem",
      ...>   "inputSchema" => %{
      ...>     "type" => "object",
      ...>     "properties" => %{
      ...>       "path" => %{"type" => "string", "description" => "File path"}
      ...>     },
      ...>     "required" => ["path"]
      ...>   }
      ...> }
      iex> OpEx.MCP.Tools.convert_to_openai_format(mcp_tool)
      %{
        "type" => "function",
        "function" => %{
          "name" => "read_file",
          "description" => "Read a file from the filesystem",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "path" => %{"type" => "string", "description" => "File path"}
            },
            "required" => ["path"]
          }
        }
      }
  """
  def convert_to_openai_format(mcp_tool) do
    %{
      "type" => "function",
      "function" => %{
        "name" => mcp_tool["name"],
        "description" => mcp_tool["description"],
        "parameters" => %{
          "type" => "object",
          "properties" => mcp_tool["inputSchema"]["properties"],
          "required" => mcp_tool["inputSchema"]["required"] || []
        }
      }
    }
  end

  @doc """
  Converts a list of MCP tools to OpenAI format.

  ## Parameters

  * `mcp_tools` - List of MCP tool definitions
  * `rejected_tools` - List of tool names to exclude (optional, defaults to [])

  ## Examples

      iex> tools = [%{"name" => "read_file"}, %{"name" => "browser_take_screenshot"}]
      iex> OpEx.MCP.Tools.convert_tools_to_openai_format(tools, ["browser_take_screenshot"])
      # Returns only the read_file tool, screenshot tool is filtered out
  """
  def convert_tools_to_openai_format(mcp_tools, rejected_tools \\ []) when is_list(mcp_tools) do
    mcp_tools
    |> Enum.reject(&tool_rejected?(&1, rejected_tools))
    |> Enum.map(&convert_to_openai_format/1)
  end

  @doc """
  Extracts tool call information from OpenAI tool call format for MCP execution.

  ## Examples

      iex> tool_call = %{
      ...>   "id" => "call_123",
      ...>   "function" => %{
      ...>     "name" => "read_file",
      ...>     "arguments" => "{\"path\": \"/tmp/test.txt\"}"
      ...>   }
      ...> }
      iex> OpEx.MCP.Tools.extract_tool_call(tool_call)
      {:ok, "read_file", %{"path" => "/tmp/test.txt"}}
  """
  def extract_tool_call(tool_call) do
    tool_name = tool_call["function"]["name"]
    arguments_json = tool_call["function"]["arguments"]
    arguments_json = if arguments_json in [nil, ""], do: "{}", else: arguments_json

    case Jason.decode(arguments_json) do
      {:ok, args} -> {:ok, tool_name, args}
      {:error, _} -> {:error, :invalid_arguments}
    end
  end

  @doc """
  Formats MCP tool result for OpenAI tool response.

  Handles multiple MCP result formats:
  - Standard MCP format: `%{"content" => [%{"type" => "text", "text" => "..."}]}`
  - Direct content array: `[%{"type" => "text", "text" => "..."}]` (some MCP servers)
  - Direct string: `%{"content" => "string"}`
  - Other formats: JSON-encoded
  """
  def format_tool_result(tool_call_id, mcp_result) do
    content =
      case mcp_result do
        # Standard MCP format with content key containing array
        %{"content" => content} when is_list(content) ->
          content
          |> Enum.map(&extract_content_text/1)
          |> Enum.join("\n")

        # Standard MCP format with content key containing string
        %{"content" => content} when is_binary(content) ->
          content

        # Direct content array (some MCP servers return this format)
        content_array when is_list(content_array) ->
          # Check if this looks like an MCP content array
          if mcp_content_array?(content_array) do
            content_array
            |> Enum.map(&extract_content_text/1)
            |> Enum.join("\n")
          else
            # Not an MCP content array, JSON encode it
            Jason.encode!(content_array)
          end

        # Other formats: JSON encode
        other ->
          Jason.encode!(other)
      end

    %{
      "role" => "tool",
      "tool_call_id" => tool_call_id,
      "content" => content
    }
  end

  # Check if a list looks like an MCP content array
  defp mcp_content_array?([]), do: false
  defp mcp_content_array?([%{"type" => _} | _]), do: true
  defp mcp_content_array?([%{"text" => _} | _]), do: true
  defp mcp_content_array?([%{type: _} | _]), do: true
  defp mcp_content_array?([%{text: _} | _]), do: true
  defp mcp_content_array?(_), do: false

  # Extract text from MCP content items, handling both string and atom keys
  defp extract_content_text(%{"type" => "text", "text" => text}), do: text
  defp extract_content_text(%{"text" => text}), do: text
  defp extract_content_text(%{type: "text", text: text}), do: text
  defp extract_content_text(%{text: text}), do: text
  defp extract_content_text(content) when is_binary(content), do: content
  defp extract_content_text(content), do: Jason.encode!(content)

  defp tool_rejected?(tool, rejected_tools) do
    tool_name = tool["name"]
    tool_name in rejected_tools
  end
end
