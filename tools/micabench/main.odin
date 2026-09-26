// A lightweight Mica-source benchmark driver.
//
// Each corpus file declares `verb bench()` (and optionally `verb setup()`).
// The driver loads the file once, runs `setup` once, then times repeated
// `bench()` calls and reports nanoseconds per call. The same corpus is meant
// to run on the Rust implementation with the same contract, so the files use
// only the shared language surface and bake their own iteration counts.
//
// Usage:
//   micabench [--samples N] [--budget-ms M] <file.mica>...
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"

import k "../../mica/kernel"
import r "../../mica/runtime"
import vm "../../mica/vm"
import v "../../mica/var"

DEFAULT_SAMPLES :: 15
DEFAULT_BUDGET_MS :: 20
DEFAULT_WORKERS :: 8
// Minimum inner repeats per sample. On a busy machine a single call can absorb
// a scheduling event and report 50% high; averaging over several calls makes a
// sample robust to that. The budget raises this further when calls are fast.
MIN_INNER :: 8

main :: proc() {
	samples := DEFAULT_SAMPLES
	budget_ms := DEFAULT_BUDGET_MS
	workers := DEFAULT_WORKERS
	disasm := false
	accel_mode := r.Accel_Mode.Unchanged
	accel_report := false
	print_result := false
	raw_samples := false
	verify_result := false
	eval_source := ""
	paths: [dynamic]string
	defer delete(paths)

	args := os.args[1:]
	index := 0
	for index < len(args) {
		arg := args[index]
		switch {
		case arg == "--disasm":
			disasm = true
		case arg == "--samples":
			index += 1
			if index < len(args) {
				samples = parse_int(args[index], DEFAULT_SAMPLES)
			}
		case strings.has_prefix(arg, "--samples="):
			samples = parse_int(arg[len("--samples="):], DEFAULT_SAMPLES)
		case arg == "--budget-ms":
			index += 1
			if index < len(args) {
				budget_ms = parse_int(args[index], DEFAULT_BUDGET_MS)
			}
		case strings.has_prefix(arg, "--budget-ms="):
			budget_ms = parse_int(arg[len("--budget-ms="):], DEFAULT_BUDGET_MS)
		case arg == "--workers":
			index += 1
			if index < len(args) {
				workers = parse_int(args[index], DEFAULT_WORKERS)
			}
		case strings.has_prefix(arg, "--workers="):
			workers = parse_int(arg[len("--workers="):], DEFAULT_WORKERS)
		case arg == "--accel":
			index += 1
			if index < len(args) {
				mode, ok := r.accel_mode_parse(args[index])
				if !ok {
					fmt.eprintf("--accel: expected %s, got %q\n", r.ACCEL_MODE_NAMES, args[index])
					os.exit(2)
				}
				accel_mode = mode
			}
		case arg == "--accel-report":
			accel_report = true
		case arg == "--raw-samples":
			raw_samples = true
		case arg == "--verify-result":
			verify_result = true
		case strings.has_prefix(arg, "--eval="):
			eval_source = arg[len("--eval="):]
		case arg == "--result":
			print_result = true
		case:
			append(&paths, arg)
		}
		index += 1
	}
	if len(paths) == 0 {
		fmt.eprintln("usage: micabench [--samples N] [--budget-ms M] [--workers N] [--accel MODE] [--accel-report] [--result] [--raw-samples] [--verify-result] [--eval=SOURCE] <file.mica>...")
		os.exit(2)
	}

	reported := 0
	for path in paths {
		if disasm {
			if disassemble_file(path) {
				reported += 1
			}
			continue
		}
		if run_file(path, samples, budget_ms, workers, accel_mode, accel_report, print_result, raw_samples, verify_result, eval_source) {
			reported += 1
		}
	}
	if reported != len(paths) {
		os.exit(1)
	}
}

// Prints the compiled program for a corpus file, for inspecting codegen.
@(private)
disassemble_file :: proc(path: string) -> bool {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := r.world_start(
		&kernel,
		[]string{path},
		context.temp_allocator,
		r.World_Config{workers = 1},
	)
	if !start.ok {
		fmt.eprintf("FAIL %s: %s\n", path, start.message)
		return false
	}
	defer r.world_destroy(world)
	fmt.printf("%s\n", vm.program_disassemble(world.program, context.temp_allocator))
	return true
}

@(private)
parse_int :: proc(text: string, fallback: int) -> int {
	if len(text) == 0 {
		return fallback
	}
	n := 0
	for c in text {
		if c < '0' || c > '9' {
			return fallback
		}
		n = n * 10 + int(c - '0')
	}
	if n == 0 {
		return fallback
	}
	return n
}

@(private)
run_file :: proc(
	path: string,
	samples, budget_ms, workers: int,
	accel_mode: r.Accel_Mode,
	accel_report, print_result, raw_samples, verify_result: bool,
	eval_source: string,
) -> bool {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	world, start := r.world_start(
		&kernel,
		[]string{path},
		context.allocator,
		r.World_Config{workers = workers, accel = accel_mode},
	)
	if !start.ok {
		fmt.eprintf("FAIL %s: %s\n", path, start.message)
		return false
	}
	defer r.world_destroy(world)
	entry := r.world_wait(world, world.entry)
	if entry.kind != .Complete {
		fmt.eprintf("FAIL %s: entry: %s\n", path, entry.message)
		return false
	}
	before := k.placement_counts()

	// Optional one-time setup.
	if setup := r.world_call(world, "setup", nil); setup.kind == .Complete {
	} else if setup.message != "no applicable method" {
		fmt.eprintf("FAIL %s: setup: %s\n", path, setup.message)
		return false
	}

	// The benchmark must resolve.
	probe := benchmark_call(world, eval_source)
	if probe.kind != .Complete {
		fmt.eprintf("FAIL %s: bench: %s\n", path, probe.message)
		return false
	}
	// The first call's value, so runs can be checked against another
	// implementation of the same corpus.
	if print_result {
		fmt.printf("result\t%s\t%s\n", filepath.base(path), r.world_value_literal(world, probe.value, context.temp_allocator))
	}

	// Calibrate the inner repeat count so one sample spans ~budget_ms.
	// A larger inner count averages out scheduling jitter; a single slow call
	// otherwise skews a whole sample.
	single, timed_ok := time_calls(world, eval_source, 1, verify_result, probe.value)
	if !timed_ok {return false}
	inner := MIN_INNER
	if single > 0 {
		target := i64(time.Duration(budget_ms) * time.Millisecond)
		if target > single {
			computed := int(target / single)
			if computed > inner {
				inner = computed
			}
		}
	}
	if inner < 1 {
		inner = 1
	}

	// Warm up, then sample.
	for _ in 0 ..< 2 {
		if _, ok := time_calls(world, eval_source, inner, verify_result, probe.value); !ok {return false}
	}

	results := make([]i64, samples, context.temp_allocator)
	defer delete(results, context.temp_allocator)
	for sample in 0 ..< samples {
		elapsed, ok := time_calls(world, eval_source, inner, verify_result, probe.value)
		if !ok {return false}
		results[sample] = elapsed / i64(inner)
		if raw_samples {
			fmt.printf("sample\t%s\t%d\t%d\t%d\n", filepath.base(path), sample, results[sample], inner)
		}
	}

	slice.sort(results)

	median := results[len(results) / 2]
	minimum := results[0]
	name := filepath.base(path)
	fmt.printf("%s\t%d\t%d\t%d\n", name, median, minimum, samples)
	if accel_report {
		delta := k.placement_counts_delta(before, k.placement_counts())
		for op in k.Placement_Operator {
			for outcome in k.Placement_Outcome {
				if delta[op][outcome] > 0 {
					fmt.printf("accel: %v %v %d\n", op, outcome, delta[op][outcome])
				}
			}
		}
	}
	return true
}

// Live evaluation includes compilation, task dispatch, and execution.
@(private)
benchmark_call :: proc(world: ^r.World, eval_source: string) -> r.Task_Outcome {
	if eval_source != "" {return r.world_eval(world, eval_source)}
	return r.world_call(world, "bench", nil)
}

// Check every invocation, including calibration and warmup. Verification is
// inside the timed interval, so before/after runs must use the same flags.
@(private)
time_calls :: proc(world: ^r.World, eval_source: string, count: int, verify: bool, expected: v.Value) -> (i64, bool) {
	start := time.tick_now()
	for _ in 0..<count {
		outcome := benchmark_call(world, eval_source)
		if outcome.kind != .Complete {
			fmt.eprintf("FAIL timed invocation: %s\n", outcome.message)
			return 0, false
		}
		if verify && !v.value_eq(outcome.value, expected) {
			fmt.eprintln("FAIL timed invocation: result changed")
			return 0, false
		}
	}
	return i64(time.tick_diff(start, time.tick_now())), true
}
