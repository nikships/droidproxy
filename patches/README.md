# CLIProxyAPI patches

The bundled `src/Sources/Resources/cli-proxy-api` is normally the unmodified
upstream release, bumped by `.github/workflows/update-cliproxyapi.yml`.

When a model ships before the upstream `router-for-me/models` registry lists it,
CLIProxyAPI returns `unknown provider for model <id>` because provider resolution
is registry-only. To unblock those models without disabling auto-refresh, the
bundled binary for the current release carries `cliproxy-sonnet5-overlay.patch`.

## What the patch does

- Adds the missing model to the embedded `internal/registry/models/models.json`.
- Adds `mergeEmbeddedFallback` in `internal/registry/model_updater.go`, which
  overlays embedded-only model definitions onto each remote refresh. Remote
  definitions always win; embedded entries only fill gaps.

Remote model refresh stays enabled, so every other model still updates on the
normal 3-hour cycle. Once the upstream registry publishes the model, the remote
definition takes precedence and the overlay becomes a no-op.

## Auto-revert

`update-cliproxyapi.yml` overwrites `src/Sources/Resources/cli-proxy-api` with
the next upstream release, dropping the patch automatically. Re-apply only if a
model is again needed ahead of the registry.

## Rebuild

```bash
git clone --depth 1 --branch v7.2.47 https://github.com/router-for-me/CLIProxyAPI.git
cd CLIProxyAPI
git apply /path/to/patches/cliproxy-sonnet5-overlay.patch
COMMIT=$(git rev-parse --short HEAD)
CGO_ENABLED=1 GOOS=darwin GOARCH=arm64 go build \
  -ldflags="-s -w -X main.Version=7.2.47 -X main.Commit=${COMMIT} -X main.BuildDate=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  -o cli-proxy-api ./cmd/server/
```
