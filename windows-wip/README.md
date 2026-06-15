# DroidProxy Windows

GPT-only Windows wrapper for [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI), built for Factory custom models.

## What it does

- Starts and stops a bundled Windows `cli-proxy-api.exe`.
- Opens the Codex/GPT OAuth login flow.
- Shows Codex OAuth usage windows from the ChatGPT usage endpoint.
- Lets you configure host, port, request timeout, retries, and logging in the UI.
- Applies GPT-only custom models to `%USERPROFILE%\.factory\settings.json` with a timestamped backup.

## Run from source

```powershell
npm install
npm start
```

## Build a portable Windows app

```powershell
npm install
npm run build:win
```

The portable app is written to `dist/`.

## Factory models

The **Apply to Factory** button writes only GPT models:

- `custom:droidproxy:gpt-5.4`
- `custom:droidproxy:gpt-5.5`

Both point at `http://<host>:<port>/v1` and use `provider: "openai"`.
