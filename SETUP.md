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
      "model": "claude-opus-4-7",
      "id": "custom:droidproxy:opus-4-7",
      "index": 0,
      "baseUrl": "http://localhost:8317",
      "apiKey": "dummy-not-used",
      "displayName": "DroidProxy: Opus 4.7",
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
      "model": "gpt-5.2",
      "id": "custom:droidproxy:gpt-5.2",
      "index": 2,
      "baseUrl": "http://localhost:8317/v1",
      "apiKey": "dummy-not-used",
      "displayName": "DroidProxy: GPT 5.2",
      "maxOutputTokens": 128000,
      "noImageSupport": false,
      "provider": "openai"
    },
    {
      "model": "gpt-5.3-codex",
      "id": "custom:droidproxy:gpt-5.3-codex",
      "index": 3,
      "baseUrl": "http://localhost:8317/v1",
      "apiKey": "dummy-not-used",
      "displayName": "DroidProxy: GPT 5.3 Codex",
      "maxOutputTokens": 128000,
      "noImageSupport": false,
      "provider": "openai"
    },
    {
      "model": "gpt-5.4",
      "id": "custom:droidproxy:gpt-5.4",
      "index": 4,
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
      "index": 5,
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
    }
]
```

Use the standard Claude and Codex model aliases in the `model` field. Claude entries use `provider: "anthropic"` with `http://localhost:8317`; GPT/Codex and Gemini entries use `provider: "openai"` with `http://localhost:8317/v1`. DroidProxy applies Claude adaptive thinking, Codex reasoning effort, and Gemini thinking levels based on the selected model and the effort/level setting in DroidProxy itself.

## 3. Configure Thinking Effort

1. Open DroidProxy Settings
2. Set the desired effort:
   - Opus 4.7: `low`, `medium`, `high`, `xhigh`, or `max`
   - Sonnet 4.6: `low`, `medium`, `high`, or `max`
   - GPT 5.2: `low`, `medium`, `high`, or `xhigh`
   - GPT 5.3 Codex: `low`, `medium`, `high`, or `xhigh`
   - GPT 5.4: `low`, `medium`, `high`, or `xhigh`
   - GPT 5.5: `low`, `medium`, `high`, or `xhigh`
   - Gemini 3.1 Pro: `low`, `medium`, or `high`
   - Gemini 3 Flash: `minimal`, `low`, `medium`, or `high`

## 4. Enable Thinking Output

1. Start Factory
2. Run `/settings`
3. Set **Show thinking in main view: On**
