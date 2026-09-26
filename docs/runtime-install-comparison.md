# Runtime installation comparison draft

This branch implements runtime identity creation (#111) and dynamic compilation and installation (#78).
It is an alternative for comparison with [PR #117](https://github.com/rdaum/omica/pull/117), not a proposed combination of both branches.
The comparison below refers to that PR's design at `a58f073bc66b2e920ea6a7c4f5ca50f613596cfa`.
Its implementation can change independently.

## This implementation

`install_source(source)` validates definitions in a private transaction view, then stages them in the caller's transaction.
It installs verbs, rules, and literal identity or relation declarations.
It requires administrative authority and rejects arbitrary top-level execution and grants.
A failed installation leaves the caller's staged catalogue unchanged.
Successful definitions become visible to other tasks at commit.

Each installation produces an ordinary multi-function program artifact.
`MethodProgram(method, [artifact, function_index])` selects a function within that image.
A frame retains its defining program; dynamic dispatch resolves methods through the task's transaction view.
Direct calls within an image keep their original target, including after a method replacement.
Replacement matches the selector and parameter signature and preserves the method identity and grants.

`compile(source)` returns encoded program bytes without installing or executing them.
`world_eval` compiles only the supplied expression source against a private context built from the caller's catalogue.
It no longer recompiles stored verb sources.

Computed `make_identity` calls use the same transactional name-binding path and atomic identity allocator as loader declarations.
Name uniqueness is enforced at commit, including stores with the older set-shaped name relation.
Recovery restores the allocation floor from stored references, including nested values whose original name binding was removed.

## Decisions to compare

| Area | This branch | PR #117 design |
| --- | --- | --- |
| Program unit | One multi-function image per installation | One image per verb, plus an entry image per filein |
| Method reference | Artifact identity and function index | Artifact identity; verb entry at function zero |
| Calls between verbs | Same-image direct calls remain bound; cross-image calls dispatch | Named dispatch between verbs; direct self-call |
| Function values | Process-unique program serial and per-program callable index | World-owned callable table containing program, function, and captures |
| Decoded image lifetime | Task pins, installed-method roots, and interned-callable roots | Resolver retains images until world destruction |
| Installation API | Administrative Mica builtin stages definitions in caller transaction | Host filein API with unit-based Add and Replace modes |
| Legacy store migration | Rewrite integer references to artifact/index pairs | Recompile stored source into per-verb artifacts |

The call rule is a language decision, not only a performance choice.
Under this branch, replacing a helper does not redirect an existing image's direct calls to that helper.
Under the other design, calls between verbs resolve through dispatch and its authority checks.
Compare replacement behavior and `CanInvoke` semantics before choosing a representation.

## Limits of this draft

- Function handles remain interned until world shutdown. Their defining images cannot be reclaimed after the last user-visible reference disappears.
- Program bytes remain durable facts. Decoded-image reclamation does not remove historical artifacts from the store.
- This branch does not add host `world_filein` Add/Replace modes or source-unit ownership.
- Type aliases are outside the current parser grammar.
- The bootstrap image remains available through `World.program` for compatibility; dispatch uses the registry.

These limits mean this draft should not close #78 without further agreement on lifetime and installation semantics.

## Review and validation

Start with `mica/runtime/program_builtins.odin`, `mica/vm/registry.odin`, and the call/return changes in `mica/vm/vm.odin`.
`mica/kernel/install_transaction.odin` implements the private staging view.
The identity and program builtin tests cover rollback, authority, concurrent commits, old frames, escaped closures, rules, recovery, and legacy stores.

The review follow-up fixes named spliced calls across programs and cached-program restoration after deadline or instruction-budget exceptions.
Spliced calls share ordinary positional dispatch's method selection, parameter restrictions, and authority checks.
The new opcode is appended, so existing artifact opcode numbers remain unchanged.
Tests cover artifact decoding and validation, stored-program recovery, optional/rest arguments, denial, and all three asynchronous-limit unwind paths.
The splice and unwind regressions failed before the fixes.

The isolated follow-up passed 189 runtime tests, 73 compiler tests, and 37 VM tests.
The focused set of 15 runtime tests passed under ThreadSanitizer with the repository's existing allocator suppression.
The isolated snapshot excludes separate pending retrieval/store repairs.
Earlier kernel tests, CLI/web integration, and compiler-tool build checks also passed; those local runs used the working tree.
The before/after benchmark builds excluded unrelated repairs and measure the original comparison draft, before this follow-up.
Large-catalogue evaluation improved by about 70%; direct calls regressed by about 14%.
The direct-call regression is unresolved in this draft.
The full run also exposed a concurrent test sharing an unsafe temporary allocator; the concurrent constructor tests now use locked arenas.

See [runtime measurements](runtime-benchmarks.md) for the baseline protocol and measurement status.
