# draft-ndn-transactions-changelog-00: Transactions, Persistence, and the Change Log

**Status:** DRAFT

**Corpus:** red (spec-first; evidence is the acceptance criteria)

**Category:** Standards-Track

**Authors:** Norman Nunley, Jr. <nnunley@gmail.com>

## Abstract

Mica is a database, programming language, and runtime at once: blending Smalltalk's live image, Self's prototypes, and Datalog. The live world is the source of truth. This RFC specifies transactional isolation, durable storage, conflict detection, and change notification. It defines optimistic transactions with snapshot isolation, conflict detection and diagnostics for set and functional relations, commit versions, durability modes, and a queryable change log recording every committed change as system relations for audit trails and time-travel debugging.

## Motivation

Mica's transactional model must provide serializability under concurrent access while allowing in-place code and data modifications. Rust mica and omica both use optimistic snapshot isolation but lack conflict diagnostics naming relations and tuples (not error codes), a configurable change feed, and a queryable permanent change record. This forces audit tools to scan snapshots rather than query history. This RFC closes these gaps by adding conflict diagnostics, a configurable change feed, and a queryable Change_Log system relation with retention policies.

## Terminology

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in BCP 14 (RFC 2119, RFC 8174) when, and only when, they appear in all capitals, as shown here.

- **Conflict** — a write-write collision when one transaction modified a tuple that a concurrent transaction also modified.
- **Functional key** — a constraint that a relation projects to at most one tuple per key value.
- **Durable relation** — a relation whose facts persist to disk and survive process restart.
- **Volatile relation** — a relation held in memory only; emptied on restart.
- **Change feed** — a bounded in-memory buffer of recent commits.
- **Change log** — a system relation recording every committed change, queryable by version, timestamp, actor, and relation.
- **Retention policy** — a rule determining which change log entries persist and which are compacted.

## Specification

This document defines transactional isolation, conflict detection, durability guarantees, and change notification. Out of scope: concurrent host access, compile/install semantics, filein, incremental rule evaluation.

**Serializability through snapshots:** Commits are totally ordered; conflicts detected before publication make every transaction serializable.

**Durability is explicit:** Each relation marked durable or volatile; users choose what survives restart.

**All changes observable:** Change log records every change, queryable for audit trails and replay.

### Transactions

#### Transaction Lifecycle

A transaction MUST capture a base snapshot and establish a local write overlay at begin time. [R-txn-read-your-writes]

All reads within a transaction MUST see base facts and locally-staged writes, deduplicated by the relation's conflict policy (set or functional). [R-txn-read-your-writes]

Transaction writes MUST remain invisible outside the transaction until commit succeeds. [R-txn-read-your-writes]

<!-- evidence: @R-txn-read-your-writes -->
| Operation | Base | Staged | Result |
|-----------|------|--------|--------|
| T.begin() | R={#a, #b} | (empty) | (none) |
| T.assert(R, #c) | R={#a, #b} | {#c} | (not external) |
| T.query(R) | R={#a, #b} | {#c} | {#a, #b, #c} |
| T2 concurrent | R={#a, #b} | (unaware) | {#a, #b} |
| T.commit() | R={#a, #b} | → v+1 | published |

A transaction's base version is fixed at begin time and MUST NOT change. If a commit detects conflict or fails, the transaction MUST abort, leaving the base snapshot unchanged.

**Within-transaction uniqueness enforcement:** A functional relation MUST reject a second distinct tuple for the same key within the same transaction, signaling `FunctionalKeyViolation` immediately. [R-txn-within-key]

<!-- evidence: @R-txn-within-key -->
| Operation | State | Result |
|-----------|-------|--------|
| Setup Color(person → color) | empty | OK |
| T.assert(#alice, "red") | {(#alice, "red")} | OK |
| T.assert(#alice, "blue") | pending | FunctionalKeyViolation |
| T.commit() | aborted | (never reached) |

Asserting a present tuple in a set relation MUST succeed and change nothing (idempotent). [R-txn-set-dedup]

<!-- evidence: @R-txn-set-dedup -->
| Case | Behavior |
|------|----------|
| T.assert(R, #x) | success |
| T.assert(R, #x) again | success; no change |
| T.commit(); query R | R = {#x} |

#### Conflict Detection

Mica supports two conflict policies per relation: set and functional.

**Set relations:** Asserting a present tuple is idempotent ([R-txn-set-dedup]). The system MUST allow concurrent writes to distinct tuples and detect conflicts when a transaction asserts a tuple that a concurrent transaction deleted. On commit, the system MUST compare each asserted tuple against the current snapshot. [R-set-conflict]

<!-- evidence: @R-set-conflict -->
| Scenario | T1 Base | T2 | T1 Write | Result |
|----------|---------|-----|----------|--------|
| Distinct tuples | R={#a} | (none) | R.assert(#b) | SUCCESS |
| Same tuple | R={} | assert R(#a) v1 | assert R(#a) | SUCCESS |
| Retraction conflict | R={#a} | retract R(#a) v1 | assert R(#a) | ABORT: E_CONFLICT |

**Functional relations:** The system MUST enforce projection and detect conflicts when a transaction modifies a key that a concurrent transaction also modified. On commit, the system MUST compare base-snapshot and current-snapshot tuples per key. [R-functional-conflict]

<!-- evidence: @R-functional-conflict -->
| Scenario | T1 Base | T2 | T1 Write | Result |
|----------|---------|-----|----------|--------|
| Concurrent key | {(#alice, "red")} | #alice → "blue" | #alice → "green" | ABORT: E_FUNCTIONAL_CONFLICT |
| Non-overlapping | {(#alice, "red")} | #bob → "blue" | #alice → "green" | SUCCESS |
| Same tuple | {(#alice, "red")} | #alice → "red" | #alice → "red" | SUCCESS |

#### Conflict Diagnostics

Conflict error messages MUST name the relation, both tuples, and the key involved. [R-conflict-diag]

<!-- evidence: @R-conflict-diag -->
| Error Type | Required Message Content | Example |
|------------|--------------------------|---------|
| E_FUNCTIONAL_CONFLICT | relation name/ID, key, base tuple, current tuple | `E_FUNCTIONAL_CONFLICT in relation #12 (Person_Color): key [#alice] conflict; base: [#alice, "red"]; current: [#alice, "blue"]` |
| E_CONFLICT | relation name/ID, tuple | `E_CONFLICT in relation #5 (User): tuple [#bob, 42] was retracted concurrently` |

### Commit Versions and Ordering

Each commit MUST increment the snapshot version by 1. Versions are IMMUTABLE, never reset, and always observable. [R-version-monotonic]

<!-- evidence: @R-version-monotonic -->
| Event | Version | Observable |
|-------|---------|------------|
| Store start | 0 | yes |
| Commit T1 | 1 | yes |
| Commit T2 | 2 | yes |
| Restart | 2 | yes |
| Query version | 2 | yes |

Commits MUST be totally ordered: only one commit SHALL succeed at a time. When multiple transactions attempt commit concurrently, one succeeds and the rest abort with version mismatch. [R-commit-serial]

<!-- evidence: @R-commit-serial -->
| Scenario | Result | Version |
|----------|--------|---------|
| Sequential | both succeed | 2 |
| Concurrent (v0) | one succeeds, one aborts | 1 |
| Races (v0→v1) | T1 succeeds; T2 aborts | 1 |

A commit record contains:

- **version** — the new snapshot version
- **timestamp** — Unix time in milliseconds of commit publication
- **actor** — identity/capability of the transaction originator
- **fact_changes** — array of (kind, relation_id, tuple) records; kind is "assert" or "retract"
- **catalog_changes** — array of (kind, relation_id, rule_id, name) records; kind is "relation_created", "rule_installed", "rule_disabled"

### Durability Modes

A store MUST offer three durability modes at store creation. [R-durability-modes]

<!-- evidence: @R-durability-modes -->
| Mode | Commit Returns | Process Crash | Power Loss |
|------|--------|---------|--------|
| `none` | Before WAL sync | Data survives if OS wrote | Commits lost |
| `group` | After WAL write (batched) | Data survives | Last batch lost |
| `strict` | After WAL sync | Data survives | Data survives |

Every relation is independently marked durable or volatile at creation. Durable relations MUST be written to disk in every commit; volatile relations' facts MUST NOT touch disk. On restart, volatile relations MUST be empty. [R-durable-volatile]

<!-- evidence: @R-durable-volatile -->
| Relation | Durable? | Persisted on Commit? | After Restart | Evidence |
|----------|----------|-------------------|---|----------|
| User | yes | yes | data restored | facts written to checkpoint |
| Temp_Cache | no | no | empty | facts never written to disk |
| Audit_Log | yes | yes | data restored | facts written to WAL and checkpoint |

### Write-Ahead Log, Checkpoints, and Restore

The system MUST maintain a write-ahead log (WAL) recording every commit before snapshot publication. Commits MUST reach WAL before becoming visible to queries. [R-wal-before-publish]

<!-- evidence: @R-wal-before-publish -->
| Event | WAL State | Snapshot State | Visible to Query | Notes |
|-------|-----------|----------------|------------------|-------|
| T1 asserts R(#a) | (in staging) | version V | (version V) | write not yet durable |
| T1 writes to WAL | version V+1 record | version V | (version V) | WAL has record, snapshot not yet updated |
| T1 publishes snapshot | version V+1 record | version V+1 | (version V+1) | after publication, visible to new queries |
| Crash before WAL | (none) | version V | (version V) | write lost, snapshot unchanged |
| Crash after WAL, before publish | version V+1 record | version V | (version V) | recovery replays WAL, restores version V+1 |

The system MUST periodically create a checkpoint: a snapshot of all durable relation data, the catalog, and current version. On restart, the system MUST follow this procedure: [R-checkpoint-restore]

1. Load the latest checkpoint (if any)
2. Replay WAL entries from the checkpoint version onward
3. Publish the last replayed version as the current snapshot

<!-- evidence: @R-checkpoint-restore -->
| State | On Restart | Final |
|-------|-----------|-------|
| Checkpoint at v50 | Load v50, replay WAL v51-v75 | 75 |
| Checkpoint at v1 | Load v1, replay WAL v2-v75 | 75 |
| No checkpoint | Replay WAL from v0 | 75 |

### Store Locking

The store MUST be protected by a file-level or OS-level lock preventing concurrent multi-process access. [R-store-lock]

<!-- evidence: @R-store-lock -->

The lock MUST be acquired on open, held until close, and record its owner. [R-lock-owner]

<!-- evidence: @R-lock-owner -->

Only one writer MUST be active; readers MAY run concurrently with each other but NOT with writers. If a lock holder crashes, an explicit recovery process MUST release the lock; the system MUST NOT auto-expire locks. [R-lock-explicit-release]

<!-- evidence: @R-lock-explicit-release -->
| Scenario | Process A | Process B | Result |
|----------|-----------|-----------|--------|
| A opens, acquires lock | (holds lock) | B tries to open | B blocked |
| A closes, releases lock | (releases) | B retries | B succeeds |
| A reader holds | read lock | B reader | both proceed |
| A reader active | (reading) | B writer | B blocked |
| A crashed, lock stale | PID 1234 | recovery (manual) | (requires manual release) |

### Change Subscriptions with Cursors

Subscribers MUST provide a cursor (version number) and receive all commits since that cursor. The system MUST maintain a bounded in-memory change feed, configurable in size (default 512 records). [R-change-feed-bounded]

<!-- evidence: @R-change-feed-bounded -->
| Configuration | Default | Min | Max | Notes |
|---------------|---------|-----|-----|-------|
| feed_capacity | 512 | 1 | unbounded | user-settable at store creation |
| Feed holds versions | 512 most recent | v0 to v512 | v(N-512) to vN | oldest entries evicted when full |

For each version in the feed, asserted and retracted tuples MUST be deep-copied so subscribers can apply deltas without holding snapshots. [R-change-feed-deep-copy]

<!-- evidence: @R-change-feed-deep-copy -->
| Version | Tuples in Feed | Subscriber View |
|---------|----------------|-----------------|
| v100 | {ASSERT R(#a), RETRACT R(#b)} | (deep copy, no snapshot dependency) |
| v101 | {ASSERT S(#c)} | (deep copy, independent) |

When a subscription cursor falls outside the retained change feed window, the subscriber MUST receive a `RESYNCHRONIZE` marker and fetch the current snapshot. [R-cursor-resync]

<!-- evidence: @R-cursor-resync -->
| Cursor | Window (v500-v1011) | Delivery |
|--------|------------|----------|
| 499 | outside | RESYNCHRONIZE + snapshot |
| 500 | boundary | Changes(v501-v1011) |
| 1000 | inside | Changes(v1001-v1011) |
| 1012 | beyond | (empty) |

### The Durable Change Log

The system relation `Change_Log` MUST record every committed change as queryable facts. [R-change-log]

The relation schema:

```
RECORD Change_Log:
    version     : u64        -- commit version
    timestamp   : i64        -- Unix time in milliseconds
    actor       : Identity   -- originator of the change
    fact_id     : u64        -- opaque identifier (version + index)
    kind        : Symbol     -- "assert" or "retract"
    relation    : Relation_ID -- which relation changed
    tuple       : Tuple      -- the tuple asserted/retracted
```

<!-- evidence: @R-change-log -->
| Commit | Action | Change_Log Records | Fact_ID | Kind |
|--------|--------|-------------------|---------|------|
| v1 | assert R(#a) | (v1, ts, actor, 0, "assert", R, (#a)) | 0 | assert |
| v2 | retract R(#a) | (v2, ts, actor, 1, "retract", R, (#a)) | 1 | retract |
| v2 | assert S(#b) | (v2, ts, actor, 2, "assert", S, (#b)) | 2 | assert |

Catalog changes MUST be recorded in a separate system relation:

```
RECORD Catalog_Change_Log:
    version     : u64        -- commit version
    timestamp   : i64        -- Unix time in milliseconds
    actor       : Identity   -- originator
    kind        : Symbol     -- "relation_created", "rule_installed", "rule_disabled"
    relation_id : Relation_ID (nullable)
    rule_id     : Rule_ID (nullable)
    name        : Symbol     -- relation or rule name
```

Change log entries MUST persist in every checkpoint and restore on restart. Queries MUST see all recorded changes within the retention window. [R-change-log-persist]

<!-- evidence: @R-change-log-persist -->
| Event | Change_Log | Checkpoint | On Restart |
|-------|------------|-----------|-----------|
| Commit v1-v100 | entries 0-99 | v100 checkpoint | restored |
| Query Change_Log | all entries | no change | queryable |
| Crash at v101 | v1-v100 on disk | load v100 | recovered to v100 |

Query the change log like any relation to find all changes to a relation in a time window:

```
Change_Log(V, T, ?, ?, "assert", #42, Tuple) where T > now - 3600000
```

#### Change Log Retention Policies

A configurable retention policy MUST control compaction, supporting these policies: [R-retention-policy]

<!-- evidence: @R-retention-policy -->
| Policy | Configuration | Behavior |
|--------|---------------|----------|
| `KEEP_ALL` | default | Retain all v1-vN |
| `KEEP_LAST_N_VERSIONS` | N=100 | Keep last 100 versions |
| `KEEP_LAST_N_DAYS` | days=7 | Keep last 7 days |

When a retention policy compacts the change log, entries outside the retention window MUST be removed during checkpoint creation, not continuously. [R-compaction-checkpoint]

<!-- evidence: @R-compaction-checkpoint -->

The compaction procedure MUST determine entries outside the retention window, copy remaining entries to a new buffer, update the checkpoint, and atomically swap the new buffer into place. [R-compaction-procedure]

<!-- evidence: @R-compaction-procedure -->
| Event | Policy | Action | Result |
|-------|--------|--------|--------|
| checkpoint v100 | KEEP_ALL | none | all retained |
| checkpoint v200 | KEEP_LAST_100 | compact | v1-v99 removed |
| checkpoint v300 | KEEP_LAST_7_DAYS | compact | old by timestamp removed |

#### Mailbox Sends and Staging

Mailbox sends within a transaction MUST be staged and become durable only upon commit. [R-mailbox-staged]

<!-- evidence: @R-mailbox-staged -->
| Event | Mailbox State | Staging State | Visible to Recipient? | Durable? |
|-------|---------------|---------------|-----------------------|----------|
| T.send(msg1) | (empty) | staged | no | no |
| T.send(msg2) | (empty) | both staged | no | no |
| T.commit() | (messages sent) | cleared | yes | yes |
| Crash before commit | (empty) | lost | no | no |
| Crash after commit | (both sent) | cleared | yes (delivered) | yes |

If a transaction aborts before commit, all staged mailbox sends MUST be discarded to prevent partial message delivery.

<!-- evidence: @R-mailbox-staged (abort case) -->
| Scenario | Staged Messages | Commit Outcome | Mailbox After Abort |
|----------|-----------------|-----------------|----------------------|
| T1 sends, commits | msg1, msg2 | success | msg1, msg2 delivered |
| T2 sends, aborts | msg3, msg4 | conflict abort | (empty, msg3/msg4 discarded) |
| T3 sends, rollback | msg5 | application abort | (empty, msg5 discarded) |

## Formal Grammar

No wire or file syntax is introduced by this RFC. Change log entries use the relation schema defined above; grammar is covered by the Values and Declarations RFCs.

## Out of Scope

**Concurrent host access.** Multiple host processes cannot run against the same store concurrently. Only one process at a time may hold the store lock. Inter-process communication happens via mailboxes and the change feed, owned by Host Protocol RFC #110, #111.

**Incremental rule evaluation.** Deriving change subscriptions by replaying the change log instead of full rule evaluation is an optimization owned by RFC #112 (incremental maintenance).

**Time-travel snapshots.** Querying data as it existed at a past version (time-travel queries) is not specified here; it requires a snapshot indexing layer owned by a separate RFC.

**Actor assignment logic.** How the `actor` field in Change_Log and Catalog_Change_Log is populated (from the transaction context, from the caller, etc.) is owned by RFC #118 (authority and grants).

## Alternatives Considered

**Bounded vs. unbounded change feed:** Bounded feed with resynchronization bounds memory while allowing subscribers to catch up; persisted change log serves long-term audit needs.

**Persistent change log vs. recomputing from checkpoints:** Persisted entries answer point queries without scanning entire snapshots.

**Separate Catalog_Change_Log vs. combined log:** Separate relations simplify queries and allow independent retention policies for different change types.

**WAL before vs. after snapshot publication:** Writing WAL before publication prevents losing commits that readers already observed.

## Security Considerations

The change log records all modifications, enabling audit trails but creating a risk if unprotected: attackers with write access could cover tracks. Implementations MUST protect the change log with the same access controls as persisted data; in multi-tenant environments, partition per tenant. The actor field MUST populate from trusted sources (transaction context or capability system), never untrusted input; RFC #118 specifies the mechanism.

## Compatibility

This RFC is normative for new implementations. Existing systems lack change log and conflict diagnostics; this specifies how to add both.

**Data migration:** To migrate an existing store, perform an initial scan of all facts and synthesize Change_Log entries as if asserted at version 0 or the current version (one-time offline operation).

**Backward compatibility:** Existing transactions and code work unchanged; the change log is a new system relation that does not alter transaction semantics or conflict detection.

## References

- **RFC 2119, RFC 8174** — BCP 14, Key words for use in RFCs to Indicate Requirement Levels
- **Smalltalk-80: The Interactive Programming Environment** — Adele Goldberg, David Robson, 1983. Chapters on the changes file and live image model.
- **Rust Mica, [crates/relation-kernel/src/transaction.rs](https://github.com/timbran-project/mica/blob/2bbceb0113b0/crates/relation-kernel/src/transaction.rs)** — https://github.com/rdaum/mica (reference implementation)
- **omica, [mica/kernel/transaction.odin](https://github.com/rdaum/omica/blob/5a22a77cc245/mica/kernel/transaction.odin)** — https://github.com/ndn/omica (alternative implementation)
- **Concurrent control with "Readers-Writers" locks** — Eswaran et al., TODS 1976. Foundation for snapshot isolation and multiversion concurrency.

## Appendix A: Relation to Rust Mica

Parity with Rust Mica: snapshot isolation, read-your-own-writes, set/functional conflicts, versioning, durability modes, durable/volatile relations, WAL/checkpoint/restore, store locking.

| Behavior | Rust Mica | omica today | This RFC | Class |
|----------|-----------|-------------|----------|-------|
| Conflict diagnostics | Named tuples | Error code only | Named tuples | Gap → Improvement |
| Change feed | Unbounded | Hardcoded 512 | Configurable 512 | Improvement |
| Cursor resync | Not needed | Via change feed | MUST implement | Improvement |
| Queryable change log | No | No | MUST implement | New |
| Retention policy | N/A | N/A | MUST support | New |
| Mailbox sends staged | Yes | Planned | MUST implement | Gap → Improvement |

---

**Authors' Notes for the RFC Editor**

This RFC settles open questions about conflict diagnostics (named tuples), durability modes (Relaxed/Strict), configurable change feed capacity, queryable change log, retention policies, and mailbox send staging. Requirements marked with `[R-*]` are acceptance criteria.
