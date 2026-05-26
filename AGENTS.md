# AGENTS.md

## Build & Run

The Swift package lives in `src/`. Run all `swift build`, `swift run`, and `swift package` commands from there, not from the repo root.

```bash
# Preferred dev loop: kill any running DroidProxy, rebuild the .app bundle, and
# launch the freshly signed build. Use this instead of running create-app-bundle.sh
# + open by hand — it guarantees the old menu-bar process and bundled
# cli-proxy-api-plus are stopped before the new app starts.
./dev-relaunch.sh

# Debug build (no .app bundle, no relaunch)
cd src && swift build

# Run the app manually (menu bar app — swift run does not work for LSUIElement apps)
# Build the .app bundle first, then open it:
./create-app-bundle.sh && open DroidProxy.app

# Release .app bundle at repo root
# Picks up CODESIGN_IDENTITY / APP_VERSION / TARGET_ARCH from env when present
./create-app-bundle.sh
```

`dev-relaunch.sh` is the preferred way to run DroidProxy during development. It calls `create-app-bundle.sh` (which runs `swift build -c release` and assembles the signed `.app`) after killing any running `CLIProxyMenuBar` / `cli-proxy-api-plus` processes, then launches the fresh bundle. Do not use it for releases — those go through `.github/workflows/release.yml`.

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

Reasoning effort is owned by **Droid CLI**, not the proxy. Each Factory custom model is registered with native reasoning metadata (`enableThinking`, `supportedReasoningEfforts`, `defaultReasoningEffort`, `reasoningEffort`) so Droid's per-session selector exposes every level the model supports, and Droid sends the chosen value in the request body. The proxy does **not** inject `thinking`, `reasoning`, `reasoning_effort`, `output_config`, `budget_tokens`, or `generationConfig.thinkingConfig` for any model — it forwards the request unchanged.

What it still does today:

- **Anthropic-Beta rewriting**: When a Claude request has `thinking.type` of `enabled`/`adaptive`/`auto`, the proxy strips `redact-thinking-2026-02-12` from the `Anthropic-Beta` header and appends the visible-thinking beta list (interleaved-thinking, prompt-caching-scope, fast-mode, etc.). Without this, Claude emits only signed empty thinking blocks.
- **Service tier (fast mode)** for Responses API paths (`/v1/responses`, `/api/v1/responses`): injects `"service_tier":"priority"` for `gpt-5.3-codex`, `gpt-5.4`, or `gpt-5.5` when `AppPreferences.gpt53CodexFastMode`, `AppPreferences.gpt54FastMode`, or `AppPreferences.gpt55FastMode` is enabled and the client did not already set `service_tier`. Fast mode is API priority and is independent of reasoning effort. (`gpt-5.2` is still served but no longer exposes a fast-mode toggle.)
- **Gemini path rewrite**: `/v1/responses` (and `/api/v1/responses`) are rewritten to `/v1/chat/completions` for Gemini models since CLIProxyAPIPlus does not support Gemini via the Responses API endpoint.
- **Amp routing**: see the `Amp routing` section below.
- **Per-request reasoning log** to `/tmp/droidproxy-debug.log`: each `POST` emits a `REQUEST REASONING:` line that extracts just `reasoning` / `reasoning_effort` / `thinking` / `output_config` / `service_tier` / `generationConfig` from the parsed body so the actual values Droid is sending are visible without dumping the whole prompt. Example: `REQUEST REASONING: model=gpt-5.5 reasoning={"effort":"xhigh","summary":"auto"}`.
- Preserves JSON key order by editing the raw JSON string instead of re-serializing (critical for Anthropic's prompt cache). The remaining helpers (`injectJSONField`, `findTopLevelFieldLocation`, etc.) exist for `processOpenAIFastMode`.

What it no longer does (removed in the Droid-CLI-thinking refactor):

- No Claude adaptive thinking injection (Opus 4.7 / 4.6 / Sonnet 4.6 — `thinking` + `output_config`)
- No Opus 4.5 classic `thinking.budget_tokens` injection
- No Codex `reasoning.effort` injection
- No Gemini `generationConfig.thinkingConfig` injection
- No Kimi `reasoning_effort` injection
- No `claude-opus-4-7(high)` / `gpt-5.2(xhigh)` etc. “advanced variant” suffix parsing — every level now ships in the single base entry via Droid CLI metadata
- No Max Budget Mode override

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
| `src/Sources/ThinkingProxy.swift` | Raw TCP HTTP proxy that forwards requests to CLIProxyAPIPlus. Rewrites the Anthropic-Beta header to drop `redact-thinking-2026-02-12` on Claude thinking requests, injects `service_tier=priority` on enabled Codex fast-mode models, rewrites Gemini `/v1/responses` to `/v1/chat/completions`, handles Amp request/response rewriting, and emits a `REQUEST REASONING` log line per request. Does not inject reasoning or thinking fields. |
| `src/Sources/DroidProxyModelCatalog.swift` | Authoritative catalog of DroidProxy-exposed models. Each `DroidProxyModelDefinition` carries its supported `levels` plus a `defaultLevelValue`, and `settingsEntry` always embeds Factory's native reasoning metadata (`enableThinking`, `supportedReasoningEfforts`, `defaultReasoningEffort`, `reasoningEffort`) so Droid CLI's per-session selector can expose the full level set. |
| `src/Sources/SettingsView.swift` | SwiftUI settings UI for server status, launch-at-login, provider toggles, auth flows, the Codex fast-mode (`service_tier=priority`) subsection, the Factory custom-models Apply button, OLED theme, background opacity, and remote-access settings. No thinking/reasoning selectors — those live in Droid CLI. |
| `src/Sources/AuthStatus.swift` | `AuthManager`, account parsing, expiry detection, file deletion, and per-account disabled-state updates. |
| `src/Sources/AppPreferences.swift` | UserDefaults-backed preferences: fast-mode toggles for GPT 5.3-codex/5.4/5.5; `allowRemote`, `secretKey`, `oledTheme`, `backgroundOpacity`, `verboseLogging`. No thinking-effort keys — reasoning is driven entirely by Droid CLI. |
| `src/Sources/OAuthUsageTracker.swift` | Reads Codex/Claude OAuth quota windows for the "OAuth Quota Usage" section in `SettingsView`. Owns its own refresh button; there is no menu-bar usage display. |
| `src/Sources/NotificationNames.swift` | Shared `Notification.Name` constants (`serverStatusChanged`, `authDirectoryChanged`). |
| `src/Sources/IconCatalog.swift` | Caches `NSImage` lookups from the bundle's resource path so menu-bar / settings icons aren't re-decoded per access. |
| `src/Sources/LogoView.swift` | Inline-SVG `LogoView` used in the settings UI. |
| `src/Sources/TunnelManager.swift` | Stubbed tunnel/remote-access scaffolding; currently not wired into the app flow despite the matching `allowRemote`/`secretKey` preferences. |
| `src/Sources/Resources/config.yaml` | Bundled CLIProxyAPIPlus config (`port: 8318`, localhost binding, Amp upstream settings, auth dir). |
| `src/Info.plist` | Bundle metadata. Current source-of-truth values include app name `DroidProxy`, bundle ID `com.droidproxy.app`, and Sparkle feed URL on `anand-92/droidproxy`. |

## Conventions

- Use `NSLog`, not `print` or `os_log`
- Source-of-truth edits land under `src/` (especially `src/Sources/**`, `src/Sources/Resources/`, `src/Info.plist`) and `create-app-bundle.sh` at the repo root; there is no longer a parallel top-level `resources/` mirror
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
