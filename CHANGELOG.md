# Changelog

## [0.2.4] - 2025-11-18

### Added
- Hook stop mechanism: `on_tool_result` and `on_assistant_message` hooks can now return `:stop` or `{:stop, context}` to immediately halt the tool execution loop. When stopped, the response includes `_metadata.stopped_by_hook = true`. Useful for implementing rate limits, cost controls, or custom error handling.

## [0.2.3] - 2025-11-18

Better error handling.

## [0.2.2] - 2025-11-18

Allow configurable role for tool call responses.

## [0.2.1] - 2025-11-17

Support for non-standard MCP server responses.

## [0.2.0] - 2025-11-17

Add `parallel_tool_calls` support.

## [0.1.0] - 2025-11-14

Initial release.
