package vm

import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import "core:time"
import k "../kernel"
import v "../var"

@(private)
test_arena :: proc() -> ^virtual.Arena {
	arena := new(virtual.Arena)
	if err := virtual.arena_init_growing(arena); err != nil {
		panic("failed to initialize vm test arena")
	}
	return arena
}

@(private)
test_arena_destroy :: proc(arena: ^virtual.Arena) {
	virtual.arena_destroy(arena)
	free(arena)
}

@(private)
must_int :: proc(n: i64) -> v.Value {
	value, ok := v.value_int(n)
	assert(ok)
	return value
}

@(private)
must_float :: proc(f: f32) -> v.Value {
	value, ok := v.value_float(f)
	assert(ok)
	return value
}

@(private)
constant :: proc(builder: ^Builder, n: i64) -> i32 {
	return i32(builder_add_constant(builder, must_int(n)))
}

@(private)
float_constant :: proc(builder: ^Builder, f: f32) -> i32 {
	return i32(builder_add_constant(builder, must_float(f)))
}

@(test)
test_vm_arithmetic_and_return :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	two := constant(&builder, 2)
	three := constant(&builder, 3)
	builder_begin_function(&builder, v.symbol_intern("main"), 0, 4, true)
	builder_emit(&builder, .Load_Const, 0, 0, two, 0)
	builder_emit(&builder, .Load_Const, 0, 1, three, 0)
	builder_emit(&builder, .Binary, u8(Bin_Op.Add), 2, 0, 1)
	builder_emit(&builder, .Return, 0, 2, 0, 0)
	builder_end_function(&builder)

	program := builder_build(&builder, alloc)
	testing.expect_value(t, program_validate(program), Program_Error.None)

	state: VM
	vm_init(&state, program, alloc)
	defer vm_destroy(&state)

	testing.expect_value(t, vm_run(&state), VM_Status.Halted)
	testing.expect_value(t, state.result, must_int(5))

	// A halted VM refuses to run again until reset; after reset it runs the
	// same program and produces the same result, reusing its buffers.
	testing.expect_value(t, vm_run(&state), VM_Status.Halted)
	vm_reset(&state)
	testing.expect_value(t, vm_run(&state), VM_Status.Halted)
	testing.expect_value(t, state.result, must_int(5))
}

@(test)
test_vm_reset_restores_instruction_budget :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	two := constant(&builder, 2)
	three := constant(&builder, 3)
	builder_begin_function(&builder, v.symbol_intern("main"), 0, 4, true)
	builder_emit(&builder, .Load_Const, 0, 0, two, 0)
	builder_emit(&builder, .Load_Const, 0, 1, three, 0)
	builder_emit(&builder, .Binary, u8(Bin_Op.Add), 2, 0, 1)
	builder_emit(&builder, .Return, 0, 2, 0, 0)
	builder_end_function(&builder)
	program := builder_build(&builder, alloc)

	state: VM
	vm_init(&state, program, alloc)
	defer vm_destroy(&state)
	// Budget is consumed down to zero by the run; reset must restore the
	// configured value rather than leaving zero, which means unlimited.
	vm_set_instruction_budget(&state, 8)
	testing.expect_value(t, vm_run(&state), VM_Status.Halted)
	vm_reset(&state)
	testing.expect_value(t, state.instruction_budget, u64(8))
	testing.expect_value(t, vm_run(&state), VM_Status.Halted)
	testing.expect_value(t, state.result, must_int(5))
}

@(test)
test_vm_branch_selects_value :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	one := constant(&builder, 1)
	two := constant(&builder, 2)
	ten := constant(&builder, 10)
	twenty := constant(&builder, 20)

	builder_begin_function(&builder, v.symbol_intern("main"), 0, 4, true)
	builder_emit(&builder, .Load_Const, 0, 0, one, 0)
	builder_emit(&builder, .Load_Const, 0, 1, two, 0)
	builder_emit(&builder, .Binary, u8(Bin_Op.Lt), 2, 0, 1)
	builder_emit(&builder, .Branch, 0, 2, 2, 0)
	builder_emit(&builder, .Load_Const, 0, 3, twenty, 0)
	builder_emit(&builder, .Return, 0, 3, 0, 0)
	builder_emit(&builder, .Load_Const, 0, 3, ten, 0)
	builder_emit(&builder, .Return, 0, 3, 0, 0)
	builder_end_function(&builder)

	program := builder_build(&builder, alloc)
	testing.expect_value(t, program_validate(program), Program_Error.None)

	state: VM
	vm_init(&state, program, alloc)
	defer vm_destroy(&state)

	testing.expect_value(t, vm_run(&state), VM_Status.Halted)
	testing.expect_value(t, state.result, must_int(10))
}

@(test)
test_vm_truthiness_matches_for_all_paths :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	empty_list := i32(builder_add_constant(&builder, v.value_list(alloc, []v.Value{})))
	one_list := i32(builder_add_constant(&builder, v.value_list(alloc, []v.Value{must_int(1)})))
	empty_relation := i32(builder_add_constant(&builder, v.value_empty_relation()))
	false_const := i32(builder_add_constant(&builder, v.value_bool(false)))

	// Each Is_Truthy and Unary Not writes into the contiguous registers 8..12
	// so the final Build_List can collect them.
	builder_begin_function(&builder, v.symbol_intern("main"), 0, 16, true)

	builder_emit(&builder, .Load_Const, 0, 0, empty_list, 0)
	builder_emit(&builder, .Is_Truthy, 0, 8, 0, 0)
	builder_emit(&builder, .Load_Const, 0, 1, empty_relation, 0)
	builder_emit(&builder, .Is_Truthy, 0, 9, 1, 0)
	builder_emit(&builder, .Load_Const, 0, 2, one_list, 0)
	builder_emit(&builder, .Is_Truthy, 0, 10, 2, 0)
	builder_emit(&builder, .Load_Const, 0, 3, false_const, 0)
	builder_emit(&builder, .Unary, u8(Un_Op.Not), 11, 3, 0)
	builder_emit(&builder, .Unary, u8(Un_Op.Not), 12, 0, 0)

	builder_emit(&builder, .Build_List, 0, 13, 8, 5)
	builder_emit(&builder, .Return, 0, 13, 0, 0)
	builder_end_function(&builder)

	program := builder_build(&builder, alloc)
	testing.expect_value(t, program_validate(program), Program_Error.None)

	state: VM
	vm_init(&state, program, alloc)
	defer vm_destroy(&state)

	testing.expect_value(t, vm_run(&state), VM_Status.Halted)
	observed, observed_ok := v.value_as_list(state.result)
	testing.expect(t, observed_ok)
	if !observed_ok {
		return
	}
	expect_bool := proc(t: ^testing.T, value: v.Value, expected: bool) {
		actual, ok := v.value_as_bool(value)
		testing.expect(t, ok)
		testing.expect_value(t, actual, expected)
	}
	// empty list false; empty relation false; non-empty list true;
	// !false true; !empty-list true.
	expect_bool(t, observed[0], false)
	expect_bool(t, observed[1], false)
	expect_bool(t, observed[2], true)
	expect_bool(t, observed[3], true)
	expect_bool(t, observed[4], true)
}

@(test)
test_vm_loop_sums_to_55 :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	zero := constant(&builder, 0)
	one := constant(&builder, 1)
	ten := constant(&builder, 10)

	builder_begin_function(&builder, v.symbol_intern("main"), 0, 6, true)
	builder_emit(&builder, .Load_Const, 0, 0, ten, 0) // limit
	builder_emit(&builder, .Load_Const, 0, 1, zero, 0) // i
	builder_emit(&builder, .Load_Const, 0, 2, zero, 0) // sum
	builder_emit(&builder, .Load_Const, 0, 3, one, 0) // step
	// Exit when i > limit.
	builder_emit(&builder, .Binary, u8(Bin_Op.Gt), 4, 1, 0)
	builder_emit(&builder, .Branch, 0, 4, 3, 0) // true -> return at 9
	builder_emit(&builder, .Binary, u8(Bin_Op.Add), 2, 2, 1)
	builder_emit(&builder, .Binary, u8(Bin_Op.Add), 1, 1, 3)
	builder_emit(&builder, .Jump, 0, 0, -5, 0) // back to 4
	builder_emit(&builder, .Return, 0, 2, 0, 0)
	builder_end_function(&builder)

	program := builder_build(&builder, alloc)
	testing.expect_value(t, program_validate(program), Program_Error.None)

	state: VM
	vm_init(&state, program, alloc)
	defer vm_destroy(&state)

	testing.expect_value(t, vm_run(&state), VM_Status.Halted)
	testing.expect_value(t, state.result, must_int(55))
}

@(test)
test_vm_function_call :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	two := constant(&builder, 2)
	twenty_one := constant(&builder, 21)

	double := builder_begin_function(&builder, v.symbol_intern("double"), 1, 2)
	builder_emit(&builder, .Load_Const, 0, 1, two, 0)
	builder_emit(&builder, .Binary, u8(Bin_Op.Mul), 1, 0, 1)
	builder_emit(&builder, .Return, 0, 1, 0, 0)
	builder_end_function(&builder)

	builder_begin_function(&builder, v.symbol_intern("main"), 0, 3, true)
	builder_emit(&builder, .Load_Const, 0, 0, twenty_one, 0)
	builder_emit(&builder, .Call, 1, 1, i32(double), 0)
	builder_emit(&builder, .Return, 0, 1, 0, 0)
	builder_end_function(&builder)

	program := builder_build(&builder, alloc)
	testing.expect_value(t, program_validate(program), Program_Error.None)

	state: VM
	vm_init(&state, program, alloc)
	defer vm_destroy(&state)

	testing.expect_value(t, vm_run(&state), VM_Status.Halted)
	testing.expect_value(t, state.result, must_int(42))
}

@(test)
test_vm_build_list_and_len :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	one := constant(&builder, 1)
	two := constant(&builder, 2)
	three := constant(&builder, 3)

	builder_begin_function(&builder, v.symbol_intern("main"), 0, 5, true)
	builder_emit(&builder, .Load_Const, 0, 0, one, 0)
	builder_emit(&builder, .Load_Const, 0, 1, two, 0)
	builder_emit(&builder, .Load_Const, 0, 2, three, 0)
	builder_emit(&builder, .Build_List, 0, 3, 0, 3)
	builder_emit(&builder, .Len, 0, 4, 3, 0)
	builder_emit(&builder, .Return, 0, 4, 0, 0)
	builder_end_function(&builder)

	program := builder_build(&builder, alloc)
	testing.expect_value(t, program_validate(program), Program_Error.None)

	state: VM
	vm_init(&state, program, alloc)
	defer vm_destroy(&state)

	testing.expect_value(t, vm_run(&state), VM_Status.Halted)
	testing.expect_value(t, state.result, must_int(3))

	// Build a list and inspect its cells through a second program run.
	builder2: Builder
	builder_init(&builder2)
	defer builder_destroy(&builder2)
	one2 := constant(&builder2, 1)
	two2 := constant(&builder2, 2)
	three2 := constant(&builder2, 3)
	builder_begin_function(&builder2, v.symbol_intern("main"), 0, 4, true)
	builder_emit(&builder2, .Load_Const, 0, 0, one2, 0)
	builder_emit(&builder2, .Load_Const, 0, 1, two2, 0)
	builder_emit(&builder2, .Load_Const, 0, 2, three2, 0)
	builder_emit(&builder2, .Build_List, 0, 3, 0, 3)
	builder_emit(&builder2, .Return, 0, 3, 0, 0)
	builder_end_function(&builder2)
	program2 := builder_build(&builder2, alloc)
	testing.expect_value(t, program_validate(program2), Program_Error.None)
	state2: VM
	vm_init(&state2, program2, alloc)
	defer vm_destroy(&state2)
	testing.expect_value(t, vm_run(&state2), VM_Status.Halted)
	values, values_ok := v.value_as_list(state2.result)
	testing.expect(t, values_ok)
	testing.expect_value(t, len(values), 3)
	testing.expect_value(t, values[0], must_int(1))
	testing.expect_value(t, values[2], must_int(3))
}

@(test)
test_vm_division_by_zero_fails :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	one := constant(&builder, 1)
	zero := constant(&builder, 0)

	builder_begin_function(&builder, v.symbol_intern("main"), 0, 3, true)
	builder_emit(&builder, .Load_Const, 0, 0, one, 0)
	builder_emit(&builder, .Load_Const, 0, 1, zero, 0)
	builder_emit(&builder, .Binary, u8(Bin_Op.Div), 2, 0, 1)
	builder_emit(&builder, .Return, 0, 2, 0, 0)
	builder_end_function(&builder)

	program := builder_build(&builder, alloc)
	testing.expect_value(t, program_validate(program), Program_Error.None)

	state: VM
	vm_init(&state, program, alloc)
	defer vm_destroy(&state)

	testing.expect_value(t, vm_run(&state), VM_Status.Failed)
	error, error_ok := v.value_as_error(state.error)
	testing.expect(t, error_ok)
	code_name, code_ok := v.symbol_name(error.code)
	testing.expect(t, code_ok)
	testing.expect_value(t, code_name, "E_DIV")
	// The error carries the operands as its payload.
	testing.expect(t, error.has_value)
	payload, payload_ok := v.value_as_list(error.value)
	testing.expect(t, payload_ok)
	testing.expect_value(t, len(payload), 2)
	testing.expect(t, v.value_eq(payload[0], must_int(1)))
	testing.expect(t, v.value_eq(payload[1], must_int(0)))
}

@(test)
test_vm_mixed_numeric_operands_fail_with_e_type :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	one := constant(&builder, 1)
	half := float_constant(&builder, 0.5)

	builder_begin_function(&builder, v.symbol_intern("main"), 0, 3, true)
	builder_emit(&builder, .Load_Const, 0, 0, one, 0)
	builder_emit(&builder, .Load_Const, 0, 1, half, 0)
	builder_emit(&builder, .Binary, u8(Bin_Op.Add), 2, 0, 1)
	builder_emit(&builder, .Return, 0, 2, 0, 0)
	builder_end_function(&builder)

	program := builder_build(&builder, alloc)
	testing.expect_value(t, program_validate(program), Program_Error.None)

	state: VM
	vm_init(&state, program, alloc)
	defer vm_destroy(&state)

	testing.expect_value(t, vm_run(&state), VM_Status.Failed)
	error, error_ok := v.value_as_error(state.error)
	testing.expect(t, error_ok)
	code_name, code_ok := v.symbol_name(error.code)
	testing.expect(t, code_ok)
	testing.expect_value(t, code_name, "E_TYPE")
}

@(test)
test_program_validation_rejects_bad_register :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	value := constant(&builder, 1)
	builder_begin_function(&builder, v.symbol_intern("main"), 0, 1, true)
	builder_emit(&builder, .Load_Const, 0, 5, value, 0)
	builder_emit(&builder, .Return, 0, 0, 0, 0)
	builder_end_function(&builder)

	program := builder_build(&builder, alloc)
	testing.expect_value(t, program_validate(program), Program_Error.Bad_Register)
}

// Variadic opcodes read registers `c .. c+flags-1`; the validator must reject
// an argument range that runs past the register file.
@(test)
test_program_validation_rejects_short_argument_range :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	// Builtin_Call: two arguments starting at r1, but only r0..r1 exist.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)
	builder_add_builtin(&builder, v.symbol_intern("noop"))
	builder_begin_function(&builder, v.symbol_intern("main"), 0, 2, true)
	builder_emit(&builder, .Builtin_Call, 2, 0, 0, 1)
	builder_emit(&builder, .Return, 0, 0, 0, 0)
	builder_end_function(&builder)
	program := builder_build(&builder, alloc)
	testing.expect_value(t, program_validate(program), Program_Error.Bad_Arguments)

	// Call_Value: same shape through a function-value register.
	builder2: Builder
	builder_init(&builder2)
	defer builder_destroy(&builder2)
	builder_begin_function(&builder2, v.symbol_intern("main"), 0, 2, true)
	builder_emit(&builder2, .Call_Value, 2, 0, 1, 1)
	builder_emit(&builder2, .Return, 0, 0, 0, 0)
	builder_end_function(&builder2)
	program2 := builder_build(&builder2, alloc)
	testing.expect_value(t, program_validate(program2), Program_Error.Bad_Arguments)

	// Positional_Dispatch: two arguments starting at r1.
	builder3: Builder
	builder_init(&builder3)
	defer builder_destroy(&builder3)
	builder_begin_function(&builder3, v.symbol_intern("main"), 0, 2, true)
	builder_emit(&builder3, .Positional_Dispatch, 2, 0, 1, 1)
	builder_emit(&builder3, .Return, 0, 0, 0, 0)
	builder_end_function(&builder3)
	program3 := builder_build(&builder3, alloc)
	testing.expect_value(t, program_validate(program3), Program_Error.Bad_Arguments)
}

@(test)
test_program_disassembly :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	value := constant(&builder, 7)
	builder_begin_function(&builder, v.symbol_intern("main"), 0, 2, true)
	builder_emit(&builder, .Load_Const, 0, 0, value, 0)
	builder_emit(&builder, .Return, 0, 0, 0, 0)
	builder_end_function(&builder)

	program := builder_build(&builder, alloc)
	text := program_disassemble(program, alloc)
	testing.expect(t, strings.contains(text, "function main"))
	testing.expect(t, strings.contains(text, "load_const"))
	testing.expect(t, strings.contains(text, "r0 c0"))
	testing.expect(t, strings.contains(text, "return"))
}

@(private)
must_identity :: proc(raw: u64) -> v.Value {
	value, ok := v.value_identity_raw(raw)
	assert(ok)
	return value
}

@(private)
relation_setup :: proc() -> (k.Kernel, k.Relation_ID) {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	metadata := k.relation_metadata(k.Relation_ID(1), v.symbol_intern("HeldBy"), 2)
	snapshot, err := k.kernel_create_relation(&kernel, metadata)
	assert(err == .None)
	k.snapshot_release(snapshot)
	return kernel, k.Relation_ID(1)
}

@(private)
relation_seed :: proc(kernel: ^k.Kernel, relation: k.Relation_ID, facts: [][2]v.Value) {
	tx := k.kernel_begin(kernel)
	for fact in facts {
		row := v.tuple_new(context.temp_allocator, []v.Value{fact[0], fact[1]})
		assert(k.transaction_assert(&tx, relation, row) == .None)
	}
	snapshot, err := k.transaction_commit(&tx)
	assert(err == .None)
	k.snapshot_release(snapshot)
	k.transaction_destroy(&tx)
}

@(test)
test_vm_scan_collect_and_len :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	kernel, relation := relation_setup()
	defer k.kernel_destroy(&kernel)
	relation_seed(&kernel, relation, [][2]v.Value {
		{must_identity(1), must_identity(2)},
		{must_identity(3), must_identity(4)},
	})
	source := k.Relation_Source{snapshot = kernel.current, use_stored_derived = true}

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	owner := v.symbol_intern("owner")
	item := v.symbol_intern("item")
	pattern := builder_add_pattern(
		&builder,
		u32(relation),
		0,
		[]v.Symbol{owner, item},
		[]Pattern_Cell{{kind = .Output}, {kind = .Output}},
	)

	builder_begin_function(&builder, v.symbol_intern("main"), 0, 2, true)
	builder_emit(&builder, .Scan_Collect, 0, 0, pattern, 0)
	builder_emit(&builder, .Len, 0, 1, 0, 0)
	builder_emit(&builder, .Return, 0, 1, 0, 0)
	builder_end_function(&builder)

	program := builder_build(&builder, alloc)
	testing.expect_value(t, program_validate(program), Program_Error.None)

	state: VM
	vm_init(&state, program, alloc)
	defer vm_destroy(&state)
	vm_set_workspace(&state, &source, nil)

	testing.expect_value(t, vm_run(&state), VM_Status.Halted)
	testing.expect_value(t, state.result, must_int(2))
}

@(test)
test_vm_scan_first_binds_register :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	kernel, relation := relation_setup()
	defer k.kernel_destroy(&kernel)
	relation_seed(&kernel, relation, [][2]v.Value {
		{must_identity(1), must_identity(2)},
	})
	source := k.Relation_Source{snapshot = kernel.current, use_stored_derived = true}

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	lamp := must_identity(2)
	lamp_constant := i32(builder_add_constant(&builder, lamp))
	owner := v.symbol_intern("owner")
	item := v.symbol_intern("item")
	pattern := builder_add_pattern(
		&builder,
		u32(relation),
		0,
		[]v.Symbol{owner, item},
		[]Pattern_Cell{{kind = .Output, operand = 0}, {kind = .Const, operand = lamp_constant}},
	)

	builder_begin_function(&builder, v.symbol_intern("main"), 0, 3, true)
	builder_emit(&builder, .Scan_First, 0, 1, pattern, 0)
	builder_emit(&builder, .Branch, 0, 1, 1, 0)
	builder_emit(&builder, .Return, 0, 1, 0, 0)
	builder_emit(&builder, .Return, 0, 0, 0, 0)
	builder_end_function(&builder)

	program := builder_build(&builder, alloc)
	testing.expect_value(t, program_validate(program), Program_Error.None)

	state: VM
	vm_init(&state, program, alloc)
	defer vm_destroy(&state)
	vm_set_workspace(&state, &source, nil)

	testing.expect_value(t, vm_run(&state), VM_Status.Halted)
	testing.expect_value(t, state.result, must_identity(1))
}

// Scan_First must enforce the same read authority as Scan_Collect/Exists.
// Regression: it scanned without any permission check.
@(test)
test_vm_scan_first_denies_unauthorized :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	kernel, relation := relation_setup()
	defer k.kernel_destroy(&kernel)
	relation_seed(&kernel, relation, [][2]v.Value {
		{must_identity(1), must_identity(2)},
	})
	source := k.Relation_Source{snapshot = kernel.current, use_stored_derived = true}

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	lamp := must_identity(2)
	lamp_constant := i32(builder_add_constant(&builder, lamp))
	owner := v.symbol_intern("owner")
	item := v.symbol_intern("item")
	pattern := builder_add_pattern(
		&builder,
		u32(relation),
		0,
		[]v.Symbol{owner, item},
		[]Pattern_Cell{{kind = .Output, operand = 0}, {kind = .Const, operand = lamp_constant}},
	)

	builder_begin_function(&builder, v.symbol_intern("main"), 0, 3, true)
	builder_emit(&builder, .Scan_First, 0, 1, pattern, 0)
	builder_emit(&builder, .Branch, 0, 1, 1, 0)
	builder_emit(&builder, .Return, 0, 1, 0, 0)
	builder_emit(&builder, .Return, 0, 0, 0, 0)
	builder_end_function(&builder)

	program := builder_build(&builder, alloc)
	testing.expect_value(t, program_validate(program), Program_Error.None)

	authority := k.authority_empty(alloc)
	defer k.authority_destroy(&authority)

	state: VM
	vm_init(&state, program, alloc)
	defer vm_destroy(&state)
	vm_set_workspace(&state, &source, nil)
	vm_set_authority(&state, &authority)

	testing.expect_value(t, vm_run(&state), VM_Status.Failed)
	error, error_ok := v.value_as_error(state.error)
	testing.expect(t, error_ok)
	code, code_ok := v.symbol_name(error.code)
	testing.expect(t, code_ok)
	testing.expect_value(t, code, "E_PERMISSION")
}

@(test)
test_vm_assert_and_retract :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	kernel, relation := relation_setup()
	defer k.kernel_destroy(&kernel)

	owner := v.symbol_intern("owner")
	item := v.symbol_intern("item")

	row_values := []v.Value{must_identity(1), must_identity(2)}
	row := v.tuple_new(alloc, row_values)
	relation_value, relation_err := v.value_relation(
		alloc,
		[]v.Symbol{owner, item},
		[]v.Tuple{row},
	)
	testing.expect_value(t, relation_err, v.Relation_Value_Error.None)

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	row_constant := i32(builder_add_constant(&builder, relation_value))
	builder_begin_function(&builder, v.symbol_intern("main"), 0, 2, true)
	builder_emit(&builder, .Load_Const, 0, 0, row_constant, 0)
	builder_emit(&builder, .Assert, 0, i32(relation), 0, 0)
	builder_emit(&builder, .Return, 0, 0, 0, 0)
	builder_end_function(&builder)

	program := builder_build(&builder, alloc)
	testing.expect_value(t, program_validate(program), Program_Error.None)

	source := k.Relation_Source{snapshot = kernel.current, use_stored_derived = true}
	tx := k.kernel_begin(&kernel)
	defer k.transaction_destroy(&tx)

	state: VM
	vm_init(&state, program, alloc)
	defer vm_destroy(&state)
	vm_set_workspace(&state, &source, &tx)

	testing.expect_value(t, vm_run(&state), VM_Status.Halted)
	snapshot, commit_err := k.transaction_commit(&tx)
	testing.expect_value(t, commit_err, k.Kernel_Error.None)
	k.snapshot_release(snapshot)

	rows := make([dynamic]v.Tuple)
	k.kernel_scan_into(&kernel, relation, []v.Binding{{}, {}}, &rows)
	testing.expect_value(t, len(rows), 1)
	delete(rows)

	// Retract the same row through a second program.
	builder2: Builder
	builder_init(&builder2)
	defer builder_destroy(&builder2)
	row_constant2 := i32(builder_add_constant(&builder2, relation_value))
	builder_begin_function(&builder2, v.symbol_intern("main"), 0, 2, true)
	builder_emit(&builder2, .Load_Const, 0, 0, row_constant2, 0)
	builder_emit(&builder2, .Retract, 0, i32(relation), 0, 0)
	builder_emit(&builder2, .Return, 0, 0, 0, 0)
	builder_end_function(&builder2)
	program2 := builder_build(&builder2, alloc)
	testing.expect_value(t, program_validate(program2), Program_Error.None)

	source2 := k.Relation_Source{snapshot = kernel.current, use_stored_derived = true}
	tx2 := k.kernel_begin(&kernel)
	defer k.transaction_destroy(&tx2)
	state2: VM
	vm_init(&state2, program2, alloc)
	defer vm_destroy(&state2)
	vm_set_workspace(&state2, &source2, &tx2)
	testing.expect_value(t, vm_run(&state2), VM_Status.Halted)
	snapshot2, commit_err2 := k.transaction_commit(&tx2)
	testing.expect_value(t, commit_err2, k.Kernel_Error.None)
	k.snapshot_release(snapshot2)

	rows2 := make([dynamic]v.Tuple)
	k.kernel_scan_into(&kernel, relation, []v.Binding{{}, {}}, &rows2)
	testing.expect_value(t, len(rows2), 0)
	delete(rows2)
}

@(test)
test_vm_retract_where :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	kernel, relation := relation_setup()
	defer k.kernel_destroy(&kernel)
	relation_seed(&kernel, relation, [][2]v.Value {
		{must_identity(1), must_identity(2)},
		{must_identity(1), must_identity(3)},
		{must_identity(4), must_identity(5)},
	})

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	alice := must_identity(1)
	alice_constant := i32(builder_add_constant(&builder, alice))
	owner := v.symbol_intern("owner")
	item := v.symbol_intern("item")
	pattern := builder_add_pattern(
		&builder,
		u32(relation),
		0,
		[]v.Symbol{owner, item},
		[]Pattern_Cell{{kind = .Const, operand = alice_constant}, {kind = .Wildcard}},
	)

	builder_begin_function(&builder, v.symbol_intern("main"), 0, 1, true)
	builder_emit(&builder, .Retract_Where, 0, 0, pattern, 0)
	builder_emit(&builder, .Load_Const, 0, 0, alice_constant, 0)
	builder_emit(&builder, .Return, 0, 0, 0, 0)
	builder_end_function(&builder)

	program := builder_build(&builder, alloc)
	testing.expect_value(t, program_validate(program), Program_Error.None)

	source := k.Relation_Source{snapshot = kernel.current, use_stored_derived = true}
	tx := k.kernel_begin(&kernel)
	defer k.transaction_destroy(&tx)
	state: VM
	vm_init(&state, program, alloc)
	defer vm_destroy(&state)
	vm_set_workspace(&state, &source, &tx)
	testing.expect_value(t, vm_run(&state), VM_Status.Halted)

	snapshot, commit_err := k.transaction_commit(&tx)
	testing.expect_value(t, commit_err, k.Kernel_Error.None)
	k.snapshot_release(snapshot)

	rows := make([dynamic]v.Tuple)
	k.kernel_scan_into(&kernel, relation, []v.Binding{{}, {}}, &rows)
	testing.expect_value(t, len(rows), 1)
	delete(rows)
}

@(test)
test_vm_build_relation_and_index :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	owner := v.symbol_intern("owner")
	item := v.symbol_intern("item")
	shape := builder_add_relation_shape(&builder, []v.Symbol{owner, item})
	owner_value := i32(builder_add_constant(&builder, must_identity(1)))
	item_value := i32(builder_add_constant(&builder, must_identity(2)))
	item_symbol := i32(builder_add_constant(&builder, v.value_symbol(item)))

	builder_begin_function(&builder, v.symbol_intern("main"), 0, 5, true)
	builder_emit(&builder, .Load_Const, 0, 0, owner_value, 0)
	builder_emit(&builder, .Load_Const, 0, 1, item_value, 0)
	builder_emit(&builder, .Build_Relation, 0, 2, shape, 0)
	builder_emit(&builder, .Load_Const, 0, 3, item_symbol, 0)
	builder_emit(&builder, .Index, 0, 4, 2, 3)
	builder_emit(&builder, .Return, 0, 4, 0, 0)
	builder_end_function(&builder)

	program := builder_build(&builder, alloc)
	testing.expect_value(t, program_validate(program), Program_Error.None)

	state: VM
	vm_init(&state, program, alloc)
	defer vm_destroy(&state)
	testing.expect_value(t, vm_run(&state), VM_Status.Halted)
	testing.expect_value(t, state.result, must_identity(2))
}

// Map indexing must behave identically after the linear scan became a binary
// search over the canonicalized (sorted) entries: hits, misses, and a map large
// enough that a scan would be the wrong complexity.
@(test)
test_vm_map_index_semantics :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	entries := make([]v.Map_Entry, 256, context.temp_allocator)
	for index in 0 ..< 256 {
		key := must_int(i64(index))
		value := must_int(i64(index * 10))
		entries[index] = v.Map_Entry{key = key, value = value}
	}
	map_value := v.value_map(alloc, entries)

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	map_constant := i32(builder_add_constant(&builder, map_value))
	present_key := i32(builder_add_constant(&builder, must_int(200)))
	missing_key := i32(builder_add_constant(&builder, must_int(999)))

	builder_begin_function(&builder, v.symbol_intern("main"), 0, 4, true)
	builder_emit(&builder, .Load_Const, 0, 0, map_constant, 0)
	builder_emit(&builder, .Load_Const, 0, 1, present_key, 0)
	builder_emit(&builder, .Index, 0, 2, 0, 1)
	builder_emit(&builder, .Return, 0, 2, 0, 0)
	builder_end_function(&builder)
	program := builder_build(&builder, alloc)
	testing.expect_value(t, program_validate(program), Program_Error.None)

	state: VM
	vm_init(&state, program, alloc)
	defer vm_destroy(&state)
	testing.expect_value(t, vm_run(&state), VM_Status.Halted)
	testing.expect_value(t, state.result, must_int(2000))

	// A missing key still fails with E_KEY.
	builder_begin_function(&builder, v.symbol_intern("missing"), 0, 4, true)
	builder_emit(&builder, .Load_Const, 0, 0, map_constant, 0)
	builder_emit(&builder, .Load_Const, 0, 1, missing_key, 0)
	builder_emit(&builder, .Index, 0, 2, 0, 1)
	builder_emit(&builder, .Return, 0, 2, 0, 0)
	builder_end_function(&builder)
	missing_program := builder_build(&builder, alloc)

	missing_state: VM
	vm_init(&missing_state, missing_program, alloc)
	defer vm_destroy(&missing_state)
	testing.expect_value(t, vm_run(&missing_state), VM_Status.Failed)
	error, error_ok := v.value_as_error(missing_state.error)
	testing.expect(t, error_ok)
	code, code_ok := v.symbol_name(error.code)
	testing.expect(t, code_ok)
	testing.expect_value(t, code, "E_KEY")
}

@(private)
double_builtin :: proc(state: ^VM, args: []v.Value) -> (v.Value, bool) {
	two, _ := v.value_int(2)
	result, ok := v.value_checked_mul(args[0], two)
	if !ok {
		vm_set_error(state, "E_ARITH", "double failed")
		return v.Value(0), false
	}
	return result, true
}

@(test)
test_vm_builtin_call :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	twenty_one := constant(&builder, 21)
	builtin := builder_add_builtin(&builder, v.symbol_intern("double"))

	builder_begin_function(&builder, v.symbol_intern("main"), 0, 2, true)
	builder_emit(&builder, .Load_Const, 0, 0, twenty_one, 0)
	builder_emit(&builder, .Builtin_Call, 0, 1, builtin, 0)
	builder_emit(&builder, .Return, 0, 1, 0, 0)
	builder_end_function(&builder)

	program := builder_build(&builder, alloc)
	testing.expect_value(t, program_validate(program), Program_Error.None)

	state: VM
	vm_init(&state, program, alloc)
	defer vm_destroy(&state)
	vm_register_builtin(&state, v.symbol_intern("double"), 1, double_builtin)

	testing.expect_value(t, vm_run(&state), VM_Status.Halted)
	testing.expect_value(t, state.result, must_int(42))
}

@(test)
test_vm_commit_boundary_resumes :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	seven := constant(&builder, 7)
	builder_begin_function(&builder, v.symbol_intern("main"), 0, 2, true)
	builder_emit(&builder, .Commit, 0, 0, 0, 0)
	builder_emit(&builder, .Load_Const, 0, 0, seven, 0)
	builder_emit(&builder, .Return, 0, 0, 0, 0)
	builder_end_function(&builder)

	program := builder_build(&builder, alloc)
	testing.expect_value(t, program_validate(program), Program_Error.None)

	state: VM
	vm_init(&state, program, alloc)
	defer vm_destroy(&state)

	testing.expect_value(t, vm_run(&state), VM_Status.Boundary)
	testing.expect_value(t, state.request, VM_Request.Commit)
	testing.expect_value(t, vm_run(&state), VM_Status.Halted)
	testing.expect_value(t, state.result, must_int(7))
}

@(test)
test_vm_raise_aborts_with_error :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	code := i32(builder_add_constant(
		&builder,
		v.value_error_code(v.symbol_intern("E_RANGE")),
	))
	message := i32(builder_add_constant(
		&builder,
		v.value_string(alloc, "out of range"),
	))

	builder_begin_function(&builder, v.symbol_intern("main"), 0, 3, true)
	builder_emit(&builder, .Load_Const, 0, 0, code, 0)
	builder_emit(&builder, .Load_Const, 0, 1, message, 0)
	builder_emit(&builder, .Raise, 0, 0, 1, -1)
	builder_emit(&builder, .Return, 0, 0, 0, 0)
	builder_end_function(&builder)

	program := builder_build(&builder, alloc)
	testing.expect_value(t, program_validate(program), Program_Error.None)

	state: VM
	vm_init(&state, program, alloc)
	defer vm_destroy(&state)

	testing.expect_value(t, vm_run(&state), VM_Status.Failed)
	error, error_ok := v.value_as_error(state.error)
	testing.expect(t, error_ok)
	code_name, code_ok := v.symbol_name(error.code)
	testing.expect(t, code_ok)
	testing.expect_value(t, code_name, "E_RANGE")
	testing.expect_value(t, error.message, "out of range")
}

@(test)
test_vm_authority_denies_and_root_allows :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	kernel, relation := relation_setup()
	defer k.kernel_destroy(&kernel)

	owner := v.symbol_intern("owner")
	item := v.symbol_intern("item")
	row := v.tuple_new(alloc, []v.Value{must_identity(1), must_identity(2)})
	relation_value, relation_err := v.value_relation(
		alloc,
		[]v.Symbol{owner, item},
		[]v.Tuple{row},
	)
	testing.expect_value(t, relation_err, v.Relation_Value_Error.None)

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)
	row_constant := i32(builder_add_constant(&builder, relation_value))
	builder_begin_function(&builder, v.symbol_intern("main"), 0, 2, true)
	builder_emit(&builder, .Load_Const, 0, 0, row_constant, 0)
	builder_emit(&builder, .Assert, 0, i32(relation), 0, 0)
	builder_emit(&builder, .Return, 0, 0, 0, 0)
	builder_end_function(&builder)

	program := builder_build(&builder, alloc)
	testing.expect_value(t, program_validate(program), Program_Error.None)

	source := k.Relation_Source{snapshot = kernel.current, use_stored_derived = true}
	tx := k.kernel_begin(&kernel)
	defer k.transaction_destroy(&tx)

	authority := k.authority_empty(alloc)
	defer k.authority_destroy(&authority)

	denied: VM
	vm_init(&denied, program, alloc)
	defer vm_destroy(&denied)
	vm_set_workspace(&denied, &source, &tx)
	vm_set_authority(&denied, &authority)
	testing.expect_value(t, vm_run(&denied), VM_Status.Failed)
	error, error_ok := v.value_as_error(denied.error)
	testing.expect(t, error_ok)
	code, code_ok := v.symbol_name(error.code)
	testing.expect(t, code_ok)
	testing.expect_value(t, code, "E_PERMISSION")

	root: VM
	vm_init(&root, program, alloc)
	defer vm_destroy(&root)
	vm_set_workspace(&root, &source, &tx)
	testing.expect_value(t, vm_run(&root), VM_Status.Halted)
	committed, commit_err := k.transaction_commit(&tx)
	testing.expect_value(t, commit_err, k.Kernel_Error.None)
	k.snapshot_release(committed)

	rows := make([dynamic]v.Tuple)
	defer delete(rows)
	k.kernel_scan_into(&kernel, relation, []v.Binding{{}, {}}, &rows)
	testing.expect_value(t, len(rows), 1)
}

// Per-instruction temporaries must not accumulate: the VM reset its scratch
// arena each instruction. Regression: these used the thread temp arena, which
// was only reclaimed at the task boundary, so one long task grew it per step.
@(test)
test_vm_scratch_arena_is_reclaimed :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)
	constant := i32(builder_add_constant(&builder, must_int(1)))
	builder_begin_function(&builder, v.symbol_intern("main"), 0, 4, true)
	for register in 0 ..< 3 {
		builder_emit(&builder, .Load_Const, 0, i32(register), constant, 0)
	}
	// Each Build_List allocates a scratch slice; 20k of them would grow a
	// non-reset arena into the megabytes.
	ITERATIONS :: 20_000
	for _ in 0 ..< ITERATIONS {
		builder_emit(&builder, .Build_List, 0, 3, 0, 3)
	}
	builder_emit(&builder, .Return, 0, 3, 0, 0)
	builder_end_function(&builder)

	program := builder_build(&builder, alloc)
	testing.expect_value(t, program_validate(program), Program_Error.None)

	state: VM
	vm_init(&state, program, alloc)
	defer vm_destroy(&state)
	testing.expect_value(t, vm_run(&state), VM_Status.Halted)
	testing.expect(t, state.scratch != nil)
	// Every instruction reclaimed its scratch, so nothing is outstanding.
	testing.expect_value(t, state.scratch.total_used, uint(0))
}

@(test)
test_vm_unwind_shrinks_registers :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	// Two functions with roomy register windows; the handler lives in
	// function 0 while function 1's dead window sits above it.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)
	builder_begin_function(&builder, v.symbol_intern("main"), 0, 8, true)
	builder_emit(&builder, .Return, 0, 0, 0, 0)
	builder_end_function(&builder)
	builder_begin_function(&builder, v.symbol_intern("child"), 0, 8, true)
	builder_emit(&builder, .Return, 0, 0, 0, 0)
	builder_end_function(&builder)
	program := builder_build(&builder, alloc)

	state: VM
	vm_init(&state, program, alloc)
	defer vm_destroy(&state)

	// A live handler frame plus a dead child frame with registers above it.
	append(&state.frames, Frame{program = program, function = 0, ip = 0, register_base = 0})
	append(
		&state.frames,
		Frame{program = program, function = 1, ip = 0, register_base = 8},
	)
	resize(&state.registers, 16)
	append(&state.handlers, Handler{frame = 0, target = 0, error_register = -1, kind = .Catch})

	testing.expect(t, vm_unwind(&state))
	testing.expect_value(t, len(state.frames), 1)
	testing.expect_value(t, len(state.registers), 8)
}

@(test)
test_vm_call_depth_limit :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	builder_begin_function(&builder, v.symbol_intern("recurse"), 0, 1, true)
	builder_emit(&builder, .Call, 0, 0, 0, 0)
	builder_emit(&builder, .Return, 0, 0, 0, 0)
	builder_end_function(&builder)

	program := builder_build(&builder, alloc)
	testing.expect_value(t, program_validate(program), Program_Error.None)

	state: VM
	vm_init(&state, program, alloc)
	defer vm_destroy(&state)
	vm_set_max_call_depth(&state, 8)

	testing.expect_value(t, vm_run(&state), VM_Status.Failed)
	error, error_ok := v.value_as_error(state.error)
	testing.expect(t, error_ok)
	code, code_ok := v.symbol_name(error.code)
	testing.expect(t, code_ok)
	testing.expect_value(t, code, "E_DEPTH")
}

@(test)
test_vm_instruction_budget :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	one := i32(builder_add_constant(&builder, must_int(1)))
	builder_begin_function(&builder, v.symbol_intern("spin"), 0, 3, true)
	builder_emit(&builder, .Load_Const, 0, 0, one, 0)
	builder_emit(&builder, .Load_Const, 0, 1, one, 0)
	builder_emit(&builder, .Binary, u8(Bin_Op.Add), 0, 0, 1)
	builder_emit(&builder, .Jump, 0, 0, -4, 0)
	builder_end_function(&builder)

	program := builder_build(&builder, alloc)
	testing.expect_value(t, program_validate(program), Program_Error.None)

	state: VM
	vm_init(&state, program, alloc)
	defer vm_destroy(&state)
	vm_set_instruction_budget(&state, 64)

	testing.expect_value(t, vm_run(&state), VM_Status.Failed)
	error, error_ok := v.value_as_error(state.error)
	testing.expect(t, error_ok)
	code, code_ok := v.symbol_name(error.code)
	testing.expect(t, code_ok)
	testing.expect_value(t, code, "E_BUDGET")
}

// An unbounded spin loop hits the wall-clock deadline even though no
// instruction budget is set. This is the limit that bounds a program whose
// per-instruction host work makes the instruction budget trip too slowly to
// distinguish a hang from a slow run (see #92).
@(test)
test_vm_deadline :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	one := i32(builder_add_constant(&builder, must_int(1)))
	builder_begin_function(&builder, v.symbol_intern("spin"), 0, 3, true)
	builder_emit(&builder, .Load_Const, 0, 0, one, 0)
	builder_emit(&builder, .Load_Const, 0, 1, one, 0)
	builder_emit(&builder, .Binary, u8(Bin_Op.Add), 0, 0, 1)
	builder_emit(&builder, .Jump, 0, 0, -4, 0)
	builder_end_function(&builder)

	program := builder_build(&builder, alloc)
	testing.expect_value(t, program_validate(program), Program_Error.None)

	state: VM
	vm_init(&state, program, alloc)
	defer vm_destroy(&state)
	// No instruction budget, only a short wall-clock limit.
	vm_set_deadline(&state, 50 * time.Millisecond)

	testing.expect_value(t, vm_run(&state), VM_Status.Failed)
	error, error_ok := v.value_as_error(state.error)
	testing.expect(t, error_ok)
	code, code_ok := v.symbol_name(error.code)
	testing.expect(t, code_ok)
	testing.expect_value(t, code, "E_DEADLINE")
}

// Catching E_BUDGET must not turn the exhausted budget (0) into unlimited.
@(test)
test_vm_caught_budget_stays_exhausted :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	one := i32(builder_add_constant(&builder, must_int(1)))
	builder_begin_function(&builder, v.symbol_intern("main"), 0, 3, true)
	handler_index := len(builder.code)
	builder_emit(&builder, .Push_Handler, 0, 0, 1, 0)
	builder_emit(&builder, .Load_Const, 0, 0, one, 0)
	builder_emit(&builder, .Load_Const, 0, 1, one, 0)
	builder_emit(&builder, .Binary, u8(Bin_Op.Add), 0, 0, 1)
	builder_emit(&builder, .Jump, 0, 0, -4, 0)
	catch_offset := len(builder.code)
	builder.code[handler_index].a = i32(catch_offset)
	builder_emit(&builder, .Return, 0, 0, 0, 0)
	builder_end_function(&builder)

	program := builder_build(&builder, alloc)
	testing.expect_value(t, program_validate(program), Program_Error.None)

	state: VM
	vm_init(&state, program, alloc)
	defer vm_destroy(&state)
	vm_set_instruction_budget(&state, 8)

	testing.expect_value(t, vm_run(&state), VM_Status.Failed)
	error, error_ok := v.value_as_error(state.error)
	testing.expect(t, error_ok)
	code, code_ok := v.symbol_name(error.code)
	testing.expect(t, code_ok)
	testing.expect_value(t, code, "E_BUDGET")
}

@(test)
test_vm_dispatch_opcode :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	for metadata in k.dispatch_relation_metadata(alloc) {
		created, err := k.kernel_create_relation(&kernel, metadata)
		if err != k.Kernel_Error.None {
			testing.expectf(t, false, "cannot create dispatch relation: %v", err)
			return
		}
		k.snapshot_release(created)
	}

	method_one, one_ok := v.value_identity_raw(0x2001)
	method_two, two_ok := v.value_identity_raw(0x2002)
	testing.expect(t, one_ok && two_ok)
	selector := v.value_symbol(v.symbol_intern("greet"))

	tx := k.kernel_begin(&kernel)
	_ = k.transaction_assert(
		&tx,
		k.DISPATCH_METHOD_SELECTOR_ID,
		v.tuple_new(alloc, []v.Value{method_one, selector}),
	)
	_ = k.transaction_assert(
		&tx,
		k.DISPATCH_METHOD_PROGRAM_ID,
		v.tuple_new(alloc, []v.Value{method_one, must_int(1)}),
	)
	committed, commit_err := k.transaction_commit(&tx)
	testing.expect_value(t, commit_err, k.Kernel_Error.None)
	k.snapshot_release(committed)
	k.transaction_destroy(&tx)

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)
	builder.dispatch_method_selector_relation = u32(k.DISPATCH_METHOD_SELECTOR_ID)
	builder.dispatch_param_relation = u32(k.DISPATCH_PARAM_ID)
	builder.dispatch_delegates_relation = u32(k.DISPATCH_DELEGATES_ID)
	builder.dispatch_method_program_relation = u32(k.DISPATCH_METHOD_PROGRAM_ID)

	answer := constant(&builder, 42)
	seven := constant(&builder, 7)
	spec := builder_add_dispatch_spec(&builder, v.symbol_intern("greet"), nil)

	builder_begin_function(&builder, v.symbol_intern("main"), 0, 2, true)
	builder_emit(&builder, .Dispatch, 0, spec, 0, 0)
	builder_emit(&builder, .Return, 0, 0, 0, 0)
	builder_end_function(&builder)

	builder_begin_function(&builder, v.symbol_intern("method_one"), 0, 2, false)
	builder_emit(&builder, .Load_Const, 0, 0, answer, 0)
	builder_emit(&builder, .Return, 0, 0, 0, 0)
	builder_end_function(&builder)

	builder_begin_function(&builder, v.symbol_intern("method_two"), 0, 2, false)
	builder_emit(&builder, .Load_Const, 0, 0, seven, 0)
	builder_emit(&builder, .Return, 0, 0, 0, 0)
	builder_end_function(&builder)

	program := builder_build(&builder, alloc)
	testing.expect_value(t, program_validate(program), Program_Error.None)

	snapshot := k.kernel_snapshot(&kernel)
	defer k.snapshot_release(snapshot)
	source := k.Relation_Source {
		snapshot = snapshot,
	}

	state: VM
	vm_init(&state, program, alloc)
	defer vm_destroy(&state)
	state.source = &source

	testing.expect_value(t, vm_run(&state), VM_Status.Halted)
	testing.expect_value(t, state.result, must_int(42))

	tx_two := k.kernel_begin(&kernel)
	_ = k.transaction_assert(
		&tx_two,
		k.DISPATCH_METHOD_SELECTOR_ID,
		v.tuple_new(alloc, []v.Value{method_two, selector}),
	)
	_ = k.transaction_assert(
		&tx_two,
		k.DISPATCH_METHOD_PROGRAM_ID,
		v.tuple_new(alloc, []v.Value{method_two, must_int(2)}),
	)
	committed_two, commit_two_err := k.transaction_commit(&tx_two)
	testing.expect_value(t, commit_two_err, k.Kernel_Error.None)
	k.snapshot_release(committed_two)
	k.transaction_destroy(&tx_two)

	ambiguous_snapshot := k.kernel_snapshot(&kernel)
	defer k.snapshot_release(ambiguous_snapshot)
	ambiguous_source := k.Relation_Source {
		snapshot = ambiguous_snapshot,
	}

	ambiguous_state: VM
	vm_init(&ambiguous_state, program, alloc)
	defer vm_destroy(&ambiguous_state)
	ambiguous_state.source = &ambiguous_source

	testing.expect_value(t, vm_run(&ambiguous_state), VM_Status.Failed)
	error, error_ok := v.value_as_error(ambiguous_state.error)
	testing.expect(t, error_ok)
	code, code_ok := v.symbol_name(error.code)
	testing.expect(t, code_ok)
	testing.expect_value(t, code, "E_DISPATCH")
	testing.expect_value(t, error.message, "ambiguous method dispatch")
}

// Handler targets must point inside the function's code range.
@(test)
test_program_validation_rejects_bad_handler_target :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)
	builder_begin_function(&builder, v.symbol_intern("main"), 0, 1, true)
	builder_emit(&builder, .Push_Handler, 0, 9999, -1, 0)
	builder_emit(&builder, .Return, 0, 0, 0, 0)
	builder_end_function(&builder)
	program := builder_build(&builder, alloc)
	testing.expect_value(t, program_validate(program), Program_Error.Bad_Jump)

	builder2: Builder
	builder_init(&builder2)
	defer builder_destroy(&builder2)
	builder_begin_function(&builder2, v.symbol_intern("main"), 0, 1, true)
	builder_emit(&builder2, .Push_Finally, 0, 9999, 0, 0)
	builder_emit(&builder2, .Return, 0, 0, 0, 0)
	builder_end_function(&builder2)
	program2 := builder_build(&builder2, alloc)
	testing.expect_value(t, program_validate(program2), Program_Error.Bad_Jump)
}
