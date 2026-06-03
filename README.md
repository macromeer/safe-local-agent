# Safe Local Agent: Human-in-the-Loop VS Code Coding Workflow

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![GitHub stars](https://img.shields.io/github/stars/macromeer/safe-local-agent?style=social)](https://github.com/macromeer/safe-local-agent/stargazers)
[![GitHub last commit](https://img.shields.io/github/last-commit/macromeer/safe-local-agent)](https://github.com/macromeer/safe-local-agent/commits/main)

This repository bootstraps a safe, human-in-the-loop local coding-agent workflow in VS Code using Cline + Ollama.

## Quickstart (60 seconds)

```bash
ollama pull qwen2.5-coder:14b
ollama pull qwen3:0.6b

cd /opt/safe-local-agent
ollama create cline-dev -f profiles/cline-dev/Modelfile

OLLAMA_KEEP_ALIVE=-1 ollama serve
```

Then in VS Code Cline settings:

- Provider: `Ollama`
- Base URL: `http://localhost:11434`
- Model: `cline-dev`
- Mode: `Act`
- Auto-approve: `Read` only (or disabled)

Run your first prompt:

```text
Open only profiles/cline-dev/Modelfile.
Explain each line briefly.
Do not modify any files.
```

You should see the line-by-line explanation in the chat response itself. If Cline only shows a completion banner, the local model likely finished the task without emitting the actual explanation.

## Why this repo

Most local-agent setup repos optimize for "it runs". This one optimizes for "it runs safely and repeatedly".

- Safety first: strict human-in-the-loop defaults, not autonomous free-run.
- Practical guardrails: repo-local `.clinerules` to constrain scope and reduce failure loops.
- Fast start: ready-to-create Ollama model profiles for Cline.
- Publishable template: minimal structure you can fork and adapt to your own stack.

## Stack

- VS Code
- Cline extension: `saoudrizwan.claude-dev`
- Ollama at `http://localhost:11434`
- Local model profiles in `profiles/`
- Repo-local guardrails in `.clinerules`

## Included Profiles

- `profiles/cline-deep/Modelfile` (`qwen2.5-coder:14b`, 32K ctx)
- `profiles/cline-dev/Modelfile` (`qwen2.5-coder:14b`, 32K ctx)
- `profiles/cline-fast/Modelfile` (`qwen3:0.6b`, 16K ctx)

Keep-alive is set when starting Ollama:

```bash
OLLAMA_KEEP_ALIVE=-1 ollama serve
```

## Install

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

## Configure Cline (VS Code)

Open Cline Settings and set:

- Provider: `Ollama`
- Base URL: `http://localhost:11434`
- API key: empty
- Model: `cline-deep` or `cline-dev` or `cline-fast`
- Request timeout: `300000`

## Local MCP Tools Server

This repository includes a production-oriented local MCP tools server in `mcp-server-local-agent/`.

What it provides:

- Workspace info and path-safe file listing
- Line-range file reads and text search
- Optional write and local command tools (manual approval recommended)

Start it through Cline MCP settings using `uv`:

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

## Safe Workflow Defaults

For local models, keep strict human-in-the-loop controls:

- Mode: `Act`
- Auto-approve: `Read` only (or disabled)
- Approve every write/edit/command manually

Why: small local models can loop in Plan mode and retry failing tool calls.

## How `.clinerules` Works

`.clinerules` is repository-local.

- It applies when Cline runs in this workspace.
- It does not apply globally to every VS Code folder.
- After editing `.clinerules`, start a new Cline task.

## Typical Usage

1. Open `/opt/safe-local-agent` in VS Code.
2. Start Ollama (`OLLAMA_KEEP_ALIVE=-1 ollama serve`).
3. Open Cline and select a local model.
4. Start a new task and give narrow prompts.
5. Review and approve each action.

Good prompt:

```text
Open only profiles/cline-dev/Modelfile.
Add repeat_penalty with value 1.1.
Do not modify any other file.
```

## Troubleshooting

- Connection errors: verify Ollama is running and base URL is exactly `http://localhost:11434`.
- Slow first response: cold load; keep timeout high and keep Ollama running.
- Agent loops: stop task, restart with tighter prompt.
- Over-broad edits: point to exact file/function and keep prompts concrete.

## Publish As Template

This repo is a strong template for reproducible local-agent workflow with guardrails.

It is not full autonomy: Cline provider/approval settings still live in each user's local Cline UI.
