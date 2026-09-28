// Times the compiler under both programs.
//
//   odin run tools/compilerperf -o:speed -- [iterations] [target]
//
// Stage 1 loads the compiler sources (Odin-compiled program) and times
// `emit_source` on `target`. Stage 2 emits the compiler with the Mica emitter,
// installs that artifact in a world, and times the same call. Reports minimum
// nanoseconds per call for each, so the two can be compared directly.
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
	iterations := 15
	if len(os.args) > 1 {
		if parsed, ok := strconv.parse_int(os.args[1]); ok {
			iterations = max(parsed, 1)
		}
	}
	target := TARGET
	if len(os.args) > 2 {
		data, read_err := os.read_entire_file_from_path(os.args[2], context.allocator)
		if read_err != nil {
			fmt.eprintln("cannot read target:", os.args[2])
			os.exit(1)
		}
		target = string(data)
	}

	compiler_source := read_compiler()
	fmt.printf("compiler source: %d bytes\n", len(compiler_source))
	fmt.printf("target: %d bytes, %d iterations\n\n", len(target), iterations)

	// Stage 1: the Odin-compiled compiler.
	odin_ns := time_compile(nil, target, iterations, "odin")

	// Emit the compiler with the Mica emitter.
	artifact := emit_compiler(compiler_source)
	if artifact == nil {
		fmt.eprintln("FAIL: Mica emitter could not emit the compiler")
		os.exit(1)
	}
	fmt.printf("mica-emitted compiler: %d bytes\n\n", len(artifact))

	// Stage 2: the Mica-emitted compiler.
	mica_ns := time_compile(artifact, target, iterations, "mica")

	// Null control: the Odin program again, under a second label. The
	// difference between odin and this is the harness noise floor.
	null_ns := time_compile(nil, target, iterations, "null")

	if odin_ns > 0 && mica_ns > 0 && null_ns > 0 {
		ratio := f64(mica_ns) / f64(odin_ns)
		null_ratio := f64(null_ns) / f64(odin_ns)
		fmt.printf("\nodin %8.3f us   mica %8.3f us   ratio %.2fx\n",
			f64(odin_ns)/1000.0, f64(mica_ns)/1000.0, ratio)
		fmt.printf("null control (odin vs odin):              %.2fx\n", null_ratio)
	}
}

read_compiler :: proc() -> string {
	total := 0
	parts: [3]string
	for path, index in COMPILER {
		data, read_err := os.read_entire_file_from_path(path, context.allocator)
		if read_err != nil {
			fmt.eprintln("cannot read", path)
			os.exit(1)
		}
		parts[index] = string(data)
		total += len(parts[index])
	}
	joined := make([dynamic]u8, 0, total+4, context.allocator)
	for part in parts {
		append(&joined, '\n')
		for ch in transmute([]u8)part {
			append(&joined, ch)
		}
	}
	return string(joined[:])
}

// Loads the compiler and times `emit_source` over `iterations`, returning the
// best (minimum) nanoseconds per call.
time_compile :: proc(replace: []u8, target: string, iterations: int, label: string) -> i64 {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := r.world_start(&kernel, COMPILER, context.allocator)
	if !start.ok {
		fmt.eprintln("compiler load failed:", start.message)
		os.exit(1)
	}
	defer r.world_destroy(world)
	entry := r.world_wait(world, world.entry)
	if entry.kind != .Complete {
		fmt.eprintln("entry failed")
		os.exit(1)
	}
	if replace != nil {
		program, decode_error := vm.program_from_bytes(replace, context.allocator)
		if decode_error != .None {
			fmt.eprintln("decode:", decode_error)
			os.exit(1)
		}
		if vm.program_validate(program) != .None {
			fmt.eprintln("invalid program")
			os.exit(1)
		}
		replaced := r.world_replace_program(world, program, context.allocator)
		assert(replaced.ok, replaced.message)
	}
	roles := []k.Role_Pair {
		{
			role = v.value_symbol(v.symbol_intern("source")),
			value = v.value_string(context.allocator, target),
		},
	}
	// Warm up.
	for _ in 0 ..< 3 {
		outcome := r.world_call(world, "emit_source", roles)
		if outcome.kind != .Complete {
			fmt.eprintln(label, "warmup failed:", outcome.message)
			os.exit(1)
		}
	}
	best := i64(1 << 62)
	for _ in 0 ..< iterations {
		start_tick := time.tick_now()
		outcome := r.world_call(world, "emit_source", roles)
		elapsed := i64(time.tick_since(start_tick))
		if outcome.kind != .Complete {
			fmt.eprintln(label, "failed:", outcome.message)
			os.exit(1)
		}
		best = min(best, elapsed)
	}
	fmt.printf("%-5s best %8.3f us/call\n", label, f64(best) / 1000.0)
	return best
}

emit_compiler :: proc(compiler_source: string) -> []u8 {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := r.world_start(&kernel, COMPILER, context.allocator)
	if !start.ok {
		return nil
	}
	defer r.world_destroy(world)
	_ = r.world_wait(world, world.entry)
	outcome := r.world_call(world, "emit_source", []k.Role_Pair{{
		role  = v.value_symbol(v.symbol_intern("source")),
		value = v.value_string(context.allocator, compiler_source),
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
		if errors := map_get(fields, "errors"); errors != 0 {
			if list, list_ok := v.value_as_list(errors); list_ok && len(list) > 0 {
				if s, s_ok := v.value_as_string(list[0]); s_ok {
					fmt.eprintln("emit error:", s)
				}
			}
		}
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
