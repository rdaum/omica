// A Mica task: one VM instance over one transaction, run to a host boundary.
//
// The task model matches the Rust runtime: a task owns its VM and its
// transaction, commits at every host boundary, and reports one of three
// outcomes. Suspension commits and releases the transaction; resume begins a
// new one.
package mica_runtime

import "core:mem"
import k "../kernel"
import vm "../vm"
import v "../var"

Task_ID :: distinct u64

// Why a task stopped at a boundary.
Task_Suspend :: enum {
	None,
	Commit,
	Yield,
	Sleep,
	Host_Request,
	Spawn,
	Mailbox_Recv,
	External_Request,
}

Task_Outcome_Kind :: enum {
	Pending,
	Complete,
	Aborted,
}

Task_Outcome :: struct {
	kind:    Task_Outcome_Kind,
	value:   v.Value,
	error:   v.Value,
	message: string,
	suspend: Task_Suspend,
	millis:  i64,
	// The metadata supplied to a `read` suspension, zero when absent.
	request: v.Value,
	// An external request's service symbol and payload, zero unless `suspend`
	// is `.External_Request`.
	service: v.Value,
	payload: v.Value,
}

Task :: struct {
	id:                    Task_ID,
	kernel:                ^k.Kernel,
	program:               ^vm.Program,
	env:                   ^Builtin_Env,
	allocator:             mem.Allocator,
	state:                 vm.VM,
	tx:                    k.Transaction,
	source:                k.Relation_Source,
	has_tx:                bool,
	outcome:               Task_Outcome,

	// Policy-derived authority, minted at init when the environment enforces
	// it. Tasks without one run with root access.
	authority:             k.Authority,
	has_authority:         bool,

	// Set by the scheduler; a running task aborts at its next boundary.
	cancel_requested:      bool,

	// Task-owned effects staged until the current transaction commits and
	// discarded on abort (see #47).
	pending_sends:         [dynamic]Pending_Send,
	programs_changed:      bool,
	pending_subscriptions: [dynamic]^Subscription,
	pending_cancels:       [dynamic]v.Value,
}

// A mailbox send staged until the task commits.
Pending_Send :: struct {
	sender: v.Value,
	value:  v.Value,
}

// Creates a task over `kernel`. The caller owns `program` and `env` and must
// keep them alive for the task's lifetime.
task_init :: proc(
	task: ^Task,
	id: Task_ID,
	kernel: ^k.Kernel,
	program: ^vm.Program,
	env: ^Builtin_Env,
	allocator := context.allocator,
) {
	task.id = id
	task.kernel = kernel
	task.program = program
	task.env = env
	task.allocator = allocator
	task.outcome = Task_Outcome{kind = .Pending}
	vm.vm_init(&task.state, program, allocator)
	task.source = k.Relation_Source {
		use_stored_derived = true,
	}
	vm.vm_set_workspace(&task.state, &task.source, &task.tx)
	task.state.user = env
	if env != nil {
		vm.vm_set_identities(&task.state, env.endpoint, env.actor, env.principal)
	}
	vm.vm_set_mailbox_validator(&task.state, mailbox_receivers_live, env)
	register_runtime_builtins(&task.state)
	task.pending_sends = make([dynamic]Pending_Send, allocator)
	task.pending_subscriptions = make([dynamic]^Subscription, allocator)
	task.pending_cancels = make([dynamic]v.Value, allocator)
	task.state.owner = task
	if env != nil && env.enforce_authority {
		task_set_actor_authority(task, env.actor, allocator)
	}
	task_begin_tx(task)
}

// Mints the task's authority for `actor`, replacing any existing authority and
// updating the VM. Used at init and when a per-call actor overrides the world
// default.
task_set_actor_authority :: proc(task: ^Task, actor: v.Value, allocator: mem.Allocator) {
	identity, has_identity := v.value_as_identity(actor)
	if !has_identity {
		return
	}
	snapshot := k.kernel_snapshot(task.kernel)
	source := k.Relation_Source {
		kernel   = task.kernel,
		snapshot = snapshot,
	}
	authority := k.authority_from_actor(&source, identity, allocator)
	k.snapshot_release(snapshot)
	task_set_authority(task, authority)
}

// Replaces the task's authority, taking ownership of `authority`.
task_set_authority :: proc(task: ^Task, authority: k.Authority) {
	if task.has_authority {
		k.authority_destroy(&task.authority)
	}
	task.authority = authority
	task.has_authority = true
	vm.vm_set_authority(&task.state, &task.authority)
}

task_destroy :: proc(task: ^Task) {
	task_discard_tx(task)
	task_discard_pending(task)
	delete(task.pending_sends)
	delete(task.pending_subscriptions)
	delete(task.pending_cancels)
	if task.has_authority {
		k.authority_destroy(&task.authority)
	}
	vm.vm_destroy(&task.state)
}

// Returns the task owning `state`, or nil for a standalone VM.
@(private)
task_from_state :: proc(state: ^vm.VM) -> ^Task {
	if state == nil || state.owner == nil {
		return nil
	}
	return (^Task)(state.owner)
}

// Flushes staged task effects after a successful commit.
@(private)
task_flush_pending :: proc(task: ^Task) {
	if task.env != nil {
		if task.env.scheduler != nil {
			for pending in task.pending_sends {
				_ = scheduler_mailbox_send(task.env.scheduler, pending.sender, pending.value)
			}
		}
		for subscription in task.pending_subscriptions {
			subscriptions_activate(task.env, subscription)
		}
		for capability in task.pending_cancels {
			_ = subscriptions_cancel(task.env, capability)
		}
	}
	clear(&task.pending_sends)
	clear(&task.pending_subscriptions)
	clear(&task.pending_cancels)
}

// Discards staged task effects on abort.
@(private)
task_discard_pending :: proc(task: ^Task) {
	task_refresh_programs(task)
	if task.env != nil {
		for subscription in task.pending_subscriptions {
			subscriptions_discard(task.env, subscription)
		}
	}
	clear(&task.pending_sends)
	clear(&task.pending_subscriptions)
	clear(&task.pending_cancels)
}

@(private)
task_begin_tx :: proc(task: ^Task) {
	task.tx = k.kernel_begin(task.kernel)
	task.source.transaction = &task.tx
	task.has_tx = true
}

@(private)
task_end_tx :: proc(task: ^Task) {
	if !task.has_tx {
		return
	}
	k.transaction_destroy(&task.tx)
	task.has_tx = false
	task.source.transaction = nil
}

@(private)
task_discard_tx :: proc(task: ^Task) {
	task_end_tx(task)
}

@(private)
task_commit :: proc(task: ^Task) -> k.Kernel_Error {
	if !task.has_tx {
		return k.Kernel_Error.None
	}
	committed, err := k.transaction_commit(&task.tx)
	if err != k.Kernel_Error.None {
		return err
	}
	k.snapshot_release(committed)
	task_flush_pending(task)
	task_refresh_programs(task)
	if task.env != nil {
		subscriptions_dispatch(task.env)
	}
	return k.Kernel_Error.None
}

@(private)
task_abort :: proc(task: ^Task, message: string) -> Task_Outcome {
	task_discard_tx(task)
	task_discard_pending(task)
	task.outcome = Task_Outcome {
		kind    = .Aborted,
		error   = v.value_deep_copy(task.allocator, task.state.error),
		message = message,
	}
	return task.outcome
}

// Runs the task until it completes, aborts, or suspends.
task_run :: proc(task: ^Task) -> Task_Outcome {
	for {
		if task.cancel_requested {
			return task_abort(task, "cancelled")
		}
		status := vm.vm_run(&task.state)
		switch status {
		case .Halted:
			if err := task_commit(task); err != k.Kernel_Error.None {
				return task_abort(task, "commit failed")
			}
			task_end_tx(task)
			task.outcome = Task_Outcome {
				kind  = .Complete,
				value = v.value_deep_copy(task.allocator, task.state.result),
			}
			return task.outcome

		case .Failed:
			return task_abort(task, "task failed")

		case .Boundary:
			switch task.state.request {
			case .Commit:
				if err := task_commit(task); err != k.Kernel_Error.None {
					return task_abort(task, "commit failed")
				}
				task_end_tx(task)
				task_begin_tx(task)
				task.state.request = .None

			case .Yield, .Sleep, .Spawn, .Host_Request, .Mailbox_Recv, .External_Request:
				if err := task_commit(task); err != k.Kernel_Error.None {
					return task_abort(task, "commit failed")
				}
				suspend: Task_Suspend
				switch task.state.request {
				case .Yield:
					suspend = .Yield
				case .Sleep:
					suspend = .Sleep
				case .Spawn:
					suspend = .Spawn
				case .Host_Request:
					suspend = .Host_Request
				case .Mailbox_Recv:
					suspend = .Mailbox_Recv
				case .External_Request:
					suspend = .External_Request
				case .Commit, .None:
					suspend = .None
				}
				millis := task.state.request_millis
				request := v.Value(0)
				service := v.Value(0)
				payload := v.Value(0)
				if suspend == .Host_Request {
					request = task.state.request_value
				}
				if suspend == .External_Request {
					service = task.state.request_value
					payload = task.state.request_payload
				}
				task_end_tx(task)
				task.state.request = .None
				task.state.request_millis = 0
				task.outcome = Task_Outcome {
					kind    = .Pending,
					suspend = suspend,
					millis  = millis,
					request = request,
					service = service,
					payload = payload,
				}
				return task.outcome

			case .None:
				return task_abort(task, "unknown host request")
			}

		case .Ready:
			return task_abort(task, "vm did not run")
		}
	}
}

// Resumes a suspended task from its next boundary without delivering a value.
task_resume :: proc(task: ^Task) -> Task_Outcome {
	if task.outcome.kind != .Pending {
		return task.outcome
	}
	if !task.has_tx {
		task_begin_tx(task)
	}
	task.outcome.suspend = .None
	return task_run(task)
}

// Resumes a suspended task, delivering `value` to the register the suspended
// instruction named (a no-op when the instruction has no result register).
task_resume_with :: proc(task: ^Task, value: v.Value) -> Task_Outcome {
	if task.outcome.kind != .Pending {
		return task.outcome
	}
	if !task.has_tx {
		task_begin_tx(task)
	}
	vm.vm_resume_with(&task.state, value)
	task.outcome.suspend = .None
	return task_run(task)
}

// Reports whether any receiver in the list is a live mailbox handle.
@(private)
mailbox_receivers_live :: proc(user: rawptr, receivers: []v.Value) -> bool {
	env := (^Builtin_Env)(user)
	if env == nil || env.scheduler == nil {
		return true
	}
	for receiver in receivers {
		if scheduler_mailbox_handle_live(env.scheduler, receiver) {
			return true
		}
	}
	return false
}

// Fails a parked task with an error code and message.
task_fail :: proc(task: ^Task, code: string, message: string) -> Task_Outcome {
	vm.vm_set_error(&task.state, code, message)
	return task_abort(task, message)
}

// Requests cancellation. A parked task aborts immediately; a running task
// aborts at its next boundary.
task_cancel :: proc(task: ^Task) -> Task_Outcome {
	task.cancel_requested = true
	if task.outcome.kind != .Pending {
		return task.outcome
	}
	return task_abort(task, "cancelled")
}

@(private)
task_refresh_programs :: proc(task: ^Task) {
	if !task.programs_changed || task.env == nil || task.env.world == nil {return}
	snapshot := k.kernel_snapshot(task.kernel)
	source := k.Relation_Source {
		kernel   = task.kernel,
		snapshot = snapshot,
	}
	vm.program_registry_refresh(&task.env.world.programs, &source)
	k.snapshot_release(snapshot)
	task.programs_changed = false
}
