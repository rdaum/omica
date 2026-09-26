# draft-ndn-declarations-catalogue-00: Declarations and the Catalogue

**Status:** DRAFT
**Corpus:** red (spec-first — evidence is the acceptance criteria)
**Category:** Standards-Track
**Authors:** Norman Nunley, Jr. <nnunley@gmail.com>


## Abstract

This RFC specifies declaration semantics and system catalogue. It settles idempotency, conflict detection, return values, and catalogue immutability.


## Motivation

Mica declares identities and relations while the world runs, so one declaration is a language call, a database write and a runtime event. omica resolves declarations in a prescan while parsing a file: a conflicting redeclaration succeeds silently, and `make_relation` returns a value that is not the relation's entity. This RFC makes declarations idempotent, makes conflicts errors, returns entities, and keeps the system relations authoritative.


## Terminology

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD",
"SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this
document are to be interpreted as described in BCP 14 (RFC 2119, RFC 8174)
when, and only when, they appear in all capitals, as shown here.

- **declaration** — a call to `make_identity`, `make_relation`, or `make_functional_relation` that creates or obtains a named entity and stores its metadata in the system catalogue.
- **idempotent declaration** — a repeated call with identical metadata (name, arity, key positions, conflict policy, durability) returns the same entity.
- **conflicting redeclaration** — a repeated call with different metadata (arity, keys, conflict policy, or durability) for the same name; MUST be rejected with an error.
- **catalogue** — the collection of system relations that store metadata about the runtime world: relation names, arities, functional keys, conflict policies, durability modes, named identities, ownership, rules, and methods.
- **system relation** — a catalogue relation created and maintained by the runtime, read-only to user programs; all assertions and retractions are rejected with an error.
- **authority** — a capability to mutate the system or code; admin authority is required for catalogue mutations.


## Specification

**Principle: Declarations Are Declarative.** Same input produces same state at load, compile, or runtime.

**Principle: Conflicts Are Errors.** Different metadata fails; same metadata succeeds idempotently.

**Principle: Catalogue Is Searchable.** System relations expose all entities; tools reconstruct worlds from facts.

### Data Model

```
-- Identity creation and naming
RECORD Identity:
    id          : Integer              -- allocated monotonically, unique within a world
    name        : Symbol               -- the declared name for lookup

-- Relation metadata
RECORD Relation:
    id          : Integer              -- allocated monotonically, unique within a world
    name        : Symbol               -- the declared name for lookup
    arity       : Integer              -- number of fields (1 or more)
    conflict_policy : ConflictPolicy   -- Set, Functional, or EventAppend
    durability  : Durability           -- Durable or Volatile
    functional_keys : List[Integer]    -- positions (0-indexed) of key fields if Functional

-- Conflict resolution strategy
ENUM ConflictPolicy:
    SET         -- no duplicate tuples; assertion of existing tuple is a no-op
    FUNCTIONAL  -- unique key constraint; new tuple with existing key replaces old tuple (upsert)
    EVENTAPPEND -- append-only; duplicates allowed

-- Persistence mode
ENUM Durability:
    DURABLE     -- facts persisted to storage and survive restart
    VOLATILE    -- facts exist only in memory; lost at shutdown
```

**Arity constraint:** Arity MUST be 1 or more.

**Functional key constraint:** If `conflict_policy` is `FUNCTIONAL`, `functional_keys` MUST contain at least one position and all positions MUST be in range `[0, arity - 1]`. If `conflict_policy` is `SET` or `EVENTAPPEND`, `functional_keys` MUST be empty.

**Name uniqueness:** Each (name, entity_type) pair MUST be unique within a world.

### Behaviour: Identity Creation

The runtime MUST accept calls to `make_identity(name)` where `name` is a symbol. [R-identity-create]

<!-- evidence: @R-identity-create -->
| Context | Behavior | Source |
|---------|----------|--------|
| First call to `make_identity(:foo)` | Creates identity I_foo, stores in NamedIdentity(:foo, I_foo), returns I_foo | Rust [crates/runtime/src/lib.rs:3124-3130](https://github.com/timbran-project/mica/blob/2bbceb0113b0/crates/runtime/src/lib.rs#L3124-L3130) |
| Computed name at runtime | Call succeeds, creating new identity | omica spec issue #111 requirement |
| No name collision | Each identity allocated unique ID from monotonic counter | Both Rust and omica design |

Calls are idempotent and transactional. Authority denial fails atomically.

If authority is denied, the call MUST fail without creating or returning an identity. [R-identity-authority]

<!-- evidence: @R-identity-authority -->
| Context | Behavior | Source |
|---------|----------|--------|
| Untrusted code calls `make_identity` | Call fails with "requires admin authority" error | Rust [crates/runtime/src/lib.rs:6476](https://github.com/timbran-project/mica/blob/2bbceb0113b0/crates/runtime/src/lib.rs#L6476) (require_admin_builtin) |
| Catalogue unchanged after denied call | NamedIdentity relation contains no new facts | Observable contract requirement |

### Behaviour: Relation Creation

The runtime MUST accept calls to `make_relation(name, arity)` where `name` is a symbol and `arity` is a positive integer. [R-relation-create]

<!-- evidence: @R-relation-create -->
| Context | Behavior | Source |
|---------|----------|--------|
| First call to `make_relation(:items, 2)` | Creates relation with arity 2, stores Relation/RelationName/Arity facts, returns relation identity | Rust [crates/runtime/src/lib.rs:3132-3148](https://github.com/timbran-project/mica/blob/2bbceb0113b0/crates/runtime/src/lib.rs#L3132-L3148) |
| Computed name at runtime | Call succeeds, creating relation with computed name | omica spec issue #110 requirement |
| Default metadata | conflict_policy=SET, durability=DURABLE, functional_keys=[] | Observable contract |

Defaults: conflict_policy=SET, durability=DURABLE. Return value is the relation handle, not its content. Idempotent on same (name, arity, policy, durability); conflicts error.

If a relation with the same name exists but has different arity, conflict policy, or durability, the call MUST fail with an error naming the conflict. [R-relation-conflict]

<!-- evidence: @R-relation-conflict -->
| Scenario | Expected Behavior | Source |
|----------|-------------------|--------|
| `make_relation(:items, 2)` then `make_relation(:items, 3)` | Second call fails with "conflicting redeclaration: arity mismatch 2 != 3" | Rust validates in ensure_declared_relation; omica D-003 shows it silently succeeds (gap) |
| `make_relation(:items, 2)` then `make_relation(:items, 2, VOLATILE)` | Second call fails with "conflicting redeclaration: durability mismatch" | Rust validates durability; needed for consistency |
| Same (name, arity, policy, durability) | Second call returns existing relation (idempotent) | Principle: Declarations Are Declarative |

If authority is denied, the call MUST fail without creating the relation. [R-relation-authority]

<!-- evidence: @R-relation-authority -->
| Context | Behavior | Source |
|---------|----------|--------|
| Untrusted code calls `make_relation(:data, 2)` | Call fails with "requires admin authority" error | Rust [crates/runtime/src/lib.rs:6476](https://github.com/timbran-project/mica/blob/2bbceb0113b0/crates/runtime/src/lib.rs#L6476) (require_admin_builtin) |
| Catalogue unchanged after denied call | Relation/RelationName/Arity relations contain no new facts for :data | Observable contract requirement (atomic failure) |

### Behaviour: Functional Relation Creation

The runtime MUST accept calls to `make_functional_relation(name, arity, key_positions)` where `name` is a symbol, `arity` is a positive integer, and `key_positions` is a list of field indices. [R-functional-create]

<!-- evidence: @R-functional-create -->
| Context | Behavior | Source |
|---------|----------|--------|
| Call to `make_functional_relation(:color, 2, [0])` | Creates relation with arity 2, conflict_policy=FUNCTIONAL, key=[0], stores all metadata | Rust [crates/runtime/src/lib.rs:3150-3169](https://github.com/timbran-project/mica/blob/2bbceb0113b0/crates/runtime/src/lib.rs#L3150-L3169) |
| Computed name at runtime | Call succeeds with computed name | omica spec issue #110 requirement |
| key_positions validation | Rejects positions < 0 or >= arity; requires non-empty list | Data model constraints, line ~88 |

Upsert semantics on existing keys. Idempotent on same (name, arity, key_positions); conflicts error.

If a relation with the same name exists but has different arity, key positions, or is not functional, the call MUST fail with an error naming the conflict. [R-functional-conflict]

<!-- evidence: @R-functional-conflict -->
| Scenario | Expected Behavior | Source |
|----------|-------------------|--------|
| `make_functional_relation(:item, 3, [0, 1])` then `make_functional_relation(:item, 3, [0])` | Second call fails with "conflicting redeclaration: key mismatch" | Rust validates keys in hir_key_positions; omica currently succeeds (gap) |
| `make_relation(:item, 2)` then `make_functional_relation(:item, 2, [0])` | Second call fails with "conflicting redeclaration: conflict_policy mismatch SET != FUNCTIONAL" | Cannot change SET to FUNCTIONAL or vice versa |
| Same (name, arity, key_positions) | Second call returns existing relation (idempotent) | Principle: Declarations Are Declarative |

### System Catalogue Relations

The runtime maintains these system relations to describe the world. All are read-only to user programs.

| Relation | Arity | Fields | Purpose |
|----------|-------|--------|---------|
| `Relation` | 1 | [relation_id] | Existence; one fact per declared relation |
| `RelationName` | 2 | [relation_id, symbol_name] | Maps relation ID to declared name |
| `Arity` | 2 | [relation_id, int_arity] | Arity of each relation |
| `ConflictPolicy` | 2 | [relation_id, policy_symbol] | SET, FUNCTIONAL, or EVENTAPPEND |
| `FunctionalKey` | 3 | [relation_id, key_position, index] | Key constraints; one fact per key field |
| `Durability` | 2 | [relation_id, durability_symbol] | DURABLE or VOLATILE |
| `NamedIdentity` | 2 | [identity, symbol_name] | Maps identity ID to declared name |
| `Rule` | 1 | [rule_id] | Existence; one fact per rule |
| `RuleHead` | 2 | [rule_id, relation_id] | Relations derived by rule |
| `Method` | 2 | [object_id, method_id] | Methods attached to objects (Self-style) |
| `SourceOwns*` | 2 | [source_unit_id, entity_id] | Ownership of relations, rules, methods by source unit |
| `Delegate` | 2 | [child_object_id, parent_object_id] | Prototype delegation links (Self-style) |

**Immutability guarantee:** The runtime MUST reject all assertions and retractions on system catalogue relations. [R-catalogue-readonly]

<!-- evidence: @R-catalogue-readonly -->
| Operation (differential run D-021) | omica 5a22a77 | Rust 2bbceb0 |
|---|---|---|
| `assert Relation(123)` | accepted | rejected: relation is read-only |
| `assert Arity(:foo, 2)`, then `Arity(:foo, ?n)` | accepted; returns `{[2]}` | rejected: relation is read-only |
| `retract RelationName(_, :foo)` (no match) | accepted | accepted |

omica does not meet this requirement yet: its list of read-only system relations ([mica/runtime/runtime.odin:1156-1179](https://github.com/rdaum/omica/blob/5a22a77cc245/mica/runtime/runtime.odin#L1156-L1179)) guards identity destruction, not `assert` and `retract`. Rust rejects writes with an uncatchable error and skips the check when a wildcard retract matches nothing; Ryan Daum's Rust parity plan ([gist](https://gist.github.com/rdaum/4891ed160b0e38e9079744e1f1a0d854)) makes these a catchable `E_READ_ONLY`, empty matches included. An implementation SHOULD raise the same catchable `E_READ_ONLY`.

Catalogues are the authoritative description of the world. Tools, fileout, and upgrade strategies depend on catalogue facts being authoritative. Allowing user mutations would create inconsistency between programme structure and catalogue structure.

### Behavior: Conflicting Redeclaration

When a user calls `make_relation`, `make_functional_relation`, or `make_identity` with a name that is already declared, the runtime MUST check that all structural metadata matches. [R-redeclaration-check]

| Scenario | Action |
|----------|--------|
| Redeclaration matches existing (same arity, same keys, same policy, same durability) | Return the existing entity (idempotent) |
| Redeclaration conflicts (different arity, or different keys, or different policy, or different durability for same name) | Fail with error "conflicting redeclaration: <details>", leaving catalogue unchanged |
| Redeclaration is for a different entity type (identity vs relation, or different kind of relation) | Fail with error "name already in use for <entity_type>" |

The evidence: differential D-003 from the spec shows omica silently succeeds on conflicting redeclaration, while Rust correctly errors. This RFC specifies error-on-conflict as the observable behavior.

<!-- evidence: @R-redeclaration-check -->
In Rust mica ([crates/runtime/src/lib.rs:3132-3148](https://github.com/timbran-project/mica/blob/2bbceb0113b0/crates/runtime/src/lib.rs#L3132-L3148)), `ensure_declared_relation()` loops to validate arity and durability; if any mismatch, it errors. In omica before this RFC, `builtin_relation()` is a lookup stub and never errors on arity mismatch. This RFC specifies Rust behavior: error on any structural mismatch.

### Behavior: Return Values

Calls to constructors MUST return the created (or existing) entity's identity (handle), not the entity's content. [R-constructor-returns-identity]

- `make_identity(name)` RETURNS an Identity (the handle itself).
- `make_relation(name, arity)` RETURNS a Relation (the handle itself).
- `make_functional_relation(name, arity, keys)` RETURNS a Relation (the handle itself).

<!-- evidence: @R-constructor-returns-identity -->
| Call | Rust Returns | omica Before RFC | This RFC Requires |
|------|--------------|------------------|-------------------|
| `make_identity(:foo)` | Identity handle (ID, name binding) | Not yet tested at runtime | Identity handle usable in subsequent declarations |
| `make_relation(:items, 2)` | Relation handle (ID, metadata binding) | Empty relation `[] {}` (D-004 differential) | Relation handle usable in other constructors |
| Using returned handle | Pass to subsequent constructors or store | Content-based returns prevent composition | Handle enables programmatic schema construction |

Not return values: the identity's name, the relation's facts, the relation's metadata as a structured object. Those are available by querying the catalogue relations (RelationName, Arity, ConflictPolicy, etc.).

Return values are handles, not introspection results. This enables programmatic composition: code can pass the returned identity to other constructors that depend on it. Evidence: differential D-004 from the spec shows omica returns empty relation `[] {}` (content, not identity); this RFC specifies return of identity/handle.

## Out of Scope

**Runtime constructor implementation (rdaum/omica#118).** This RFC specifies the observable contract: idempotency, conflict detection, return values, authority checks. The implementation — allocation atomicity, transactional staging, concurrent call serialization — is owned by #118. This RFC cites #118 for reference only.

**Authority enforcement details (rdaum/omica#118).** This RFC specifies that admin authority is required for catalogue mutations and denied calls leave state unchanged. The mechanism — authority checks, capability tokens, install gates — is owned by #118.

**Filein and atomic replacement (#117).** This RFC specifies that system relations are read-only and declarations are idempotent. The mechanics — retracting old facts, loading new source atomically, handling concurrent readers — is owned by #117.

**Delegation and prototype lookup (Self-style).** This RFC lists the Delegate catalogue relation but does not specify lookup or method dispatch semantics. Those are owned by a future RFC on method dispatch.

## Alternatives Considered

**Why not allow silent idempotency without error on conflict?** Silent success hides schema mismatches and allows invalid data into relations. Code that redeclares with wrong arity needs clear failure to distinguish error from idempotency. Explicit errors force tools and code to validate schema constraints.

**Why not return the relation's content instead of its identity?** Returning content is expensive for large relations and breaks composition. Code cannot pass facts to other constructors. Returning identity (handle) is lightweight and enables composition. Introspection queries are available through catalogue relations.

**Why not allow user programs to update catalogue relations?** Catalogues are the authoritative description of the runtime world. Allowing mutations introduces inconsistency: a program could create a relation but then retract its metadata. Tools and upgrade strategies depend on catalogue facts. Read-only enforcement protects this invariant at the boundary.

## Security Considerations

Declarations mutate system state; denial of authority on such calls prevents untrusted code from altering the schema or creating relations it does not own. This RFC specifies that denied calls leave state unchanged (atomic failure), preventing partial mutations.

Authority enforcement is owned by #118. If authority is denied, no catalogue entry is created and no facts are stored. Implementation must ensure atomicity.

## Compatibility

This RFC aligns omica with Rust mica. Existing omica code that relies on silent success for conflicting redeclarations will now receive errors. Migration: ensure redeclarations match existing metadata, or add guard clauses to handle errors.

Code that expects return values to be relation content (iterating over facts returned from `make_relation`) will break. Migration: use catalogue relations (Arity, ConflictPolicy, etc.) to query metadata; query relation facts separately.

## References

- rdaum/omica#110: Runtime relation creation contract
- rdaum/omica#111: Runtime identity creation contract
- rdaum/omica#117: Filein into running world and atomic replace mode
- rdaum/omica#118: Runtime constructors, allocation, and install authority gate
