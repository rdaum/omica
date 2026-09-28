# In-process HTTP/1.1 + SSE host: design

> Historical design note, preserved on 2026-09-27.
> The HTTP/SSE host exists in `host/web` and `tools/webhost`.
> The milestone notes record the original implementation work.
> Later future-tense sections retain the original design questions.
> They do not describe the current backlog.

Status: M0 through M5 implemented (`host/web`, `tools/webhost`, world API).
Date: 2026-09-12. Scope: the first live web transport for the Odin port. The
host runs in the same process as the kernel and the scheduler.

## 1. Summary

Add a host binary, `tools/webhost`, that serves Mica worlds over HTTP:

- HTTP/1.1 request parsing and responses, written by hand on `core:net`.
- Server-Sent Events (SSE) for DOM sync, matching rust-mica's wire format.
- In-process calls into Mica for document routes and sync view rendering.
- The browser client is the existing `sync-client.js` from rust-mica. The Odin
  host serves that file and speaks the same SSE payloads.

The host is world-agnostic. Any world that provides the document and sync verbs
works. No ZeroMQ, no WebTransport, no TLS, and no WebSockets in this phase. A
reverse proxy terminates TLS.

## 2. Goals and non-goals

Goals:

- Serve `/healthz`, `/sync-client.js`, document routes, `/sync/events`, and
  `/sync/input`.
- Match the rust-mica SSE JSON shape and the `MSY1` sync envelope.
- Keep all socket I/O off the scheduler threads.
- Keep all kernel and transaction access on Mica tasks.
- Bound per-session buffering.
- Support any world that supplies the `http_request` and sync view verbs.

Non-goals for this phase:

- Out-of-process hosts, the host protocol framing and ZMQ carrier.
- WebTransport.
- OAuth. Password auth may come later.
- Chunked request bodies. The reference rejects them too.
- HTTP/2, HTTP/3, and WebSockets.

## 3. Reference behavior

Reference crates: `crates/web-host` (HTTP + SSE), `crates/webtransport-host`
(shared JS client), `crates/host-protocol` (sync envelope + DOM JSON),
`crates/driver` (sessions, event routing).

### 3.1 Routes

| Route | Method | Behavior |
| --- | --- | --- |
| `/healthz` | GET | `200 OK`, body `ok\n` |
| `/sync-client.js` | GET | Serve the JS client, `text/javascript` |
| document routes | GET/POST | Call the world's `http_request` verb, return its response |
| `/sync/events` | GET | SSE stream of sync envelopes |
| `/sync/input` | POST | One `MSY1` sync envelope as the request body |

### 3.2 HTTP subset

- Parse the request line and headers. Reject requests with
  `Transfer-Encoding: chunked`.
- Read the body from `Content-Length` only.
- HTTP/1.1 keeps the connection alive unless `Connection: close` is present.
- Responses use `Content-Length` and an explicit `Connection` header.
- Only `/sync/events` uses `Transfer-Encoding: chunked`.

### 3.3 Document route contract

The host owns the request facts. For each request it writes these facts in one
transaction, then dispatches the `http_request` selector with the request
identity:

```
HttpRequest(request)
RequestMethod(request, method)
RequestPath(request, path)
RequestVersion(request, version)
RequestPrincipal(request, principal)
RequestActor(request, actor)          # when known
RequestHeader(request, name, bytes)   # names lowercased
RequestBody(request, bytes)           # when non-empty
```

The world supplies the `http_request` verb. The shared helper surface
(`http_response`, `http_html`, `http_text`, `http_json`) lives in the corpus,
not in the host.

The verb result is one of:

- a string: `200 OK` with that body;
- `unit`: `204 No Content`;
- a map: `{:status int, :reason string, :headers [[name, value], ...],
  :body string|bytes}`.

All response values are validated: status range, header name and value tokens,
and reason phrase characters.

### 3.4 SSE contract

Headers:

```
HTTP/1.1 200 OK
Content-Type: text/event-stream; charset=utf-8
Cache-Control: no-store
Connection: keep-alive
Transfer-Encoding: chunked
X-Accel-Buffering: no
```

Each envelope is one SSE event, with the JSON on the `data:` line:

```
event: sync
data: {"kind":"ViewSnapshot","session":"...","view":"...",
       "clientRevision":"...","clientSignature":"...",
       "serverRevision":"...","serverSignature":"...",
       "payload":"..."}

```

Revision and signature fields are decimal strings. `payload` is a string that
holds DOM snapshot or delta JSON.

### 3.5 Sync envelope

`crates/host-protocol/src/sync.rs`:

- Magic `MSY1`, header length 56 bytes.
- Kinds: `HaveView` 1, `NeedView` 2, `ViewSnapshot` 3, `ViewDelta` 4.
- Fields: kind, session id, view id, client revision, client signature, server
  revision, server signature, payload bytes.

Input actions:

- `HaveView`: the client reports a revision it holds. The host renders the view
  and replies with a snapshot or a delta.
- `NeedView`: the host renders the view and replies with a snapshot.
- `ViewSnapshot` and `ViewDelta`: client to server payloads, forwarded to the
  world through the endpoint input path.

### 3.6 View contract

- The host renders a view by calling the world. The shared helpers live in the
  corpus under `apps/shared/`.
- `sync_need_view` and `sync_have_view` are the selector names the host uses.
- A rendered view yields a revision, a signature, a DOM node tree, and a
  payload. The host diffs the new tree against the last tree with
  `diff_dom_nodes`.
- View dependencies come from the sync view relation. The host subscribes to
  the dependency relations and re-renders when they change.

## 4. Odin architecture

### 4.1 Thread roles

Three roles. They share only queues and condition variables.

```
acceptor thread          connection threads              scheduler workers
     |                        |                                |
 accept() on bind      parse HTTP; write bytes          run tasks, transactions,
     |                        |                           commits, rendering
 spawn connection  <---->  session queues  <---->  session tasks (parked)
```

Rules:

- Connection threads never call the kernel.
- Scheduler workers never call `recv` or `send`.
- Tasks own session state and produce output. They do not own sockets.
- Mailboxes and `subscribe_changes` carry input and change events to tasks.
- Per-session output queues are bounded. A slow client applies backpressure to
  its own connection only.

### 4.2 Modules

New package `host/web`:

| File | Contents |
| --- | --- |
| `http.odin` | request parse, response encode, chunked writer, limits |
| `server.odin` | listener, acceptor loop, connection threads, keep-alive |
| `routes.odin` | route table, document dispatch, response decode |
| `sse.odin` | SSE headers, chunk framing, heartbeat, event JSON |
| `sync.odin` | `MSY1` encode/decode, session table, view flow |
| `dom_json.odin` | DOM node and patch JSON, supported tags and attrs |
| `session.odin` | session records, output queues, wakeups, shutdown |
| `auth.odin` | later: cookie session and login (optional) |

New binary `tools/webhost`:

- Parse flags: `--bind`, `--filein` (repeatable), `--actor`, `--sync-client`.
- Build the kernel and compile the world with the existing `run_files` path.
- Start the scheduler with the entry task.
- Start the HTTP listener.
- Wait for a signal, then stop the listener and join threads.

### 4.3 HTTP server

Request parsing, in order:

1. Read up to a byte limit for the request line and headers (`\r\n\r\n`).
2. Reject oversized headers, too many headers, and bad methods.
3. Reject any `Transfer-Encoding`.
4. Read `Content-Length` bytes for the body. Reject oversized bodies.
5. Keep the connection open when HTTP/1.1 and `Connection` is not `close`.

Response encoding:

- Status line, `Content-Length`, `Connection`, then body.
- Always flush after a full response.

Connection loop:

```
for request in parse_loop:
    route = match_route(request)
    response = handle(route, request)
    write(response)
    if close: break
```

Limits to define as constants and test: max request line, max header bytes, max
header count, max body bytes, socket read and write timeouts.

### 4.4 Document route flow

The connection thread:

1. Parse the request.
2. Build a request identity and a request record.
3. Submit the request to a session task and wait on a condition variable for
   the response (with timeout).
4. Encode and write the response.

The session task (on the scheduler):

1. Begins a transaction.
2. Asserts the request facts.
3. Dispatches `http_request(request)`.
4. Commits at the boundary.
5. Publishes the response map to the session queue and wakes the connection.

Reuse `scheduler_resume` and the existing task host-request path. For the first
cut, one task per request is acceptable. Later, one long-lived session task per
endpoint avoids per-request setup and matches the reference endpoint model.

### 4.5 SSE flow

Connection thread:

1. Parse `GET /sync/events`. Resolve the session (from query or cookie).
2. Register the connection as the stream writer for that session.
3. Write the SSE headers.
4. Loop:
   - wait on the session queue with a heartbeat timeout;
   - write `: keepalive\n\n` on timeout;
   - for each envelope, write `event: sync\ndata: {...}\n\n` as one chunk.

Only one writer per session. A new stream replaces the old writer; the old
writer sees a generation mismatch and exits.

### 4.6 Session lifecycle

A session holds:

- `session_id`, `view_id`, endpoint identity, actor and principal identities;
- the last rendered DOM tree, revision, and signature per view;
- a bounded output queue (`HIGH_WATER = 128`, `DRAIN_BATCH = 64`);
- input mailbox sender and view dependency subscriptions.

Flow:

1. First `/sync/input` envelope creates the session (`ensure_session`).
2. `HaveView` or `NeedView` renders the view.
3. The host stores the tree and signature, then posts a `ViewSnapshot` or
   `ViewDelta` envelope to the session queue.
4. The host subscribes to the view dependency relations with
   `subscribe_changes`. A change marks the view dirty.
5. A dirty view is re-rendered on the next input or change dispatch.

### 4.7 Backpressure

- The output queue is bounded. Writers drain in batches.
- When the queue is at the high-water mark, the session may send `NeedView` to
  make the client resynchronize instead of queueing more.
- Subscription overflow already sends `:resynchronize`. The host treats it as
  a dirty view.
- A blocked socket write blocks only its own connection thread.

### 4.8 Shutdown

1. Stop the acceptor.
2. Mark all sessions closed and wake their writers.
3. Join connection threads with a timeout.
4. Stop the scheduler and destroy the kernel.

## 5. Protocol port surface

Port these pieces from `crates/host-protocol`:

| Piece | Reference | Notes |
| --- | --- | --- |
| Sync envelope header | `sync.rs` | `MSY1`, 56 bytes, kinds 1-4 |
| Sync envelope encode/decode | `sync.rs` | little-endian fields, payload last |
| DOM node and patch JSON | `dom_sync.rs` | tags, attributes, patch ops |
| Snapshot payload JSON | `dom_sync.rs` | `snapshot_payload_json` shape |
| Signature | `dom_sync.rs` | `sync_payload_signature` |
| View dependencies | `view_dependency.rs` | subject relations and selectors |

Frame and message framing (`frame.rs`, `message.rs`) is out of scope until an
out-of-process host exists. The in-process host calls tasks directly.

## 6. Existing Odin surface

Already present and used by this plan:

- `endpoint`, `actor`, `principal` builtins.
- Mailboxes and `mailbox_recv` wakeups.
- `subscribe_changes` with `:facts`, `:relation`, and `:catalogue` subjects,
  queue budgets, and resynchronize markers.
- `external_request` suspension and `scheduler_resume`.
- DOM builtins: `dom_text`, `dom_raw`, `dom_element`, `to_xml`.
- `dom_snapshot_payload` and `sync_signature`.

Gaps to close:

1. `dom_snapshot_payload` currently returns
   `{"view":N,"revision":R,"root":"<xml>"}`. The sync protocol needs the JSON
   DOM node tree. Replace the XML string with the `DomNode` JSON encoder.
2. Verify `sync_signature` against `sync_payload_signature`. Replace the hash
   if it differs.
3. Add a DOM diff and patch encoder in Odin for `ViewDelta`.
4. Port the view render contract (`sync_need_view`, `sync_have_view`) and the
   view dependency subjects.
5. Add a session endpoint wrapper that owns input and subscriptions.

## 7. Milestones

### M0: HTTP skeleton (done)

- `host/web/http.odin` and `server.odin`.
- `tools/webhost` serves `/healthz`, `/`, and `/sync-client.js`.
- Raw-socket tests: keep-alive, `Content-Length`, chunked reject, limits.
- Notes: the acceptor uses non-blocking accept with a 1ms poll so
  `web_server_stop` can wake it by closing the listener. Handler header lists
  must live at file scope; slice literals built inside a handler can escape
  the frame.

### M1: Document routes (done)

- `tools/webhost --filein` loads a world through `world_start` and keeps it
  alive; the connection thread submits `http_request` with request facts and
  waits for the outcome.
- Response map decode with validation (`host/web/response.odin`).
- Tests: a fixture world serves a document and a 404; the mud corpus serves
  `/mud` as a 49KB page and `/nope` as a 404.

`world_start` loads a world and submits its entry task. `world_wait` awaits a
task outcome, `world_submit_call_with_facts` submits a dispatch with a
transaction preamble, and `world_release` frees a terminal entry. `run_files`
is a thin wrapper over this path.

M1 exposed three runtime gaps, now fixed: `actor()`/`principal()` return
`some`/`none` options, branch conditions and `not` use value truthiness
(non-empty lists and relations are true), and `sync_signature` masks to the
56-bit Mica integer range.

### M2: Sync transport (done)

- `MSY1` encode/decode (`sync_protocol.odin`), SSE event JSON with escaping
  (`sync_json.odin`), session state with a bounded output queue, and the
  chunked `/sync/events` stream (`sync.odin`).
- `/sync/input` renders `sync_snapshot_payload(view)` through the world and
  queues a `ViewSnapshot`; `HaveView` and `NeedView` both render.
- The server has a streaming handler hook so `/sync/events` owns its
  connection.
- Tests: envelope and signature fixtures, SSE JSON format, session/query
  units, and a raw-socket client that streams an event for a fixture world.
- Smoke test: the mud world answers `/sync/input` with 202 and streams a
  `ViewSnapshot` for view 21.

M2 still renders through the app's `sync_snapshot_payload` verb. M3 replaces
that with `sync_view_tree` plus host-side DOM node JSON, which the JS client
needs for a real view.

### M3: DOM fidelity (done)

- New package `mica/dom`: the sync DOM model, tags and attributes, node and
  patch JSON encoders, and snapshot payloads with sorted keys and attributes
  to match the Rust host byte for byte.
- `dom_snapshot_payload` and the SSE render path use it. `sync_render_view`
  now calls `sync_view_tree` and encodes the tree host-side, matching Rust.
- The JS client is vendored at `host/web/sync-client.js` and served by the
  host.
- Tests: exact JSON fixtures for nodes, attributes, and patches; rejects for
  unsupported tags, attributes, and raw nodes; the sync integration test
  asserts DOM node JSON in the stream.
- Smoke test: the mud world streams a snapshot whose payload passes the JS
  client's own rules (view and revision match the envelope, FNV signature
  matches, node structure valid), and the client script is served.

A real browser check is manual. Deltas (`ViewDelta`) need the M4 diff and
subscription work; the patch encoder is in place.

### M4: Live updates (done)

- View state keeps the last tree, revision, and signature per session view.
- After the first render the host calls `sync_view_dependencies(view)`,
  resolves each relation, and subscribes with a host mailbox
  (`world_mailbox_create`, `world_subscribe_changes`).
- A pump drains session mailboxes every 25ms, marks views dirty, and
  re-renders. A dirty render diffs the tree and posts a `ViewDelta`; no
  change posts nothing. `:resynchronize` and `:revoked` markers force a
  snapshot on the next render.
- Tests: DOM diff fixtures (text, attrs, children, keyed reorder) and a
  raw-socket end-to-end test: snapshot, `bump` a relation, delta with
  `append_child` at revision 2.

Three bugs surfaced and were fixed on the way: DOM payloads were returned
from destroyed builders (use-after-free), list child interpolations were not
flattened, and the SSE chunk writer aliased the builder it appended to,
which duplicated events.

### M5: Auth (done)

- Seeded local users (`alice`/`alice-pass`, `bob`/`bob-pass`) with Argon2id
  password hashes (`core:crypto/argon2id`, OWASP-small parameters). Rust uses
  Argon2 with signed tokens; this port uses an opaque random token in memory.
- `POST /auth/login` issues a `mica_session` cookie and redirects;
  `POST /auth/logout` clears it; bad credentials return 401.
- `World_Call_Options` overrides the actor, principal, and endpoint per call.
  Documents and sync renders run as the session actor, so a logged-in player
  sees the world view.
- Tests: password/session units, form decode, login request, and a fixture
  where `sync_view_tree` renders differently for `#alice` and for the default
  actor.
- End-to-end: logging in as alice and opening the sync stream yields the MUD
  game view (`mud-shell`), not the login node.

Divergences: user creation (`/auth/create`) returns 400, GitHub OAuth is not
implemented, session tokens are not signed, and per-session authority
enforcement is not minted yet (tasks run with the world default authority).

## 8. Testing

- Unit: HTTP parse and encode tables, chunk framing, envelope round trip,
  DOM JSON against Rust fixtures.
- Integration: raw TCP tests for every route; a scripted SSE client.
- World: a minimal fixture world covers the contract; corpus worlds load and
  serve their documents.
- Differential: capture SSE payloads from rust-mica and compare JSON field by
  field. This is a fixture comparison, not a live cross-run.
- Concurrency: many SSE sessions with concurrent writers; slow-client test
  that a blocked socket does not stall the scheduler.

## 9. Risks and open questions

- DOM JSON must match the JS client exactly. The client parses patch tags and
  attributes against fixed sets. Byte differences break the view.
- The view render contract is not yet read in full. The host must know which
  selectors to call and what value shape is expected.
- Session to task mapping: per-request tasks are simple but stateful views want
  a long-lived session task. Decide before M2.
- One writer per stream is required. The second connection replaces the first.
- Heartbeat interval is a proxy concern. Pick a value and make it a constant.
- Password hashing and the cookie format are host policy. OAuth stays out.
- Chunked writes need explicit flushes. A partial write must be retried.
