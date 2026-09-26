// Register virtual machine execution core.
//
// The VM runs a `Program` until the entry function returns or an operation
// fails. It executes one instruction at a time, with a frame stack and a flat
// register window per active call. Host boundaries such as commit, dispatch,
// and builtin calls are added on top of this core.
package vm

import k "../kernel"
import v "../var"
import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"

VM_Status :: enum {
	Ready,
	Halted,
	Failed,
	// The VM stopped at a host boundary; inspect `request`, act, and call
	// `vm_run` again to continue.
	Boundary,
}

// A request from the VM to its host.
VM_Request :: enum {
	None,
	// Commit the transaction and continue.
	Commit,
	// Suspend the task; it is runnable again immediately.
	Yield,
	// Suspend the task until at least `request_millis` have passed.
	Sleep,
	// Suspend the task and ask the host to start a child task described by
	// `request_spec`, then resume with the child's task id.
	Spawn,
	// Suspend the task and ask the host for a value.
	Host_Request,
	// Suspend the task until a message arrives on one of `request_value`'s
	// mailboxes, or until `request_millis` passes.
	Mailbox_Recv,
	// Suspend the task and ask the host to resolve `request_value` (a service
	// symbol) with `request_payload`.
	External_Request,
}

// A builtin procedure. It returns false after recording an error with
// `vm_set_error`.
Builtin_Proc :: proc(state: ^VM, args: []v.Value) -> (v.Value, bool)

VM_Builtin :: struct {
	name: v.Symbol,
	argc: int,
	run:  Builtin_Proc,
}

Frame :: struct {
	function:      int,
	ip:            int,
	register_base: int,
	caller_base:   int,
	caller_dst:    i32,
}

// A compiled exception handler: errors raised at or below `frame` jump to the
// absolute code offset `target` with the error delivered to `error_register`
// (-1 when the handler takes no value). A Finally handler also intercepts
// returns so the finally body runs before the frame is popped.
Handler_Kind :: enum {
	Catch,
	Finally,
}

Handler :: struct {
	frame:             int,
	target:            i32,
	error_register:    i32,
	kind:              Handler_Kind,
	// A catch-body finally routes exceptions through itself before they
	// propagate outward; a try-body finally only intercepts returns.
	routes_exceptions: bool,
}

// A return diverted through a finally body.
Pending_Return :: struct {
	frame: int,
	value: v.Value,
}

// An exception diverted through a finally body, re-raised when the finally
// body completes.
Pending_Raise :: struct {
	frame: int,
	error: v.Value,
}

VM :: struct {
	program:                      ^Program,
	allocator:                    mem.Allocator,
	registers:                    [dynamic]v.Value,
	frames:                       [dynamic]Frame,
	result:                       v.Value,
	error:                        v.Value,
	status:                       VM_Status,
	source:                       ^k.Relation_Source,
	transaction:                  ^k.Transaction,
	builtins:                     [dynamic]VM_Builtin,
	request:                      VM_Request,
	// Sleep duration in milliseconds when `request == .Sleep`, or the child
	// start delay when `request == .Spawn`.
	request_millis:               i64,
	// Dispatch spec index for a `.Spawn` request.
	request_spec:                 i32,
	// Primary request value: the receiver list for `.Mailbox_Recv`, or the
	// service symbol for `.External_Request`.
	request_value:                v.Value,
	// Secondary request value: the payload for `.External_Request`.
	request_payload:              v.Value,
	// Register (frame-relative) that receives the resume value.
	pending_resume:               i32,
	// Active exception handlers, innermost last.
	handlers:                     [dynamic]Handler,
	// Returns diverted through a finally body, innermost last.
	pending_returns:              [dynamic]Pending_Return,
	pending_raises:               [dynamic]Pending_Raise,
	// Execution limits. Zero means unlimited.
	max_call_depth:               int,
	instruction_budget:           u64,
	// The budget as configured, restored by `vm_reset`. Without it a reset
	// after a run that consumed the budget would leave zero, which means
	// unlimited, silently disabling the limit.
	configured_budget:            u64,
	// Set once the budget reaches zero, so a caught E_BUDGET cannot silently
	// turn the exhausted budget (0) into "unlimited".
	instruction_budget_exhausted: bool,
	// Wall-clock deadline, checked every `DEADLINE_CHECK_INTERVAL`
	// instructions. A program whose work is dominated by per-instruction host
	// calls (relation writes, for one) can burn little instruction budget per
	// second, so a deadline bounds it when the budget would trip only after
	// minutes. `has_deadline` false means unlimited.
	deadline:                     time.Tick,
	has_deadline:                 bool,
	// Counts instructions down to the next deadline check.
	deadline_countdown:           u32,
	// Runtime context identities: endpoint, actor, and principal.
	endpoint:                     v.Value,
	actor:                        v.Value,
	principal:                    v.Value,
	// Task authority. Nil means root access.
	authority:                    ^k.Authority,
	// Optional validator run before a Mailbox_Recv suspends, so an invalid
	// receiver fails inside the interpreter and can be caught.
	mailbox_validator:            proc(user: rawptr, receivers: []v.Value) -> bool,
	mailbox_validator_user:       rawptr,
	// Free slot for host data, for example a builtin environment.
	user:                         rawptr,
	// Values copied into the entry function's parameter registers before the
	// first run. The caller keeps them alive.
	entry_arguments:              []v.Value,
	// When non-negative, the function index to start at instead of the program
	// entry. Used to start spawned method tasks.
	entry_function:               i32,
	// The owning task, when the VM runs as part of one. Used by task-scoped
	// builtins to stage effects until the task commits.
	owner:                        rawptr,
	// VM-local scratch arena for per-instruction temporaries. Reset at the top
	// of each instruction so a long-running task does not grow the thread's
	// temp arena without bound.
	scratch:                      ^virtual.Arena,
	scratch_allocator:            mem.Allocator,
	// Builtin dispatch table: program builtin index -> VM_Builtin index, or -1
	// when the name is not registered. Resolved once at init so a builtin call
	// does not scan the registration list.
	builtin_index:                []int,
}

vm_init :: proc(state: ^VM, program: ^Program, allocator := context.allocator) {
	state.program = program
	state.allocator = allocator
	state.registers = make([dynamic]v.Value)
	state.frames = make([dynamic]Frame)
	state.builtins = make([dynamic]VM_Builtin)
	state.request = .None
	state.request_spec = -1
	state.request_value = v.Value(0)
	state.request_payload = v.Value(0)
	state.pending_resume = -1
	state.max_call_depth = DEFAULT_MAX_CALL_DEPTH
	state.entry_function = -1
	state.handlers = make([dynamic]Handler)
	state.pending_returns = make([dynamic]Pending_Return)
	state.pending_raises = make([dynamic]Pending_Raise)
	state.result = v.value_empty_relation()
	state.error = v.value_empty_relation()
	state.status = .Ready
	state.scratch = new(virtual.Arena, allocator)
	if init_error := virtual.arena_init_growing(state.scratch); init_error != nil {
		panic("failed to initialize VM scratch arena")
	}
	state.scratch_allocator = virtual.arena_allocator(state.scratch)
}

// Returns the VM to a runnable state so the same program can run again,
// reusing the register, frame, and handler buffers and the scratch arena.
// Configuration set through the `vm_set_*` calls (authority, workspace,
// identities, entry overrides, limits) is preserved; only per-run state is
// cleared.
//
// A benchmark that repeats a program must call this between runs: `vm_run`
// returns immediately on a halted or failed VM, and re-initializing the VM
// instead allocates several dynamic arrays and a fresh arena per iteration.
vm_reset :: proc(state: ^VM) {
	clear(&state.registers)
	clear(&state.frames)
	clear(&state.handlers)
	clear(&state.pending_returns)
	clear(&state.pending_raises)
	state.result = v.value_empty_relation()
	state.error = v.value_empty_relation()
	state.status = .Ready
	state.request = .None
	state.request_spec = -1
	state.request_value = v.Value(0)
	state.request_payload = v.Value(0)
	state.request_millis = 0
	state.pending_resume = -1
	state.instruction_budget = state.configured_budget
	state.instruction_budget_exhausted = false
	// The deadline is an absolute wall-clock limit set by the caller, so a
	// reset only rearms the check interval, not the limit itself.
	if state.has_deadline {
		state.deadline_countdown = DEADLINE_CHECK_INTERVAL
	}
	if state.scratch != nil {
		virtual.arena_free_all(state.scratch)
	}
}

vm_destroy :: proc(state: ^VM) {
	delete(state.pending_returns)
	delete(state.pending_raises)
	delete(state.handlers)
	delete(state.registers)
	delete(state.frames)
	delete(state.builtins)
	if state.scratch != nil {
		virtual.arena_destroy(state.scratch)
		free(state.scratch, state.allocator)
		state.scratch = nil
	}
	delete(state.builtin_index, state.allocator)
	state.builtin_index = nil
}

// --- Stack growth ----------------------------------------------------------
//
// The register and frame arrays are flat stacks whose length is the current
// top. `resize` and `append` funnel through the generic dynamic-array runtime,
// a call plus a zero fill per operation; a call/return pair does that twice
// per call. These helpers set the length through the same type-erased layout
// the runtime's built-ins use, grow capacity geometrically, and leave zero
// fills to the caller. They are the only raw layout access in the VM.

// Opens the register stack to `needed` entries. Entries the call does not
// write must be zeroed by the caller (see `vm_zero_locals`).
@(private)
vm_registers_open :: #force_inline proc(state: ^VM, needed: int) {
	if needed > cap(state.registers) {
		reserve(&state.registers, max(needed, cap(state.registers) * 2 + 16))
	}
	(^runtime.Raw_Dynamic_Array)(&state.registers).len = needed
}

// Drops the register stack back to `length` entries. Shrinking never needs a
// zero fill: entries above the top are stale until the next open, which writes
// or zeroes them.
@(private)
vm_registers_close :: #force_inline proc(state: ^VM, length: int) {
	assert(length <= len(state.registers))
	(^runtime.Raw_Dynamic_Array)(&state.registers).len = length
}

// Zeroes the registers a callee's binding does not write: the locals after its
// parameters. `param_base` is where binding started and `param_count` how many
// registers it wrote. Compiler-sized frames measure worse with a scalar store
// loop than with the memset it replaced, and one- or two-register tails measure
// worse with a call to memset, so small tails use stores and large ones a
// bulk zero.
@(private)
vm_zero_locals :: #force_inline proc(
	state: ^VM,
	param_base: int,
	param_count: int,
	register_count: int,
) {
	first := param_base + param_count
	count := register_count - first
	if count <= 0 {
		return
	}
	// Small tails are cheaper as stores; a bulk zero is a libc memset call for
	// larger ones, which wins once the tail is more than a few registers.
	if count <= 8 {
		for index in first ..< register_count {
			state.registers[index] = v.Value(0)
		}
	} else {
		intrinsics.mem_zero(raw_data(state.registers[first:]), count * size_of(v.Value))
	}
}

@(private)
vm_frames_push :: #force_inline proc(state: ^VM, frame: Frame) {
	if len(state.frames) >= cap(state.frames) {
		reserve(&state.frames, max(8, len(state.frames) * 2))
	}
	raw := (^runtime.Raw_Dynamic_Array)(&state.frames)
	([^]Frame)(raw.data)[raw.len] = frame
	raw.len += 1
}

@(private)
vm_frames_pop :: #force_inline proc(state: ^VM) -> Frame {
	raw := (^runtime.Raw_Dynamic_Array)(&state.frames)
	assert(raw.len > 0)
	frame := ([^]Frame)(raw.data)[raw.len - 1]
	raw.len -= 1
	return frame
}

// Drops frames above `length`, mirroring a run of pops.
@(private)
vm_frames_close :: #force_inline proc(state: ^VM, length: int) {
	assert(length <= len(state.frames))
	(^runtime.Raw_Dynamic_Array)(&state.frames).len = length
}

// Writes a resume value into the register the suspended instruction named.
// Does nothing when the suspension has no destination.
vm_resume_with :: proc(state: ^VM, value: v.Value) {
	if state.pending_resume < 0 || len(state.frames) == 0 {
		return
	}
	frame := state.frames[len(state.frames) - 1]
	state.registers[frame.register_base + int(state.pending_resume)] = value
	state.pending_resume = -1
}

// Default nesting limit for call frames.
DEFAULT_MAX_CALL_DEPTH :: 1024

// Limits the number of nested call frames. Zero means unlimited.
vm_set_max_call_depth :: proc(state: ^VM, depth: int) {
	state.max_call_depth = depth
}

// Limits how many instructions the VM may execute before failing. The budget
// is not reset by boundaries. Zero means unlimited; exceeding a positive budget
// fails even if the task catches `E_BUDGET`.
vm_set_instruction_budget :: proc(state: ^VM, budget: u64) {
	state.instruction_budget = budget
	state.configured_budget = budget
	state.instruction_budget_exhausted = false
}

// How often the run loop checks the wall-clock deadline, in instructions. The
// check is a clock read, so it is amortized: coarse enough not to matter for
// throughput, fine enough to stop a runaway program promptly.
DEADLINE_CHECK_INTERVAL :: u32(1 << 16)

// Limits how long the VM may run. A run still executing when the limit
// elapses fails with `E_DEADLINE`. A zero limit means unlimited.
vm_set_deadline :: proc(state: ^VM, limit: time.Duration) {
	if limit <= 0 {
		state.has_deadline = false
		state.deadline = time.Tick{}
		return
	}
	state.deadline = time.tick_add(time.tick_now(), limit)
	state.has_deadline = true
	state.deadline_countdown = DEADLINE_CHECK_INTERVAL
}

// Sets the authority used for permission checks. Nil means root access.
vm_set_authority :: proc(state: ^VM, authority: ^k.Authority) {
	state.authority = authority
	if state.source != nil {
		state.source.authority = authority
	}
}

// Sets the runtime context identities returned by `endpoint`, `actor`, and
// `principal`.
vm_set_identities :: proc(state: ^VM, endpoint: v.Value, actor: v.Value, principal: v.Value) {
	state.endpoint = endpoint
	state.actor = actor
	state.principal = principal
}

// Registers a validator for mailbox receiver lists. It returns false when no
// receiver is a live mailbox handle.
vm_set_mailbox_validator :: proc(
	state: ^VM,
	validator: proc(user: rawptr, receivers: []v.Value) -> bool,
	user: rawptr,
) {
	state.mailbox_validator = validator
	state.mailbox_validator_user = user
}

// Starts execution at `function_index` instead of the program entry.
vm_set_entry_function :: proc(state: ^VM, function_index: i32) {
	state.entry_function = function_index
}

// Seeds the entry function's parameter registers.
vm_set_entry_arguments :: proc(state: ^VM, arguments: []v.Value) {
	state.entry_arguments = arguments
}

// Returns the frame-relative register base of the suspended frame.
vm_frame_base :: proc(state: ^VM) -> int {
	if len(state.frames) == 0 {
		return 0
	}
	return state.frames[len(state.frames) - 1].register_base
}

// Registers a builtin procedure under `name`. Returns its index.
vm_register_builtin :: proc(state: ^VM, name: v.Symbol, argc: int, run: Builtin_Proc) -> int {
	append(&state.builtins, VM_Builtin{name = name, argc = argc, run = run})
	return len(state.builtins) - 1
}

// Resolves every program builtin name to a `state.builtins` index once. Builtin
// calls then index directly instead of scanning the registration list. Call
// after all builtins are registered; vm_builtin_call also calls it lazily.
vm_resolve_builtins :: proc(state: ^VM) {
	delete(state.builtin_index, state.allocator)
	program := state.program
	if program == nil || len(program.builtins) == 0 {
		state.builtin_index = nil
		return
	}
	table := make([]int, len(program.builtins), state.allocator)
	for name, index in program.builtins {
		table[index] = -1
		for builtin, builtin_index in state.builtins {
			if builtin.name == name {
				table[index] = builtin_index
				break
			}
		}
	}
	state.builtin_index = table
}

// Sets the relation read source and write transaction for relation
// instructions. Either may be nil when the program does not use them.
vm_set_workspace :: proc(state: ^VM, source: ^k.Relation_Source, transaction: ^k.Transaction) {
	state.source = source
	state.transaction = transaction
	if source != nil {
		source.authority = state.authority
	}
}

// Runs the program from its entry function until it returns. Read
// `state.result` on success and `state.error` on failure.
vm_run :: proc(state: ^VM) -> VM_Status {
	if state.status == .Boundary {
		state.status = .Ready
		state.request = .None
		state.request_spec = -1
		state.request_value = v.Value(0)
		state.request_payload = v.Value(0)
	}
	if state.status != .Ready {
		return state.status
	}
	if state.authority != nil {
		epoch: u64 = 0
		if state.transaction != nil {
			epoch = state.transaction.base.version
		}
		k.authority_set_clock(state.authority, epoch, time.tick_now())
	}

	program := state.program
	if len(state.frames) == 0 {
		entry := program.entry
		if state.entry_function >= 0 {
			entry = int(state.entry_function)
		}
		// A hand-built program or a bogus entry override must fail cleanly,
		// not index past the function table. Compiler output always passes
		// program_validate before running.
		if entry < 0 || entry >= len(program.functions) {
			vm_fail(state, "E_VM_FAULT", "entry function out of range")
			return .Failed
		}
		entry_function := program.functions[entry]
		vm_frames_push(
			state,
			Frame {
				function = entry,
				ip = entry_function.code_offset,
				register_base = 0,
				caller_base = 0,
				caller_dst = -1,
			},
		)
		vm_registers_open(state, entry_function.register_count)
		vm_zero_locals(state, 0, 0, entry_function.register_count)
		if len(state.entry_arguments) > len(state.registers) {
			vm_fail(state, "E_VM_FAULT", "too many entry arguments")
			return .Failed
		}
		for argument, index in state.entry_arguments {
			state.registers[index] = argument
		}
	}

	for {
		// Per-instruction temporaries live in the VM scratch arena. Reclaim
		// them only when the arena was actually used: freeing unconditionally
		// takes an arena mutex and zeroes memory on every instruction, which
		// dominated simple integer loops.
		if state.scratch.total_used > 0 {
			virtual.arena_free_all(state.scratch)
		}
		top := len(state.frames) - 1
		// `frames` is non-empty here (the entry frame is pushed above and
		// Return pops only while frames remain) and `top` is derived from its
		// length, so this access cannot be out of bounds. Avoid the copy of
		// the whole frame and the repeated bounds-checked indexing.
		#no_bounds_check frame := &state.frames[top]
		if frame.ip < 0 || frame.ip >= len(program.code) {
			vm_fail(state, "E_VM_FAULT", "instruction pointer out of range")
			return .Failed
		}

		// Check the wall-clock deadline every `DEADLINE_CHECK_INTERVAL`
		// instructions: a clock read per instruction would cost more than the
		// limit is worth, and a runaway loop only needs to be caught promptly,
		// not exactly.
		if state.has_deadline {
			state.deadline_countdown -= 1
			if state.deadline_countdown == 0 {
				state.deadline_countdown = DEADLINE_CHECK_INTERVAL
				if time.tick_since(state.deadline) > 0 {
					vm_fail(state, "E_DEADLINE", "wall-clock deadline exceeded")
					if vm_unwind(state) {
						continue
					}
					return .Failed
				}
			}
		}

		// A configured budget is the uncommon case, so test the stable
		// enabled flag once. Inside it the live count can be zero, which is
		// when the budget is exhausted rather than disabled.
		if state.configured_budget != 0 {
			if state.instruction_budget_exhausted {
				vm_fail(state, "E_BUDGET", "instruction budget exhausted")
				if vm_unwind(state) {
					continue
				}
				return .Failed
			}
			state.instruction_budget -= 1
			if state.instruction_budget == 0 {
				state.instruction_budget_exhausted = true
				vm_fail(state, "E_BUDGET", "instruction budget exhausted")
				if vm_unwind(state) {
					continue
				}
				return .Failed
			}
		}

		// The range check above already proved the index valid.
		#no_bounds_check instr := program.code[frame.ip]
		frame.ip += 1
		base := frame.register_base

		switch instr.op {
		case .Load_Const:
			state.registers[base + int(instr.a)] = program.constants[instr.b]

		case .Move:
			state.registers[base + int(instr.a)] = state.registers[base + int(instr.b)]

		case .Binary:
			left := state.registers[base + int(instr.b)]
			right := state.registers[base + int(instr.c)]
			// Inline the packed-int case so the common arithmetic path does not
			// call the large general helper; anything it does not handle falls
			// through to vm_binary.
			if v.value_tag(left) == .Int && v.value_tag(right) == .Int {
				match := true
				switch Bin_Op(instr.flags) {
				case .Add:
					l := v.value_int_unchecked(left)
					r := v.value_int_unchecked(right)
					sum, overflow := intrinsics.overflow_add(l, r)
					if !overflow && sum >= v.INT_MIN && sum <= v.INT_MAX {
						state.registers[base + int(instr.a)] = v.value_int_unchecked_pack(sum)
					} else {
						match = false
					}
				case .Sub:
					l := v.value_int_unchecked(left)
					r := v.value_int_unchecked(right)
					diff, overflow := intrinsics.overflow_sub(l, r)
					if !overflow && diff >= v.INT_MIN && diff <= v.INT_MAX {
						state.registers[base + int(instr.a)] = v.value_int_unchecked_pack(diff)
					} else {
						match = false
					}
				case .Mul:
					l := v.value_int_unchecked(left)
					r := v.value_int_unchecked(right)
					product, overflow := intrinsics.overflow_mul(l, r)
					if !overflow && product >= v.INT_MIN && product <= v.INT_MAX {
						state.registers[base + int(instr.a)] = v.value_int_unchecked_pack(product)
					} else {
						match = false
					}
				case .Lt:
					state.registers[base + int(instr.a)] = v.value_bool(
						v.value_int_unchecked(left) < v.value_int_unchecked(right),
					)
				case .Le:
					state.registers[base + int(instr.a)] = v.value_bool(
						v.value_int_unchecked(left) <= v.value_int_unchecked(right),
					)
				case .Gt:
					state.registers[base + int(instr.a)] = v.value_bool(
						v.value_int_unchecked(left) > v.value_int_unchecked(right),
					)
				case .Ge:
					state.registers[base + int(instr.a)] = v.value_bool(
						v.value_int_unchecked(left) >= v.value_int_unchecked(right),
					)
				case .Eq:
					state.registers[base + int(instr.a)] = v.value_bool(
						v.value_int_unchecked(left) == v.value_int_unchecked(right),
					)
				case .Ne:
					state.registers[base + int(instr.a)] = v.value_bool(
						v.value_int_unchecked(left) != v.value_int_unchecked(right),
					)
				case .Div:
					l := v.value_int_unchecked(left)
					r := v.value_int_unchecked(right)
					if r != 0 && l % r == 0 {
						state.registers[base + int(instr.a)] = v.value_int_unchecked_pack(l / r)
					} else {
						match = false
					}
				case .Rem:
					l := v.value_int_unchecked(left)
					r := v.value_int_unchecked(right)
					if r != 0 {
						state.registers[base + int(instr.a)] = v.value_int_unchecked_pack(l % r)
					} else {
						match = false
					}
				case:
					match = false
				}
				if match {
					break
				}
			} else if v.value_tag(left) == .Float && v.value_tag(right) == .Float {
				// Float operands: decode both and apply the operation on raw
				// f32 bits, checking finiteness of the result. Arithmetic that
				// overflows to inf/nan raises E_ARITH, so a non-finite result
				// falls through to the general helper (which reports it).
				// `done` marks a comparison, which writes its own result and
				// needs no finiteness check; `match` marks an arithmetic op
				// whose result must be finite.
				done := false
				match := true
				l := v.value_float_unchecked(left)
				r := v.value_float_unchecked(right)
				result := f32(0)
				switch Bin_Op(instr.flags) {
				case .Add:
					result = l + r
				case .Sub:
					result = l - r
				case .Mul:
					result = l * r
				case .Div:
					if r == 0 {
						match = false
					} else {
						result = l / r
					}
				case .Rem:
					if r == 0 {
						match = false
					} else {
						result = l - math.trunc(l / r) * r
					}
				case .Lt:
					state.registers[base + int(instr.a)] = v.value_bool(l < r)
					done = true
				case .Le:
					state.registers[base + int(instr.a)] = v.value_bool(l <= r)
					done = true
				case .Gt:
					state.registers[base + int(instr.a)] = v.value_bool(l > r)
					done = true
				case .Ge:
					state.registers[base + int(instr.a)] = v.value_bool(l >= r)
					done = true
				case .Eq:
					state.registers[base + int(instr.a)] = v.value_bool(l == r)
					done = true
				case .Ne:
					state.registers[base + int(instr.a)] = v.value_bool(l != r)
					done = true
				case:
					match = false
				}
				if done {
					break
				}
				if match && v.float_is_finite(result) {
					state.registers[base + int(instr.a)] = v.value_float_unchecked_pack(result)
					break
				}
			}
			if !vm_binary(state, base, instr) {
				break
			}

		case .Unary:
			if !vm_unary(state, base, instr) {
				break
			}

		case .Branch:
			if vm_truthy(state.registers[base + int(instr.a)]) {
				frame.ip += int(instr.b)
			}

		case .Jump:
			frame.ip += int(instr.b)

		case .Call:
			if vm_depth_exceeded(state) {
				break
			}
			callee := &program.functions[instr.b]
			argument_count := int(instr.flags)
			callee_base := len(state.registers)
			callee_top := callee_base + callee.register_count
			vm_registers_open(state, callee_top)
			// Bind from the caller's register window directly: materializing
			// an args slice allocated from scratch memory and copied it on
			// every call, and the common case is a straight register copy.
			if !vm_bind_params_range(
				state,
				callee,
				base + int(instr.c),
				argument_count,
				callee_base,
			) {
				break
			}
			vm_zero_locals(state, callee_base, callee.param_count, callee_top)
			vm_frames_push(
				state,
				Frame {
					function = int(instr.b),
					ip = callee.code_offset,
					register_base = callee_base,
					caller_base = base,
					caller_dst = instr.a,
				},
			)

		case .Return:
			value := state.registers[base + int(instr.a)]
			// A frame with no active handlers and no diverted return or raise
			// is the common case; skip both scans entirely.
			if len(state.handlers) > 0 {
				if handler_index := vm_finally_handler(state, top); handler_index >= 0 {
					handler := state.handlers[handler_index]
					ordered_remove(&state.handlers, handler_index)
					append(&state.pending_returns, Pending_Return{frame = top, value = value})
					state.frames[top].ip = int(handler.target)
					break
				}
			}
			if len(state.handlers) > 0 ||
			   len(state.pending_returns) > 0 ||
			   len(state.pending_raises) > 0 {
				vm_remove_frame_handlers(state, top)
			}
			returned := vm_frames_pop(state)
			vm_registers_close(state, base)
			if len(state.frames) == 0 {
				state.result = value
				state.status = .Halted
				return .Halted
			}
			caller := state.frames[len(state.frames) - 1]
			state.registers[caller.register_base + int(returned.caller_dst)] = value

		case .Build_List:
			count := int(instr.c)
			items := make([]v.Value, count, state.scratch_allocator)
			for index in 0 ..< count {
				items[index] = state.registers[base + int(instr.b) + index]
			}
			state.registers[base + int(instr.a)] = v.value_list(state.allocator, items)

		case .Build_Map:
			count := int(instr.c)
			entries := make([]v.Map_Entry, count, state.scratch_allocator)
			for index in 0 ..< count {
				entries[index] = v.Map_Entry {
					key   = state.registers[base + int(instr.b) + index * 2],
					value = state.registers[base + int(instr.b) + index * 2 + 1],
				}
			}
			state.registers[base + int(instr.a)] = v.value_map(state.allocator, entries)

		case .Build_Range:
			has_end := (instr.flags & 1) != 0
			start := state.registers[base + int(instr.b)]
			end := state.registers[base + int(instr.c)]
			state.registers[base + int(instr.a)] = v.value_range(
				state.allocator,
				start,
				end,
				has_end,
			)

		case .Len:
			collection := state.registers[base + int(instr.b)]
			length: int
			length_ok: bool
			#partial switch v.value_kind(collection) {
			case .List:
				values, ok := v.value_as_list(collection)
				if ok {
					length = len(values)
					length_ok = true
				}
			case .Map:
				entries, ok := v.value_as_map(collection)
				if ok {
					length = len(entries)
					length_ok = true
				}
			case .Relation:
				relation, ok := v.value_as_relation(collection)
				if ok {
					length = len(relation.rows)
					length_ok = true
				}
			case .String:
				count, ok := v.string_scalar_count(collection)
				if ok {
					length = count
					length_ok = true
				}
			case:
			}
			if !length_ok {
				vm_fail(state, "E_TYPE", "len expects a list, map, relation, or string")
				break
			}
			length_value, length_ok_value := v.value_int(i64(length))
			if !length_ok_value {
				vm_fail(state, "E_RANGE", "length does not fit an integer")
				break
			}
			state.registers[base + int(instr.a)] = length_value

		case .Scan_Collect:
			if !vm_scan_collect(state, base, instr) {
				break
			}

		case .Scan_Exists:
			if !vm_scan_exists(state, base, instr) {
				break
			}

		case .Scan_First:
			if !vm_scan_first(state, base, instr) {
				break
			}

		case .Assert:
			if !vm_apply_write(state, base, instr, true) {
				break
			}

		case .Retract:
			if !vm_apply_write(state, base, instr, false) {
				break
			}

		case .Retract_Where:
			if !vm_retract_where(state, base, instr) {
				break
			}

		case .Build_Relation:
			if !vm_build_relation(state, base, instr) {
				break
			}

		case .Index:
			if !vm_index(state, base, instr) {
				break
			}

		case .Collection_Key_At:
			if !vm_collection_key_at(state, base, instr) {
				break
			}

		case .Collection_Value_At:
			if !vm_collection_value_at(state, base, instr) {
				break
			}

		case .Builtin_Call:
			if !vm_builtin_call(state, base, instr) {
				break
			}

		case .Commit:
			state.request = .Commit
			state.status = .Boundary
			return .Boundary

		case .Yield:
			state.pending_resume = instr.a
			state.request = .Yield
			state.status = .Boundary
			return .Boundary

		case .Sleep:
			millis, is_int := v.value_as_int(state.registers[base + int(instr.b)])
			if !is_int || millis < 0 {
				vm_fail(state, "E_TYPE", "sleep duration must be a non-negative integer")
				break
			}
			state.pending_resume = instr.a
			state.request = .Sleep
			state.request_millis = millis
			state.status = .Boundary
			return .Boundary

		case .Raise:
			state.error = vm_raised_error(state, base, instr)
			state.status = .Failed
			break

		case .Push_Handler:
			append(
				&state.handlers,
				Handler{frame = top, target = instr.a, error_register = instr.b},
			)

		case .Pop_Handler:
			if len(state.handlers) > 0 {
				pop(&state.handlers)
			}

		case .Spawn:
			delay_millis := i64(0)
			if instr.flags & 1 != 0 {
				millis, is_int := v.value_as_int(state.registers[base + int(instr.c)])
				if !is_int || millis < 0 {
					vm_fail(state, "E_TYPE", "spawn delay must be a non-negative integer")
					break
				}
				delay_millis = millis
			}
			state.pending_resume = instr.a
			state.request = .Spawn
			state.request_spec = instr.b
			state.request_millis = delay_millis
			state.status = .Boundary
			return .Boundary

		case .Mailbox_Recv:
			receivers := state.registers[base + int(instr.b)]
			receiver_list, is_list := v.value_as_list(receivers)
			if !is_list {
				vm_fail(state, "E_TYPE", "mailbox_recv expects a list of receivers")
				break
			}
			if state.mailbox_validator != nil &&
			   !state.mailbox_validator(state.mailbox_validator_user, receiver_list) {
				vm_fail(state, "E_INVARG", "mailbox has no live receivers")
				break
			}
			timeout_millis := i64(-1)
			if instr.flags & 1 != 0 {
				millis, is_int := v.value_as_int(state.registers[base + int(instr.c)])
				if !is_int || millis < 0 {
					vm_fail(state, "E_TYPE", "mailbox_recv timeout must be a non-negative integer")
					break
				}
				timeout_millis = millis
			}
			state.pending_resume = instr.a
			state.request = .Mailbox_Recv
			state.request_value = receivers
			state.request_millis = timeout_millis
			state.status = .Boundary
			return .Boundary

		case .External_Request:
			if !k.authority_can_effect(state.authority) {
				vm_fail(state, "E_PERMISSION", "effect denied")
				break
			}
			service := state.registers[base + int(instr.b)]
			if _, is_symbol := v.value_as_symbol(service); !is_symbol {
				vm_fail(state, "E_TYPE", "external_request expects a service symbol")
				break
			}
			state.pending_resume = instr.a
			state.request = .External_Request
			state.request_value = service
			state.request_payload = state.registers[base + int(instr.c)]
			state.status = .Boundary
			return .Boundary

		case .Read:
			state.pending_resume = instr.a
			state.request = .Host_Request
			if instr.b >= 0 {
				state.request_value = state.registers[base + int(instr.b)]
			} else {
				state.request_value = v.Value(0)
			}
			state.request_millis = 0
			state.status = .Boundary
			return .Boundary

		case .Make_Self_Function:
			capture_count := int(instr.flags)
			if capture_count == 0 {
				vm_fail(state, "E_VM_FAULT", "self function needs a capture slot")
				break
			}
			captures := make([]v.Value, capture_count, state.allocator)
			for index in 0 ..< capture_count {
				captures[index] = state.registers[base + int(instr.c) + index]
			}
			captures[capture_count - 1] = v.Value(0)
			sync.mutex_lock(&program.callables_mutex)
			callable_id := i32(len(program.callables))
			append(&program.callables, Callable_Info{function = instr.b, captures = captures})
			value, value_ok := v.value_function_raw(u64(callable_id))
			if value_ok {
				program.callables[int(callable_id)].captures[capture_count - 1] = value
			}
			sync.mutex_unlock(&program.callables_mutex)
			if !value_ok {
				vm_fail(state, "E_TYPE", "callable index is out of range")
				break
			}
			state.registers[base + int(instr.a)] = value

		case .Make_Function:
			if instr.b < 0 || int(instr.b) >= len(program.functions) {
				vm_fail(state, "E_TYPE", "function index is out of range")
				break
			}
			capture_count := int(instr.flags)
			captures := make([]v.Value, capture_count, state.allocator)
			for index in 0 ..< capture_count {
				captures[index] = state.registers[base + int(instr.c) + index]
			}
			callable_id := vm_intern_callable(state, instr.b, captures)
			function, function_ok := v.value_function_raw(u64(callable_id))
			if !function_ok {
				vm_fail(state, "E_TYPE", "callable index is out of range")
				break
			}
			state.registers[base + int(instr.a)] = function

		case .Call_Value:
			if vm_depth_exceeded(state) {
				break
			}
			target := state.registers[base + int(instr.b)]
			function_id, is_function := v.value_as_function(target)
			if !is_function {
				vm_fail(state, "E_TYPE", "call target is not a function")
				break
			}
			callable, callable_ok := vm_resolve_callable(state, function_id)
			if !callable_ok {
				vm_fail(state, "E_DISPATCH", "callable index is invalid")
				break
			}
			function_index := int(callable.function)
			if function_index < 0 || function_index >= len(program.functions) {
				vm_fail(state, "E_DISPATCH", "function index is invalid")
				break
			}
			callee := &program.functions[function_index]
			capture_count := len(callable.captures)
			argument_count := int(instr.flags)
			args := make([]v.Value, argument_count, state.scratch_allocator)
			for index in 0 ..< argument_count {
				args[index] = state.registers[base + int(instr.c) + index]
			}
			callee_base := len(state.registers)
			callee_top := callee_base + callee.register_count
			vm_registers_open(state, callee_top)
			for capture, index in callable.captures {
				state.registers[callee_base + index] = capture
			}
			if !vm_bind_params(state, callee, args, callee_base + capture_count) {
				break
			}
			vm_zero_locals(state, callee_base + capture_count, callee.param_count, callee_top)
			vm_frames_push(
				state,
				Frame {
					function = function_index,
					ip = callee.code_offset,
					register_base = callee_base,
					caller_base = base,
					caller_dst = instr.a,
				},
			)

		case .Call_Splice:
			if vm_depth_exceeded(state) {
				break
			}
			args, args_ok := vm_list_args(state, base, instr.c)
			if !args_ok {
				break
			}
			if instr.b < 0 || int(instr.b) >= len(program.functions) {
				vm_fail(state, "E_DISPATCH", "function index is invalid")
				break
			}
			callee := &program.functions[instr.b]
			callee_base := len(state.registers)
			callee_top := callee_base + callee.register_count
			vm_registers_open(state, callee_top)
			if !vm_bind_params(state, callee, args, callee_base) {
				break
			}
			vm_zero_locals(state, callee_base, callee.param_count, callee_top)
			vm_frames_push(
				state,
				Frame {
					function = int(instr.b),
					ip = callee.code_offset,
					register_base = callee_base,
					caller_base = base,
					caller_dst = instr.a,
				},
			)

		case .Builtin_Call_Splice:
			args, args_ok := vm_list_args(state, base, instr.c)
			if !args_ok {
				break
			}
			if instr.b < 0 || int(instr.b) >= len(program.builtins) {
				vm_fail(state, "E_UNKNOWN_BUILTIN", "builtin is not registered")
				break
			}
			name := program.builtins[instr.b]
			if !vm_builtin_allowed(state, name) {
				vm_fail(state, "E_PERMISSION", "builtin invoke denied")
				break
			}
			matched := false
			for builtin in state.builtins {
				if builtin.name != name {
					continue
				}
				result, builtin_ok := builtin.run(state, args)
				if !builtin_ok {
					if state.error == v.value_empty_relation() {
						vm_fail(state, "E_BUILTIN", "builtin failed")
					}
					break
				}
				state.registers[base + int(instr.a)] = result
				matched = true
				break
			}
			if !matched && state.error == v.value_empty_relation() {
				vm_fail(state, "E_UNKNOWN_BUILTIN", "builtin is not registered")
			}

		case .Call_Value_Splice:
			if vm_depth_exceeded(state) {
				break
			}
			target := state.registers[base + int(instr.b)]
			function_id, is_function := v.value_as_function(target)
			if !is_function {
				vm_fail(state, "E_TYPE", "call target is not a function")
				break
			}
			callable, callable_ok := vm_resolve_callable(state, function_id)
			if !callable_ok {
				vm_fail(state, "E_DISPATCH", "callable index is invalid")
				break
			}
			function_index := int(callable.function)
			if function_index < 0 || function_index >= len(program.functions) {
				vm_fail(state, "E_DISPATCH", "function index is invalid")
				break
			}
			args, args_ok := vm_list_args(state, base, instr.c)
			if !args_ok {
				break
			}
			callee := &program.functions[function_index]
			capture_count := len(callable.captures)
			callee_base := len(state.registers)
			callee_top := callee_base + callee.register_count
			vm_registers_open(state, callee_top)
			for capture, index in callable.captures {
				state.registers[callee_base + index] = capture
			}
			if !vm_bind_params(state, callee, args, callee_base + capture_count) {
				break
			}
			vm_zero_locals(state, callee_base + capture_count, callee.param_count, callee_top)
			vm_frames_push(
				state,
				Frame {
					function = function_index,
					ip = callee.code_offset,
					register_base = callee_base,
					caller_base = base,
					caller_dst = instr.a,
				},
			)

		case .Push_Finally:
			append(
				&state.handlers,
				Handler {
					frame = top,
					target = instr.a,
					error_register = -1,
					kind = .Finally,
					routes_exceptions = instr.flags & 1 != 0,
				},
			)

		case .Resume_Return:
			if len(state.pending_raises) > 0 &&
			   state.pending_raises[len(state.pending_raises) - 1].frame == top {
				// An exception diverted through this finally: re-raise it.
				pending := pop(&state.pending_raises)
				state.error = pending.error
				state.status = .Failed
				break
			}
			if len(state.pending_returns) > 0 &&
			   state.pending_returns[len(state.pending_returns) - 1].frame == top {
				pending := state.pending_returns[len(state.pending_returns) - 1]
				if handler_index := vm_finally_handler(state, top); handler_index >= 0 {
					handler := state.handlers[handler_index]
					ordered_remove(&state.handlers, handler_index)
					state.frames[top].ip = int(handler.target)
					break
				}
				pop(&state.pending_returns)
				vm_remove_frame_handlers(state, top)
				returned := vm_frames_pop(state)
				vm_registers_close(state, base)
				if len(state.frames) == 0 {
					state.result = pending.value
					state.status = .Halted
					return .Halted
				}
				caller := state.frames[len(state.frames) - 1]
				state.registers[caller.register_base + int(returned.caller_dst)] = pending.value
			}

		case .Is_Truthy:
			truthy := vm_truthy(state.registers[base + int(instr.b)])
			state.registers[base + int(instr.a)] = v.value_bool(truthy)

		case .Scan_One:
			if !vm_scan_one(state, base, instr) {
				break
			}

		case .Dispatch:
			if !vm_dispatch(state, base, instr) {
				break
			}

		case .Dynamic_Dispatch:
			if !vm_dynamic_dispatch(state, base, instr) {
				break
			}

		case .Positional_Dispatch:
			if !vm_positional_dispatch(state, base, instr) {
				break
			}
		}

		if state.status == .Failed {
			if vm_unwind(state) {
				continue
			}
			return .Failed
		}
	}
}

// Returns the index of the innermost Finally handler for `frame`, or -1.
@(private)
vm_finally_handler :: proc(state: ^VM, frame: int) -> int {
	for index := len(state.handlers) - 1; index >= 0; index -= 1 {
		handler := state.handlers[index]
		if handler.frame == frame && handler.kind == .Finally {
			return index
		}
	}
	return -1
}

// Retires every handler (and pending return) owned by `frame` when its call
// frame is popped. Without this, a handler left behind by an early return can
// be found by a later unwind at the same depth and use the wrong register
// window.
@(private)
vm_remove_frame_handlers :: proc(state: ^VM, frame: int) {
	// Most returns retire no handler at all; the three scans below are only
	// worth starting when there is something to retire.
	if len(state.handlers) == 0 &&
	   len(state.pending_returns) == 0 &&
	   len(state.pending_raises) == 0 {
		return
	}
	write := 0
	for handler in state.handlers {
		if handler.frame == frame {
			continue
		}
		state.handlers[write] = handler
		write += 1
	}
	if write != len(state.handlers) {
		resize(&state.handlers, write)
	}
	pending_write := 0
	for pending in state.pending_returns {
		if pending.frame == frame {
			continue
		}
		state.pending_returns[pending_write] = pending
		pending_write += 1
	}
	if pending_write != len(state.pending_returns) {
		resize(&state.pending_returns, pending_write)
	}
	raise_write := 0
	for pending in state.pending_raises {
		if pending.frame == frame {
			continue
		}
		state.pending_raises[raise_write] = pending
		raise_write += 1
	}
	if raise_write != len(state.pending_raises) {
		resize(&state.pending_raises, raise_write)
	}
}

// Transfers control to the innermost handler. Returns false when no handler
// exists and the error must escape the VM.
@(private)
vm_unwind :: proc(state: ^VM) -> bool {
	if len(state.handlers) == 0 {
		return false
	}
	handler_index := -1
	handler_is_finally := false
	for index := len(state.handlers) - 1; index >= 0; index -= 1 {
		handler := state.handlers[index]
		if handler.kind == .Catch || (handler.kind == .Finally && handler.routes_exceptions) {
			handler_index = index
			handler_is_finally = handler.kind == .Finally
			break
		}
	}
	if handler_index < 0 {
		return false
	}
	handler := state.handlers[handler_index]
	resize(&state.handlers, handler_index)
	for len(state.pending_returns) > 0 &&
	    state.pending_returns[len(state.pending_returns) - 1].frame >= handler.frame {
		pop(&state.pending_returns)
	}
	if handler.frame >= len(state.frames) {
		return false
	}
	vm_frames_close(state, handler.frame + 1)
	frame := state.frames[handler.frame]
	state.frames[handler.frame].ip = int(handler.target)
	// Drop the dead frames' registers, mirroring Return: only the handler
	// frame's window stays live. Without this, errors caught in a loop grow
	// the register file on every iteration.
	if frame.function >= 0 && frame.function < len(state.program.functions) {
		function := state.program.functions[frame.function]
		if frame.register_base + function.register_count < len(state.registers) {
			vm_registers_close(state, frame.register_base + function.register_count)
		}
	}
	if handler_is_finally {
		// Run the finally body, then re-raise the error when it completes.
		append(&state.pending_raises, Pending_Raise{frame = handler.frame, error = state.error})
		state.status = .Ready
		return true
	}
	if handler.error_register >= 0 {
		state.registers[frame.register_base + int(handler.error_register)] = state.error
	}
	state.status = .Ready
	return true
}

@(private)
vm_build_relation :: proc(state: ^VM, base: int, instr: Instruction) -> bool {
	shape := state.program.relation_shapes[instr.b]
	values := make([]v.Value, len(shape.heading), state.scratch_allocator)
	for index in 0 ..< len(values) {
		values[index] = state.registers[base + int(instr.c) + index]
	}
	row := v.tuple_new(state.allocator, values)
	result, err := v.value_relation(state.allocator, shape.heading, []v.Tuple{row})
	if err != .None {
		vm_fail(state, "E_RELATION", "relation heading is invalid")
		return false
	}
	state.registers[base + int(instr.a)] = result
	return true
}

@(private)
vm_collection_key_at :: proc(state: ^VM, base: int, instr: Instruction) -> bool {
	collection := state.registers[base + int(instr.b)]
	index, is_int := v.value_as_int(state.registers[base + int(instr.c)])
	if !is_int || index < 0 {
		vm_fail(state, "E_TYPE", "collection index is not a non-negative integer")
		return false
	}

	#partial switch v.value_kind(collection) {
	case .List:
		values, _ := v.value_as_list(collection)
		if int(index) >= len(values) {
			vm_fail(state, "E_INDEX", "collection index out of range")
			return false
		}
		result, _ := v.value_int(index)
		state.registers[base + int(instr.a)] = result

	case .Map:
		entries, _ := v.value_as_map(collection)
		if int(index) >= len(entries) {
			vm_fail(state, "E_INDEX", "collection index out of range")
			return false
		}
		state.registers[base + int(instr.a)] = entries[index].key

	case .Relation:
		relation, _ := v.value_as_relation(collection)
		if int(index) >= len(relation.rows) {
			vm_fail(state, "E_INDEX", "collection index out of range")
			return false
		}
		result, _ := v.value_int(index)
		state.registers[base + int(instr.a)] = result

	case .String:
		count, _ := v.string_scalar_count(collection)
		if int(index) >= count {
			vm_fail(state, "E_INDEX", "collection index out of range")
			return false
		}
		result, _ := v.value_int(index)
		state.registers[base + int(instr.a)] = result

	case:
		vm_fail(state, "E_TYPE", "collection key iteration needs a list, map, relation, or string")
		return false
	}
	return true
}

@(private)
vm_collection_value_at :: proc(state: ^VM, base: int, instr: Instruction) -> bool {
	collection := state.registers[base + int(instr.b)]
	index, is_int := v.value_as_int(state.registers[base + int(instr.c)])
	if !is_int || index < 0 {
		vm_fail(state, "E_TYPE", "collection index is not a non-negative integer")
		return false
	}

	#partial switch v.value_kind(collection) {
	case .List:
		values, _ := v.value_as_list(collection)
		if int(index) >= len(values) {
			vm_fail(state, "E_INDEX", "collection index out of range")
			return false
		}
		state.registers[base + int(instr.a)] = values[index]

	case .Map:
		entries, _ := v.value_as_map(collection)
		if int(index) >= len(entries) {
			vm_fail(state, "E_INDEX", "collection index out of range")
			return false
		}
		state.registers[base + int(instr.a)] = entries[index].value

	case .Relation:
		relation, _ := v.value_as_relation(collection)
		if int(index) >= len(relation.rows) {
			vm_fail(state, "E_INDEX", "collection index out of range")
			return false
		}
		row := v.tuple_values(relation.rows[index])
		entries := make([]v.Map_Entry, len(relation.heading), state.scratch_allocator)
		for column, column_index in relation.heading {
			entries[column_index] = v.Map_Entry {
				key   = v.value_symbol(column),
				value = row[column_index],
			}
		}
		state.registers[base + int(instr.a)] = v.value_map(state.allocator, entries)

	case .String:
		scalar, found := v.string_scalar_at(collection, int(index))
		if !found {
			vm_fail(state, "E_INDEX", "collection index out of range")
			return false
		}
		result, _ := v.value_int(i64(scalar))
		state.registers[base + int(instr.a)] = result

	case:
		vm_fail(
			state,
			"E_TYPE",
			"collection value iteration needs a list, map, relation, or string",
		)
		return false
	}
	return true
}

@(private)
vm_index :: proc(state: ^VM, base: int, instr: Instruction) -> bool {
	collection := state.registers[base + int(instr.b)]
	key := state.registers[base + int(instr.c)]
	result: v.Value

	#partial switch v.value_kind(collection) {
	case .List:
		index, is_int := v.value_as_int(key)
		if !is_int {
			vm_fail(state, "E_TYPE", "list index is not an integer")
			return false
		}
		values, _ := v.value_as_list(collection)
		if index < 0 || int(index) >= len(values) {
			vm_fail(state, "E_INDEX", "list index out of range")
			return false
		}
		result = values[index]

	case .String:
		// A scalar position, not a byte: strings are sequences of Unicode
		// scalar values. The value is an integer, which is what a scanner
		// compares and classifies.
		index, is_int := v.value_as_int(key)
		if !is_int {
			vm_fail(state, "E_TYPE", "string index is not an integer")
			return false
		}
		scalar, found := v.string_scalar_at(collection, int(index))
		if !found {
			vm_fail(state, "E_INDEX", "string index out of range")
			return false
		}
		result, _ = v.value_int(i64(scalar))

	case .Map:
		entries, _ := v.value_as_map(collection)
		// Probe with a cheap exact-key comparison first: for the common key
		// kinds (symbols, ints, strings, identities) equality is a tag plus a
		// payload/bytes comparison, which avoids the recursive canonical
		// comparison the binary search comparator performs per probe. Fall
		// back to the canonical comparison only for keys it cannot answer.
		index, found := v.map_entry_index(entries, key)
		if !found {
			vm_fail(state, "E_KEY", "map key is not present")
			return false
		}
		result = entries[index].value

	case .Relation:
		relation, _ := v.value_as_relation(collection)

		if row_index, is_int := v.value_as_int(key); is_int {
			if row_index < 0 || int(row_index) >= len(relation.rows) {
				vm_fail(state, "E_INDEX", "relation row index out of range")
				return false
			}
			row := relation.rows[row_index]
			entries := make([]v.Map_Entry, len(relation.heading), state.scratch_allocator)
			for column, index in relation.heading {
				entries[index] = v.Map_Entry {
					key   = v.value_symbol(column),
					value = v.tuple_values(row)[index],
				}
			}
			state.registers[base + int(instr.a)] = v.value_map(state.allocator, entries)
			return true
		}

		symbol, is_symbol := v.value_as_symbol(key)
		if !is_symbol {
			vm_fail(state, "E_TYPE", "relation column key is not a symbol")
			return false
		}
		position := -1
		for column, index in relation.heading {
			if column == symbol {
				position = index
				break
			}
		}
		if position < 0 {
			vm_fail(state, "E_KEY", "relation column is not present")
			return false
		}
		if len(relation.rows) == 0 {
			result = v.value_list(state.allocator, nil)
		} else if len(relation.rows) == 1 {
			result = v.tuple_values(relation.rows[0])[position]
		} else {
			cells := make([]v.Value, len(relation.rows), state.scratch_allocator)
			for row, index in relation.rows {
				cells[index] = v.tuple_values(row)[position]
			}
			result = v.value_list(state.allocator, cells)
		}

	case:
		vm_fail(state, "E_TYPE", "index expects a list, map, relation, or string")
		return false
	}

	state.registers[base + int(instr.a)] = result
	return true
}

@(private)
vm_builtin_call :: proc(state: ^VM, base: int, instr: Instruction) -> bool {
	name := state.program.builtins[instr.b]
	if !vm_builtin_allowed(state, name) {
		vm_fail(state, "E_PERMISSION", "builtin invoke denied")
		return false
	}
	// The index table is built at init; build it lazily if a host registered
	// builtins after init (the table is stale only until the next call).
	if state.builtin_index == nil && len(state.program.builtins) > 0 {
		vm_resolve_builtins(state)
	}
	builtin_index := -1
	if instr.b >= 0 && int(instr.b) < len(state.builtin_index) {
		builtin_index = state.builtin_index[instr.b]
	}
	if builtin_index >= 0 && builtin_index < len(state.builtins) {
		builtin := state.builtins[builtin_index]
		argc := builtin.argc
		if argc < 0 {
			argc = int(instr.flags)
		}
		args := make([]v.Value, argc, state.scratch_allocator)
		for index in 0 ..< argc {
			args[index] = state.registers[base + int(instr.c) + index]
		}
		result, ok := builtin.run(state, args)
		if !ok {
			if state.error == v.value_empty_relation() {
				vm_fail(state, "E_BUILTIN", "builtin failed")
			}
			return false
		}
		state.registers[base + int(instr.a)] = result
		return true
	}
	vm_fail(state, "E_UNKNOWN_BUILTIN", "builtin is not registered")
	return false
}

@(private)
vm_pattern_bindings :: proc(
	state: ^VM,
	base: int,
	pattern: Scan_Pattern,
	alloc: mem.Allocator,
) -> []v.Binding {
	bindings := make([]v.Binding, len(pattern.cells), alloc)
	for cell, index in pattern.cells {
		switch cell.kind {
		case .Const:
			bindings[index] = v.binding_of(state.program.constants[cell.operand])
		case .Bind:
			bindings[index] = v.binding_of(state.registers[base + int(cell.operand)])
		case .Output, .Wildcard:
		}
	}
	return bindings
}

@(private)
// Resolves a scan pattern's relation to a kernel id. A nonzero `relation` is
// already resolved. A zero id resolves `relation_name` against the live
// snapshot, which lets an assembled artifact name its relations rather than
// bake ids that vary between worlds.
vm_resolve_pattern_relation :: proc(state: ^VM, pattern: Scan_Pattern) -> (k.Relation_ID, bool) {
	if pattern.relation != 0 {
		return k.Relation_ID(pattern.relation), true
	}
	metadata: k.Relation_Metadata
	found: bool
	if state.source.transaction != nil {
		metadata, found = k.transaction_relation_metadata_named(state.source.transaction, pattern.relation_name)
	} else if state.source.snapshot != nil {
		metadata, found = k.snapshot_relation_metadata_named(state.source.snapshot, pattern.relation_name)
	} else {
		vm_fail(state, "E_NO_SOURCE", "relation scan has no source to resolve a name")
		return 0, false
	}

	if !found {
		name, _ := v.symbol_name(pattern.relation_name)
		vm_fail(
			state,
			"E_UNKNOWN_RELATION",
			fmt.aprintf(
				"relation scan names an unknown relation: %s",
				name,
				allocator = context.temp_allocator,
			),
		)
		return 0, false
	}
	return metadata.id, true
}

@(private)
vm_scan_rows :: proc(
	state: ^VM,
	base: int,
	pattern: Scan_Pattern,
	out: ^[dynamic]v.Tuple,
) -> bool {
	if state.source == nil {
		vm_fail(state, "E_NO_SOURCE", "relation scan has no source")
		return false
	}
	relation, resolved := vm_resolve_pattern_relation(state, pattern)
	if !resolved {
		return false
	}
	if !k.authority_can_read(state.authority, relation) {
		vm_fail(state, "E_PERMISSION", "relation read denied")
		return false
	}
	bindings := vm_pattern_bindings(state, base, pattern, state.scratch_allocator)
	state.source.error = .None
	k.relation_source_scan_into(state.source, relation, bindings, out)
	if state.source.error != .None {
		vm_fail(state, kernel_error_code(state.source.error), "computed relation scan failed")
		return false
	}
	return true
}

@(private)
vm_scan_collect :: proc(state: ^VM, base: int, instr: Instruction) -> bool {
	pattern := state.program.patterns[instr.b]
	rows: [dynamic]v.Tuple
	defer delete(rows)
	if !vm_scan_rows(state, base, pattern, &rows) {
		return false
	}
	// Only named query variables are result columns; bound values and
	// wildcards participate in matching but do not appear in the heading.
	output_count := 0
	for cell in pattern.cells {
		if cell.kind == .Output {
			output_count += 1
		}
	}
	result: v.Value
	if output_count == len(pattern.cells) {
		converted, err := v.value_relation(state.allocator, pattern.column_names, rows[:])
		if err != .None {
			vm_fail(state, "E_RELATION", "scan result columns are invalid")
			return false
		}
		result = converted
	} else {
		heading := make([]v.Symbol, output_count, state.scratch_allocator)
		positions := make([]u16, output_count, state.scratch_allocator)
		write := 0
		for cell, index in pattern.cells {
			if cell.kind == .Output {
				heading[write] = pattern.column_names[index]
				positions[write] = u16(index)
				write += 1
			}
		}
		projected := make([]v.Tuple, len(rows), state.scratch_allocator)
		for row, index in rows {
			projected[index] = v.tuple_select(row, state.allocator, positions)
		}
		converted, err := v.value_relation(state.allocator, heading, projected)
		if err != .None {
			vm_fail(state, "E_RELATION", "scan result columns are invalid")
			return false
		}
		result = converted
	}
	state.registers[base + int(instr.a)] = result
	return true
}

@(private)
First_Binding_Context :: struct {
	vm:      ^VM,
	base:    int,
	pattern: ^Scan_Pattern,
	found:   bool,
}

@(private)
first_binding_visit :: proc(user: rawptr, row: v.Tuple) -> bool {
	ctx := (^First_Binding_Context)(user)
	for cell, index in ctx.pattern.cells {
		if cell.kind == .Output {
			ctx.vm.registers[ctx.base + int(cell.operand)] = v.tuple_values(row)[index]
		}
	}
	ctx.found = true
	return false
}

@(private)
vm_scan_first :: proc(state: ^VM, base: int, instr: Instruction) -> bool {
	if state.source == nil {
		vm_fail(state, "E_NO_SOURCE", "relation scan has no source")
		return false
	}
	pattern := state.program.patterns[instr.b]
	relation, resolved := vm_resolve_pattern_relation(state, pattern)
	if !resolved {
		return false
	}
	if !k.authority_can_read(state.authority, relation) {
		vm_fail(state, "E_PERMISSION", "relation read denied")
		return false
	}
	bindings := vm_pattern_bindings(state, base, pattern, state.scratch_allocator)
	ctx := First_Binding_Context {
		vm      = state,
		base    = base,
		pattern = &pattern,
	}
	state.source.error = .None
	k.relation_source_visit(state.source, relation, bindings, first_binding_visit, &ctx)
	if state.source.error != .None {
		vm_fail(state, kernel_error_code(state.source.error), "computed relation scan failed")
		return false
	}
	state.registers[base + int(instr.a)] = v.value_bool(ctx.found)
	return true
}

@(private)
vm_scan_exists :: proc(state: ^VM, base: int, instr: Instruction) -> bool {
	pattern := state.program.patterns[instr.b]
	rows: [dynamic]v.Tuple
	defer delete(rows)
	if !vm_scan_rows(state, base, pattern, &rows) {
		return false
	}
	state.registers[base + int(instr.a)] = v.value_bool(len(rows) > 0)
	return true
}

@(private)
vm_scan_one :: proc(state: ^VM, base: int, instr: Instruction) -> bool {
	pattern := state.program.patterns[instr.b]
	rows: [dynamic]v.Tuple
	defer delete(rows)
	if !vm_scan_rows(state, base, pattern, &rows) {
		return false
	}
	if len(rows) != 1 {
		vm_fail(state, "E_ONE", "exactly one row is required")
		return false
	}
	for cell, index in pattern.cells {
		if cell.kind == .Output {
			state.registers[base + int(cell.operand)] = v.tuple_values(rows[0])[index]
		}
	}
	state.registers[base + int(instr.a)] = v.value_bool(true)
	return true
}

@(private)
vm_apply_write :: proc(state: ^VM, base: int, instr: Instruction, assert_write: bool) -> bool {
	if state.transaction == nil {
		vm_fail(state, "E_NO_TRANSACTION", "relation write has no transaction")
		return false
	}
	value := state.registers[base + int(instr.b)]
	relation, ok := v.value_as_relation(value)
	if !ok || len(relation.rows) != 1 {
		vm_fail(state, "E_TYPE", "relation write expects a single-row relation value")
		return false
	}
	tuple := relation.rows[0]
	relation_id := k.Relation_ID(u32(instr.a))
	if !k.authority_can_write(state.authority, relation_id) {
		vm_fail(state, "E_PERMISSION", "relation write denied")
		return false
	}
	err: k.Kernel_Error
	if assert_write {
		err = k.transaction_assert(state.transaction, relation_id, tuple)
	} else {
		err = k.transaction_retract(state.transaction, relation_id, tuple)
	}
	if err != .None {
		vm_fail(state, kernel_error_code(err), "relation write failed")
		return false
	}
	return true
}

@(private)
vm_dispatch :: proc(state: ^VM, base: int, instr: Instruction) -> bool {
	program := state.program
	spec := program.dispatch_specs[instr.b]
	selector := v.value_symbol(spec.selector)
	roles := make([]k.Role_Pair, len(spec.roles), state.scratch_allocator)
	for role, index in spec.roles {
		roles[index] = k.Role_Pair {
			role  = v.value_symbol(role.role),
			value = state.registers[base + int(role.register)],
		}
	}
	return vm_dispatch_call(state, base, instr.a, selector, roles)
}

// Resolves a method for `selector` with `roles` and calls its function in this
// program. The destination register receives the method's return value.
@(private)
vm_dispatch_call :: proc(
	state: ^VM,
	base: int,
	destination: i32,
	selector: v.Value,
	roles: []k.Role_Pair,
) -> bool {
	program := state.program
	if state.source == nil {
		vm_fail(state, "E_NO_SOURCE", "dispatch has no relation source")
		return false
	}
	if program.dispatch_method_selector_relation == 0 ||
	   program.dispatch_param_relation == 0 ||
	   program.dispatch_delegates_relation == 0 ||
	   program.dispatch_method_program_relation == 0 {
		vm_fail(state, "E_DISPATCH", "dispatch relations are not configured")
		return false
	}

	relations := k.Dispatch_Relations {
		method_selector = k.Relation_ID(program.dispatch_method_selector_relation),
		param           = k.Relation_ID(program.dispatch_param_relation),
		delegates       = k.Relation_ID(program.dispatch_delegates_relation),
	}
	all_entries := k.applicable_method_entries(
		state.source,
		relations,
		selector,
		roles,
		state.scratch_allocator,
	)
	if len(all_entries) == 0 {
		vm_fail(state, "E_DISPATCH", "no applicable method")
		return false
	}
	selector_symbol, _ := v.value_as_symbol(selector)
	entries: [dynamic]k.Applicable_Method
	defer delete(entries)
	for entry in all_entries {
		if k.authority_can_invoke_method(state.authority, entry.method) ||
		   k.authority_can_invoke_selector(state.authority, selector_symbol) {
			append(&entries, entry)
		}
	}
	if len(entries) == 0 {
		vm_fail(state, "E_PERMISSION", "method invoke denied")
		return false
	}
	if len(entries) > 1 {
		vm_fail(state, "E_DISPATCH", "ambiguous method dispatch")
		return false
	}
	entry := entries[0]
	args, args_ok := k.dispatch_method_args(entry.params, roles, state.scratch_allocator)
	if !args_ok {
		vm_fail(state, "E_DISPATCH", "method parameters cannot be bound")
		return false
	}
	return vm_call_dispatch_entry(state, base, destination, entry, args)
}

// Resolves the method's function index and calls it with `args`.
@(private)
vm_call_dispatch_entry :: proc(
	state: ^VM,
	base: int,
	destination: i32,
	entry: k.Applicable_Method,
	args: []v.Value,
) -> bool {
	program := state.program
	program_value, found := k.dispatch_method_program(
		state.source,
		k.Relation_ID(program.dispatch_method_program_relation),
		entry.method,
	)
	if !found {
		vm_fail(state, "E_DISPATCH", "method has no program")
		return false
	}
	function_index, is_int := v.value_as_int(program_value)
	if !is_int || function_index < 0 || int(function_index) >= len(program.functions) {
		vm_fail(state, "E_DISPATCH", "method program index is invalid")
		return false
	}
	return vm_call_function(state, base, destination, int(function_index), nil, args)
}

// Calls a program function from a dispatch site, binding `args` to its
// parameters.
@(private)
vm_call_function :: proc(
	state: ^VM,
	base: int,
	destination: i32,
	function_index: int,
	captures: []v.Value,
	args: []v.Value,
) -> bool {
	if vm_depth_exceeded(state) {
		return false
	}
	program := state.program
	callee := &program.functions[function_index]
	capture_count := len(captures)
	callee_base := len(state.registers)
	callee_top := callee_base + callee.register_count
	vm_registers_open(state, callee_top)
	for capture, index in captures {
		state.registers[callee_base + index] = capture
	}
	if !vm_bind_params(state, callee, args, callee_base + capture_count) {
		return false
	}
	vm_zero_locals(state, callee_base + capture_count, callee.param_count, callee_top)
	vm_frames_push(
		state,
		Frame {
			function = function_index,
			ip = callee.code_offset,
			register_base = callee_base,
			caller_base = base,
			caller_dst = destination,
		},
	)
	return true
}

@(private)
vm_positional_dispatch :: proc(state: ^VM, base: int, instr: Instruction) -> bool {
	program := state.program
	if state.source == nil {
		vm_fail(state, "E_NO_SOURCE", "dispatch has no relation source")
		return false
	}
	selector := state.registers[base + int(instr.b)]
	if _, is_symbol := v.value_as_symbol(selector); !is_symbol {
		vm_fail(state, "E_TYPE", "receiver dispatch selector is not a symbol")
		return false
	}
	argument_count := int(instr.flags)
	args := make([]v.Value, argument_count, state.scratch_allocator)
	for index in 0 ..< argument_count {
		args[index] = state.registers[base + int(instr.c) + index]
	}
	relations := k.Dispatch_Relations {
		method_selector = k.Relation_ID(program.dispatch_method_selector_relation),
		param           = k.Relation_ID(program.dispatch_param_relation),
		delegates       = k.Relation_ID(program.dispatch_delegates_relation),
	}
	all_entries := k.applicable_positional_method_entries(
		state.source,
		relations,
		selector,
		args,
		state.scratch_allocator,
	)
	if len(all_entries) == 0 {
		vm_fail(state, "E_DISPATCH", "no applicable method")
		return false
	}
	selector_symbol, _ := v.value_as_symbol(selector)
	entries: [dynamic]k.Applicable_Method
	defer delete(entries)
	for entry in all_entries {
		if k.authority_can_invoke_method(state.authority, entry.method) ||
		   k.authority_can_invoke_selector(state.authority, selector_symbol) {
			append(&entries, entry)
		}
	}
	if len(entries) == 0 {
		vm_fail(state, "E_PERMISSION", "method invoke denied")
		return false
	}
	if len(entries) > 1 {
		vm_fail(state, "E_DISPATCH", "ambiguous method dispatch")
		return false
	}
	return vm_call_dispatch_entry(state, base, instr.a, entries[0], args)
}

@(private)
vm_dynamic_dispatch :: proc(state: ^VM, base: int, instr: Instruction) -> bool {
	selector := state.registers[base + int(instr.b)]
	if _, is_symbol := v.value_as_symbol(selector); !is_symbol {
		vm_fail(state, "E_TYPE", "invoke selector is not a symbol")
		return false
	}
	entries, is_map := v.value_as_map(state.registers[base + int(instr.c)])
	if !is_map {
		vm_fail(state, "E_TYPE", "invoke roles are not a map")
		return false
	}
	roles := make([]k.Role_Pair, len(entries), state.scratch_allocator)
	for entry, index in entries {
		role, is_symbol := v.value_as_symbol(entry.key)
		if !is_symbol {
			vm_fail(state, "E_TYPE", "invoke role name is not a symbol")
			return false
		}
		roles[index] = k.Role_Pair {
			role  = v.value_symbol(role),
			value = entry.value,
		}
	}
	return vm_dispatch_call(state, base, instr.a, selector, roles)
}

@(private)
vm_retract_where :: proc(state: ^VM, base: int, instr: Instruction) -> bool {
	if state.transaction == nil {
		vm_fail(state, "E_NO_TRANSACTION", "relation write has no transaction")
		return false
	}
	pattern := state.program.patterns[instr.b]
	relation, resolved := vm_resolve_pattern_relation(state, pattern)
	if !resolved {
		return false
	}
	if !k.authority_can_write(state.authority, relation) {
		vm_fail(state, "E_PERMISSION", "relation write denied")
		return false
	}
	rows: [dynamic]v.Tuple
	defer delete(rows)
	if !vm_scan_rows(state, base, pattern, &rows) {
		return false
	}
	for row in rows {
		err := k.transaction_retract(state.transaction, relation, row)
		if err != .None {
			vm_fail(state, kernel_error_code(err), "relation retract failed")
			return false
		}
	}
	return true
}

@(private)
kernel_error_code :: proc(err: k.Kernel_Error) -> string {
	switch err {
	case .Unknown_Relation:
		return "E_UNKNOWN_RELATION"
	case .Arity_Mismatch:
		return "E_ARITY"
	case .Non_Persistent_Value:
		return "E_NOT_PERSISTENT"
	case .Functional_Key_Violation:
		return "E_FUNCTIONAL_KEY"
	case .Read_Only:
		return "E_READ_ONLY"
	case .Permission_Denied:
		return "E_PERMISSION"
	case .Computed_Binding_Required:
		return "E_DB"
	case .Already_Applied:
		return "E_STATE"
	case .Killed:
		return "E_KILLED"
	case .Conflict:
		return "E_CONFLICT"
	case .Overloaded:
		return "E_OVERLOADED"
	case .Duplicate_Relation_Name, .Invalid_Metadata:
		return "E_METADATA"
	case .No_Such_Rule,
	     .Unstratified_Negation,
	     .Unsafe_Negation,
	     .Unsafe_Guard,
	     .Unbound_Head_Variable:
		return "E_RULE"
	case .None:
		return "E_NONE"
	}
	return "E_KERNEL"
}

@(private)
vm_binary :: proc(state: ^VM, base: int, instr: Instruction) -> bool {
	left := state.registers[base + int(instr.b)]
	right := state.registers[base + int(instr.c)]
	op := Bin_Op(instr.flags)

	result: v.Value
	ok: bool
	switch op {
	case .Add:
		result, ok = v.value_checked_add(left, right)
	case .Sub:
		result, ok = v.value_checked_sub(left, right)
	case .Mul:
		result, ok = v.value_checked_mul(left, right)
	case .Div:
		result, ok = v.value_checked_div(left, right)
	case .Rem:
		result, ok = v.value_checked_rem(left, right)
	case .Eq:
		result = v.value_bool(v.language_numeric_eq(left, right))
		ok = true
	case .Ne:
		result = v.value_bool(!v.language_numeric_eq(left, right))
		ok = true
	case .Lt:
		result = v.value_bool(v.language_numeric_cmp(left, right) == .Less)
		ok = true
	case .Le:
		order := v.language_numeric_cmp(left, right)
		result = v.value_bool(order == .Less || order == .Equal)
		ok = true
	case .Gt:
		result = v.value_bool(v.language_numeric_cmp(left, right) == .Greater)
		ok = true
	case .Ge:
		order := v.language_numeric_cmp(left, right)
		result = v.value_bool(order == .Greater || order == .Equal)
		ok = true
	}

	if !ok {
		vm_arithmetic_fail(state, op, left, right)
		return false
	}
	state.registers[base + int(instr.a)] = result
	return true
}

// Records an arithmetic failure with the error code the language documents.
// A zero divisor in division or remainder raises E_DIV carrying the operands;
// mixing an integer and a float raises E_TYPE; every other failure, such as
// overflow or a non-finite float result, raises E_ARITH.
@(private)
vm_arithmetic_fail :: proc(state: ^VM, op: Bin_Op, left, right: v.Value) {
	code := "E_ARITH"
	message := "invalid arithmetic"
	#partial switch op {
	case .Div, .Rem:
		divisor_is_zero := false
		if divisor, ok := v.value_as_int(right); ok && divisor == 0 {
			divisor_is_zero = true
		}
		if divisor, ok := v.value_as_float(right); ok && divisor == 0 {
			divisor_is_zero = true
		}
		if divisor_is_zero {
			code = "E_DIV"
			message = op == .Div ? "division by zero" : "remainder by zero"
		}
	}
	left_is_int := v.value_kind(left) == .Int
	right_is_int := v.value_kind(right) == .Int
	left_is_numeric := left_is_int || v.value_kind(left) == .Float
	right_is_numeric := right_is_int || v.value_kind(right) == .Float
	if left_is_numeric && right_is_numeric && left_is_int != right_is_int {
		code = "E_TYPE"
		message = "numeric operands must have the same kind"
	}

	payload := v.value_list(state.allocator, []v.Value{left, right})
	state.error = v.value_error(
		state.allocator,
		v.symbol_intern(code),
		message,
		true,
		payload,
		true,
	)
	state.status = .Failed
}

// Truthiness used by conditions, `&&`, `||`, `!`, and `require`: false, an
// empty list, and an empty relation are falsy; everything else is truthy.
vm_truthy :: proc(value: v.Value) -> bool {
	#partial switch v.value_kind(value) {
	case .Bool:
		result, _ := v.value_as_bool(value)
		return result
	case .List:
		values, _ := v.value_as_list(value)
		return len(values) > 0
	case .Relation:
		relation, _ := v.value_as_relation(value)
		return len(relation.rows) > 0
	}
	return true
}

@(private)
vm_unary :: proc(state: ^VM, base: int, instr: Instruction) -> bool {
	source := state.registers[base + int(instr.b)]
	op := Un_Op(instr.flags)

	switch op {
	case .Neg:
		result, ok := v.value_checked_neg(source)
		if !ok {
			vm_fail(state, "E_ARITH", "invalid unary arithmetic")
			return false
		}
		state.registers[base + int(instr.a)] = result
	case .Not:
		state.registers[base + int(instr.a)] = v.value_bool(!vm_truthy(source))
	}
	return true
}

// Builds the error value for a Raise instruction, mirroring the Rust VM:
// raising an existing error merges its message and value.
@(private)
vm_raised_error :: proc(state: ^VM, base: int, instr: Instruction) -> v.Value {
	raised := state.registers[base + int(instr.a)]

	has_message := false
	message: string
	if instr.b >= 0 {
		text, is_string := v.value_as_string(state.registers[base + int(instr.b)])
		if !is_string {
			vm_fail(state, "E_TYPE", "raise message is not a string")
			return state.error
		}
		message = text
		has_message = true
	}
	has_value := instr.c >= 0
	value := v.Value(0)
	if has_value {
		value = state.registers[base + int(instr.c)]
	}

	if code, is_code := v.value_as_error_code(raised); is_code {
		return v.value_error(state.allocator, code, message, has_message, value, has_value)
	}
	if existing, is_error := v.value_as_error(raised); is_error {
		return v.value_error(
			state.allocator,
			existing.code,
			has_message ? message : existing.message,
			has_message || existing.has_message,
			has_value ? value : existing.value,
			has_value || existing.has_value,
		)
	}
	vm_fail(state, "E_TYPE", "raise expects an error code or error value")
	return state.error
}

// Fails the VM when the frame stack is at the configured call-depth limit.
// Inlined: every call opcode tests it and calls are hot.
@(private)
vm_depth_exceeded :: #force_inline proc(state: ^VM) -> bool {
	if state.max_call_depth > 0 && len(state.frames) >= state.max_call_depth {
		vm_fail(state, "E_DEPTH", "call depth exceeded")
		return true
	}
	return false
}

// The `none` value: an empty relation headed by `value`, matching the literal.
@(private)
vm_none_value :: proc(state: ^VM) -> v.Value {
	result, _ := v.value_relation(state.allocator, []v.Symbol{v.symbol_intern("value")}, nil)
	return result
}

// Binds call arguments into a callee's parameter registers, applying optional
// defaults and packing a rest parameter. `param_base` is the register where
// parameters start (after any captures).
// Binds parameters from a caller register range. Equivalent to collecting
// `count` values starting at `source_base` into a slice and calling
// `vm_bind_params`, without the slice or the copy for the common no-rest case.
//
// The common case supplies every non-rest parameter, so each one is a straight
// copy from the caller window and no default or empty-relation padding can
// apply. That case is a tight copy loop; only calls that omit optional
// parameters take the general path.
@(private)
vm_bind_params_range :: proc(
	state: ^VM,
	callee: ^Function,
	source_base: int,
	count: int,
	param_base: int,
) -> bool {
	program := state.program
	required := int(callee.required_count)
	non_rest := callee.param_count
	if callee.has_rest {
		non_rest -= 1
	}
	if count < required || (!callee.has_rest && count > non_rest) {
		vm_fail(state, "E_ARITY", "wrong number of arguments for function call")
		return false
	}
	// Every parameter is supplied, so no default or empty-relation padding can
	// apply: a straight copy. (Emitted programs always carry a defaults slice,
	// so testing it for nil would miss this path.)
	if count >= non_rest {
		registers := state.registers
		for index in 0 ..< non_rest {
			registers[param_base + index] = registers[source_base + index]
		}
	} else {
		for index in 0 ..< non_rest {
			value: v.Value
			if index < count {
				value = state.registers[source_base + index]
			} else if callee.defaults != nil &&
			   index < len(callee.defaults) &&
			   callee.defaults[index] >= 0 {
				value = program.constants[callee.defaults[index]]
			} else {
				value = vm_none_value(state)
			}
			state.registers[param_base + index] = value
		}
	}
	if callee.has_rest {
		rest_count := count - non_rest
		if rest_count < 0 {
			rest_count = 0
		}
		rest := make([]v.Value, rest_count, state.scratch_allocator)
		for index in 0 ..< rest_count {
			rest[index] = state.registers[source_base + non_rest + index]
		}
		state.registers[param_base + non_rest] = v.value_list(state.allocator, rest)
	}
	return true
}

@(private)
vm_bind_params :: proc(state: ^VM, callee: ^Function, args: []v.Value, param_base: int) -> bool {
	program := state.program
	required := int(callee.required_count)
	non_rest := callee.param_count
	if callee.has_rest {
		non_rest -= 1
	}
	if len(args) < required || (!callee.has_rest && len(args) > non_rest) {
		vm_fail(state, "E_ARITY", "wrong number of arguments for function call")
		return false
	}
	// Every parameter is supplied, so no default or empty-relation padding can
	// apply: a straight copy.
	if len(args) >= non_rest {
		registers := state.registers
		for index in 0 ..< non_rest {
			registers[param_base + index] = args[index]
		}
	} else {
		for index in 0 ..< non_rest {
			value: v.Value
			if index < len(args) {
				value = args[index]
			} else if callee.defaults != nil &&
			   index < len(callee.defaults) &&
			   callee.defaults[index] >= 0 {
				value = program.constants[callee.defaults[index]]
			} else {
				value = vm_none_value(state)
			}
			state.registers[param_base + index] = value
		}
	}
	if callee.has_rest {
		rest_count := len(args) - non_rest
		if rest_count < 0 {
			rest_count = 0
		}
		rest := make([]v.Value, rest_count, state.scratch_allocator)
		for index in 0 ..< rest_count {
			rest[index] = args[non_rest + index]
		}
		state.registers[param_base + non_rest] = v.value_list(state.allocator, rest)
	}
	return true
}

// Returns the list value in `register` as call arguments.
@(private)
vm_list_args :: proc(state: ^VM, base: int, register: i32) -> ([]v.Value, bool) {
	value := state.registers[base + int(register)]
	args, is_list := v.value_as_list(value)
	if !is_list {
		vm_fail(state, "E_TYPE", "spliced arguments must be a list")
		return nil, false
	}
	return args, true
}

// Internal builtins (`__` prefix) are always invocable; other builtins need an
// invoke grant when the task has a non-root authority.
@(private)
vm_builtin_allowed :: proc(state: ^VM, name: v.Symbol) -> bool {
	if state.authority == nil || state.authority.root {
		return true
	}
	text, _ := v.symbol_name(name)
	if strings.has_prefix(text, "__") {
		return true
	}
	if text == "emit" {
		return k.authority_can_effect(state.authority)
	}
	// Capability bootstrap: the capability builtins check their own authority.
	if text == "use_capability" ||
	   text == "mint_capability" ||
	   text == "restrict_capability" ||
	   text == "revoke_capability" ||
	   text == "drop_capability" {
		return true
	}
	return k.authority_can_invoke_builtin(state.authority, name)
}

// Resolves a function value to its callable, copying the info out under the
// program callable lock.
@(private)
vm_resolve_callable :: proc(state: ^VM, id: v.Function_ID) -> (Callable_Info, bool) {
	program := state.program
	index := int(v.function_id_raw(id))
	sync.mutex_lock(&program.callables_mutex)
	defer sync.mutex_unlock(&program.callables_mutex)
	if index < 0 || index >= len(program.callables) {
		return {}, false
	}
	return program.callables[index], true
}

// Interns a callable, reusing an existing entry with the same function and
// captured values. Takes ownership of `captures`.
@(private)
vm_intern_callable :: proc(state: ^VM, function: i32, captures: []v.Value) -> i32 {
	program := state.program
	sync.mutex_lock(&program.callables_mutex)
	defer sync.mutex_unlock(&program.callables_mutex)
	for callable, index in program.callables {
		if callable.function != function || len(callable.captures) != len(captures) {
			continue
		}
		matches := true
		for capture, capture_index in captures {
			if !v.value_eq(callable.captures[capture_index], capture) {
				matches = false
				break
			}
		}
		if matches {
			delete(captures)
			return i32(index)
		}
	}
	index := len(program.callables)
	append(&program.callables, Callable_Info{function = function, captures = captures})
	return i32(index)
}

// Records an error and marks the VM failed. Available to builtins.
vm_set_error :: proc(state: ^VM, code: string, message: string) {
	state.error = v.value_error(
		state.allocator,
		v.symbol_intern(code),
		message,
		true,
		v.Value(0),
		false,
	)
	state.status = .Failed
}

@(private)
vm_fail :: proc(state: ^VM, code: string, message: string) {
	vm_set_error(state, code, message)
}
