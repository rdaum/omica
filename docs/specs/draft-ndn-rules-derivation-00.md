# draft-ndn-rules-derivation-00: Rules and Derivation

**Status:** DRAFT

**Corpus:** red (spec-first; evidence is the acceptance criteria)

**Category:** Standards-Track

**Authors:** Norman Nunley, Jr. <nnunley@gmail.com>


## Abstract

This RFC specifies rule safety validation, installation mechanics, evaluation strategies (stratified and semi-naive), visibility guarantees, and activation modes (eager vs demand).


## Motivation

Mica is a database, a programming language, and a runtime; the live world is the source of truth. Rules transform this world by deriving new facts.

Rust mica defers safety checks until first read, failing on queries that looked safe. omica validates at install and rejects unsafe rules immediately. This RFC settles safety timing, visibility, and activation modes.


## Terminology

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD",
"SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this
document are to be interpreted as described in BCP 14 (RFC 2119, RFC 8174)
when, and only when, they appear in all capitals, as shown here.

- **rule** — A Datalog-style declaration: head relation :- body conditions. Asserts head tuples when all body conditions hold.
- **derived relation** — A relation populated by active rules; contains no directly asserted facts.
- **extensional fact** — A tuple directly asserted into a relation (not derived).
- **derived fact** — A tuple produced by evaluating a rule body.
- **stratum** — A level in the rule dependency graph; stratification ensures negation depends only on lower strata, preventing circular negation.
- **semi-naive evaluation** — Fixpoint evaluation that re-evaluates only rules affected by newly derived tuples (delta), not all rules with all tuples.
- **snapshot** — An immutable point-in-time view of the relation state, including both extensional and derived facts.
- **activation mode** — The evaluation strategy for a relation: eager (all rules evaluated at every commit) or demand (rules evaluated only when queried).


## Specification

**Live installation.** Rules are installed, validated, derived, and published atomically while readers at earlier snapshots see their consistent view uninterrupted.


### Rule Validation at Installation

The system MUST reject any rule at installation time if it violates safety constraints. [R-install-time-safety]

```transcript @R-install-time-safety
$ make_identity :alice
$ make_relation :Person 1
$ make_relation :Out 1
$ assert Person(#alice)
$ Out(?x) :- Person(#alice)
ERROR: rule install failed: Unbound_Head_Variable
```

The system MUST reject a rule if any variable appears in its head but is not bound by any body atom. [R-unbound-head-reject]

```transcript @R-unbound-head-reject
$ Out(?x) :- Person(#alice)
ERROR: rule install failed: Unbound_Head_Variable
```

The system MUST reject a rule if a negated atom contains an unbound variable or if a comparison guard references an unbound operand. [R-unsafe-negation-guard]

```transcript @R-unsafe-negation-guard
$ make_relation :P 1
$ make_relation :Q 1
$ Q(?x) :- not P(?y)
ERROR: rule install failed: Unsafe_Negation
```

The system MUST reject a rule set if negation over a relation R would create a cycle in the rule dependency graph (stratification failure). [R-stratification]

```transcript @R-stratification
$ make_relation :P 1
$ make_relation :Q 1
$ P(?x) :- Q(?x)
$ Q(?x) :- not P(?x)
ERROR: rule install failed: Unstratified_Negation
```


**Holes in rule bodies.** Each `_` in a positive body atom MUST act as its own anonymous variable, matching any value independently of every other `_`. [R-rule-body-hole]

<!-- evidence: @R-rule-body-hole -->
| Rule, over `R(#a, 1, 2)` and `R(#b, 3, 3)` | omica | Rust 2bbceb0 |
|---|---|---|
| `P(?x) :- R(?x, _, _)`, then `P(?x)` | `{[#a], [#b]}` | rejected at parse: holes are not valid here |

### Rule Installation and Lifecycle

When a rule is installed, the system MUST atomically publish a new snapshot containing the rule's effects. [R-atomic-install]

Validate, acquire lock, fork snapshot, add rule, compute relations, CAS new snapshot as current. Readers at earlier snapshots continue uninterrupted.

```transcript @R-atomic-install
$ make_identity :a :b
$ make_relation :E 2
$ make_relation :P 2
$ assert E(#a, #b)
$ P(?x, ?y) :- E(?x, ?y)
loaded
$ return P(?x, ?y)
[:x, :y] {[#a, #b]}
```

A disabled rule can later be re-enabled, triggering the same atomic recomputation. [R-enable-disable-retrigger]

```transcript @R-enable-disable-retrigger
$ disable_rule
$ return P(?x, ?y)
[:x, :y] {}
$ enable_rule
$ return P(?x, ?y)
[:x, :y] {[#a, #b]}
```

The system MUST support disabling a rule (setting its active flag to false) without removing it from the catalog. [R-disable-without-removal]

Disabled rule facts are removed; rule definition persists.

```transcript @R-disable-without-removal
$ make_relation :Active 1
$ make_relation :P 1
$ P(?x) :- Active(?x)
$ assert Active(#a)
$ return P(?x)
[:x] {[#a]}
$ disable_rule
$ return P(?x)
[:x] {}
$ enable_rule
$ return P(?x)
[:x] {[#a]}
```

Facts derived only through disabled rules MUST no longer appear; facts still derived by active rules MUST remain. [R-disable-removes-facts]

```transcript @R-disable-removes-facts
$ disable_rule
$ return P(?x, ?y)
[:x, :y] {}
```



### Evaluation Strategies

Non-recursive rules (no cycles) evaluate in a single stratified pass. [R-stratified-eval]

```transcript @R-stratified-eval
$ make_identity :a
$ make_relation :Base 1
$ make_relation :Derived 1
$ assert Base(#a)
$ Derived(?x) :- Base(?x)
$ return Derived(?x)
[:x] {[#a]}
```

Recursive rules use semi-naive evaluation: seed phase (evaluate non-recursive rules), delta phases (re-evaluate affected rules with deltas until convergence). [R-semi-naive]

```transcript @R-semi-naive
$ make_relation :E 2
$ make_relation :P 2
$ assert E(#a, #b)
$ assert E(#b, #c)
$ P(?x, ?y) :- E(?x, ?y)
$ P(?x, ?z) :- E(?x, ?y), P(?y, ?z)
loaded
$ return P(?x, ?y)
[:x, :y] {[#a, #b], [#a, #c], [#b, #c]}
```


### Derived Relation Visibility

Every reader (query, transaction, rule evaluation) MUST see a consistent union of extensional and derived facts at the snapshot it observes. [R-consistent-union]

No duplicates; no partial derivation states visible.

```transcript @R-consistent-union
$ make_identity :a
$ make_relation :Base 1
$ make_relation :Der 1
$ Base(?x) :- true
$ Der(?x) :- Base(?x)
$ assert Base(#a)
$ return [Base(?x), Der(?x)]
[[:x] {[#a]}, [:x] {[#a]}]
```

When a transaction reads a derived relation after writing to relations that the rule depends on, the system MUST evaluate the rule against the transaction's combined view (base snapshot plus transaction writes). Results are cached within the transaction; subsequent writes invalidate and re-evaluate. [R-txn-read-derived]

```transcript @R-txn-read-derived
$ make_relation :R 1
$ make_relation :D 1
$ D(?x) :- R(?x)
$ begin_txn
$ assert R(#a)
$ return D(?x)
[:x] {[#a]}
$ end_txn
```


### Derived State Persistence

The system MUST store derived facts separately from extensional facts and MUST NOT persist derived facts as extensional facts. On restart, re-derive from active rules; never restore directly from checkpoint. [R-never-persist-derived]

<!-- evidence: @R-never-persist-derived -->
| Scenario | Behavior |
|----------|----------|
| Rule installed, derived facts created, checkpoint written | Derived facts stored separately; not in checkpoint |
| Process restart | All derived relations recomputed from restored extensional facts and active rules |
| Rule disabled, checkpoint written | Disabled rule's facts are gone; checkpoint contains only extensional facts |
| Rule changed, process restart | New rule applied to extensional facts; old derived facts never restored |


### Incremental Maintenance

The system MUST maintain the guarantee that every reader sees all facts derived by the active rule set at the snapshot's version, whether derived eagerly at every commit or computed on demand when queried. [R-incremental-guarantee]

Implementations MAY re-derive eagerly, maintain incrementally, or hybrid; reader-visible result MUST be identical.

<!-- evidence: @R-incremental-guarantee -->
| Reader view | Guarantee |
|-------------|-----------|
| Query derived relation R at snapshot v | Reader sees all facts R produces under active rules at v |
| Concurrent reader at older snapshot v-1 | Sees all facts R produces under active rules at v-1; unaffected by v's derivation |
| Reader at v after eager re-derivation | Sees complete fixpoint of all active rules over current extensional facts |
| Reader at v after on-demand computation | Sees complete fixpoint of queried rules; uncomputed rules' derivations not visible unless queried |


### Activation Mode: Eager vs Demand

Each relation MUST declare an activation mode: eager or demand. [R-activation-declared]

- **eager**: Evaluated at every snapshot, fully materialized.
- **demand**: Evaluated only when queried (backward chaining).

Stage 1 evaluates all relations eagerly; backward-chaining RFC will add demand mode with SLG tabling.

```transcript @R-activation-declared
$ make_relation :Source 1
$ make_relation :Result 1 :eager
$ Result(?x) :- Source(?x)
$ make_relation :OnDemand 1 :demand
$ OnDemand(?x) :- Result(?x)
loaded
```

```
ENUM Activation_Mode:
    EAGER       -- relation is kept current at every snapshot
    DEMAND      -- relation is computed when queried
```

Demand relations introduce lazy evaluation; negation over a demand relation is deferred until its dependencies have been tabled. (The backward-chaining RFC will specify this in detail.)


## Out of Scope

Query planning, tabling, computed relations, and functional key conflicts in derived relations are deferred.


## Alternatives Considered

Lazy validation surprises users; eager fails fast. Eager evaluation doesn't scale to large rule sets; demand evaluation enables lazy evaluation only of queried relations.


## Security Considerations

Rule installation is subject to authority checks owned by RFC #118. Derived relations inherit defining rule authority.


## Compatibility

Mica is a live database. Every world starts fresh; rules are installed live with snapshot consistency for readers.


## References

- RFC 2119, RFC 8174: BCP 14 keywords
- Datalog semantics: Ullman, "Database and Knowledge-Base Systems" (foundational reference for stratified Datalog)
- Incremental maintenance: omica `docs/incremental-maintenance-design.md`; stage 1 in rdaum/omica#125
- Rule authority and program installation: rdaum/omica#118
- Backward chaining: draft-ndn-demand-evaluation-00, which uses this RFC's activation mode interface


## Appendix A: Relation to Rust mica

| Behavior | Rust | omica today | This RFC | Class |
|----------|------|-------------|----------|-------|
| Unbound head variable validation | Lazy: install succeeds, first read fails with `UnboundHeadVariable` error | Eager: install fails with `Unbound_Head_Variable` error | Eager validation at install time (Rust behavior changes to match omica) | Improvement |
| `_` holes in positive rule bodies | Rejected at parse | Independent anonymous variables | omica behavior (differential run D-020) | Improvement |
| Stratification validation | At install time, rejects unstratified rules | At install time, rejects unstratified rules | At install time (no change) | Parity |
| Negation safety check (unbound terms) | At evaluation time, fails with `UnsafeNegation` | At evaluation time, fails with `Unsafe_Negation` | At evaluation time (no change) | Parity |
| Guard safety check (unbound operands) | At evaluation time, fails | At evaluation time, fails | At evaluation time (no change) | Parity |
| Non-recursive evaluation (stratified) | Single pass through strata | Single pass or fixpoint with 1 iteration | Stratified single-pass semantics (no change) | Parity |
| Recursive evaluation (fixpoint) | Semi-naive: seed + delta rounds until convergence | Semi-naive: seed + delta rounds until convergence | Semi-naive fixpoint (no change) | Parity |
| Join equality semantics | Canonical Value equality (int(1) ≠ float(1.0)) | Canonical Value equality (int(1) ≠ float(1.0)) | Canonical equality in joins; numeric equality in guards (no change) | Parity |
| Derived relation visibility | Union of extensional + derived, consistent snapshot | Union of extensional + derived, consistent snapshot | Union with consistency guarantee (no change) | Parity |
| Transaction read-your-writes for derived | Evaluates rule over txn view, caches result | Evaluates rule over txn view, caches result | Consistent semantics (no change) | Parity |
| Incremental maintenance | Lazy differential: weighted deltas, maintained after first read | Full fixpoint recompute on every commit (Stage 1: blocks + COW) | Observable guarantee only; algorithm deferred to incremental-maintenance design | Gap → Scheduled |
| Derived state persistence | Separate from extensional; fingerprint-based recovery (planned) | Separate from extensional; always re-derived | Never persist derived facts; re-derive on restart (no change) | Parity |
| Rule enable/disable | Supported; recomputes derived relations | Supported; recomputes derived relations | Supported (no change) | Parity |
| Activation mode (eager/demand) | All eager (lazy differential is implementation detail) | All eager | Declared per relation; backward-chaining RFC will add demand mode | Extension |
| Cache invalidation strategy | Explicit on rule install | Implicit (no persistent cache) | Not specified; implementations may vary | Implementation-defined |


