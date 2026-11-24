# Security policy

## Reporting a vulnerability

Please don't open a public issue for a security problem. Report it privately
through GitHub instead: on this repository's **Security** tab, choose
**Report a vulnerability**.

Include what you ran (distribution, OpenClaw and Podman versions, your
`config.env` without secrets), what you expected the setup to prevent, and
what the agent could do instead. You'll get an answer within a week.

## What counts

The [README](README.md#what-this-protects-and-what-it-doesnt) lists what
this setup protects and what it doesn't. A vulnerability is a way around
something it says it protects, for example:

- the agent, or its sandboxed tools, reading your home folder, the Colibri
  key, or (with the sandbox) its own OpenClaw config
- the agent getting root, sudo rights or a privileged group
- the sandboxed tools reaching the network with `SANDBOX_NETWORK=none`
- the researcher agent running commands or changing its own instructions
- a script that weakens the setup, or `verify.sh` passing a setup that is broken
- the scripts doing damage outside what they say they change

Not vulnerabilities here, because the README already lists them as open:
the gateway's internet access, plugins running outside the sandbox, other
services on localhost, Ollama without authentication, the shared kernel, and
a prompt injection that talks a model out of its instructions without getting
past the tool lists and mounts.

Bugs in OpenClaw, Colibri, Podman or SearXNG themselves belong to those
projects. If this setup makes one of them worse, report it here too.

## Supported versions

Only the latest commit on `main`, with the `OPENCLAW_VERSION` it pins.
