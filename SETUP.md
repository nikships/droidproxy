# DroidProxy Setup

## 1. Launch & Authenticate

1. Open DroidProxy from your Applications folder
2. Click the menu bar icon and select "Open Settings"
3. Click "Connect" next to Claude Code, Codex, Gemini, Kimi, or **GitHub Copilot** (browser/device-code OAuth), Junie (API key), or **Grok** (device-code browser login)

### GitHub Copilot

1. Connect **GitHub Copilot** in Settings and complete the device-code sign-in.
2. After the local Copilot gateway starts, click **Refresh Models**.
3. Choose up to three models available to your Copilot subscription.
4. Click **Apply** / **Re-apply** under Factory custom models.

Only these selected Copilot models are written into `~/.factory/settings.json`. The gateway runs locally on `127.0.0.1:8319`; no Copilot credential is added to Factory settings.
GitHub Copilot support requires Node.js 20 or later so DroidProxy can run the maintained local gateway. Node.js 22.13 or later additionally enables the gateway's local usage storage.

For **Grok 4.6** (SuperGrok / X Premium+ OAuth → `api.x.ai`):

1. Connect **Grok** in Settings (device-code browser login)
2. Click **Apply** / **Re-apply** under Factory models (registers `custom:droidproxy:grok-4.6`)
3. In Droid, `/model` → **DroidProxy: Grok 4.6**

Optional **Grok 4.6 Fast Mode** (Settings → Grok): rewrites `grok-4.6` → `grok-4.6-fast` through the Cursor API. Enable Beta → Cursor and add a Cursor API key first; `api.x.ai` does not offer `grok-4.6-fast`. Default off.

> Note: some SuperGrok tiers return HTTP 403 on the OAuth API surface even after a successful login. Fallback is an `XAI_API_KEY` via Factory BYOK.

### Grok Imagine (image generation)

Chat and image generation share the same Grok OAuth session, but **Droid will not call the image API by itself**. Install the skill from this repo:

```bash
mkdir -p ~/.factory/skills
cp -R skills/grok-imagine ~/.factory/skills/
```

See [`skills/grok-imagine/SKILL.md`](skills/grok-imagine/SKILL.md). With DroidProxy running and Grok connected, the skill posts to `http://localhost:8317/v1/images/generations` (`grok-imagine-image-2.0`); the proxy injects your subscription bearer and forwards to `api.x.ai`.

### GPT Image (Codex OAuth)

Same pattern as Grok, but through Codex. ChatGPT Plus/Pro OAuth is required; Free accounts are skipped (`auth_not_found`).

```bash
mkdir -p ~/.factory/skills
cp -R skills/gpt-image ~/.factory/skills/
```

See [`skills/gpt-image/SKILL.md`](skills/gpt-image/SKILL.md). With DroidProxy running and Codex connected, the skill posts to `http://localhost:8317/v1/images/generations` (`gpt-image-2.5-flare` or `gpt-image-2.5-sunburst`); CLIProxyAPI injects your Codex bearer. Selecting a DroidProxy GPT chat model does not generate images.

## 2. Configure Factory

Open `~/.factory/settings.json` and add the following to the `customModels` array:

```json
"customModels": [
    {
      "model": "claude-fable-5-1",
      "id": "custom:droidproxy:fable-5-1",
      "index": 0,
      "baseUrl": "http://localhost:8317",
      "apiKey": "dummy-not-used",
      "displayName": "DroidProxy: Fable 5.1",
      "maxOutputTokens": 128000,
      "noImageSupport": false,
      "provider": "anthropic"
    },
    {
      "model": "claude-fable-5",
      "id": "custom:droidproxy:fable-5",
      "index": 1,
      "baseUrl": "http://localhost:8317",
      "apiKey": "dummy-not-used",
      "displayName": "DroidProxy: Fable 5",
      "maxOutputTokens": 128000,
      "noImageSupport": false,
      "provider": "anthropic"
    },
    {
      "model": "claude-opus-5",
      "id": "custom:droidproxy:opus-5",
      "index": 2,
      "baseUrl": "http://localhost:8317",
      "apiKey": "dummy-not-used",
      "displayName": "DroidProxy: Opus 5",
      "maxOutputTokens": 128000,
      "noImageSupport": false,
      "provider": "anthropic"
    },
    {
      "model": "claude-sonnet-4-6",
      "id": "custom:droidproxy:sonnet-4-6",
      "index": 3,
      "baseUrl": "http://localhost:8317",
      "apiKey": "dummy-not-used",
      "displayName": "DroidProxy: Sonnet 4.6",
      "maxOutputTokens": 64000,
      "noImageSupport": false,
      "provider": "anthropic"
    },
    {
      "model": "gpt-5.6-terra",
      "id": "custom:droidproxy:gpt-5.6-terra",
      "index": 4,
      "baseUrl": "http://localhost:8317/v1",
      "apiKey": "dummy-not-used",
      "displayName": "DroidProxy: GPT 5.6 Terra",
      "maxOutputTokens": 128000,
      "noImageSupport": false,
      "provider": "openai"
    },
    {
      "model": "gpt-5.6-sol",
      "id": "custom:droidproxy:gpt-5.6-sol",
      "index": 5,
      "baseUrl": "http://localhost:8317/v1",
      "apiKey": "dummy-not-used",
      "displayName": "DroidProxy: GPT 5.6 Sol",
      "maxOutputTokens": 128000,
      "noImageSupport": false,
      "provider": "openai"
    },
    {
      "model": "gemini-3.1-pro-preview",
      "id": "custom:droidproxy:gemini-3.1-pro",
      "index": 6,
      "baseUrl": "http://localhost:8317",
      "apiKey": "dummy-not-used",
      "displayName": "DroidProxy: Gemini 3.1 Pro",
      "maxOutputTokens": 65536,
      "noImageSupport": false,
      "provider": "google"
    },
    {
      "model": "gemini-3-flash-preview",
      "id": "custom:droidproxy:gemini-3-flash",
      "index": 7,
      "baseUrl": "http://localhost:8317",
      "apiKey": "dummy-not-used",
      "displayName": "DroidProxy: Gemini 3 Flash",
      "maxOutputTokens": 65536,
      "noImageSupport": false,
      "provider": "google"
    },
    {
      "model": "kimi-k3",
      "id": "custom:droidproxy:kimi-k3",
      "index": 8,
      "baseUrl": "http://localhost:8317/v1",
      "apiKey": "dummy-not-used",
      "displayName": "DroidProxy: Kimi K3",
      "maxOutputTokens": 65536,
      "noImageSupport": false,
      "provider": "openai",
      "enableThinking": true,
      "supportedReasoningEfforts": ["max"],
      "defaultReasoningEffort": "max",
      "reasoningEffort": "max"
    }
]
```

Use the standard Claude, Codex, Gemini, and Kimi model aliases in the `model` field. Claude and Gemini entries use `http://localhost:8317` (with `provider: "anthropic"` and `provider: "google"` respectively); GPT/Codex and Kimi entries use `provider: "openai"` with `http://localhost:8317/v1`. Reasoning effort is chosen per session from Droid CLI's model selector. DroidProxy preserves that selection, and CLIProxyAPI translates it to the provider-native request format.

## 3. Choose Reasoning Effort

Reasoning effort is selected per session in Droid CLI's model picker. DroidProxy registers each model with its native reasoning levels, preserves the selected value, and lets CLIProxyAPI translate it to the upstream provider format. Supported levels per model:

- Fable 5.1: `low`, `medium`, `high`, `xhigh`, or `max`
- Fable 5: `low`, `medium`, `high`, `xhigh`, or `max`
- Opus 5: `low`, `medium`, `high`, `xhigh`, or `max`
- Sonnet 4.6: `low`, `medium`, `high`, or `max`
- GPT 5.6 Terra: `none`, `low`, `medium`, `high`, `xhigh`, or `max`
- GPT 5.6 Sol: `dynamic`, `low`, `medium`, `high`, `xhigh`, or `max`
- Gemini 3.1 Pro: `low`, `medium`, or `high`
- Gemini 3 Flash: `minimal`, `low`, `medium`, or `high`
- Kimi K3: `max` (the only currently supported effort)
- Kimi K2.6: `high`

## 4. Enable Thinking Output

1. Start Factory
2. Run `/settings`
3. Set **Show thinking in main view: On**
