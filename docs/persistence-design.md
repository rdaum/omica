# Persistence for mica-odin: design

> Historical design note, preserved on 2026-09-27.
> The store implements layers A and B in `mica/store`.
> Layer C remains a proposal.
> The format sketches and open questions retain the original design alternatives.
> The implementation and runtime guide define current behavior.

Status: layers A and B implemented. Value codec, budget admission, memory WAL,
durable version, the file-backed write-ahead log with group/strict sync and
torn-tail recovery, kernel replay, and runtime boot are in place. Chunk shadow
pages: checkpoints write only chunks not yet persisted, the manifest lists each
durable relation's page ids, the log is truncated at each checkpoint, and boot
materializes blocks from pages then replays only the WAL tail. Manifests are
retained for point-in-time reads, and dead pages are reclaimed by generation
compaction.
Date: 2026-09-12.
Scope: durable world state for the Odin port. References: `../pagebox`
(buffer pool, WAL, page store) and `../moor/crates/db` (write pipeline).

## 1. Summary

The kernel does not need a ground-up storage engine. Its committed store is
already a versioned copy-on-write structure of immutable, reference-counted
row chunks. Persistence adds three things:

1. a durable representation of chunks and catalogue state,
2. a write pipeline that hands committed state to disk without blocking the
   in-memory commit path on I/O, and
3. a boot path that reconstructs a kernel and world from the store.

The design borrows two ideas. From pagebox: an append-only page store with a
write-ahead log, free-page allocation, and eventually a swizzled-pointer
buffer pool for working sets larger than RAM. From moor: **reserve durable
capacity before publishing in memory**, so the visible state can never run
unboundedly ahead of what has been handed to persistence.

## 2. Goals and non-goals

Goals:

- A world survives process restart with its facts, schema, rules, identity
  names, and installed behaviour intact.
- Crash safety: a restart after a crash recovers the last contiguous
  committed version, not a torn or partial one.
- The memory commit path does not wait on disk I/O except for bounded
  capacity admission.
- Disk is durable storage, and later a cold tier for working sets larger than
  RAM, without changing the kernel's data structures.

Non-goals for the first milestone:

- Multi-process writers. The kernel is single-writer; the store takes an
  exclusive lock.
- On-disk format stability across versions. Like pagebox, a format change
  means reinitialising the store.
- Durable bearer capabilities, subscriptions, or mailboxes. These are
  runtime state, not world state.
- Compression and encryption (leave room in the format).

## 3. What the kernel already provides

### 3.1 Immutable chunks are pages

`Relation_Chunk` (`mica/kernel/store.odin`) is an immutable, reference-counted
run of up to `CHUNK_CAPACITY` (128) sorted tuples in its own arena.
`relation_block_apply` builds a new `Relation_Block` that shares unaffected
chunks and rebuilds only the chunks a commit touched. Pages are therefore:

- immutable between commits, so shadow paging is natural;
- shareable across versions, so a checkpoint writes only new chunks;
- never dirty, so there is no page write-back path and no double-write
  problem (unlike a mutable page store).

### 3.2 Versioned snapshots

`Snapshot` (`mica/kernel/snapshot.odin`) holds the catalogue, one block per
relation, rules, and derived rows. Snapshots are immutable after publication
and reference-counted. Versions are monotonic (`snapshot.version`), which
gives us a commit sequence for WAL records, manifests, and point-in-time
reads.

### 3.3 A single committer with group commit

`transaction_commit` prepares candidates and enqueues them;
`kernel_committer_drain` / `kernel_publish_group` (`mica/kernel/kernel.odin`)
publish batches, merging disjoint candidates into one snapshot. This is the
single serialization point where the store hooks in, and it already batches
commits so one fsync can cover many transactions.

### 3.4 Logical change records already exist

`changes_record_writes` (`mica/kernel/changes.odin`) records a
`Change_Record{version, relation, asserted, retracted, catalogue}` per version
for subscriptions. The same record is the natural logical WAL payload.

### 3.5 Value and durability classification exist

`value_is_storable` and `value_is_persistable` (`mica/var/heap.odin`) already
separate values that may live in the kernel from values that may be written
to durable storage; capability values pass the first and fail the second.
`Relation_Durability` (`mica/kernel/relation.odin`) marks a relation
`:durable` or `:volatile` via `make_relation(:Name, n, :volatile)`.

## 4. Reference designs

### 4.1 pagebox

Pagebox is a Rust storage substrate: a swizzled-pointer buffer pool with
anonymous-mmap reservation and a resident budget, a hybrid optimistic latch,
a concurrent B+tree, a WAL with group commit, and a file-backed page store
with a free-page allocator. Relevant ideas, not code:

- fixed-size page identity plus a swizzle word (resident pointer or page id);
- group commit on a log with configurable sync;
- free-page allocation and reuse;
- working set bounded by RAM, cold pages evicted and re-read.

Our chunks play the page role. Because they are immutable, eviction needs no
dirty-page machinery, which removes most of the hard part of pagebox.

### 4.2 moor write handling

`../moor/crates/db/src/engine/moor_db/commit_pipeline.rs` and
`provider/batch_writer.rs` implement a write path that never blocks memory on
I/O:

- `admit_commit` is called **before** the root snapshot is published. Admission
  is a bounded token ring; when it is full, the commit waits under a
  warn/timeout policy and can fail with `DatabaseOverloaded` instead of
  publishing.
- After publish, the encoded batch is enqueued to a bounded channel. Encoder
  threads (up to 8) serialise in parallel; one writer thread persists
  version-ordered batches, holding out-of-order arrivals in a `BTreeMap`
  until gaps fill. The admission token travels with the batch and is returned
  when it has been written.
- `through_version` barriers let callers wait for durability or take
  consistent snapshots.
- Commits prepare in parallel and publish with a CAS, with a bloom-filter
  assisted rebase fast path when losers are disjoint from the winner.

The invariant to copy: **bounded durable capacity is reserved before an effect
becomes visible in memory**. Bounding the queue after publication would let a
slow disk inflate memory through retained chunks and snapshot ancestry.

## 5. Store design

### 5.1 Layers

Build in order; each layer is useful on its own.

**Layer A: boot image and logical WAL.**

- Store directory: `MANIFEST`, `image`, `wal/`.
- Commit: the committer appends the batch's change records plus catalogue
  changes to the WAL, group-syncs per durability mode, then acknowledges.
- Checkpoint: serialise the latest snapshot's durable relations, catalogue,
  rules, named identities, unit sources, and method sources to a new `image`
  file; atomically update `MANIFEST`; truncate the WAL.
- Boot: load the image into a fresh kernel, replay WAL records past the
  checkpoint version, recompute derived relations lazily.

Checkpoints are O(rows) but infrequent. This layer is easy to verify: a world
of any size round-trips through text or binary with no reliance on internal
layouts.

**Layer B: chunk shadow pages.**

- Assign a page id to a chunk the first time it is persisted.
- Checkpoint writes only chunks absent from the previous manifest. New chunks
  are found by pointer-identity diff of the candidate block against its base
  block, which the commit already has.
- A manifest lists, per relation, chunk page ids and row counts, plus
  catalogue metadata, rules, names, and code state; a double-buffered header
  switches manifests atomically.
- WAL still covers commits between checkpoints. Retaining old manifests gives
  point-in-time reads for free; unreferenced pages are reclaimed by a
  mark-sweep over live manifests.

**Layer C: paged chunks and a buffer pool.**

- A chunk reference becomes a swizzle: resident pointer or `(page id,
  length)`. A chunk cache loads on demand and evicts clean chunks under a
  byte budget.
- Fixed-size pages (for example 8 or 16 KiB, splitting `CHUNK_CAPACITY` by
  bytes) would let pages map directly onto a pagebox-style layout. Start with
  variable-length pages; the format already records lengths.
- Optional read-only mmap. Because chunks are immutable, there is no write-back
  and no page-level WAL; crash safety stays at the commit/manifest level.

### 5.2 Commit pipeline

Proposed shape, following moor but bounding bytes rather than commit count:

1. A transaction prepares its candidate as today. While diffing the candidate
   against its base, estimate newly created chunk bytes.
2. `store_admit(bytes)` reserves that many bytes from a bounded durable budget
   (default proposal: 128 MiB). On an empty budget, wait with a warn/timeout
   policy; on timeout, fail the commit with an overload error and do not
   publish.
3. Publish and acknowledge the task as today. Enqueue `{version, change
   record, new chunk references}` to the store writer. This is a hand-off; the
   commit path does not wait for serialisation or fsync.
4. The writer thread persists version-ordered entries, advances
   `durable_version`, and returns the bytes to the budget when the entry is
   durable.
5. `wait_durable(version)` blocks until `durable_version >= version`, for
   shutdown, checkpoints, and tests.

Durability modes:

- `:none` — no store writes, in-memory only.
- `:group` (default) — commits are acked at publish; the writer syncs in
  batches. `wait_durable` still gives a strict barrier on demand.
- `:strict` — the task is acked only after its version is durable.

Persist failures are fatal to the store: refuse further commits and signal a
fatal error, as moor does, rather than continue with a store that may have
gaps. Tests use an in-memory store implementation of the same interface.

### 5.3 Durable state inventory

Durable:

- catalogue metadata: id, name, arity, argument names, indexes, conflict
  policy, durability;
- all tuples of relations marked durable;
- rules: id, head relation, source, active flag (derived rows recomputed);
- `NamedIdentity(identity, name)` facts (new, see below);
- unit sources and `MethodSource` text, or a serialised program;
- symbol directory: symbol id to name, append-only.

Ephemeral (never persisted):

- volatile relations, including the endpoint state relations (`Endpoint`,
  `EndpointActor`, `EndpointPrincipal`, `EndpointProtocol`, `EndpointOpen`),
  which are marked `:volatile` in `system_relation_metadata`;
- bearer capabilities, epochs, subscriptions, mailboxes;
- derived rows, rebuildable from rules;
- function values, which `value_is_persistable` already rejects.

### 5.4 Data model additions

- **`NamedIdentity(identity, name)`** as a durable relation, populated when
  identities are declared, so a file-less boot resolves `#name`. This is
  implemented; `destroy_identity` also removes the binding.
- **`UnitSource(ordinal, unit, source)`** facts persist each loaded file's
  expanded source for `fileout` and for boot-time recompilation in order.
  Implemented.
- **Code**: keep the ordered unit sources and per-method `MethodSource` text,
  and recompile at boot through the existing install path (identity ids come
  from the durable named identities; method ids are allocated above the
  persisted maximum). Persisting a serialised program stays an option if
  startup cost matters.
- **Symbols**: persist the intern table. On boot, re-intern names in id order
  so ids inside persisted values stay valid, or encode names inline and remap
  while loading pages.
- **Catalogue and rule sources**: already plain data; the parser records each
  rule's span, so rule source persists exactly as `describe_rule` returns it.

### 5.5 Format sketch

```
store/
  wal               logical records: {version, writes, catalogue}
  MANIFEST          future: format, generation, durable_version, roots
  image             future: layer A logical snapshot
  pages/            future: layer B append-only chunk pages
```

All integers little-endian, lengths varint or u32. Values use the
`value_is_persistable` subset: null/unit, bool, int, float, string, bytes,
symbol (by name), identity (raw), frob (delegate + value), list, map,
relation, range, error. Strings and byte strings are length-prefixed.

### 5.6 Recovery

1. Read `MANIFEST`; load the newest valid generation (double-buffered header,
   checksummed).
2. Load the image (A) or the relation chunk pages (B) into a kernel snapshot.
3. Replay WAL records with `version > checkpoint`, asserting and retracting in
   version order. Stop at the first checksum or gap failure, truncate the log
   there, and recover to the last contiguous version.
4. On boot, install code from persisted sources in recorded order and
   repopulate the compile context from `NamedIdentity` and catalogue facts.

A checkpoint is safe at any time because published snapshots are immutable:
the writer serialises a snapshot while new commits proceed. The manifest swap
is the atomic publication of the checkpoint; a crash before the swap leaves
the old generation valid and the WAL still covers everything.

## 6. API surface

- `kernel_attach_store(kernel, Store_Options{path, durability, budget})` and
  `kernel_detach_store` (flush and close). Persistence belongs to the kernel
  because commits happen there.
- `kernel_wait_durable(kernel, version)`; a world-level convenience.
- `world_start` continues to load fileins; when a store is attached and
  non-empty, the world boots from it and fileins become additions (the
  `--replace`/unit model can come later on top of `NamedIdentity` and source
  ownership).
- CLI: `tools/filein --store DIR [--durability MODE]`,
  `tools/webhost --store DIR`, `scripts/mud.sh` reads `MICA_STORE`.
- On-disk and in-memory store implementations share one interface so tests
  run without touching the filesystem.

## 7. Testing

- Value round-trip over the persistable subset, including nested containers
  and frobs.
- World round-trip: filein a corpus, checkpoint, reopen, verify facts, rules,
  names, code, and subscriptions still work.
- Crash simulation: write N commits, truncate or corrupt the WAL tail, verify
  recovery to the last contiguous version.
- Admission: fill the byte budget with a stalled writer, verify commits fail
  or wait with the policy, that memory is bounded, and that no commit
  publishes without a reservation.
- Checkpoint under load: commits continue while a checkpoint serialises;
  reading from the pre-checkpoint snapshot stays consistent.
- Differential test: random transaction streams applied to a persistent and a
  fresh in-memory world produce identical snapshot contents.

## 8. Risks and open questions

Risks:

- Symbol and identity stability across boots is the sharpest edge; both
  need deterministic reconstruction or remapping.
- Method identity allocation and program indices must be stable when code is
  recompiled; the persisted maximum identity and recorded unit order control
  this.
- Serialising every durable relation at checkpoint is O(rows); layer A is
  fine for small worlds but layer B should follow before large ones.
- Byte-budget admission interacts with long-running transactions that retain
  old snapshots, delaying chunk reclamation.

Open questions:

1. First milestone: is layer A with `:group` durability enough, or do we go
   straight to chunk pages (B) because we plan large worlds?
2. Code at boot: recompile persisted sources, or persist compiled programs?
3. History: latest manifest only, or retain N generations for point-in-time
   reads?
4. Store shape: single file or directory; variable-length pages or fixed
   page size?
5. Default byte budget and timeout policy for admission.
