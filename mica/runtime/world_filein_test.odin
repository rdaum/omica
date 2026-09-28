// Tests for filing new sources into a running world.
package mica_runtime

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:testing"
import k "../kernel"
import v "../var"

@(private = "file")
BASE_SOURCE :: `make_identity(:alice)
make_relation(:Marker, 2)

verb mark(who)
  assert Marker(who, :marked)
end
assert Marker(#alice, :seed)
`

@(private = "file")
ADDED_SOURCE :: `make_identity(:bob)
make_relation(:Friend, 2)
make_relation(:Reach, 2)

verb befriend(a, b)
  assert Friend(a, b)
end

Reach(?x, ?y) :- Friend(?x, ?y)
Reach(?x, ?z) :- Friend(?x, ?y), Reach(?y, ?z)

assert Friend(#alice, #bob)
assert Marker(#bob, :added)
`

@(private = "file")
temp_store :: proc(t: ^testing.T, name: string) -> (string, bool) {
	directory, directory_error := os.temp_dir(context.temp_allocator)
	if directory_error != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return "", false
	}
	path, join_error := filepath.join([]string{directory, name}, context.temp_allocator)
	if join_error != nil {
		return "", false
	}
	os.remove_all(path)
	return path, true
}

@(private = "file")
expect_eval_text :: proc(t: ^testing.T, world: ^World, source: string, expected: string) {
	outcome := world_eval(world, source)
	testing.expectf(t, outcome.kind == .Complete, "%s failed: %s", source, outcome.message)
	if outcome.kind == .Complete {
		text := world_value_literal(world, outcome.value)
		testing.expectf(t, text == expected, "%s: expected %s, got %s", source, expected, text)
	}
}

@(test)
test_world_filein_adds_to_running_world :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	base, base_ok := write_temp_source(t, "mica_filein_base.mica", BASE_SOURCE)
	added, added_ok := write_temp_source(t, "mica_filein_added.mica", ADDED_SOURCE)
	if !base_ok || !added_ok {
		return
	}
	defer os.remove(base)
	defer os.remove(added)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := world_start(&kernel, []string{base}, runtime.heap_allocator(), World_Config{})
	testing.expectf(t, start.ok, "load failed: %s", start.message)
	if !start.ok {
		return
	}
	defer world_destroy(world)
	testing.expect_value(t, world_wait(world, world.entry).kind, Task_Outcome_Kind.Complete)

	loaded := world_filein(world, []string{added}, "")
	testing.expectf(t, loaded.kind == .Complete, "filein failed: %s", loaded.message)

	// New declarations, facts, and rules are visible.
	expect_eval_text(t, world, "return Reach(#alice, ?y)", "[:y] {[#bob]}")
	expect_relation_rows(t, &kernel, "Marker", 2)
	// The new verb and the old verb both dispatch.
	bob := world.ctx.identities["bob"]
	alice := world.ctx.identities["alice"]
	befriended := world_call(
		world,
		"befriend",
		[]k.Role_Pair {
			{role = v.value_symbol(v.symbol_intern("a")), value = bob},
			{role = v.value_symbol(v.symbol_intern("b")), value = alice},
		},
	)
	testing.expectf(t, befriended.kind == .Complete, "befriend failed: %s", befriended.message)
	marked := world_call(
		world,
		"mark",
		[]k.Role_Pair{{role = v.value_symbol(v.symbol_intern("who")), value = bob}},
	)
	testing.expectf(t, marked.kind == .Complete, "mark failed: %s", marked.message)
	expect_relation_rows(t, &kernel, "Marker", 3)
	expect_eval_text(t, world, "return Reach(#bob, #bob)", "true")
}

@(test)
test_world_filein_into_booted_store_persists :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	base, base_ok := write_temp_source(t, "mica_filein_store_base.mica", BASE_SOURCE)
	added, added_ok := write_temp_source(t, "mica_filein_store_added.mica", ADDED_SOURCE)
	store_path, store_ok := temp_store(t, "mica_filein_store")
	if !base_ok || !added_ok || !store_ok {
		return
	}
	defer os.remove(base)
	defer os.remove(added)
	defer os.remove_all(store_path)

	// Load the base world.
	{
		kernel: k.Kernel
		k.kernel_init(&kernel)
		world, start := world_start(&kernel, []string{base}, runtime.heap_allocator(), World_Config{store_path = store_path})
		testing.expectf(t, start.ok, "load failed: %s", start.message)
		if start.ok {
			testing.expect_value(t, world_wait(world, world.entry).kind, Task_Outcome_Kind.Complete)
			testing.expect(t, world_checkpoint(world))
			world_destroy(world)
		}
		k.kernel_destroy(&kernel)
	}
	// Boot it and file in more source.
	{
		kernel: k.Kernel
		k.kernel_init(&kernel)
		world, start := world_start(&kernel, nil, runtime.heap_allocator(), World_Config{store_path = store_path})
		testing.expectf(t, start.ok, "boot failed: %s", start.message)
		if start.ok {
			testing.expect(t, world.booted)
			loaded := world_filein(world, []string{added}, "")
			testing.expectf(t, loaded.kind == .Complete, "filein failed: %s", loaded.message)
			expect_eval_text(t, world, "return Reach(#alice, ?y)", "[:y] {[#bob]}")
			testing.expect(t, world_checkpoint(world))
			world_destroy(world)
		}
		k.kernel_destroy(&kernel)
	}
	// Boot again: everything the filein added is still there, and both verbs dispatch.
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := world_start(&kernel, nil, runtime.heap_allocator(), World_Config{store_path = store_path})
	testing.expectf(t, start.ok, "second boot failed: %s", start.message)
	if !start.ok {
		return
	}
	defer world_destroy(world)
	expect_eval_text(t, world, "return Reach(#alice, ?y)", "[:y] {[#bob]}")
	expect_relation_rows(t, &kernel, "Marker", 2)
	bob, has_bob := world.ctx.identities["bob"]
	testing.expect(t, has_bob)
	marked := world_call(
		world,
		"mark",
		[]k.Role_Pair{{role = v.value_symbol(v.symbol_intern("who")), value = bob}},
	)
	testing.expectf(t, marked.kind == .Complete, "mark after reboot failed: %s", marked.message)
	befriended := world_call(
		world,
		"befriend",
		[]k.Role_Pair {
			{role = v.value_symbol(v.symbol_intern("a")), value = bob},
			{role = v.value_symbol(v.symbol_intern("b")), value = bob},
		},
	)
	testing.expectf(t, befriended.kind == .Complete, "befriend after reboot failed: %s", befriended.message)
	program_rows: [dynamic]v.Tuple
	defer delete(program_rows)
	k.kernel_scan_into(&kernel, k.SYSTEM_PROGRAM_BYTES_ID, []v.Binding{{}, {}}, &program_rows)
	testing.expect_value(t, len(program_rows), 2)
}

@(private = "file")
CALLER_SOURCE :: `make_relation(:Adder, 2)

verb mark_twice(who)
  mark(who)
  mark(who)
end

verb make_adder(n)
  return fn(x) x + n end
end

verb add_with(n, x)
  let f = make_adder(n)
  return f(x)
end
`

@(test)
test_world_filein_verbs_call_across_programs :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	base, base_ok := write_temp_source(t, "mica_filein_across_base.mica", BASE_SOURCE)
	caller, caller_ok := write_temp_source(t, "mica_filein_across_caller.mica", CALLER_SOURCE)
	if !base_ok || !caller_ok {
		return
	}
	defer os.remove(base)
	defer os.remove(caller)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := world_start(&kernel, []string{base}, runtime.heap_allocator(), World_Config{})
	testing.expectf(t, start.ok, "load failed: %s", start.message)
	if !start.ok {
		return
	}
	defer world_destroy(world)
	testing.expect_value(t, world_wait(world, world.entry).kind, Task_Outcome_Kind.Complete)
	loaded := world_filein(world, []string{caller}, "")
	testing.expectf(t, loaded.kind == .Complete, "filein failed: %s", loaded.message)

	// A verb in the new file dispatches to a verb from the first load.
	alice := world.ctx.identities["alice"]
	twice := world_call(
		world,
		"mark_twice",
		[]k.Role_Pair{{role = v.value_symbol(v.symbol_intern("who")), value = alice}},
	)
	testing.expectf(t, twice.kind == .Complete, "mark_twice failed: %s", twice.message)
	expect_relation_rows(t, &kernel, "Marker", 2)
	// A closure made in one method's program is called from another's, and
	// from an eval program.
	expect_eval_text(t, world, "return add_with(2, 3)", "5")
	expect_eval_text(t, world, "let f = make_adder(10)\nreturn f(1)", "11")
}

// Add mode matches Rust mica: filing a unit in again runs it again, and each
// verb is installed as a new method.
@(test)
test_world_filein_add_runs_a_unit_again :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	base, base_ok := write_temp_source(t, "mica_filein_again.mica", BASE_SOURCE)
	if !base_ok {
		return
	}
	defer os.remove(base)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := world_start(&kernel, []string{base}, runtime.heap_allocator(), World_Config{})
	testing.expectf(t, start.ok, "load failed: %s", start.message)
	if !start.ok {
		return
	}
	defer world_destroy(world)
	testing.expect_value(t, world_wait(world, world.entry).kind, Task_Outcome_Kind.Complete)

	again := world_filein(world, []string{base}, "")
	testing.expectf(t, again.kind == .Complete, "second filein failed: %s", again.message)
	selectors: [dynamic]v.Tuple
	defer delete(selectors)
	k.kernel_scan_into(
		&kernel,
		k.DISPATCH_METHOD_SELECTOR_ID,
		[]v.Binding{{}, v.binding_of(v.value_symbol(v.symbol_intern("mark")))},
		&selectors,
	)
	testing.expect_value(t, len(selectors), 2)
	// Identical verb bodies share one program.
	program_rows: [dynamic]v.Tuple
	defer delete(program_rows)
	k.kernel_scan_into(&kernel, k.SYSTEM_PROGRAM_BYTES_ID, []v.Binding{{}, {}}, &program_rows)
	testing.expect_value(t, len(program_rows), 1)
}

// run_files against a store that already holds a world files the given
// sources into it, in the same process, and reports their outcome.
@(test)
test_run_files_into_booted_store :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	directory, directory_error := os.temp_dir(context.temp_allocator)
	if directory_error != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	store_path, join_error := filepath.join(
		[]string{directory, "mica_run_files_booted_store"},
		context.temp_allocator,
	)
	if join_error != nil {
		return
	}
	os.remove_all(store_path)
	defer os.remove_all(store_path)
	options := Run_Options{store_path = store_path}

	sources := [3]string {
		"make_relation(:First, 1)\nassert First(1)\n",
		"make_relation(:Second, 1)\nassert Second(1)\n",
		"require false\n",
	}
	names := [3]string {
		"mica_run_files_first.mica",
		"mica_run_files_second.mica",
		"mica_run_files_failing.mica",
	}
	for source, run in sources {
		path, path_ok := write_temp_source(t, names[run], source)
		if !path_ok {
			return
		}
		defer os.remove(path)
		kernel: k.Kernel
		k.kernel_init(&kernel)
		defer k.kernel_destroy(&kernel)
		result := run_files(&kernel, []string{path}, runtime.heap_allocator(), options)
		switch run {
		case 0:
			testing.expectf(t, result.ok, "first run failed: %s", result.message)
		case 1:
			testing.expectf(t, result.ok, "second run failed: %s", result.message)
			expect_relation_rows(t, &kernel, "First", 1)
			expect_relation_rows(t, &kernel, "Second", 1)
		case 2:
			testing.expect(t, !result.ok, "a failing file into a booted store must fail")
		}
	}
}
