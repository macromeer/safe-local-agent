# Local Agent Stack: VS Code + Cline + Ollama

This repository bootstraps a safe local coding-agent workflow in VS Code using Cline + Ollama.

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

All profiles include:

```text
ENV OLLAMA_KEEP_ALIVE=-1
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

Context window should match profile:

- `cline-deep`: `32768`
- `cline-dev`: `32768`
- `cline-fast`: `16384`

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
