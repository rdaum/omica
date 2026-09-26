package vm

import v "../var"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import "core:time"

// Force each asynchronous-limit path to unwind from a short callee image to
// a handler whose instruction offset exists only in the caller image.
@(test)
test_vm_cross_program_limit_unwind :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)
	caller_builder, callee_builder: Builder
	builder_init(&caller_builder, alloc)
	builder_init(&callee_builder, alloc)
	defer builder_destroy(&caller_builder)
	defer builder_destroy(&callee_builder)
	answer := builder_add_constant(&caller_builder, must_int(42))
	builder_begin_function(&caller_builder, v.symbol_intern("catch_limit"), 0, 2, true)
	builder_emit(&caller_builder, .Push_Handler, 0, 1, 1, 0)
	builder_emit(&caller_builder, .Load_Const, 0, 0, i32(answer), 0)
	builder_emit(&caller_builder, .Return, 0, 0, 0, 0)
	builder_end_function(&caller_builder)
	builder_begin_function(&callee_builder, v.symbol_intern("spin"), 0, 1, true)
	builder_emit(&callee_builder, .Jump, 0, 0, -1, 0)
	builder_end_function(&callee_builder)
	caller := builder_build(&caller_builder, alloc)
	callee := builder_build(&callee_builder, alloc)
	testing.expect_value(t, program_validate(caller), Program_Error.None)
	testing.expect_value(t, program_validate(callee), Program_Error.None)
	for mode in 0 ..< 3 {
		state: VM
		vm_init(&state, caller, alloc)
		vm_frames_push(&state, Frame{function = 0, ip = 1, register_base = 0, caller_dst = -1})
		vm_select_program(&state, callee)
		vm_frames_push(&state, Frame{function = 0, ip = 0, register_base = 2, caller_dst = 0})
		vm_registers_open(&state, 3)
		append(&state.handlers, Handler{kind = .Catch, frame = 0, target = 1, error_register = 1})
		if mode == 0 {
			vm_set_deadline(&state, time.Nanosecond)
			state.deadline = time.tick_add(time.tick_now(), -time.Second)
			state.deadline_countdown = 1
		} else {
			vm_set_instruction_budget(&state, 1)
			state.instruction_budget_exhausted = mode == 2
		}
		status := vm_run(&state)
		if mode == 0 {
			testing.expect_value(t, status, VM_Status.Halted)
			testing.expect_value(t, state.result, must_int(42))
		} else {
			testing.expect_value(t, status, VM_Status.Failed)
			error, ok := v.value_as_error(state.error)
			if testing.expect(t, ok) {
				name, _ := v.symbol_name(error.code)
				testing.expect_value(t, name, "E_BUDGET")
			}
		}
		testing.expect(t, state.program == caller)
		vm_destroy(&state)
	}
}

@(test)
test_program_splice_dispatch_artifact :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)
	builder: Builder
	builder_init(&builder, alloc)
	defer builder_destroy(&builder)
	builder_begin_function(&builder, v.symbol_intern("call"), 0, 3, true)
	builder_emit(&builder, .Positional_Dispatch_Splice, 0, 0, 1, 2)
	builder_emit(&builder, .Return, 0, 0, 0, 0)
	builder_end_function(&builder)
	program := builder_build(&builder, alloc)
	testing.expect_value(t, program_validate(program), Program_Error.None)
	bytes: [dynamic]u8
	defer delete(bytes)
	testing.expect_value(t, program_to_bytes(program, &bytes), Artifact_Error.None)
	decoded, err := program_from_bytes(bytes[:], alloc)
	if !testing.expect_value(t, err, Artifact_Error.None) || decoded == nil {return}
	testing.expect_value(t, decoded.code[0].op, Op.Positional_Dispatch_Splice)
	testing.expect_value(t, program_validate(decoded), Program_Error.None)
	testing.expect(
		t,
		strings.contains(program_disassemble(decoded, alloc), "positional_dispatch_splice"),
	)
	valid := decoded.code[0]
	for operand in 0 ..< 3 {
		decoded.code[0] = valid
		switch operand {
		case 0:
			decoded.code[0].a = 3
		case 1:
			decoded.code[0].b = -1
		case 2:
			decoded.code[0].c = 3
		}
		testing.expect_value(t, program_validate(decoded), Program_Error.Bad_Register)
	}
}
