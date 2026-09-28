# VM Opcode Dispatch Cost

> Historical measurements for the revision named below.
> These figures do not measure the current runtime.
> Optimization candidates require fresh measurements before implementation.

This document records the measured per-opcode cost of the register VM dispatch
loop, where those instructions go, and the ranked candidates for reducing it.
It is a measurement note, not a plan of record; update it when the loop changes
or a candidate lands.

## Scope

- Repository: `mica-odin`
- Component: `mica/vm/vm.odin`, `vm_run` dispatch loop
- Base revision: `cd7ab53`
- Date: 2026-09-14
- Machine: aarch64, two `armv8_pmuv3` PMU instances, `kernel.perf_event_paranoid
  = -1`

## How this was measured

Two independent methods, which agree when the comparison is controlled:

- **Hardware counters** via `benchmarks/vm_bench.odin` and the PMU support in
  `micromeasure`. Straight-line programs repeat one opcode 20000 times, so the
  per-opcode cost excludes loop control. `vm_reset` (added in `b82638e`) makes
  one VM reusable across benchmark operations; without it the harness would pay
  5.6 µs of init/destroy per run against 27 ns for reset+run. The reported
  `insn/op` and `br/op` are normalized per opcode and are the reliable signal.
- **Callgrind** on a `-debug` build, which attributes counts to source lines
  deterministically. Callgrind totals are only comparable across runs that
  execute identical work: comparing them across different `-filter` values
  gives meaningless deltas.

Caveat on `perf stat`: it opens many events at once, so it reports multiplexed
scheduled shares (e.g. 5%/95% across two `armv8_pmuv3` instances). The
harness's `micromeasure/perf.odin` opens each counter on its own thread and
reads raw counts, which are 100% scheduled in that configuration. The raw
counts are correct here; the `perf stat` percentages are an artifact of its
own grouping.

Reproduce:

```sh
odin build benchmarks -o:speed -out:bench
./bench -suite=vm
./bench -suite=vm -save=vm_baseline.tsv
```

## Per-opcode cost

Current, after the budget merge (`cd7ab53`):

| Opcode | native insn/op | cycles/op |
| --- | --- | --- |
| Move | 52.0 | 8.2 |
| Load_Const | 54.0 | 9.0 |
| Binary_Cmp | 74.0 | 11.1 |
| Binary_Add | 77.0 | 12.6 |
| Is_Truthy | 67.0 | 9.0 |
| Index_List | 68.0 | 10.1 |
| Unary_Not | 70.0 | 11.3 |
| Builtin_Call | 130.0 | 25.2 |
| Call | 418.0 | 94.0 |

Before the budget merge (`36630bb`) the same opcodes were Move 58, Load_Const
60, Binary_Add 83, Binary_Cmp 80, Unary_Not 95, Index_List 86, Is_Truthy 73,
Builtin_Call 161, Call 432.

The baseline dispatch floor is **~52 native instructions and ~8 cycles** per
opcode. `Call` is the outlier at 418 instructions, 8x baseline, consistent
with argument marshaling dominating the emitted `Move` flood measured earlier
in the compiler work.

A split probe confirmed the floor is not fixed-cost contamination: a
`vm_reset` + `vm_run` cycle costs ~455 fixed instructions, and the marginal
cost of one `Move` opcode matches the per-opcode figure.

## Where the instructions go

Callgrind line attribution for the `Move` opcode, as shares of the `vm_run`
body. Only about 23% is the opcode's actual payload work.

| Share of vm_run | Line |
| --- | --- |
| ~23% | `switch instr.op` |
| ~17% | `#no_bounds_check instr := program.code[frame.ip]` |
| ~12% | `if state.status == .Failed` and the unwind path |
| ~12% | `registers[a] = registers[b]` (the Move itself) |
| ~10% | `if frame.ip < 0 \|\| frame.ip >= len(program.code)` |
| ~6% | `if state.scratch.total_used > 0` |
| ~4% | `if state.configured_budget != 0` |
| ~4% | `top := len(frames)-1` |
| ~4% | `frame.ip += 1` |

## Landed

- **Budget check collapsed to one branch** (`cd7ab53`). The loop tested
  `instruction_budget_exhausted` and then `instruction_budget > 0` every
  instruction; both are now behind a single stable `configured_budget != 0`
  guard. Move 58 -> 52 instructions, 11 -> 10 branches. VM suite passes,
  including both budget tests.

## Candidates, ranked

Ranked by measured headroom. Each is localized to the dispatch loop and
measurable with the `vm` suite.

1. **Status check every instruction (~12%, ceiling ~8%).** `if state.status ==
   .Failed` and the `vm_unwind` path run unconditionally, but only fallible
   opcodes can set `.Failed`. Skipping the check for opcodes whose body cannot
   fail was measured at 52 -> 48 instructions, 10 -> 9 branches, by disabling
   the check outright. That is the ceiling, not the achievable win: a correct
   implementation classifies all 46 opcodes by fallibility, and a
   misclassification silently swallows an error, so the classification needs
   care. Lower priority than the old estimate of 17% suggested.
2. **IP bounds check (~10%).** `frame.ip < 0 || frame.ip >= len(program.code)`
   is two comparisons; a single unsigned `uint(frame.ip) >= uint(len(code))`
   expresses the same test. `program_validate` already proves every jump target
   lands inside its function (`Bad_Jump`), so the runtime check is defence
   against a malformed program rather than a correctness requirement. It is
   also the guard that turns a malformed program into `E_VM_FAULT` instead of a
   segfault, so it must move rather than disappear. Risk: low.
3. **Scratch-arena check (~6%).** Already optimized once; the comment in the
   loop records that an unconditional `arena_free_all` was worse. Further
   reduction needs a different reclaim trigger. Risk: low.
4. **Runtime `error_checks` bounds check.** Worth understanding why
   `#no_bounds_check` did not remove this one; it may be a different array.
   Risk: low, but diagnose first.

## Not low-hanging

`Call` at 418 instructions is the largest absolute cost but is a design change,
not a local one. It points at argument marshaling and the calling convention
(consecutive-register packing before each call), which is the same area the
compiler work already identified as 66% of the parser's emitted `Move`s. This
deserves its own note if pursued.
