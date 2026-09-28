// Full-corpus execution conformance for the Mica emitter (#81).
//
// For each corpus file this runs `setup` then `bench` twice:
//
//   - Odin baseline: the file loads and the Odin compiler's program runs.
//   - Mica path: the Mica emitter compiles the same source, and the decoded
//     artifact replaces the world's program before the calls run.
//
// Both worlds load only the corpus file, so method function indices agree;
// the Mica program reserves `main` then verbs in the same order. The results
// must be equal.
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import k "../../mica/kernel"
import r "../../mica/runtime"
import v "../../mica/var"
import vm "../../mica/vm"

COMPILER :: []string {
	"apps/compiler/lex.mica",
	"apps/compiler/parse.mica",
	"apps/compiler/emit.mica",
}

main :: proc() {
	dir := "benchmarks/mica"
	single := ""
	if len(os.args) > 1 {
		single = os.args[1]
	}
	handle, open_err := os.open(dir)
	if open_err != nil {
		fmt.eprintln("cannot open corpus:", open_err)
		os.exit(1)
	}
	defer os.close(handle)
	entries, read_err := os.read_dir(handle, -1, context.allocator)
	if read_err != nil {
		fmt.eprintln("cannot read corpus:", read_err)
		os.exit(1)
	}

	ok, failed := 0, 0
	for entry in entries {
		if !strings.has_suffix(entry.name, ".mica") {
			continue
		}
		if single != "" && entry.name != single {
			continue
		}
		path, join_err := filepath.join([]string{dir, entry.name}, context.allocator)
		if join_err != nil {
			continue
		}
		fmt.printf("...  %s\n", entry.name)
		source, read_source_err := os.read_entire_file_from_path(path, context.allocator)
		if read_source_err != nil {
			fmt.printf("FAIL %s: cannot read\n", entry.name)
			failed += 1
			continue
		}

		artifact, emit_ok := emit_artifact(string(source))
		if !emit_ok {
			fmt.printf("FAIL %s: emit\n", entry.name)
			failed += 1
			continue
		}

		baseline, baseline_ok := run_file(path, nil)
		if !baseline_ok {
			fmt.printf("FAIL %s: odin run\n", entry.name)
			failed += 1
			continue
		}
		emitted, emitted_ok := run_file(path, artifact)
		if !emitted_ok {
			fmt.printf("FAIL %s: mica run\n", entry.name)
			failed += 1
			continue
		}
		if v.value_eq(baseline, emitted) {
			fmt.printf("ok   %s\n", entry.name)
			ok += 1
		} else {
			fmt.printf("FAIL %s: results differ (odin %v, mica %v)\n", entry.name, baseline, emitted)
			failed += 1
		}
	}
	fmt.printf("\nok=%d failed=%d\n", ok, failed)
	if failed > 0 {
		os.exit(failed)
	}
}

// Compiles `source` with the Mica emitter in a compiler-only world.
emit_artifact :: proc(source: string) -> ([]u8, bool) {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := r.world_start(&kernel, COMPILER, context.allocator)
	if !start.ok {
		fmt.eprintln("compiler load failed:", start.message)
		return nil, false
	}
	defer r.world_destroy(world)
	_ = r.world_wait(world, world.entry)
	outcome := r.world_call(world, "emit_source", []k.Role_Pair{{
		role  = v.value_symbol(v.symbol_intern("source")),
		value = v.value_string(context.allocator, source),
	}})
	if outcome.kind != .Complete {
		return nil, false
	}
	fields, fields_ok := v.value_as_map(outcome.value)
	if !fields_ok {
		return nil, false
	}
	ok, _ := v.value_as_bool(map_get(fields, "ok"))
	if !ok {
		return nil, false
	}
	artifact, artifact_ok := v.value_as_bytes(map_get(fields, "bytes"))
	if !artifact_ok {
		return nil, false
	}
	owned := make([]u8, len(artifact), context.allocator)
	copy(owned, artifact)
	return owned, true
}

// Loads `path` alone, runs setup then bench, and returns the bench result.
// When `artifact` is non-nil it replaces the world's program first, so the
// calls exercise the Mica-emitted program.
run_file :: proc(path: string, artifact: []u8) -> (v.Value, bool) {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	// A mis-emitted loop is unbounded; the budget turns that into a failed
	// case rather than a hung run.
	world, start := r.world_start(&kernel, []string{path}, context.allocator, r.HARNESS_CONFIG)
	if !start.ok {
		return v.Value(0), false
	}
	defer r.world_destroy(world)
	entry := r.world_wait(world, world.entry)
	if entry.kind != .Complete {
		return v.Value(0), false
	}

	if artifact != nil {
		program, decode_error := vm.program_from_bytes(artifact, context.allocator)
		if decode_error != .None {
			return v.Value(0), false
		}
		if vm.program_validate(program) != .None {
			return v.Value(0), false
		}
		replaced := r.world_replace_program(world, program, context.allocator)
		assert(replaced.ok, replaced.message)
	}

	if setup := r.world_call(world, "setup", nil); setup.kind != .Complete {
		if setup.message != "no applicable method" {
			return v.Value(0), false
		}
	}
	bench := r.world_call(world, "bench", nil)
	if bench.kind != .Complete {
		return v.Value(0), false
	}
	return bench.value, true
}

map_get :: proc(entries: []v.Map_Entry, name: string) -> v.Value {
	key := v.value_symbol(v.symbol_intern(name))
	for entry in entries {
		if entry.key == key {
			return entry.value
		}
	}
	return v.Value(0)
}
