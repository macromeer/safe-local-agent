#!/usr/bin/env bash
set -euo pipefail

if ! command -v ollama >/dev/null 2>&1; then
  exit 0
fi

# Keep models loaded while a VS Code family editor process is running.
if pgrep -fa '(^|/)(code|code-insiders|codium|cursor)( |$)' >/dev/null 2>&1; then
  logger -t ollama-vscode-guard "VS Code is running - keeping models loaded"
  exit 0
fi

# Unload any currently loaded models so GPU memory is released.
model_names="$(ollama ps | awk 'NR>1 && $1 != "" { print $1 }')"
if [[ -z "${model_names}" ]]; then
  logger -t ollama-vscode-guard "VS Code not running, no models loaded"
  exit 0
fi

while IFS= read -r model_name; do
  [[ -z "${model_name}" ]] && continue
  logger -t ollama-vscode-guard "Stopping model: ${model_name}"
  if ollama stop "${model_name}" 2>&1 | logger -t ollama-vscode-guard; then
    logger -t ollama-vscode-guard "Stopped: ${model_name}"
  else
    logger -t ollama-vscode-guard "WARNING: failed to stop ${model_name}"
  fi
done <<< "${model_names}"
