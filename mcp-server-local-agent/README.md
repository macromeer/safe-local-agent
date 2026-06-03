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
