// Worlds with many verbs across units: dispatch specificity through
// delegation, mutual recursion between units, optional and rest parameters,
// closures passed between verbs, spawn, and concurrent calls. Each verb runs
// in its own program, and the second unit is filed into the running world.
package mica_runtime

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:time"
import k "../kernel"
import v "../var"

@(private = "file")
THINGS_UNIT :: `make_identity(:thing)
make_identity(:animal)
make_identity(:dog)
make_identity(:cat)
make_identity(:rex)
make_identity(:rock)
make_relation(:Heard, 2)
assert Delegates(#animal, #thing, 0)
assert Delegates(#dog, #animal, 0)
assert Delegates(#cat, #animal, 0)
assert Delegates(#rex, #dog, 0)
assert Delegates(#rock, #thing, 0)

verb describe(it @ #thing)
  return "a thing"
end

verb describe(it @ #animal)
  return "an animal"
end

verb is_even(n)
  if n == 0
    return true
  end
  return is_odd(n - 1)
end
`

@(private = "file")
BEHAVIOUR_UNIT :: `verb describe(it @ #dog)
  return "a dog"
end

verb is_odd(n)
  if n == 0
    return false
  end
  return is_even(n - 1)
end

verb shout(it, ?volume = 1, @extra)
  return [describe(it), volume, extra]
end

verb make_adder(n)
  return fn(x) => x + n
end

verb apply(f, x)
  return f(x)
end

verb note(who, what)
  assert Heard(who, what)
end

verb notify_later(who)
  spawn :note(who: who, what: :spawned)
end
`

@(private = "file")
Units :: struct {
	things:    string,
	behaviour: string,
}

@(private = "file")
write_units :: proc(t: ^testing.T, tag: string) -> (Units, bool) {
	// Tests run in parallel, so each gets its own file names. The unit name is
	// the base name, so each test has its own units.
	things, things_ok := write_temp_source(t, fmt.tprintf("mica_mv_%s_things.mica", tag), THINGS_UNIT)
	behaviour, behaviour_ok := write_temp_source(t, fmt.tprintf("mica_mv_%s_behaviour.mica", tag), BEHAVIOUR_UNIT)
	return Units{things = things, behaviour = behaviour}, things_ok && behaviour_ok
}

@(private = "file")
expect_eval :: proc(t: ^testing.T, world: ^World, source: string, expected: string, loc := #caller_location) {
	outcome := world_eval(world, source)
	testing.expectf(t, outcome.kind == .Complete, "%s failed: %s", source, outcome.message, loc = loc)
	if outcome.kind == .Complete {
		text := world_value_literal(world, outcome.value)
		testing.expectf(t, text == expected, "%s: expected %s, got %s", source, expected, text, loc = loc)
	}
}

// The behaviour every world in this file must show, whether it was loaded,
// filed into, or booted from a store.
@(private = "file")
expect_multiverb_behaviour :: proc(t: ^testing.T, world: ^World, loc := #caller_location) {
	// The most specific method wins, across units and through delegation.
	expect_eval(
		t,
		world,
		"return [describe(#rex), describe(#cat), describe(#rock)]",
		`["a dog", "an animal", "a thing"]`,
		loc,
	)
	// Mutual recursion between verbs of different units.
	expect_eval(t, world, "return [is_even(10), is_odd(7), is_even(3)]", "[true, true, false]", loc)
	// Optional and rest parameters on a verb reached by dispatch.
	expect_eval(t, world, "return shout(#rex)", `["a dog", 1, []]`, loc)
	expect_eval(t, world, "return shout(#cat, 3, :a, :b)", `["an animal", 3, [:a, :b]]`, loc)
	// A closure made in one verb, called by another verb and by eval code.
	expect_eval(t, world, "return apply(make_adder(5), 2)", "7", loc)
	expect_eval(t, world, "let add = make_adder(10)\nreturn add(1)", "11", loc)
}

@(test)
test_world_multiverb_across_units :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	units, ok := write_units(t, "memory")
	if !ok {
		return
	}
	defer os.remove(units.things)
	defer os.remove(units.behaviour)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := world_start(&kernel, []string{units.things}, runtime.heap_allocator(), World_Config{workers = 4})
	testing.expectf(t, start.ok, "load failed: %s", start.message)
	if !start.ok {
		return
	}
	defer world_destroy(world)
	testing.expect_value(t, world_wait(world, world.entry).kind, Task_Outcome_Kind.Complete)
	filed := world_filein(world, []string{units.behaviour}, "")
	testing.expectf(t, filed.kind == .Complete, "filein failed: %s", filed.message)

	expect_multiverb_behaviour(t, world)

	// A verb spawns a task that dispatches to another verb.
	rex := world.ctx.identities["rex"]
	spawned := world_call(
		world,
		"notify_later",
		[]k.Role_Pair{{role = v.value_symbol(v.symbol_intern("who")), value = rex}},
	)
	testing.expectf(t, spawned.kind == .Complete, "notify_later failed: %s", spawned.message)
	deadline := time.tick_now()
	for time.tick_since(deadline) < 2 * time.Second {
		if world_eval(world, "return Heard(#rex, :spawned)").value == v.value_bool(true) {
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	expect_eval(t, world, "return Heard(#rex, :spawned)", "true")
}


@(test)
test_world_multiverb_survives_reboot :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	units, ok := write_units(t, "store")
	if !ok {
		return
	}
	defer os.remove(units.things)
	defer os.remove(units.behaviour)
	directory, directory_error := os.temp_dir(context.temp_allocator)
	if directory_error != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	store_path, join_error := filepath.join([]string{directory, "mica_multiverb_store"}, context.temp_allocator)
	if join_error != nil {
		return
	}
	os.remove_all(store_path)
	defer os.remove_all(store_path)

	// Load the first unit, then file the second into the booted store.
	for step in 0 ..< 2 {
		kernel: k.Kernel
		k.kernel_init(&kernel)
		paths := []string{units.things} if step == 0 else nil
		world, start := world_start(&kernel, paths, runtime.heap_allocator(), World_Config{store_path = store_path})
		testing.expectf(t, start.ok, "start %d failed: %s", step, start.message)
		if start.ok {
			if step == 0 {
				testing.expect_value(t, world_wait(world, world.entry).kind, Task_Outcome_Kind.Complete)
			} else {
				filed := world_filein(world, []string{units.behaviour}, "")
				testing.expectf(t, filed.kind == .Complete, "filein failed: %s", filed.message)
			}
			testing.expect(t, world_checkpoint(world))
			world_destroy(world)
		}
		k.kernel_destroy(&kernel)
	}

	// Boot again: every verb from both units dispatches as before.
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := world_start(&kernel, nil, runtime.heap_allocator(), World_Config{store_path = store_path})
	testing.expectf(t, start.ok, "reboot failed: %s", start.message)
	if !start.ok {
		return
	}
	defer world_destroy(world)
	expect_multiverb_behaviour(t, world)
}
