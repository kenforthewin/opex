defmodule OpEx.Client do
  @moduledoc """
  HTTP client for OpenRouter API.
  Handles API requests with retry logic and error handling.
  """

  require Logger

  @default_base_url "https://openrouter.ai/api/v1"
  @default_user_agent "opex/0.1.0"

  defstruct [:req]

  @doc """
  Creates a new OpenRouter client with the given API key and options.

  ## Options

  * `:base_url` - Base URL for OpenRouter API (default: "https://openrouter.ai/api/v1")
  * `:user_agent` - User agent string (default: "opex/0.1.0")
  * `:app_title` - Application title for X-Title header (optional)
  """
  def new(api_key, opts \\ []) do
    base_url = Keyword.get(opts, :base_url, @default_base_url)
    user_agent = Keyword.get(opts, :user_agent, @default_user_agent)
    app_title = Keyword.get(opts, :app_title)

    req =
      Req.new(base_url: base_url)
      |> Req.Request.put_header("Authorization", "Bearer #{api_key}")
      |> Req.Request.put_header("User-Agent", user_agent)

    req =
      if app_title do
        Req.Request.put_header(req, "X-Title", app_title)
      else
        req
      end

    %__MODULE__{req: req}
  end

  @doc """
  Fetches the list of available models from OpenRouter API.
  Returns {:ok, models} where models is a list of %{id: string, name: string}
  """
  def get_models(%__MODULE__{} = client) do
    case request(client, :get, "/models") do
      {:ok, %{"data" => models}} ->
        formatted_models =
          Enum.map(models, fn model ->
            %{
              id: model["id"],
              name: model["name"] || model["id"]
            }
          end)

        {:ok, formatted_models}

      {:ok, unexpected} ->
        Logger.error("Unexpected response format from /models: #{inspect(unexpected)}")
        {:error, "Unexpected response format"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Makes a chat completion request to OpenRouter.

  ## Parameters

  * `client` - The OpEx.Client struct
  * `body` - Request body containing messages, model, tools, etc.

  ## Returns

  * `{:ok, response}` - Successful response with choices
  * `{:error, reason}` - Error response
  """
  def chat_completion(%__MODULE__{} = client, body) do
    retry_on_transient_error(fn ->
      case request(client, :post, "/chat/completions", json: body) do
        {:ok, response_body} ->
          # Check for errors embedded in the response body
          case check_for_embedded_errors(response_body) do
            {:error, converted_error} ->
              Logger.info("Found embedded error, converting for retry: #{inspect(converted_error)}")
              {:error, converted_error}

            :ok ->
              {:ok, response_body}
          end

        error ->
          error
      end
    end)
  end

  # Private functions

  defp request(%__MODULE__{req: req}, method, path, opts \\ []) do
    opts = Keyword.merge(opts, method: method, url: path)

    case Req.request(req, opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp check_for_embedded_errors(%{"choices" => [%{"error" => error_info} | _]}) do
    # Extract error details and convert to retryable format
    error_code = get_in(error_info, ["code"])
    error_message = get_in(error_info, ["message"])

    # Handle specific error code mappings for rate limits
    final_status =
      case error_code do
        # Rate limit from OpenAI reported as 502, treat as 429
        502 -> 429
        code -> code
      end

    # Convert to the format expected by retry logic
    {:error, %{status: final_status, body: %{error: %{message: error_message}}}}
  end

  defp check_for_embedded_errors(%{"error" => error_info}) do
    # Handle top-level error responses (e.g., provider errors)
    error_code = get_in(error_info, ["code"])
    error_message = get_in(error_info, ["message"])

    # Handle specific error code mappings for rate limits
    final_status =
      case error_code do
        # Rate limit from OpenAI reported as 502, treat as 429
        502 -> 429
        code -> code
      end

    # Convert to the format expected by retry logic
    {:error, %{status: final_status, body: %{error: %{message: error_message}}}}
  end

  defp check_for_embedded_errors(_response), do: :ok

  defp retry_on_transient_error(fun, attempt \\ 1, max_retries \\ 3) do
    case fun.() do
      # Handle successful responses
      {:ok, response} ->
        {:ok, response}

      # Handle HTTP status code errors that should be retried
      {:error, %{status: status} = error} when status in [429, 500, 502, 503, 504, 508] ->
        if attempt <= max_retries do
          delay_ms = calculate_backoff_delay(status, attempt)
          error_type = get_error_type(status)
          Logger.warning("#{error_type} (#{status}), retrying attempt #{attempt}/#{max_retries} after #{delay_ms}ms...")
          Process.sleep(delay_ms)
          retry_on_transient_error(fun, attempt + 1, max_retries)
        else
          Logger.error("Max retries (#{max_retries}) exceeded for HTTP #{status} error")
          {:error, error}
        end

      # Handle other HTTP errors (don't retry)
      {:error, %{status: _status} = error} ->
        {:error, error}

      # Handle other non-retryable errors
      {:error, error} ->
        {:error, error}
    end
  rescue
    # Handle transport errors
    error in [Req.TransportError] ->
      case error do
        %Req.TransportError{reason: reason} when reason in [:closed, :timeout, :econnrefused, :nxdomain] ->
          if attempt <= max_retries do
            delay_ms = calculate_transport_backoff_delay(reason, attempt)

            Logger.warning(
              "Transport error (#{reason}), retrying attempt #{attempt}/#{max_retries} after #{delay_ms}ms..."
            )

            Process.sleep(delay_ms)
            retry_on_transient_error(fun, attempt + 1, max_retries)
          else
            Logger.error("Max retries (#{max_retries}) exceeded for transport error: #{reason}")
            {:error, error}
          end

        _ ->
          reraise error, __STACKTRACE__
      end

    other_error ->
      reraise other_error, __STACKTRACE__
  end

  defp calculate_backoff_delay(status, attempt) do
    base_delay =
      case status do
        # Rate limits: start with 5 seconds
        429 -> 5000
        # Server errors: start with 2 seconds
        _ -> 2000
      end

    (:math.pow(2, attempt - 1) * base_delay) |> round()
  end

  defp calculate_transport_backoff_delay(_reason, attempt) do
    # Standard exponential backoff for transport errors
    (:math.pow(2, attempt - 1) * 1000) |> round()
  end

  defp get_error_type(status) do
    case status do
      429 -> "Rate limited"
      500 -> "Internal server error"
      502 -> "Bad gateway"
      503 -> "Service unavailable"
      504 -> "Gateway timeout"
      508 -> "Loop detected"
      _ -> "Server error"
    end
  end
end
