# AGENTS.md

## Scope

These instructions apply only to `windows-wip/`.

## Project

This folder is a Windows-only Electron app for DroidProxy. Keep it isolated from the macOS Swift app in `../src`.

## Commands

Run commands from `windows-wip/`:

```powershell
npm install
npm start
npm run check
npm run build:win
```

Use `npm run check` as the default validator for code changes.

## Conventions

- Treat `src/` and `resources/` as the source of truth.
- Do not edit `node_modules/`, `dist/`, or packaged build outputs.
- Keep Factory custom-model writes GPT-only unless the Windows app scope changes.
- Prefer small, Windows-specific changes that do not affect the repo root macOS app.
