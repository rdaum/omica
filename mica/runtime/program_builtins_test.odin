package mica_runtime

import k "../kernel"
import v "../var"
import vm "../vm"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:testing"
import "core:time"

@(test)
test_program_install_dispatch_and_rollback :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world := relation_test_world(
		t,
		&kernel,
		`verb original(x)
  return x + 1
end`,
		"program_install",
	)
	if world == nil {return}
	defer world_destroy(world)
	expect_relation_eval(
		t,
		world,
		`let artifact = install_source("verb added(x)\n return original(x) + 1\nend")
require(len(ProgramBytes(artifact, ?bytes)) == 1)
require(added(40) == 42)
return added(1)`,
	)
	expect_relation_eval(
		t,
		world,
		`require(added(40) == 42)
require(original(40) == 41)
compile("return 1")`,
	)
	expect_relation_eval(
		t,
		world,
		`install_source("verb aborted()\n return 7\nend")
raise E_ABORT`,
		false,
	)
	expect_relation_eval(t, world, `aborted()`, false)
	expect_relation_eval(
		t,
		world,
		`try
 install_source("make_identity(:partial)\nmake_relation(:Partial, 1)\nverb bad()\n return #missing\nend")
 raise E_NOT_REJECTED
catch E_COMPILE
end
require(len(NamedIdentity(?id, :partial)) == 0)
require(len(RelationName(?id, :Partial)) == 0)`,
	)
}

@(test)
test_program_install_replacement_pins_frames_and_callables :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world := relation_test_world(t, &kernel, `verb apply(f)
  return f()
end`, "program_pins")
	if world == nil {return}
	defer world_destroy(world)
	expect_relation_eval(
		t,
		world,
		`install_source("verb helper()\n return 41\nend\nverb paused()\n read()\n return helper()\nend")`,
	)
	old := world_submit_call(world, "paused", nil)
	parked := false
	for _ in 0 ..< 1000 {
		if _, waiting := world_task_request(world, old); waiting {parked = true; break}
		time.sleep(time.Millisecond)
	}
	if !testing.expect(t, parked) {return}
	expect_relation_eval(
		t,
		world,
		`install_source("verb helper()\n return 42\nend\nverb paused()\n return helper()\nend")
require(helper() == 42)
require(paused() == 42)`,
	)
	testing.expect(t, world_resume(world, old, v.value_empty_relation()))
	outcome := world_wait(world, old)
	testing.expect_value(t, outcome.kind, Task_Outcome_Kind.Complete)
	testing.expect_value(t, outcome.value, value_int_must(41))
	world_release(world, old)
	callable := expect_relation_eval(
		t,
		world,
		`let text = "survives producing task"
return fn() => text`,
	)
	applied := world_call(
		world,
		"apply",
		[]k.Role_Pair{{role = v.value_symbol(v.symbol_intern("f")), value = callable.value}},
	)
	testing.expectf(t, applied.kind == .Complete, "callable failed: %s", applied.message)
	text, ok := v.value_as_string(applied.value)
	testing.expect(t, ok)
	testing.expect_value(t, text, "survives producing task")
	for _ in 0 ..< 10 {expect_relation_eval(t, world, `require(helper() == 42)`)}
	// Bootstrap + current installed image + escaped callable's image.
	testing.expect_value(t, len(world.programs.serials), 3)
}

@(test)
test_program_install_authority_and_concurrent_replacement :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world := relation_test_world(t, &kernel, "", "program_authority")
	if world == nil {return}
	defer world_destroy(world)
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
	before := k.kernel_snapshot(&kernel)
	version := before.version
	k.snapshot_release(before)
	_, installed := builtin_install_source(
		&state,
		[]v.Value {
			v.value_string(
				context.temp_allocator,
				"make_identity(:denied)\nverb denied()\n return 1\nend",
			),
		},
	)
	testing.expect(t, !installed)
	testing.expect_value(t, len(tx.writes), 0)
	testing.expect_value(t, len(tx.catalog_changes), 0)
	after := k.kernel_snapshot(&kernel)
	testing.expect_value(t, after.version, version)
	k.snapshot_release(after)
	// Two source installations based on the same snapshot may not create
	// ambiguous duplicate signatures, even when both initially see no method.
	left := k.kernel_begin(&kernel)
	defer k.transaction_destroy(&left)
	right := k.kernel_begin(&kernel)
	defer k.transaction_destroy(&right)
	left.source_install = true
	right.source_install = true
	key := v.value_symbol(v.symbol_intern("parallel"))
	for tx in ([]^k.Transaction{&left, &right}) {
		identity, _ := k.kernel_reserve_identity(&kernel)
		testing.expect_value(
			t,
			k.transaction_assert(
				tx,
				k.DISPATCH_METHOD_SELECTOR_ID,
				v.tuple_new(context.temp_allocator, []v.Value{identity, key}),
			),
			k.Kernel_Error.None,
		)
	}
	snapshot, err := k.transaction_commit(&left)
	testing.expect_value(t, err, k.Kernel_Error.None)
	k.snapshot_release(snapshot)
	loser, conflict := k.transaction_commit(&right)
	testing.expect_value(t, conflict, k.Kernel_Error.Conflict)
	if loser != nil {k.snapshot_release(loser)}
}

@(test)
test_program_install_rules_and_recovery :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	directory, err := os.temp_dir(context.temp_allocator)
	if !testing.expect(t, err == nil) {return}
	store_path := fmt.aprintf(
		"%s/mica_program_recovery",
		directory,
		allocator = context.temp_allocator,
	)
	os.remove_all(store_path)
	defer os.remove_all(store_path)
	path, ok := write_temp_source(t, "mica_program_recovery.mica", "")
	if !ok {return}
	defer os.remove(path)
	for boot in 0 ..< 2 {
		kernel: k.Kernel
		k.kernel_init(&kernel)
		paths: []string
		if boot == 0 {paths = []string{path}}
		world, started := world_start(
			&kernel,
			paths,
			context.temp_allocator,
			World_Config{store_path = store_path},
		)
		if testing.expectf(t, started.ok, "boot: %s", started.message) {
			if boot == 0 {
				world_wait(world, world.entry)
				expect_relation_eval(
					t,
					world,
					`install_source("make_relation(:Base, 1)\nmake_relation(:Derived, 1)\nDerived(x) :- Base(x)\nverb one()\n return 1\nend")
install_source("verb two()\n return one(@[]) + 1\nend")`,
				)
				expect_relation_eval(
					t,
					world,
					`assert Base(9)
require(Derived(9))
require(two() == 2)`,
				)
			} else {
				expect_relation_eval(
					t,
					world,
					`require(Derived(9))
require(one() == 1)
require(two() == 2)`,
				)
			}
			world_destroy(world)
		}
		k.kernel_destroy(&kernel)
	}
}

@(test)
test_program_cross_image_handlers_defaults_splice_and_spawn :: proc(t: ^testing.T) {
	// Parent and spawned child can allocate concurrently.
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) {return}
	defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)
	defer free_all(context.temp_allocator)
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world := relation_test_world(t, &kernel, "", "program_cross_image", 2)
	if world == nil {return}
	defer world_destroy(world)
	expect_relation_eval(
		t,
		world,
		`install_source("verb fail()\n raise E_RANGE\nend\nverb add(x, ?y = 2)\n return x + y\nend\nverb child(sender)\n mailbox_send(sender, 42)\nend\nverb launch(sender)\n spawn :child(sender: sender)\nend")`,
	)
	expect_relation_eval(
		t,
		world,
		`try
 fail()
 raise E_NOT_REJECTED
catch E_RANGE
end
require(add(40) == 42)
let f = fn(x) => add(x)
require(f(@[40]) == 42)
let pair = mailbox()
launch(pair[1])
let received = mailbox_recv([pair[0]], 2000)
require(received[0][1][0] == 42)`,
	)
	for bad in ([]string{`install_source("make_identity()")`, `install_source("make_identity(7)")`, `install_source("return 1")`}) {
		expect_relation_eval(t, world, bad, false)
	}
}

@(test)
test_program_legacy_store_reference_upgrade :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	directory, err := os.temp_dir(context.temp_allocator)
	if !testing.expect(t, err == nil) {return}
	store_path := fmt.aprintf(
		"%s/mica_program_legacy_recovery",
		directory,
		allocator = context.temp_allocator,
	)
	os.remove_all(store_path)
	defer os.remove_all(store_path)
	path, ok := write_temp_source(
		t,
		"mica_program_legacy_recovery.mica",
		"verb legacy()\n return 41\nend",
	)
	if !ok {return}
	defer os.remove(path)
	for boot in 0 ..< 3 {
		kernel: k.Kernel
		k.kernel_init(&kernel)
		paths: []string
		if boot == 0 {paths = []string{path}}
		world, started := world_start(
			&kernel,
			paths,
			context.temp_allocator,
			World_Config{store_path = store_path},
		)
		if testing.expectf(t, started.ok, "boot: %s", started.message) {
			if boot == 0 {
				world_wait(world, world.entry)
				tx := k.kernel_begin(&kernel)
				source := k.Relation_Source {
					transaction = &tx,
				}
				rows: [dynamic]v.Tuple
				k.relation_source_scan_into(
					&source,
					k.DISPATCH_METHOD_PROGRAM_ID,
					[]v.Binding{{}, {}},
					&rows,
				)
				for row in rows {
					values := v.tuple_values(row)
					reference, _ := v.value_as_list(values[1])
					testing.expect_value(
						t,
						k.transaction_retract(&tx, k.DISPATCH_METHOD_PROGRAM_ID, row),
						k.Kernel_Error.None,
					)
					testing.expect_value(
						t,
						k.transaction_assert(
							&tx,
							k.DISPATCH_METHOD_PROGRAM_ID,
							v.tuple_new(
								context.temp_allocator,
								[]v.Value{values[0], reference[1]},
							),
						),
						k.Kernel_Error.None,
					)
				}
				snapshot, committed := k.transaction_commit(&tx)
				testing.expect_value(t, committed, k.Kernel_Error.None)
				k.snapshot_release(snapshot)
				k.transaction_destroy(&tx)
				delete(rows)
			} else {
				expect_relation_eval(t, world, `require(legacy() == 41)`)
				if boot ==
				   1 {expect_relation_eval(t, world, `install_source("verb new()\n return legacy() + 1\nend")`)}
				expect_relation_eval(t, world, `require(new() == 42)`)
			}
			world_destroy(world)
		}
		k.kernel_destroy(&kernel)
	}
}

@(test)
test_program_historical_decode_does_not_retain_replaced_image :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world := relation_test_world(t, &kernel, "", "program_historical")
	if world == nil {return}
	defer world_destroy(world)
	first := expect_relation_eval(
		t,
		world,
		`return install_source("verb version()\n return 1\nend")`,
	)
	old := k.kernel_snapshot(&kernel)
	defer k.snapshot_release(old)
	second := expect_relation_eval(
		t,
		world,
		`return install_source("verb version()\n return 2\nend")`,
	)
	source := k.Relation_Source {
		snapshot = old,
	}
	vm.program_registry_refresh(&world.programs, &source)
	current, exists := world.programs.artifacts[second.value]
	testing.expect(t, exists && current.installed)
	_, retained := world.programs.artifacts[first.value]
	testing.expect(t, !retained)
	historical := vm.program_registry_resolve(&world.programs, &source, first.value)
	if testing.expect(t, historical != nil) {
		testing.expect(t, !historical.installed)
		vm.program_release(historical)
		_, leaked := world.programs.artifacts[first.value]
		testing.expect(t, !leaked)
	}
}

@(test)
test_program_named_splice_dispatch :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world := relation_test_world(t, &kernel, "", "program_named_splice")
	if world == nil {return}
	defer world_destroy(world)
	expect_relation_eval(
		t,
		world,
		`install_source("verb sum3(x, y, ?z = 3)\n return x + y + z\nend")`,
	)
	expect_relation_eval(
		t,
		world,
		`require(sum3(@[1, 2, 3]) == 6)
require(sum3(1, @[2]) == 6)
require(sum3(@[], 1, @[2, 4]) == 7)
try
 sum3(@[1])
 raise E_NOT_REJECTED
catch E_DISPATCH
end
try
 missing_verb(@[])
 raise E_NOT_REJECTED
catch E_DISPATCH
end
try
 sum3(@42)
 raise E_NOT_REJECTED
catch E_TYPE
end`,
	)
	// Both the outer compiler and compile(source)'s artifact path must accept
	// a named splice whose target was installed in another program.
	compiled := expect_relation_eval(t, world, `return compile("return sum3(@[1, 2, 3])")`)
	bytes, ok := v.value_as_bytes(compiled.value)
	if !testing.expect(t, ok) {return}
	decoded, err := vm.program_from_bytes(bytes, context.temp_allocator)
	testing.expect_value(t, err, vm.Artifact_Error.None)
	if decoded !=
	   nil {testing.expect_value(t, vm.program_validate(decoded), vm.Program_Error.None)}
}

@(test)
test_program_splice_dispatch_restrictions_and_authority :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world := relation_test_world(
		t,
		&kernel,
		`verb kind(x @ #integer)
 return :number
end
verb kind(x @ #string)
 return :text
end
verb count(x, @rest)
 return x + len(rest)
end
require(kind(@[1]) == :number)
require(kind(@["hello"]) == :text)
require(count(40, @[1, 2]) == 42)
try
 kind(@[true])
 raise E_NOT_REJECTED
catch E_DISPATCH
end`,
		"splice_restrictions",
	)
	if world == nil {return}
	defer world_destroy(world)
	for allowed in ([]bool{false, true}) {
		tx := k.kernel_begin(&kernel)
		program, message := runtime_compile(world, &tx, "return kind(@[1])", false)
		k.transaction_destroy(&tx)
		if !testing.expectf(t, program != nil, "compile: %s", message) {return}
		task: Task
		task_init(&task, 0, &kernel, program, &world.env, context.temp_allocator)
		vm.program_release(program)
		authority := k.authority_empty(context.temp_allocator)
		authority.read_all = true
		if allowed {authority.selectors[v.symbol_intern("kind")] = true}
		task_set_authority(&task, authority)
		result := task_run(&task)
		if allowed {
			testing.expect_value(t, result.kind, Task_Outcome_Kind.Complete)
			testing.expect_value(t, result.value, v.value_symbol(v.symbol_intern("number")))
		} else {
			testing.expect_value(t, result.kind, Task_Outcome_Kind.Aborted)
			error, ok := v.value_as_error(result.error)
			if testing.expect(
				t,
				ok,
			) {testing.expect_value(t, error.code, v.symbol_intern("E_PERMISSION"))}
		}
		task_destroy(&task)
	}
}
