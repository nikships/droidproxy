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

Meta Muse models (`muse-spark-1.3`, `muse-spark-1.3-contributor`) split by API:

- **Responses** (`/v1/responses`, `/responses/compact`): ThinkingProxy TLS-forwards to `https://api.meta.ai/v1` with the minted Model API key. CLIProxyAPI's generic `openai-compatibility` executor otherwise rewrites Responses into `/chat/completions`, which drops `reasoning.encrypted_content` and breaks long Muse/Foundry runs.
- **Chat Completions**: still `:8317 -> :8318 -> api.meta.ai` via the `openai-compatibility` block `ServerManager` writes into `merged-config.yaml`, so multi-account failover keeps working for Completions clients.

### Current ThinkingProxy behavior

Reasoning effort is owned by **Droid CLI**, not the proxy. Each Factory custom model is registered with native reasoning metadata (`enableThinking`, `supportedReasoningEfforts`, `defaultReasoningEffort`, `reasoningEffort`) so Droid's per-session selector exposes every level the model supports, and Droid sends the chosen value in the request body. The proxy does **not** inject `thinking`, `reasoning`, `reasoning_effort`, `output_config`, `budget_tokens`, or `generationConfig.thinkingConfig` for any model — it forwards the request unchanged.

What it still does today:

- **Anthropic-Beta rewriting**: When a Claude request has `thinking.type` of `enabled`/`adaptive`/`auto`, the proxy strips `redact-thinking-2026-02-12` from the `Anthropic-Beta` header and appends the visible-thinking beta list (interleaved-thinking, prompt-caching-scope, etc.). It never injects `fast-mode-*` and always strips it if Factory/Droid sent it — CLIProxyAPI treats any Fast-marked 429 as request-scoped, which blocks OAuth seat failover. Claude has no Fast mode. Without the redact-thinking strip, Claude emits only signed empty thinking blocks.
- **Service tier (fast mode)** for Responses API paths (`/v1/responses`, `/api/v1/responses`): injects `"service_tier":"priority"` for `gpt-6-astra`, `gpt-6-sol`, or `gpt-6-luna` when `AppPreferences.gpt6AstraFastMode` / `gpt6SolFastMode` / `gpt6LunaFastMode` is enabled and the client did not already set `service_tier`. Fast mode is API priority and is independent of reasoning effort.
- **Grok 4.7 Fast**: `grok-4.7-build-fast` is a separate SuperGrok catalog model (same OAuth bearer as `grok-4.7`). `grok-4.7` TLS-forwards to `api.x.ai`. The fast id is not on the public API; ThinkingProxy sends it to `cli-chat-proxy.grok.com` with `X-XAI-Token-Auth: xai-grok-cli`, `x-grok-model-override: grok-4.7-build-fast`, `x-grok-client-version`, and `x-grok-client-identifier: grok-shell`. The proxy rejects a missing client version. The JSON `model` field stays `grok-4.7-build-fast`. Reasoning effort stays whatever Droid put in the body.
- **Grok native tool-call rewrite**: Grok often leaks Factory markup (`<|tool_calls_begin|>` / `<|tool_call_begin|>`) into `message.content`, or a fenced `{"name","arguments"}` JSON object. Factory's first-party Grok adapter parses the markup; the custom OpenAI route does not, so the worker turn ends as plain text. The proxy buffers Grok responses and lifts markup or JSON into OpenAI `tool_calls` before the client sees it.
- **Grok EndFeatureRun repair**: Grok often calls `EndFeatureRun` without `handoff`, or with `validatorsPassed` as a thought-string. Factory rejects those and the worker loops. The proxy inserts a stub `handoff` and coerces `validatorsPassed` before the client sees the call.
- **Grok Execute repair**: Grok often calls `Execute` with only `summary` (or `cmd`/`input`/`shell`) and Factory rejects it (`command is required`). The proxy remaps aliases, lifts a command embedded in `summary` or a same-turn fenced code block, and promotes a summary that is already a shell string. It does **not** invent a command from English. On the request path, `GrokRequestSanitizer` also pins `command` as a required Execute/Bash/Shell parameter so xAI sees the field.
- **Gemini path rewrite**: `/v1/responses` (and `/api/v1/responses`) are rewritten to `/v1/chat/completions` for OAuth Code Assist Gemini models (the `-preview`-suffixed names) since CLIProxyAPI does not support those via the Responses API endpoint.
- **Meta Muse Responses TLS-forward**: `muse-spark-1.3` / `muse-spark-1.3-contributor` POSTs to `/v1/responses` (and `/responses/compact`) skip CLIProxyAPI and go to `api.meta.ai` with the minted Model API key, preserving encrypted reasoning. Chat Completions for those models still use the `openai-compatibility` block.
- **Meta usage sniffing**: Meta has no usage endpoint, so the proxy inspects (never modifies) relayed Meta Responses bytes for `response.subscription_usage` SSE events (`window` 5h + `weekly` percents with `resets_at`) and records them per serving account into `MetaMuseUsageStore`, which backs the Meta cards in OAuth Quota Usage with `muse /usage`-style "as of" semantics.
- **Per-request reasoning log** to `/tmp/droidproxy-debug.log`: each `POST` emits a `REQUEST REASONING:` line that extracts just `reasoning` / `reasoning_effort` / `thinking` / `output_config` / `service_tier` / `generationConfig` from the parsed body so the actual values Droid is sending are visible without dumping the whole prompt. Example: `REQUEST REASONING: model=gpt-6-sol reasoning={"effort":"high","summary":"auto"}`.
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
- `copilot` (device-code OAuth; credentials stay in `~/.droidproxy/copilot-api/`; the separate local Copilot API gateway serves only the user-selected models)
- `meta` (Meta Muse subscription; device-code OAuth against `auth.meta.com` reproduces the `muse` CLI's own login flow, then mints a Model API key from `api.meta.ai/muse-code/key`. Completions keys are written into a generic `openai-compatibility` block in `merged-config.yaml`; Responses are TLS-forwarded by ThinkingProxy. This contract is reverse-engineered from the `muse` binary and a third-party client, not official docs.)

Auth data for `AuthManager`-managed providers lives in `~/.cli-proxy-api/` as JSON files. Copilot is the exception: its gateway owns `~/.droidproxy/copilot-api/github_token`, which DroidProxy never reads. Meta Muse is a second exception: its per-account identity tokens and minted Model API keys live in `~/.droidproxy/meta/accounts.json` (mode 0600, parent directory 0700; legacy `credentials.json` is migrated automatically), never in `~/.cli-proxy-api/`.

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
| `src/Sources/ThinkingProxy.swift` | Raw TCP HTTP proxy that forwards requests to CLIProxyAPI (and TLS-forwards Junie/Grok/Meta Responses). Rewrites the Anthropic-Beta header to drop `redact-thinking-2026-02-12` on Claude thinking requests and always strips `fast-mode-*` on Claude traffic, injects `service_tier=priority` on enabled Codex fast-mode models, rewrites OAuth Code Assist Gemini `/v1/responses` to `/v1/chat/completions`, sanitizes Grok tool types, sends `grok-4.7` to `api.x.ai` and `grok-4.7-build-fast` to `cli-chat-proxy.grok.com`, lifts Grok tool markup into OpenAI `tool_calls`, repairs Grok `EndFeatureRun`/`Execute` arguments, TLS-forwards Muse Spark `/v1/responses` to `api.meta.ai`, sniffs `response.subscription_usage` SSE events from Meta Responses streams into `MetaMuseUsageStore` (relayed bytes pass through unchanged), and emits a `REQUEST REASONING` log line per request. Does not inject reasoning or thinking fields. |
| `src/Sources/MetaMuseUpstream.swift` | Pure helpers: Muse model detection, Responses-path detection, and `api.meta.ai` path normalization used by ThinkingProxy's TLS forward. |
| `src/Sources/ClaudeAnthropicBetaRewriter.swift` | Strips `fast-mode-*` from Claude `Anthropic-Beta` headers (never injects it) and, on thinking requests, drops `redact-thinking-2026-02-12` then appends the visible-thinking beta list. |
| `src/Sources/GrokAuth.swift` | Grok device-flow OAuth, token refresh (single-flight + terminal-refresh quarantine), path/header helpers. `grok-4.7` → `api.x.ai`; `grok-4.7-build-fast` → `cli-chat-proxy.grok.com` plus `x-grok-model-override`. |
| `src/Sources/GrokRequestSanitizer.swift` | Remaps Factory `custom` tools to `function` (and drops unsupported types) before Grok upstream. |
| `src/Sources/GrokNativeToolCallRewriter.swift` | Lifts Factory/Droid `<\|tool_calls_begin\|>` markup out of Grok chat-completion content into OpenAI `tool_calls` (JSON, SSE, and full HTTP responses). |
| `src/Sources/GrokEndFeatureRunRepair.swift` | Repairs Grok `EndFeatureRun` arguments that omit `handoff` or send a non-bool `validatorsPassed`, and `Execute`/`Read`/`Grep` calls that omit `command`/`file_path`/`pattern` or use aliases. |
| `src/Sources/DroidProxyModelCatalog.swift` | Authoritative catalog of DroidProxy-exposed models. Each `DroidProxyModelDefinition` carries its supported `levels` plus a `defaultLevelValue`, and `settingsEntry` always embeds Factory's native reasoning metadata (`enableThinking`, `supportedReasoningEfforts`, `defaultReasoningEffort`, `reasoningEffort`) so Droid CLI's per-session selector can expose the full level set. |
| `src/Sources/CopilotSupport.swift` | Local `@jeffreycao/copilot-api` gateway lifecycle (`CopilotGatewayState` of `idle`/`starting`/`running`/`failed`, with a `/v1/models` readiness probe so a gateway that exits before binding its port surfaces as `failed`), device-code authentication, account-specific model discovery, and persistence for at most three Factory-selected Copilot models. |
| `src/Sources/MetaMuseSupport.swift` | `MetaMuseAuthManager` reproduces `muse login`'s device-code flow entirely in-process (no child process): device authorization + token polling against `auth.meta.com`, then Model API key minting against `api.meta.ai/muse-code/key`. `AppDelegate` checks hourly and independently refreshes enabled accounts within 6h of their ~24h key expiry. Completions keys are written into CLIProxyAPI; Responses skip it. |
| `src/Sources/MetaMuseCredentialStore.swift` | Private multi-account persistence, legacy migration, account disable/remove, and stale-refresh protection. `ServerManager` emits all enabled, unexpired keys as `api-key-entries` for Completions round-robin/sequential failover. Responses TLS-forward uses the first usable key. `.metaAccountsChanged` triggers config hot reload and the shared Settings account list. |
| `src/Sources/MetaMuseUsageStore.swift` | Last-observed Meta subscription quota per account id (`~/.droidproxy/meta/usage.json`). Meta has no usage endpoint — the 5-hour window and weekly percents arrive as `response.subscription_usage` SSE events that ThinkingProxy sniffs into this store (same "as of last response" semantics as `muse /usage`). `.metaUsageChanged` drives live Settings card updates without refetching other providers. |
| `src/Sources/SettingsView.swift` | SwiftUI settings UI for server status, launch-at-login, provider toggles, auth flows, the Codex fast-mode (`service_tier=priority`) subsection, the Copilot gateway status row (renders the `failed` reason plus a Retry button), the Factory custom-models Apply button, OLED theme, background opacity, and remote-access settings. No thinking/reasoning selectors — those live in Droid CLI. |
| `src/Sources/AuthStatus.swift` | `AuthManager`, account parsing, expiry detection, file deletion, and per-account disabled-state updates. |
| `src/Sources/AppPreferences.swift` | UserDefaults-backed preferences: fast-mode toggles for GPT 6 Astra/Sol/Luna; `allowRemote`, `secretKey`, `oledTheme`, `backgroundOpacity`, `verboseLogging`. No thinking-effort keys — reasoning is driven entirely by Droid CLI. |
| `src/Sources/OAuthUsageTracker.swift` | Reads Codex/Claude OAuth quota windows, the SuperGrok pooled credit window (`cli-chat-proxy.grok.com/v1/billing?format=credits`, bearer from `GrokAuth.ensureValidAccessToken`), and Meta last-observed usage from `MetaMuseUsageStore` (no network; only the account serving Responses traffic ever gets observations) for the "OAuth Quota Usage" section in `SettingsView`. Codex window titles come from `limit_window_seconds` because plans differ (5-hour + weekly, weekly only, or monthly only); Claude always has 5-hour + weekly; Meta has 5-hour + weekly with an "as of" stamp; SuperGrok has one weekly window. Owns its own refresh button; there is no menu-bar usage display. |
| `src/Sources/OAuthUsageViews.swift` | Compact quota dashboard: an adaptive grid of small per-account cards, each with one hollow ring gauge per window that drains as quota is used. Depends only on the usage model types, so it can be rendered outside the full app. |
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
