---
name: gpt-image
version: 2.0.0
description: |
  Generate or edit images via GPT Image 2.5 Flare or Sunburst through
  DroidProxy Codex OAuth (no OPENAI_API_KEY). Use when the user asks to
  generate, create, draw, or edit an image with GPT, OpenAI, Codex,
  gpt-image, or DALL-E, including transparent PNGs, and DroidProxy Codex
  OAuth is available. Prefer this over inventing image URLs or base64. If
  they name Grok or Imagine, use grok-imagine instead.
---

# GPT Image 2.5 (via DroidProxy Codex)

POST `http://localhost:8317/v1/images/generations` (or `/edits`) with
`Authorization: Bearer dummy-not-used`. Send only `gpt-image-2.5-flare` or
`gpt-image-2.5-sunburst`. Never send an older image model, a dated snapshot,
or a chat id (`gpt-*` without `image`). Never use an `OPENAI_API_KEY`. Chat
models on `:8317` do not generate images.

Default to **Flare** for fast, high-quality everyday generation. Use
**Sunburst** when the user prioritizes demanding quality, editing precision,
or subject preservation over latency. If Sunburst meets the requirements,
prefer Flare only after it produces acceptable results on the same prompt,
references, dimensions, and quality setting.

Use this for generating or editing visual assets, not for understanding an
image the user already attached.

## Generate

Requests often take 15–70s. Use `--max-time 180`. Default `quality` to
`auto`; select a higher explicit setting only to meet a quality requirement.

```bash
RESP=$(curl -sS --max-time 180 http://localhost:8317/v1/images/generations \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer dummy-not-used" \
  -d "$(jq -n --arg p "A red balloon on a wooden table, soft natural light" \
    '{model:"gpt-image-2.5-flare", prompt:$p, size:"1024x1024",
      quality:"auto"}')")

if B64=$(printf '%s' "$RESP" | jq -er '.data[0].b64_json' 2>/dev/null); then
  printf '%s' "$B64" | base64 -d > out.png
else
  printf '%s\n' "$RESP" >&2
  exit 1
fi
```

Check `.data[0].b64_json` before decoding. On failure print the raw body —
Codex errors are JSON (`usage_limit_reached`, `auth_not_found`,
`moderation_blocked`).

## Edit

Same auth. JSON with a data URL — no upload step, no `file_id`. Do **not**
pass the data URL through `jq --arg`: a typical generated PNG is larger
than `ARG_MAX` (~1MB on macOS) and `jq` dies with `Argument list too long`.
Write the data URL to a file and use `--rawfile`, then POST with
`--data-binary`. Decode the same way as Generate.

```bash
SRC_FILE=$(mktemp)
REQ=$(mktemp)
printf 'data:image/png;base64,%s' "$(base64 -i ./photo.png)" > "$SRC_FILE"
jq -n --arg p "Make it blue-tinted studio lighting" --rawfile u "$SRC_FILE" \
  '{model:"gpt-image-2.5-sunburst", prompt:$p, images:[{image_url:$u}],
    quality:"auto"}' > "$REQ"

RESP=$(curl -sS --max-time 180 http://localhost:8317/v1/images/edits \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer dummy-not-used" \
  --data-binary @"$REQ")
rm -f "$SRC_FILE" "$REQ"

if B64=$(printf '%s' "$RESP" | jq -er '.data[0].b64_json' 2>/dev/null); then
  printf '%s' "$B64" | base64 -d > out.png
else
  printf '%s\n' "$RESP" >&2
  exit 1
fi
```

Pick the data-URL mime from the source (`image/jpeg`, `image/png`,
`image/webp`). Optional `mask.image_url` (PNG with alpha) marks the region
to replace. Chain edits by feeding each output back as the next
`images[0].image_url`.

## Prompting

If the user gives a detailed prompt or asks you to use theirs, use it
verbatim. Otherwise define the intended result, then describe the subject,
action/pose, setting, style, composition, lighting/mood, visible details, and
constraints. For complex work, use labeled sections. Keep requirements easy
to read rather than relying on special prompt syntax.

Quote required text exactly, specify its placement and typography, ask for no
extra text, and verify spelling and legibility. For edits, say “change only X”
and explicitly list what must stay the same. Identify each reference image by
number and role (subject, style, clothing, or background). Make one change per
edit and restate critical preservation constraints on every turn.

Ground named people, brands, places, and “current/latest” facts with a web
search first. For a named real person, edit from a real reference photo —
do not generate the likeness from text alone.

## Parameters

| Field | Values | Notes |
|---|---|---|
| `model` | `gpt-image-2.5-flare`, `gpt-image-2.5-sunburst` | Flare by default; Sunburst for demanding quality or precise edits. No other model ids. |
| `prompt` | string | Required on generate and edit. |
| `size` | `auto` or `WIDTHxHEIGHT` | Each edge ≤3840 and divisible by 16; aspect ratio ≤3:1; 655,360–8,294,400 total pixels. Above 2560×1440 is experimental. |
| `quality` | `auto`, `low`, `medium`, `high`, `xhigh`, `max` | Default `auto`. Compare one setting at a time; use `xhigh`/`max` only for an unmet quality requirement. Never send `hd` or `standard`. |
| `n` | 1–10 | Default 1. Same-prompt variations use `n`, not parallel calls. |
| `background` | `auto`, `opaque`, `transparent` | `transparent` needs `output_format` `png` or `webp`. |
| `output_format` | `png`, `jpeg`, `webp` | Send `png` for transparency. |
| `output_compression` | 0–100 | JPEG/WebP only. Omit unless asked. |
| `images` | `[{image_url}]` | Edits only. Data URL or https URL. |
| `mask` | `{image_url}` | Edits only. PNG with alpha. |

## Response

```json
{"created": 0, "background": "opaque", "data": [{"b64_json": "..."}],
 "output_format": "png", "quality": "low", "size": "1536x1024", "usage": {}}
```

GPT Image 2.5 always returns base64, so do not send `response_format`.
`.data[0]` is only `b64_json` — no `url`, no `mime_type`. Pick the file
extension from top-level `output_format` when present, otherwise from the
decoded magic bytes (`PNG` / `JFIF` / `RIFF…WEBP`).

Codex OAuth often ignores `size` and sometimes `quality`. A `1024x1024` /
`low` request may come back `1536x1024` / `low`, or an off-enum size like
`1312x1199` with `quality: medium`. Trust the response `size` / `quality` /
`background` and the decoded IHDR. Do **not** retry just because they
differ from the request.

## Transparency

When the user **explicitly** wants a transparent PNG or alpha background
(sticker, cutout, icon), send both:

```json
{"background":"transparent","output_format":"png"}
```

If they asked for a campaign, slide, or print asset without mentioning
transparency, keep opaque or ask. Don't assume.

The prompt beats `background`. If it describes a backdrop, scene, color,
plinth, or shadow, the model paints that instead of alpha. Keep the prompt
on an isolated subject and say so explicitly:

- Isolated object, fully visible, generously padded
- Actual fully transparent alpha
- No backdrop, rectangle, plinth, cast shadow, watermark, or readable label text
- Preserve natural transparency, refraction, and fine material edges (glass, ribbon, fibers)

Size by use: icons/stickers `1024x1024`, product shots `1024x1536`, charts
`1536x1024`. Compare `medium` or `high` when the asset has small text.
Expect the returned pixel size to differ; that's not a failure.

**Products / campaign cutouts.** One object. No scene. Ask for fully
transparent alpha around the silhouette. Good for reuse across storefronts
and seasonal backgrounds.

**Charts for dark slides.** Ask for a genuinely transparent background
*and* a transparent plot area — not just a transparent silhouette. No
card, frame, filled panel, title, or grid fill. Specify pale/white labels
and bright series colors so they read on navy or gradient themes. Keep
exact data values in the prompt, then verify labels and proportions
against the source before using the chart.

**Icons, stickers, decorations.** Keep everything outside the tile, die-cut
border, or sprig transparent — including gaps between branches and leaves.
No text, watermark, or drop shadow.

**Print-on-demand.** Generate the artwork and any blank garments as
separate transparent PNGs. Keep open space *inside* the design transparent
too (no white rectangle or badge). Composite locally; do not bake the
print onto the garment in one generation if they need to reuse it.

After decoding, confirm a real alpha channel (RGBA / PNG `tRNS`) and that
some pixels are fully transparent. Also check top-level
`"background":"transparent"`. If the file is opaque, strip backdrop
language from the prompt and retry once.

If `background:transparent` 400s, generate on a flat uniform background
that contrasts with the subject and key it out locally (PIL, ImageMagick).
Recolor the subject for the background they named before you finish — a
near-black mark on a dark header is invisible. Say what you did.

## Failures

| Symptom | Fix |
|---|---|
| Connection refused | DroidProxy isn't running — tell the user to launch it |
| `auth_not_found` / no auth for `codex` | Codex not connected, or the account is Free. Settings → Connect Codex. Image gen requires Plus/Pro. |
| `usage_limit_reached` (`plan_type`, `resets_in_seconds`) | Quota exhausted. Tell the user when it resets. Do not retry in a loop. |
| 401 after a long idle | OAuth session dead — Settings → Connect Codex |
| 400 unsupported model | Use `gpt-image-2.5-flare` or `gpt-image-2.5-sunburst`; no other model is supported. |
| `jq: Argument list too long` | You put a data URL in `jq --arg`. Use `--rawfile` as in Edit. |
| Response `size`/`quality` ≠ request | Not a failure. Save the image. Do not retry. |

On `moderation_blocked`, stop. Don't retry and don't paraphrase the prompt
to evade the filter. Report the API's own message. Never invent image
content or a URL for a request that failed.

## Sources

- [GPT Image 2.5 prompting guide](https://developers.openai.com/api/docs/guides/image-prompting)
- [Image generation guide](https://developers.openai.com/api/docs/guides/image-generation)
