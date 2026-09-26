# draft-ndn-language-00: Language: Recover, Exhaustive Match, Catch Patterns and Dispatch

**Status:** DRAFT

**Corpus:** red (spec-first — evidence is the acceptance criteria)

**Category:** Standards-Track

**Authors:** Norman Nunley, Jr. <nnunley@gmail.com>

## Abstract

Omica's language layer has three gaps: recover expressions lack parsing and compilation; match exhaustiveness is unchecked at compile time; catch clauses don't support dynamic patterns or guards. This RFC closes these gaps by adopting Rust's semantics while preserving omica's extensions (optional/rest verb parameters, rule-management/capability builtins).

## Motivation

Mica is a database, a programming language and a runtime; this RFC touches the language face, and the runtime sees it only as the errors a task raises or recovers from. omica lacks three features Rust mica has: `recover` expressions, compile-time match exhaustiveness, and catch clauses with patterns and guards. Code written for Rust mica fails to compile in omica or needs rewriting. The project decided to close all three gaps with Rust's semantics and keep omica's extensions.

## Terminology

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD",
"SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this
document are to be interpreted as described in BCP 14 (RFC 2119, RFC 8174)
when, and only when, they appear in all capitals.

- **closed structural type** — algebraic type with known, finite cases; `option<T>` (some/none) and `result<T, E>` (ok/err)
- **dynamic value** — value whose type is unknown at compile time
- **recover expression** — error recovery mechanism that yields a value
- **verb-to-verb call** — dispatch between verbs in the same method; resolves specificity per method

## Specification

Defines: (1) recover expressions (D-007); (2) match exhaustiveness checking (D-008); (3) catch patterns and guards (D-009); (4) verb dispatch semantics (D-015, #117). References runtime compile builtin (#118) without redesigning it. Out of scope: error handling, trait dispatch, program registry.

### Recover Expressions

Syntax: `recover EXPR catch PATTERN [if GUARD] => EXPR ... end`.

[R-recover-expr-value] Recover MUST be expression-valued; every branch produces a value. On error, catch clauses evaluate in source order; first match's `=>` becomes the result. Unmatched errors propagate. [R-recover-guards] Guards MUST be supported and evaluated after pattern match, before `=>`.

```transcript @R-recover-guards
$ tools/filein --eval '
  let result = recover raise :E_SAMPLE, "msg", 5
    catch :E_SAMPLE as err if err.value > 3 => :big
    catch :E_SAMPLE => :small
  end
  return result
'
:big
? 0
```

```transcript @R-recover-expr-value
$ tools/filein --eval '
  let result = recover raise :E_SAMPLE, "msg"
    catch :E_SAMPLE as err => :recovered
  end
  return result
'
:recovered
? 0
```

### Match Exhaustiveness

[R-structural-exhaustive] All match expressions MUST validate exhaustiveness at compile time. Matches over closed structural types MUST cover every case; errors MUST name missing cases. [R-dynamic-wildcard] Matches over dynamic values MUST have an unguarded wildcard case (`case _ => ...`) if any case is guarded, else the compiler rejects it.

```transcript @R-structural-exhaustive
$ tools/filein --eval '
  let value: option<int> = some(1)
  match value
  case some(n) => n
  end
'
error: non-exhaustive structural relation match; missing: none
? 1
```

```transcript @R-dynamic-wildcard
$ tools/filein --eval '
  let value = some(1)
  match value
  case some(n) if n > 0 => "positive"
  case some(n) => "zero or negative"
  end
'
error: a match on a dynamic value requires an unguarded wildcard case
? 1
```

### Catch Clauses with Patterns and Guards

[R-catch-pattern] A catch clause MUST accept a pattern (error code, structured pattern, or binding). [R-catch-guard] Guards MUST be supported and evaluated after pattern match.

```transcript @R-catch-pattern
$ tools/filein --eval '
  try
    raise :E_SAMPLE, "msg", 42
  catch :E_SAMPLE as err if err.value > 40 =>
    return "large error"
  catch :E_SAMPLE =>
    return "small error"
  end
'
large error
? 0
```

```transcript @R-catch-guard
$ tools/filein --eval '
  try
    raise :E_SAMPLE, "first", 10
  catch :E_SAMPLE as err if err.value > 20 =>
    return "large"
  catch :E_SAMPLE as err if err.value > 5 =>
    return "medium"
  catch _ =>
    return "other"
  end
'
medium
? 0
```

### Verbs and Dispatch

Verbs are named procedures reached by role and receiver dispatch. A verb MUST accept defaulted parameters (`?name = default`) and a rest parameter (`@tail`); omica supports both, Rust mica does not. [R-verb-param-extended]

```transcript @R-verb-param-extended
$ tools/filein --eval '
  verb process(?tag = :default, @extra) => {:tag -> tag, :extra -> extra} end
  return :process(?tag = :custom, 1, 2, 3)
'
{:tag -> :custom, :extra -> [1, 2, 3]}
? 0
```

[R-per-method-dispatch] Every verb-to-verb call MUST dispatch independently, resolving specificity through the receiver's delegate chain; global shared dispatch is prohibited.

```transcript @R-per-method-dispatch
$ tools/filein --eval '
  verb outer() => :process() end
  verb process() => :default end
  method #special process() => :special end
  return #special:outer()
'
:special
? 0
```

[R-closures-cross-verbs] Functions and closures MUST be values that can be passed across verb boundaries and stored in unit state.

```transcript @R-closures-cross-verbs
$ tools/filein --eval '
  let saved = {x} => x + 1
  verb apply(fn) => fn(5) end
  return :apply(saved)
'
6
? 0
```

### Runtime Compile Builtin

The `compile(source: String) -> Result<Function, Error>` builtin compiles source at runtime (issue #118). This RFC references it without redesigning its semantics, authority model, or program registry integration.

### Strings, Loops and Comprehensions

These forms run in omica and are rejected by Rust mica at 2bbceb0. Ryan Daum's Rust parity plan ([gist](https://gist.github.com/rdaum/4891ed160b0e38e9079744e1f1a0d854)) found the same set and adds them to Rust. Results below are differential runs D-013 and D-015 to D-019.

`len` MUST accept a string and count its Unicode scalar values. [R-len-string]

<!-- evidence: @R-len-string -->
| Input | omica | Rust 2bbceb0 |
|---|---|---|
| `len([1, 2, 3])` | `3` | `3` |
| `len({:a -> 1, :b -> 2})` | `2` | `2` |
| `len("héllo")` | `5` | error: len expects a list, map, or relation |

Indexing a string MUST address Unicode scalar values and yield the scalar's code point; an index past the end MUST raise `E_INDEX`. [R-string-index-scalar]

<!-- evidence: @R-string-index-scalar -->
| Input | omica | Rust 2bbceb0 |
|---|---|---|
| `"héllo"[0]` | `104` | `E_INDEX` |
| `"héllo"[1]` | `233` | `E_INDEX` |
| `"hello"[10]` | `E_INDEX` | `E_INDEX` |

The runtime MUST provide `string_append`, `string_span` and `string_find_any`. [R-string-builtins]

<!-- evidence: @R-string-builtins -->
| Input | omica | Rust 2bbceb0 |
|---|---|---|
| `string_append("hello", " world")` | `"hello world"` | no applicable method |
| `string_span("hello world", 0, " ")` | `0` | no applicable method |
| `string_find_any("hello world", 0, " o")` | `4` | no applicable method |

A `for` header MUST accept a list pattern that binds each element of the item, and `_` in a `for` header MUST bind nothing. [R-loop-patterns]

<!-- evidence: @R-loop-patterns -->
| Input | omica | Rust 2bbceb0 |
|---|---|---|
| `for [a, b] in [[1, 2], [3, 4]]` appending `a + b` | `[3, 7]` | parse error: expected expression |
| `for _ in [1, 2, 3]` counting iterations | `3` | parse error: expected expression |

A list comprehension `[expr for x in list]` MUST evaluate `expr` once per element, in order, and yield the results as a list. [R-list-comprehension]

<!-- evidence: @R-list-comprehension -->
| Input | omica | Rust 2bbceb0 |
|---|---|---|
| `[x * 2 for x in [1, 2, 3]]` | `[2, 4, 6]` | parse error: expected end after for |

## Formal Grammar

Pattern matching integrates at the parser level; this ABNF captures new shapes:

```abnf
recover-expr   = %s"recover" expr
                 catch-clause*
                 %s"end"

catch-clause   = %s"catch" pattern [ %s"if" expr ] %s"=>" expr

pattern        = error-code / wildcard / variable-binding

error-code     = ":" ALPHA *( ALPHA / DIGIT / "_" )

wildcard       = "_"

variable-binding = ALPHA *( ALPHA / DIGIT / "_" ) [ %s"as" ALPHA *( ALPHA / DIGIT / "_" ) ]

expr           = 1*ALPHA  ; placeholder: any expression in the language grammar
```

## Out of Scope

**Anonymous error syntax.** Inline error literals are out of scope; use explicit pattern matching.

**Typed catch bindings.** No type annotations on bound variables (e.g., `catch :E_SAMPLE as err: Error => ...`).

**Fallthrough.** No fallthrough to next catch clause; every clause is terminal or raises.

## Alternatives Considered

**Why recover, not just catch?** `recover` is an expression: each clause yields the value, so code binds the result directly instead of assigning a local inside `try`.

**Why keep omica's parameters?** Existing omica code uses defaulted and rest parameters; dropping them to match Rust would break it.

**Why compile-time exhaustiveness?** A missing case then fails when the verb is installed, not when a running task first reaches it.

## Security Considerations

Recover expressions and catch patterns are evaluated in the caller's authority context; no new boundaries are crossed. The `compile` builtin inherits caller context per RFC #118.

## Compatibility

Existing code continues to work. Try/catch with static codes remains valid; dynamic patterns are additive. Optional/rest verb parameters are already lexed; this RFC formalizes parsing.

## References

- CHUNK-007b/007c — Rust test vectors
- rdaum/omica#117 — per-method programs
- rdaum/omica#118 — runtime compile builtin

## Appendix A: Relation to Rust mica

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
