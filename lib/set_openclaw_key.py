"""Set the apiKey of every OpenClaw model provider that points at a local port.

Run as the agent user. The key is read from stdin, so it never shows up in a
process list. Usage: python3 set_openclaw_key.py PORT [CONFIG_PATH] < key
"""
import json
import os
import sys
import tempfile
from urllib.parse import urlsplit

LOCAL_HOSTS = ("127.0.0.1", "localhost", "::1")


def is_local(url, port):
    """True if url is http:// on a loopback host and exactly this port."""
    try:
        u = urlsplit(str(url))
        return u.scheme == "http" and u.hostname in LOCAL_HOSTS and u.port == int(port)
    except ValueError:  # malformed URL or port
        return False


def main(argv):
    port = argv[1]
    path = argv[2] if len(argv) > 2 else os.path.expanduser("~/.openclaw/openclaw.json")
    key = sys.stdin.readline().strip()
    if not key:
        sys.exit("no key on stdin")

    with open(path, encoding="utf-8") as f:
        cfg = json.load(f)

    hits = []
    for name, provider in cfg.get("models", {}).get("providers", {}).items():
        if is_local(provider.get("baseUrl", ""), port):
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


if __name__ == "__main__":
    main(sys.argv)
