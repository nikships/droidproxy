# Request journal v1

The schema defines records, not the wrappers in the golden and transcript files.
Every top-level key is required. Unknown values are explicit `null`; only the
four optional seat identity keys are omitted. Extra keys are invalid at every
record object level. `v` is exactly 1. No prompts, response text, credential
contents, or unrelated headers belong in a journal record.

## Admission and paths

When enabled (off by default), observe one record per POST forwarded to
CLIProxyAPI on :8318 whose path is in the following list. Strip the query before
matching; do not prefix-match arbitrary paths or treat `/api/v1` as `/v1`.
An admitted dial/send failure still produces an observation.

| Paths | Family |
| --- | --- |
| `/v1/messages` | Anthropic |
| `/v1/chat/completions`, `/v1/completions` | OpenAI completions |
| `/v1/responses`, `/backend-api/codex/responses` | Responses |
| `/v1/responses/compact`, `/backend-api/codex/responses/compact` | Responses compact |
| `/v1/alpha/search`, `/backend-api/codex/alpha/search` | Codex search |
| `/v1/images/generations`, `/v1/images/edits` | Images |
| `/v1/videos`, `/v1/videos/generations`, `/v1/videos/edits`, `/v1/videos/extensions`, `/openai/v1/videos` | Videos |
| `/v1/audio/speech`, `/v1/tts` | Speech |
| `/v1/live`, `/v1/realtime`, `/v1/realtime/calls`, `/v1/realtime/translations` | HTTP live/realtime entry points |
| `/v1beta/interactions` | Gemini interactions |
| `/v1beta/models/{model}:generateContent`, `/v1beta/models/{model}:streamGenerateContent` | Native Gemini; `{model}` is one nonempty model identifier |

Source: pinned **v8.0.61**,
[`internal/api/server_routes.go`, `setupRoutes`, lines 45–157](https://github.com/router-for-me/CLIProxyAPI/blob/v8.0.61/internal/api/server_routes.go#L45-L157);
native Gemini actions are dispatched by
[`sdk/api/handlers/gemini/gemini_handlers.go`, `GeminiHandler`](https://github.com/router-for-me/CLIProxyAPI/blob/v8.0.61/sdk/api/handlers/gemini/gemini_handlers.go).
This list includes inference beyond the three text formats; v1 leaves their
unsupported usage null. A live/realtime record covers only that HTTP exchange,
not a later media session or its cost.

Exclude all non-POSTs (including Responses WebSockets), model lists, management,
health, OAuth callbacks, realtime secret/session provisioning and SIP controls,
`/v1/messages/count_tokens`, and native Gemini `:countTokens`. Exclude requests
that bypass :8318: Grok, Meta Responses, Junie, and the Copilot gateway. A model
on a listed path is not sufficient if its actual route bypasses CLIProxyAPI.

`endpoint` is the client's original path; `forwarded_endpoint` is null unless
the forwarded path differs. For example, `/v1/responses?x=1` with
`gemini-3.1-pro-preview` becomes endpoint `/v1/responses`, forwarded endpoint
`/v1/chat/completions`. Preserve the original model before alias rewrites.
`requested_model` is null when missing, non-string, or not observable; for a
native Gemini URL use its model identifier. Do not invent a model for an
agent-only interactions request or an unparsed multipart body.

### Provider derivation

This is a request-family label, not the credential's provider or billing owner.
Apply these rules in order to the original model/path (case-sensitive):

1. `claude-*`, `gemini-claude-*`, and the relay's `ag-c55s-high`,
   `ag-c55o-high`, `ag-c46s-thinking`, `ag-c46o-thinking` aliases: `claude`.
2. `gemini-*` or a native `/v1beta` inference path: `gemini`.
3. `gpt-*`, `codex-*`, or a `/backend-api/codex/` inference path or
   `/v1/alpha/search`: `codex`.
4. `/v1/messages`: `claude`. Other listed `/v1/` or `/openai/v1/` paths: `openai`.
5. Otherwise: `unknown`.

Thus a custom alias on `/v1/responses` is `openai`, even if CLIProxyAPI later
uses a Codex seat. Unknown seat metadata does not change this label.

## Sessions and origin

Choose the first valid string, in order:
`X-Session-ID`, `X-Claude-Code-Session-Id`, body `prompt_cache_key`, then the
session id in string body `metadata.user_id` (forms below).
Header names are case-insensitive; repeated values are tried in wire order.
Remove HTTP header surrounding SP/HTAB only; body values are not trimmed.
Accept only `^[A-Za-z0-9_.:-]{8,128}$`. Skip malformed candidates and continue;
never truncate, hash, lowercase, or add an affinity namespace. No valid
candidate means null. Do not store the rest of `metadata.user_id`.

`metadata.user_id` is a single candidate slot with two forms, chosen by its first
byte. If the string starts with `{`, it is the JSON form: parse it as a JSON
object and take its string member `session_id`. Malformed JSON, a non-object, a
missing or non-string `session_id`, or an id failing the grammar yields no
candidate from metadata, so the result is null when no earlier source matched.
A string starting with `{` is never also read as a legacy suffix. Any other
string is the legacy form: the suffix after the final `_session_`.

Known legacy Claude Code shape (source fixture, not a live client capture):
`user_123_acc__session_01a06a06-e830-7da9-a866-98470a94389c` yields
`01a06a06-e830-7da9-a866-98470a94389c`.
Source:
[`sdk/cliproxy/session/info_test.go`, `TestExtractSessionInfoEnhancedHarnesses`](https://github.com/router-for-me/CLIProxyAPI/blob/v8.0.61/sdk/cliproxy/session/info_test.go).
No real `metadata.user_id` value was captured for these fixtures. Droid sends its
session UUID as `prompt_cache_key` on `/v1/responses`, for example
`{"prompt_cache_key":"11111111-2222-4333-8444-555555555555"}` (illustrative, not
a capture). Droid sends no session id on `/v1/messages`. Do not infer a session
from request content or time.

The JSON form is JSON encoded *inside the user_id string*, e.g.
`{"metadata":{"user_id":"{\"session_id\":\"json-session-0001\"}"}}` yields
`json-session-0001`. CLIProxyAPI treats it as current metadata: when `user_id`
starts with `{` it parses the string and reads `session_id`
([`sdk/cliproxy/session/identity.go`, `ClaudeMetadataIdentities`, lines 146–193](https://github.com/router-for-me/CLIProxyAPI/blob/v8.0.61/sdk/cliproxy/session/identity.go#L146-L193);
the JSON branch is lines 161–176, and the legacy `_session_([a-f0-9-]+)$` branch
starts at line 177). The journal reads both forms at the same precedence. It reads
only `session_id`: it does not read the
`parent_session_id`, `parent_agent_id`, `parent_id`, `agent_id`, or `subagent_id`
members, and takes no `request.metadata.user_id` envelope fallback. This journal key is therefore an
explicit client session key used for affinity, not CLIProxyAPI's full canonical
affinity identity, agent hierarchy, or derived UUID. The journal grammar is
stricter than CLIProxyAPI's `NormalizeExplicitID` (no trimming, 8–128 characters,
limited alphabet), so an id CLIProxyAPI accepts may be null here.

`X-DroidProxy-Origin: window-primer` sets origin `primer`; otherwise `client`.
Strip this internal marker before forwarding. It does not exclude the request.

## Response observation and usage

Never alter relayed bytes. For observed requests only, remove `Accept-Encoding`
on the :8317 → :8318 hop; do not change bundled compression settings. Decode HTTP
chunk framing before scanning the entity body. Ignore interim 1xx heads and use
the final status. Header names are case-insensitive. Compressed bodies remain
opaque if received anyway: tokens and response_model are null, not zero.
Observation caps (head 64 KiB, SSE line 256 KiB, JSON body 2 MiB) never stop the
relay; unobserved usage stays null.

Use only nonnegative integral counters. A missing usage object, malformed
required counter, or negative value makes the whole `tokens` value null. For
OpenAI shapes only, a cached count greater than the input total also makes
`tokens` null: Responses `input_tokens` and chat/completions `prompt_tokens`
include cached tokens, so a larger cached count is malformed. This rule does not
apply to Anthropic: its `input_tokens` already excludes cache reads and
creations, so `cache_read_input_tokens` may exceed it and the usage is valid. A
present zero counter is known zero.

| Format | Terminal usage |
| --- | --- |
| Anthropic SSE | Merge `message_start.message.usage` with `message_delta.usage` by field; later values replace, never sum. Require a message_delta usage with final output. Input/cache fields may come from message_start; a start alone is not terminal usage. `message_stop` is the stream terminator. |
| Responses SSE | Use `response.usage` only in `response.completed` or `response.incomplete`, both terminal. Incomplete is a completed protocol exchange, not premature EOF. Never use a partial response.created usage. |
| Chat/text completions SSE | Use the final chunk's non-null `usage` before `[DONE]`, including usage on a finish_reason chunk or an empty-choices usage chunk. Do not treat finish_reason alone as stream end; `[DONE]` is terminal. Without usage, tokens are null. |
| Non-stream JSON | Only a fully framed, decoded response object's `usage`; Anthropic and OpenAI shapes as below. Missing usage means null. |
| Other formats | v1 does not normalize native Gemini, interactions, media, search, compact-specific, or live-session usage. Tokens stay null unless the body actually has a supported terminal text-format usage shape. |

Anthropic: `input_uncached = input_tokens`, `cache_read =
cache_read_input_tokens`, `cache_creation = cache_creation_input_tokens`,
`output = output_tokens`, `reasoning = null`. Missing Anthropic cache counters
in otherwise valid terminal usage mean zero (non-cached protocol variant).
Responses: subtract `input_tokens_details.cached_tokens` from `input_tokens`;
chat/completions: subtract `prompt_tokens_details.cached_tokens` from
`prompt_tokens`. Missing OpenAI cached detail means zero. Output is respectively
`output_tokens` or `completion_tokens`; reasoning comes from the corresponding
output/completion details or is null. Responses cache_creation is always null,
even if an extension reports cache_write_tokens. Chat cache_creation is null
unless explicit prompt details report `cache_write_tokens` (or, if absent,
`cached_creation_tokens`); never derive it from the input total. Do not sum
reasoning into output or add cache_creation to OpenAI input totals.

Retain terminal usage already observed even if the later exit is a failed
client write or truncated transport. Before terminal usage it is null.
`response_model` is the last explicit nonempty response model, not the requested
model by default; it can be known even when tokens are not.

## Termination, status, and clocks

Finalize exactly once. `status` is the final status line observed from :8318,
not a guessed client-delivered status. The one exception is the proxy's own
dial-failure 502. A failed client write does not erase an observed status.

| Relay exit | outcome | status |
| --- | --- | --- |
| Backend dial failure | backend_unreachable | 502 |
| Upstream request send failure | upstream_error | null (no response head read) |
| Upstream read error, timeout, malformed HTTP framing, or explicit protocol error event before completion | upstream_error | observed final status, else null |
| Framing complete: protocol terminal event, Content-Length reached, or complete chunked terminator/trailers | complete | observed final status |
| Upstream EOF before framing end, including empty connection/partial head | upstream_closed_early | observed final status, else null |
| EOF ending a legal close-delimited non-stream body | complete | observed final status |
| Failed client response write | client_disconnected | observed final status, else null |
| Cancellation without failed client write and before completion | upstream_error | observed final status, else null |

First finalizer wins. A failed write of the bytes that would have completed
framing is client_disconnected, not complete. No separate disconnect monitor
exists. A clean HTTP chunk end without an SSE terminal event is complete, since
framing ended, but has tokens null if no terminal usage arrived.
Conversely a terminal SSE event can complete before the HTTP connection closes.
`complete` describes delivery/framing, not HTTP success: a fully delivered 429
JSON error is complete with status 429, last_tried seat, and tokens null.

Start at the forwarding attempt (before dialing); end at finalization.
Latency and ttft use monotonic elapsed time, floored to integer milliseconds;
ttft is null until the first entity-body byte, not a header or chunk-size byte.
It is no greater than latency. Timestamps use wall-clock UTC with exactly three
fractional digits and Z:
`^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$`.
Wall-clock adjustment can differ from monotonic latency; do not reconstruct
latency by subtracting serialized timestamps.

## Trace and seat

Split `X-CPA-TRACE-ID` with at most three parts:
`YYYYMMDDHHMMSS-<16 lowercase hex auth_index>-<request UUID>`.
Preserve the raw header as trace_id; execution_id is its request UUID (normally
UUIDv7). Without a usable UUID mint UUIDv4. Without a fully usable trace/index,
seat is null; never recover a seat from the model or current account selection.
The UUID and index must match the header, a semantic rule beyond this schema.
Fixed redacted fixture traces are syntactically valid, not real account traces.

For a usable index, seat contains auth_index and role even when unresolved.
Role is served for 2xx, last_tried otherwise; the schema enforces both directions
with if/then/else, including rejecting served + 429. Neither a 2xx nor role served
alone proves spend. Do not use last_tried for spend.

Build the index map from auth-directory entries:
`hex(sha256(lower(type) + ":" + clean_absolute_path)[:8])`.
Refresh on auth-dir watcher events and on a miss at most once per second.
On every hit stat and compare size, mtime, and inode where available; re-read
identity fields on change before binding. At finalization revalidate against
the fingerprint bound for this request: a replacement, disappearance, duplicate
index, ambiguity, or unreadable identity leaves only `{auth_index, role}`.
Do not attach a replacement file's current metadata to an earlier request.
Read only identity fields for binding: type, email, organization_uuid/nested
organization, Codex top-level account_id, and basename. Unknown identity fields
are omitted, not null. No management key or usage-queue consumer is needed.

## Persistence and fixtures

Append one UTF-8 JSON object with no trailing spaces and one LF to
`~/.droidproxy/journal/requests-YYYY-MM.jsonl`, using the UTC month of started_at.
Directory mode 0700, file mode 0600; create no-follow and verify owner and regular
file. A bounded process-local queue must not block the relay. Each append takes
an advisory exclusive lock, repairs an incomplete trailing line, retries short
writes, fsyncs the file, and fsyncs the directory on month-file creation.
Successful fsynced appends are durable; overflow/crash before append can lose
records. Count drops/write errors and log failures without failing the relay.

Golden lines wrap `{name, valid, reason?, record}`. Invalid cases isolate schema
violations, not unprovable provenance: a schema cannot distinguish invented
zero usage from observed zero usage.

Transcripts contain raw response bytes represented as Latin-1 JSON strings:
map each Unicode code point 0–255 back to one byte, NOT UTF-8 (gzip case).
HTTP lines use explicit CRLF; captured SSE body lines legitimately use LF.
Replay every split point and one byte at a time, preserving the result.
Each case supplies content-free request context, synthetic seat identities,
clock observations, end signal, and a full expected record. The `request` object
holds `method`, `endpoint`, `headers` (only those that affect the record, as a
name-to-value map) and `body` (only the fields that do, such as `model`,
`prompt_cache_key`, and `metadata.user_id`). Session and usage-validation cases
include the metadata JSON form, header precedence, malformed JSON, a grammar
failure, and OpenAI cached-over-input (`tokens` null) beside the Anthropic
cache-read-over-input case (valid). Clock values are
fixture inputs, not measured capture timings. For the missing-trace case only,
the expected execution_id is a representative UUIDv4: compare UUIDv4 validity,
not that literal value; no test-only production UUID hook is required.

Six source captures were made through a local macOS DroidProxy on :8317 (bundled
CLIProxyAPI v8.0.66), 2026-11-11, with identity
encoding and tiny "Reply with OK" prompts. Captures redact trace values and the
provider's stable safety_identifier to fixed placeholders. Fixture seat email,
org and account IDs are wholly synthetic. Both chat captures returned usage,
even without include_usage; the actually usage-free case is explicitly derived.
Derived fixtures also cover incomplete Responses, cache subtraction, Anthropic
merge-only usage, 429, missing trace, truncation, gzip, and chunk boundaries.
Their provenance is recorded per case; they are not claimed as real captures.

### Limits in v1

- Non-text inference routes are admitted, but their usage is null.
- The relay recognizes `/api/v1/responses`, but CLIProxyAPI v8.0.61 does not
  serve that path, so it is not admitted.
- `complete` means the response framing ended. HTTP errors that were fully
  delivered are complete; status and seat role carry the failure.
- CLIProxyAPI's parent and agent identities, canonical-UUID projection, and
  affinity normalization are not adopted; only `session_id` from the JSON or
  suffix form of `metadata.user_id` is read.
