# Mica specification: omica status

The Mica specification lives in [timbran-project/mica-spec](https://github.com/timbran-project/mica-spec)
and names no implementation. This page keeps the implementation status that
used to sit inside the drafts: comparisons of omica with Rust mica, parity,
gap and divergence notes, and the omica pull requests they cite. It is a
snapshot as of 2026-09-28; `tools/spec-conformance/known-failures.txt` is the
current list of evidence blocks omica does not pass.

## draft-ndn-authority-00

### Appendix A: Relation to Rust mica

| Behavior | Rust | omica | Class |
|----------|------|-------|-------|
| Direct authority via Can* relations | ✓ | ✓ | Parity |
| Role delegation via Delegates | ✓ | ✓ | Parity |
| Root authority for bootstrap | ✓ | ✓ | Parity |
| Method-identity invoke checks | ✓ | ✓ | Parity |
| Selector-specific invoke checks | ✗ (method identity only) | ✓ | Omica Improvement |
| Capabilities as ephemeral tokens | ✓ | ✓ | Parity |
| Capability revocation (atomic, transitive) | ✓ | ✓ | Parity |
| Capability expiry by deadline (wall-tick) | ✓ | ✓ | Parity |
| Capability expiry by epoch (world version) | ✗ | ✓ | Omica Improvement |
| Mailbox sender-receiver capabilities | ✓ | ✓ | Parity |
| Subscription capabilities | ✓ | ✓ | Parity |
| Assume-actor blocks | ✓ | ✓ | Parity |
| Authority re-computed at task startup only | ✓ | ✓ | Parity |

Rust citations: [crates/vm/src/vm.rs:3595-3632](https://github.com/timbran-project/mica/blob/2bbceb0113b0/crates/vm/src/vm.rs#L3595-L3632) (dispatch candidate filtering), [crates/vm/src/authority.rs:211-218](https://github.com/timbran-project/mica/blob/2bbceb0113b0/crates/vm/src/authority.rs#L211-L218) (can_invoke_method).
Omica citations: [mica/kernel/authority.odin:246-286](https://github.com/rdaum/omica/blob/5a22a77cc245/mica/kernel/authority.odin#L246-L286) (authority minting), [mica/kernel/capability.odin:18-150](https://github.com/rdaum/omica/blob/5a22a77cc245/mica/kernel/capability.odin#L18-L150) (capability lifecycle).

### References (removed implementation-specific entries)

- rdaum/omica#117 (per-method programs)
- rdaum/omica#118 (install authority gate)
- omica/mica/kernel/authority.odin (implementation)
- omica/docs/incremental-maintenance-design.md (epoch tracking)

## draft-ndn-declarations-catalogue-00

### Motivation (removed omica-specific content)

Mica declares identities and relations while the world runs, so one declaration is a language call, a database write and a runtime event. omica resolves declarations in a prescan while parsing a file: a conflicting redeclaration succeeds silently, and `make_relation` returns a value that is not the relation's entity. This RFC makes declarations idempotent, makes conflicts errors, returns entities, and keeps the system relations authoritative.

### Evidence blocks with implementation status

### R-identity-create evidence
| Context | Behavior | Source |
|---------|----------|--------|
| Computed name at runtime | Call succeeds, creating new identity | omica spec issue #111 requirement |
| No name collision | Each identity allocated unique ID from monotonic counter | Both Rust and omica design |

### R-relation-create evidence
| Context | Behavior | Source |
|---------|----------|--------|
| Computed name at runtime | Call succeeds, creating relation with computed name | omica spec issue #110 requirement |

### R-relation-conflict evidence (Scenario references)
| `make_relation(:items, 2)` then `make_relation(:items, 3)` | Second call fails with "conflicting redeclaration: arity mismatch 2 != 3" | Rust validates in ensure_declared_relation; omica D-003 shows it silently succeeds (gap) |
| `make_relation(:items, 2)` then `make_relation(:items, 2, VOLATILE)` | Second call fails with "conflicting redeclaration: durability mismatch" | Rust validates durability; needed for consistency |

### R-functional-create evidence
| Context | Behavior | Source |
|---------|----------|--------|
| Computed name at runtime | Call succeeds with computed name | omica spec issue #110 requirement |

### R-functional-conflict evidence (Scenario references)
| `make_functional_relation(:item, 3, [0, 1])` then `make_functional_relation(:item, 3, [0])` | Second call fails with "conflicting redeclaration: key mismatch" | Rust validates keys in hir_key_positions; omica currently succeeds (gap) |

### R-catalogue-readonly evidence with implementation comparison

| Operation (differential run D-021) | omica 5a22a77 | Rust 2bbceb0 |
|---|---|---|
| `assert Relation(123)` | accepted | rejected: relation is read-only |
| `assert Arity(:foo, 2)`, then `Arity(:foo, ?n)` | accepted; returns `{[2]}` | rejected: relation is read-only |
| `retract RelationName(_, :foo)` (no match) | accepted | accepted |

omica does not meet this requirement yet: its list of read-only system relations ([mica/runtime/runtime.odin:1156-1179](https://github.com/rdaum/omica/blob/5a22a77cc245/mica/runtime/runtime.odin#L1156-L1179)) guards identity destruction, not `assert` and `retract`. Rust rejects writes with an uncatchable error and skips the check when a wildcard retract matches nothing; Ryan Daum's Rust parity plan ([gist](https://gist.github.com/rdaum/4891ed160b0e38e9079744e1f1a0d854)) makes these a catchable `E_READ_ONLY`, empty matches included. An implementation SHOULD raise the same catchable `E_READ_ONLY`.

### R-redeclaration-check evidence with implementation comparison

The evidence: differential D-003 from the spec shows omica silently succeeds on conflicting redeclaration, while Rust correctly errors. This RFC specifies error-on-conflict as the observable behavior.

In Rust mica ([crates/runtime/src/lib.rs:3132-3148](https://github.com/timbran-project/mica/blob/2bbceb0113b0/crates/runtime/src/lib.rs#L3132-L3148)), `ensure_declared_relation()` loops to validate arity and durability; if any mismatch, it errors. In omica before this RFC, `builtin_relation()` is a lookup stub and never errors on arity mismatch. This RFC specifies Rust behavior: error on any structural mismatch.

### R-constructor-returns-identity evidence with implementation comparison

| Call | Rust Returns | omica Before RFC | This RFC Requires |
|------|--------------|------------------|-------------------|
| `make_identity(:foo)` | Identity handle (ID, name binding) | Not yet tested at runtime | Identity handle usable in subsequent declarations |
| `make_relation(:items, 2)` | Relation handle (ID, metadata binding) | Empty relation `[] {}` (D-004 differential) | Relation handle usable in other constructors |

Return values are handles, not introspection results. This enables programmatic composition: code can pass the returned identity to other constructors that depend on it. Evidence: differential D-004 from the spec shows omica returns empty relation `[] {}` (content, not identity); this RFC specifies return of identity/handle.

### Out of Scope (removed PR references)

**Runtime constructor implementation.** This RFC specifies the observable contract: idempotency, conflict detection, return values, authority checks. The implementation — allocation atomicity, transactional staging, concurrent call serialization — is a separate concern. This RFC cites implementation work for reference only.

**Authority enforcement details.** This RFC specifies that admin authority is required for catalogue mutations and denied calls leave state unchanged. The mechanism — authority checks, capability tokens, install gates — is a separate concern.

**Filein and atomic replacement.** This RFC specifies that system relations are read-only and declarations are idempotent. The mechanics — retracting old facts, loading new source atomically, handling concurrent readers — is a separate concern.

### Compatibility (removed omica-specific migration guidance)

This RFC aligns omica with Rust mica. Existing omica code that relies on silent success for conflicting redeclarations will now receive errors. Migration: ensure redeclarations match existing metadata, or add guard clauses to handle errors.

Code that expects return values to be relation content (iterating over facts returned from `make_relation`) will break. Migration: use catalogue relations (Arity, ConflictPolicy, etc.) to query metadata; query relation facts separately.

### References (removed PR references)

- rdaum/omica#110: Runtime relation creation contract
- rdaum/omica#111: Runtime identity creation contract
- rdaum/omica#117: Filein into running world and atomic replace mode
- rdaum/omica#118: Runtime constructors, allocation, and install authority gate

## draft-ndn-hosts-00

### Relation to Rust Mica

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

### Motivation (removed implementation-specific content)

Filing to a running world (rdaum/omica#117) works via CLI only. Concurrent calls crashed the world until rdaum/omica#119 made shared structures allocate thread-safely.

### What Matters for Live Worlds (removed PR references)

1. **Filing into a running world (#117)**: External code must submit source via host endpoint. CLI-only filein blocks live patching.

2. **Concurrent host calls (#119)**: Multiple endpoints must not corrupt state. The host layer must not add shared state outside the world.

### Recommended Adoption Path (removed PR references)

1. **Remote SubmitSource**: Expose world_filein (#117) as a host message.

### References (removed implementation-specific links)

- **omica host/web**: https://github.com/rdaum/omica/tree/5a22a77cc245/host/web ([host/web/sync_protocol.odin:1-97](https://github.com/rdaum/omica/blob/5a22a77cc245/host/web/sync_protocol.odin#L1-L97))
- **PR #117**: https://github.com/rdaum/omica/pull/117 (per-method programs; filein into a running world)
- **PR #119**: https://github.com/rdaum/omica/pull/119 (thread-safe allocation in everything a world shares)
- **PR #118**: https://github.com/rdaum/omica/pull/118 (runtime make_identity/make_relation, program registry, install authority gate)
- **MSY1 specification**: [host/web/sync_protocol.odin:42-97](https://github.com/rdaum/omica/blob/5a22a77cc245/host/web/sync_protocol.odin#L42-L97) (omica implementation); [crates/host-protocol/src/sync.rs](https://github.com/timbran-project/mica/blob/2bbceb0113b0/crates/host-protocol/src/sync.rs) (Rust reference).
- **Session/actor mapping**: [host/web/auth.odin:1-80](https://github.com/rdaum/omica/blob/5a22a77cc245/host/web/auth.odin#L1-L80) (omica); [crates/web-host/src/auth.rs:1-80](https://github.com/timbran-project/mica/blob/2bbceb0113b0/crates/web-host/src/auth.rs#L1-L80) (Rust).

## draft-ndn-language-00


### table for R-len-string

<!-- evidence: @R-len-string -->
| Input | omica | Rust 2bbceb0 |
|---|---|---|
| `len([1, 2, 3])` | `3` | `3` |
| `len({:a -> 1, :b -> 2})` | `2` | `2` |
| `len("héllo")` | `5` | error: len expects a list, map, or relation |

### table for R-string-index-scalar

<!-- evidence: @R-string-index-scalar -->
| Input | omica | Rust 2bbceb0 |
|---|---|---|
| `"héllo"[0]` | `104` | `E_INDEX` |
| `"héllo"[1]` | `233` | `E_INDEX` |
| `"hello"[10]` | `E_INDEX` | `E_INDEX` |

### table for R-string-builtins

<!-- evidence: @R-string-builtins -->
| Input | omica | Rust 2bbceb0 |
|---|---|---|
| `string_append("hello", " world")` | `"hello world"` | no applicable method |
| `string_span("hello world", 0, " ")` | `0` | no applicable method |
| `string_find_any("hello world", 0, " o")` | `4` | no applicable method |

### table for R-loop-patterns

<!-- evidence: @R-loop-patterns -->
| Input | omica | Rust 2bbceb0 |
|---|---|---|
| `for [a, b] in [[1, 2], [3, 4]]` appending `a + b` | `[3, 7]` | parse error: expected expression |
| `for _ in [1, 2, 3]` counting iterations | `3` | parse error: expected expression |

### table for R-list-comprehension

<!-- evidence: @R-list-comprehension -->
| Input | omica | Rust 2bbceb0 |
|---|---|---|
| `[x * 2 for x in [1, 2, 3]]` | `[2, 4, 6]` | parse error: expected end after for |

### replaced text

Omica's language layer has three gaps: recover expressions lack parsing and compilation; match exhaustiveness is unchecked at compile time; catch clauses don't support dynamic patterns or guards. This RFC closes these gaps by adopting Rust's semantics while preserving omica's extensions (optional/rest verb parameters, rule-management/capability builtins).

### replaced text

Defines: (1) recover expressions (D-007); (2) match exhaustiveness checking (D-008); (3) catch patterns and guards (D-009); (4) verb dispatch semantics (D-015, #117). References runtime compile builtin (#118) without redesigning it.

### replaced text

; omica supports both, Rust mica does not. [R-verb-param-extended]

### replaced text

compiles source at runtime (issue #118). This RFC

### replaced text

The `compile` builtin inherits caller context per RFC #118.

### replaced text

**Why keep omica's parameters?** Existing omica code uses defaulted and rest parameters; dropping them to match Rust would break it.

### Strings, Loops and Comprehensions

These forms run in omica and are rejected by Rust mica at 2bbceb0. Ryan Daum's Rust parity plan ([gist](https://gist.github.com/rdaum/4891ed160b0e38e9079744e1f1a0d854)) found the same set and adds them to Rust. Results below are differential runs D-013 and D-015 to D-019.

### Appendix A: Relation to Rust mica

| Behavior | Rust | omica | This RFC | Class |
|----------|------|-------|----------|-------|
| Recover expressions | AST, codegen | Lexed only | Full | Gap → Parity |
| Match exhaustiveness | Checked | No | Yes | Gap → Parity |
| Catch patterns (dynamic) | Yes | No | Yes | Gap → Parity |
| Catch guards | Yes | No | Yes | Gap → Parity |
| Optional verb params | No | Yes | Yes | Keep divergence |
| Rest verb params | No | Yes | Yes | Keep divergence |
| Per-method dispatch | Yes | Yes | Yes | Parity |
| Closures as values | Yes | Yes | Yes | Parity |
| Runtime compile | Yes | No | Reference (#118) | Gap → #118 |
| `len` on strings | No | Yes | Yes | Improvement |
| String indexing by scalar | No | Yes | Yes | Improvement |
| `string_append`, `string_span`, `string_find_any` | No | Yes | Yes | Improvement |
| Loop list patterns and `_` | No | Yes | Yes | Improvement |
| List comprehensions | No | Yes | Yes | Improvement |

---

**Citation style for evidence:** All test vector transcripts use `tools/filein --eval` format from the omica repository, matching the test runner contract in draft-ndn-evidence-adapters-00.

### Motivation

omica lacks three features Rust mica has: `recover` expressions, compile-time match exhaustiveness, and catch clauses with patterns and guards. Code written for Rust mica fails to compile in omica or needs rewriting. The project decided to close all three gaps with Rust's semantics and keep omica's extensions.

## draft-ndn-relational-objecthood-00


### References (implementation links) removed:
- rdaum/omica#120 (sources and lineage table)
- rdaum/omica#135 (values.md and verbs-roles-dispatch.md)
- rdaum/omica#134 (objecthood views fix)

### Appendix A: Coverage and gaps (non-normative)

This appendix was removed as it compares implementation status across Rust mica and omica.

| Requirement | Mica book | Rust mica | omica | Gap |
|---|---|---|---|---|
| R-handle-poor | defined (`values.md`, identities) | meets | meets | none |
| R-handle-equality | defined (`values.md`: equivalence is a modelled relationship) | meets | meets | none |
| R-equivalence-claims | not defined: the book shows a domain claim but not purpose- or authority-bound equivalence or its closure | expressible with user relations and rules | same | **spec**: defined by rdaum/omica#135 (`values.md`) |
| R-delegation-explicit | partly: `Delegates` feeds dispatch matching (`frobs.md`, `verbs-roles-dispatch.md`); that reads never follow it, and that defaults are named rules, is unwritten | behaves so; dot read raises `E_CARDINALITY` | behaves so; dot read raises `E_KEY` | **spec**: defined by rdaum/omica#135 (`verbs-roles-dispatch.md`); **omica**: dot read should raise `E_CARDINALITY` as the book says (`keyed-relations.md`), not `E_KEY` |
| R-objecthood-views | defined (`runtime/catalogue-and-introspection.md`) | meets | returns no rows on main | **omica**: fixed by rdaum/omica#134 |
| R-claim-history | not defined (buffer text provenance only) | absent | absent | **spec**: needs design (interface, retention, authority) |
| R-unnamed-handles | not defined: the numeric `#12345` literal form exists, but no way to make such a handle | absent | absent | **spec**: needs design |

### Implementation-specific mentions removed:

- Line 295: Removed reference to `docs/specs/index.md` (rdaum/omica#120)
- Lines 299-315: Removed entire Appendix A with Rust mica / omica comparison table
- Removed implementation status notes from table rows

## draft-ndn-rules-derivation-00


### Appendix A: Relation to Rust mica

| Behavior | Rust | omica today | This RFC | Class |
|----------|------|-------------|----------|-------|
| Unbound head variable validation | Lazy: install succeeds, first read fails with `UnboundHeadVariable` error | Eager: install fails with `Unbound_Head_Variable` error | Eager validation at install time (Rust behavior changes to match omica) | Improvement |
| `_` holes in positive rule bodies | rejected at parse at 2bbceb0; independent anonymous variables at a433170 | independent anonymous variables | independent anonymous variables | Parity (at a433170) |
| Stratification validation | At install time, rejects unstratified rules | At install time, rejects unstratified rules | At install time (no change) | Parity |
| Negation and guard safety (unbound terms) | Unsafe negation installs, then the first read fails with `E_DB UnsafeNegation`; a comparison on a query variable is rejected at parse | Rejected at install: `Unsafe_Negation`, `Unsafe_Guard` | Rejected at install ([R-unsafe-negation-guard]) | Improvement (differential run D-022) |
| Guard safety check (unbound operands) | At evaluation time, fails | At evaluation time, fails | At evaluation time (no change) | Parity |
| Non-recursive evaluation (stratified) | Single pass through strata | Single pass or fixpoint with 1 iteration | Stratified single-pass semantics (no change) | Parity |
| Recursive evaluation (fixpoint) | Semi-naive: seed + delta rounds until convergence | Semi-naive: seed + delta rounds until convergence | Semi-naive fixpoint (no change) | Parity |
| Join equality semantics | Canonical Value equality (int(1) ≠ float(1.0)) | Canonical Value equality (int(1) ≠ float(1.0)) | Canonical equality in joins; numeric equality in guards (no change) | Parity |
| Derived relation visibility | Union of extensional + derived, consistent snapshot | Union of extensional + derived, consistent snapshot | Union with consistency guarantee (no change) | Parity |
| Transaction read-your-writes for derived | Evaluates rule over txn view, caches result | Evaluates rule over txn view, caches result | Consistent semantics (no change) | Parity |
| Incremental maintenance | Lazy differential: weighted deltas, maintained after first read | Full fixpoint recompute on every commit (Stage 1: blocks + COW) | Observable guarantee only; algorithm deferred to incremental-maintenance design | Gap → Scheduled |
| Derived state persistence | Separate from extensional; fingerprint-based recovery (planned) | Separate from extensional; always re-derived | Never persist derived facts; re-derive on restart (no change) | Parity |
| Rule enable/disable | Supported; recomputes derived relations | Supported; recomputes derived relations | Supported (no change) | Parity |
| Evaluation strategy | lazy differential maintenance after first read | full recompute per commit | undeclared; any strategy, same answer (draft-ndn-demand-evaluation-00) | Parity (answers) |
| Cache invalidation strategy | Explicit on rule install | Implicit (no persistent cache) | Not specified; implementations may vary | Implementation-defined |
| Rejection error code (`E_RULE`, proposed) | unsafe rules fail on first read with `E_DB` | rejected at load with a message, no code | raised in the installing task | **spec**: the book says rejected but names no code |
| `enable_rule` | only `disable_rule` | has `enable_rule` | defined | **rust**: the book defines it; Rust mica lacks it |
| Rule toggles before commit | both `ActiveRule` and answers unchanged until commit | `ActiveRule` changes, answers do not | activation and answers agree within the task; read-your-writes vs at-commit is open | **omica**: reads disagree within the task |

### Implementation-specific references removed:

- Line 20: Removed comparison of Rust mica vs omica validation timing
- Line 136: Removed reference to "Rust mica at a433170 does not implement it"
- Line 159: Removed statement about omica satisfying neither choice
- Lines 352-354: Removed references to rdaum/omica#125, rdaum/omica#118, rdaum/omica#136
- Lines 357-378: Entire Appendix A comparing Rust and omica implementations

### References (implementation links) removed:
- rdaum/omica#125 (incremental maintenance)
- rdaum/omica#118 (rule authority)
- rdaum/omica#136 (evaluation strategy)
### Appendix A: Relation to Rust mica

| Behavior | Rust | omica today | This RFC | Class |
|----------|------|-------------|----------|-------|
| Unbound head variable validation | Lazy: install succeeds, first read fails with `UnboundHeadVariable` error | Eager: install fails with `Unbound_Head_Variable` error | Eager validation at install time (Rust behavior changes to match omica) | Improvement |
| `_` holes in positive rule bodies | rejected at parse at 2bbceb0; independent anonymous variables at a433170 | independent anonymous variables | independent anonymous variables | Parity (at a433170) |
| Stratification validation | At install time, rejects unstratified rules | At install time, rejects unstratified rules | At install time (no change) | Parity |
| Negation and guard safety (unbound terms) | Unsafe negation installs, then the first read fails with `E_DB UnsafeNegation`; a comparison on a query variable is rejected at parse | Rejected at install: `Unsafe_Negation`, `Unsafe_Guard` | Rejected at install ([R-unsafe-negation-guard]) | Improvement (differential run D-022) |
| Guard safety check (unbound operands) | At evaluation time, fails | At evaluation time, fails | At evaluation time (no change) | Parity |
| Non-recursive evaluation (stratified) | Single pass through strata | Single pass or fixpoint with 1 iteration | Stratified single-pass semantics (no change) | Parity |
| Recursive evaluation (fixpoint) | Semi-naive: seed + delta rounds until convergence | Semi-naive: seed + delta rounds until convergence | Semi-naive fixpoint (no change) | Parity |
| Join equality semantics | Canonical Value equality (int(1) ≠ float(1.0)) | Canonical Value equality (int(1) ≠ float(1.0)) | Canonical equality in joins; numeric equality in guards (no change) | Parity |
| Derived relation visibility | Union of extensional + derived, consistent snapshot | Union of extensional + derived, consistent snapshot | Union with consistency guarantee (no change) | Parity |
| Transaction read-your-writes for derived | Evaluates rule over txn view, caches result | Evaluates rule over txn view, caches result | Consistent semantics (no change) | Parity |
| Incremental maintenance | Lazy differential: weighted deltas, maintained after first read | Full fixpoint recompute on every commit (Stage 1: blocks + COW) | Observable guarantee only; algorithm deferred to incremental-maintenance design | Gap → Scheduled |
| Derived state persistence | Separate from extensional; fingerprint-based recovery (planned) | Separate from extensional; always re-derived | Never persist derived facts; re-derive on restart (no change) | Parity |
| Rule enable/disable | Supported; recomputes derived relations | Supported; recomputes derived relations | Supported (no change) | Parity |
| Evaluation strategy | lazy differential maintenance after first read | full recompute per commit | undeclared; any strategy, same answer (draft-ndn-demand-evaluation-00) | Parity (answers) |
| Cache invalidation strategy | Explicit on rule install | Implicit (no persistent cache) | Not specified; implementations may vary | Implementation-defined |
| Rejection error code (`E_RULE`, proposed) | unsafe rules fail on first read with `E_DB` | rejected at load with a message, no code | raised in the installing task | **spec**: the book says rejected but names no code |
| `enable_rule` | only `disable_rule` | has `enable_rule` | defined | **rust**: the book defines it; Rust mica lacks it |
| Rule toggles before commit | both `ActiveRule` and answers unchanged until commit | `ActiveRule` changes, answers do not | activation and answers agree within the task; read-your-writes vs at-commit is open | **omica**: reads disagree within the task |

### Appendix A: Relation to Rust mica (removed)

[Full table and comparison data moved to status-extract]

## draft-ndn-source-git-00


### Abstract and Motivation rewordings:

Original abstract:
"This RFC specifies three computed relations for omica's source host: `source/CommitLog`, `source/ChangedFiles`, `source/FileHistory`."

Changed to be implementation-neutral.

Original motivation:
"omica exposes repository state as relations but not git history. The quality-tool RFC (rdaum/omica#109) requires fix-commit counts per file and file change deltas for defect density."

Changed to be implementation-neutral.

### References (implementation links) removed:

- Line 148: Rust mica source-provider references to specific code locations
- Line 149: rdaum/omica#109 (quality-tool RFC)
- Line 150: [host/source/index.odin] reference to omica implementation

### Appendix: Relation to Rust mica

This appendix was removed as it compares implementation status across Rust mica and omica.

| Behavior | Rust | omica today | This RFC | Class |
|----------|------|-------------|----------|-------|
| CommitLog relation | L403-L427 | Not implemented | Computed on demand, 512-commit bound | Gap → Parity |
| ChangedFiles relation | L337-L371 | Not implemented | Computed on demand, 3 bindings required | Gap → Parity |
| FileHistory relation | L474-L517 | Not implemented | Computed on demand, 512-commit bound | Gap → Parity |
| Bounded walk | L16 | Not applicable | 512-commit limit per relation | Gap → Parity |
| Read-only access | No .git write | N/A | Read-only computed views | Parity |
| Path confinement | No validation | Not applicable | Escapes rejected; E_PATH_ESCAPE error | Improvement |

### Implementation-specific mentions removed:

- Line 16: "omica's source host" → made implementation-neutral
- Line 21: "omica exposes repository state" and rdaum/omica#109 reference
- Lines 148-150: Implementation-specific source file references
- Lines 153-162: Entire Appendix comparing implementations

## draft-ndn-transactions-changelog-00


### References (implementation links) removed:

- Line 378: **Rust Mica, [crates/relation-kernel/src/transaction.rs](https://github.com/timbran-project/mica/blob/2bbceb0113b0/crates/relation-kernel/src/transaction.rs)** — https://github.com/rdaum/mica (reference implementation)

This reference was removed as it explicitly calls out a specific implementation repository and source files.

## draft-ndn-units-00


### transcript for R-slots-persist

```transcript @R-slots-persist
$ mkdir -p /tmp/test_persist && tools/filein --store /tmp/test_persist --unit=:web --eval '
let api_key = "sk-1234"
let retry_count = 3
'
$ tools/filein --store /tmp/test_persist --unit=:web --eval '
UnitSlot(:web, N, V) -> {slot: N, value: V}
'
{slot: api_key, value: sk-1234}
{slot: retry_count, value: 3}
$ tools/filein --store /tmp/test_persist --boot --eval '
UnitSlot(:web, N, V) -> {slot: N, value: V}
'
{slot: api_key, value: sk-1234}
{slot: retry_count, value: 3}
? 0
```

### transcript for R-name-resolution

```transcript @R-name-resolution
$ tools/filein --eval '
make_identity(:web)
let config = {timeout: 30}
let get_config = verb() { config }
get_config()
'
{timeout: 30}
$ tools/filein --eval '
make_identity(:web)
let config = {timeout: 30}
let shadowed_config = verb() { let config = {timeout: 60}; config }
shadowed_config()
'
{timeout: 60}
? 0
```

### transcript for R-slot-authority

```transcript @R-slot-authority
$ mkdir -p /tmp/test_auth && tools/filein --store /tmp/test_auth --unit=:web --eval '
let counter = 0
'
$ tools/filein --store /tmp/test_auth --unit=:admin --eval '
assign :web "counter" 10
'
error: E_PERMISSION: unit :admin cannot assign slot of unit :web
? 1
$ tools/filein --store /tmp/test_auth --unit=:web --eval '
assign :web "counter" 10
'
$ tools/filein --store /tmp/test_auth --unit=:web --eval '
UnitSlot(:web, "counter", V) -> V
'
10
? 0
```

### transcript for R-slot-assign

```transcript @R-slot-assign
$ tools/filein --unit=:web --eval '
let counter = 0
let increment = verb() {
  UnitSlot(:web, "counter", X) -> assign :web "counter" (X + 1)
}
increment()
UnitSlot(:web, "counter", Y) -> Y
'
1
$ tools/filein --unit=:web --eval '
UnitSlot(:web, "counter", Z) -> Z
'
1
? 0
```

### transcript for R-add-live

```transcript @R-add-live
$ mkdir -p /tmp/test_add && tools/filein --store /tmp/test_add --unit=:auth --eval '
let secret = "auth-key"
let verify = verb(user) { user }
'
$ tools/filein --store /tmp/test_add --unit=:web --eval '
let config = {timeout: 30}
'
$ tools/filein --store /tmp/test_add --unit=:auth --eval '
UnitSlot(:auth, N, V) -> {auth_slot: N}
'
{auth_slot: secret}
$ tools/filein --store /tmp/test_add --unit=:web --eval '
UnitSlot(:web, N, V) -> {web_slot: N}
'
{web_slot: config}
? 0
```

### transcript for R-replace-keeps-declared

```transcript @R-replace-keeps-declared
$ mkdir -p /tmp/test_keep && tools/filein --store /tmp/test_keep --unit=:cfg --eval '
let timeout = 30
let port = 8080
let debug = true
'
$ tools/filein --store /tmp/test_keep --unit=:cfg --eval '
let timeout = 60
let port = 9000
'
$ tools/filein --store /tmp/test_keep --unit=:cfg --eval '
UnitSlot(:cfg, N, V) -> {slot: N, value: V}
'
{slot: timeout, value: 60}
{slot: port, value: 9000}
? 0
```

### transcript for R-replace-failure-safety

```transcript @R-replace-failure-safety
$ mkdir -p /tmp/test_replace && tools/filein --store /tmp/test_replace --unit=:cfg --eval '
let timeout = 30
let port = 8080
'
$ tools/filein --store /tmp/test_replace --unit=:cfg --eval '
UnitSlot(:cfg, timeout, T) -> UnitSlot(:cfg, port, P) -> {timeout: T, port: P}
'
{timeout: 30, port: 8080}
$ tools/filein --store /tmp/test_replace --unit=:cfg --eval '
let timeout = 60
let port = 9000
let fail = error("replace fails mid-way")
'
$ tools/filein --store /tmp/test_replace --unit=:cfg --eval '
UnitSlot(:cfg, timeout, T) -> UnitSlot(:cfg, port, P) -> {timeout: T, port: P}
'
{timeout: 30, port: 8080}
? 0
```

### transcript for R-fileout-roundtrip

```transcript @R-fileout-roundtrip
$ mkdir -p /tmp/test_rt && tools/filein --store /tmp/test_rt --unit=:lib --eval '
make_identity(:lib)
let version = "1.0"
let enabled = true
'
$ tools/fileout --store /tmp/test_rt --unit=:lib > /tmp/lib.mica
$ mkdir -p /tmp/test_rt2 && tools/filein --store /tmp/test_rt2 < /tmp/lib.mica
$ tools/filein --store /tmp/test_rt2 --unit=:lib --eval '
UnitSlot(:lib, N, V) -> {slot: N, value: V}
'
{slot: version, value: 1.0}
{slot: enabled, value: true}
? 0
```

### transcript for R-drift-detect

```transcript @R-drift-detect
$ tools/filein --unit=:web --eval '
let config = {timeout: 30}
UnitSlot(:web, "config", V) -> V
'
{timeout: 30}
$ tools/filein --unit=:admin --eval '
retract UnitSlot(:web, "config", {timeout: 30})
assert UnitSlot(:web, "config", {timeout: 60})
'
$ tools/filein --eval '
UnitSlot(:web, "config", V) -> V
'
{timeout: 60}
? 0
```

### replaced

This RFC specifies omica's unit model:

### replaced

MUST be reported in the quality tool (RFC #109).

### replaced

**Install authority gate (PR #118):** authority to file source, make_identity/make_relation, program registry, and install gate.

### replaced

**Quality tool implementation (PR #109):** this RFC names quality-tool responsibilities (drift detection) but does not specify implementation.

### replaced

authority to file source is gated by PR #118;

### replaced

**Backward compatibility:** omica's semantics match Rust's design; this RFC codifies them and extends minimal implementation.



### replaced



**Status (September 2026):** unit state is not yet implemented in omica; this RFC guides development.

### reference

- - PR rdaum/omica#117: [Filing into a running world](https://github.com/rdaum/omica/pull/117) — per-method programs and world_filein primitives

### reference

- - PR rdaum/omica#118: [Install authority and source registry](https://github.com/rdaum/omica/pull/118) — make_identity, make_relation, compile, install_source, program registry, and install gate

### reference

- - [Per-method programs design](https://rdaum.github.io/omica/docs/per-method-programs-design.md) — unit identity and verbs in omica

### reference

- - [Incremental maintenance design](https://rdaum.github.io/omica/docs/incremental-maintenance-design.md) — snapshot versioning for Replace mode atomicity

### references

- PR rdaum/omica#117: [Filing into a running world](https://github.com/rdaum/omica/pull/117) — per-method programs and world_filein primitives
- PR rdaum/omica#118: [Install authority and source registry](https://github.com/rdaum/omica/pull/118) — make_identity, make_relation, compile, install_source, program registry, and install gate
- [Per-method programs design](https://rdaum.github.io/omica/docs/per-method-programs-design.md) — unit identity and verbs in omica
- [Incremental maintenance design](https://rdaum.github.io/omica/docs/incremental-maintenance-design.md) — snapshot versioning for Replace mode atomicity

## draft-ndn-values-equality-00


### table

| Input | omica | Rust 2bbceb0 |
|---|---|---|
| `parse_int("42")` | `42` | no applicable method |
| `parse_int("abc")` | `E_INVARG`: parse_int found no digits | no applicable method |
| `parse_int("999999999999999999")` | `E_INVARG`: parse_int is out of range | no applicable method |


### table

| Input | omica | Rust 2bbceb0 |
|---|---|---|
| `parse_float("3.14")` | `3.14` | no applicable method |
| `parse_float("1.0e2")` | `100` | no applicable method |
| `parse_float("NaN")` | `E_INVARG`: parse_float is out of range | no applicable method |


### table (Behavior | Rust | omica | RFC)

| Behavior | Rust | omica | RFC |
|----------|------|-------|-----|
| Range [-2^55, 2^55-1] | Enforced | Enforced | MUST enforce |
| Overflow rejection | ValueError | ValueError | MUST reject |
| Silent truncation | No | No | MUST NOT |

### table (Behavior | Rust | omica | RFC)

| Behavior | Rust | omica | RFC |
|----------|------|-------|-----|
| binary32 domain | Yes | Yes | MUST |
| Reject NaN/Infinity | Yes | Yes | MUST |
| Canonicalize -0.0 | Yes | Yes | MUST |
| Reject subnormals | Yes | Yes | MUST |

### table (Behavior | Rust 2bbceb0 | omica | This RFC | Class)

| Behavior | Rust 2bbceb0 | omica | This RFC | Class |
|---|---|---|---|---|
| `parse_int`, `parse_float` | No | Yes | Yes | Improvement |
| `to_int` on an exactly integral float; `E_TYPE` otherwise | Yes | Yes | Yes | Parity |
| `to_float` | Yes (prints `4.2e1`) | Yes (prints `42`) | Yes | Parity; float literal printing differs |

### Numeric Conversion Builtins

Both exist in omica and not in Rust mica at 2bbceb0; Ryan Daum's Rust parity plan ([gist](https://gist.github.com/rdaum/4891ed160b0e38e9079744e1f1a0d854)) adds them. `to_int` and `to_float` behave the same in both (differential run D-014).

### Compatibility

RFC formalizes current behavior; Rust and omica implementations already match (differential D-006). No data or code changes required;

### Appendix A: Relation to Rust mica

| Behavior | This RFC | Class |
| --- | --- | --- |
| `parse_int`, `parse_float` | Yes | Improvement |
| `to_int` on an exactly integral float; `E_TYPE` otherwise | Yes | Parity |
| `to_float` | Yes | Parity; float literal printing differs |

### Motivation

Differential run D-006 found omica and Rust mica agree on int/float join equality.

## draft-ndn-casts-and-literals-00

Text removed when the draft became implementation-neutral (before, as it read):

> Ryan Daum is working toward one normative form across Mica
> implementations. Differential runs of `to_literal` on omica 5a22a77 and
> Rust mica a433170 agree on integers, strings, simple symbols, lists,
> ranges and relations, and disagree on:
> | Value | omica | Rust mica | Problem |
> |---|---|---|---|
> | `1.0` | `1` | `1e0` | omica's text reads back as an integer |
> | `100.0` | `100` | `1e2` | two float spellings |
> | `0.0` | `0` | `0.0` | Rust mixes positional and exponent forms |
> | `1.0e20` | `1e+20` | `1e20` | exponent sign spelling |
> | `:"with space"` | `:with space` | `:"with space"` | omica's text cannot be read back |
> | `ok(1)` | `[:case, :value] {…}` | `[:value, :case] {…}` | heading order differs |
> | `{:alpha -> 1, :value -> 2}` | `:alpha` first | `:value` first | Rust orders symbols by interning |
> The last two rows show that "canonical order" is decided by the order
> in which each runtime happened to intern symbols. Separately, the
> language compares `1 == 1.0` as true and orders `1 < "a"` across kinds,
> so equality silently converts between kinds even though arithmetic
> already refuses to (`1 + 1.5` raises `E_TYPE`).
> - rdaum/omica#127 — the book harness; the book's cast examples are listed as known failures until an implementation supports them.

## draft-ndn-demand-evaluation-00

Text removed when the draft became implementation-neutral (before, as it read):

> ## Appendix A: Coverage (non-normative)
> | Requirement | Mica book | Rust mica | omica |
> |---|---|---|---|
> | R-eval-independence | `rules.md` (least fixpoint; this draft's PR adds the strategy rule) | meets (lazy differential maintenance) | meets (recompute per commit) |
> | R-demand-terminates | `rules.md` recursion | meets bottom-up; no demand evaluation | same |
> | R-negation-any-strategy | `rules.md` stratified negation | meets | meets |
> | R-current-view | `rules.md` | meets | meets |
> | R-watched-and-hints | not in the book | subscriptions maintained | change feed; no hints |
> On-demand evaluation itself exists in neither implementation. Because
> it cannot change an answer, that is an optimization still to build, not
> a specification gap.

## draft-ndn-error-hierarchy-00

Text removed when the draft became implementation-neutral (before, as it read):

> but the code no longer says what went wrong. omica already raises
> Rust mica raises `E_INDEX` for map keys and omica raises `E_KEY`; neither
>    Rust's `EnterTry` catch entries (`[error_code, binding_register, target]`)
>    match codes exactly. Whether assembly catch entries match by ancestry, and

## draft-ndn-live-collaboration-00

Text removed when the draft became implementation-neutral (before, as it read):

> differently. Transaction cost is not the obstacle: on omica, one task
> (September 2026), omica accepts them only with rdaum/omica#138.
> - rdaum/omica#138 — durations in seconds, integer or float.

