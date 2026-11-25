# GPT Image 2.6 compatibility

DroidProxy serves GPT Image through CLIProxyAPI's Codex OAuth route:

```text
POST http://localhost:8317/v1/images/generations
POST http://localhost:8317/v1/images/edits
Authorization: Bearer dummy-not-used
```

| Request | Result through DroidProxy |
|---|---|
| `gpt-image-2.6-flare`, `gpt-image-2.6-sunburst` or `gpt-image-2.6` generation | Image returned |
| 2.6 JSON edit with an `images` data URL | Edited image returned |
| `complexity` | Accepted |
| `markup` on a JSON edit | Accepted |
| `background: "transparent"` with `output_format: "png"` | RGBA PNG with fully transparent pixels |
| `output_format: "svg"` | PNG returned; the helper refuses to save it as SVG |
| `output_format: "gif"` | HTTP 400, `GIF output is not enabled for this request.` |
| `size`, `quality` | The response values can differ from the request |

Unit tests use an isolated local contract server; they do not prove provider
acceptance.

## Backend boundary

ThinkingProxy forwards non-Grok Images JSON bodies to CLIProxyAPI; it has no
GPT image model allowlist or pricing table. CLIProxyAPI sends the 1.5, 2, 2.5
and 2.6 image IDs directly to the Codex Images endpoints and forwards JSON
bodies unchanged apart from `model` and `stream`. Do not alias a 2.6 ID to a
2.5 ID. Do not send a 2.6 image model as the top-level model of the public
Responses or Chat Completions API.

Image models intentionally stay out of `DroidProxyModelCatalog.swift`:
that catalog provisions Factory **chat** models. The skill's `models` export
lists the image choices and preserves older IDs. API pricing belongs in the
skill, not the Codex subscription quota gauge.

## Official references

- [Flare model](https://developers.openai.com/api/docs/models/gpt-image-2.6-flare)
- [Sunburst model](https://developers.openai.com/api/docs/models/gpt-image-2.6-sunburst)
- [Generation guide](https://developers.openai.com/api/docs/guides/image-generation)
- [Prompting guide](https://developers.openai.com/api/docs/guides/image-prompting)
- [Generate API reference](https://developers.openai.com/api/reference/cli/resources/images/methods/generate/index.md)

The guide documents 2–64 GIF frames; the API reference documents 2–16.
The helper leaves the upper bound to the API unless `GPT_IMAGE_MAX_FRAMES`
sets a local cap. The helper does not impose 2.5 custom-size limits on 2.6.
