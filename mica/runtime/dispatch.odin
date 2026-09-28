// Method installation for relation-driven dispatch.
//
// Every verb becomes a method: its selector is the verb name, its parameters
// become role bindings with prototype restrictions, and its compiled function
// index is recorded in MethodProgram.
package mica_runtime

import "core:fmt"
import "core:strings"
import c "../compiler"
import k "../kernel"
import v "../var"

// Creates the reserved dispatch relations and records their ids in the compile
// context. Runs before user declarations so `make_relation(:Delegates, 3)`
// binds to the system relation.
@(private)
install_dispatch_relations :: proc(env: ^Builtin_Env) -> Run_Result {
	groups := [2][]k.Relation_Metadata {
		k.dispatch_relation_metadata(env.allocator),
		k.system_relation_metadata(env.allocator),
	}
	for metadata in groups {
		for entry in metadata {
			created, create_err := k.kernel_create_relation(env.kernel, entry)
			if create_err != k.Kernel_Error.None {
				name, _ := v.symbol_name(entry.name)
				return Run_Result{ok = false, message = fmt.aprintf(
					"cannot create system relation %s: %v",
					name,
					create_err,
					allocator = env.allocator,
				)}
			}
			k.snapshot_release(created)
			name, _ := v.symbol_name(entry.name)
			env.ctx.relations[name] = u32(entry.id)
		}
	}

	env.ctx.dispatch_method_selector_relation = u32(k.DISPATCH_METHOD_SELECTOR_ID)
	env.ctx.dispatch_param_relation = u32(k.DISPATCH_PARAM_ID)
	env.ctx.dispatch_delegates_relation = u32(k.DISPATCH_DELEGATES_ID)
	env.ctx.dispatch_method_program_relation = u32(k.DISPATCH_METHOD_PROGRAM_ID)

	all: [dynamic]k.Relation_Metadata
	defer delete(all)
	for metadata in groups {
		append(&all, ..metadata)
	}
	fact_result := assert_relation_facts(env, all[:])
	if !fact_result.ok {
		return fact_result
	}
	return Run_Result{ok = true, message = "loaded"}
}

// Records every verb in `asts` as a method. Function indices follow the same
// order `compile_program` assigns: entry is 0, verbs start at 1. `sources`
// holds the trimmed program text for each AST, recorded as MethodSource facts.
@(private)
install_methods :: proc(
	env: ^Builtin_Env,
	asts: []^c.Program_AST,
	sources: []string,
	declarations: ^Declarations,
	// Per-verb program ids, in declaration order. Nil records function
	// indices into one shared program instead.
	program_ids: []v.Value = nil,
) -> Run_Result {
	tx := k.kernel_begin(env.kernel)
	defer k.transaction_destroy(&tx)
	function_index := 1

	for ast, ast_index in asts {
		// Fallback for hand-built ASTs that carry no per-verb span.
		unit_source := ""
		if ast_index < len(sources) {
			unit_source = strings.trim_space(sources[ast_index])
		}
		for item in ast.items {
			verb, is_verb := item.(c.Verb_Item)
			if !is_verb {
				continue
			}
			// Record the verb's own text, not the whole unit: a unit source
			// per method duplicates the file once per verb and the kernel
			// deep-copies every copy on write.
			source_text := verb.source
			if source_text == "" {
				source_text = unit_source
			}
			method_value, identity_ok := v.value_identity_raw(declarations.next_identity)
			if !identity_ok {
				return Run_Result{ok = false, message = "method identity space exhausted"}
			}
			declarations.next_identity += 1

			selector := v.value_symbol(v.symbol_intern(verb.name))
			if err := k.transaction_assert(
				&tx,
				k.DISPATCH_METHOD_SELECTOR_ID,
				v.tuple_new(context.temp_allocator, []v.Value{method_value, selector}),
			); err != k.Kernel_Error.None {
				return method_install_error(env, verb.name, err)
			}

			program_value := value_int_must(i64(function_index))
			if program_ids != nil {
				program_value = program_ids[function_index - 1]
			}
			if err := k.transaction_assert(
				&tx,
				k.DISPATCH_METHOD_PROGRAM_ID,
				v.tuple_new(context.temp_allocator, []v.Value{method_value, program_value}),
			); err != k.Kernel_Error.None {
				return method_install_error(env, verb.name, err)
			}

			if source_text != "" {
				if err := k.transaction_assert(
					&tx,
					k.SYSTEM_METHOD_SOURCE_ID,
					v.tuple_new(context.temp_allocator, []v.Value {
						method_value,
						v.value_string(context.temp_allocator, source_text),
					}),
				); err != k.Kernel_Error.None {
					return method_install_error(env, verb.name, err)
				}
			}

			for param, position in verb.params {
				restriction := method_restriction(env, param)
				mode := k.PARAM_REQUIRED_MODE
				switch param.mode {
				case .Optional:
					mode = k.PARAM_OPTIONAL_MODE
				case .Rest:
					mode = k.PARAM_REST_MODE
				case .Required:
				}
				if err := k.transaction_assert(
					&tx,
					k.DISPATCH_PARAM_ID,
					v.tuple_new(context.temp_allocator, []v.Value {
						method_value,
						v.value_symbol(v.symbol_intern(param.name)),
						restriction,
						value_int_must(i64(position) + i64(mode) * 65536),
					}),
				); err != k.Kernel_Error.None {
					return method_install_error(env, verb.name, err)
				}
			}
			function_index += 1
		}
	}

	committed, commit_err := k.transaction_commit(&tx)
	if commit_err != k.Kernel_Error.None {
		return Run_Result{ok = false, message = fmt.aprintf(
			"method install commit failed: %v",
			commit_err,
			allocator = env.allocator,
		)}
	}
	k.snapshot_release(committed)
	return Run_Result{ok = true, message = "loaded"}
}

@(private)
method_install_error :: proc(env: ^Builtin_Env, name: string, err: k.Kernel_Error) -> Run_Result {
	return Run_Result{ok = false, message = fmt.aprintf(
		"cannot install method %s: %v",
		name,
		err,
		allocator = env.allocator,
	)}
}

// Converts a parameter annotation into a dispatch restriction. A bare
// prototype restricts to values matching that prototype or its delegates;
// `#proto<_>` additionally requires the value to be a frob.
@(private)
method_restriction :: proc(env: ^Builtin_Env, param: c.Param) -> v.Value {
	if param.mode == .Rest {
		return k.rest_dispatch_restriction()
	}
	if !param.has_restriction || param.restriction == nil {
		return k.unrestricted_dispatch_restriction()
	}
	#partial switch restriction in param.restriction^ {
	case c.Identity_Literal:
		if value, found := env.ctx.identities[restriction.name]; found {
			return value
		}
	case c.Structural_Literal:
		head, is_identity := restriction.head^.(c.Identity_Literal)
		if is_identity {
			if value, found := env.ctx.identities[head.name]; found {
				if delegate, is_id := v.value_as_identity(value); is_id {
					return k.frob_only_dispatch_restriction(env.allocator, delegate)
				}
			}
		}
	case:
	}
	return k.unrestricted_dispatch_restriction()
}
