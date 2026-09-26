package mica_runtime

import k "../kernel"
import v "../var"
import vm "../vm"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:testing"

@(test)
test_identity_constructor_visibility_and_compilation :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world := relation_test_world(
		t,
		&kernel,
		`make_identity(:literal)
verb create(name)
  return make_identity(name)
end`,
		"identity_visibility",
	)
	if world == nil {return}
	defer world_destroy(world)
	expect_relation_eval(
		t,
		world,
		`let id = create(to_symbol("computed"))
require(NamedIdentity(id, :computed))
require(create(:computed) == id)
require(create(:distinct) != id)
require(make_identity(:literal) == #literal)`,
	)
	expect_relation_eval(t, world, `require(make_identity(:computed) == #computed)`)
	expect_relation_eval(t, world, `create(:aborted)
raise E_ABORT`, false)
	expect_relation_eval(t, world, `require(len(NamedIdentity(?id, :aborted)) == 0)`)
	expect_relation_eval(t, world, `return #aborted`, false)
	expect_relation_eval(t, world, `create(:committed)
commit()
raise E_ABORT`, false)
	expect_relation_eval(t, world, `require(NamedIdentity(#committed, :committed))`)
	expect_relation_eval(
		t,
		world,
		`let old = #computed
destroy_identity(old)
let fresh = create(:computed)
require(fresh != old)
require(NamedIdentity(fresh, :computed))`,
	)
	expect_relation_eval(t, world, `require(make_identity(:computed) == #computed)`)
	_, leaked := world.ctx.identities["computed"]
	testing.expect(t, !leaked)
}

@(test)
test_identity_constructor_validation_and_authority :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world := relation_test_world(t, &kernel, "make_identity(:existing)", "identity_authority")
	if world == nil {return}
	defer world_destroy(world)
	for source in ([]string{`make_identity()`, `make_identity(:bad, 1)`, `make_identity("bad")`, `make_identity(1)`}) {
		expect_relation_eval(t, world, source, false)
	}
	tx := k.kernel_begin(&kernel)
	defer k.transaction_destroy(&tx)
	authority := k.authority_empty()
	defer k.authority_destroy(&authority)
	state := vm.VM {
		transaction = &tx,
		authority   = &authority,
		user        = &world.env,
		allocator   = context.temp_allocator,
	}
	for name in ([]string{"denied", "existing"}) {
		_, ok := builtin_make_identity(&state, []v.Value{v.value_symbol(v.symbol_intern(name))})
		testing.expect(t, !ok)
		error, _ := v.value_as_error(state.error)
		code, _ := v.symbol_name(error.code)
		testing.expect_value(t, code, "E_PERMISSION")
	}
	state.authority = nil
	tx.read_only = true
	_, ok := builtin_make_identity(&state, []v.Value{v.value_symbol(v.symbol_intern("read_only"))})
	testing.expect(t, !ok)
	testing.expect_value(t, len(tx.writes), 0)
}

@(test)
test_identity_constructor_competing_transactions :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world := relation_test_world(t, &kernel, "", "identity_competing")
	if world == nil {return}
	defer world_destroy(world)
	left := k.kernel_begin(&kernel)
	defer k.transaction_destroy(&left)
	right := k.kernel_begin(&kernel)
	defer k.transaction_destroy(&right)
	name := v.value_symbol(v.symbol_intern("raced"))
	first, err := ensure_named_identity(&kernel, &left, name)
	testing.expect_value(t, err, k.Kernel_Error.None)
	second, other_err := ensure_named_identity(&kernel, &right, name)
	testing.expect_value(t, other_err, k.Kernel_Error.None)
	testing.expect(t, first != second)
	snapshot, committed := k.transaction_commit(&left)
	testing.expect_value(t, committed, k.Kernel_Error.None)
	k.snapshot_release(snapshot)
	loser, conflict := k.transaction_commit(&right)
	testing.expect_value(t, conflict, k.Kernel_Error.Conflict)
	if loser != nil {k.snapshot_release(loser)}
	outcome := expect_relation_eval(
		t,
		world,
		`require(len(NamedIdentity(?id, :raced)) == 1)
return make_identity(:raced)`,
	)
	testing.expect_value(t, outcome.value, first)
}

@(test)
test_identity_constructor_workers_and_recovery :: proc(t: ^testing.T) {
	// The world allocator is shared by workers. The default temporary arena
	// is not thread-safe; give this concurrent test a locked arena instead.
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) {return}
	defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)
	defer free_all(context.temp_allocator)
	directory, err := os.temp_dir(context.temp_allocator)
	if !testing.expect(t, err == nil) {return}
	store_path := fmt.aprintf(
		"%s/mica_identity_recovery",
		directory,
		allocator = context.temp_allocator,
	)
	os.remove_all(store_path)
	defer os.remove_all(store_path)
	path, ok := write_temp_source(
		t,
		"mica_identity_recovery.mica",
		`make_identity(:literal)
make_relation(:Reference, 2)
verb create(x)
  return make_identity(x)
end`,
	)
	if !ok {return}
	defer os.remove(path)
	values: [32]v.Value
	removed: v.Value
	for boot in 0 ..< 2 {
		kernel: k.Kernel
		k.kernel_init(&kernel)
		paths: []string
		if boot == 0 {paths = []string{path}}
		world, started := world_start(
			&kernel,
			paths,
			context.temp_allocator,
			World_Config{workers = 4, store_path = store_path},
		)
		if testing.expectf(t, started.ok, "boot: %s", started.message) {
			if boot == 0 {
				testing.expect_value(
					t,
					world_wait(world, world.entry).kind,
					Task_Outcome_Kind.Complete,
				)
				tasks: [32]Task_ID
				for &task, i in tasks {
					name := fmt.aprintf("Identity%d", i, allocator = context.temp_allocator)
					task = world_submit_call(
						world,
						"create",
						[]k.Role_Pair{role_x(v.value_symbol(v.symbol_intern(name)))},
					)
				}
				for task, i in tasks {
					outcome := world_wait(world, task)
					testing.expectf(t, outcome.kind == .Complete, "create: %s", outcome.message)
					values[i] = outcome.value
					for other in values[:i] {testing.expect(t, other != outcome.value)}
					world_release(world, task)
				}
				removed =
					expect_relation_eval(t, world, `let id = make_identity(:removed)
assert Reference(1, [id])
destroy_identity(id)
return id`).value
			} else {
				for value, i in values {
					outcome := expect_relation_eval(
						t,
						world,
						fmt.aprintf(
							"require(make_identity(:Identity%d) == #Identity%d)\nreturn #Identity%d",
							i,
							i,
							i,
							allocator = context.temp_allocator,
						),
					)
					testing.expect_value(t, outcome.value, value)
				}
				fresh := expect_relation_eval(t, world, `return make_identity(:after_boot)`)
				for value in values {testing.expect(t, value != fresh.value)}
				testing.expect(t, removed != fresh.value)
			}
			world_destroy(world)
		}
		k.kernel_destroy(&kernel)
	}
}

@(test)
test_identity_constructor_legacy_set_catalogue :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	// Pre-#111 stores describe NamedIdentity as a set, without a key index.
	snapshot, err := k.kernel_create_relation(
		&kernel,
		k.relation_metadata(k.SYSTEM_NAMED_IDENTITY_ID, v.symbol_intern("NamedIdentity"), 2),
	)
	testing.expect_value(t, err, k.Kernel_Error.None)
	k.snapshot_release(snapshot)
	left := k.kernel_begin(&kernel)
	defer k.transaction_destroy(&left)
	right := k.kernel_begin(&kernel)
	defer k.transaction_destroy(&right)
	name := v.value_symbol(v.symbol_intern("legacy"))
	_, a := ensure_named_identity(&kernel, &left, name)
	_, b := ensure_named_identity(&kernel, &right, name)
	testing.expect_value(t, a, k.Kernel_Error.None)
	testing.expect_value(t, b, k.Kernel_Error.None)
	winner, committed := k.transaction_commit(&left)
	testing.expect_value(t, committed, k.Kernel_Error.None)
	k.snapshot_release(winner)
	loser, conflict := k.transaction_commit(&right)
	testing.expect_value(t, conflict, k.Kernel_Error.Conflict)
	if loser != nil {k.snapshot_release(loser)}
}
