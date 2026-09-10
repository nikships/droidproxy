# AGENTS.md

## Build & Run

The Swift package lives in `src/`. Run all `swift build`, `swift run`, and `swift package` commands from there, not from the repo root.

```bash
# Preferred dev loop: kill any running DroidProxy, rebuild the .app bundle, and
# launch the freshly signed build. Use this instead of running create-app-bundle.sh
# + open by hand — it guarantees the old menu-bar process and bundled
# cli-proxy-api are stopped before the new app starts.
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

`dev-relaunch.sh` is the preferred way to run DroidProxy during development. It calls `create-app-bundle.sh` (which runs `swift build -c release` and assembles the signed `.app`) after killing any running `CLIProxyMenuBar` / `cli-proxy-api` processes, then launches the fresh bundle. Do not use it for releases — those go through `.github/workflows/release.yml`.

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
2. Bundled `CLIProxyAPI` on `127.0.0.1:8318`, managed as a child process by `ServerManager`.
3. A separate localhost-only Copilot API gateway on `127.0.0.1:8319`, managed by `CopilotGatewayManager`.

Typical request flow:

`Client -> :8317 ThinkingProxy -> :8318 CLIProxyAPI -> upstream provider`

Selected GitHub Copilot models instead use:

`Client -> :8319 Copilot API gateway -> GitHub Copilot`

### Current ThinkingProxy behavior

Reasoning effort is owned by **Droid CLI**, not the proxy. Each Factory custom model is registered with native reasoning metadata (`enableThinking`, `supportedReasoningEfforts`, `defaultReasoningEffort`, `reasoningEffort`) so Droid's per-session selector exposes every level the model supports, and Droid sends the chosen value in the request body. The proxy does **not** inject `thinking`, `reasoning`, `reasoning_effort`, `output_config`, `budget_tokens`, or `generationConfig.thinkingConfig` for any model — it forwards the request unchanged.

What it still does today:

- **Anthropic-Beta rewriting**: When a Claude request has `thinking.type` of `enabled`/`adaptive`/`auto`, the proxy strips `redact-thinking-2026-02-12` from the `Anthropic-Beta` header and appends the visible-thinking beta list (interleaved-thinking, prompt-caching-scope, etc.). It never injects `fast-mode-*` and always strips it if Factory/Droid sent it — CLIProxyAPI treats any Fast-marked 429 as request-scoped, which blocks OAuth seat failover. Claude has no Fast mode. Without the redact-thinking strip, Claude emits only signed empty thinking blocks.
- **Service tier (fast mode)** for Responses API paths (`/v1/responses`, `/api/v1/responses`): injects `"service_tier":"priority"` for `gpt-5.6-terra` or `gpt-5.6-sol` when `AppPreferences.gpt56TerraFastMode` / `gpt56SolFastMode` is enabled and the client did not already set `service_tier`. Fast mode is API priority and is independent of reasoning effort.
- **Grok 4.6 Fast Mode**: when `AppPreferences.grok46FastMode` is on, `grok-4.6` is rewritten to `grok-4.6-fast` and diverted to the Cursor API (`api.x.ai` does not expose the fast variant). Requires a Cursor API key.
- **Grok native tool-call rewrite**: Grok (including `cursor-grok-*`) often leaks Factory markup (`<|tool_calls_begin|>` / `<|tool_call_begin|>`) into `message.content`. Factory's first-party Grok adapter parses that; `generic-chat-completion-api` does not, so the worker turn ends as plain text. The proxy buffers Grok/Cursor-Grok responses and lifts that markup into OpenAI `tool_calls` before the client sees it.
- **Grok EndFeatureRun repair**: Grok often calls `EndFeatureRun` without `handoff`, or with `validatorsPassed` as a thought-string. Factory rejects those and the worker loops. The proxy inserts a stub `handoff` and coerces `validatorsPassed` before the client sees the call.
- **Grok Execute repair**: Grok often calls `Execute` with only `summary` (or `cmd`/`input`/`shell`) and Factory rejects it (`command is required`). The proxy remaps aliases, lifts a command embedded in `summary` or a same-turn fenced code block, and promotes a summary that is already a shell string. It does **not** invent a command from English. On the request path, `GrokRequestSanitizer` also pins `command` as a required Execute/Bash/Shell parameter so xAI sees the field.
- **Gemini path rewrite**: `/v1/responses` (and `/api/v1/responses`) are rewritten to `/v1/chat/completions` for OAuth Code Assist Gemini models (the `-preview`-suffixed names) since CLIProxyAPI does not support those via the Responses API endpoint.
- **Per-request reasoning log** to `/tmp/droidproxy-debug.log`: each `POST` emits a `REQUEST REASONING:` line that extracts just `reasoning` / `reasoning_effort` / `thinking` / `output_config` / `service_tier` / `generationConfig` from the parsed body so the actual values Droid is sending are visible without dumping the whole prompt. Example: `REQUEST REASONING: model=gpt-5.6-terra reasoning={"effort":"high","summary":"auto"}`.
- Preserves JSON key order by editing the raw JSON string instead of re-serializing (critical for Anthropic's prompt cache). The remaining helpers (`injectJSONField`, `findTopLevelFieldLocation`, etc.) exist for `processOpenAIFastMode`.

What it no longer does (removed in the Droid-CLI-thinking refactor):

- No Claude adaptive thinking injection (Opus 4.8 / Sonnet 5 — `thinking` + `output_config`)
- No classic `thinking.budget_tokens` injection
- No Codex `reasoning.effort` injection
- No Gemini `generationConfig.thinkingConfig` injection
- No Kimi `reasoning_effort` injection
- No `claude-opus-4-8(high)` / `gpt-5.2(xhigh)` etc. “advanced variant” suffix parsing — every level now ships in the single base entry via Droid CLI metadata
- No Max Budget Mode override
- No Amp CLI routing (the `/auth/cli-login` redirect, `/provider/*` rewrite, `ampcode.com` management forwarding, and Amp response normalization were removed when switching to mainline CLIProxyAPI)

## Auth And Providers

The current app/UI exposes these provider types:

- `claude`
- `codex`
- `gemini`
- `kimi`
- `grok` (device-flow OAuth; credentials in `~/.cli-proxy-api/grok-cli.json`; ThinkingProxy forwards `grok-*` to `api.x.ai` and bypasses CLIProxyAPI)
- `copilot` (device-code OAuth; credentials stay in `~/.droidproxy/copilot-api/`; the separate local Copilot API gateway serves only the user-selected models)
- `cline` (browser OAuth via WorkOS AuthKit with a localhost callback on 127.0.0.1:31234; credentials in `~/.cli-proxy-api/cline.json`; ThinkingProxy forwards OpenRouter-style slugs like `kwaipilot/kat-coder-pro` to `api.cline.bot` for Cline's limited-time free models — an app.cline.bot API key cannot use them, only account tokens)

Auth data for `AuthManager`-managed providers lives in `~/.cli-proxy-api/` as JSON files. Copilot is the exception: its gateway owns `~/.droidproxy/copilot-api/github_token`, which DroidProxy never reads.

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
- `CLIProxyAPI` hot-reloads config changes, so provider enable/disable does not require a restart
- The app watches `~/.cli-proxy-api/` for changes from both `AppDelegate` and `SettingsView`

## Key Files

| File | Role |
|---|---|
| `src/Sources/main.swift` | NSApplication entry point that instantiates `AppDelegate` and calls `NSApplicationMain`. |
| `src/Sources/AppDelegate.swift` | App lifecycle, menu bar UI, settings window, notifications, Sparkle updater, auth-directory watcher, startup ordering for the two local servers. |
| `src/Sources/ServerManager.swift` | Starts/stops bundled `cli-proxy-api`, captures logs, merges config (including injecting the remote-management `allow-remote`/`secret-key` settings from UserDefaults), handles provider enable/disable, runs Claude/Codex/Gemini login commands, and kills orphaned backend processes. |
| `src/Sources/ThinkingProxy.swift` | Raw TCP HTTP proxy that forwards requests to CLIProxyAPI (and TLS-forwards Cursor/Junie/Grok/Cline). Rewrites the Anthropic-Beta header to drop `redact-thinking-2026-02-12` on Claude thinking requests and always strips `fast-mode-*` on Claude traffic, injects `service_tier=priority` on enabled Codex fast-mode models, rewrites OAuth Code Assist Gemini `/v1/responses` to `/v1/chat/completions`, sanitizes Grok tool types before `api.x.ai`, diverts `grok-4.6` to the Cursor API as `grok-4.6-fast` when Grok Fast Mode is on, rewrites Grok native `<\|tool_calls_begin\|>` markup into OpenAI `tool_calls`, repairs Grok `EndFeatureRun`/`Execute` arguments, forwards Cline free-model requests (models matching the catalog's Cline slugs) to api.cline.bot with account OAuth, strips Cline's non-streaming `{"data": ...}` response envelope (streaming SSE already unwrapped), and emits a `REQUEST REASONING` log line per request. Does not inject reasoning or thinking fields. |
| `src/Sources/ClaudeAnthropicBetaRewriter.swift` | Strips `fast-mode-*` from Claude `Anthropic-Beta` headers (never injects it) and, on thinking requests, drops `redact-thinking-2026-02-12` then appends the visible-thinking beta list. |
| `src/Sources/GrokAuth.swift` | Grok device-flow OAuth, token refresh (single-flight + terminal-refresh quarantine), path/header helpers for api.x.ai. |
| `src/Sources/ClineAuth.swift` | Cline account OAuth (authorize URL + local 31234 callback + code exchange), refresh-token rotation handling (upstream rotates on every refresh), single-flight `ensureValidAccessToken`, and credential storage in `~/.cli-proxy-api/cline.json`. |
| `src/Sources/GrokRequestSanitizer.swift` | Remaps Factory `custom` tools to `function` (and drops unsupported types) before Grok upstream. |
| `src/Sources/GrokNativeToolCallRewriter.swift` | Lifts Factory/Droid `<\|tool_calls_begin\|>` markup out of Grok chat-completion content into OpenAI `tool_calls` (JSON, SSE, and full HTTP responses). |
| `src/Sources/GrokEndFeatureRunRepair.swift` | Repairs Grok `EndFeatureRun` arguments that omit `handoff` or send a non-bool `validatorsPassed`, and `Execute`/`Read`/`Grep` calls that omit `command`/`file_path`/`pattern` or use aliases. |
| `src/Sources/DroidProxyModelCatalog.swift` | Authoritative catalog of DroidProxy-exposed models. Each `DroidProxyModelDefinition` carries its supported `levels` plus a `defaultLevelValue`, and `settingsEntry` always embeds Factory's native reasoning metadata (`enableThinking`, `supportedReasoningEfforts`, `defaultReasoningEffort`, `reasoningEffort`) so Droid CLI's per-session selector can expose the full level set. Cline free models use the upstream OpenRouter-style slug as `baseModel`, and `clineBaseModels` exposes that set so ThinkingProxy can match Cline traffic exactly. The free list rotates; entries must be updated when Cline swaps promos. |
| `src/Sources/CopilotSupport.swift` | Local `@jeffreycao/copilot-api` gateway lifecycle (`CopilotGatewayState` of `idle`/`starting`/`running`/`failed`, with a `/v1/models` readiness probe so a gateway that exits before binding its port surfaces as `failed`), device-code authentication, account-specific model discovery, and persistence for at most three Factory-selected Copilot models. |
| `src/Sources/SettingsView.swift` | SwiftUI settings UI for server status, launch-at-login, provider toggles, auth flows (including the Cline browser-OAuth login), the Codex fast-mode (`service_tier=priority`) subsection, the Grok 4.6 Fast Mode toggle, the Copilot gateway status row (renders the `failed` reason plus a Retry button), the Factory custom-models Apply button, OLED theme, background opacity, and remote-access settings. No thinking/reasoning selectors — those live in Droid CLI. |
| `src/Sources/AuthStatus.swift` | `AuthManager`, account parsing, expiry detection, file deletion, and per-account disabled-state updates. |
| `src/Sources/AppPreferences.swift` | UserDefaults-backed preferences: fast-mode toggles for GPT 5.6-terra/5.6-sol/5.6-luna and Grok 4.6; `allowRemote`, `secretKey`, `oledTheme`, `backgroundOpacity`, `verboseLogging`. No thinking-effort keys — reasoning is driven entirely by Droid CLI. |
| `src/Sources/OAuthUsageTracker.swift` | Reads Codex/Claude OAuth quota windows for the "OAuth Quota Usage" section in `SettingsView`. Owns its own refresh button; there is no menu-bar usage display. |
| `src/Sources/NotificationNames.swift` | Shared `Notification.Name` constants (`serverStatusChanged`, `authDirectoryChanged`). |
| `src/Sources/IconCatalog.swift` | Caches `NSImage` lookups from the bundle's resource path so menu-bar / settings icons aren't re-decoded per access. |
| `src/Sources/LogoView.swift` | Inline-SVG `LogoView` used in the settings UI. |
| `src/Sources/AuthDirectoryMonitor.swift` | Debounced `DispatchSource` watcher on `~/.cli-proxy-api` that fires an `onChange` callback when auth JSON files are added, changed, or removed. Used by both `AppDelegate` and `SettingsView`. |
| `src/Sources/AuthPaths.swift` | Single source of truth for the auth directory location (`~/.cli-proxy-api`). |
| `src/Sources/Resources/config.yaml` | Bundled CLIProxyAPI config (`port: 8318`, localhost binding, auth dir). |
| `src/Info.plist` | Bundle metadata. Current source-of-truth values include app name `DroidProxy`, bundle ID `com.droidproxy.app`, and Sparkle feed URL on `anand-92/droidproxy`. |

## Conventions

- Use `NSLog`, not `print` or `os_log`
- Source-of-truth edits land under `src/` (especially `src/Sources/**`, `src/Sources/Resources/`, `src/Info.plist`) and `create-app-bundle.sh` at the repo root; there is no longer a parallel top-level `resources/` mirror
- Treat `DroidProxy.app`, `CLIProxyMenuBar`, and `com.droidproxy.app` as the active app identity
- `CLIProxyAPI` is bundled as `src/Sources/Resources/cli-proxy-api`
- `ThinkingProxy` uses surgical string insertion for JSON edits to preserve cache-sensitive key ordering (do not switch to `JSONSerialization.data` round-trips)
- Local backend traffic is intended to stay on localhost only (`127.0.0.1:8318`)

## Release Notes For Agents

Release automation lives in `.github/workflows/release.yml` (no `Makefile` or `scripts/create-release.sh` in this repo). The app ships as a single arm64 build; there is no x86_64 appcast or Intel release path.

If a task touches release tooling, audit the current workflow and `create-app-bundle.sh`.
