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

For **Grok 4.7** and **Grok 4.7 Fast** (SuperGrok / X Premium+ OAuth):

1. Connect **Grok** in Settings (device-code browser login)
2. Click **Apply** / **Re-apply** under Factory models (registers `custom:droidproxy:grok-4.7` and `custom:droidproxy:grok-4.7-build-fast`)
3. In Droid, `/model` → **DroidProxy: Grok 4.7** or **DroidProxy: Grok 4.7 Fast**

Grok 4.7 and Grok 4.7 Fast (`grok-4.7-build-fast`, the same model on faster infrastructure) are both forwarded to `cli-chat-proxy.grok.com` with `x-grok-model-override`, so usage counts as Grok Build rather than X API. The public xAI API does not serve the fast id.

Apply also removes retired ids, including the old Cursor models (`cursor-composer-2.5`, `cursor-grok-4.6`, `cursor-grok-4.5`, `cursor-small`, `cursor-grok-4.6-fast`) and `grok-4.5` / `grok-4.6`, from `~/.factory/settings.json`.

> Note: some SuperGrok tiers return HTTP 403 on the OAuth API surface even after a successful login. Fallback is an `XAI_API_KEY` via Factory BYOK.

### Grok Imagine (image generation)

Chat and image generation share the same Grok OAuth session, but **Droid will not call the image API by itself**. Install the skill from this repo:

```bash
mkdir -p ~/.factory/skills
cp -R skills/grok-imagine ~/.factory/skills/
```

See [`skills/grok-imagine/SKILL.md`](skills/grok-imagine/SKILL.md). With DroidProxy running and Grok connected, the skill posts to `http://localhost:8317/v1/images/generations` (`grok-imagine-image-2.0`); the proxy injects your subscription bearer and forwards to `api.x.ai`.

### GPT Image (Codex OAuth)

Same pattern as Grok, but through Codex. Connect Codex in Settings. Older
backends skip Free accounts (`auth_not_found`); OpenAI announces 2.6 on all
ChatGPT/Codex tiers, but this OAuth route's 2.6 access is not verified.

```bash
mkdir -p ~/.factory/skills
cp -R skills/gpt-image ~/.factory/skills/
```

Copy the whole directory, not just `SKILL.md`; the optional helper requires
[Bun](https://bun.sh) and no dependencies. See
[`skills/gpt-image/SKILL.md`](skills/gpt-image/SKILL.md) for generation/edit
examples, complexity, markup, SVG and GIF opt-ins, pricing and limits.

The skill defaults to `gpt-image-2.6-flare`; choose `gpt-image-2.6-sunburst`
for detail and consistent edits. Both use `/v1/images/generations` or
`/v1/images/edits`, with CLIProxyAPI injecting the Codex bearer. **The current
backend rejects both 2.6 IDs with HTTP 400.** Until backend support arrives,
explicitly select an older model, e.g. `GPT_IMAGE_MODEL=gpt-image-2.5-flare`,
without new feature fields. See [compatibility proof](skills/gpt-image/COMPATIBILITY.md).
Selecting a GPT chat model does not generate images; do not add image-only
models to Factory's chat-model list.

## 2. Configure Factory

Open `~/.factory/settings.json` and add the following to the `customModels` array:

```json
"customModels": [
    {
      "model": "claude-fable-5-2",
      "id": "custom:droidproxy:fable-5-2",
      "index": 0,
      "baseUrl": "http://localhost:8317",
      "apiKey": "dummy-not-used",
      "displayName": "DroidProxy: Fable 5.2",
      "maxOutputTokens": 128000,
      "maxContextLimit": 872000,
      "noImageSupport": false,
      "provider": "anthropic"
    },
    {
      "model": "claude-opus-5-5",
      "id": "custom:droidproxy:opus-5-5",
      "index": 1,
      "baseUrl": "http://localhost:8317",
      "apiKey": "dummy-not-used",
      "displayName": "DroidProxy: Opus 5.5",
      "maxOutputTokens": 128000,
      "noImageSupport": false,
      "provider": "anthropic"
    },
    {
      "model": "claude-sonnet-4-6",
      "id": "custom:droidproxy:sonnet-4-6",
      "index": 2,
      "baseUrl": "http://localhost:8317",
      "apiKey": "dummy-not-used",
      "displayName": "DroidProxy: Sonnet 4.6",
      "maxOutputTokens": 64000,
      "noImageSupport": false,
      "provider": "anthropic"
    },
    {
      "model": "gpt-6.1-sol",
      "id": "custom:droidproxy:gpt-6.1-sol",
      "index": 3,
      "baseUrl": "http://localhost:8317/v1",
      "apiKey": "dummy-not-used",
      "displayName": "DroidProxy: GPT 6.1 Sol",
      "maxOutputTokens": 128000,
      "maxContextLimit": 272000,
      "noImageSupport": false,
      "provider": "openai",
      "enableThinking": true,
      "supportedReasoningEfforts": ["low", "medium", "high", "xhigh", "max"],
      "defaultReasoningEffort": "xhigh",
      "reasoningEffort": "xhigh"
    },
    {
      "model": "gpt-6.1-terra",
      "id": "custom:droidproxy:gpt-6.1-terra",
      "index": 4,
      "baseUrl": "http://localhost:8317/v1",
      "apiKey": "dummy-not-used",
      "displayName": "DroidProxy: GPT 6.1 Terra",
      "maxOutputTokens": 128000,
      "maxContextLimit": 272000,
      "noImageSupport": false,
      "provider": "openai",
      "enableThinking": true,
      "supportedReasoningEfforts": ["low", "medium", "high", "xhigh", "max"],
      "defaultReasoningEffort": "xhigh",
      "reasoningEffort": "xhigh"
    },
    {
      "model": "gpt-6-luna",
      "id": "custom:droidproxy:gpt-6-luna",
      "index": 5,
      "baseUrl": "http://localhost:8317/v1",
      "apiKey": "dummy-not-used",
      "displayName": "DroidProxy: GPT 6 Luna",
      "maxOutputTokens": 128000,
      "maxContextLimit": 272000,
      "noImageSupport": false,
      "provider": "openai",
      "enableThinking": true,
      "supportedReasoningEfforts": ["low", "medium", "high", "xhigh", "max"],
      "defaultReasoningEffort": "xhigh",
      "reasoningEffort": "xhigh"
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

- Fable 5.2: `low`, `medium`, `high`, `xhigh`, or `max`
- Opus 5.5: `low`, `medium`, `high`, `xhigh`, or `max`
- Haiku 5.5: `low`, `medium`, `high`, `xhigh`, or `max`
- Sonnet 4.6: `low`, `medium`, `high`, or `max`
- GPT 6 Astra, GPT 6.1 Sol, GPT 6.1 Terra, GPT 6 Luna: `low`, `medium`, `high`, `xhigh`, or `max`
- Gemini 3 Flash: `minimal`, `low`, `medium`, or `high`
- Kimi K3: `max` (the only currently supported effort)
- Kimi K2.6: `high`

## 4. Enable Thinking Output

1. Start Factory
2. Run `/settings`
3. Set **Show thinking in main view: On**
