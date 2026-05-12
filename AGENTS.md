# AGENTS.md

## Build & Run

The Swift package lives in `src/`. Run all `swift build`, `swift run`, and `swift package` commands from there, not from the repo root.

```bash
# Debug build
cd src && swift build

# Run the app (menu bar app — swift run does not work for LSUIElement apps)
# Build the .app bundle first, then open it:
./create-app-bundle.sh && open DroidProxy.app

# Release .app bundle at repo root
# Picks up CODESIGN_IDENTITY / APP_VERSION / TARGET_ARCH from env when present
./create-app-bundle.sh
```

`create-app-bundle.sh` currently builds `DroidProxy.app` at the repo root and bundles resources from `src/Sources/Resources/`.

### Notarization (local)

```bash
ditto -c -k --sequesterRsrc --keepParent "DroidProxy.app" "DroidProxy-notarize.zip"
xcrun notarytool submit "DroidProxy-notarize.zip" --keychain-profile "notarytool" --wait
xcrun stapler staple "DroidProxy.app"
```

### Sparkle update signing

```bash
src/.build/artifacts/sparkle/Sparkle/bin/sign_update DroidProxy-arm64.zip
```

## Source Of Truth

The compiled app code is under `src/`. Treat `src/Sources/**`, `src/Info.plist`, and `create-app-bundle.sh` as source of truth.

There is also a top-level `resources/` tree containing mirrored Swift files and assets. It is not the SwiftPM target used by `src/Package.swift`, so do not assume edits there affect the app unless the task is explicitly about that directory.

## Architecture

DroidProxy is a macOS menu bar app (`LSUIElement`) with:

1. `ThinkingProxy` on `localhost:8317`, the user-facing TCP proxy.
2. Bundled `CLIProxyAPIPlus` on `127.0.0.1:8318`, managed as a child process by `ServerManager`.

Typical request flow:

`Client -> :8317 ThinkingProxy -> :8318 CLIProxyAPIPlus -> upstream provider`

### Current ThinkingProxy behavior

`ThinkingProxy.swift` no longer implements the old `-thinking-N` suffix parser described in older docs.

What it does today:

- Inspects `POST` JSON requests for supported Claude, Codex GPT, and Gemini models
- Injects Claude adaptive thinking for models whose name contains `opus-4-7` or `sonnet-4-6`
- Injects `"thinking":{"type":"adaptive"}` and forces `"stream":true` for Claude
- Injects `"output_config":{"effort":"..."}`
- Reads effort from `AppPreferences.opus47ThinkingEffort` or `AppPreferences.sonnet46ThinkingEffort`
- Injects Codex reasoning for exact models `gpt-5.3-codex`, `gpt-5.4`, and `gpt-5.5`
- Injects `"reasoning":{"effort":"..."}`
- Reads effort from `AppPreferences.gpt53CodexReasoningEffort`, `AppPreferences.gpt54ReasoningEffort`, or `AppPreferences.gpt55ReasoningEffort`
- Injects Gemini thinking levels for `gemini-3.1-pro-preview` and `gemini-3-flash-preview`
- Injects Kimi reasoning for `kimi-k2.6`
- Rewrites the model name to append a suffix (e.g. `gemini-3.1-pro-preview(high)`) which CLIProxyAPIPlus parses via its `ParseSuffix` logic
- Reads level from `AppPreferences.gemini31ProThinkingLevel` or `AppPreferences.gemini3FlashThinkingLevel`
- Reads Kimi effort from `AppPreferences.k26ReasoningEffort`
- Optionally injects `"service_tier":"priority"` for `gpt-5.4` or `gpt-5.5` on Responses API paths (`/v1/responses`, `/api/v1/responses`) when `AppPreferences.gpt54FastMode` or `AppPreferences.gpt55FastMode` is enabled and the client did not already set `service_tier`
- Preserves JSON key order by editing the raw JSON string instead of re-serializing
- **Max Budget Mode**: When `AppPreferences.claudeMaxBudgetMode` is enabled, forces streaming and applies a Sonnet-4.6-only override: classic extended thinking with `budget_tokens=63999` / `max_tokens=64000` / `effort=max`. Opus 4.7 is unaffected and continues to receive `thinking.type=adaptive` with `output_config.effort` from `AppPreferences.opus47ThinkingEffort`.

What it does not do anymore:

- It does not strip or normalize model suffixes
- It does not send `thinking.budget_tokens` to Opus 4.7 (rejected with 400)
- It does not add `anthropic-beta` interleaved-thinking headers (adaptive thinking enables interleaving automatically)
- It does not implement the old `-thinking-N` / suffix-based branching documented in stale docs

### Amp routing

`ThinkingProxy` also handles Amp-specific routing:

- `/auth/cli-login` and `/api/auth/cli-login` are redirected directly to `https://ampcode.com/...`
- `/provider/*` is rewritten to `/api/provider/*`
- Requests that are not provider requests and not `/v1/*` or `/api/v1/*` are treated as Amp management requests and forwarded to `ampcode.com`
- Amp response `Location` headers and cookie domains are rewritten so browser flows continue working through localhost

## Auth And Providers

The current app/UI exposes three provider types:

- `claude`
- `codex`
- `gemini`
- `kimi`

Auth data lives in `~/.cli-proxy-api/` as JSON files. `AuthManager` scans that directory and reads fields like:

- `type`
- `email`
- `login`
- `expired`
- `disabled`

Behavior to know:

- Multiple accounts per provider are supported
- Per-account disable/enable is supported via the `disabled` field in each auth JSON
- The last enabled account for a provider cannot be disabled
- Provider-level toggles in `SettingsView` are separate from per-account disable flags
- Provider-level disable writes `oauth-excluded-models` into `~/.cli-proxy-api/merged-config.yaml`
- `CLIProxyAPIPlus` hot-reloads config changes, so provider enable/disable does not require a restart
- The app watches `~/.cli-proxy-api/` for changes from both `AppDelegate` and `SettingsView`

## Key Files

| File | Role |
|---|---|
| `src/Sources/AppDelegate.swift` | App lifecycle, menu bar UI, settings window, notifications, Sparkle updater, auth-directory watcher, startup ordering for the two local servers. |
| `src/Sources/ServerManager.swift` | Starts/stops bundled `cli-proxy-api-plus`, captures logs, merges config, handles provider enable/disable, runs Claude/Codex/Gemini login commands, and kills orphaned backend processes. |
| `src/Sources/ThinkingProxy.swift` | Raw TCP HTTP proxy for thinking injection plus Amp request/response rewriting. |
| `src/Sources/SettingsView.swift` | SwiftUI settings UI for server status, launch-at-login, provider toggles, auth flows, and per-model effort pickers. |
| `src/Sources/AuthStatus.swift` | `AuthManager`, account parsing, expiry detection, file deletion, and per-account disabled-state updates. |
| `src/Sources/AppPreferences.swift` | UserDefaults-backed effort preferences for Opus 4.7, Sonnet 4.6, GPT 5.3 Codex, GPT 5.4, Gemini 3.1 Pro, Gemini 3 Flash, and Kimi K2.6, plus fast mode toggles and the usage probe controls (`showUsageInMenuBar`, `usageAutoRefreshSeconds`). |
| `src/Sources/ClaudeUsageProbe.swift` | Hits `https://api.anthropic.com/api/oauth/usage` with the access token from `~/.cli-proxy-api/claude-*.json`. Handles OAuth refresh against `platform.claude.com/v1/oauth/token` (atomic write back to the auth file) and decodes the flat-keyed response shape (`five_hour`, `seven_day_*`). |
| `src/Sources/CodexUsageProbe.swift` | Spawns `codex -s read-only -a untrusted app-server` as a child process and issues line-delimited JSON-RPC (`initialize` + `account/rateLimits/read`) to read Codex/ChatGPT rate limit windows. Requires the `codex` CLI to be installed and logged in. |
| `src/Sources/UsageStore.swift` | `@MainActor` singleton that fan-outs to both probes in parallel, debounces overlapping refreshes (cancels in-flight task before starting a new one), and schedules a repeating timer based on `AppPreferences.usageAutoRefreshSeconds` (skips scheduling when set to 0/Manual). Posts `usageUpdated` notifications for UI consumers. |
| `src/Sources/UsageModels.swift` | `UsageWindowKind`, `UsageWindow`, and `ProviderUsageSnapshot` data types shared by the probes and `AppDelegate`. Probes leave `limit` / `used` at `0` since the upstream APIs return only `percentUsed`. |
| `src/Sources/Resources/config.yaml` | Bundled CLIProxyAPIPlus config (`port: 8318`, localhost binding, Amp upstream settings, auth dir). |
| `src/Info.plist` | Bundle metadata. Current source-of-truth values include app name `DroidProxy`, bundle ID `com.droidproxy.app`, and Sparkle feed URL on `anand-92/droidproxy`. |

## Conventions

- Use `NSLog`, not `print` or `os_log`
- Prefer updating the app under `src/`, not the mirrored top-level `resources/` directory
- Treat `DroidProxy.app`, `CLIProxyMenuBar`, and `com.droidproxy.app` as the active app identity
- `CLIProxyAPIPlus` is bundled as `src/Sources/Resources/cli-proxy-api-plus`
- `ThinkingProxy` uses surgical string insertion for JSON edits to preserve cache-sensitive key ordering
- Local backend traffic is intended to stay on localhost only (`127.0.0.1:8318`)
- `TunnelManager.swift` exists in `src/Sources/` but is currently not wired into the app flow

## Release Notes For Agents

The repo still contains stale VibeProxy-era references outside the active runtime path. Before changing release automation, double-check names and URLs against current files.

Known drift includes some combinations of:

- `Makefile`
- `scripts/create-release.sh`
- `.github/workflows/release.yml`

Those files still reference old names like `VibeProxy.app`, `automazeio/vibeproxy`, and legacy appcast URLs in places. If a task touches release tooling, audit it carefully instead of trusting the existing wording.
