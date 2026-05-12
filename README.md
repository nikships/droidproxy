# DroidProxy

<p align="center">
  <img src="logo.png" alt="DroidProxy" width="128">
</p>

A native macOS menu bar app that proxies Claude Code, Codex, Gemini, and Kimi authentication for use with [<img src="factory-logo.svg" alt="Factory.ai" height="16">](https://app.factory.ai) Droids. Built on [CLIProxyAPIPlus](https://github.com/router-for-me/CLIProxyAPIPlus).

## Download

Grab the latest release from [Releases](https://github.com/anand-92/droidproxy/releases/latest):

- **DroidProxy-arm64.dmg** -- Apple Silicon
- **DroidProxy-arm64.zip** -- ZIP alternative

All releases are code-signed and notarized by Apple. Existing installs auto-update via Sparkle.

## Features

- **One-click OAuth auth** -- Claude Code, Codex, Gemini, and Kimi login from the menu bar, credential monitoring, auto-refresh
- **Per-model reasoning/effort controls** -- Configure Opus 4.7, Sonnet 4.6, GPT 5.3 Codex, GPT 5.4, GPT 5.5, Gemini 3.1 Pro, Gemini 3 Flash, and Kimi K2.6 directly from the Settings window. Also supports `fast` mode for gpt models.
- **Max Budget Mode** -- Nuclear launch button that forces maximum reasoning on Opud/Sonnet 4.6 requests: classic extended thinking with `budget_tokens: 63999`, `max_tokens: 64000`, and `effort: max`. Opus 4.7 does not need this override. Full thinking power for Sonnet, your quota's problem.
- **Usage tracking** -- Live Claude and Codex rate limit windows (5-hour + weekly) in the menu bar dropdown. Auto-refreshes every 5 minutes (configurable) and on Mac wake. Codex tracking requires the `codex` CLI to be installed and logged in (`codex login`).

<p align="center">
  <img src="settings-screenshot.png" alt="DroidProxy Settings" width="420">
</p>

## Setup

See [SETUP.md](SETUP.md) for authentication and manaul Factory configuration instructions. **(OR use the 1-click options in the UI!)**

## Requirements

- macOS 13.0+ (Ventura or later)
- Apple Silicon (M1/M2/M3/M4)

## Build from source

```bash
# Debug build
make build

# Release build + signed .app bundle
./create-app-bundle.sh
```

## Project Structure

```
src/
├── Sources/
│   ├── main.swift              # App entry point
│   ├── AppDelegate.swift       # Menu bar & window management
│   ├── ServerManager.swift     # Server process control & auth
│   ├── SettingsView.swift      # Main UI
│   ├── AuthStatus.swift        # Auth file monitoring
│   ├── ThinkingProxy.swift     # Thinking parameter injection proxy
│   ├── TunnelManager.swift     # Network tunnel management
│   ├── IconCatalog.swift       # Icon loading & caching
│   ├── NotificationNames.swift # Notification constants
│   ├── ClaudeUsageProbe.swift  # Claude rate-limit fetcher
│   ├── CodexUsageProbe.swift   # Codex rate-limit fetcher (via codex app-server)
│   ├── UsageStore.swift        # Coordinates probes + auto-refresh
│   ├── UsageModels.swift       # Usage window data types
│   └── Resources/
│       ├── cli-proxy-api-plus  # CLIProxyAPIPlus binary
│       ├── config.yaml         # Server config
│       ├── AppIcon.icns        # App icon
│       ├── icon-active.png     # Menu bar icon (active)
│       ├── icon-inactive.png   # Menu bar icon (inactive)
│       ├── icon-claude.png     # Claude service icon
│       ├── icon-codex.png      # Codex service icon
│       └── icon-gemini.png     # Gemini service icon
├── Package.swift
└── Info.plist
```

## Challenger Droids - 1 Click Install via UI

DroidProxy ships with three devil's advocate code reviewer droids -- powered by Claude Opus 4.7, GPT 5.5, and Gemini 3.1 Pro. They challenge your code decisions, surface tradeoffs you may have missed, stress-test edge cases, and suggest concrete alternatives. Running multiple gives you a cross-model second opinion that catches blind spots a single reviewer might miss.


### Usage

In any Droid session, use the slash commands:

- `/challenge-opus` -- summon the Claude Opus 4.7 challenger
- `/challenge-gpt` -- summon the GPT 5.5 challenger
- `/challenge-gemini` -- summon the Gemini 3.1 Pro challenger

Both droids are read-only (no file edits) and return a structured verdict with challenges, edge cases, and acknowledgements of what's solid.

## Stargazers over time
[![Stargazers over time](https://starchart.cc/anand-92/droidproxy.svg?variant=dark)](https://starchart.cc/anand-92/droidproxy)
## License

MIT
