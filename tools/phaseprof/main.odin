// Times compiler phases separately: lex, parse_rows, and the full emit.
//
//   odin run tools/phaseprof -o:speed -- [iterations] [target]
//
// Each phase is a verb in the compiler world, so the split shows whether the
// interpreter-side cost is dominated by lexing, parsing, or emission.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"
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
	iterations := 7
	if len(os.args) > 1 {
		if parsed, ok := strconv.parse_int(os.args[1]); ok {
			iterations = max(parsed, 1)
		}
	}
	target_path := "apps/compiler/emit.mica"
	if len(os.args) > 2 {
		target_path = os.args[2]
	}
	data, read_err := os.read_entire_file_from_path(target_path, context.allocator)
	if read_err != nil {
		fmt.eprintln("cannot read", target_path)
		os.exit(1)
	}
	target := string(data)

	// Read the compiler up front so the artifact load is outside the timing.
	compiler_source := read_compiler()
	fmt.printf("target: %s (%d bytes)\n", target_path, len(target))

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := r.world_start(&kernel, COMPILER, context.allocator)
	if !start.ok {
		fmt.eprintln("load failed:", start.message)
		os.exit(1)
	}
	defer r.world_destroy(world)
	_ = r.world_wait(world, world.entry)

	// Odin-compiled compiler: phase split on the target.
	fmt.println("\n-- odin-compiled compiler --")
	time_verb(world, "lex", target, iterations)
	time_verb(world, "parse_rows", target, iterations)
	time_verb(world, "emit_source", target, iterations)

	// Compile the compiler with itself (the Mica emitter), then swap it in and
	// repeat. The compiler emitting itself is the heaviest single workload.
	artifact := emit_artifact(world, compiler_source)
	if artifact == nil {
		fmt.eprintln("FAIL: could not emit the compiler")
		os.exit(1)
	}
	program, decode_error := vm.program_from_bytes(artifact, context.allocator)
	if decode_error != .None {
		fmt.eprintln("decode:", decode_error)
		os.exit(1)
	}
	replaced := r.world_replace_program(world, program, context.allocator)
	assert(replaced.ok, replaced.message)

	fmt.println("\n-- mica-emitted compiler --")
	time_verb(world, "lex", target, iterations)
	time_verb(world, "parse_rows", target, iterations)
	time_verb(world, "emit_source", target, iterations)

	fmt.println("\n-- mica-emitted compiler compiling itself --")
	time_verb(world, "lex", compiler_source, iterations)
	time_verb(world, "parse_rows", compiler_source, iterations)
	time_verb(world, "emit_source", compiler_source, iterations)
}

time_verb :: proc(world: ^r.World, selector: string, source: string, iterations: int) -> i64 {
	roles := []k.Role_Pair{{
		role  = v.value_symbol(v.symbol_intern("source")),
		value = v.value_string(context.allocator, source),
	}}
	for _ in 0 ..< 2 {
		outcome := r.world_call(world, selector, roles)
		if outcome.kind != .Complete {
			fmt.eprintln(selector, "warmup failed:", outcome.message)
			return 0
		}
	}
	best := i64(1 << 62)
	for _ in 0 ..< iterations {
		start_tick := time.tick_now()
		outcome := r.world_call(world, selector, roles)
		elapsed := i64(time.tick_since(start_tick))
		if outcome.kind != .Complete {
			fmt.eprintln(selector, "failed:", outcome.message)
			return 0
		}
		best = min(best, elapsed)
	}
	per_byte := f64(best) / f64(len(source))
	fmt.printf("  %-12s %9.3f us  (%.3f us/byte)\n", selector, f64(best)/1000.0, per_byte)
	return best
}

read_compiler :: proc() -> string {
	joined := make([dynamic]u8, 0, 160000, context.allocator)
	for path in COMPILER {
		data, read_err := os.read_entire_file_from_path(path, context.allocator)
		if read_err != nil {
			fmt.eprintln("cannot read", path)
			os.exit(1)
		}
		append(&joined, '\n')
		for ch in transmute([]u8)string(data) {
			append(&joined, ch)
		}
	}
	return string(joined[:])
}

emit_artifact :: proc(world: ^r.World, source: string) -> []u8 {
	outcome := r.world_call(world, "emit_source", []k.Role_Pair{{
		role  = v.value_symbol(v.symbol_intern("source")),
		value = v.value_string(context.allocator, source),
	}})
	if outcome.kind != .Complete {
		return nil
	}
	fields, fields_ok := v.value_as_map(outcome.value)
	if !fields_ok {
		return nil
	}
	ok, _ := v.value_as_bool(map_get(fields, "ok"))
	if !ok {
		return nil
	}
	artifact, artifact_ok := v.value_as_bytes(map_get(fields, "bytes"))
	if !artifact_ok {
		return nil
	}
	owned := make([]u8, len(artifact), context.allocator)
	copy(owned, artifact)
	return owned
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
