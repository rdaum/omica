# draft-ndn-units-00: Units: Filein, Fileout and Unit State

**Status:** DRAFT
**Corpus:** red (spec-first; evidence is the acceptance criteria)
**Category:** Standards-Track
**Authors:** Norman Nunley, Jr. <nnunley@gmail.com>


## Abstract

This RFC specifies omica's unit model: namespace, ownership, and state semantics for filed-in code. Units are persistent namespaces with readable and writable bindings; verbs access and modify slot values like Smalltalk instance variables or Self slots. Filein into a running world extends a live image: Add mode appends, Replace mode atomically retracts prior ownership and installs new source.


## Motivation

Mica is a database, programming language, and runtime at once: blending Smalltalk's live image, Self's prototypes, and Datalog; the live world is the source of truth. Units are the organizational boundary for filed-in code, bridging code (methods, rules, state) with the persistent world. Current specs leave unit state binding access and slot mutation unspecified. This RFC closes both gaps: verbs refer to and assign their unit's top-level bindings, assignments persist as transactional facts to durable storage, and Replace mode keeps declared slots—enabling hot-reload and stateful units.


## Terminology

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD",
"SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this
document are to be interpreted as described in BCP 14 (RFC 2119, RFC 8174)
when, and only when, they appear in all capitals, as shown here.

- **unit** — a persistent namespace identified by a symbol, holding methods, rules, facts, and state bindings.
- **slot** — a named binding in a unit, storing a mutable value as a persistent fact (e.g., `UnitSlot(unit, name, value)`).
- **filein** — reading and executing source code in the running world, creating identities, relations, methods, rules, and facts owned by a unit.
- **fileout** — reconstructing human-readable source code from world state, preserving all unit declarations, methods, rules, facts, and grants.
- **Add mode** — filein mode appending declarations and facts without retracting prior ownership.
- **Replace mode** — filein mode atomically retracting all unit-owned facts, rules, relations, and methods, then appending new source.
- **name resolution** — the order verbs look up names: local scope, unit slots, then world-global names (relations, identities, verbs).
- **authority** — the privilege to retract facts or modify a unit's relations and slots.


## Specification

This document defines unit identity, ownership, state persistence, filein modes (Add and Replace), fileout reconstruction, name resolution, slot assignment, and state vs. world divergence detection. It does NOT define the install authority gate (PR rdaum/omica#118), per-method program registry (#118), quality tool implementation (PR #109), or runtime-install gate (#118).


### Unit Identity and Naming

A unit is identified by a symbol (e.g., `:web`, `:auth`, `:storage`). The unit symbol acts as a namespace and is stored as a Symbol value in the world.

**Unit symbols MUST be interned and canonical across the world's lifetime.** Two fileins naming the same unit symbol refer to the same unit. The filein caller specifies the unit symbol owning declarations and state produced.

Unit symbols appear in:
- `SourceOwnsFact`, `SourceOwnsRule`, `SourceOwnsRelation`, `SourceOwnsTypeAlias`, `SourceOwnsIdentity` ownership tuples (first field)
- `UnitSource` relation tracking
- Fileout output (structured code)


### Unit Ownership Model

Ownership is tracked via `SourceOwnsFact`, `SourceOwnsRule`, `SourceOwnsRelation`, `SourceOwnsTypeAlias`, `SourceOwnsIdentity` by comparing world state before and after filein, enabling selective retraction on Replace and fileout queries. A unit owns facts it asserts, even into relations created by other units.


### Unit State and Slots

Top-level bindings become the unit's persistent state, stored as facts in `UnitSlot(unit, name, value)`.

**The runtime MUST execute all top-level bindings in a shared scope** so one binding reads earlier values. Unit state persists across reboots; slots restore from facts before verbs execute. [R-slots-persist]

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


### Name Resolution for Verbs

When a verb in unit `U` references name `N`, the runtime resolves in order: [R-name-resolution]

1. **Local scope**: verb parameters and `let` bindings
2. **Unit scope**: slots in `UnitSlot(U, N, _)`
3. **Global scope**: world-global names (relations, identities, verbs)

The earliest scope wins. Shadowing is permitted and MUST be reported in the quality tool (RFC #109).

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


### Slot Assignment Semantics

A unit's verbs assign to unit slots via `let`-like syntax or direct assignment, creating a transactional `UnitSlot` fact. [R-slot-assign]

**Each assignment is a transactional write:** if slot `S` in unit `U` has value `V1` and a verb assigns `V2`, the old fact retracts and the new fact asserts in one transaction. No in-between state is visible to readers.

**Only a unit's verbs can assign its slots.** A verb in unit `U` can assign to `UnitSlot(U, _, _)`, but not to other units' slots. [R-slot-authority]

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


### Filein Add Mode

**Add mode appends declarations, methods, rules, and facts without retracting.** Add mode filings do not recompile or disturb other units. [R-add-live]

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

```
PROCEDURE AddMode(unit, source):
  -- Prescan declarations (parse identities, relations, type aliases)
  FOR EACH identity_decl IN source.identities:
    IF identity exists with same name:
      reuse existing identity
    ELSE:
      create new identity
  FOR EACH relation_decl IN source.relations:
    IF relation exists with same name and arity:
      reuse existing relation
    ELSE:
      create new relation
  -- Execute filein: install type aliases, methods, rules, run top-level expressions
  install type_aliases(source)
  install methods(source)
  install rules(source)
  execute top_level_expressions(source)
  -- Record ownership facts in append-only fashion
  FOR EACH new_fact IN facts_created:
    assert SourceOwnsFact(unit, fact.relation, fact.tuple)
  RETURN success
```

**Redeclaration is idempotent.** Declaring a relation with the same name and arity reuses the existing relation ID; declaring a verb twice adds a clause alongside existing ones; declaring the same rule text reuses the existing rule ID.

**Ownership facts append:** multiple Add fileins accumulate ownership records; duplicates in `SourceOwnsFact` are permitted.


### Filein Replace Mode

**Replace mode atomically retracts all unit-owned facts, rules, relations, methods, and state, then performs Add.**

```
PROCEDURE ReplaceMode(unit, source):
  START TRANSACTION
  -- Retraction phase retracts everything the unit owns
  retract all SourceOwnsFact(unit, _, _) facts [R-replace-retracts]
  retract all SourceOwnsRule(unit, _) records
  retract all SourceOwnsRelation(unit, _) records
  retract all SourceOwnsTypeAlias(unit, _) records
  retract all SourceOwnsIdentity(unit, _) records
  -- Installation phase (same as Add mode)
  add_mode(unit, source)
  -- Atomic commit
  IF installation succeeds:
    COMMIT TRANSACTION
    return success
  ELSE:
    ROLLBACK TRANSACTION
    return error
```

[R-replace-retracts]

<!-- evidence: @R-replace-retracts -->
| Artifact | Before Replace | After Replace (same unit, new source) |
|----------|---|---|
| `SourceOwnsFact(unit, rel, fact)` | Retracted | Only facts from new source present |
| `SourceOwnsRule(unit, rule)` | Retracted | Only rules from new source present |
| `SourceOwnsRelation(unit, rel)` | Retracted | Only relations from new source present |
| Methods (from `UnitSource`) | Retracted | Only methods from new source present |
| `UnitSlot(unit, slot, val)` | Retracted | Only slots from new source present |

**Replace keeps only slots the new source declares.** [R-replace-keeps-declared]

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

**All readers see atomic replacement:** readers see either the old or new unit state, never both. [R-replace-atomic]

<!-- evidence: @R-replace-atomic -->
| Scenario | Before Replace | After Replace Succeeds | After Replace Fails |
|----------|---|---|---|
| Reader at snapshot N | Sees old unit | Still sees old unit until snapshot N+1 | Sees old unit (intact) |
| Reader at snapshot N+1 | Sees old unit | Sees new unit (atomic switch) | N/A (fails at N) |
| Method reference held by task | Executes old method | Task continues with old method; new tasks call new method | Old method continues (unit unchanged) |

This requires kernel-level snapshot versioning or transaction isolation (readers see committed-before or committed-after state, never mid-transaction).

**If Replace mode fails, the unit retains prior state:** no partial updates are visible. [R-replace-failure-safety]

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


### Fileout and Source Reconstruction

**Fileout reconstructs human-readable source code from world state,** producing a file that files back into a running world with round-trip fidelity.

```
PROCEDURE FileoutUnit(unit):
  output = []
  -- Emit identities
  FOR EACH SourceOwnsIdentity(unit, identity) IN world:
    emit "make_identity(:" + identity.name + ")"
  -- Emit relations
  FOR EACH SourceOwnsRelation(unit, relation) IN world:
    emit "make_relation(:" + relation.name + ", " + relation.arity + ")"
  -- Emit type aliases
  FOR EACH SourceOwnsTypeAlias(unit, alias_name) IN world:
    emit type_alias_definition(unit, alias_name)
  -- Emit verbs and methods
  FOR EACH UnitSource(unit, method, source_text) IN world:
    emit source_text
  -- Emit rules
  FOR EACH SourceOwnsRule(unit, rule_id) IN world:
    emit rule_source(rule_id)
  -- Emit unit state (slots)
  FOR EACH UnitSlot(unit, name, value) IN world:
    emit "let " + name + " = " + format(value)
  -- Emit facts
  FOR EACH SourceOwnsFact(unit, relation, tuple) IN world:
    IF NOT is_unit_slot(relation):  -- skip UnitSlot facts (already emitted)
      emit "assert " + relation.name + format(tuple)
  -- Emit authority grants
  FOR EACH authority_pattern_matching_unit IN world:
    emit grant_block(unit)
  RETURN output
```

**Method source text is stored for round-trip fidelity:** `UnitSource(unit, method, source-text)` preserves source; bytecode derives from source.

**Grant blocks are recognized and emitted:** fileout recognizes authority fact patterns and emits grant blocks.

**The round-trip guarantee:** A source file filed in, then filed out, then filed in again MUST produce identical world state (modulo fact order). [R-fileout-roundtrip]

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


### Unit State vs. World State and Drift

**Unit state** (top-level bindings) differs from **world state** (facts, rules, verbs, identities), diverging when a slot is retracted by another unit or manual override. The quality tool (draft-ndn-quality-tool-00, PR #109) detects and reports divergences. [R-drift-detect]

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

**Unit state is immutable by verbs outside the unit:** only a unit's own verbs can modify its state (via Replace mode or direct assignment), preventing accidental divergence while allowing intentional updates.


## Data Model

```
RECORD UnitSlot:
    unit        : Symbol            -- the unit that declared this slot
    name        : String            -- the binding name
    value       : Any               -- the slot's current value

RECORD UnitSource:
    unit        : Symbol
    method      : MethodId
    source_text : String            -- human-readable source code

ENUM FileinMode:
    ADD                             -- append mode: no retractions
    REPLACE                         -- replace mode: atomic retract + append
```

`UnitSlot.unit` MUST be interned; `UnitSlot.name` MUST conform to verb-name syntax; `UnitSlot.value` MAY be any ground term.


## Out of Scope

**Install authority gate (PR #118):** authority to file source, make_identity/make_relation, program registry, and install gate.

**Quality tool implementation (PR #109):** this RFC names quality-tool responsibilities (drift detection) but does not specify implementation.


## Alternatives Considered

**Why not immutable unit state?** Smalltalk and Self permit mutation; living systems require state evolution.

**Why not per-unit relations for state?** Per-unit relations require pre-declaration; a single `UnitSlot` simplifies fileout and allows any type.

**Why not bytecode reconstruction for fileout?** Bytecode reconstruction is compiler-version-dependent; storing source guarantees exact round-trip fidelity.

**Why atomically replace instead of incremental update?** Atomic Replace ensures consistency; incremental updates risk inconsistent state if a filein fails mid-way.


## Security Considerations

**Slot assignment authority:** only a unit's verbs can modify its slots; authority to file source is gated by PR #118; once running, verbs inherit unit authority.

**Slot reads:** no read barriers; verbs can read any unit's slots (consistent with Smalltalk and Self); sensitive data must use guarded relations.

**Replace mode atomicity:** old or new unit state is visible, never mixed; cached method references from old units continue working with old code.


## Compatibility

**Backward compatibility:** omica's semantics match Rust's design; this RFC codifies them and extends minimal implementation.

**Upgrade path:** fileins without `let` bindings are unchanged; new fileins create persistent `UnitSlot` facts without migration.

**Status (September 2026):** unit state is not yet implemented in omica; this RFC guides development.


## References

- PR rdaum/omica#117: [Filing into a running world](https://github.com/rdaum/omica/pull/117) — per-method programs and world_filein primitives
- PR rdaum/omica#118: [Install authority and source registry](https://github.com/rdaum/omica/pull/118) — make_identity, make_relation, compile, install_source, program registry, and install gate
- draft-ndn-quality-tool-00 (PR rdaum/omica#109): Quality tool and diagnostics — drift detection, schema validation, and consistency auditing
- [Per-method programs design](https://rdaum.github.io/omica/docs/per-method-programs-design.md) — unit identity and verbs in omica
- [Incremental maintenance design](https://rdaum.github.io/omica/docs/incremental-maintenance-design.md) — snapshot versioning for Replace mode atomicity
- Smalltalk language documentation: instance variables, packages, and fileout semantics
- Self language documentation: slots, prototypes, and hot-reload patterns
