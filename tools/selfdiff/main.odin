// Runtime differential test of the Mica compiler's emitter (#81).
//
// For each `.mica` file given on the command line this compiles the file's
// source two ways:
//
//   Stage 1: the compiler sources compiled by the Odin compiler run inside a
//            world and emit the target. Artifact A is that compiler's output.
//   Stage 2: the Mica emitter emits the compiler itself (with the Odin
//            compiler running it), the decoded self-emitted compiler replaces
//            the world's program, and it emits the same target. Artifact B is
//            the self-hosted compiler's output.
//
// Both artifacts must decode with `vm.program_from_bytes` and pass
// `vm.program_validate`. When the target declares a `bench` verb both programs
// are run against the target's own world and their results must agree; every
// target is also compared structurally on function count and total instruction
// count, which catches disagreement even without a runnable entry.
//
// One line per file: `ok <path>` or `FAIL <path>: <reason>`, then `failed=<n>`.
//
//   odin build tools/selfdiff -o:speed -out:/tmp/selfdiff
//   /tmp/selfdiff $(find apps mica -name '*.mica' -type f | sort)
package main

import "core:fmt"
import "core:os"
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
	paths := os.args[1:]
	if len(paths) == 0 {
		fmt.eprintln("usage: selfdiff <file.mica> ...")
		os.exit(2)
	}

	// Emit the compiler with the Mica emitter once; every stage 2 reuses it.
	compiler_artifact, compiler_ok, compiler_reason := emit_compiler()
	if !compiler_ok {
		fmt.eprintln("FAIL: the Mica emitter could not emit the compiler:", compiler_reason)
		os.exit(1)
	}

	failed := 0
	for path in paths {
		ok, reason := diff_file(path, compiler_artifact)
		if ok {
			fmt.printf("ok   %s\n", path)
		} else {
			fmt.printf("FAIL %s: %s\n", path, reason)
			failed += 1
		}
	}
	fmt.printf("\nfailed=%d\n", failed)
	os.exit(failed)
}

// Compiles `path` with both compilers and compares the results.
diff_file :: proc(path: string, compiler_artifact: []u8) -> (bool, string) {
	data, read_err := os.read_entire_file_from_path(path, context.allocator)
	if read_err != nil {
		return false, "cannot read"
	}
	source := string(data)

	// Stage 1: the Odin-compiled compiler emits the target.
	odin_artifact, odin_ok, odin_reason := compile_with(source)
	if !odin_ok {
		return false, fmt.aprintf("odin-compiled compiler: %s", odin_reason)
	}
	defer delete(odin_artifact, context.allocator)

	// Stage 2: the Mica-emitted compiler emits the same target.
	mica_artifact, mica_ok, mica_reason := compile_with(source, compiler_artifact)
	if !mica_ok {
		return false, fmt.aprintf("mica-emitted compiler: %s", mica_reason)
	}
	defer delete(mica_artifact, context.allocator)

	odin_program, odin_decode := vm.program_from_bytes(odin_artifact, context.allocator)
	if odin_decode != .None {
		return false, fmt.aprintf("odin artifact decode: %v", odin_decode)
	}
	defer vm.program_destroy(odin_program, context.allocator)
	if odin_validation := vm.program_validate(odin_program); odin_validation != .None {
		return false, fmt.aprintf("odin artifact invalid: %v", odin_validation)
	}

	mica_program, mica_decode := vm.program_from_bytes(mica_artifact, context.allocator)
	if mica_decode != .None {
		return false, fmt.aprintf("mica artifact decode: %v", mica_decode)
	}
	defer vm.program_destroy(mica_program, context.allocator)
	if mica_validation := vm.program_validate(mica_program); mica_validation != .None {
		return false, fmt.aprintf("mica artifact invalid: %v", mica_validation)
	}

	if len(odin_program.functions) != len(mica_program.functions) {
		return false, fmt.aprintf(
			"function count differs (odin %d, mica %d)",
			len(odin_program.functions),
			len(mica_program.functions),
		)
	}
	odin_instructions := total_instructions(odin_program)
	mica_instructions := total_instructions(mica_program)
	if odin_instructions != mica_instructions {
		return false, fmt.aprintf(
			"instruction count differs (odin %d, mica %d)",
			odin_instructions,
			mica_instructions,
		)
	}

	// A runnable target is exercised end to end: load its world, swap each
	// program in, run `bench`, and require equal results.
	if has_function(odin_program, "bench") && has_function(mica_program, "bench") {
		odin_result, odin_ran := run_artifact(path, odin_artifact)
		if !odin_ran {
			return false, "odin program did not run"
		}
		mica_result, mica_ran := run_artifact(path, mica_artifact)
		if !mica_ran {
			return false, "mica program did not run"
		}
		if !v.value_eq(odin_result, mica_result) {
			return false, fmt.aprintf(
				"results differ (odin %s, mica %s)",
				v.value_to_string(odin_result, context.temp_allocator),
				v.value_to_string(mica_result, context.temp_allocator),
			)
		}
	}
	return true, ""
}

// Loads the compiler into a world and compiles `target`. With a `replace`
// artifact the world's program is swapped first, so `emit_source` runs that
// compiler instead of the Odin-compiled one.
compile_with :: proc(target: string, replace: []u8 = nil) -> ([]u8, bool, string) {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := r.world_start(&kernel, COMPILER, context.allocator)
	if !start.ok {
		return nil, false, fmt.aprintf("compiler load: %s", start.message)
	}
	defer r.world_destroy(world)
	entry := r.world_wait(world, world.entry)
	if entry.kind != .Complete {
		return nil, false, fmt.aprintf("compiler entry: %s", entry.message)
	}
	if replace != nil {
		program, decode_error := vm.program_from_bytes(replace, context.allocator)
		if decode_error != .None {
			return nil, false, fmt.aprintf("replace decode: %v", decode_error)
		}
		if vm.program_validate(program) != .None {
			return nil, false, "replace invalid"
		}
		replaced := r.world_replace_program(world, program, context.allocator)
		assert(replaced.ok, replaced.message)
	}
	outcome := r.world_call(
		world,
		"emit_source",
		[]k.Role_Pair {
			{
				role = v.value_symbol(v.symbol_intern("source")),
				value = v.value_string(context.allocator, target),
			},
		},
	)
	if outcome.kind != .Complete {
		detail := outcome.message
		if error_value, is_error := v.value_as_error(outcome.error); is_error {
			detail = error_value.message
		}
		return nil, false, fmt.aprintf("emit_source call: %s", detail)
	}
	fields, fields_ok := v.value_as_map(outcome.value)
	if !fields_ok {
		return nil, false, "emit returned a non-map"
	}
	ok, _ := v.value_as_bool(map_get(fields, "ok"))
	if !ok {
		if list, list_ok := v.value_as_list(map_get(fields, "errors")); list_ok && len(list) > 0 {
			if message, message_ok := v.value_as_string(list[0]); message_ok {
				return nil, false, message
			}
		}
		return nil, false, "emitter reported an error"
	}
	artifact, artifact_ok := v.value_as_bytes(map_get(fields, "bytes"))
	if !artifact_ok {
		return nil, false, "emit returned no bytes"
	}
	owned := make([]u8, len(artifact), context.allocator)
	copy(owned, artifact)
	return owned, true, ""
}

// Emits the compiler sources with the Mica emitter, in a clean world.
emit_compiler :: proc() -> ([]u8, bool, string) {
	source := ""
	for path in COMPILER {
		data, read_err := os.read_entire_file_from_path(path, context.allocator)
		if read_err != nil {
			return nil, false, fmt.aprintf("cannot read %s", path)
		}
		source = fmt.aprintf("%s\n%s", source, string(data))
	}
	return compile_with(source)
}

// Loads the target file into a world (so its relations and methods exist),
// swaps in `artifact`, and runs `bench`. The Odin-compiled and Mica-emitted
// programs share function indices, so installed methods dispatch into the
// swapped program.
run_artifact :: proc(path: string, artifact: []u8) -> (v.Value, bool) {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	// A mis-emitted loop is unbounded; the budget turns that into a failed
	// case rather than a hung run.
	world, start := r.world_start(&kernel, []string{path}, context.allocator, r.HARNESS_CONFIG)
	if !start.ok {
		fmt.eprintln("  target load failed:", start.message)
		return v.Value(0), false
	}
	defer r.world_destroy(world)
	entry := r.world_wait(world, world.entry)
	if entry.kind != .Complete {
		fmt.eprintln("  target entry failed:", entry.message)
		return v.Value(0), false
	}
	program, decode_error := vm.program_from_bytes(artifact, context.allocator)
	if decode_error != .None {
		fmt.eprintln("  target artifact decode:", decode_error)
		return v.Value(0), false
	}
	if vm.program_validate(program) != .None {
		fmt.eprintln("  target artifact invalid")
		return v.Value(0), false
	}
	replaced := r.world_replace_program(world, program, context.allocator)
	assert(replaced.ok, replaced.message)
	bench := r.world_call(world, "bench", nil)
	if bench.kind != .Complete {
		fmt.eprintln("  target bench:", bench.message)
		return v.Value(0), false
	}
	return bench.value, true
}

// Whether the program declares a function with the given name. The emitter
// reserves `main` first, then verbs in declaration order.
has_function :: proc(program: ^vm.Program, name: string) -> bool {
	wanted := v.symbol_intern(name)
	for function in program.functions {
		if function.name == wanted {
			return true
		}
	}
	return false
}

total_instructions :: proc(program: ^vm.Program) -> int {
	total := 0
	for function in program.functions {
		total += function.code_len
	}
	return total
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
