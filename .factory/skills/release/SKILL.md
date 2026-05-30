---
name: release
version: 1.0.0
description: |
  Build, sign, notarize, and publish a new DroidProxy release. Use when the user
  wants to cut a release, merge a PR and ship it, or asks to build/notarize/publish.
  Covers the full pipeline: PR merge, version bump, swift build, code signing,
  Apple notarization, Sparkle appcast update, and GitHub release creation.
---

# DroidProxy Release

End-to-end release pipeline for DroidProxy macOS menu bar app.

## Prerequisites

- Developer ID signing identity available in keychain
- `notarytool` keychain profile named `"notarytool"` configured
- Sparkle EdDSA signing key in keychain (used by `sign_update`)
- `gh` CLI authenticated with push access to `anand-92/droidproxy`
- On the `main` branch with a clean working tree

## Steps

### 1. Determine version

Check the latest git tag and the commits being released to decide the new semver:

```bash
git tag --sort=-v:refname | head -5
git log --oneline $(git describe --tags --abbrev=0)..HEAD
```

- New feature -> bump minor (e.g. 1.5.0 -> 1.6.0)
- Bug fix only -> bump patch (e.g. 1.5.0 -> 1.5.1)
- CLIProxyAPI bump alone -> bump patch

### 2. Bump version in Info.plist

Edit `src/Info.plist` and update `CFBundleShortVersionString` to the new version.

### 3. Build the app bundle

```bash
APP_VERSION=<version> ./create-app-bundle.sh
```

This does a release swift build from `src/`, assembles the `.app` bundle, signs everything
(cli-proxy-api, Sparkle.framework, main executable) with Developer ID, and verifies.

The build number (`CFBundleVersion`) is auto-set to `git rev-list --count HEAD`.

### 4. Notarize

```bash
ditto -c -k --sequesterRsrc --keepParent "DroidProxy.app" "DroidProxy-notarize.zip"
xcrun notarytool submit "DroidProxy-notarize.zip" --keychain-profile "notarytool" --wait
xcrun stapler staple "DroidProxy.app"
```

Wait for `status: Accepted` before proceeding. If rejected, fetch the log:

```bash
xcrun notarytool log <submission-id> --keychain-profile "notarytool"
```

### 5. Create distribution zip and sign with Sparkle

```bash
ditto -c -k --sequesterRsrc --keepParent "DroidProxy.app" "DroidProxy-arm64.zip"
src/.build/artifacts/sparkle/Sparkle/bin/sign_update DroidProxy-arm64.zip
```

Capture the `sparkle:edSignature="..."` and `length="..."` from the output.

### 6. Update appcast.xml

Add a new `<item>` block at the top of `appcast.xml` (after `<language>en</language>`):

```xml
<item>
  <title>Version X.Y.Z</title>
  <sparkle:version>BUILD_NUMBER</sparkle:version>
  <sparkle:shortVersionString>X.Y.Z</sparkle:shortVersionString>
  <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
  <pubDate>DAY, DD MMM YYYY HH:MM:SS +0000</pubDate>
  <enclosure url="https://github.com/anand-92/droidproxy/releases/download/vX.Y.Z/DroidProxy-arm64.zip"
             type="application/octet-stream"
             sparkle:edSignature="SIGNATURE_FROM_STEP_5"
             length="LENGTH_FROM_STEP_5"/>
</item>
```

- `sparkle:version` = the build number from step 3 (printed during build)
- `pubDate` = current UTC time in RFC 2822 format

### 7. Commit, tag, and push

```bash
git add src/Info.plist appcast.xml
git commit -m "Update appcast for vX.Y.Z"
git tag vX.Y.Z
git push origin main --tags
```

Before committing, run `git diff --cached` to verify no secrets or unintended files.

### 8. Create GitHub release

```bash
gh release create vX.Y.Z DroidProxy-arm64.zip \
  --title "vX.Y.Z" \
  --notes "### Added
- Feature description
- **CLIProxyAPI X.X.X** -- Latest upstream release"
```

## Verify it worked

- Release visible at `https://github.com/anand-92/droidproxy/releases/tag/vX.Y.Z`
- `DroidProxy-arm64.zip` attached to the release
- `appcast.xml` on main has the new entry (existing installs will auto-update within 24h)
- Run `codesign --verify --deep --strict DroidProxy.app` confirms valid signature

## What not to do

- Don't skip notarization -- unsigned apps won't launch on recent macOS without manual override.
- Don't re-create the zip after stapling for Sparkle signing -- staple first, then zip, then sign.
  The order is: notarize zip -> staple .app -> fresh zip for distribution -> sparkle sign.
- Don't edit `appcast.xml` without the actual Sparkle signature -- copy/paste errors break auto-update.
- Don't push the tag before the appcast commit, or the release download URL will 404 until the asset is uploaded.
