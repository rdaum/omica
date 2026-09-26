<!-- Backward-chaining demand evaluation for omica.
     Evidence blocks follow RFC 7322 (IETF) and rfc-tangle conventions;
     requirement markers are permanent references, used by later RFCs and plans.
  -->

# draft-ndn-demand-evaluation-00: Demand-Driven Evaluation (Backward Chaining)

**Status:** DRAFT
**Corpus:** red (spec-first; evidence is the acceptance criteria)
**Category:** Experimental
**Authors:** Norman Nunley, Jr. <nnunley@gmail.com>

## Abstract

Omica evaluates all derived relations eagerly on every commit. This RFC adds per-relation modes—eager or demand—enabling backward-chaining for infrequently queried relations. Demand relations use SLG-style tabling with completion to guarantee termination on recursive goals. Tables are ephemeral and never persisted.

## Motivation

Mica is a database, programming language, and runtime: a Datalog layer with a live image. Omica recomputes all derived relations via fixpoint on commit, even if unused. Demand evaluation shifts cost from commits to queries. Recursion matters: recursive relations like transitive closure dominate eager maintenance cost.

## Terminology

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD",
"SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this
document are to be interpreted as described in BCP 14 (RFC 2119, RFC 8174)
when, and only when, they appear in all capitals, as shown here.

- **Eager relation** — A derived relation fully materialized on every commit via fixpoint.
- **Demand relation** — A derived relation computed only when queried; results cached during task execution.
- **SLG resolution** — A backward-chaining strategy with tabling and completion detection for termination on recursion.
- **Completion table** — A cache detecting cyclic dependencies during SLG resolution.
- **Table invalidation** — Discarding cached results when rules change, authority shifts, or dependencies become stale.

## Specification

This document specifies per-relation modes, evaluation strategy, table lifetime, termination guarantees, and interactions with transactions, snapshots, authority, and rule installation.

**Evaluation model coherence.** Demand relations use backward chaining with tabling; eager relations use incremental maintenance. Both MUST return identical results. [R-demand-correctness]

<!-- evidence: @R-demand-correctness -->
| Case | Eager Result | Demand Result | Match |
|------|--------------|---------------|-------|
| Simple fact `Parent(alice, bob)` | `{(alice, bob)}` | `{(alice, bob)}` (from cache or fixpoint) | Yes |
| Recursive query `Ancestor(alice, X)` with facts `Parent(alice, bob), Parent(bob, charlie)` | `{(alice, bob), (alice, charlie)}` (full fixpoint) | `{(alice, bob), (alice, charlie)}` (SLG completion) | Yes |
| Authority denied (CanRead(R) = false) | Query fails with authorization error | Query fails with authorization error | Yes |

### Data model

```
Relation_Mode :: enum {
    EAGER,            -- Materialized on every commit; lives on snapshot
    DEMAND,           -- Computed on-demand per query; cached per snapshot
}

Relation :: struct {
    -- (existing fields)
    mode              : Relation_Mode = EAGER  -- Default for backward compatibility
    requires_eager    : bool                   -- True if negation or subscription forces eagerness
}

Table_Entry :: struct {
    goal_bindings     : Bindings         -- Query parameters (e.g., Ancestor(alice, ?))
    snapshot_version  : Version          -- Snapshot this table is valid for
    authority_context : Authority_Set    -- Authority checks in effect at table creation
    results           : Set[Row]         -- Cached result rows
}

Demand_Table :: struct {
    relation          : Relation
    entries           : Map[Table_Key, Table_Entry]  -- Keyed by goal + snapshot + authority
    completion_set    : Set[Frame]       -- SLG completion set for cycle detection
}
```

**Relation_Mode:** EAGER materializes; DEMAND computes on query. EAGER default.

**Table_Entry:** Cached results keyed by goal, snapshot version, authority context.

**Mode:** Compile-time fixed; per-relation, not partial.

### Evaluation strategy

When a query reads a derived relation R: EAGER uses materialized block; DEMAND checks table cache. Miss triggers fixpoint with goal bindings seeded by SLG completion table. [R-demand-on-read] [R-stratified-fixpoint]

<!-- evidence: @R-demand-on-read -->
| Scenario | Setup (Mica facts/rules) | Query | Expected |
|---|---|---|---|
| Simple fact match | `Parent(alice, bob)` `Ancestor(X, Y) :- Parent(X, Y) @mode(demand)` | `Ancestor(alice, X)` | Cache miss triggers fixpoint; returns `{(alice, bob)}` |
| Recursive resolution with completion check | `Parent(alice, bob), Parent(bob, charlie)` `Ancestor(X, Y) :- Ancestor(X, Z), Parent(Z, Y) @mode(demand)` | `Ancestor(alice, X)` | Fixpoint iteration 1 discovers `bob`, iteration 2 discovers `charlie` via recursion; completion table prevents re-entry; returns `{(alice, bob), (alice, charlie)}` |
| Completion table convergence | Same facts and rules | Same query on second task with same snapshot | Cache hit; returns `{(alice, bob), (alice, charlie)}` without fixpoint recomputation |

**Termination via completion.** SLG tables recursive calls and returns accumulated results on re-entry. [R-slg-termination] [R-slg-completion]

<!-- evidence: @R-slg-termination -->
<!-- evidence: @R-slg-completion -->
| Scenario | State | Action |
|----------|-------|--------|
| First call Ancestor(bob, ?) | Empty | Recurse; add frame |
| Re-entry Ancestor(bob, ?) | {Ancestor(alice, ?)} | Return accumulated |
| No new frames | {alice, bob} | Terminate |

**Stratum requirement.** Demand relations negated in rules force eager mode; fixpoint respects stratification. [R-stratified-fixpoint]

<!-- evidence: @R-stratified-fixpoint -->
| Stratum | Relations | Negation Check |
|---------|-----------|---|
| Stratum 0 (base facts) | Parent(X, Y) | Not applicable |
| Stratum 1 (eager, derived) | Ancestor(X, Y) :- Parent(X, Y) | OK (reads only stratum 0) |
| Stratum 2 (eager, higher-order) | NonReachable(X, Y) :- not Ancestor(X, Y) | OK (negates stratum 1, which is complete) |
| Stratum 1 with demand | Ancestor(X, Y) marked @mode(demand) | Error: negation of demand relation in stratum 2 |

### Table lifetime and invalidation

Demand tables are scoped to snapshot versions and discarded at commit. [R-table-per-snapshot]

<!-- evidence: @R-table-per-snapshot -->

If a task's authority changes mid-execution, cached tables for the changed authority MUST be invalidated and recomputed on next query. [R-authority-invalidation]

<!-- evidence: @R-authority-invalidation -->

When a rule is installed, removed, enabled, or disabled, all demand tables depending on the changed rule MUST be invalidated; the dependency graph is provided by the rules RFC (draft-ndn-rules-derivation-00). [R-rule-change-invalidation]

<!-- evidence: @R-rule-change-invalidation -->
| Event | Table State | Behavior |
|-------|-----------|----------|
| T1 reads S1, queries demand | Cache miss → created | Cached for S1 |
| T1 commits (S2 created) | S1 table invalidated | Discarded |
| Authority revoked mid-task | Cache invalidated | Next query recomputes |
| Rule installed/disabled | Dependent tables | Invalidated, re-runs on query |
| Relation renamed | Referencing tables | Invalidated |

### Negation over demand relations

Negation of a demand relation is rejected at rule-installation time. [R-negation-demand-rejected]

Negation requires complete enumeration, conflicting with demand evaluation's selective computation. The compiler rejects negated demand relations at install time. [R-negation-demand-rejected]

<!-- evidence: @R-negation-demand-rejected -->
| Scenario | Rule Definition | Mode Check | Expected |
|---|---|---|---|
| Negation over demand relation | `NonReachable(X, Y) :- not Reachable(X, Y)` where `Reachable @mode(demand)` | Compiler checks if `Reachable` is DEMAND | Rule install fails; error: "Cannot negate demand relation Reachable" |
| Negation over eager relation (valid) | `NonReachable(X, Y) :- not Reachable(X, Y)` where `Reachable @mode(eager)` | Compiler checks if `Reachable` is DEMAND | Rule installs successfully |

### Recursive demand relations with SLG tabling

Recursive demand relations are supported with termination guaranteed via SLG completion tables. [R-recursive-demand]

<!-- evidence: @R-recursive-demand -->
| Rule Set | Query | Result | Termination |
|----------|-------|--------|-------------|
| `Ancestor(X, Y) :- Parent(X, Y)` marked @mode(demand) | `Ancestor(alice, X)` | Rows for X in transitive closure | Guaranteed (SLG completion) |
| `Ancestor(X, Y) :- Ancestor(X, Z), Parent(Z, Y)` added | Same query | Additional rows via recursion | Guaranteed (frames are memoized) |
| Cyclic fact base: `Parent(a, b), Parent(b, a)` | `Ancestor(a, X)` | Result terminates; no infinite loop | Guaranteed (completion table detects cycles) |

The standard SLG completion mechanism (Chen & Warren, 1996) maintains a completion set of subgoal frames.

### Interaction with transactions and snapshots

Demand tables are scoped to snapshot versions.

**Write-then-read within a task.** If a task writes and reads a demand relation on the new snapshot, the following sequence MUST occur:
1. Write invalidates tables for the old snapshot (version mismatch)
2. Next query triggers fresh fixpoint evaluation
3. New table is cached for the new snapshot
4. Derived tables reflect all task writes

[R-write-invalidates-tables]

<!-- evidence: @R-write-invalidates-tables -->
| Step | Snapshot | Table State | Query Result |
|------|----------|-------------|---|
| 1. Task reads Snapshot S1 | S1 | Empty cache | |
| 2. Query Ancestor(alice, X) on S1 | S1 | Cached result: {(alice, bob), (alice, charlie)} | {(alice, bob), (alice, charlie)} |
| 3. Task inserts new Parent fact, creates Snapshot S2 | S2 | S1 cache invalidated (version mismatch) | |
| 4. Query Ancestor(alice, X) on S2 | S2 | Cache miss (version changed); recompute | Result includes new fact from S2 |

**Concurrent tasks with different authority.** Concurrent tasks with different authority contexts build independent demand tables (keyed by authority_context). No coordination is needed; tables are task-local.

### Subscriptions on demand relations

A subscription on a demand relation forces eager: materializes at next commit and maintains like any eager relation; removing last subscription returns to demand and discards table. [R-subscription-eager-promotion]

<!-- evidence: @R-subscription-eager-promotion -->
| Event | Mode | Active subscriptions | Behavior |
|-------|------|---------|----------|
| Demand relation, no subscriptions | DEMAND | 0 | Evaluated on read; nothing materialized |
| Subscription added | EAGER | 1 | Materialized at the next commit |
| Another subscription added | EAGER | 2 | Still eager |
| One subscription removed | EAGER | 1 | Still eager |
| Last subscription removed | DEMAND | 0 | Returns to demand mode; table discarded |

### Authority (CanRead) checks

Demand-relation queries are subject to the same CanRead checks as eager relations. If a task lacks CanRead(R), a query on R MUST fail with an authorization error. [R-authority-check]

<!-- evidence: @R-authority-check -->
| Relation Mode | Authority Check | Query Result |
|---|---|---|
| EAGER | CanRead(R) granted | Succeeds; returns materialized rows |
| EAGER | CanRead(R) denied | Fails; authorization error |
| DEMAND | CanRead(R) granted | Succeeds; returns computed rows from fixpoint |
| DEMAND | CanRead(R) denied | Fails; authorization error (same as eager) |

Authority changes mid-task invalidate dependent tables, which recompute under new authority.

### Rule install and disable in a running world

When a rule is installed, removed, or disabled:
1. All demand tables whose dependency graph includes the changed rule are invalidated
2. The invalidation is immediate (no lazy evaluation)
3. The next query rebuilds the table

**Dependency tracking.** The rule catalogue provides a dependency graph; the runtime uses it to identify invalidated tables.


### Persistence and fingerprints

Demand tables are **never persisted**. On every boot, demand relations MUST be recomputed from scratch. [R-tables-not-persisted]

<!-- evidence: @R-tables-not-persisted -->
| Scenario | Snapshot File | Memory Table | On Boot |
|---|---|---|---|
| Eager relation materialized | Stored (relation block) | Cached (during task) | Loaded from disk |
| Demand relation queried | Not stored | Cached (during task only) | Recomputed; no boot shortcut |
| Task commits | Eager blocks saved | Demand tables discarded | Demand tables gone |

**Fingerprints:** Validate base facts and eager blocks; ignore demand relations (never persisted). Fall back correctly by recomputing demand on query.

```
-- Fingerprint logic (pseudocode)
on_commit:
    snapshot.fingerprint = hash(snapshot.facts)  -- includes only base facts and eager derived blocks
    -- Demand relations are NOT included; they are recomputed on next query
```

### Default behavior

All derived relations default to EAGER mode, ensuring backward compatibility: existing Omica code behaves identically to before this RFC. Users opt into demand evaluation by declaring `@mode(demand)` on specific relations. [R-default-eager]

<!-- evidence: @R-default-eager -->
| Relation Declaration | Declared Mode | Actual Mode | Behavior |
|---|---|---|---|
| Helper(X) :- Fact(X) | (not declared) | EAGER (default) | Materialized on every commit |
| @mode(demand) Helper(X) :- Fact(X) | DEMAND | DEMAND | Computed on-demand |
| Existing code (no mode annotation) | (not declared) | EAGER (default) | Unchanged from pre-RFC behavior |

## Formal Grammar

Mode declaration syntax is defined in the rules RFC. At runtime, the relation definition includes a mode field (EAGER or DEMAND):

```abnf
relation-mode = %s"eager" / %s"demand"
mode-declaration = %s"@mode" "(" relation-mode ")"
```

## Out of Scope

**Compile-time cost analysis.** No warnings or limits on demand-table explosion. A later RFC may define cost-analysis hooks for unexpectedly large materialization.

**Dynamic mode switching.** Modes are fixed at compile time. Runtime mode switching (via pragma or API) is not supported.

**Optimization of query binding parameterization.** Unspecified: tables may be parameterized by full bindings (e.g., `Ancestor(alice, eve)` vs. `Ancestor(alice, bob)`) or patterns (e.g., `Ancestor(alice, ?)`). Full parameterization is recommended for correctness but may require finer-grained invalidation.

**Incremental tabling across commits.** Demand tables recompute fresh on each query without incremental maintenance across commits. A later RFC may define incremental tabling for higher-cost queries.

## Alternatives Considered

**Why not lazy materialization?** Simpler but doesn't support mid-stream queries; SLG completion aligns better with Omica.

**Why not persist demand tables?** Persistence requires versioning; recomputation on boot is simpler for infrequent queries.

**Why not support negation over demand relations?** Negation requires complete enumeration, conflicting with selective computation. Stratified completion forces eager materialization, defeating demand's purpose.

**Why not allow partial eagerness?** A relation evaluated eagerly for some rules and on demand for others has two answers to one query. Each relation therefore takes one mode; different relations may take different modes.

## Security Considerations

**Authority checks.** Demand-relation queries must pass the same CanRead checks as eager queries. If authority is insufficient, the query fails and no table is created. Queries with different authority produce independent results (or errors).

**Information leakage via table-hit timing.** Cache hits return faster than cache misses. Attackers with timing access might infer recent query patterns. Mitigation requires deployment-level constant-time operations or access controls.

**Denial of service via large tables.** Demand queries can materialize large tables. Mitigation requires rate limiting or cost limits (out of scope).

## Compatibility

**Existing Omica code.** No breaking changes; EAGER defaults preserve existing behavior. Demand tables are never persisted. Table invalidation is internal. Query results are identical whether relations are eager or demand.

## References

- Chen, W. and Warren, D.S., 1996. **Tabled evaluation with delaying for general logic programs.** *Journal of the ACM*, 43(1), pp.20-74. https://dl.acm.org/doi/10.1145/227595.227597 — Foundational SLG resolution and tabling mechanism.

- Bancilhon, F., Maier, D., Sagiv, Y. and Ullman, J.D., 1986. **Magic sets and other strange ways to implement logic programs.** *Proceedings of the Fifth ACM SIGMOD-SIGACT Symposium on Principles of Database Systems*. ACM, pp.1-15. https://dl.acm.org/doi/10.1145/235809.235814 — Compile-time optimization for forward-chaining Datalog; used to prune irrelevant facts.

- Tekle, K.T. and Liu, Y.A., 2010. **More effective datalog queries: subsumptive tabling.** In *Proceedings of the 12th International ACM SIGPLAN Symposium on Principles and Practice of Declarative Programming* (pp. 287-298). https://dl.acm.org/doi/10.1145/1836089.1836129 — Demand-driven tabling with subsumption; reduces table lookups compared to magic sets.

- Ramakrishnan, R., Srivastava, D., Sudarshan, S. and Safra, P., 1992. **Space optimization for datalog programs.** In *Proceedings of the 1992 ACM SIGMOD International Conference on Management of Data* (pp. 269-278). https://dl.acm.org/doi/10.1145/141484.141507 — Formalization of stratified Datalog with negation.

- Datomic, Inc., 2024. **Query (pull API).** https://docs.datomic.com/queries/pull.html — Immutable snapshot-based query model with backward-chaining on indexes; reference for snapshot consistency during concurrent queries.

- omica `docs/incremental-maintenance-design.md`: a design for differential re-derivation of eager relations in stages; only stage 1 exists (rdaum/omica#125, in review). Demand relations coexist with it.

## Appendix: Relation to Rust mica

| Behavior | Rust mica | omica today (Stage 2) | This RFC | Class |
|----------|-----------|----------------------|----------|-------|
| Maintain eager relations across commits | Lazy differential maintenance after first read ([crates/runtime/src/subscription.rs:387-407](https://github.com/timbran-project/mica/blob/2bbceb0113b0/crates/runtime/src/subscription.rs#L387-L407)) | Full fixpoint recompute on every commit; rdaum/omica#125 (stage 1, in review) shares blocks whose rows did not change; differential re-derivation is designed, not implemented | Unchanged; demand relations coexist with either | Gap (omica) |
| Lazy materialization of demand relations | Not implemented | Not implemented | SLG-style tabling per snapshot | Improvement |
| Recursive query support with completion tables | Not implemented | Not implemented | SLG completion for cycle detection | Improvement |
| Persistence of derived tables | Not verified | Recomputed at boot, not persisted | Never persist demand tables; recompute on query | Parity for omica; Rust not verified |
| Negation of eager relations | Supported (stratified) | Supported (stratified) | Supported | Parity |
| Negation of demand relations | N/A (no demand) | N/A (no demand) | Rejected at install | Improvement |
| Authority checks on queries | Implemented ([crates/vm/src/authority.rs](https://github.com/timbran-project/mica/blob/2bbceb0113b0/crates/vm/src/authority.rs)) | Implemented | Unchanged; applies to demand relations | Parity |
| Subscriptions on eager relations | Supported via differential subscriptions | Supported | Retained for EAGER mode | Parity |
| Subscriptions on demand relations | N/A (no demand) | N/A (no demand) | Must be explicitly supported; strategy (eager promotion or per-query) chosen by implementation | Improvement |
| Rule installation invalidates caches | N/A (caches external to runtime) | N/A (no caching) | Invalidates demand tables; eager relations use existing maintenance | Improvement |
| Snapshot isolation for queries | Supported (implicit in immutable snapshots) | Supported (implicit in incremental maintenance) | Tables keyed by snapshot version; invalidated at commit | Parity |

