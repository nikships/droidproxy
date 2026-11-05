# GPT Image 2.6 compatibility

Checked November 4, 2026. This is **client-side request support**, not a
claim that the bundled OAuth backend serves GPT Image 2.6.

## Real proxy proof

Both requests went through the existing installed DroidProxy route:

```text
POST http://localhost:8317/v1/images/generations
Authorization: Bearer dummy-not-used
prompt: A small red cube on a plain white background, no text.
quality: low
size: 1024x1024

gpt-image-2.6-flare     -> HTTP 400, invalid_request_error
gpt-image-2.6-sunburst  -> HTTP 400, invalid_request_error

Model <id> is not supported on /v1/images/generations or /v1/images/edits.
```

No images were generated, so there are no authentic 2.6 sample files.
Complexity, markup, SVG, GIF, tier access, and 2.6 edit fidelity could not be
live-verified behind this rejection. Unit tests use an isolated local contract
server; they do not prove provider acceptance.

## Backend boundary

ThinkingProxy already forwards non-Grok Images JSON bodies to CLIProxyAPI;
it has no GPT image model allowlist or pricing table to extend. Keep that
pass-through and all older IDs intact. Do not alias a 2.6 ID to a 2.5 ID.

CLIProxyAPI upstream `main`, inspected November 4, has hard-coded image model
lists in:

- `sdk/api/handlers/openai/openai_images_handlers.go`: `isCodexImagesToolModel`
  accepts 1.5, 2, 2.5 Flare/Sunburst and the 2.5 backend alias, not 2.6.
- `internal/runtime/executor/codex_openai_images.go`: its direct image routing
  and request preparation also need auditing for the new IDs/fields.
  Its Responses-tool fallback copies selected fields, not arbitrary JSON;
  complexity/markup/frame controls must not be assumed to survive it.

Allowlisting alone would not prove that ChatGPT's private OAuth backend
accepts the IDs or parameters. No unverified backend patch, binary swap,
new credential flow, or public-API-key fallback is included here. After an
upstream update, repeat the live requests and then test each opt-in, including
markup preservation and decoded SVG/GIF bytes. Do not send a 2.6 image model
as the top-level model of the public Responses or Chat Completions API.

Image models intentionally stay out of `DroidProxyModelCatalog.swift`:
that catalog provisions Factory **chat** models. The skill's `models` export
lists the image choices and preserves older IDs. API pricing belongs in the
skill, not the Codex subscription quota gauge.

## Related repositories, read-only inspection

- **nikships/droidproxy-omarchy:** `skills/gpt-image/SKILL.md` is the old 2.5-only
  version. Port this whole skill directory and its Bun tests/CI; update
  README/SETUP image instructions. Its CLIProxyAPI dependency needs the same
  image-handler/executor support before 2.6 can work. Do not put these IDs in
  `internal/catalog/catalog.go` as chat models. No changes made there.
- **/Users/nik/repos/droid-office:** no GPT image IDs found. The model picker
  (`src/client/ui/models.ts`) consumes Droid's model catalogue, rather than a
  hard-coded image model list. No chat model-list change is needed. If the
  Office distributes a copy of this image skill in future, copy the whole
  directory and preserve the same compatibility caveat. No changes made there.

## Official references

- [Flare model](https://developers.openai.com/api/docs/models/gpt-image-2.6-flare)
- [Sunburst model](https://developers.openai.com/api/docs/models/gpt-image-2.6-sunburst)
- [Generation guide](https://developers.openai.com/api/docs/guides/image-generation)
- [Prompting guide](https://developers.openai.com/api/docs/guides/image-prompting)
- [Generate API reference](https://developers.openai.com/api/reference/cli/resources/images/methods/generate/index.md)

The guide documents 2–64 GIF frames; the API reference documents 2–16.
The helper leaves the upper bound to the API unless `GPT_IMAGE_MAX_FRAMES`
sets a local cap. The helper does not impose 2.5 custom-size limits on 2.6.
