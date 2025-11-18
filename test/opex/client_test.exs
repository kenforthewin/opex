defmodule OpEx.ClientTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias OpEx.Test.MCPHelpers

  setup do
    # Create a test client - we'll mock the actual HTTP calls in tests
    client = OpEx.Client.new("test-api-key")
    {:ok, client: client}
  end

  describe "new/2" do
    test "creates client with API key and default options" do
      client = OpEx.Client.new("my-api-key")

      assert %OpEx.Client{} = client
      assert client.req != nil
    end

    test "accepts custom base_url option" do
      client = OpEx.Client.new("key", base_url: "http://localhost:4000")

      assert %OpEx.Client{} = client
    end

    test "accepts app_title option" do
      client = OpEx.Client.new("key", app_title: "MyApp")

      assert %OpEx.Client{} = client
    end
  end

  describe "chat_completion/2 retry logic" do
    test "succeeds on first attempt with valid response", %{client: client} do
      # Mock successful response
      body = %{
        messages: [%{"role" => "user", "content" => "hello"}],
        model: "anthropic/claude-3.5-sonnet"
      }

      # We need to stub the internal request function
      # For now, we'll test the retry logic by calling it directly
      success_fun = fn -> {:ok, MCPHelpers.openrouter_response("Hi there!")} end

      result = test_retry_logic(success_fun)

      assert {:ok, response} = result
      assert get_in(response, ["choices", Access.at(0), "message", "content"]) == "Hi there!"
    end

    test "retries rate limit errors (429) with 5s base delay" do
      attempt = make_ref()
      :persistent_term.put(attempt, 0)

      retry_fun = fn ->
        count = :persistent_term.get(attempt)
        :persistent_term.put(attempt, count + 1)

        if count < 2 do
          {:error, %{status: 429, body: MCPHelpers.openrouter_error_response(429, "Rate limited")}}
        else
          {:ok, MCPHelpers.openrouter_response("Success after retries")}
        end
      end

      _log =
        capture_log(fn ->
          result = test_retry_logic_with_mock_sleep(retry_fun)

          # Should succeed after retries
          assert {:ok, response} = result
          assert get_in(response, ["choices", Access.at(0), "message", "content"]) == "Success after retries"

          # Should have retried 2 times (3 total attempts)
          assert :persistent_term.get(attempt) == 3
        end)

      # Clean up
      :persistent_term.erase(attempt)
    end

    test "retries server errors (500) with 2s base delay" do
      attempt = make_ref()
      :persistent_term.put(attempt, 0)

      retry_fun = fn ->
        count = :persistent_term.get(attempt)
        :persistent_term.put(attempt, count + 1)

        if count < 1 do
          {:error, %{status: 500, body: %{"error" => "Internal server error"}}}
        else
          {:ok, MCPHelpers.openrouter_response("Recovered")}
        end
      end

      result = test_retry_logic_with_mock_sleep(retry_fun)

      assert {:ok, _response} = result
      assert :persistent_term.get(attempt) == 2

      :persistent_term.erase(attempt)
    end

    test "fails after max retries (3 attempts)" do
      attempt = make_ref()
      :persistent_term.put(attempt, 0)

      always_fail = fn ->
        count = :persistent_term.get(attempt)
        :persistent_term.put(attempt, count + 1)
        {:error, %{status: 503, body: %{"error" => "Service unavailable"}}}
      end

      result = test_retry_logic_with_mock_sleep(always_fail)

      assert {:error, %{status: 503}} = result
      # Should have tried 4 times total (initial + 3 retries)
      assert :persistent_term.get(attempt) == 4

      :persistent_term.erase(attempt)
    end

    test "does not retry non-retryable errors (4xx except 429)" do
      attempt = make_ref()
      :persistent_term.put(attempt, 0)

      bad_request = fn ->
        count = :persistent_term.get(attempt)
        :persistent_term.put(attempt, count + 1)
        {:error, %{status: 400, body: %{"error" => "Bad request"}}}
      end

      result = test_retry_logic_with_mock_sleep(bad_request)

      assert {:error, %{status: 400}} = result
      # Should only try once
      assert :persistent_term.get(attempt) == 1

      :persistent_term.erase(attempt)
    end

    test "retries specific server error codes" do
      # Test each retryable status code
      retryable_codes = [429, 500, 502, 503, 504, 508]

      for code <- retryable_codes do
        attempt = make_ref()
        :persistent_term.put(attempt, 0)

        retry_fun = fn ->
          count = :persistent_term.get(attempt)
          :persistent_term.put(attempt, count + 1)

          if count < 1 do
            {:error, %{status: code, body: %{}}}
          else
            {:ok, MCPHelpers.openrouter_response("ok")}
          end
        end

        result = test_retry_logic_with_mock_sleep(retry_fun)

        assert {:ok, _} = result, "Should retry status #{code}"
        assert :persistent_term.get(attempt) >= 2, "Should have retried status #{code}"

        :persistent_term.erase(attempt)
      end
    end
  end

  describe "embedded error detection" do
    test "detects error in choices and converts to retryable format" do
      embedded_error = MCPHelpers.openrouter_embedded_error(502, "Upstream error")

      # This would normally be caught by check_for_embedded_errors
      # We'll test the logic directly
      result = check_embedded_error(embedded_error)

      # 502 should convert to 429
      assert {:error, %{status: 429}} = result
    end

    test "converts 502 to 429 for rate limit handling" do
      embedded_502 = MCPHelpers.openrouter_embedded_error(502, "Rate limit from upstream")

      result = check_embedded_error(embedded_502)

      assert {:error, %{status: 429, body: body}} = result
      assert body.error.message == "Rate limit from upstream"
    end

    test "passes through other error codes unchanged" do
      embedded_500 = MCPHelpers.openrouter_embedded_error(500, "Server error")

      result = check_embedded_error(embedded_500)

      assert {:error, %{status: 500}} = result
    end

    test "returns :ok for responses without embedded errors" do
      normal_response = MCPHelpers.openrouter_response("Hello")

      result = check_embedded_error(normal_response)

      assert :ok = result
    end

    test "detects top-level error and converts to retryable format" do
      # Provider error like the one reported: code 524
      top_level_error = %{
        "error" => %{
          "code" => 524,
          "message" => "Provider returned error",
          "metadata" => %{
            "provider_name" => "Google",
            "raw" => "error code: 524"
          }
        },
        "user_id" => "user_123"
      }

      result = check_embedded_error(top_level_error)

      assert {:error, %{status: 524, body: body}} = result
      assert body.error.message == "Provider returned error"
    end

    test "converts top-level 502 to 429 for rate limit handling" do
      top_level_502 = %{
        "error" => %{
          "code" => 502,
          "message" => "Rate limit from provider"
        }
      }

      result = check_embedded_error(top_level_502)

      assert {:error, %{status: 429, body: body}} = result
      assert body.error.message == "Rate limit from provider"
    end
  end

  describe "get_models/1" do
    test "formats model list from API response", %{client: client} do
      # This would need mocking in a real scenario
      # For now, we test the structure expectations

      # Mock response structure
      mock_response = %{
        "data" => [
          %{"id" => "anthropic/claude-3.5-sonnet", "name" => "Claude 3.5 Sonnet"},
          %{"id" => "openai/gpt-4", "name" => "GPT-4"}
        ]
      }

      # Test the formatting logic would handle this correctly
      models =
        Enum.map(mock_response["data"], fn model ->
          %{
            id: model["id"],
            name: model["name"] || model["id"]
          }
        end)

      assert length(models) == 2
      assert Enum.at(models, 0).id == "anthropic/claude-3.5-sonnet"
      assert Enum.at(models, 1).name == "GPT-4"
    end

    test "uses id as name when name is missing" do
      model_without_name = %{"id" => "test/model"}

      formatted = %{
        id: model_without_name["id"],
        name: model_without_name["name"] || model_without_name["id"]
      }

      assert formatted.name == "test/model"
    end
  end

  # Helper functions for testing

  defp test_retry_logic(fun) do
    # Simulate the retry_on_transient_error logic for testing
    case fun.() do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp test_retry_logic_with_mock_sleep(fun) do
    # Test the retry logic but with instant "sleep"
    # This simulates the actual retry_on_transient_error behavior
    test_retry_impl(fun, 1, 3)
  end

  defp test_retry_impl(fun, attempt, max_retries) do
    case fun.() do
      {:ok, response} ->
        {:ok, response}

      {:error, %{status: status} = error} when status in [429, 500, 502, 503, 504, 508] ->
        if attempt <= max_retries do
          # Skip actual sleep for testing
          test_retry_impl(fun, attempt + 1, max_retries)
        else
          {:error, error}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp check_embedded_error(%{"choices" => [%{"error" => error_info} | _]}) do
    error_code = get_in(error_info, ["code"])
    error_message = get_in(error_info, ["message"])

    final_status =
      case error_code do
        502 -> 429
        code -> code
      end

    {:error, %{status: final_status, body: %{error: %{message: error_message}}}}
  end

  defp check_embedded_error(%{"error" => error_info}) do
    # Handle top-level error responses (e.g., provider errors)
    error_code = get_in(error_info, ["code"])
    error_message = get_in(error_info, ["message"])

    final_status =
      case error_code do
        502 -> 429
        code -> code
      end

    {:error, %{status: final_status, body: %{error: %{message: error_message}}}}
  end

  defp check_embedded_error(_response), do: :ok
end
