package mica_runtime

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:testing"
import k "../kernel"
import v "../var"
import vm "../vm"

@(private)
relation_test_world :: proc(t: ^testing.T, kernel: ^k.Kernel, source, suffix: string, workers := 1) -> ^World {
	path, ok := write_temp_source(t, fmt.aprintf("mica_relation_constructor_%s.mica", suffix, allocator = context.temp_allocator), source)
	if !ok {return nil}
	defer os.remove(path)
	world, result := world_start(kernel, []string{path}, context.temp_allocator, World_Config{workers = workers})
	if !testing.expectf(t, result.ok, "world start failed: %s", result.message) {return nil}
	outcome := world_wait(world, world.entry)
	if !testing.expectf(t, outcome.kind == .Complete, "entry failed: %s", outcome.message) {
		world_destroy(world)
		return nil
	}
	return world
}

@(private)
expect_relation_eval :: proc(
	t: ^testing.T,
	world: ^World,
	source: string,
	success := true,
) -> Task_Outcome {
	outcome := world_eval(world, source, context.temp_allocator)
	testing.expectf(
		t,
		(outcome.kind == .Complete) == success,
		"eval: %s\noutcome: %v %s %s",
		source,
		outcome.kind,
		outcome.message,
		v.value_to_string(outcome.error, context.temp_allocator),
	)
	return outcome
}

@(test)
test_relation_constructor_computed_verb_and_later_compilation :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world := relation_test_world(t, &kernel, `verb create(name, width, keys, life)
  return make_functional_relation(name, width, keys, life)
end`, "computed")
	if world == nil {return}
	defer world_destroy(world)
	before := k.kernel_snapshot(&kernel)
	_, existed := k.snapshot_relation_metadata_named(before, v.symbol_intern("Generated"))
	testing.expect(t, !existed)
	k.snapshot_release(before)
	expect_relation_eval(t, world, `let name = to_symbol("Generated")
let id = create(name, 1 + 1, [0], :volatile)
require(RelationName(id, name))
require(Arity(id, 2))
require(ConflictPolicy(id, :functional))
require(FunctionalKey(id, 0, 0))
require(RelationDurability(id, :volatile))
require(make_functional_relation(name, 2, [0], :volatile) == id)
__relation_assert(name, [:key, :value] { [1, 10] })
require(__get_field(1, :generated) == 10)
__set_field(1, :generated, 20)
require(__get_field(1, :generated) == 20)
try
  __relation_assert(name, [:key, :value] { [1, 30] })
  raise E_NOT_REJECTED
catch E_WRITE
end
return id`)
	// No worker updated the shared compiler maps. Compilation gets its own
	// committed catalogue view, and runtime field lookup sees the same entry.
	_, leaked := world.ctx.relations["Generated"]
	testing.expect(t, !leaked)
	expect_relation_eval(t, world, `require(Generated(1, 20))
require(1.generated == 20)
assert Generated(2, 30)
require(Generated(2, 30))`)
	// Literal zero-column declarations and an empty functional key are valid.
	expect_relation_eval(t, world, `let name = :Flag
let id = make_relation(name, 0)
require(Arity(id, 0))
require(make_relation(name, 0, :durable) == id)`)
	expect_relation_eval(t, world, `assert Flag()
require(Flag())`)
}

@(test)
test_relation_constructor_abort_and_commit_visibility :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world := relation_test_world(t, &kernel, "", "abort")
	if world == nil {return}
	defer world_destroy(world)
	expect_relation_eval(t, world, `let name = :Aborted
let id = make_relation(name, 1)
require(RelationName(id, name))
__relation_assert(name, [:x] { [7] })
raise E_ABORT`, false)
	expect_relation_eval(t, world, `require(len(RelationName(?id, :Aborted)) == 0)`)
	snapshot := k.kernel_snapshot(&kernel)
	_, found := k.snapshot_relation_metadata_named(snapshot, v.symbol_intern("Aborted"))
	testing.expect(t, !found)
	k.snapshot_release(snapshot)
	_, leaked := world.ctx.relations["Aborted"]
	testing.expect(t, !leaked)
	expect_relation_eval(t, world, `assert Aborted(1)`, false)
	expect_relation_eval(t, world, `make_relation(:Committed, 1)
commit()
raise E_ABORT`, false)
	expect_relation_eval(t, world, `assert Committed(8)
require(Committed(8))`)
}

@(test)
test_relation_constructor_argument_validation :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world := relation_test_world(t, &kernel, "", "arguments")
	if world == nil {return}
	defer world_destroy(world)
	cases := []string{
		`make_relation()`, `make_relation(:Bad)`, `make_relation(:Bad, 1, :durable, 4)`,
		`make_relation("Bad", 1)`, `make_relation(:Bad, true)`,
		`make_relation(:Bad, -1)`, `make_relation(:Bad, 65536)`,
		`make_relation(:Bad, 1, :typo)`, `make_relation(:Bad, 1, 7)`,
		`make_functional_relation(:Bad, 2)`, `make_functional_relation(:Bad, 2, 0)`,
		`make_functional_relation(:Bad, 2, [true])`, `make_functional_relation(:Bad, 2, [-1])`,
		`make_functional_relation(:Bad, 2, [2])`, `make_functional_relation(:Bad, 2, [65536])`,
		`make_functional_relation(:Bad, 2, [0, 0])`,
	}
	for source in cases {
		expect_relation_eval(t, world, source, false)
	}
	expect_relation_eval(t, world, `require(len(RelationName(?id, :Bad)) == 0)
make_relation(:Existing, 2)
make_functional_relation(:Keyed, 2, [0])`)
	for source in ([]string{
		`make_relation(:Existing, 3)`, `make_relation(:Existing, 2, :volatile)`,
		`make_functional_relation(:Existing, 2, [0])`, `make_relation(:Keyed, 2)`,
		`make_functional_relation(:Keyed, 2, [1])`,
	}) {expect_relation_eval(t, world, source, false)}
	expect_relation_eval(t, world, `make_functional_relation(:Singleton, 1, [])
__relation_assert(:Singleton, [:x] { [1] })
try
  __relation_assert(:Singleton, [:x] { [2] })
  raise E_NOT_REJECTED
catch E_WRITE
end`)
}

@(test)
test_relation_constructor_authority_and_read_only :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world := relation_test_world(t, &kernel, "make_relation(:Existing, 1)", "authority")
	if world == nil {return}
	defer world_destroy(world)
	tx := k.kernel_begin(&kernel)
	defer k.transaction_destroy(&tx)
	authority := k.authority_empty()
	defer k.authority_destroy(&authority)
	state := vm.VM{transaction = &tx, authority = &authority, user = &world.env, allocator = context.temp_allocator}
	for name in ([]string{"Denied", "Existing"}) {
		_, ok := builtin_make_relation(&state, []v.Value{v.value_symbol(v.symbol_intern(name)), value_int_must(1)})
		testing.expect(t, !ok)
		error, _ := v.value_as_error(state.error)
		code, _ := v.symbol_name(error.code)
		testing.expect_value(t, code, "E_PERMISSION")
	}
	state.authority = nil
	tx.read_only = true
	_, ok := builtin_make_relation(&state, []v.Value{v.value_symbol(v.symbol_intern("ReadOnly")), value_int_must(1)})
	testing.expect(t, !ok)
	testing.expect_value(t, len(tx.catalog_changes), 0)
	testing.expect_value(t, len(tx.writes), 0)
}

@(test)
test_relation_constructor_concurrent_creation :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world := relation_test_world(t, &kernel, "", "concurrent")
	if world == nil {return}
	defer world_destroy(world)
	left := k.kernel_begin(&kernel)
	defer k.transaction_destroy(&left)
	right := k.kernel_begin(&kernel)
	defer k.transaction_destroy(&right)
	args := []v.Value{v.value_symbol(v.symbol_intern("Raced")), value_int_must(1)}
	a := vm.VM{transaction = &left, user = &world.env, allocator = context.temp_allocator}
	b := vm.VM{transaction = &right, user = &world.env, allocator = context.temp_allocator}
	first, ok := builtin_make_relation(&a, args)
	testing.expect(t, ok)
	_, visible := k.transaction_relation_metadata_named(&right, v.symbol_intern("Raced"))
	testing.expect(t, !visible)
	second, second_ok := builtin_make_relation(&b, args)
	testing.expect(t, second_ok)
	testing.expect(t, first != second)
	snapshot, err := k.transaction_commit(&left)
	testing.expect_value(t, err, k.Kernel_Error.None)
	k.snapshot_release(snapshot)
	loser, loser_err := k.transaction_commit(&right)
	testing.expect_value(t, loser_err, k.Kernel_Error.Conflict)
	if loser != nil {k.snapshot_release(loser)}
	result := expect_relation_eval(t, world, `require(len(RelationName(?id, :Raced)) == 1)
return make_relation(:Raced, 1)`)
	testing.expect_value(t, result.value, first)
	rows: [dynamic]v.Tuple
	defer delete(rows)
	snapshot = k.kernel_snapshot(&kernel)
	defer k.snapshot_release(snapshot)
	source := k.Relation_Source{snapshot = snapshot}
	k.relation_source_scan_into(&source, k.SYSTEM_RELATION_ID, []v.Binding{v.binding_of(second)}, &rows)
	testing.expect_value(t, len(rows), 0)
}

@(test)
test_relation_constructor_prescan_validation :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for source, i in ([]string{
		"make_relation(:Bad, 65536)",
		"make_relation(:Bad, -1)",
		"make_relation(:Bad, 1, :typo)",
		"make_functional_relation(:Bad, 2, [65536])",
		"make_functional_relation(:Bad, 2, [0, 0])",
		"make_relation(:Bad, 1)\nmake_relation(:Bad, 2)",
		"make_relation(:Bad, 1)\nmake_functional_relation(:Bad, 1, [0])",
	}) {
		kernel: k.Kernel
		k.kernel_init(&kernel)
		path, ok := write_temp_source(t, fmt.aprintf("mica_bad_declaration_%d.mica", i, allocator = context.temp_allocator), source)
		if !ok {k.kernel_destroy(&kernel); continue}
		result := run_files(&kernel, []string{path}, context.temp_allocator)
		testing.expectf(t, !result.ok, "invalid declaration succeeded: %s", source)
		snapshot := k.kernel_snapshot(&kernel)
		_, found := k.snapshot_relation_metadata_named(snapshot, v.symbol_intern("Bad"))
		testing.expect(t, !found)
		k.snapshot_release(snapshot)
		os.remove(path)
		k.kernel_destroy(&kernel)
	}
	// Literal declarations return identities when their calls execute.
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world := relation_test_world(t, &kernel, `let id = make_relation(:Zero, 0)
require(RelationName(id, :Zero))
make_relation(:Zero, 0)
assert Zero()
require(Zero())
let quoted = make_relation(:"quoted\nname", 1)
require(RelationName(quoted, to_symbol("quoted\nname")))`, "literal")
	if world != nil {world_destroy(world)}
}

@(test)
test_relation_constructor_store_recovery :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	directory, err := os.temp_dir(context.temp_allocator)
	if !testing.expect(t, err == nil) {return}
	store_path := fmt.aprintf("%s/mica_relation_constructor_recovery", directory, allocator = context.temp_allocator)
	os.remove_all(store_path)
	defer os.remove_all(store_path)
	path, ok := write_temp_source(t, "mica_relation_constructor_recovery.mica", "")
	if !ok {return}
	defer os.remove(path)
	identity: v.Value
	for boot in 0..<2 {
		kernel: k.Kernel
		k.kernel_init(&kernel)
		paths: []string
		if boot == 0 {paths = []string{path}}
		world, start := world_start(&kernel, paths, context.temp_allocator, World_Config{store_path = store_path})
		if testing.expectf(t, start.ok, "boot %d: %s", boot, start.message) {
			if boot == 0 {
				entry := world_wait(world, world.entry)
				testing.expect_value(t, entry.kind, Task_Outcome_Kind.Complete)
				result := expect_relation_eval(t, world, `let id = make_functional_relation(:Persistent, 2, [0])
make_relation(:Transient, 1, :volatile)
__relation_assert(:Persistent, [:key, :value] { [1, 2] })
__relation_assert(:Transient, [:value] { [3] })
return id`)
				identity = result.value
			} else {
				result := expect_relation_eval(t, world, `require(Persistent(1, 2))
require(1.persistent == 2)
require(len(Transient(?value)) == 0)
require(len(RelationName(?id, :Transient)) == 1)
return make_functional_relation(:Persistent, 2, [0])`)
				testing.expect_value(t, result.value, identity)
				expect_relation_eval(t, world, `make_functional_relation(:Persistent, 2, [1])`, false)
			}
			world_destroy(world)
		}
		k.kernel_destroy(&kernel)
	}
}

@(test)
test_relation_constructor_multiple_workers :: proc(t: ^testing.T) {
	// The world allocator is shared by workers. The default temporary arena
	// is not thread-safe; give this concurrent test a locked arena instead.
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) {return}
	defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)
	defer free_all(context.temp_allocator)
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world := relation_test_world(t, &kernel, `verb create(x)
  let id = make_functional_relation(x, 2, [0])
  __relation_assert(x, [:key, :value] { [1, 2] })
  require(__get_field(1, x) == 2)
  return id
end`, "workers", 4)
	if world == nil {return}
	defer world_destroy(world)
	ids: [32]Task_ID
	for &id, i in ids {
		name := fmt.aprintf("Concurrent%d", i, allocator = context.temp_allocator)
		id = world_submit_call(world, "create", []k.Role_Pair{role_x(v.value_symbol(v.symbol_intern(name)))})
		testing.expect(t, id != 0)
	}
	for id in ids {
		outcome := world_wait(world, id)
		testing.expectf(t, outcome.kind == .Complete, "creation failed: %s", outcome.message)
		world_release(world, id)
	}
	for i in 0..<len(ids) {
		expect_relation_eval(t, world, fmt.aprintf("require(Concurrent%d(1, 2))", i, allocator = context.temp_allocator))
	}
}
