<!-- Structure and boilerplate derived from IETF practice (RFC 7322 style,
     BCP 14/RFC 8174); Specification body shape derived from NLSpec
     (jhugman/nlspec). Original guidance prose: CC0 — copy freely, owe nothing. -->

# draft-ndn-values-equality-00: Values and Equality

<!-- Unpublished: filename and this title are draft-<author>-<slug>-NN.
     At publication both become RFC NNNN (number taken from index.md). -->

**Status:** DRAFT
**Corpus:** red (spec-first — evidence is the acceptance criteria)
**Category:** Standards-Track
**Authors:** Norman Nunley, Jr. <nnunley@gmail.com>


## Abstract

This RFC defines omica's value domain (integers, floats, text, collections, identities, relations, capabilities, functions, frobs) and two equalities: canonical equality (strict, for storage/joins) and language `==` (numeric, 1 == 1.0 true). Canonical forms carry a total order.


## Motivation

Mica is a database, a programming language and a runtime, and values cross all three: the language compares them, the database stores and joins them, the runtime holds them in tasks. Like Rust mica, omica therefore has two equalities: `==` compares numerically (1 == 1.0 is true), while storage and joins compare strictly (int(1) ≠ float(1.0)). Persistent storage adds a distinct problem: capabilities and functions are VM-local and become invalid after restart. This RFC defines the value domain, distinguishes the two equalities, and specifies persistence eligibility—invariants downstream specs depend on. Differential run D-006 found omica and Rust mica agree on int/float join equality.


## Terminology

Key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHOULD", "MAY", "OPTIONAL" per BCP 14 (RFC 2119).

- **value**: data unit (int, float, identity, symbol, string, bytes, list, map, range, error, relation, capability, function, frob)
- **canonical equality**: strict kind+payload equality (storage, joins, deduplication); int(1) ≠ float(1.0)
- **language equality**: numeric equality (`==`); 1 == 1.0 is true
- **persistent**: eligible for serialization; recursively persistent if all cells are
- **ephemeral**: VM-local only; capabilities and functions cannot persist


## Specification

This RFC defines omica's value domain, the two equalities and their uses, and persistence eligibility. It does NOT define the type system (draft-ndn-declarations-catalogue-00), join semantics (draft-ndn-rules-derivation-00), error recovery (draft-ndn-language-00), or authority (draft-ndn-authority-00).

**Principle: immutability.** Values are immutable; modifications create new values.

**Principle: canonical forms.** Storage, indexes, and deduplication use canonical equality: same kind tag AND identical payloads, bit-for-bit.

**Principle: dual equality.** Language equality (`==`) permits numeric comparison; canonical equality forbids it. Intentional, not a bug.

**Principle: total order.** All values have a deterministic total order by kind tag, then within-kind, for canonicalization and index consistency.

### Value Domain and Storage

```
RECORD Value:
    kind: Kind                          -- type of this value
    payload: u64                        -- immediate or heap pointer

ENUM Kind:
    BOOL, INT, FLOAT, IDENTITY, SYMBOL, STRING, BYTES,
    LIST, MAP, RANGE, ERROR, RELATION, CAPABILITY, FROB, FUNCTION
```

**Kind tag ordering:** Bool < Int < Float < Identity < Symbol < ErrorCode < String < Bytes < List < Map < Range < Error < Capability < Frob < Function < Relation. Used in canonical sort, map canonicalization, and relation row deduplication to prevent index ambiguity.

### Integer Values

56-bit signed range [-2^55, 2^55-1]. [R-int-domain]

<!-- evidence: @R-int-domain -->
| Behavior | Rust | omica | RFC |
|----------|------|-------|-----|
| Range [-2^55, 2^55-1] | Enforced | Enforced | MUST enforce |
| Overflow rejection | ValueError | ValueError | MUST reject |
| Silent truncation | No | No | MUST NOT |

**Range enforcement:** Constructor rejects out-of-range inputs with ValueError; 56-bit allows immediate tagged storage and aligns with IEEE binary32 precision. [R-int-reject-overflow]

<!-- evidence: @R-int-reject-overflow -->
| Input | Expected |
|-------|----------|
| `int(±36028797018963967)` | Valid |
| `int(36028797018963968)` | ValueError |

### Float Values

IEEE 754 binary32, excluding NaN, Infinity, subnormals; -0.0 canonicalized to +0.0. [R-float-domain]

<!-- evidence: @R-float-domain -->
| Behavior | Rust | omica | RFC |
|----------|------|-------|-----|
| binary32 domain | Yes | Yes | MUST |
| Reject NaN/Infinity | Yes | Yes | MUST |
| Canonicalize -0.0 | Yes | Yes | MUST |
| Reject subnormals | Yes | Yes | MUST |

**Non-finite rejection:** Constructor rejects NaN, Infinity, -Infinity with ValueError; non-finite values break index semantics. [R-float-reject-nonfinite]

<!-- evidence: @R-float-reject-nonfinite -->
| Input | Expected |
|-------|----------|
| `float(1.0)` | Valid |
| `float(NaN)` | ValueError |

**Negative zero canonicalization:** Constructor converts `-0.0` to `+0.0`; sign bit of zero is non-semantic. [R-float-canonicalize-zero]

<!-- evidence: @R-float-canonicalize-zero -->
| Input | Result |
|-------|--------|
| `float(-0.0)` | `+0.0` |
| `-0.0 == +0.0` | true |

### Identity Values

56-bit stable entity reference, created via `make_identity` builtin, persisted in `named_identity(name, id)`. Identity 0 is reserved. [R-identity-stable]

<!-- evidence: @R-identity-stable -->
| Scenario | Result |
|----------|--------|
| `make_identity(:alice)` twice | Same identity |
| Persists to `named_identity` | Durable |
| Process restart | Restored unchanged |

**Stability:** Identity returned for a name is stable across restarts (if `named_identity` is durable); identities are fixed points for long-lived entities. [R-identity-persistent]

<!-- evidence: @R-identity-persistent -->
| Scenario | Result |
|----------|--------|
| Store + restart | Same identity |
| Multiple calls, same name | Identical |

**Uniqueness:** `make_identity(:name)` returns same identity on repeated calls; each name is unique. [R-identity-unique]

<!-- evidence: @R-identity-unique -->
| Scenario | Result |
|----------|--------|
| Same name twice | Same ID |
| Different names | Different IDs |

**Reservation:** Identity 0 is reserved; used as nil-check sentinel. [R-identity-zero-reserved]

<!-- evidence: @R-identity-zero-reserved -->
| Scenario | Result |
|----------|--------|
| Create Identity(0) | Rejected |
| System generation | Starts at 1 |

### Symbol Values

32-bit interned string ID; `intern(:name)` returns same ID across calls; global table (L16 cache + global). [R-symbol-intern]

<!-- evidence: @R-symbol-intern -->
| Scenario | Result |
|----------|--------|
| `intern(:x)` twice | Same ID |
| `intern(:x)` vs `intern(:y)` | Different IDs |
| Two threads | Same ID (synchronized) |

**Interning:** Global symbol table never deallocates (names leak); survives relation/query lifetime. Reference counting would dominate creation cost. [R-symbol-leak-acceptable]

<!-- evidence: @R-symbol-leak-acceptable -->
| Scenario | Behavior |
|----------|----------|
| Many `intern` calls | Memory grows (append-only) |
| Long-running process | No deallocation |
| Trade-off | Simplicity > leaks |

**Equality:** Two symbols equal iff same ID; implementation never compares strings. [R-symbol-id-equality]

<!-- evidence: @R-symbol-id-equality -->
| Scenario | Result |
|----------|--------|
| Same name | true (same ID) |
| Different names | false (different IDs) |
| Comparison | ID only, not string |

### String and Bytes Values

String: UTF-8 text, Arc-shared, immutable. Bytes: raw sequence, Arc-shared, immutable. [R-string-bytes-immutable]

<!-- evidence: @R-string-bytes-immutable -->
| Scenario | Behavior |
|----------|----------|
| Modify string | Creates new string |
| Modify bytes | Creates new bytes |
| Multiple references | Same heap (Arc) |

**Copy-on-write:** Modifications create new values; existing references persist unchanged. [R-string-bytes-cow]

<!-- evidence: @R-string-bytes-cow -->
| Scenario | Result |
|----------|--------|
| Modify, existing ref | Unchanged |
| Create modified | New value |
| Arc sharing | Multiple refs valid |

### Collection Values (List, Map, Range)

List: ordered [Value]; Map: [(Key, Value)] canonical-ordered (int ≠ float); Range: [start, stop). All immutable, recursively persistent. [R-collections-immutable]

<!-- evidence: @R-collections-immutable -->
| Scenario | Behavior |
|----------|----------|
| Modify list element | Creates new list |
| Modify map pair | Creates new map |
| Modify range bounds | Creates new range |

**Map key constraint:** Keys use canonical equality; int and float are never the same key. [R-map-canonical-keys]

<!-- evidence: @R-map-canonical-keys -->
| Scenario | Result |
|----------|--------|
| `map{1 → "a"}.get(1.0)` | Not found |
| `map{1 → "a", 1.0 → "b"}` | Both keys |
| Query with int vs float | Different results |

**Canonical ordering:** Map pairs stored in canonical kind-tag order for reproducible indexes. [R-map-canonical-order]

<!-- evidence: @R-map-canonical-order -->
| Scenario | Result |
|----------|--------|
| Mixed key types | Ordered by kind tag |
| Roundtrip serialization | Same key order |
| Index construction | Deterministic |

### Error and Frob Values

Error: code (Identity | Symbol) + message (String | None). Frob: prototype Identity + tagged value. Both immutable, recursively persistent. [R-error-frob-immutable]

<!-- evidence: @R-error-frob-immutable -->
| Scenario | Behavior |
|----------|----------|
| Modify error code | Creates new error |
| Modify error message | Creates new error |
| Modify frob value | Creates new frob |

### Relation Values

Relation: schema + rows (canonical order). Immutable within snapshot; facts asserted/retracted, never mutated. [R-relation-immutable-snapshot]

<!-- evidence: @R-relation-immutable-snapshot -->
| Scenario | Behavior |
|----------|----------|
| Modify row | Creates new relation |
| Assert fact | Row added |
| Retract fact | Row removed |

**Row ordering:** Canonical order by kind tag, then within-kind value. [R-relation-canonical-rows]

<!-- evidence: @R-relation-canonical-rows -->
| Scenario | Result |
|----------|--------|
| Mixed-type rows | Canonical tag order |
| Deduplication | Same form |
| Index construction | Reproducible |

### Capability and Function Values (Ephemeral)

Capability: VM-local authority. Function: compiled code reference. Both runtime-local only, MUST NOT persist. [R-ephemeral-not-persistent]

<!-- evidence: @R-ephemeral-not-persistent -->
| Scenario | Behavior |
|----------|----------|
| In memory | Valid (capability/function) |
| Across restart | Lost, invalid |

**Non-persistence contract:** Serialize attempt aborts with CapabilityNotEncodable or FunctionNotEncodable; serializing across boundaries is a security and semantic error. [R-ephemeral-codec-error]

<!-- evidence: @R-ephemeral-codec-error -->
| Scenario | Result |
|----------|--------|
| Persist capability | CapabilityNotEncodable |
| Persist function | FunctionNotEncodable |
| Persist list with capability | Rejected (transitive) |


## Canonical Equality Semantics

**Canonical equality:** Same kind tag AND identical payloads/content. [R-canonical-equality]

<!-- evidence: @R-canonical-equality -->
| Scenario | Equal |
|----------|--------|
| `int(1)` and `int(1)` | Yes |
| `int(1)` and `float(1.0)` | No |
| `string("a")` and `string("a")` | Yes |
| `symbol(:x)` and `symbol(:x)` | Yes |

Canonical equality forbids numeric comparison; language equality (`==`) allows it. [R-canonical-no-numeric]

<!-- evidence: @R-canonical-no-numeric -->
Covered by @R-canonical-equality evidence above.

**Integers and floats never canonically equal:** Int and float never equal even with same numeric value; storage and joins must be unambiguous. [R-int-float-never-canonical]

```transcript @R-int-float-never-canonical
$ tools/filein --eval 'return [map{1 -> "int"}.get(1.0), map{1 -> "int"}.get(1), map{1.0 -> "float"}.get(1)]'
[None, "int", None]
```

### Total Ordering

All values have a total order: (tag(A) < tag(B)) OR (tag(A) == tag(B) AND within_kind_order(A, B)). [R-total-ordering]

Kind order: Bool < Int < Float < Identity < Symbol < ErrorCode < String < Bytes < List < Map < Range < Error < Capability < Frob < Function < Relation.

<!-- evidence: @R-total-ordering -->
| Scenario | Result |
|----------|--------|
| `1` vs `1.0` | int < float (kind tag) |
| `"a"` vs `[1]` | string < list |
| `1` vs `3` (int) | `1 < 3` |
| `1.0` vs `1.5` (float) | `1.0 < 1.5` (IEEE) |

**Within-kind ordering:** Bool (false < true); Int/Float/Identity/Symbol (numeric/numeric/u56/ID value); String/Bytes (UTF-8/byte-sequence lexicographic); List (count, element-by-element); Map (canonical pairs); Range (start, stop); Error (code, message); Capability/Function/Relation (identity).

Necessary for canonicalization and indexes; without it, same data has multiple canonical forms. [R-total-order-necessity]

<!-- evidence: @R-total-order-necessity -->
| Concern | Without | With |
|---------|---------|------|
| Map form | Ambiguous | Deterministic |
| Deduplication | Non-deterministic | Identical |
| Index construction | Variable | Stable |
| Serialization | Variable | Idempotent |

## Language Numeric Equality (== Operator)

The `==` operator performs numeric comparison across numeric types. [R-language-equality]

<!-- evidence: @R-language-equality -->
| Expression | Result |
|-----------|--------|
| `1 == 1.0` | true |
| `1 == 1.5` | false |
| `1 == "1"` | false |
| `map{1 → "a"}.get(1.0)` | None |

Convert to common representation; prefer exact int comparison when float is finite and within ±2^55. [R-language-numeric-impl]

<!-- evidence: @R-language-numeric-impl -->
| Comparison | Strategy |
|------------|----------|
| `int(1)` vs `float(1.0)` | Exact int |
| `int(2^54)` vs `float(2^54)` | Exact int |
| `int(2^56)` vs `float(2^56)` | Float result |

Language equality does NOT affect storage or joins; int and float keys are distinct. [R-language-no-storage-coerce]

```transcript @R-language-no-storage-coerce
$ tools/filein --eval 'let m = map{1 -> "i", 1.0 -> "f"}; return [m.get(1), m.get(1.0), 1 == 1.0]'
["i", "f", true]
```

## Persistence Eligibility

Capabilities and Functions MUST NOT persist; encode attempt raises CapabilityNotEncodable or FunctionNotEncodable. [R-ephemeral-must-not-persist]

<!-- evidence: @R-ephemeral-must-not-persist -->
| Scenario | Result |
|----------|--------|
| Persist capability | CapabilityNotEncodable |
| Persist function | FunctionNotEncodable |

Value is persistable iff all cells are; collections inherit property transitively. [R-recursive-persistable]

<!-- evidence: @R-recursive-persistable -->
| Scenario | Persistable |
|----------|-----------|
| [1, 2, 3] | Yes |
| [1, capability(1)] | No |
| List with all persistent | Yes |

## Numeric Conversion Builtins

`parse_int` MUST parse a whole decimal string into an integer and raise `E_INVARG` for a string with no digits or a value outside the integer domain. [R-parse-int] `parse_float` MUST parse a decimal or exponent string into a finite float and raise `E_INVARG` for a non-finite result. [R-parse-float] Both exist in omica and not in Rust mica at 2bbceb0; Ryan Daum's Rust parity plan ([gist](https://gist.github.com/rdaum/4891ed160b0e38e9079744e1f1a0d854)) adds them. `to_int` and `to_float` behave the same in both (differential run D-014).

<!-- evidence: @R-parse-int -->
| Input | omica | Rust 2bbceb0 |
|---|---|---|
| `parse_int("42")` | `42` | no applicable method |
| `parse_int("abc")` | `E_INVARG`: parse_int found no digits | no applicable method |
| `parse_int("999999999999999999")` | `E_INVARG`: parse_int is out of range | no applicable method |

<!-- evidence: @R-parse-float -->
| Input | omica | Rust 2bbceb0 |
|---|---|---|
| `parse_float("3.14")` | `3.14` | no applicable method |
| `parse_float("1.0e2")` | `100` | no applicable method |
| `parse_float("NaN")` | `E_INVARG`: parse_float is out of range | no applicable method |

## Out of Scope

**Type system** (draft-ndn-declarations-catalogue-00), **join algorithms** (draft-ndn-rules-derivation-00), **authority model and delegation** (draft-ndn-authority-00), **error recovery** (draft-ndn-language-00).

## Alternatives Considered

**Three-way equality (strict, numeric, structural)?** A third equality adds a third answer to "are these equal" without a use that the two existing ones miss.

**Common int/float representation?** Float imprecision (e.g., 1.1) and rounding overhead on integers make separate types cleaner.

**Allow NaN and Infinity?** NaN is not equal to itself, so an index cannot find it; rejecting all non-finite values keeps one rule.

**Persistable capabilities via re-issue?** Re-issuing a capability after restart is an authority decision; draft-ndn-authority-00 owns it.

## Security Considerations

**Capability persistence:** Non-persistent capabilities prevent unintended authority grants. Persist attempts abort immediately with CapabilityNotEncodable, surfacing errors rather than silently dropping.

**Float precision:** Imprecise floats (IEEE 754) may not rejoin after restore (e.g., 1.1 → 1.0999...). Use integers or symbols for canonical joins.

**Symbol interning:** Symbols leak memory; unbounded `intern` calls exhaust memory. Access control boundary (draft-ndn-authority-00).

## Compatibility

RFC formalizes current behavior; Rust and omica implementations already match (differential D-006). No data or code changes required; float canonicalization (-0.0 → +0.0) is a one-time read correction.

## Appendix A: Relation to Rust mica

| Behavior | Rust 2bbceb0 | omica | This RFC | Class |
|---|---|---|---|---|
| `parse_int`, `parse_float` | No | Yes | Yes | Improvement |
| `to_int` on an exactly integral float; `E_TYPE` otherwise | Yes | Yes | Yes | Parity |
| `to_float` | Yes (prints `4.2e1`) | Yes (prints `42`) | Yes | Parity; float literal printing differs |

## References

- RFC 2119, RFC 8174: BCP 14 keywords
- Differential D-006: Int vs float parity (Rust and omica dual-equality model)
- RFC-03: Rules and Derivation
- RFC-04: Backward Chaining
- RFC-07: Language
- RFC-08: Authority and Grants
