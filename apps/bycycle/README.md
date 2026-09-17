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

Load order matters. Fileins lower rules one file at a time against the relations
declared so far, so every relation a rule *body* reads must be declared in the same
file or an earlier one: `20_constraints` reads `InstanceOf`/`Subsumes` from
`10_taxonomy`. A body relation declared later fails with `could not lower a rule`.
Heads are not restricted: `30_graph` derives `TextUnit`, which
`apps/shared/retrieval.mica` declares after it. `scripts/bycycle-load.sh` fixes the order in its `ONTOLOGY` list.

## Retrieval

`apps/shared/retrieval.mica` gates every candidate through
`CanRetrieveSubject(actor, subject)`. The store has no actor model to derive it from,
so the loader asserts it for every subject when given `--retrieval-actor NAME`
(minting `#NAME` if the store lacks it). `scripts/bycycle-load.sh load` passes
`bycycle_reader`; retrieve as `#bycycle_reader`.

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

The loader persists its scan position in `LoaderState(:resume)` after every commit
batch (20k queued facts by default), alongside the facts, in the same durable store;
with `--checkpoint` (the script passes it) the store is also checkpointed per batch.
A killed run resumes exactly where it stopped — no re-scan of already-loaded
subjects. `GuidOf` rows pre-seed the identity map so forward references from new
subjects resolve to existing identities. Set semantics make overlap idempotent.

## Identity mapping

OpenCyc GUID fragments become Mica identities named `guid_<fragment>` (`.` and
`-` mapped to `_`, the Mica ident charset). `GuidOf` maps identity → source GUID;
`NamedIdentity` facts make `#guid_X` resolve after reboot. Functional
Label/CycLabel/Comment keep the first value; repeats route to `Alias`.

Only fragments of 20+ identifier characters count as GUIDs (OpenCyc's are 26). A
resource with a shorter fragment (say `.../Dog`) is not loaded: as a subject it is
counted under `skipped`, as an object under `dropped resources` in the loader's
summary line.

## Growth notes

Every commit recomputes the whole rule fixpoint, so load cost is driven by the
number of commits far more than by the number of triples. The loader therefore
queues every fact — including the `GuidOf`, `NamedIdentity` and
`CanRetrieveSubject` rows it generates — and commits once per `--commit-batch`.
Committing per new identity instead (what the loader did before) costs, on the real
dump at `--limit 2000`: 1454.7s vs 7.1s, same derived results (4,420 `Subsumes`,
3,153 `InstanceOf`). The older timing table in the bycycle scratch repo
(`docs/growth.md`) predates this change.
Queries are boot-dominated until the columnar projection lands; the negated
single-column atom path already routes through `mica/kernel/accel`.
