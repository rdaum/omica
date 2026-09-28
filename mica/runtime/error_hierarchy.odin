// Error hierarchy surfaces: the ErrorIsA computed relation and the built-in
// ErrorParent links a new world starts with (draft-ndn-error-hierarchy-00).
//
//	ErrorIsA(code, ancestor)    the code itself and every ancestor through ErrorParent
//
// The code must be bound. ErrorParent is read under the reader's authority,
// so a query never reveals links the reader could not read directly.
package mica_runtime

import k "../kernel"
import v "../var"

@(private)
error_is_a_scan :: proc(
	user: rawptr,
	source: ^k.Relation_Source,
	bindings: []v.Binding,
	visit: k.Computed_Visit_Proc,
	visit_user: rawptr,
) -> k.Kernel_Error {
	if len(bindings) < 1 || !bindings[0].bound {
		return .Computed_Binding_Required
	}
	Scan :: struct {
		code:       v.Value,
		ancestor:   v.Binding,
		visit:      k.Computed_Visit_Proc,
		visit_user: rawptr,
	}
	scan := Scan {
		code       = bindings[0].value,
		visit      = visit,
		visit_user = visit_user,
	}
	if len(bindings) > 1 {
		scan.ancestor = bindings[1]
	}
	k.error_ancestors_visit(source, scan.code, proc(user: rawptr, ancestor: v.Value) -> bool {
		scan := (^Scan)(user)
		if scan.ancestor.bound && !v.value_eq(scan.ancestor.value, ancestor) {
			return true
		}
		row := v.tuple_new(context.temp_allocator, []v.Value{scan.code, ancestor})
		return scan.visit(scan.visit_user, row)
	}, &scan)
	return .None
}

@(private)
install_error_hierarchy_computed_relation :: proc(env: ^Builtin_Env) -> Run_Result {
	if err := k.kernel_register_computed_relation(
		env.kernel,
		k.SYSTEM_ERROR_IS_A_ID,
		[]u16{0},
		error_is_a_scan,
		rawptr(env),
	); err != .None {
		return Run_Result{ok = false, message = "cannot register ErrorIsA"}
	}
	return Run_Result{ok = true, message = "loaded"}
}

// Asserts the built-in ErrorParent links into a new world. A world booted
// from its store keeps the links it has, including any it retracted.
@(private)
seed_error_hierarchy :: proc(env: ^Builtin_Env) -> Run_Result {
	tx := k.kernel_begin(env.kernel)
	defer k.transaction_destroy(&tx)
	for link in k.ERROR_HIERARCHY_BUILTIN_LINKS {
		row := v.tuple_new(
			context.temp_allocator,
			[]v.Value {
				v.value_error_code(v.symbol_intern(link[0])),
				v.value_error_code(v.symbol_intern(link[1])),
			},
		)
		if err := k.transaction_assert(&tx, k.SYSTEM_ERROR_PARENT_ID, row); err != .None {
			return catalog_error(env, "ErrorParent", err)
		}
	}
	committed, err := k.transaction_commit(&tx)
	if err != .None {
		return catalog_error(env, "ErrorParent", err)
	}
	k.snapshot_release(committed)
	return Run_Result{ok = true, message = "loaded"}
}

// Adds ErrorParent and ErrorIsA to a world booted from a store written before
// they existed: creates and catalogues both relations and seeds the built-in
// links. A store that already has them is left alone.
@(private)
upgrade_error_hierarchy :: proc(env: ^Builtin_Env) -> Run_Result {
	snapshot := k.kernel_snapshot(env.kernel)
	_, present := k.snapshot_relation_metadata(snapshot, k.SYSTEM_ERROR_PARENT_ID)
	k.snapshot_release(snapshot)
	if present {
		return Run_Result{ok = true, message = "loaded"}
	}
	added: [dynamic]k.Relation_Metadata
	defer delete(added)
	for entry in k.system_relation_metadata(context.temp_allocator) {
		if entry.id != k.SYSTEM_ERROR_PARENT_ID && entry.id != k.SYSTEM_ERROR_IS_A_ID {
			continue
		}
		created, err := k.kernel_create_relation(env.kernel, entry)
		if err != .None {
			return catalog_error(env, "ErrorParent", err)
		}
		k.snapshot_release(created)
		name, _ := v.symbol_name(entry.name)
		env.ctx.relations[name] = u32(entry.id)
		append(&added, entry)
	}
	if facts := assert_relation_facts(env, added[:]); !facts.ok {
		return facts
	}
	return seed_error_hierarchy(env)
}
