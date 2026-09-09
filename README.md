# DroidProxy

<p align="center">
  <img src="logo.png" alt="DroidProxy" width="128">
</p>

A native macOS menu bar app that proxies Claude Code, Codex, Gemini, Kimi, GitHub Copilot, Junie, and Grok authentication for use with [<img src="factory-logo.svg" alt="Factory.ai" height="16">](https://app.factory.ai) Droids. Built on [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI).



https://github.com/user-attachments/assets/8bc180a3-0baf-473d-87c9-6aaacce302f2



## Download

Grab the latest release from [Releases](https://github.com/anand-92/droidproxy/releases/latest):

- **DroidProxy-arm64.zip** -- Apple Silicon

Each release also ships a `DroidProxy-arm64.zip.sha256` checksum. Unzip and drag `DroidProxy.app` into your Applications folder. All releases are code-signed and notarized by Apple, and existing installs auto-update via Sparkle.

## Features

- **One-click OAuth auth** -- Claude Code, Codex, Gemini, and Kimi login launched from the Settings window, with credential monitoring and automatic OAuth token refresh.
- **GitHub Copilot** -- Sign in through the Settings window, then select up to three models available to your Copilot subscription. Only those selected models are added to Factory's custom-model configuration.
- **Every model, every reasoning level** -- Fable 5, Opus 5, Sonnet 4.6, GPT 5.6 Terra, GPT 5.6 Sol, Gemini 3.1 Pro, Gemini 3 Flash, Kimi K3, and Kimi K2.6 are registered as Factory custom models with their full set of native reasoning levels. Reasoning effort is chosen per session from Droid CLI's model selector; DroidProxy preserves the selection and the bundled backend translates it to each provider's native request format.
- **Fast Mode** -- Optional `service_tier=priority` for GPT 5.6 Terra, GPT 5.6 Luna, and GPT 5.6 Sol, plus an opt-in Grok 4.6 toggle that rewrites `grok-4.6` → `grok-4.6-fast` via the Cursor API (`api.x.ai` has no fast variant).
- **Usage tracking** -- Claude and Codex OAuth quota windows (5-hour + weekly) rendered in the **OAuth Quota Usage** section of the Settings window. Fetched directly from each provider's OAuth API (no `codex` CLI dependency) and refreshed on demand via the inline refresh button.
- **Grok Imagine (image gen)** -- With Grok OAuth connected, DroidProxy also forwards OpenAI-compatible image requests (`POST /v1/images/generations` for `grok-imagine-*` models) to `api.x.ai` — no `XAI_API_KEY`. Factory/Droid does not call that endpoint on its own; use the bundled skill below.
- **GPT Image (Codex OAuth)** -- With Codex connected, `POST /v1/images/generations` for `gpt-image-2.5-flare` or `gpt-image-2.5-sunburst` is forwarded to CLIProxyAPI, which uses your ChatGPT Plus/Pro OAuth session — no `OPENAI_API_KEY`. Same rule as Grok: Droid will not call that endpoint unless you install the bundled skill.

<p align="center">
  <img src="settings-screenshot.png" alt="DroidProxy Settings" width="420">
</p>

## Setup

See [SETUP.md](SETUP.md) for authentication and manual Factory configuration instructions. **(OR use the 1-click options in the UI!)**

### Image generation skills

If you have **Grok** and/or **Codex** auth set up in DroidProxy, you can generate images through the same proxy. Grab the skills from this repo:

```bash
# From a clone of this repo, copy into your personal Factory skills
mkdir -p ~/.factory/skills
cp -R skills/grok-imagine ~/.factory/skills/
cp -R skills/gpt-image ~/.factory/skills/
```

Or keep [`skills/grok-imagine/SKILL.md`](skills/grok-imagine/SKILL.md) under `~/.factory/skills/grok-imagine/` and [`skills/gpt-image/SKILL.md`](skills/gpt-image/SKILL.md) under `~/.factory/skills/gpt-image/`.

Then in Droid, ask to generate an image (or invoke the skill). Both skills post to `http://localhost:8317/v1/images/generations` with `Authorization: Bearer dummy-not-used`:

- **Grok** — model `grok-imagine-image-2.0`; ThinkingProxy injects your Grok OAuth token and forwards to xAI.
- **GPT** — model `gpt-image-2.5-flare` (fast default) or `gpt-image-2.5-sunburst` (maximum quality); CLIProxyAPI injects your Codex OAuth token. Requires ChatGPT Plus/Pro (Free is rejected).

**Requirements:** DroidProxy running, the matching provider connected in Settings. Image gen is separate from chat — selecting “DroidProxy: Grok 4.6” or “DroidProxy: GPT 5.x” alone does not generate images.

## Requirements

- macOS 13.0+ (Ventura or later)
- Apple Silicon 

## Build from source

The Swift package lives in `src/`, so run `swift` commands from there.

```bash
# Debug build
cd src && swift build

# Release build + signed .app bundle (run from the repo root)
./create-app-bundle.sh

# Preferred dev loop: rebuild the signed .app and relaunch it
./dev-relaunch.sh
```

See [AGENTS.md](AGENTS.md) for the full build, notarization, and release workflow.

## Project Structure

```
src/
├── Sources/
│   ├── main.swift                   # NSApplication entry point
│   ├── AppDelegate.swift            # App lifecycle, menu bar, settings window, Sparkle updater
│   ├── ServerManager.swift          # cli-proxy-api process control, config merge, auth flows
│   ├── ThinkingProxy.swift          # TCP proxy on :8317 (Anthropic-Beta rewrite, fast mode, Gemini path rewrite)
│   ├── SettingsView.swift           # SwiftUI settings UI
│   ├── DroidProxyModelCatalog.swift # Authoritative catalog of exposed Factory models
│   ├── AuthStatus.swift             # AuthManager: account parsing, expiry, enable/disable
│   ├── AuthDirectoryMonitor.swift   # Debounced watcher on ~/.cli-proxy-api
│   ├── AuthPaths.swift              # Auth directory location constant
│   ├── AppPreferences.swift         # UserDefaults-backed preferences
│   ├── OAuthUsageTracker.swift      # OAuth quota windows for SettingsView
│   ├── CopilotSupport.swift          # Local Copilot API gateway, device login, and selected-model persistence
│   ├── IconCatalog.swift            # NSImage caching for menu-bar / settings icons
│   ├── NotificationNames.swift      # Shared Notification.Name constants
│   ├── LogoView.swift               # Inline-SVG logo used in the settings UI
│   └── Resources/
│       ├── cli-proxy-api            # Bundled CLIProxyAPI binary
│       ├── config.yaml              # Server config (port 8318, localhost)
│       ├── AppIcon.icns             # App icon
│       ├── icon-active.png          # Menu bar icon (active)
│       ├── icon-inactive.png        # Menu bar icon (inactive)
│       ├── icon-claude.png          # Claude service icon
│       ├── icon-codex.png           # Codex service icon
│       ├── icon-copilot.png         # GitHub Copilot service icon
│       ├── icon-gemini.png          # Gemini service icon
│       ├── icon-cursor.png          # Cursor service icon
│       ├── icon-kimi.svg            # Kimi service icon
│       └── glyph.png                # App glyph
├── Package.swift
├── Package.resolved
└── Info.plist
```

> See [AGENTS.md](AGENTS.md) for a per-file breakdown of what each source file does.

## Stargazers over time
[![Stargazers over time](https://starchart.cc/anand-92/droidproxy.svg?variant=dark)](https://starchart.cc/anand-92/droidproxy)
## License

MIT
