# draft-ndn-quality-tool-00: A Relational Code-Quality Tool for Omica

**Status:** DRAFT
**Corpus:** red (spec-first; the evidence is the acceptance criteria and no implementation exists yet)
**Category:** Experimental
**Authors:** Norman Nunley, Jr. <nnunley@gmail.com>


## Abstract

This document specifies `apps/quality`, a Mica application that measures a
Mica world: the verbs, rules, relations and grants installed in it, whether
the world is running, stored, or built from source for the run. It also
measures omica's Odin source. It scores with the erosion and verbosity
metrics of SlopCodeBench [SCB], adds dead-code, coverage, defect and testing
terms, and checks rule, relation and grant health. Every finding is a fact in
a Mica relation, so the command-line report, the agent tool and ad hoc
queries all read the same data.

## Motivation

Mica is a database, a programming language and a runtime at once, a blend
of Smalltalk's live image, Self's prototypes and a Datalog database:
behavior is installed into a live world beside its facts, and the world,
not any source file, is the source of truth. A verb can be filed in, replaced or
edited while the world runs, so a tool that reads only files measures what
the world was built from, not what it is. omica has no measure of which
installed code is hard to change, which code the tests never reach, or which
relations and grants are broken. In a relational system the last two fail
silently: a query over a missing fact returns an empty result, not an error.
The world's catalogue already describes its code; this document specifies a
tool that measures the world through it.

## Terminology

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD",
"SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this
document are to be interpreted as described in BCP 14 (RFC 2119, RFC 8174)
when, and only when, they appear in all capitals, as shown here.

- **measured world** — the Mica world whose installed code a run measures.
- **corpus** — the Odin files a run measures, and the Mica files a run files into a fresh measured world when it is not given one.
- **run world** — the disposable Mica world one run creates, analyses and discards.
- **syntax fact** — a row `(node, role, target, ordinal)` describing one edge of a syntax tree, in the shape `parse_rows` produces.
- **callable** — a Mica verb, a top-level Mica `fn`, or an Odin procedure. Nested function literals are part of their enclosing callable.
- **rule** — a Mica relation rule (`Head(...) :- Body`).
- **SLOC** — source lines: lines inside a span that carry at least one token. Blank and comment-only lines do not count.
- **branch point** — a syntax node that adds one independent path through a callable (listed under "Complexity").
- **diagnostic** — a row of `quality/Diagnostic`: one finding with a code, severity, subject and message.
- **term** — one scored dimension, a number in [0, 1] where 0 is perfect.
- **composite** — the weighted mean of the present terms.
- **test root** — where test reachability starts: a top-level expression in a Mica test file, or an Odin procedure marked `@(test)`.

## Specification

This document defines the tool's inputs, the facts it derives, its measures,
its terms and composite, its diagnostics, and its two surfaces: a
command-line report and an agent tool verb. It does NOT define the source
host's git relations beyond the columns the tool reads; the source host owns
them.

**Two subjects, measured side by side.** Mica code exists in two states, and
the tool measures both:

- **World state**: the code installed in the world, as the world holds it:
  methods and their `MethodSource`, rules and their `RuleSource`, relations,
  grants, and what each unit owns. This is what runs.
- **Unit and file state**: the text a unit was filed in from (its
  `UnitSource`), or the files on disk. This is what a fileout, a review or a
  version-control history sees.

They agree right after a filein and diverge as soon as a verb is edited in
the running world and not filed out, as in a Smalltalk image with unsaved
changes. The tool reports each subject in its own scope and reports where
they differ.

**Measuring changes nothing.** A run never writes to the measured world's
durable state. Results live in volatile relations or in a disposable run
world. This follows [BOOTSTRAP] section 5.2.

**Facts in, facts out.** Every input and every finding is a relation in the
run world. Reports render those relations; nothing bypasses them.

**Rules analyse, verbs count.** Transitive analyses (reachability, relation
health) are stratified rules that allocate no identities. Counting measures
and rendering are verbs over a frozen snapshot. This follows [BOOTSTRAP]
section 5.1.

**Every score is a share.** Each term lies in [0, 1], 0 is perfect, and each
moves whenever any input moves. A clamped scale would hide improvement to the
worst code, which is where improvement matters most.

### Data model

Inputs, read from the measured world:

```
-- Catalogue relations the compiler already writes (mica/kernel/dispatch.odin):
--   Relation, RelationName, Arity, FunctionalKey, ConflictPolicy,
--   Rule, RuleHead, RuleSource, ActiveRule,
--   UnitSource, MethodSource, NamedIdentity,
--   SourceOwnsFact, SourceOwnsRule, SourceOwnsRelation
-- Grant relations minted by mica/kernel/authority.odin:
--   CanRead, CanWrite, CanInvoke, CanEffect

RECORD SyntaxFact:                      -- relation quality/Syntax
    file        : String                -- corpus-relative path
    node        : Integer               -- node id, unique within the file
    role        : Symbol                -- :kind, :child, :callee, :op, :name, :line, ...
    target      : Value                 -- a node id, or an attribute value
    ordinal     : Integer               -- position among siblings with the same role

RECORD Callable:                        -- relation quality/Callable
    file        : String
    node        : Integer               -- the callable's root node
    name        : String                -- verb name, or package.proc for Odin
    language    : Language
    first_line  : Integer
    last_line   : Integer

RECORD CallEdge:                        -- relation quality/Calls (derived)
    caller      : Callable
    callee      : Callable | Unresolved -- Unresolved for proc values and dynamic dispatch

ENUM Language:
    MICA
    ODIN
```

Outputs:

```
RECORD Diagnostic:                      -- relation quality/Diagnostic
    id          : Integer
    code        : DiagnosticCode        -- Appendix A
    severity    : Severity
    file        : String
    node        : Integer | None        -- None for file- or corpus-level findings
    message     : String                -- names the measured value and its threshold

RECORD Evidence:                        -- relation quality/Evidence
    diagnostic  : Integer               -- Diagnostic.id
    position    : Integer
    detail      : Value                 -- a call-path step, a clone region, a commit id

RECORD Term:                            -- relation quality/Term
    scope       : String                -- "world", "world/<unit>", "unit/<unit>", "file/<path>", "mica", "odin", or "corpus"
    name        : Symbol                -- :erosion, :verbosity, :uncovered, :dead, :defects, :testing
    raw         : Float                 -- the measured input before shaping
    value       : Float | None          -- in [0, 1]; None when the input is missing

ENUM Severity:
    ERROR       -- a definite defect, such as a dangling grant
    WARNING     -- over a threshold
    NOTE        -- informational
```

**Field constraints:** `Diagnostic.id` values are dense from 1 in emission
order, which is deterministic ([R-deterministic]). `message` holds no
absolute paths or timestamps.

### Configuration

| Key | Type | Default | Description |
|---|---|---|---|
| `--since` | Date or commit | 180 days before the run | Start of the defect window; resolved once to a commit range and printed |
| `--format` | `text` \| `mica` | `text` | `mica` prints the report as one Mica map value |
| `--top` | Integer | `25` | Ranked issues shown in `text` format |
| `--root` | Path | current directory | Repository root; corpus paths are relative to it |
| `--store` | Path | none | A stored world to measure. Without it, the Mica files under the corpus roots are filed into a fresh world |
| paths | Path list | `apps`, `mica`, `host`, `tools` | Corpus roots, walked for `.odin` files, and for `.mica` files when `--store` is absent |

All thresholds, squash constants and weights live in one table in
`apps/quality/`; no other code holds a number. Their defaults appear under
"Terms".

**Resolution precedence** (highest first):

1. Command-line flag
2. Argument passed to `tool/quality`
3. Default from the table above

### The measured world

A run measures one of three worlds (**precedence**, highest first):

1. **The running world**, when `tool/quality` is called inside it. The tool
   reads that world's own catalogue.
2. **A stored world**, given with `--store`. The tool copies the store into a
   temporary directory and boots the copy, so the stored world and its lock
   are untouched.
3. **A fresh world** built by filing the corpus's `.mica` files into an empty
   run world through the ordinary filein path.

The tool MUST read Mica code from the measured world's catalogue, so a verb
edited or filed in while the world runs is measured as it now is. [R-world-subject]

```transcript @R-world-subject
$ tools/filein --store /tmp/qw tests/quality/fixtures/decls/decls.mica > /dev/null
$ tools/filein --store /tmp/qw tests/quality/fixtures/decls/extra-verb.mica > /dev/null
$ tools/quality --store /tmp/qw --format mica | grep -c ':verb :extra'
1
? 0
```

The tool MUST measure complexity, duplication and verbosity for both
subjects: installed code in the `world` and `world/<unit>` scopes, and unit
text or files in the `unit/<unit>` and `file/<path>` scopes. [R-both-subjects]

```transcript @R-both-subjects
$ tools/filein --store /tmp/qw3 tests/quality/fixtures/decls/decls.mica > /dev/null
$ tools/quality --store /tmp/qw3 --format mica | grep -o -E ':scope -> "(world/decls|unit/decls)"' | sort -u
:scope -> "unit/decls"
:scope -> "world/decls"
? 0
```

When a unit's installed code differs from its unit text (a method or rule
the unit owns has no matching definition in the text, or the text defines
one the world lacks), the tool MUST yield one `Q_DRIFT` diagnostic per such
method or rule, naming both sides. [R-drift]

```transcript @R-drift
$ tools/filein --store /tmp/qw4 --unit decls tests/quality/fixtures/decls/decls.mica > /dev/null
$ tools/filein --store /tmp/qw4 --eval 'install_source(:decls, "verb hello() return 2 end")' > /dev/null
$ tools/quality --store /tmp/qw4 | grep Q_DRIFT
unit/decls Q_DRIFT NOTE verb hello is installed with a body that differs from unit decls
? 0
```

A run MUST NOT change the durable state of the world it measures. In the
running world, the tool's own relations are volatile; for a stored world, the
tool boots a copy. [R-measure-without-writing]

```transcript @R-measure-without-writing
$ tools/filein --store /tmp/qw2 tests/quality/fixtures/decls/decls.mica > /dev/null
$ find /tmp/qw2 -type f -exec cksum {} + | sort > /tmp/before
$ tools/quality --store /tmp/qw2 > /dev/null
$ find /tmp/qw2 -type f -exec cksum {} + | sort > /tmp/after
$ cmp /tmp/before /tmp/after && echo unchanged
unchanged
? 0
```

A fresh run world MUST have no store and MUST NOT give the corpus any host
effect: no network, external-request or subscription capability. [R-sandboxed-world]
Filing in runs the corpus's top-level expressions, so this rule bounds what a
hostile or broken corpus can do.

```transcript @R-sandboxed-world
$ tools/quality tests/quality/fixtures/effects | grep Q_LOAD
tests/quality/fixtures/effects/fetch.mica:1 Q_LOAD ERROR external_request is not available while loading a corpus
? 0
```

The tool MUST take Mica syntax facts from `parse_rows` in
`apps/compiler/parse.mica`, applied to each method's `MethodSource` and each
rule's `RuleSource` in the measured world. Line numbers map back to a file
through the owning unit's `UnitSource` when the world has one. [R-mica-syntax-from-parser]

```transcript @R-mica-syntax-from-parser
$ tools/quality --format mica tests/quality/fixtures/one-verb | grep -c ':kind :VerbItem'
1
? 0
```

The tool MUST take Odin syntax facts from `core:odin/parser`, through a
helper `tools/quality-facts` that writes rows in the `quality/Syntax` shape. [R-odin-syntax-from-core]
The language's own parser stays exact as Odin changes; a second parser would drift.

```transcript @R-odin-syntax-from-core
$ tools/quality-facts tests/quality/fixtures/one-proc/p.odin | grep -c 'proc_lit'
1
? 0
```

A file that fails to parse MUST yield one `Q_PARSE` diagnostic and MUST NOT
stop the run. [R-parse-failure-isolated]

```transcript @R-parse-failure-isolated
$ tools/quality --format text tests/quality/fixtures/broken
file tests/quality/fixtures/broken/bad.mica: Q_PARSE ERROR 3:9 expected an expression
file tests/quality/fixtures/broken/good.mica: scored
? 0
```

### Complexity

**Branch points.**

| Language | Branch points (each adds 1) |
|---|---|
| Mica | each conditional `IfBranch` (not a final `else`), each `MatchCase` after the first, `While`, `For`, `Comprehension`, `Catch`, and each `and`/`or` |
| Odin | each `if`/`when` condition (including `else if`), `for`, each `case` after the first in a `switch`, each `&&`/`\|\|`, and each `or_return`, `or_else`, `or_break`, `or_continue` |

The cyclomatic complexity (CC) of a callable MUST be 1 plus its branch
points, including those of nested function literals. [R-cyclomatic]

<!-- evidence: @R-cyclomatic -->
| language | callable body | CC |
|---|---|---|
| mica | `return x` | 1 |
| mica | `if a return 1 elseif b return 2 else return 3 end` | 3 |
| mica | `if a and b return 1 end` | 3 |
| mica | `match v case some(n) n case none 0 end` | 2 |
| odin | `return x` | 1 |
| odin | `if a && b { return 1 }` | 3 |
| odin | `x := f() or_return` | 2 |
| odin | `switch k { case .A: f() case .B: g() case: h() }` | 3 |

The cognitive complexity of a callable MUST follow [COGNITIVE]. Each branch
point adds 1. A branch point that opens a nested block (`if`, `for`,
`while`, `switch`, `match`, `try`) also adds its nesting depth. Each labelled
`break` or `continue` adds 1, and so does each direct recursive call. A run
of one boolean operator counts once. [R-cognitive]

<!-- evidence: @R-cognitive -->
| language | callable body | cognitive |
|---|---|---|
| odin | `if a { return 1 }` | 1 |
| odin | `for x in xs { if x > 0 { n += 1 } }` | 3 |
| odin | `if a && b && c { return 1 }` | 2 |
| odin | `if a && b \|\| c { return 1 }` | 3 |
| mica | `for x in xs if x > 0 n = n + 1 end end` | 3 |

For every callable the tool MUST also compute maximum nesting depth, SLOC,
parameter count, fan-out (distinct resolved callees) and fan-in (distinct
resolved callers). [R-shape-measures]

<!-- evidence: @R-shape-measures -->
| language | callable | nesting | SLOC | parameters |
|---|---|---|---|---|
| odin | `f :: proc(a, b: int) -> int { if a > 0 { for i in 0..<b { a += i } }; return a }` | 2 | 1 | 2 |
| mica | `verb f(a, b) if a > 0 for i in b a = a + i end end return a end` | 2 | 1 | 2 |

For every rule the tool MUST compute rule complexity: its body atoms, with
each negated atom counting 2. [R-rule-complexity]

<!-- evidence: @R-rule-complexity -->
| rule | rule complexity |
|---|---|
| `Path(?x, ?y) :- Edge(?x, ?y)` | 1 |
| `Path(?x, ?z) :- Edge(?x, ?y), Path(?y, ?z)` | 2 |
| `Allowed(?x) :- Person(?x), not Banned(?x)` | 3 |

### Duplication and verbose code

Clone detection MUST use winnowing [WINNOW] with k = 25 tokens and window
w = 40. Tokens come from `lex` in `apps/compiler/lex.mica` for Mica and from
`core:odin/tokenizer` for Odin. Identifiers normalize to `ID`, string and
numeric literals to `STR` and `NUM`, and comments drop out. Files are
compared only with files of the same language. [R-duplication]

```transcript @R-duplication
$ tools/quality tests/quality/fixtures/dup | grep -c Q_DUP
1
? 0
```

Each clone pair MUST yield one `Q_DUP` diagnostic whose evidence names both
regions by file and line range. [R-dup-evidence]

```transcript @R-dup-evidence
$ tools/quality tests/quality/fixtures/dup | grep Q_DUP
tests/quality/fixtures/dup/a.odin:3 Q_DUP WARNING 31 tokens duplicated with tests/quality/fixtures/dup/b.odin:5-14
? 0
```

Verbose-code rules flag lines that add code without adding behavior. They
are rules over syntax facts that derive `quality/Flagged(file, line, rule)`.
The initial set MUST include at least: a branch whose arms are identical; a
`return` of a boolean literal chosen by a condition that is itself the
result; a variable assigned and returned on the next line with no other use;
and an Odin `if cond { return true } return false`. [R-verbose-rules]
[SCB] uses 137 such rules for Python; this set starts small and grows, and
every rule is a Mica rule anyone can read.

<!-- evidence: @R-verbose-rules -->
| language | code | flagged |
|---|---|---|
| mica | `if a return 1 else return 1 end` | yes |
| mica | `let r = f(x)` then `return r` | yes |
| mica | `return f(x)` | no |
| odin | `if ok { return true }; return false` | yes |
| odin | `return ok` | no |

### History

A file's defect count MUST be the number of commits in the `--since` window
whose subject matches `^fix` and which touch the file. Its defect rate is
that count per thousand SLOC. [R-defect-density]
The count reads the source host's git relations; the tool never runs `git`.

<!-- evidence: @R-defect-density -->
| fix commits touching file | SLOC | defects per KSLOC |
|---|---|---|
| 0 | 500 | 0 |
| 1 | 500 | 2 |
| 3 | 500 | 6 |

The report header MUST print the resolved commit range. [R-history-range-printed]

```transcript @R-history-range-printed
$ tools/quality --since 2026-03-01 --root tests/quality/fixtures/repo | head -1
quality 0.1  roots: .  history: 1a2b3c4..9f8e7d6 (2026-03-01..HEAD)
? 0
```

### Reachability

Test roots are the top-level expressions of files under `apps/*/tests/` and
the Odin procedures marked `@(test)`. Production roots are exported Odin
procedures of `mica/*` packages that another package calls, `main`
procedures, verbs a grant names, and top-level expressions outside test
files.

The tool MUST derive `quality/Reached(subject, from)` with stratified rules
equivalent to:

```
Reached(r, k)  :- Root(r, k).
Reached(g, k)  :- Reached(f, k), Calls(f, g).
Reached(rl, k) :- Reached(f, k), Reads(f, rel), RuleHead(rl, rel).
Reached(g, k)  :- Reached(rl, k), RuleBodyReads(rl, rel), Deriving(g, rel).
```

where `k` is `:test` or `:production`. The rules MUST NOT allocate
identities, and an `Unresolved` callee MUST NOT count as reached. [R-reachability-rules]
Guessing unresolved edges would inflate coverage and hide dead code.

<!-- evidence: @R-reachability-rules -->
| fixture | subject | reached from test | reached from production |
|---|---|---|---|
| `reach` | `helper`, called from a test and from `main` | yes | yes |
| `reach` | `only_tested`, called only from a test | yes | no |
| `reach` | `unused`, called by nothing | no | no |
| `reach` | `callback`, called only through a proc value | no | no |

### Terms

Every term MUST lie in [0, 1], with 0 as the best value, and MUST be
reported to three decimal places. [R-terms-bounded]

```transcript @R-terms-bounded
$ tools/quality --format mica tests/quality/fixtures/mixed | grep -c -E ':value -> (0\.[0-9]{3}|1\.000|none)'
7
? 0
```

**Erosion** follows [SCB] section 2.3, equations 2 and 3:

```
mass(f)  = CC(f) * sqrt(SLOC(f))
erosion  = sum of mass(f) over callables with CC(f) > 10
           / sum of mass(f) over all callables
```

The comparison is strict: a callable with CC exactly 10 carries no erosion. [R-erosion]

<!-- evidence: @R-erosion -->
| callables (CC, SLOC) | masses | erosion |
|---|---|---|
| (11, 4), (10, 9), (2, 1) | 22, 30, 2 | 0.407 |
| (10, 9), (2, 1) | 30, 2 | 0.000 |
| (40, 25), (5, 25) | 200, 25 | 0.889 |

**Verbosity** follows [SCB] equation 4: the flagged lines of
[R-verbose-rules] united with clone lines, divided by SLOC. A line that is
both flagged and cloned counts once. [R-verbosity]

<!-- evidence: @R-verbosity -->
| SLOC | clone lines | flagged lines | verbosity |
|---|---|---|---|
| 100 | 10–19 | 15–24 | 0.150 |
| 100 | none | 1–5 | 0.050 |

**Uncovered** is 1 minus the share of callables and rules reached from a test root. [R-uncovered]

<!-- evidence: @R-uncovered -->
| callables and rules | reached from a test | uncovered |
|---|---|---|
| 4 | 2 | 0.500 |
| 10 | 10 | 0.000 |

**Dead** is the SLOC of callables that no root reaches, divided by the SLOC
of all callables. Callables reached only from test roots count as dead
production code and are listed separately. [R-dead]

<!-- evidence: @R-dead -->
| callables (SLOC, reached from) | dead |
|---|---|
| (100, production), (50, test only), (50, none) | 0.500 |
| (100, production), (100, production) | 0.000 |

**Defects** and **testing** are rates, shaped by `squash(v, k) = v / (v + k)`,
which is 0 at 0, strictly increasing, and below 1. `k` sits where a rate
turns bad, so that rate maps to exactly 0.5. Defects use the defect rate with
k = 5 per KSLOC. Testing uses the shortfall below 20 assertions per KSLOC
with k = 10, so meeting 20 scores 0. An assertion is a call to a verb whose
name starts with `test/assert`, or to `testing.expect`, `testing.expectf` or
`testing.expect_value`. [R-squash]

<!-- evidence: @R-squash -->
| term | rate | shaped value |
|---|---|---|
| defects | 0 per KSLOC | 0.000 |
| defects | 5 per KSLOC | 0.500 |
| defects | 15 per KSLOC | 0.750 |
| testing | 20 assertions per KSLOC | 0.000 |
| testing | 10 assertions per KSLOC | 0.500 |
| testing | 0 assertions per KSLOC | 0.667 |

The composite MUST be the weighted mean of the present terms, with weights
renormalized over the terms whose inputs exist. [R-composite]
A missing input, such as history outside a repository, drops its term; it never counts as a perfect score.

| Term | Weight | Source |
|---|---|---|
| erosion | 0.25 | [SCB] |
| verbosity | 0.20 | [SCB] |
| uncovered | 0.20 | this document |
| dead | 0.10 | this document |
| defects | 0.10 | this document |
| testing | 0.15 | this document |

<!-- evidence: @R-composite -->
| erosion | verbosity | uncovered | dead | defects | testing | composite |
|---|---|---|---|---|---|---|
| 0.4 | 0.2 | 0.5 | 0.1 | 0.2 | 0.0 | 0.270 |
| 0.4 | 0.2 | 0.5 | 0.1 | missing | 0.0 | 0.278 |

The tool MUST compute every term for each file, each language and the whole
corpus. Erosion, verbosity and dead are shares, so a wider scope takes the
same ratio over its callables and lines rather than averaging narrower scores. [R-scopes]

<!-- evidence: @R-scopes -->
| file | erosion mass above threshold | total mass | file erosion |
|---|---|---|---|
| a.odin | 200 | 225 | 0.889 |
| b.odin | 0 | 775 | 0.000 |
| corpus (a + b) | 200 | 1000 | 0.200 |

The `text` report MUST print [SCB]'s published baselines next to the
corpus erosion and verbosity: human-written code 0.34 and 0.19,
agent-written code 0.68 and 0.44. [R-baselines]
A number without its reference point cannot be read.

```transcript @R-baselines
$ tools/quality tests/quality/fixtures/mixed | grep -c 'human 0.34, agent 0.68'
1
? 0
```

Maintainability index, cognitive complexity, nesting, SLOC, parameters,
fan-in, fan-out and rule complexity do not enter the composite. They yield
`WARNING` diagnostics above these thresholds: maintainability below 65,
cognitive 15, nesting 4, SLOC 60, parameters 5, fan-out 15, fan-in 20,
rule complexity 6. Erosion already carries complexity weighted by size, and
scoring these as well would count one problem several times.

Ranked issues MUST be ordered by how much fixing each would lower the
composite, largest first, with ties broken by file path and then line. [R-ranking]

<!-- evidence: @R-ranking -->
| issue | composite reduction | file | line | rank |
|---|---|---|---|---|
| CC 74 proc | 0.018 | mica/kernel/b.odin | 40 | 1 |
| clone pair | 0.009 | mica/kernel/a.odin | 10 | 2 |
| verbose return | 0.009 | mica/kernel/a.odin | 90 | 3 |

### Rule and relation health

Each condition below MUST yield one diagnostic per subject. [R-health]

<!-- evidence: @R-health -->
| code | severity | condition |
|---|---|---|
| `Q_DEAD_RELATION` | WARNING | a declared relation that no callable or rule body reads |
| `Q_EMPTY_RELATION` | WARNING | a relation that is read but never asserted, derived or loaded, and is neither computed nor host-provided |
| `Q_MIXED_DERIVATION` | ERROR | a relation that is both a rule head and the target of a direct `assert` |
| `Q_INACTIVE_RULE` | NOTE | a rule whose `ActiveRule` value is false |
| `Q_RULE_COMPLEXITY` | WARNING | rule complexity above 6 |

### Authority and grants

Each condition below MUST yield one diagnostic per grant row or verb. [R-grants]

<!-- evidence: @R-grants -->
| code | severity | condition |
|---|---|---|
| `Q_DANGLING_GRANT` | ERROR | a `CanRead`, `CanWrite`, `CanInvoke` or `CanEffect` row naming an undeclared relation, verb or identity |
| `Q_SYSTEM_GRANT` | ERROR | a grant on a catalogue relation to a subject other than root |
| `Q_DERIVED_WRITE_GRANT` | WARNING | a `CanWrite` grant on a rule head |
| `Q_UNGRANTED_TOOL` | WARNING | a `tool/*` verb that no `CanInvoke` row covers |

### Determinism

Two runs over the same corpus, history range and options MUST produce
byte-identical reports, whatever the file-system order, symbol interning
order or fact insertion order. [R-deterministic]
An agent tuning code against a score that shifts between identical runs chases noise.

```transcript @R-deterministic
$ tools/quality --format mica tests/quality/fixtures/mixed > /tmp/q1
$ QUALITY_SHUFFLE_SEED=7 tools/quality --format mica tests/quality/fixtures/mixed > /tmp/q2
$ cmp /tmp/q1 /tmp/q2 && echo same
same
? 0
```

### Surfaces

The command-line tool MUST exit 0 when it finishes, whatever the scores, and
exit 1 only when it cannot finish. [R-exit-status]
The tool measures; gating on a score is CI policy.

```transcript @R-exit-status
$ tools/quality --root /nonexistent
quality: root /nonexistent does not exist
? 1
```

The `text` report MUST open with a header (tool version, corpus roots,
history range), then the composite and terms for the corpus and each
language, then the top `--top` issues, one per line as
`path:line code severity message`. [R-text-report]

```transcript @R-text-report
$ tools/quality tests/quality/fixtures/mixed
quality 0.1  roots: tests/quality/fixtures/mixed  history: none (not a repository)
composite 0.312  erosion 0.407 (human 0.34, agent 0.68)  verbosity 0.150 (human 0.19, agent 0.44)
tests/quality/fixtures/mixed/deep.odin:3 Q_COMPLEXITY WARNING cyclomatic complexity 22 exceeds 10
tests/quality/fixtures/mixed/rules.mica:4 Q_MIXED_DERIVATION ERROR Seen is a rule head and is asserted directly
? 0
```

The `mica` report MUST be one Mica map value with the keys `:header`,
`:terms` and `:diagnostics`, and its content MUST equal the run's
`quality/Term` and `quality/Diagnostic` relations. [R-mica-report]

```transcript @R-mica-report
$ tools/quality --format mica tests/quality/fixtures/mixed | head -c 25
{:header -> {:version ->
? 0
```

The verb `tool/quality(agent, arguments)` MUST return the map the `mica`
report prints, for the paths in `arguments[:paths]`, and MUST be callable
only by subjects holding a `CanInvoke` grant on it. [R-tool-verb]

```transcript @R-tool-verb
$ tools/filein apps/quality/*.mica --eval 'return tool/quality(#agent, {:paths -> ["tests/quality/fixtures/mixed"]})[:terms][:corpus][:composite]'
0.312
? 0
```

### Deviations from SlopCodeBench

The numbers compare with [SCB]'s baselines only if the departures are known.

- **Callables.** [SCB] defines erosion over "all callables" without saying how nesting counts. Here nested function literals fold into the enclosing callable, whose branches they are. Mica rules are not callables; they have their own complexity measure.
- **Verbosity is a lower bound.** The flagged-line rules number a handful, not 137, so verbosity understates what [SCB]'s rules would find.
- **Dead, uncovered, defects and testing are this document's,** not the paper's.
- **Dead is an upper bound.** Reachability follows resolved calls only, so code reached through proc values or dynamic dispatch looks dead.
- **Languages differ.** [SCB] measures Python. Mica and Odin differ in what a line and a branch are, so cross-language comparison is indicative, not exact.

### Errors

| Error | Example | Recovery |
|---|---|---|
| `Q_PARSE` (diagnostic) | a `.mica` file with a syntax error | Record it, skip the file's measures, continue |
| `Q_LOAD` (diagnostic) | a filein expression aborts while the corpus loads | Record it with the unit name, keep what loaded, continue |
| `Q_NO_HISTORY` (diagnostic, NOTE) | the root is not a git repository | Drop the defects term; the others renormalize |
| `Q_UNRESOLVED_CALL` (diagnostic, NOTE) | an Odin call through a proc value | Keep the edge unresolved; never count it as reached |
| exit 1 | `--root` does not exist | Print the reason on stderr and exit 1 |

## Formal Grammar

```abnf
command     = "tools/quality" *( SP option ) *( SP path )
option      = since / format / top / root / store
since       = "--since" SP ( date / commit )
format      = "--format" SP ( %s"text" / %s"mica" )
top         = "--top" SP 1*DIGIT
root        = "--root" SP path
store       = "--store" SP path
date        = 4DIGIT "-" 2DIGIT "-" 2DIGIT
commit      = 7*40HEXDIG
path        = 1*( ALPHA / DIGIT / "/" / "." / "_" / "-" )
issue-line  = path ":" 1*DIGIT SP code SP severity SP message
code        = %s"Q_" 1*( %x41-5A / "_" )
severity    = %s"ERROR" / %s"WARNING" / %s"NOTE"
message     = 1*( %x20-7E )
```

## Out of Scope

**Change delta.** [SCB] tracks erosion and verbosity across checkpoints of
one task, and a pull request is the same idea: terms at a base and a head
revision, and the signed difference. It is excluded until the git relations
exist. Extension point: a `--base <commit>` option that runs both revisions
and reports each term's delta, per file, using `source/ChangedFiles` to list
touched files.

**Dynamic coverage.** Branch coverage from running the tests needs VM hit
counters that omica lacks. Extension point: a `quality/Hit(file, node)`
relation filled by an instrumented run, replacing `Reached` in [R-uncovered].

**Ratchet.** Failing CI when a term rises is policy, not measurement
([R-exit-status]). Extension point: a script that compares two `mica` reports.

**Auto-fixing.** The tool only reports.

## Alternatives Considered

**Why not measure source files?** In Mica the world is the source of truth.
Verbs are filed in, replaced and edited while it runs, and nothing requires a
world's current code to match any file. Reading files measures what a world
was built from, which can differ from what it runs. Files remain one way to
build the measured world.

**Why not clamped linear scores?** A clamped scale saturates: CC 30 and CC
200 score the same, so fixing the worst callable in the corpus does not move
the number. Shares and squashed rates always move.

**Why not score maintainability index?** It is built from complexity,
volume and lines, which erosion already weighs. It stays a diagnostic.

**Why not extend the Odin compiler to emit structure facts?** That changes
the compiler for a tool's benefit. `parse.mica` already produces the facts,
and the self-differential tool checks them against the Odin parser.

**Why not write an Odin parser in Mica?** It would duplicate
`core:odin/parser`, which tracks the language and ships with every Odin
install.

**Why not hand-written tree walks for reachability and health?** They are
transitive queries. Rules state them in a few lines, stratify by
construction, and match the analysis idiom of [BOOTSTRAP].

**Why not a plain text report?** Agents would scrape it, and findings could
not be joined with other facts, such as the dead relations added last month.

**Why not run `git` for history?** Parsing command output is fragile.
Relations make history queryable by the same rules as everything else.

## Security Considerations

Loading a corpus runs its top-level Mica expressions, so a hostile or broken
corpus runs code during a run. [R-sandboxed-world] bounds it: with no store
nothing persists, and with no host-effect capability nothing leaves the
process. CPU and memory remain, so an untrusted corpus SHOULD run under
memory and time limits.

The Odin helper parses files and never executes them.

The git relations are read-only, confined to `--root`, and walk at most 512
commits, so a large repository cannot stall a run.

Reports hold paths relative to `--root` and short messages. They reveal no
source beyond the identifiers a message names.

`tool/quality` requires a `CanInvoke` grant ([R-tool-verb]), so an agent
without one cannot make the host parse arbitrary paths. Inside a running
world the tool reads the catalogue, including every method's source; the
same grant decides who may read that through the tool. It writes only
volatile relations there ([R-measure-without-writing]).

A stored world is measured through a temporary copy, so the tool never takes
the store's lock or writes to it, and a crash mid-run cannot damage it.

## Compatibility

The tool adds files and changes no existing behavior. Beyond `apps/quality/`
it needs:

1. `tools/quality-facts`, an Odin helper that writes Odin syntax facts and tokens.
2. Read-only git relations in `host/source/`:
   `source/CommitLog(repository, commit, parent, subject, author, time)` and
   `source/ChangedFiles(repository, from, to, path, change)`, modelled on the
   relations of the same names in the Rust source provider [RUST-SOURCE].
3. `tools/quality`, a thin Odin entry point that starts a run world, loads
   `apps/quality/`, and prints the report.

Until item 2 lands, runs report `Q_NO_HISTORY` and score without defects.

Drift ([R-drift]) appears only once code can change in a running world
without a filein of the whole unit: an in-place install such as #78's
`install_source`, or `world_filein` into a running world (rdaum/omica#117).
Until then the two subjects always agree, and drift is reported as zero.

## References

- [SCB] G. Orlanski, D. Roy, A. Yun, C. Shin, A. Gu, A. Ge, D. Adila, et al., "SlopCodeBench: Benchmarking How Coding Agents Degrade Over Long-Horizon Iterative Tasks", arXiv:2603.24755, https://arxiv.org/abs/2603.24755
- [BOOTSTRAP] R. Daum, "A runtime generated by Mica", draft for discussion, 2026-09-26, https://gist.github.com/rdaum/566a6d0afe1358742b40e5728b7893a3
- [COGNITIVE] G. A. Campbell, "Cognitive Complexity: A new way of measuring understandability", SonarSource, 2018, https://www.sonarsource.com/docs/CognitiveComplexity.pdf
- [WINNOW] S. Schleimer, D. Wilkerson, A. Aiken, "Winnowing: Local Algorithms for Document Fingerprinting", SIGMOD 2003, https://doi.org/10.1145/872757.872770
- [RUST-SOURCE] timbran-project/mica, `crates/source-provider/src/relations.rs` (commit 2bbceb0).
- Reference project: let-go, `scripts/quality.lg`, a SlopCodeBench-aligned quality score for a Lisp and Go codebase.
- omica code this document builds on: `apps/compiler/parse.mica`, `apps/compiler/lex.mica`, `mica/kernel/dispatch.odin`, `mica/kernel/authority.odin`, `host/source/index.odin`, `apps/agent/tools.mica`.

## Appendix A. Diagnostic codes

| Code | Severity | Meaning |
|---|---|---|
| `Q_PARSE` | ERROR | the file does not parse |
| `Q_LOAD` | ERROR | a filein expression aborted while the corpus loaded |
| `Q_COMPLEXITY` | WARNING | CC above 10 (the erosion threshold) |
| `Q_COGNITIVE` | WARNING | cognitive complexity above 15 |
| `Q_NESTING` | WARNING | nesting depth above 4 |
| `Q_LENGTH` | WARNING | more than 60 SLOC |
| `Q_PARAMETERS` | WARNING | more than 5 parameters |
| `Q_FAN_OUT` | WARNING | more than 15 distinct callees |
| `Q_FAN_IN` | WARNING | more than 20 distinct callers |
| `Q_RULE_COMPLEXITY` | WARNING | rule complexity above 6 |
| `Q_MAINTAINABILITY` | WARNING | file maintainability index below 65 |
| `Q_DUP` | WARNING | a clone pair |
| `Q_VERBOSE` | WARNING | a line a verbose-code rule flags |
| `Q_DEFECTS` | NOTE | defect rate above 2 per KSLOC |
| `Q_UNREACHED` | NOTE | a callable or rule no test reaches |
| `Q_DEAD` | WARNING | a callable no root reaches |
| `Q_UNRESOLVED_CALL` | NOTE | a call edge the tool cannot resolve |
| `Q_DRIFT` | NOTE | a unit's installed code differs from its unit text |
| `Q_NO_HISTORY` | NOTE | no git history is available |
| `Q_DEAD_RELATION` | WARNING | see "Rule and relation health" |
| `Q_EMPTY_RELATION` | WARNING | see "Rule and relation health" |
| `Q_MIXED_DERIVATION` | ERROR | see "Rule and relation health" |
| `Q_INACTIVE_RULE` | NOTE | see "Rule and relation health" |
| `Q_DANGLING_GRANT` | ERROR | see "Authority and grants" |
| `Q_SYSTEM_GRANT` | ERROR | see "Authority and grants" |
| `Q_DERIVED_WRITE_GRANT` | WARNING | see "Authority and grants" |
| `Q_UNGRANTED_TOOL` | WARNING | see "Authority and grants" |

The maintainability index, reported per file, is
`clamp(171 − 5.2·ln(V) − 0.23·CC_total − 16.2·ln(SLOC) + 50·sin(√(2.4·CR)), 0, 100)`,
where `V` is Halstead volume from the file's syntax facts, `CC_total` sums
the file's callable CC, and `CR` is the share of comment lines.
