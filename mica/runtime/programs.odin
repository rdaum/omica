// The programs of a world.
//
// Each verb compiles to its own program, identified by its artifact id (the
// content address of its encoded bytes). MethodProgram facts name that id and
// ProgramBytes facts hold the bytes, one row per program. The registry maps
// ids to decoded programs for dispatch. Programs are immutable once added and
// live until the world is destroyed, so a resolved pointer never dangles, and
// every program shares one callable registry so function values cross
// programs.
package mica_runtime

import "core:fmt"
import "core:mem"
import "core:sync"
import c "../compiler"
import k "../kernel"
import v "../var"
import vm "../vm"

Program_Registry :: struct {
	lock:      sync.Mutex,
	programs:  map[v.Value]^vm.Program,
	callables: ^vm.Callable_Registry,
	allocator: mem.Allocator,
}

program_registry_new :: proc(allocator: mem.Allocator) -> ^Program_Registry {
	registry := new(Program_Registry, allocator)
	registry.programs = make(map[v.Value]^vm.Program, allocator = allocator)
	registry.callables = vm.callable_registry_new(allocator)
	registry.allocator = allocator
	return registry
}

program_registry_destroy :: proc(registry: ^Program_Registry) {
	if registry == nil {
		return
	}
	for _, program in registry.programs {
		vm.program_destroy(program, registry.allocator)
	}
	delete(registry.programs)
	vm.callable_registry_destroy(registry.callables)
	free(registry, registry.allocator)
}

// Adds `program` under `id` and returns the registered program. A program
// with the same id is already identical, so the new copy is destroyed.
program_registry_add :: proc(
	registry: ^Program_Registry,
	id: v.Value,
	program: ^vm.Program,
) -> ^vm.Program {
	sync.mutex_lock(&registry.lock)
	defer sync.mutex_unlock(&registry.lock)
	if existing, found := registry.programs[id]; found {
		vm.program_destroy(program, registry.allocator)
		return existing
	}
	vm.program_share_callables(program, registry.callables)
	registry.programs[id] = program
	return program
}

program_registry_get :: proc(registry: ^Program_Registry, id: v.Value) -> ^vm.Program {
	if registry == nil {
		return nil
	}
	sync.mutex_lock(&registry.lock)
	defer sync.mutex_unlock(&registry.lock)
	return registry.programs[id]
}

// The VM resolver hook: `user` is the registry.
program_registry_resolve :: proc(user: rawptr, id: v.Value) -> ^vm.Program {
	return program_registry_get((^Program_Registry)(user), id)
}

// Compiles one verb as its own program. Function 0 is an empty entry, the
// verb body is function 1 and becomes the program's entry, and its fn
// literals follow. Calls to other verbs compile to dispatch.
@(private)
compile_verb_program :: proc(
	verb: c.Verb_Item,
	ctx: ^c.Compile_Context,
	allocator: mem.Allocator,
) -> (
	^vm.Program,
	Run_Result,
) {
	items := []c.Item{verb}
	ast := c.Program_AST {
		items = items,
	}
	compiled := c.compile_program(&ast, ctx, allocator)
	if len(compiled.errors) > 0 {
		return nil, Run_Result{ok = false, message = compiled.errors[0].message}
	}
	compiled.program.entry = 1
	return compiled.program, Run_Result{ok = true, message = "loaded"}
}

// Compiles every verb in `asts` to its own program, registers each program,
// and records one ProgramBytes row per new program. Returns the program id of
// each verb in declaration order, the order `install_methods` walks.
@(private)
install_verb_programs :: proc(
	env: ^Builtin_Env,
	asts: []^c.Program_AST,
) -> (
	[dynamic]v.Value,
	Run_Result,
) {
	ids := make([dynamic]v.Value, env.allocator)
	tx := k.kernel_begin(env.kernel)
	defer k.transaction_destroy(&tx)
	recorded := make(map[v.Value]bool, allocator = context.temp_allocator)
	for ast in asts {
		for item in ast.items {
			verb, is_verb := item.(c.Verb_Item)
			if !is_verb {
				continue
			}
			program, compile_result := compile_verb_program(verb, env.ctx, env.allocator)
			if !compile_result.ok {
				delete(ids)
				return nil, compile_result
			}
			bytes: [dynamic]u8
			if error := vm.program_to_bytes(program, &bytes); error != .None {
				delete(bytes)
				vm.program_destroy(program, env.allocator)
				delete(ids)
				return nil, Run_Result {
					ok = false,
					message = fmt.aprintf(
						"cannot encode program for %s: %v",
						verb.name,
						error,
						allocator = env.allocator,
					),
				}
			}
			id, id_ok := vm.program_artifact_id(bytes[:])
			if !id_ok {
				delete(bytes)
				vm.program_destroy(program, env.allocator)
				delete(ids)
				return nil, Run_Result{ok = false, message = "program identity is out of range"}
			}
			program_registry_add(env.programs, id, program)
			if !recorded[id] && !program_bytes_recorded(env.kernel, id) {
				if err := k.transaction_assert(
					&tx,
					k.SYSTEM_PROGRAM_BYTES_ID,
					v.tuple_new(
						context.temp_allocator,
						[]v.Value{id, v.value_bytes(env.allocator, bytes[:])},
					),
				); err != k.Kernel_Error.None {
					delete(bytes)
					delete(ids)
					return nil, Run_Result {
						ok = false,
						message = fmt.aprintf(
							"cannot record program bytes: %v",
							err,
							allocator = env.allocator,
						),
					}
				}
				recorded[id] = true
			}
			delete(bytes)
			append(&ids, id)
		}
	}
	committed, commit_err := k.transaction_commit(&tx)
	if commit_err != k.Kernel_Error.None {
		delete(ids)
		return nil, Run_Result {
			ok = false,
			message = fmt.aprintf(
				"cannot record program bytes: %v",
				commit_err,
				allocator = env.allocator,
			),
		}
	}
	k.snapshot_release(committed)
	return ids, Run_Result{ok = true, message = "loaded"}
}

@(private)
program_bytes_recorded :: proc(kernel: ^k.Kernel, id: v.Value) -> bool {
	rows: [dynamic]v.Tuple
	defer delete(rows)
	k.kernel_scan_into(kernel, k.SYSTEM_PROGRAM_BYTES_ID, []v.Binding{v.binding_of(id), {}}, &rows)
	return len(rows) > 0
}

// Decodes every ProgramBytes row whose MethodProgram values name programs
// into the registry. Reports false when the store uses the single-program
// layout (integer MethodProgram values), which boots through its one row.
@(private)
load_method_programs :: proc(env: ^Builtin_Env) -> (per_method: bool, result: Run_Result) {
	methods: [dynamic]v.Tuple
	defer delete(methods)
	k.kernel_scan_into(env.kernel, k.DISPATCH_METHOD_PROGRAM_ID, []v.Binding{{}, {}}, &methods)
	for row in methods {
		if _, is_int := v.value_as_int(v.tuple_values(row)[1]); is_int {
			return false, Run_Result{ok = true, message = "loaded"}
		}
	}
	rows: [dynamic]v.Tuple
	defer delete(rows)
	k.kernel_scan_into(env.kernel, k.SYSTEM_PROGRAM_BYTES_ID, []v.Binding{{}, {}}, &rows)
	for row in rows {
		values := v.tuple_values(row)
		artifact, artifact_ok := v.value_as_bytes(values[1])
		if !artifact_ok {
			return true, Run_Result{ok = false, message = "program artifact is not bytes"}
		}
		program, decode_error := vm.program_from_bytes(artifact, env.allocator)
		if decode_error != .None {
			return true, Run_Result {
				ok = false,
				message = fmt.aprintf(
					"cannot decode program artifact: %v",
					decode_error,
					allocator = env.allocator,
				),
			}
		}
		if validation := vm.program_validate(program); validation != .None {
			vm.program_destroy(program, env.allocator)
			return true, Run_Result {
				ok = false,
				message = fmt.aprintf(
					"program artifact failed validation: %v",
					validation,
					allocator = env.allocator,
				),
			}
		}
		program_registry_add(env.programs, values[0], program)
	}
	// A method whose program has no ProgramBytes row (stripped, or written
	// before rows were recorded) recompiles from its MethodSource text. The
	// id is a content address, so the recompiled program must hash to it.
	for row in methods {
		values := v.tuple_values(row)
		method, id := values[0], values[1]
		if program_registry_get(env.programs, id) != nil {
			continue
		}
		if recompiled := recompile_method_program(env, method, id); !recompiled.ok {
			return true, recompiled
		}
	}
	return true, Run_Result{ok = true, message = "loaded"}
}

@(private)
recompile_method_program :: proc(env: ^Builtin_Env, method: v.Value, id: v.Value) -> Run_Result {
	sources: [dynamic]v.Tuple
	defer delete(sources)
	k.kernel_scan_into(env.kernel, k.SYSTEM_METHOD_SOURCE_ID, []v.Binding{v.binding_of(method), {}}, &sources)
	if len(sources) == 0 {
		return Run_Result{ok = false, message = "a method has neither program bytes nor source"}
	}
	text, is_string := v.value_as_string(v.tuple_values(sources[0])[1])
	if !is_string {
		return Run_Result{ok = false, message = "method source is not a string"}
	}
	ast, parse_errors := c.parse_program(text, env.allocator)
	if len(parse_errors) > 0 {
		return Run_Result{ok = false, message = parse_errors[0].message}
	}
	asts := []^c.Program_AST{ast}
	ids, result := install_verb_programs(env, asts)
	defer delete(ids)
	if !result.ok {
		return result
	}
	if len(ids) != 1 || !v.value_eq(ids[0], id) {
		return Run_Result{ok = false, message = "recompiled method program does not match its recorded id"}
	}
	return Run_Result{ok = true, message = "loaded"}
}
