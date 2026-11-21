"""Set the apiKey of every OpenClaw model provider that points at a local port.

Run as the agent user. The key is read from stdin, so it never shows up in a
process list. Usage: python3 set_openclaw_key.py PORT [CONFIG_PATH] < key
"""
import json
import os
import sys
import tempfile

port = sys.argv[1]
path = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser("~/.openclaw/openclaw.json")
key = sys.stdin.readline().strip()
if not key:
    sys.exit("no key on stdin")

with open(path, encoding="utf-8") as f:
    cfg = json.load(f)

hits = []
for name, provider in cfg.get("models", {}).get("providers", {}).items():
    url = str(provider.get("baseUrl", ""))
    if any(url.startswith(f"http://{host}:{port}") for host in ("127.0.0.1", "localhost", "[::1]")):
        provider["apiKey"] = key
        hits.append(name)

if not hits:
    sys.exit(f"no provider in {path} points at http://127.0.0.1:{port}")

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".openclaw.json.")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, path)
print("API key set for provider(s): " + ", ".join(hits))
