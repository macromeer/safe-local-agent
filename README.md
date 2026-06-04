# Safe Local Agent: Human-in-the-Loop VS Code Coding Workflow

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![GitHub stars](https://img.shields.io/github/stars/macromeer/safe-local-agent?style=social)](https://github.com/macromeer/safe-local-agent/stargazers)
[![GitHub last commit](https://img.shields.io/github/last-commit/macromeer/safe-local-agent)](https://github.com/macromeer/safe-local-agent/commits/main)

This repository helps you run a local coding agent in VS Code with strong human approval boundaries.

It combines:
- Cline as the coding-agent UI in VS Code
- Ollama as the local model runtime
- Repo-local guardrails in `.clinerules`
- Optional local MCP servers for safer, scoped tool access

## Who This Is For

Use this repo if you want to:
- run coding-agent workflows locally
- keep full control over file edits and commands
- avoid broad autonomous behavior
- start from a repeatable baseline you can fork

## What You Get

- Predefined Ollama model profiles in `profiles/`
- A workspace-scoped MCP tools server in `mcp-server-local-agent/main.py`
- A built-in MCP server repertoire launcher in `mcp-server-local-agent/built_in_servers.py`
- A generator for Cline MCP config in `mcp-server-local-agent/generate_cline_mcp_config.py`

## Quickstart

```bash
ollama pull qwen2.5-coder:14b
ollama pull qwen3:0.6b

cd /opt/safe-local-agent
ollama create cline-dev -f profiles/cline-dev/Modelfile

OLLAMA_KEEP_ALIVE=-1 ollama serve
```

Then set Cline in VS Code:
- Provider: `Ollama`
- Base URL: `http://localhost:11434`
- Model: `cline-dev`
- Mode: `Act`
- Auto-approve: `Read` only (or disabled)

Run this first prompt:

```text
Open only profiles/cline-dev/Modelfile.
Explain each line briefly.
Do not modify any files.
```

Expected result:
- Cline returns a line-by-line explanation in chat
- Cline does not propose edits

## Included Model Profiles

- `profiles/cline-deep/Modelfile` (`qwen2.5-coder:14b`, 32K context)
- `profiles/cline-dev/Modelfile` (`qwen2.5-coder:14b`, 32K context)
- `profiles/cline-fast/Modelfile` (`qwen3:0.6b`, 16K context)

## Model Selection for This Workflow

There is no single best model for every machine and team.

For local, human-in-the-loop coding, select models based on these tradeoffs:
- Quality: correctness of edits and instruction-following
- Latency: time to first useful answer
- Stability: low looping/retry behavior under constrained prompts
- Cost: local compute and memory requirements

Why Qwen is the default here:
- strong coding quality per local compute budget
- broad availability in Ollama
- practical speed/quality range across profile sizes

When another model may be better:
- you have more hardware and need stronger long-context reasoning
- your priority is minimal latency over deeper code quality
- your tasks are mostly architecture/spec reasoning instead of scoped edits

### Benchmark Protocol (Recommended)

Use this protocol before switching defaults:
1. Pick 10 to 20 real prompts from your own workflow.
2. Keep environment fixed (same repo state, Cline settings, approval mode, timeout).
3. Run each prompt on candidate models with identical wording.
4. Record for each run:
	- time to first actionable response
	- number of approval steps needed
	- number of correction prompts required
	- final pass/fail against expected outcome
5. Compare aggregate results and choose the best quality-latency-stability balance.

Suggested acceptance bar for a default model:
- high pass rate on your prompt set
- low correction count
- predictable latency on your hardware

## Full Setup

1. Install Ollama

Linux:

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

macOS:

```bash
brew install ollama
```

2. Pull base models

```bash
ollama pull qwen2.5-coder:14b
ollama pull qwen3:0.6b
```

3. Create local Cline models

```bash
cd /opt/safe-local-agent
ollama create cline-deep -f profiles/cline-deep/Modelfile
ollama create cline-dev -f profiles/cline-dev/Modelfile
ollama create cline-fast -f profiles/cline-fast/Modelfile
ollama list
```

4. Start Ollama for active sessions

```bash
OLLAMA_KEEP_ALIVE=-1 ollama serve
```

## Cline Configuration (VS Code)

Open Cline settings and set:
- Provider: `Ollama`
- Base URL: `http://localhost:11434`
- API key: empty
- Model: `cline-deep` or `cline-dev` or `cline-fast`
- Request timeout: `300000`

## Local MCP Tools Server

This repo includes a production-oriented local MCP tools server in `mcp-server-local-agent/`.

Capabilities:
- workspace info and path-safe file listing
- line-range file reads and text search
- optional write and command tools (manual approval recommended)

Add it to Cline MCP settings:

```json
{
	"mcpServers": {
		"local-agent-tools": {
			"autoApprove": [
				"workspace_info",
				"list_files",
				"read_file_lines",
				"grep_text"
			],
			"disabled": false,
			"timeout": 60,
			"transportType": "stdio",
			"command": "uv",
			"args": [
				"run",
				"--project",
				"/opt/safe-local-agent/mcp-server-local-agent",
				"python",
				"/opt/safe-local-agent/mcp-server-local-agent/main.py"
			]
		}
	}
}
```

## Built-In MCP Server Repertoire

The workspace also includes a built-in server repertoire that mirrors upstream MCP Python SDK server patterns.

Run one server by name:

```bash
uv run --project /opt/safe-local-agent/mcp-server-local-agent python /opt/safe-local-agent/mcp-server-local-agent/built_in_servers.py fastmcp_quickstart
```

If you omit the server argument, it runs the default quickstart server.

Generate a ready-to-paste Cline `mcpServers` JSON block for all stdio-compatible built-in servers:

```bash
uv run --project /opt/safe-local-agent/mcp-server-local-agent python /opt/safe-local-agent/mcp-server-local-agent/generate_cline_mcp_config.py
```

Note:
- Cline loads stdio MCP servers directly.
- Some built-in servers are HTTP/ASGI-oriented and are excluded by default from generator output.

## Safety Defaults

Recommended defaults for local models:
- Mode: `Act`
- Auto-approve: `Read` only (or disabled)
- Require manual approval for each write/edit/command

Why this matters:
- smaller local models are more likely to loop in Plan mode
- explicit approvals reduce accidental broad edits
- bounded prompts improve repeatability

## Typical Usage Flow

1. Open `/opt/safe-local-agent` in VS Code.
2. Start Ollama: `OLLAMA_KEEP_ALIVE=-1 ollama serve`.
3. Open Cline and select one model profile.
4. Start a task with a narrow prompt and explicit file scope.
5. Review each action before approval.

Example prompt:

```text
Open only profiles/cline-dev/Modelfile.
Add repeat_penalty with value 1.1.
Do not modify any other file.
```

## How `.clinerules` Works

`.clinerules` in this repo is workspace-local:
- it applies when Cline runs in this workspace
- it does not apply to unrelated VS Code folders
- after changing `.clinerules`, start a new Cline task

## Troubleshooting

- Connection errors:
  Verify Ollama is running and base URL is exactly `http://localhost:11434`.
- Missing or empty chat output:
  Reduce prompt scope, keep timeout at `300000`, and retry with `cline-dev`.
- Slow first response:
  Initial model load can be cold; keep timeout high and keep Ollama running.
- Agent loops:
  Stop the task and restart with narrower scope and explicit file boundaries.
- Over-broad edits:
  Reference exact files/functions and state non-target files explicitly.

## Limitations

- This setup is not fully autonomous by design.
- Cline provider/approval settings remain user-local in each Cline installation.
- Local model quality and latency vary by machine and model size.

## Use As Template

This repo is a practical starting point for teams that want reproducible, human-in-the-loop local coding-agent workflows.
