# Runtime change measurements

Use this protocol before and after runtime identity creation (#111) and dynamic program installation (#78).
Keep the runtime revision separate from the benchmark harness revision.

## Capture and compare

The launcher builds an isolated Git snapshot with `-o:speed`.
It adds the current benchmark driver and corpus to that snapshot.
A saved patch can be applied with `--runtime-patch PATH`.
Other working-tree changes do not enter the build.
Each output directory retains the source, binary, compiler identity, fixture hashes, commands, raw samples, and results.

```sh
python3 scripts/runtime-baseline.py benchmarks/results/runtime-before \
  --revision 1282559 --cpu 5 --runs 5 --samples 21 --budget-ms 20

# After the implementation is committed:
python3 scripts/runtime-baseline.py benchmarks/results/runtime-after \
  --revision HEAD --cpu 5 --runs 5 --samples 21 --budget-ms 20 \
  --baseline benchmarks/results/runtime-before/manifest.json
```

CPU 5 is a Cortex-X925 core on the machine used for the initial baseline.
Select an allowed CPU on other machines and use that same CPU for both revisions.
The launcher changes process affinity only. It does not change the host governor or stop other processes.

Measurements run serially, with one scheduler worker pinned to that CPU.
Each workload runs in five fresh processes. Each process collects 21 samples after calibration and warmup.
Workload order rotates between runs to distribute time and thermal effects.
Every invocation must complete. Its result must match the probe result, which the launcher checks against an expected value.
Result checks remain inside the timed interval on both revisions.

The summary reports the median of process medians and their range.
A percentage change describes those measurements. It does not establish statistical significance.
For small differences, repeat both revisions in the same session before accepting a regression or improvement.
The launcher rejects comparisons with different machines, compilers, CPU selections, fixtures, or harnesses.

## Captured baseline

Captured on 2026-09-26 at runtime commit `128255965c03d3400c0cc71d133b3bac9365ed7b`, before changes for #111 or #78.
The host was `yew`, running Linux aarch64, with CPU 5 selected.
The compiler was Odin `dev-2026-09-nightly:a2fb372` with `-o:speed`.
All 50 process runs completed with valid results, producing 1,050 samples.

The local bundle is [`runtime-before-111-78-1282559-complete`](../benchmarks/results/runtime-before-111-78-1282559-complete/).
It contains the full manifest, raw samples, source snapshot, binary, and process peak RSS values.
Use its `manifest.json` as the `--baseline` argument for the comparison run.

These times cover one whole benchmark invocation, including its loop and result checks.
The range spans the five process medians.

| Case | Median (µs) | Process median range (µs) |
| --- | ---: | ---: |
| Empty task | 52.8 | 51.7–53.7 |
| 30,000 direct calls | 1,129.5 | 1,127.9–1,132.6 |
| 30,000 callable calls | 2,182.0 | 2,180.6–2,182.2 |
| 2,000 dynamic dispatches | 1,126.9 | 1,120.3–1,130.5 |
| 10,000 identity lookups | 696.7 | 675.5–719.5 |
| 10,000 identity lookups, large catalogue | 728.3 | 716.8–770.6 |
| Live evaluation | 59.8 | 59.1–60.9 |
| Live evaluation, large catalogue | 539.8 | 535.4–551.5 |
| Scan 1,000 rows | 172.4 | 171.6–173.8 |
| 256 relation commits | 708.4 | 705.1–715.6 |

## Workloads

| Case | Work per invocation | Purpose |
| --- | --- | --- |
| Empty task | One empty verb | Scheduler, dispatch, and transaction overhead |
| Direct calls | 30,000 helper calls | Direct VM calls |
| Callable calls | 30,000 function-value calls | Callable execution and program ownership |
| Dynamic dispatch | 2,000 `invoke` calls | Role-map construction and method dispatch |
| Identity lookup | 10,000 matching constructor calls | Existing-name lookup |
| Identity lookup, large catalogue | Same calls with 1,024 extra identities and 64 extra verbs | Lookup scaling |
| Live evaluation | Compile and run `return 1` | Compilation against a live world |
| Live evaluation, large catalogue | Same expression in the larger world | Context and source scaling |
| Relation scan | Count 1,000 rows | Read-path control |
| Relation commits | 256 explicit commits | Transaction-path control |

Per-unit figures divide the whole invocation by its operation count.
They include loop and harness costs. They are not isolated instruction timings.
This protocol measures single-worker costs, not parallel throughput.

Process peak RSS covers startup, calibration, warmup, and all samples.
Calibration can select different invocation counts between revisions.
Do not interpret this RSS value as bytes per operation or as evidence of a memory leak.
Measure retention separately with a fixed operation count when changing program lifetime management.

## New operations

The baseline runtime cannot create fresh identities or install independent programs.
Those operations have no valid pre-fix throughput number.
Do not compare their implementation against a failed call or a no-op.

For #111, add measurements for fresh names, matching names, conflicting concurrent names, and increasing catalogue size.
Check committed bindings and returned identities after each measured batch.
For #78, add installation, cross-program dispatch, replacement with active tasks, and retained-program memory measurements.
Keep the existing-call measurements unchanged to detect regressions.

Generated measurement directories are ignored by Git. Preserve or copy the complete directory before removing local benchmark results.

## Comparison draft capture

The comparison uses the baseline revision plus the saved runtime patch, with unrelated pending repairs excluded.
Both captures completed 50 process runs and 1,050 samples with valid results.
The samples, hashes, protocol, and summaries are preserved in [`runtime-111-78-comparison.json`](../benchmarks/runtime-111-78-comparison.json).
The complete local bundle is [`runtime-after-111-78-final`](../benchmarks/results/runtime-after-111-78-final/).
The JSON records the exact patch hash; its source snapshot and `runtime.patch` remain in that bundle.

| Case | Before (µs) | After (µs) | Change |
| --- | ---: | ---: | ---: |
| Empty task | 52.8 | 53.3 | +1.0% |
| 30,000 direct calls | 1,129.5 | 1,288.8 | +14.1% |
| 30,000 callable calls | 2,182.0 | 2,287.4 | +4.8% |
| 2,000 dynamic dispatches | 1,126.9 | 1,156.1 | +2.6% |
| 10,000 identity lookups | 696.7 | 680.1 | -2.4% |
| 10,000 lookups, large catalogue | 728.3 | 696.6 | -4.4% |
| Live evaluation | 59.8 | 63.3 | +5.9% |
| Live evaluation, large catalogue | 539.8 | 160.0 | -70.4% |
| Scan 1,000 rows | 172.4 | 182.8 | +6.0% |
| 256 relation commits | 708.4 | 710.1 | +0.2% |

The direct-call regression remains unresolved in this comparison draft.
Calls now retain and restore their defining program; further profiling is required to attribute the measured cost.
Small changes need repeated paired captures before a firm conclusion.

The large-catalogue evaluation process peaked at 7,344 KiB RSS, compared with 589,220 KiB in the baseline.
These are adaptive harness process peaks, not allocation counts or equal-operation retention measurements.

`tools/runtimeopsbench` and `benchmarks/mica/runtime_new_operations.mica` add fixed-count measurements for the new operations.
Each fresh process measures 100 identity creations, 20 installations, 20 replacements, or 2,000 calls across programs.
The driver reports elapsed nanoseconds, operation count, and cached program count after task release.
World startup is outside the timer; result checks and transaction commits remain inside it.

```sh
odin build tools/runtimeopsbench -o:speed -out:/tmp/runtimeopsbench
for case in identities installation replacement cross_program; do
  for run in 1 2 3 4 5; do
    /usr/bin/time -f '%M KiB peak RSS' taskset -c 5 /tmp/runtimeopsbench "$case"
  done
done
```

Fixed-count results used five fresh processes per case, on the same CPU and isolated runtime snapshot.
The table reports the median whole-invocation time and the range across processes.
The program count is measured after the benchmark task is released; all five runs agreed.

| Case | Median (µs) | Range (µs) | Cached programs |
| --- | ---: | ---: | ---: |
| 100 fresh identities | 2,606.8 | 2,301.8–2,891.3 | 1 |
| 20 distinct installations | 1,153.6 | 1,066.9–1,243.5 | 21 |
| 20 replacements | 1,221.6 | 1,125.2–1,266.8 | 2 |
| 2,000 calls across programs | 905.5 | 884.0–906.8 | 2 |

Replacement leaves the bootstrap image and the current installed image cached in this workload.
This workload creates no function handles; it does not measure the unresolved callable-retention limit.
