#!/usr/bin/env bash
set -euo pipefail

if ! command -v ollama >/dev/null 2>&1; then
  exit 0
fi

# Keep models loaded while a VS Code family editor process is running.
if pgrep -fa '(^|/)(code|code-insiders|codium|cursor)( |$)' >/dev/null 2>&1; then
  exit 0
fi

# Unload any currently loaded models so GPU memory is released.
model_names="$(ollama ps | awk 'NR>1 && $1 != "" { print $1 }')"
if [[ -z "${model_names}" ]]; then
  exit 0
fi

while IFS= read -r model_name; do
  [[ -z "${model_name}" ]] && continue
  ollama stop "${model_name}" >/dev/null 2>&1 || true
done <<< "${model_names}"
