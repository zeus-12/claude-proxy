# claude-proxy

**One subscription. AI in every app.**

A simple menu-bar-only macOS app that exposes an OpenAI-compatible endpoint to
your Claude Code subscription.

<p align="center">
  <img src="docs/menubar.png" alt="claude-proxy menu bar app" width="380">
</p>

`claude-proxy` turns your Claude Code subscription into a local, OpenAI-compatible
API. You run it once, and it gives you a URL like `http://127.0.0.1:8787/v1`.
Paste that URL into any app that lets you point at a custom OpenAI endpoint — and
that app now has AI, powered by the subscription you already pay for.

No separate per-app AI plan. No extra tokens to buy. The apps you already use just
start talking to the model through your one subscription.

Add as many endpoints as you want — one per port, each backed by whatever Claude
model you choose.

---

## How it works

Each "instance" runs a small local HTTP server that speaks the OpenAI
`/v1/chat/completions` (and `/v1/models`) protocol. When a request comes in, it
drives the headless `claude` CLI (`claude -p --output-format stream-json`) and
streams the response back in OpenAI's format. Tool use is disabled and the system
prompt is overridden, so responses behave like a plain chat model.

```
your app  ──HTTP──▶  claude-proxy (localhost:8787)  ──▶  claude CLI  ──▶  your subscription
        ◀──OpenAI JSON / SSE──
```

## Requirements

- macOS 14 or later
- [Claude Code](https://claude.com/claude-code) installed and logged in
  (`claude` must be on your login shell's `PATH`)
- Swift 6 toolchain (Xcode command-line tools) to build

## Install

1. Download the latest `Claude-Proxy-<version>.zip` from the
   [Releases](https://github.com/zeus-12/claude-proxy/releases) page.
2. Unzip it and move **Claude Proxy.app** to `/Applications`.
3. Open it the first time using **one of the two workarounds below**.
4. It launches into the menu bar (no Dock icon) — click the icon to use it.

### "Claude Proxy can't be opened" — why, and how to get past it

macOS tags anything downloaded from the internet with a *quarantine* flag, and
**Gatekeeper refuses to open apps that aren't signed and notarized by a paid
Apple Developer account** ($99/yr — which this app doesn't have). So on first
launch you'll see a warning like *"Apple could not verify Claude Proxy is free of
malware."* The app is fine; it just isn't notarized. Get past it either way:

- **Right-click** (or Control-click) the app in Finder → **Open** → **Open** again
  in the dialog. macOS remembers this and won't ask again.
- **Or** clear the quarantine flag from the terminal once:

  ```bash
  xattr -dr com.apple.quarantine "/Applications/Claude Proxy.app"
  ```

You only have to do this once, right after installing (or after each update).

## Build & run (from source)

```bash
swift build -c release
./.build/release/ClaudeProxy &
```

Or for development:

```bash
swift run
```

It launches as a **menu-bar app** — no Dock icon, no window. Click the icon in the
menu bar to add, start, stop, and edit instances. The first instance defaults to
model `sonnet` on port `8787`.

To stop it: `pkill -f ClaudeProxy`.

## Point an app at it

In any OpenAI-compatible client (chat apps, editors, SDKs):

| Field        | Value                          |
| ------------ | ------------------------------ |
| Base URL     | `http://127.0.0.1:8787/v1`     |
| API key      | any non-empty string (ignored) |
| Model        | `sonnet` (or your instance's model) |

### Try it with curl

Non-streaming:

```bash
curl http://127.0.0.1:8787/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "sonnet",
    "messages": [{"role": "user", "content": "Give me three names for a coffee shop."}]
  }'
```

Streaming (SSE):

```bash
curl -N http://127.0.0.1:8787/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "sonnet",
    "stream": true,
    "messages": [{"role": "user", "content": "Count from 1 to 5."}]
  }'
```

## Using it beyond your Mac

The server binds to `127.0.0.1` only. To reach it from another device or a hosted
app, run a local tunnel — it runs on your Mac and forwards to the port:

```bash
ngrok http 8787
# or
cloudflared tunnel --url http://127.0.0.1:8787
```

## Honest caveats

- **Terms of service.** This routes a Claude Code subscription through a
  general-purpose API endpoint. That's in tension with Anthropic's terms, which
  license the subscription for use *through* their client — not as a redistributable
  gateway. Use it for yourself, at your own risk.
- **It's an agent, not the raw API.** Output comes from the Claude Code agent with
  its baseline context, so it isn't byte-for-byte identical to the Anthropic API.
- **Per-request token floor.** Each request carries ~12k tokens of baseline context,
  which counts against your subscription's usage limits. Short replies still cost
  that floor.

## Releasing (maintainers)

Releases are tag-driven. One command from a clean `main` cuts a release:

```bash
./Scripts/release.sh 0.1.1
```

It verifies you're on `main` with a clean tree, pushes `main`, then creates and
pushes the `v0.1.1` tag. Pushing that tag triggers
[`.github/workflows/release.yml`](.github/workflows/release.yml), which builds a
universal `Claude Proxy.app` on a macOS runner and publishes it as a GitHub
Release with the zip attached. The **git tag is the single source of truth** for
the version.

To build a test artifact without publishing, run the workflow manually from the
**Actions** tab (it builds and uploads an artifact but creates no Release).

> First-time setup: the workflow file must already be on `main` before the first
> tag, and **Settings → Actions → General → Workflow permissions** must be set to
> **Read and write** so the release can be created.

## Development notes

- Pure SwiftUI / AppKit / Network / Foundation — no external dependencies.
- If runtime behavior ever contradicts your source edits, do a clean build:
  `rm -rf .build && swift build`. Incremental builds occasionally don't relink.
