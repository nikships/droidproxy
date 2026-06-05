# DroidProxy Setup

## 1. Launch & Authenticate

1. Open DroidProxy from your Applications folder
2. Click the menu bar icon and select "Open Settings"
3. Click "Connect" next to Claude Code, Codex, or Gemini and complete the OAuth flow in your browser

## 2. Configure Factory

Open `~/.factory/settings.json` and add the following to the `customModels` array:

```json
"customModels": [
    {
      "model": "claude-opus-4-8",
      "id": "custom:droidproxy:opus-4-8",
      "index": 0,
      "baseUrl": "http://localhost:8317",
      "apiKey": "dummy-not-used",
      "displayName": "DroidProxy: Opus 4.8",
      "maxOutputTokens": 128000,
      "noImageSupport": false,
      "provider": "anthropic"
    },
    {
      "model": "claude-sonnet-4-6",
      "id": "custom:droidproxy:sonnet-4-6",
      "index": 1,
      "baseUrl": "http://localhost:8317",
      "apiKey": "dummy-not-used",
      "displayName": "DroidProxy: Sonnet 4.6",
      "maxOutputTokens": 64000,
      "noImageSupport": false,
      "provider": "anthropic"
    },
    {
      "model": "gpt-5.4",
      "id": "custom:droidproxy:gpt-5.4",
      "index": 2,
      "baseUrl": "http://localhost:8317/v1",
      "apiKey": "dummy-not-used",
      "displayName": "DroidProxy: GPT 5.4",
      "maxOutputTokens": 128000,
      "noImageSupport": false,
      "provider": "openai"
    },
    {
      "model": "gpt-5.5",
      "id": "custom:droidproxy:gpt-5.5",
      "index": 3,
      "baseUrl": "http://localhost:8317/v1",
      "apiKey": "dummy-not-used",
      "displayName": "DroidProxy: GPT 5.5",
      "maxOutputTokens": 128000,
      "noImageSupport": false,
      "provider": "openai"
    },
    {
      "model": "gemini-3.1-pro-preview",
      "id": "custom:droidproxy:gemini-3.1-pro",
      "index": 4,
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
      "index": 5,
      "baseUrl": "http://localhost:8317",
      "apiKey": "dummy-not-used",
      "displayName": "DroidProxy: Gemini 3 Flash",
      "maxOutputTokens": 65536,
      "noImageSupport": false,
      "provider": "google"
    }
]
```

Use the standard Claude, Codex, and Gemini model aliases in the `model` field. Claude and Gemini entries use `http://localhost:8317` (with `provider: "anthropic"` and `provider: "google"` respectively); GPT/Codex entries use `provider: "openai"` with `http://localhost:8317/v1`. Reasoning effort is chosen per session from Droid CLI's model selector — DroidProxy registers each model with its native reasoning levels and forwards the chosen value upstream unchanged.

## 3. Choose Reasoning Effort

Reasoning effort is selected per session in Droid CLI's model picker — DroidProxy registers each model with its native reasoning levels, so the level you pick in Droid is forwarded upstream unchanged. Supported levels per model:

- Opus 4.8: `low`, `medium`, `high`, `xhigh`, or `max`
- Sonnet 4.6: `low`, `medium`, `high`, or `max`
- GPT 5.4: `low`, `medium`, `high`, or `xhigh`
- GPT 5.5: `low`, `medium`, `high`, or `xhigh`
- Gemini 3.1 Pro: `low`, `medium`, or `high`
- Gemini 3 Flash: `minimal`, `low`, `medium`, or `high`

## 4. Enable Thinking Output

1. Start Factory
2. Run `/settings`
3. Set **Show thinking in main view: On**
