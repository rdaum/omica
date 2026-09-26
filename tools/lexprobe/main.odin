// Emits the lexer with the Mica emitter, runs its `lex`, and compares the
// token list to the Odin-compiled lexer. A mismatch is a miscompilation.
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
TARGET_SRC :: "let x = 1 + 2\nif x > 0\n  return x\nend\n"

main :: proc() {
	// Odin baseline: load the lexer source, call lex.
	baseline := run_lexer(nil)
	// Mica: emit lex.mica with the Mica emitter, swap it in, call lex.
	source, _ := os.read_entire_file_from_path("apps/compiler/lex.mica", context.allocator)
	artifact := emit_source(string(source))
	if artifact == nil {
		fmt.eprintln("FAIL: could not emit lex.mica")
		os.exit(1)
	}
	emitted := run_lexer(artifact)
	fmt.println("odin :", v.value_to_string(baseline, context.allocator))
	fmt.println("mica :", v.value_to_string(emitted, context.allocator))
	if !v.value_eq(baseline, emitted) {
		fmt.println("MISMATCH")
		os.exit(1)
	}
	fmt.println("ok")
}

emit_source :: proc(source: string) -> []u8 {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := r.world_start(&kernel, COMPILER, context.allocator)
	if !start.ok {
		fmt.eprintln("load failed:", start.message)
		return nil
	}
	defer r.world_destroy(world)
	_ = r.world_wait(world, world.entry)
	outcome := r.world_call(world, "emit_source", []k.Role_Pair{{
		role  = v.value_symbol(v.symbol_intern("source")),
		value = v.value_string(context.allocator, source),
	}})
	if outcome.kind != .Complete { return nil }
	fields, _ := v.value_as_map(outcome.value)
	ok, _ := v.value_as_bool(map_get(fields, "ok"))
	if !ok { return nil }
	artifact, _ := v.value_as_bytes(map_get(fields, "bytes"))
	owned := make([]u8, len(artifact), context.allocator)
	copy(owned, artifact)
	return owned
}

run_lexer :: proc(replace: []u8) -> v.Value {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	// Budget the lexer under test so a mis-emitted loop fails instead of
	// hanging.
	world, start := r.world_start(
		&kernel,
		[]string{"apps/compiler/lex.mica"},
		context.allocator,
		r.HARNESS_CONFIG,
	)
	if !start.ok {fmt.eprintln("lexer load:", start.message); return v.Value(0)}
	defer r.world_destroy(world)
	_ = r.world_wait(world, world.entry)
	if replace != nil {
		program, err := vm.program_from_bytes(replace, context.allocator)
		if err != .None {fmt.eprintln("decode:", err); return v.Value(0)}
		replaced := r.world_replace_program(world, program, context.allocator)
		assert(replaced.ok, replaced.message)
	}
	outcome := r.world_call(
		world,
		"lex",
		[]k.Role_Pair {
			{
				role = v.value_symbol(v.symbol_intern("source")),
				value = v.value_string(context.allocator, TARGET_SRC),
			},
		},
	)
	if outcome.kind != .Complete {
		detail := outcome.message
		if ev, is_err := v.value_as_error(outcome.error); is_err {detail = ev.message}
		fmt.eprintln("lex call failed:", detail)
		return v.Value(0)
	}
	return outcome.value
}

map_get :: proc(entries: []v.Map_Entry, name: string) -> v.Value {
	key := v.value_symbol(v.symbol_intern(name))
	for entry in entries { if entry.key == key { return entry.value } }
	return v.Value(0)
}
