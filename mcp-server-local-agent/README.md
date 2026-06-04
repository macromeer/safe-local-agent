## local-agent-tools

Workspace-scoped MCP tools server for local coding-agent workflows.

### Run

```bash
uv run --project /opt/safe-local-agent/mcp-server-local-agent python /opt/safe-local-agent/mcp-server-local-agent/main.py
```

### Exposed Tools

- `workspace_info`
- `list_files`
- `read_file_lines`
- `grep_text`
- `write_text_file`
- `run_local_command`

Set `MCP_WORKSPACE_ROOT` to restrict tool access to a specific root path.

## Built-In Servers

The `built_in_servers.py` launcher now serves as the built-in server repertoire for this workspace. It mirrors the upstream MCP SDK server set and lets you run a specific server by name, such as `simple_tool`, `simple_resource`, `simple_prompt`, `structured_output`, `completion`, `simple_pagination`, or `sse_polling_demo`.

```bash
uv run --project /opt/safe-local-agent/mcp-server-local-agent python /opt/safe-local-agent/mcp-server-local-agent/built_in_servers.py fastmcp_quickstart
```

Generate a ready-to-paste Cline `mcpServers` block for all stdio-compatible built-in servers:

```bash
uv run --project /opt/safe-local-agent/mcp-server-local-agent python /opt/safe-local-agent/mcp-server-local-agent/generate_cline_mcp_config.py
```
