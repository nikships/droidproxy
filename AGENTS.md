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

The compiled app code is under `src/`. Treat `src/Sources/**`, `src/Info.plist`, and `create-app-bundle.sh` as source of truth. There is no longer a mirrored top-level `resources/` tree — older AGENTS notes about it are stale.

## Architecture

DroidProxy is a macOS menu bar app (`LSUIElement`) with:

1. `ThinkingProxy` on `localhost:8317`, the user-facing TCP proxy.
2. Bundled `CLIProxyAPIPlus` on `127.0.0.1:8318`, managed as a child process by `ServerManager`.

Typical request flow:

`Client -> :8317 ThinkingProxy -> :8318 CLIProxyAPIPlus -> upstream provider`

### Current ThinkingProxy behavior

`ThinkingProxy.swift` no longer implements the old `-thinking-N` suffix parser described in older docs.

What it does today:

- Inspects `POST` JSON requests for supported Claude, Codex GPT, Gemini, and Kimi models
- **Claude adaptive thinking** for models whose name contains `opus-4-7`, `opus-4-6`, or `sonnet-4-6`:
  - Injects `"thinking":{"type":"adaptive"}` (Opus 4.7 gets `{"type":"adaptive","display":"summarized"}`)
  - Injects `"output_config":{"effort":"..."}`
  - Forces `"stream":true`
  - Reads effort from `AppPreferences.opus47ThinkingEffort`, `AppPreferences.opus46ThinkingEffort`, or `AppPreferences.sonnet46ThinkingEffort`
- **Claude classic thinking** for models whose name contains `opus-4-5` (which does not support adaptive thinking):
  - Injects `"thinking":{"type":"enabled","budget_tokens":N}` plus a matching `"max_tokens"`, mapped from `AppPreferences.opus45ThinkingEffort` (low/medium/high/max → fixed budget/max-token pairs, see `opus45ClassicBudget`)
  - Forces `"stream":true`
- **Anthropic-Beta rewriting**: When a Claude request has `thinking.type` of `enabled`/`adaptive`/`auto`, the proxy strips `redact-thinking-2026-02-12` from the `Anthropic-Beta` header and appends the visible-thinking beta list (interleaved-thinking, prompt-caching-scope, fast-mode, etc.). Without this, Claude emits only signed empty thinking blocks.
- **Codex reasoning** for exact models `gpt-5.2`, `gpt-5.3-codex`, `gpt-5.4`, and `gpt-5.5`:
  - Injects `"reasoning":{"effort":"..."}`
  - Reads effort from `AppPreferences.gpt52ReasoningEffort`, `AppPreferences.gpt53CodexReasoningEffort`, `AppPreferences.gpt54ReasoningEffort`, or `AppPreferences.gpt55ReasoningEffort`
- **Gemini thinking levels** for `gemini-3.1-pro-preview` and `gemini-3-flash-preview`:
  - Rewrites the model name to append a suffix (e.g. `gemini-3.1-pro-preview(high)`) which CLIProxyAPIPlus parses via its `ParseSuffix` logic
  - Reads level from `AppPreferences.gemini31ProThinkingLevel` or `AppPreferences.gemini3FlashThinkingLevel`
  - Also rewrites `/v1/responses` (and `/api/v1/responses`) to `/v1/chat/completions` for Gemini models since CLIProxyAPIPlus does not support Gemini via the Responses API
- **Kimi reasoning** for `kimi-k2.6`:
  - Injects `"reasoning":{"effort":"high"}` when `AppPreferences.k26ReasoningEnabled` is true; passes through unchanged otherwise (k2.6 only has a boolean toggle, not an effort picker)
- **Service tier (fast mode)** for Responses API paths (`/v1/responses`, `/api/v1/responses`): injects `"service_tier":"priority"` for `gpt-5.2`, `gpt-5.4`, or `gpt-5.5` when `AppPreferences.gpt52FastMode`, `AppPreferences.gpt54FastMode`, or `AppPreferences.gpt55FastMode` is enabled and the client did not already set `service_tier`
- **Factory advanced variants**: When a request's model matches a `DroidProxyModelCatalog.advancedVariant` (e.g. `claude-opus-4-7(high)`), the proxy strips the level suffix, rewrites the JSON `model`, and routes through the matching Claude/Codex/Gemini/Kimi injection path with the variant's level overriding the AppPreferences default
- Preserves JSON key order by editing the raw JSON string instead of re-serializing (critical for Anthropic's prompt cache)
- **Max Budget Mode**: When `AppPreferences.claudeMaxBudgetMode` is enabled, the Sonnet 4.6 / Opus 4.6 adaptive path is replaced with classic extended thinking — `"thinking":{"type":"enabled","budget_tokens":63999}`, `"max_tokens":64000`, `"output_config":{"effort":"max"}`, and forced streaming. Opus 4.7 is unaffected and continues to receive `thinking.type=adaptive` with `output_config.effort` from `AppPreferences.opus47ThinkingEffort`.

What it does not do anymore:

- It does not strip or normalize model suffixes for unsupported models
- It does not send `thinking.budget_tokens` to Opus 4.6 or 4.7 (those use adaptive thinking only — budget_tokens is rejected). Opus 4.5 and the Max Budget override deliberately *do* use `budget_tokens`.
- It does not add `anthropic-beta` interleaved-thinking headers manually for adaptive models (adaptive thinking enables interleaving automatically; the Anthropic-Beta rewrite above is about removing `redact-thinking-2026-02-12`)
- It does not implement the old `-thinking-N` / suffix-based branching documented in stale docs

### Amp routing

`ThinkingProxy` also handles Amp-specific routing:

- `/auth/cli-login` and `/api/auth/cli-login` are redirected directly to `https://ampcode.com/...`
- `/provider/*` is rewritten to `/api/provider/*`
- Requests that are not provider requests and not `/v1/*` or `/api/v1/*` are treated as Amp management requests and forwarded to `ampcode.com`
- Amp response `Location` headers and cookie domains are rewritten so browser flows continue working through localhost

## Auth And Providers

The current app/UI exposes four provider types:

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
| `src/Sources/main.swift` | NSApplication entry point that instantiates `AppDelegate` and calls `NSApplicationMain`. |
| `src/Sources/AppDelegate.swift` | App lifecycle, menu bar UI, settings window, notifications, Sparkle updater, auth-directory watcher, startup ordering for the two local servers. |
| `src/Sources/ServerManager.swift` | Starts/stops bundled `cli-proxy-api-plus`, captures logs, merges config, handles provider enable/disable, runs Claude/Codex/Gemini login commands, and kills orphaned backend processes. |
| `src/Sources/ThinkingProxy.swift` | Raw TCP HTTP proxy for thinking/reasoning injection, Anthropic-Beta header rewriting, Gemini path rewriting, factory-advanced variant routing, and Amp request/response rewriting. |
| `src/Sources/DroidProxyModelCatalog.swift` | Authoritative catalog of DroidProxy-exposed models (base + advanced variants per reasoning/thinking level). Powers Settings entries when `factoryAdvancedModels` is on and `ThinkingProxy.advancedVariant` lookups. |
| `src/Sources/SettingsView.swift` | SwiftUI settings UI for server status, launch-at-login, provider toggles, auth flows, per-model effort/level pickers, Kimi reasoning toggle, Max Budget Mode, factory-advanced-models toggle, OLED theme, background opacity, and remote-access settings. |
| `src/Sources/AuthStatus.swift` | `AuthManager`, account parsing, expiry detection, file deletion, and per-account disabled-state updates. |
| `src/Sources/AppPreferences.swift` | UserDefaults-backed preferences: effort/level for Opus 4.7/4.6/4.5, Sonnet 4.6, GPT 5.2/5.3-codex/5.4/5.5, Gemini 3.1 Pro, Gemini 3 Flash; Kimi K2.6 enabled toggle; fast-mode toggles for GPT 5.2/5.3-codex/5.4/5.5; `claudeMaxBudgetMode`, `allowRemote`, `secretKey`, `oledTheme`, `factoryAdvancedModels`, `backgroundOpacity`; and the usage probe controls (`showUsageInMenuBar`, `usageAutoRefreshSeconds`). |
| `src/Sources/ClaudeUsageProbe.swift` | Hits `https://api.anthropic.com/api/oauth/usage` with the access token from `~/.cli-proxy-api/claude-*.json`. Handles OAuth refresh against `platform.claude.com/v1/oauth/token` (atomic write back to the auth file) and decodes the flat-keyed response shape (`five_hour`, `seven_day_*`). |
| `src/Sources/CodexUsageProbe.swift` | Spawns `codex -s read-only -a untrusted app-server` as a child process and issues line-delimited JSON-RPC (`initialize` + `account/rateLimits/read`) to read Codex/ChatGPT rate limit windows. Requires the `codex` CLI to be installed and logged in. |
| `src/Sources/UsageStore.swift` | `@MainActor` singleton that fan-outs to both probes in parallel, debounces overlapping refreshes (cancels in-flight task before starting a new one), and schedules a repeating timer based on `AppPreferences.usageAutoRefreshSeconds` (skips scheduling when set to 0/Manual). Posts `usageUpdated` notifications for UI consumers. |
| `src/Sources/UsageModels.swift` | `UsageWindowKind`, `UsageWindow`, and `ProviderUsageSnapshot` data types shared by the probes and `AppDelegate`. Probes leave `limit` / `used` at `0` since the upstream APIs return only `percentUsed`. |
| `src/Sources/NotificationNames.swift` | Shared `Notification.Name` constants (`serverStatusChanged`, `authDirectoryChanged`, `usageUpdated`). |
| `src/Sources/IconCatalog.swift` | Caches `NSImage` lookups from the bundle's resource path so menu-bar / settings icons aren't re-decoded per access. |
| `src/Sources/LogoView.swift` | Inline-SVG `LogoView` used in the settings UI. |
| `src/Sources/TunnelManager.swift` | Stubbed tunnel/remote-access scaffolding; currently not wired into the app flow despite the matching `allowRemote`/`secretKey` preferences. |
| `src/Sources/Resources/config.yaml` | Bundled CLIProxyAPIPlus config (`port: 8318`, localhost binding, Amp upstream settings, auth dir). |
| `src/Info.plist` | Bundle metadata. Current source-of-truth values include app name `DroidProxy`, bundle ID `com.droidproxy.app`, and Sparkle feed URL on `anand-92/droidproxy`. |

## Conventions

- Use `NSLog`, not `print` or `os_log`
- Edits land in `src/Sources/**`; there is no longer a parallel top-level `resources/` mirror
- Treat `DroidProxy.app`, `CLIProxyMenuBar`, and `com.droidproxy.app` as the active app identity
- `CLIProxyAPIPlus` is bundled as `src/Sources/Resources/cli-proxy-api-plus`
- `ThinkingProxy` uses surgical string insertion for JSON edits to preserve cache-sensitive key ordering (do not switch to `JSONSerialization.data` round-trips)
- Local backend traffic is intended to stay on localhost only (`127.0.0.1:8318`)

## Release Notes For Agents

Release automation lives in `.github/workflows/release.yml` (no `Makefile` or `scripts/create-release.sh` in this repo). The workflow has already been migrated off the old `VibeProxy` / `automazeio/vibeproxy` identity.

Legacy `VibeProxy` references still live in:

- `appcast-x86_64.xml` (historical enclosure URLs)
- `CHANGELOG.md` (release history)
- `context/OG-vibeproxy-we-forked/` (full upstream fork snapshot, reference only)

Those are intentional history. If a task touches release tooling, audit the current workflow and `create-app-bundle.sh` rather than copying from those legacy files.
