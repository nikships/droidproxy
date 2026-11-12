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

Request bodies are parsed as strict RFC 8259 JSON, as defined under JSON below:
valid UTF-8, with no trailing commas, comments, `NaN`, or other extensions. A
body that is not strict JSON, including one whose only fault is invalid UTF-8
in a member the journal does not read, gives requested_model null and no
body-based session candidates; the request is still observed and forwarded
unchanged.

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
Body candidates exist only when the request body is strict JSON.
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

## Response observation

Never alter relayed bytes. For observed requests only, remove `Accept-Encoding`
on the :8317 → :8318 hop; do not change bundled compression settings. Ignore
interim 1xx heads and use the final status. Header names are case-insensitive.
Observation caps (head 64 KiB, SSE line 2 MiB, SSE event data 2 MiB,
non-stream JSON body 2 MiB) never stop the relay; usage that is not observed
stays null.

### HTTP framing

The observer accepts only this framing:

- The status line is `HTTP/1.0` or `HTTP/1.1`, a space, and a three-digit
  status code from 100 through 599, followed either directly by CRLF or by a
  space, any reason text (possibly empty), and CRLF. `HTTP/1.1 200`,
  `HTTP/1.1 200 ` and `HTTP/1.1 200 OK` are valid; `HTTP/1.1 20`,
  `HTTP/2 200 OK`, `HTTP/1.1 200OK`, and `HTTP/1.1 999 Custom` are malformed.
- Every header line and every trailer line ends in CRLF, contains a colon, and
  has a nonempty token as the name before the colon.
- A bare LF anywhere in the head or the trailers, including at the end of the
  status line, is a violation.
- A chunk-size line is one or more hex digits, optionally followed by `;` and a
  chunk extension, then CRLF. Any other byte before the extension or the CRLF,
  including a space or tab, is a violation, and so is a bare LF ending the line.
- A chunk-size line, including its extension and its CRLF, must fit within
  65,536 bytes, however the bytes were split across reads; a longer line is a
  violation. Within that length the only restriction on the size is that its
  value fits a signed 64-bit integer (at most 9223372036854775807): leading
  zeros are allowed and the number of digits is not limited.
- Each trailer line, including its CRLF, must also fit within 65,536 bytes,
  however the bytes were split across reads; a longer line is a violation.
- The line ending after each chunk's data is CRLF.

Any violation is malformed framing. The record's outcome is `upstream_error`
whichever exit finalizes it, `status` is the final status as observed, and
`tokens` is null.

The final status is retained as soon as its status line is complete (ends in
CRLF) and valid, even if the rest of the head never arrives. A malformed status
line, including one whose code is outside 100 through 599, retains no status, so
`status` is null.

The final head, including the blank line that terminates it, must fit within
its first 65,536 bytes (64 KiB), counted from its first byte, however the bytes
were split across reads. Once 65,536 bytes of the final head have been observed
without its terminator, the head is over the cap at that moment, including when
the response ends there. Observation of that response then stops: the outcome
is `upstream_error`, `status` comes from the status line if one was observed,
`tokens`, `response_model`, and `ttft_ms` are null, and no framing completion
is inferred.
The relay keeps relaying the response.

`Transfer-Encoding` is a comma-separated list of codings. Chunk framing applies
when the last coding is `chunked` (case-insensitive) and is decoded before the
entity body is scanned. If any other transfer coding is listed, the entity is
opaque: `tokens` and `response_model` are null, but framing is still tracked, so
such a response can still be complete. A `Content-Encoding` other than
`identity` also makes the entity opaque. Opaque usage is null, not zero.

EOF ends a close-delimited body. For a non-stream body that is framing
completion and the outcome is complete. For an SSE body it is not: the outcome
is complete only if protocol completion was delivered first, otherwise
`upstream_closed_early`; terminal usage already published is kept.

### JSON

Request and response JSON is parsed as strict RFC 8259 JSON: no trailing commas,
comments, `NaN`, or other extensions. Strict JSON is also valid UTF-8 (RFC 8259
section 8.1). A byte sequence that is not valid UTF-8, including an overlong
encoding or an encoded surrogate (U+D800 through U+DFFF), anywhere in a request
body, response body, SSE payload, or seat credential file makes that whole text
not strict JSON, whether or not the bytes are in a member the journal reads.
Invalid bytes are not replaced with U+FFFD. A response body or SSE payload that
is not strict JSON contributes no usage, no response model, and no
payload-based protocol error; for a non-stream body this means `tokens` is
null. Requests are covered under Admission and paths. For repeated member names
in any JSON object, only the last occurrence counts. A value nested more than
512 arrays and objects deep is not strict JSON and has the same effect as a
parse failure; the outermost array or object is depth 1, and depth 512 is
accepted. Forwarded bytes are never changed.

### SSE

SSE lines are capped at 2 MiB and an assembled event's data at 2 MiB. Line
limits count bytes before the line terminator, including the field name and
colon but excluding CR and LF. Event-data limits count the assembled data bytes,
including the LF inserted between data lines and excluding the final LF removed
for dispatch. Because a line counts its field name and colon, an event with one
data line reaches the line limit first; only an event of several data lines can
exceed the event-data limit. Exceeding either limit discards the whole current
event; scanning resumes after the next blank line that delimits events. HTTP
framing is tracked throughout.

Protocol completion is a strict-JSON payload whose `type` is `message_stop`,
`response.completed`, or `response.incomplete`, or assembled data exactly equal
to `[DONE]`. An `event:` name alone does not establish completion.

A protocol error is exactly one of:

- an SSE event whose `event:` field is `error`;
- an SSE payload whose `type` is `error`, `response.failed`, or
  `response.error`;
- an SSE payload with no `type` member and a non-null top-level `error`.

Nothing else is a protocol error. In particular, a non-stream JSON error body,
such as a 429 response, is not one.

### Response model

`response_model` comes from observed SSE payloads and non-stream JSON bodies.
Within each payload, consider top-level `model`, `message.model`, and
`response.model` in that order, keeping each nonempty string; the last
qualifying location wins. Later observed payloads replace earlier ones. It is
not the requested model by default, and it can be known even when `tokens` is
not.

## Usage

A counter must be a JSON integer literal (no fraction and no exponent) from 0
to 9223372036854775807. A negative, fractional, exponent-form, or out-of-range
counter is malformed; `1.0` and `1e3` are malformed even though their values are
whole numbers.

The required counters are Anthropic `input_tokens` and `output_tokens`,
Responses `input_tokens` and `output_tokens`, and chat/text completions
`prompt_tokens` and `completion_tokens`. A missing usage object, or a required
counter that is missing, null, or malformed, makes the whole `tokens` value
null. Optional counters and optional details objects (Anthropic
`cache_read_input_tokens` and `cache_creation_input_tokens`; OpenAI
`input_tokens_details`, `prompt_tokens_details`, `cached_tokens`,
`output_tokens_details`, `completion_tokens_details`, `reasoning_tokens`,
`cache_write_tokens`, and `cached_creation_tokens`) that are absent or null are
treated as absent, and the defaults below apply. A present, non-null, malformed
optional value makes `tokens` null. A present zero counter is known zero.

For OpenAI shapes only, a cached count greater than the input total also makes
`tokens` null: Responses `input_tokens` and chat/completions `prompt_tokens`
include cached tokens, so a larger cached count is malformed. This rule does not
apply to Anthropic: its `input_tokens` already excludes cache reads and
creations, so `cache_read_input_tokens` may exceed it and the usage is valid.

SSE usage is read only from terminal usage of the family of the path forwarded
to CLIProxyAPI (the original path unless it was rewritten, query stripped).
`/v1/messages` takes Anthropic SSE only. `/v1/chat/completions` and
`/v1/completions` take chat/text completions SSE only. `/v1/responses`,
`/backend-api/codex/responses`, `/v1/responses/compact`, and
`/backend-api/codex/responses/compact` take Responses SSE only. Terminal usage
of another family gives tokens null, and so does SSE usage on every other
admitted path. The family does not affect outcome, completion, protocol errors,
or `response_model`.

| Format | Terminal usage |
| --- | --- |
| Anthropic SSE | Usage objects from `message_start.message.usage` and from every `message_delta.usage` merge field by field; later values replace earlier ones and are never summed. Terminal usage exists once any message_delta has carried `output_tokens`. After that it is re-normalized on every later usage update, and the record keeps the latest merged state. A message_start alone is not terminal usage. `message_stop` is the stream terminator. |
| Responses SSE | Use `response.usage` only in `response.completed` or `response.incomplete`, both terminal. Incomplete is a completed protocol exchange, not premature EOF. Never use a partial response.created usage. |
| Chat/text completions SSE | A chunk with non-null `usage` that also has a `finish_reason`, or has an empty `choices` array, publishes terminal usage immediately; a later chunk with non-null `usage` replaces it. A finish reason qualifies only when at least one choices entry has a non-null string `finish_reason`; a present null does not qualify. `[DONE]` or HTTP framing completion (not EOF of a close-delimited SSE body) is still required for outcome complete, and terminal usage already published is kept if the stream is later truncated. finish_reason alone does not end the stream. Without usage, tokens are null. |
| Non-stream JSON | Usage is read only from a fully framed, decoded body whose envelope matches the family of the path forwarded to CLIProxyAPI (the original path unless it was rewritten): Anthropic `type: "message"`; Responses `object: "response"`; chat completions `object: "chat.completion"`; text completions `object: "text_completion"`. Any other body gives tokens null; `response_model` is still read from it. A recognized envelope without usage also gives null. |
| Other formats | v1 does not normalize native Gemini, interactions, media, search, or live-session usage. Their non-stream bodies have no recognized envelope and their SSE usage is not read, so tokens are null even when a stream carries one of the shapes above. A compact non-stream body has no recognized envelope either, so its tokens are null. |

Anthropic: `input_uncached = input_tokens`, `cache_read =
cache_read_input_tokens`, `cache_creation = cache_creation_input_tokens`,
`output = output_tokens`, `reasoning = null`. Absent or null Anthropic cache
counters in otherwise valid terminal usage mean zero (non-cached protocol
variant).
Responses: subtract `input_tokens_details.cached_tokens` from `input_tokens`;
chat/completions: subtract `prompt_tokens_details.cached_tokens` from
`prompt_tokens`. An absent or null OpenAI cached detail means zero. Output is
respectively `output_tokens` or `completion_tokens`; reasoning comes from the
corresponding output/completion details or is null. Responses cache_creation is
always null, even if an extension reports cache_write_tokens. Chat
cache_creation is null unless explicit prompt details report
`cache_write_tokens`; an absent or null `cache_write_tokens` permits using
`cached_creation_tokens`. Never derive it from the input total. Do not sum
reasoning into output or add cache_creation to OpenAI input totals.

Usage, `response_model`, `ttft_ms`, and completion come only from bytes
delivered to the client (see below). Terminal usage already observed is kept
even if the later exit is a failed client write or truncated transport. Before
terminal usage, tokens is null.

## Termination, status, and clocks

Finalize exactly once, at the earliest of:

1. a successful client write after which the observation has reached protocol
   completion (defined under SSE), HTTP framing completion, or a protocol
   error;
2. a relay exit in the table below.

`ended_at` and `latency_ms` are taken at that moment. Bytes relayed after
finalization are not observed; the relay keeps relaying them unchanged.

Process accepted bytes in wire order. Within a successful write, observation
stops at the first delivered protocol completion, protocol error, or HTTP
framing completion, even when the same write accepted more bytes; finalize at
that write's completion time. Bytes after that point contribute nothing to the
record.

`status` is the final status line observed from :8318, not a guessed
client-delivered status. The one exception is the proxy's own dial-failure 502.
A failed client write does not erase an observed status.

A byte is delivered once a client write has accepted it. When a write reports a
positive accepted byte count together with an error, the accepted prefix is
delivered and the rest of its buffer is undelivered. Undelivered bytes may be
used only to learn the final status line and the `X-CPA-TRACE-ID` header while
the response head is still incomplete; they never contribute usage,
`response_model`, `ttft_ms`, or completion. A failed write gives
`client_disconnected`, even if its undelivered bytes would have completed
framing, unless the observation had already finalized.

| Finalizing event | outcome | status |
| --- | --- | --- |
| Backend dial failure | backend_unreachable | 502 |
| Upstream request send failure | upstream_error | null (no response head read) |
| Upstream read error or timeout before completion | upstream_error | observed final status, else null |
| Delivered protocol error before completion | upstream_error | observed final status |
| Delivered protocol completion, or framing completion: Content-Length reached, or complete chunked terminator/trailers | complete | observed final status |
| Upstream EOF before framing end, including empty connection/partial head | upstream_closed_early | observed final status, else null |
| EOF ending a legal close-delimited non-stream body | complete | observed final status |
| EOF ending a close-delimited SSE body before delivered protocol completion | upstream_closed_early | observed final status |
| Failed client response write | client_disconnected | observed final status, else null |
| Cancellation without failed client write and before completion | upstream_error | observed final status, else null |

Malformed framing and an over-cap head make the outcome `upstream_error`
whichever row finalizes the record. No separate disconnect monitor exists. A
clean HTTP chunk end without an SSE terminal event is complete, since framing
ended, but has tokens null if no terminal usage arrived. Conversely a terminal
SSE event can complete before the HTTP connection closes. `complete` describes
delivery/framing, not HTTP success: a fully delivered 429 JSON error is complete
with status 429, last_tried seat, and tokens null.

Start at the forwarding attempt (before dialing); end at finalization.
Latency and ttft use monotonic elapsed time, floored to integer milliseconds.
ttft is taken when the upstream read containing the first entity-body byte
returns (not a header or chunk-size byte) and counts only once that byte is
delivered; until then it is null. It is no greater than latency. Timestamps use
wall-clock UTC with exactly three fractional digits and Z:
`^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$`.
Wall-clock adjustment can differ from monotonic latency; do not reconstruct
latency by subtracting serialized timestamps.

## Trace and seat

Split `X-CPA-TRACE-ID` with at most three parts:
`YYYYMMDDHHMMSS-<16 lowercase hex auth_index>-<request UUID>`.
Only the first `X-CPA-TRACE-ID` header line in the final head counts, whatever
its value; later ones are ignored. trace_id, execution_id, and seat come from
that header alone; later headers cannot repair or replace any of them. An empty
first header gives a minted execution_id and a null seat. A nonempty first
header with an invalid timestamp or auth_index still supplies execution_id when
its third segment alone is a valid UUID, but gives a null seat. A first header
whose value is empty after removing surrounding SP/HTAB still counts as the
first header but gives trace_id null. Otherwise preserve the raw header as
trace_id. execution_id is the third segment whenever that segment alone is a
valid UUID (per the schema's `uuid` definition; normally UUIDv7), whatever the
other segments contain; otherwise mint a UUIDv4. The seat
needs the whole trace to be valid: a 14-digit timestamp, a 16-character
lowercase hex index, and a valid UUID. Without a valid trace, seat is null; never
recover a seat from the model or current account selection. The UUID and index
must match the header, a semantic rule beyond this schema. Fixed redacted
fixture traces are syntactically valid, not real account traces.

For a valid trace, seat contains auth_index and role even when unresolved.
Role is served for 2xx, last_tried otherwise; the schema enforces both directions
with if/then/else, including rejecting served + 429. Neither a 2xx nor role served
alone proves spend. Do not use last_tried for spend.

The seat index covers only entries directly in `~/.cli-proxy-api` whose names
end in `.json` (case-sensitive). Each indexed entry's index is
`hex(sha256(lower(type) + ":" + clean_absolute_path)[:8])`. Regular files and
symlinks are indexed; a symlink's `type` is read through the link. Other
non-regular entries (FIFOs, sockets, devices) are not indexed. A credential file
larger than 1 MiB (1,048,576 bytes) is not read, so it supplies no `type` and is
not indexed. A credential file that is not strict JSON (see JSON), including one
with invalid UTF-8 only in a member the journal does not read, also supplies no
`type` and is not indexed. Only regular files owned by the running user can be
bound to a request. Symlinks and files not owned by the running user are
indexed, so a trace that names them still finds its entry, but they are never
bound. A valid trace whose index has no bindable entry, including one with no
entry at all, yields a seat of `{auth_index, role}` only. A basename that fails
the schema's `file` pattern is omitted from the seat.

Refresh on auth-dir watcher events and on a miss at most once per second.
On every hit stat and compare size, mtime, and inode where available; re-read
identity fields on change before binding. Identity reading decodes only these
members of a credential file: `type`, `email`, `organization_uuid` or the
nested organization uuid, and the Codex top-level `account_id`. No other member
is materialized. For Claude organization identity, use a nonempty string
`organization_uuid`; otherwise a nonempty string `organization.uuid`. Omit `org`
when neither qualifies. The basename comes from the directory entry. Unknown
identity fields are omitted, not null. No management key or usage-queue consumer
is needed.

After finalization and before the record is written, off the relay, the
binding is revalidated: the file must have the same fingerprint that was bound
for this request, must still be readable, and its auth_index must still be
unique in the current map. Any failure, including a
replacement, disappearance, or duplicate index, leaves only
`{auth_index, role}`. Do not attach a replacement file's current metadata to an
earlier request.

## Persistence and fixtures

Append one UTF-8 JSON object with no trailing spaces and one LF to
`~/.droidproxy/journal/requests-YYYY-MM.jsonl`, using the UTC month of started_at.
Directory mode 0700, file mode 0600; create no-follow and verify owner and regular
file. Each append takes an advisory exclusive lock, repairs an incomplete
trailing line, retries short writes, fsyncs the file, and fsyncs the directory on
month-file creation. Successful fsynced appends are durable; overflow/crash
before append can lose records.

Response observation (HTTP framing, SSE scanning, and decoding a completed JSON
payload) runs inline on the relay as bounded CPU work, linear in the size of the
observed payload, with no I/O, locks, or waits. All other journal work runs off
the relay: request body parsing, seat work, file I/O, and file locks. A
finalized record is handed to a bounded process-local queue that never blocks
the relay. Process shutdown may wait only until a bounded flush deadline;
records remaining after it are counted as dropped. Lock acquisition gives up
after a short bounded wait and counts the record as dropped. Drop and write-error
diagnostics are aggregated and emitted without blocking the relay, and never
fail it. Emitting them, including at shutdown, never holds a flush or close past
its deadline.

Golden lines wrap `{name, valid, reason?, record}`. Invalid cases isolate schema
violations, not unprovable provenance: a schema cannot distinguish invented
zero usage from observed zero usage.

Transcripts contain raw response bytes represented as Latin-1 JSON strings:
map each Unicode code point 0–255 back to one byte, NOT UTF-8 (gzip cases).
HTTP lines use explicit CRLF unless a case tests a framing violation; captured
SSE body lines legitimately use LF. Each case supplies content-free request
context, synthetic seat identities, clock observations, an end signal, and a
full expected record.

- `request` holds `method`, `endpoint`, `headers` (only those that affect the
  record, as a name-to-value map), and exactly one of `body` or `body_raw`.
  `body` is a JSON object with only the fields that affect the record, such as
  `model`, `prompt_cache_key`, and `metadata.user_id`; send it serialized as
  JSON. `body_raw` is the exact request body text, for bodies that are not
  strict JSON or repeat a member; send it as its UTF-8 bytes with nothing
  added. The request is forwarded on `endpoint` unless the expected record's
  `forwarded_endpoint` is not null, in which case it is forwarded on that path.
- `observation` gives the clock. Elapsed time 0 is `started_at`. Every upstream
  read returns at `first_body_elapsed_ms`. Every client write completes at the
  elapsed time of `ended_at`. The end signal arrives at `end_signal_elapsed_ms`
  when present, otherwise at the elapsed time of `ended_at`; a later end signal
  shows that latency was taken at an earlier write. Fixture clocks have no
  wall-clock adjustment: a write's elapsed time is `ended_at - started_at`.
  Clock values are fixture inputs, not measured capture timings.
- `end_signal` is `eof` (upstream EOF after the last response byte) or
  `client_write_failed`. With `client_write_failed`, `client_write_fails_at` is
  a byte offset after the response head. Failure offsets are zero-based
  absolute response-wire byte offsets, including the response head and
  transfer framing. The write whose buffer contains that offset, or starts at
  it, accepts only the bytes before the offset and reports an error; nothing
  after that buffer is read, and the relay exits with the failed client write.
- `body_read_error` marks a response whose body ends early (truncated
  transport).
- `nonstandard_wire`, when present, explains why the bytes are deliberately not
  a complete, generally parseable HTTP/1.1 response (a framing violation, a head
  cut short, or a transfer coding generic clients reject). The fixture
  structure check does not parse these as HTTP.
- `nondeterministic_fields` lists fields the expected record cannot fix. Only
  `execution_id` may appear: the expected value is a representative UUIDv4, so
  compare UUIDv4 validity, not that literal value; no test-only production UUID
  hook is required.

Replay every split point and one byte at a time, preserving the result. A
split at k supplies exactly two upstream reads, bytes [0,k) and [k,N), where N
is the response length. Whole replay supplies one read; bytewise replay
supplies one byte per read. Each read is followed by one client write of that
buffer before the next read. For responses over 64 KiB, two-read splits may be
limited to k = 509, 1018, … below N, plus whole and bytewise replay.

Session and usage-validation cases include the metadata JSON form, header
precedence, malformed JSON, a grammar failure, and OpenAI cached-over-input
(`tokens` null) beside the Anthropic cache-read-over-input case (valid).

Six source captures were made through a local macOS DroidProxy on :8317 (bundled
CLIProxyAPI v8.0.66), 2026-11-11, with identity
encoding and tiny "Reply with OK" prompts. Captures redact trace values and the
provider's stable safety_identifier to fixed placeholders. Fixture seat email,
org and account IDs are wholly synthetic. Both chat captures returned usage,
even without include_usage; the actually usage-free case is explicitly derived.
Derived fixtures also cover incomplete Responses, cache subtraction, Anthropic
merge-only and later cache-only usage, a message_delta model, 429, missing and
malformed traces, truncation, gzip content and transfer codings, chunk
boundaries, framing violations (bare LF in status, header, and trailer lines,
trailer lines without a colon, and padded chunk-size lines), chunk-size lines
at and one byte over the line limit, chunk sizes at and one over the int64
maximum, repeated trace headers, JSON nested at and one over the depth limit,
the head cap (including a head that reaches the cap without its terminator and
then ends), protocol errors, null optional and extreme or fractional counters,
unrecognized envelopes, non-strict request and response JSON, invalid UTF-8 in
an unread member of a non-stream body and of an SSE completion payload and in a
response model string, repeated request members, response-model location
order, out-of-range status codes, close-delimited SSE, event names without a
completion payload, the chat cache-creation fallback and null finish reasons,
bytes after `[DONE]`, failed client writes, and SSE usage of a family other
than the forwarded path's, including a forwarded path that differs from the
original.
Their provenance is recorded per case; they are not claimed as real captures.

Each implementation tests these rules itself rather than through transcripts:

- The seat index's file rules, identity decoding, and finalization
  revalidation, because they need real directory entries, symlinks, file
  ownership, and file changes between binding and finalization. The transcript
  seat identity carries one `org` value, so precedence between
  `organization_uuid` and `organization.uuid` is tested the same way. The
  snapshot carries identity values, not credential file bytes, so a credential
  file with invalid UTF-8 is tested the same way too.
- Persistence limits (lock wait, shutdown flush, aggregated diagnostics),
  because they need lock contention and process shutdown.
- Invalid UTF-8 in a request body, because a transcript request body is sent
  as UTF-8 text and cannot carry invalid bytes, and an implementation that
  rejects such a request before forwarding never journals it.
- Learning the status line or trace header from undelivered bytes, because
  the result depends on where a read boundary falls relative to the failing
  write, so no single expected record holds at every split point.
- SSE lines at and one byte over the 2 MiB line cap, and an event over the
  2 MiB data cap, because their fixtures would exceed 2 MiB, which is too
  large to keep in the repository.

### Limits in v1

- Non-text inference routes are admitted. Their usage is null, even when a
  stream carries a text-format usage shape.
- Response observation adds relay CPU time that grows linearly with the
  observed payload, up to the observation caps.
- The relay recognizes `/api/v1/responses`, but CLIProxyAPI v8.0.61 does not
  serve that path, so it is not admitted.
- `complete` means delivered protocol completion or HTTP framing completion.
  Fully delivered HTTP errors are complete; status and seat role carry the
  failure.
- CLIProxyAPI's parent and agent identities, canonical-UUID projection, and
  affinity normalization are not adopted; only `session_id` from the JSON or
  suffix form of `metadata.user_id` is read.
