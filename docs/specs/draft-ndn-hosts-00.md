# draft-ndn-hosts-00: Hosts and the Host Protocol

**Status:** DRAFT
**Corpus:** red (spec-first; evidence is the acceptance criteria)
**Category:** Informational
**Authors:** Norman Nunley, Jr. <nnunley@gmail.com>


## Abstract

Mica is a database, a programming language, and a runtime at once—Smalltalk's live image, Self's prototypes, and a Datalog database. Hosts connect people and services to a running world, keeping it accessible while it evolves. This RFC documents what hosts are, how omica implements them, which capabilities matter most for multi-user worlds, and which Rust host features omica should adopt first.


## Motivation

Mica is a database, a programming language and a runtime; hosts are where people and services reach the running world. Rust mica defines MHP1 (15 message types, six transports). Omica implements only MSY1 view-sync and tools/filein for batch loading. Missing: documentation, scope clarity, and remote code submission. Filing to a running world (rdaum/omica#117) works via CLI only. Concurrent calls crashed the world until rdaum/omica#119 made shared structures allocate thread-safely. This RFC settles what hosts are, compares omica against Rust, and frames adoption priorities.


## Terminology

- **Host** — An endpoint for external input and output tied to a session.
- **Endpoint** — A single connection within a session, with an address, transport, and volatile facts.
- **Session** — A client connection mapped to a Mica actor identity for permission and ownership.
- **View sync** — The MSY1 protocol: snapshots and deltas with FNV-1a signatures.
- **Volatile facts** — Facts stored in an endpoint's mailbox, lost on disconnect.
- **Mailbox** — The message queue and volatile store for an endpoint.
- **Filein** — Loading Mica code into a running world.


## Specification

### What a Host Is

Each host endpoint:

- Opens with a session (an actor identity), lasting until explicit close or transport failure.
- Accepts input (queries, code submissions, subscriptions).
- Produces output (results, facts, view deltas, errors).
- Holds a mailbox (message queue and volatile store).
- Delivers view sync (MSY1: 56-byte header, snapshots, and deltas).

Omica's host/web ([host/web/http.odin:1-96](https://github.com/rdaum/omica/blob/5a22a77cc245/host/web/http.odin#L1-L96), server.odin) handles HTTP POST/GET and MSY1 directly. Sessions map to HTTP cookies or WebSocket peer identity. The mailbox is implicit in the pending-reply table (vm/runtime.odin).

### View Sync (MSY1)

Both Rust and omica use the same 56-byte envelope:

- **Header**: session_id (8), view_id (8), client_revision (4), client_signature (4, FNV-1a), server_revision (4), server_signature (4), payload_kind (1)
- **Payload**: full snapshot or delta.

Encoding: little-endian; integrity: FNV-1a ([host/web/sync_protocol.odin:42-97](https://github.com/rdaum/omica/blob/5a22a77cc245/host/web/sync_protocol.odin#L42-L97)).

### Sessions and Actor Identity

The HTTP host creates a session when a client connects, mapping the cookie to a Mica actor identity ([host/web/auth.odin:1-80](https://github.com/rdaum/omica/blob/5a22a77cc245/host/web/auth.odin#L1-L80)). All commands run as that actor. Host-level isolation is a host concern; actor-level authorization is owned by #118.

### Mailbox Semantics

A mailbox is the per-endpoint message queue and volatile store. Tasks submit replies to it; the host drains it on each sync poll. On disconnect, volatile facts are discarded. Messages are not durably logged; they survive only while the endpoint is live. This suffices for interactive clients but not for guaranteed delivery across process boundaries.


## Relation to Rust Mica

| Behavior | Rust | omica today | This RFC | Class |
|----------|------|-------------|----------|-------|
| **Wire protocol** | MHP1 frames (15 message types) | MSY1 only | Specify MSY1; MHP1 is what an omica world needs to connect to Rust hosts | Gap |
| **View sync envelope** | MSY1 (56-byte header, FNV-1a) | MSY1 implemented | Check byte parity against Rust's encoder | Parity |
| **Session/actor mapping** | HTTP session → auth token → actor | HTTP cookie → actor | Document explicitly | Parity |
| **Endpoint lifecycle** | OpenEndpoint, CloseEndpoint, EndpointClosed | Implicit in HTTP connection | Standardize close signaling | Gap |
| **Code submission** | SubmitSource (MHP1 message) | filein CLI tool | Remote SubmitSource on top of world_filein (#117) | Gap |
| **Output batching** | OutputReady + DrainOutput + OutputBatch | Mailbox drain on sync poll | Formalize as batch-reply semantics | Divergence |
| **Telnet interface** | telnet-host (text protocol) | None | Not planned for MVP | Gap |
| **WebTransport** | webtransport-host (QUIC) | None | Evaluate after WebSocket | Gap |
| **ZMQ/daemon** | daemon RPC hub (multi-world routing) | None | Single-process sufficient | Gap |
| **Auth model** | Centralized (OAuth2 + daemon) | Per-host | Out of scope | Gap |


## What Matters for Live Worlds

Three capabilities unlock the multi-user live-world model:

1. **Filing into a running world (#117)**: External code must submit source via host endpoint. CLI-only filein blocks live patching.

2. **Concurrent host calls (#119)**: Multiple endpoints must not corrupt state. The host layer must not add shared state outside the world.

3. **Mailboxes as process boundaries**: Tasks communicate across boundaries via mailboxes, decoupling programs from transport.


## Recommended Adoption Path

**Adopt first**:

1. **Remote SubmitSource**: Expose world_filein (#117) as a host message.
2. **EndpointClosed signaling**: Notify programs when clients disconnect.
3. **Telnet fallback**: Minimal text interface for debugging.

**Defer**:

4. **WebSocket**: Enable bidirectional sync without polling.
5. **Multi-endpoint federation**: Route calls via daemon.

**Out of scope**: OAuth2/PKCE, WebTransport, ZMQ federation.


## Alternatives Considered

**Why MSY1 only, not full MHP1?** omica's own hosts need only MSY1. MHP1 matters when an omica world should be served by Rust hosts; that interoperability is a separate decision. Porting a host or the editor into Rust does not depend on it.

**Why Telnet before WebSocket?** WebSocket has higher overhead for sparse updates. Telnet is simpler to debug and fallback to.

**Why mailboxes, not shared memory?** Mailboxes enforce isolation and decouple sender from transport. Shared memory requires locking and is fragile across boundaries.


## Security Considerations

Host endpoints are trust boundaries. Input is untrusted until authenticated. The host layer must:

- Validate session identity before allowing commands.
- Not cache sensitive output across session boundaries.
- Discard volatile facts on disconnect.
- Leave conflicting concurrent writes to transaction commit, not host serialization.

No additional crypto is needed beyond MSY1's FNV-1a hash; TLS on the transport is assumed.


## Compatibility

This RFC formalizes existing host semantics. Remote SubmitSource and Telnet support are additive. Existing MSY1 clients will continue to work.


## References

- **Rust mica host protocol**: https://github.com/rdaum/mica/tree/main/crates/host-protocol
- **omica host/web**: https://github.com/rdaum/omica/tree/5a22a77cc245/host/web ([host/web/sync_protocol.odin:1-97](https://github.com/rdaum/omica/blob/5a22a77cc245/host/web/sync_protocol.odin#L1-L97))
- **PR #117**: https://github.com/rdaum/omica/pull/117 (per-method programs; filein into a running world)
- **PR #119**: https://github.com/rdaum/omica/pull/119 (thread-safe allocation in everything a world shares)
- **PR #118**: https://github.com/rdaum/omica/pull/118 (runtime make_identity/make_relation, program registry, install authority gate)
- **MSY1 specification**: [host/web/sync_protocol.odin:42-97](https://github.com/rdaum/omica/blob/5a22a77cc245/host/web/sync_protocol.odin#L42-L97) (omica implementation); [crates/host-protocol/src/sync.rs](https://github.com/timbran-project/mica/blob/2bbceb0113b0/crates/host-protocol/src/sync.rs) (Rust reference).
- **Session/actor mapping**: [host/web/auth.odin:1-80](https://github.com/rdaum/omica/blob/5a22a77cc245/host/web/auth.odin#L1-L80) (omica); [crates/web-host/src/auth.rs:1-80](https://github.com/timbran-project/mica/blob/2bbceb0113b0/crates/web-host/src/auth.rs#L1-L80) (Rust).
