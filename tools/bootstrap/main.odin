// Boots the Mica-emitted compiler (#81).
//
// Stage 1 (bootstrap): load the compiler sources into a world. The world
// compiles them with the Odin compiler and installs the verbs as methods;
// calling `emit_source` runs that Odin-compiled program.
//
// Stage 2 (self-hosted): compile the same sources with the Mica emitter,
// decode the artifact, and replace the world's program. Method function
// indices agree (entry `main` first, then verbs in declaration order), so the
// installed methods now dispatch into the Mica-emitted compiler. Calling
// `emit_source` again compiles the target with the Mica compiler.
//
// The bootstrap holds when both stages compile the same target to programs
// that decode, validate, and agree on running the result.
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

// A target exercising literals, arithmetic, control flow, a call, a relation
// query/write, a comprehension, and a for-pattern.
TARGET :: `make_relation(:Point, 1)
verb classify(n)
  if n < 0
    "neg"
  elseif n == 0
    "zero"
  else
    "pos"
  end
end

verb bench()
  assert Point(3)
  assert Point(7)
  let total = 0
  for row in Point(?x)
    total = total + row[:x]
  end
  let doubled = [n * 2 for n in [1, 2, 3] if n != 2]
  let label = classify(total)
  if label == "pos"
    total + string_len("boot") + len(doubled)
  else
    0
  end
end
`

main :: proc() {
	failed := 0

	// Stage 1: the Odin-compiled compiler's answer for the target.
	odin_artifact, odin_ok := compile_with(TARGET)
	if !odin_ok {
		fmt.eprintln("FAIL: odin-compiled compiler could not emit the target")
		os.exit(1)
	}

	// Emit the compiler itself with the Mica emitter, in a separate world.
	compiler_artifact, compiler_ok := emit_compiler()
	if !compiler_ok {
		fmt.eprintln("FAIL: the Mica emitter could not emit the compiler")
		os.exit(1)
	}
	fmt.printf("ok   Mica emitter emitted the compiler (%d bytes)\n", len(compiler_artifact))

	// Stage 2: boot the compiler world, swap in the Mica-emitted compiler, and
	// compile the same target with it.
	self_artifact, self_ok := compile_with(TARGET, compiler_artifact)
	if !self_ok {
		fmt.eprintln("FAIL: the Mica-emitted compiler could not emit the target")
		os.exit(1)
	}
	fmt.printf("ok   Mica-emitted compiler emitted the target (%d bytes)\n", len(self_artifact))

	// The two compilers must produce behaviorally identical programs: run
	// both artifacts and compare results.
	odin_result, odin_ran := run_artifact(TARGET, odin_artifact)
	self_result, self_ran := run_artifact(TARGET, self_artifact)
	if !odin_ran || !self_ran {
		fmt.eprintln("FAIL: a bootstrap artifact did not run")
		os.exit(1)
	}
	if !v.value_eq(odin_result, self_result) {
		fmt.printf(
			"FAIL: bootstrap results differ (odin %s, mica %s)\n",
			v.value_to_string(odin_result, context.allocator),
			v.value_to_string(self_result, context.allocator),
		)
		failed += 1
	} else {
		fmt.printf(
			"ok   bootstrap agrees: %s\n",
			v.value_to_string(self_result, context.allocator),
		)
	}
	os.exit(failed)
}

// Loads the compiler into a world and compiles `target`. With `main` true the
// world runs its own Odin-compiled program. With a `replace` artifact the
// world's program is swapped first, so the call runs that compiler instead.
compile_with :: proc(target: string, replace: []u8 = nil) -> ([]u8, bool) {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := r.world_start(&kernel, COMPILER, context.allocator)
	if !start.ok {
		fmt.eprintln("compiler load failed:", start.message)
		return nil, false
	}
	defer r.world_destroy(world)
	entry := r.world_wait(world, world.entry)
	if entry.kind != .Complete {
		return nil, false
	}
	if replace != nil {
		program, decode_error := vm.program_from_bytes(replace, context.allocator)
		if decode_error != .None {
			return nil, false
		}
		if vm.program_validate(program) != .None {
			return nil, false
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

// Emits the compiler sources with the Mica emitter, in a clean world.
emit_compiler :: proc() -> ([]u8, bool) {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := r.world_start(&kernel, COMPILER, context.allocator)
	if !start.ok {
		return nil, false
	}
	defer r.world_destroy(world)
	_ = r.world_wait(world, world.entry)

	// Concatenate the three sources so the Mica emitter sees one program, the
	// same shape a single-file load produces.
	source := ""
	for path in COMPILER {
		data, read_err := os.read_entire_file_from_path(path, context.allocator)
		if read_err != nil {
			return nil, false
		}
		source = fmt.aprintf("%s\n%s", source, string(data))
	}
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
		errors := map_get(fields, "errors")
		if list, list_ok := v.value_as_list(errors); list_ok && len(list) > 0 {
			if s, s_ok := v.value_as_string(list[0]); s_ok {
				fmt.eprintln("emit error:", s)
			}
		}
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

// Loads the target source into a world (so its relations and methods exist),
// swaps in `artifact`, and runs bench. The Odin-compiled and Mica-emitted
// programs share function indices, so the installed methods dispatch into the
// swapped program.
run_artifact :: proc(target: string, artifact: []u8) -> (v.Value, bool) {
	path := "/tmp/mica_bootstrap_target.mica"
	if write_err := os.write_entire_file(path, target); write_err != nil {
		return v.Value(0), false
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	// A mis-emitted loop is unbounded; the budget turns that into a failed
	// case rather than a hung run.
	world, start := r.world_start(&kernel, []string{path}, context.allocator, r.HARNESS_CONFIG)
	if !start.ok {
		fmt.eprintln("target load failed:", start.message)
		return v.Value(0), false
	}
	defer r.world_destroy(world)
	entry := r.world_wait(world, world.entry)
	if entry.kind != .Complete {
		return v.Value(0), false
	}
	program, decode_error := vm.program_from_bytes(artifact, context.allocator)
	if decode_error != .None {
		fmt.eprintln("target artifact decode:", decode_error)
		return v.Value(0), false
	}
	if vm.program_validate(program) != .None {
		fmt.eprintln("target artifact invalid")
		return v.Value(0), false
	}
	replaced := r.world_replace_program(world, program, context.allocator)
	assert(replaced.ok, replaced.message)
	bench := r.world_call(world, "bench", nil)
	if bench.kind != .Complete {
		fmt.eprintln("target bench:", bench.message)
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
