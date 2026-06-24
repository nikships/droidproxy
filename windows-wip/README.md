# DroidProxy Windows WIP

Small Electron-based Windows wrapper for the bundled `cli-proxy-api.exe`.

## Scope

- Runs the local API proxy on Windows.
- Supports Codex/GPT OAuth login and usage display.
- Applies GPT-only DroidProxy custom models to Factory settings.
- Keeps Windows-specific work isolated from the macOS Swift app in `../src`.

## Development

```powershell
npm install
npm start
```

Run a syntax check before committing:

```powershell
npm run check
```

Build the portable Windows app with:

```powershell
npm run build:win
```
