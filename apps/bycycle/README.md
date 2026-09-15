# Bycycle: OpenCyc commonsense KB in Mica

Loads the [OpenCyc](https://github.com/asanchez75/opencyc) OWL dump (the LarKC-era
Apache-licensed export, ~242k subjects / ~2.4M triples) into a Mica store as plain
assertions, then layers Datalog-style inference rules on top.

The OWL is **not transformed**: `tools/owlstream` streams `owl:Class` blocks and
asserts each triple into the relations declared here. Rules derive everything else
(transitive closure, disjointness symmetry, inconsistency detection).

## Fileins

- `00_schema.mica` — Isa/Genls/DisjointWith/QuotedIsa/TypeGenls/Arg1Pred/RewriteOf/
  BroaderTerm; Label/CycLabel/Comment/Alias/SeeAlso/WikiName/WikiURL/SameAs;
  GuidOf (identity → source GUID audit); LoaderState (durable resume point);
  CanRetrieveSubject.
- `10_taxonomy.mica` — `Subsumes` transitive closure, `InstanceOf` via Isa+Subsumes,
  `DirectChild`/`IndirectChild`.
- `20_constraints.mica` — DisjointWith symmetry, `InconsistentWith` violations,
  `QuotedInstanceOf`/`TypedInstanceOf`.
- `30_graph.mica` — Broader (both directions), `RewrittenTo` transitive,
  TextUnit/TextUnitText retrieval wiring.

## Loading

```sh
# 1. ontology + rules into a fresh store
scripts/bycycle-load.sh init /tmp/bycycle-db

# 2. facts (streaming, batched, resumable — safe to re-run after a kill)
scripts/bycycle-load.sh load /tmp/bycycle-db /path/to/opencyc-latest.owl.gz

# 3. query
scripts/bycycle-load.sh query /tmp/bycycle-db 'return Subsumes(?a, ?d)'
scripts/bycycle-load.sh query /tmp/bycycle-db 'return InconsistentWith(?x, ?a, ?b)'
```

The dump is the `opencyc-latest.owl.gz` from the asanchez75/opencyc repo (note: a
Git LFS pointer unless fetched via the media URL).

## Resume semantics

The loader persists its scan position in `LoaderState(:resume)` after every
checkpoint (each 20k-triple batch), alongside the facts, in the same durable store.
A killed run resumes exactly where it stopped — no re-scan of already-loaded
subjects. `GuidOf` rows pre-seed the identity map so forward references from new
subjects resolve to existing identities. Set semantics make overlap idempotent.

## Identity mapping

OpenCyc GUID fragments become Mica identities named `guid_<fragment>` (`.` and
`-` mapped to `_`, the Mica ident charset). `GuidOf` maps identity → source GUID;
`NamedIdentity` facts make `#guid_X` resolve after reboot. Functional
Label/CycLabel/Comment keep the first value; repeats route to `Alias`.

## Growth notes

Load is linear in triples; inference (rule fixpoint on commit) is the superlinear
term — see the timing table in the bycycle scratch repo (`docs/growth.md`).
Queries are boot-dominated until the columnar projection lands; the negated
single-column atom path already routes through `mica/kernel/accel`.
