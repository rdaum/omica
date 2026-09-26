# draft-ndn-authority-00: Authority and Grants

**Status:** DRAFT
**Corpus:** red (spec-first; evidence is the acceptance criteria)
**Category:** Standards-Track
**Authors:** Norman Nunley, Jr. <nnunley@gmail.com>

## Abstract

This RFC specifies how omica enforces access control: reading and writing relations, invoking verbs, and triggering effects. Authority is minted at task startup from policy facts and delegated through roles. Capabilities are revocable, attenuable tokens adopted at runtime to extend authority without modifying policy.

## Motivation

Mica is a database, a programming language and a runtime, and many actors share one live world. Authority lets them share it safely: policy is stored as facts (database), checked on every read, write, call and effect (runtime), and passed between verbs as capabilities (language). rdaum/omica#118 adds a gate on installing source and rdaum/omica#117 installs per-method programs; both rely on the rules written down here.

## Terminology

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in BCP 14 (RFC 2119, RFC 8174) when, and only when, they appear in all capitals, as shown here.

- **Actor** — an identity at runtime: a principal UUID minted via `make_identity`. Actors hold or delegate authority.
- **Principal** — a named role in policy facts (Can*, RoleCan*, Delegates relations). Principals are actor UUIDs or role names; they are not endpoints.
- **Authority** — a struct minted at task startup from policy facts: sets of principals (actors and delegated roles) permitted to read/write relations, invoke verbs, and trigger effects.
- **Capability** — an ephemeral in-memory grant token created at runtime: a right (Read, Write, Invoke, Effect, Grant), a scope (All, Relations, Selectors, Mailbox, Subscription), and optional expiry (deadline wall-tick or epoch version).
- **Root authority** — a marker (nil actor) that passes all checks. Used for loaders and system tasks during bootstrap. Non-nil authority is restricted.
- **Verb-to-verb dispatch** — a verb calling another verb via selector matching; each call is re-dispatched under the caller's authority context, unless overridden by `assume_actor`.
- **Filein** — loading relations, rules, and verbs into a running world; filein sugar allows writing grants as facts before installation.

## Specification

This RFC does not define the source-install gate (rdaum/omica#118) or catalogue mutation authority.

**Authority is policy-based and enforced on every operation.** Every read, write, invocation, and effect is verified against an actor's direct authority and delegated roles before execution. If denied, the operation fails immediately with `PermissionDenied`; no partial state changes.

### Policy Relations

Policy facts hold authority. All are ordinary relations queryable at any time.

```
-- Direct authority facts, keyed on actor or principal
CanRead(principal: Identity, relation: Identity)
CanWrite(principal: Identity, relation: Identity)
CanInvoke(principal: Identity, method_or_selector: Value)
CanEffect(principal: Identity)

-- Delegation facts, keyed on [actor, role]
Delegates(actor: Identity, role: Identity, level: Integer?)
RoleCanRead(role: Identity, relation: Identity)
RoleCanWrite(role: Identity, relation: Identity)
RoleCanInvoke(role: Identity, method_or_selector: Value)
RoleCanEffect(role: Identity)
```

**Authority is minted at task startup.** The runtime scans `CanRead(A, ?)` and `RoleCanRead(role, ?)` for each role `B` where `Delegates(A, B, _)` exists. The scan runs once; authority is not recomputed on policy changes unless the task restarts. [R-auth-minted-once]

<!-- evidence: @R-auth-minted-once -->
| Scenario | Setup | Behavior |
|----------|-------|----------|
| Authority minted once at startup | Task spawns with actor A; CanRead(A, R1) exists | Query R1 permitted; later adding CanRead(A, R2) to policy does not permit R2 until task restarts |
| Scan includes delegated roles | Task spawns with actor A; Delegates(A, roleB, 0) and RoleCanRead(roleB, R1) exist | Query R1 permitted (via roleB delegation) |

**Authority is additive: roles extend the actor's authority.** Each delegated role appends its Can*/RoleCan* facts to the task's authority. If the actor lacks read authority but a delegated role grants it, the read is permitted. [R-delegation-additive]

<!-- evidence: @R-delegation-additive -->
| Scenario | Setup | Behavior |
|----------|-------|----------|
| Role grants permission | Actor A has no direct CanRead(A, R1); Delegates(A, roleB, 0) and RoleCanRead(roleB, R1) exist | Query R1 permitted via roleB |
| Additive rights | Actor A has CanRead(A, R1); Delegates(A, roleB, 0) and RoleCanRead(roleB, R2) exist | Both R1 and R2 queryable |

### Root Authority

Root authority (root=true) is a nil actor used for loaders and system tasks. Root MUST pass all authorization checks; non-root MUST enforce all checks. [R-root-passes-all]

<!-- evidence: @R-root-passes-all -->
| Scenario | Setup | Behavior |
|----------|-------|----------|
| Root task bypasses authority | Task spawned with nil actor; authority.root=true | All reads, writes, invokes, effects permitted without checking policy |
| Non-root task enforces checks | Task spawned with actor A; authority.root=false | All operations checked against Can*/RoleCan* facts |

### Enforcement Points

Authority is checked before every operation. If an operation is denied, no state changes are visible.

**Read authority** is checked when querying relations or reflecting over catalogue. A denied read MUST return an empty result. [R-read-denied-empty]

<!-- evidence: @R-read-denied-empty -->
| Scenario | Setup | Behavior |
|----------|-------|----------|
| Denied read returns empty | No CanRead(A, R) fact | Query R returns empty set |
| Permitted read succeeds | CanRead(A, R) exists | Query R returns matching rows |

**Write authority** is checked when asserting or retracting tuples. A denied write MUST raise `PermissionDenied` before any change. [R-write-denied-no-partial]

<!-- evidence: @R-write-denied-no-partial -->
| Scenario | Setup | Behavior |
|----------|-------|----------|
| Denied write fails atomically | No CanWrite(A, R) fact | Assert to R raises PermissionDenied; relation unchanged |
| Permitted write succeeds | CanWrite(A, R) exists | Assert to R succeeds; tuple added |

**Invoke authority** is checked when dispatching a verb by selector. The dispatch process performs method resolution (ordering by arity and type), then filters candidates by `authority.can_invoke_method()`, selecting the first authorized. When CanInvoke is keyed on a selector, the check applies to all matching methods. [R-invoke-filtered-dispatch]

<!-- evidence: @R-invoke-filtered-dispatch -->
| Scenario | Setup | Behavior |
|----------|-------|----------|
| Authorized candidate selected | Two methods match selector; CanInvoke(A, m1) exists | m1 invoked; m2 skipped |
| Unauthorized candidates filtered | Two methods match selector; neither authorized | Dispatch fails with NoApplicableMethod |

Verb-to-verb dispatch (a verb calling another verb) goes through the same check: the call is re-dispatched under the caller's authority context unless the method is wrapped in an `assume_actor(actor_id)` block, which temporarily switches to that actor's authority. [R-verb-to-verb-authority-context]

<!-- evidence: @R-verb-to-verb-authority-context -->
| Scenario | Setup | Behavior |
|----------|-------|----------|
| Verb calls verb with caller's authority | Verb v1 (actor A) invokes v2; CanInvoke(A, v2) exists | v2 dispatched under A's authority |
| Assume-actor switches context | Verb v1 (actor A) has assume_actor(B) block; CanInvoke(B, v2) exists, CanInvoke(A, v2) absent | v2 inside block dispatched under B's authority |

**Effect authority** is checked when emitting effects (`emit(target, value)`), asserting/retracting relations, and raising/requiring errors. A denied effect MUST raise `PermissionDenied`. [R-effect-denied-no-partial]

<!-- evidence: @R-effect-denied-no-partial -->
| Scenario | Setup | Behavior |
|----------|-------|----------|
| Denied effect fails | No CanEffect(A) fact | emit() raises PermissionDenied; no message sent |
| Permitted effect succeeds | CanEffect(A) exists | emit() sends message to target |

**Subscription authority** is checked when creating a subscription via `subscribe_changes()`. The returned capability is tied to the actor's authority; canceling revokes it. [R-subscription-ties-actor-authority]

<!-- evidence: @R-subscription-ties-actor-authority -->
| Scenario | Setup | Behavior |
|----------|-------|----------|
| Subscription binds actor authority | Task A calls subscribe_changes(sender, subject, R, ...) | Returned capability tied to A; revoking affects subscriptions tied to A |
| Cancel revokes capability | Subscription cap created by A; cancel called | Cap revoked; further messages on that subscription fail |

### Capabilities

A capability comprises:
- Right set: Read, Write, Invoke, Effect, Grant
- Scope: All, Relations, Selectors, Mailbox, Subscription
- Targets
- Optional limits: deadline, epoch

**Capabilities are ephemeral.** They MUST NOT be serialized; they exist only in RAM. [R-capabilities-ephemeral]

<!-- evidence: @R-capabilities-ephemeral -->
| Scenario | Setup | Behavior |
|----------|-------|----------|
| Capability not in snapshot | Task A mints a capability | Snapshot taken; capability absent from snapshot |
| Capability lost on restart | Task A mints capability C; task restarts | C does not exist in restarted task |

**Capability mint** creates a new grant via `mint_capability(rights, scope, targets, limits?)`. Minting MUST require Grant right. [R-mint-requires-grant]

<!-- evidence: @R-mint-requires-grant -->
| Scenario | Setup | Behavior |
|----------|-------|----------|
| Authorized mint succeeds | Task A has CanGrant(A) or adopted Grant capability | mint_capability succeeds; capability created |
| Unauthorized mint fails | Task A has no Grant authority | mint_capability raises PermissionDenied |

**Capability restrict** derives a weaker capability via `restrict_capability(parent, subset_of_rights)`. It MUST inherit the parent's scope and targets. If the parent is revoked, all children MUST be revoked. [R-restrict-inherits-scope-targets]

<!-- evidence: @R-restrict-inherits-scope-targets -->
| Scenario | Setup | Behavior |
|----------|-------|----------|
| Restrict inherits scope | Cap1 has Relations scope targeting [R1, R2] and Read right; restrict to Write | Cap2 has Relations scope targeting [R1, R2] and Write right only |
| Parent revoke cascades | Cap1 (parent) has child Cap2; revoke Cap1 | Cap2 also revoked |

**Capability revoke** sets the revoked flag and recursively revokes all children. Revocation MUST be immediate; holders observe it on the next check. [R-revoke-atomic-transitive]

<!-- evidence: @R-revoke-atomic-transitive -->
| Scenario | Setup | Behavior |
|----------|-------|----------|
| Immediate revocation observed | Cap revoked; task checks capability on next use | Check fails; capability not live |
| Transitive revocation | Cap1 has children Cap2, Cap3; revoke Cap1 | Both Cap2 and Cap3 also revoked |

**Capability expiry** is checked via `capability_live()`. Checks MUST occur before every use. [R-capability-expiry-deadline-epoch]

<!-- evidence: @R-capability-expiry-deadline-epoch -->
| Scenario | Setup | Behavior |
|----------|-------|----------|
| Deadline expiry | Cap with deadline T1; now is later than T1 | capability_live returns false on check |
| Deadline boundary | Cap with deadline T1; now is T1 | capability_live returns true (expiry is strictly after the deadline) |
| Epoch expiry | Cap with epoch_limit E1; world epoch is E1 or later | capability_live returns false on check |

**Capability check** passes if the capability matches the operation's scope and targets, is live, and grants the right. [R-capability-scope-targets-check]

<!-- evidence: @R-capability-scope-targets-check -->
| Scenario | Setup | Behavior |
|----------|-------|----------|
| Capability grants permission | Cap with Read right, Relations scope, targets [R1]; query R1 | Read permitted via capability even without CanRead fact |
| Scope/target mismatch | Cap with Relations scope, targets [R1]; query R2 | Read denied; R2 not in cap targets |

**Capability drop** removes a capability from the task without revoking it; other holders retain it. [R-drop-does-not-revoke]

<!-- evidence: @R-drop-does-not-revoke -->
| Scenario | Setup | Behavior |
|----------|-------|----------|
| Drop does not revoke | Task A and Task B both hold Cap; A drops it | B can still use Cap; A cannot |

**Mailbox capabilities** are created via `mailbox()` as a [receiver, sender] pair. Sending MUST check the sender capability is live; receiving MUST check the receiver capability. [R-mailbox-sender-receiver-caps]

<!-- evidence: @R-mailbox-sender-receiver-caps -->
| Scenario | Setup | Behavior |
|----------|-------|----------|
| Sender checks sender cap | Task A calls send(sender_cap, msg) with valid sender_cap | Message sent |
| Receiver checks receiver cap | Task B calls receive(receiver_cap) with revoked receiver_cap | Receive fails |

### Authority at Startup

When a task spawns with actor `A`, the runtime MUST initialize Authority by:

1. Query `CanRead(A, ?R)` for all relations; add R to authority.read_set
2. Query `Delegates(A, ?role, _)` and collect roles
3. For each role, query `RoleCanRead(role, ?R)` and add to authority.read_set
4. Repeat for Write, Invoke, Effect
5. Set authority.root = false

If `A` is nil, set authority.root = true. [R-startup-scan-delegates]

<!-- evidence: @R-startup-scan-delegates -->
| Scenario | Setup | Behavior |
|----------|-------|----------|
| Actor A with delegated roles | Task starts with A; CanRead(A, R1), Delegates(A, roleB, 0), RoleCanRead(roleB, R2) | Authority includes both R1 and R2 in read_set |
| Root task has no actor | Task starts with nil actor | authority.root = true; all checks pass |

### Assume-Actor Blocks

An `assume_actor(actor_id)` block temporarily switches the task's authority to that actor's. The runtime MUST re-initialize Authority from actor_id's policy facts inside the block. Exiting MUST restore the previous authority. Blocks MAY be nested. [R-assume-actor-nested-restore]

<!-- evidence: @R-assume-actor-nested-restore -->
| Scenario | Setup | Behavior |
|----------|-------|----------|
| Assume-actor switches authority | Task A calls assume_actor(B) block; CanInvoke(B, v) exists | Inside block, v can be invoked (under B's authority); exiting restores A's authority |
| Nested assume-actor | Task A in assume_actor(B) in assume_actor(C) block | Innermost C's authority used; exiting restores to B's; exiting again restores to A's |

### Source Installation Gate

Installation of relations, rules, and verbs requires the `admin` authority gate (rdaum/omica#118), preventing untrusted code from modifying the schema at runtime.

## Formal Grammar

```abnf
principal      = actor / role
actor          = UUID
role           = UUID
level          = DIGIT
UUID           = 8*8 HEXDIG "-" 4*4 HEXDIG "-" 4*4 HEXDIG "-" 4*4 HEXDIG "-" 12*12 HEXDIG
target         = relation-id / selector
relation-id    = UUID
selector       = ALPHA *( ALPHA / DIGIT / "-" / "_" )

policy-relation = "Can" ("Read" / "Write" / "Invoke" / "Effect")
                  "(" principal "," target ")"
delegate-relation = "Delegates" "(" actor "," role ["," level] ")"
role-can-relation = "RoleCan" ("Read" / "Write" / "Invoke" / "Effect")
                    "(" role "," target ")"
```

Notes: **actor** is minted at runtime via `make_identity`. **level** is typically 0 for direct delegation.

## Out of Scope

**Grant blocks in filein.** Filein sugar (#117) is not specified here.

**Endpoint identities.** Remote system communication via endpoints is future work.

**Session-actor binding.** PASETO session binding (#118) is owned by the host layer.

**Revocation notification.** Async notification to remote holders is out of scope.

## Alternatives Considered

**Why separate rights instead of a boolean read-write flag?** Asymmetry (read-only caps, write-only caps) is more expressive than a flag.

**Why separate actor and principal identities?** Keeping them separate allows roles to delegate recursively without conflating identity and naming.

**Why epoch limits on capabilities?** In a live world, a capability's meaning can drift if the schema changes. Epoch limits tie capabilities to a specific world version, preventing stale use after schema migration.

## Security Considerations

**Unauthorized policy writes.** Untrusted writes to policy relations grant arbitrary authority. Policy facts must be protected by write authority (rdaum/omica#118).

**Capability leakage.** Leaked capabilities can be used by untrusted components. Treat capabilities as secrets; do not log or serialize.

**Assume-actor abuse.** `assume_actor` blocks switch authority; misuse can escalate privilege. Verification is the caller's responsibility.

**Revocation delay.** Revocation is not atomic across holders. Tasks may not observe revocation until the next check. Long-running tasks should periodically re-check.

## Compatibility

This RFC formalizes already-implemented behavior. Root authority, policy relations, and authority minting are stable. Capabilities and expiry tracking are deployed.

For systems migrating from earlier versions: tasks must adopt assume-actor or capabilities to operate with restricted authority. Systems running with root authority must transition to policy-based authority before production.

## References

- rdaum/omica#117 (per-method programs)
- rdaum/omica#118 (install authority gate)
- omica/mica/kernel/authority.odin (implementation)
- omica/docs/incremental-maintenance-design.md (epoch tracking)

## Appendix A: Relation to Rust mica

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
