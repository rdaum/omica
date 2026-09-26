// Relation constructors share validation and catalogue staging with filein.
package mica_runtime

import "core:fmt"
import "core:strconv"
import c "../compiler"
import k "../kernel"
import v "../var"
import vm "../vm"

@(private)
relation_constructor_metadata :: proc(args: []v.Value, functional: bool) -> (k.Relation_Metadata, string, string) {
	minimum := functional ? 3 : 2
	if len(args) < minimum || len(args) > minimum+1 {
		return {}, "E_INVARG", "relation constructor has the wrong argument count"
	}
	name, symbol_ok := v.value_as_symbol(args[0])
	if !symbol_ok {return {}, "E_TYPE", "relation name must be a symbol"}
	if _, ok := v.symbol_name(name); !ok {return {}, "E_INVARG", "relation name must be interned"}
	arity, arity_ok := v.value_as_int(args[1])
	if !arity_ok {return {}, "E_TYPE", "relation arity must be an integer"}
	if arity < 0 || arity > 65535 {return {}, "E_INVARG", "relation arity must be between 0 and 65535"}
	metadata := k.relation_metadata(0, name, u16(arity))
	if functional {
		keys, ok := v.value_as_list(args[2])
		if !ok {return {}, "E_TYPE", "functional keys must be a list"}
		positions := make([]u16, len(keys), context.temp_allocator)
		for key, i in keys {
			position, ok := v.value_as_int(key)
			if !ok {return {}, "E_TYPE", "functional key positions must be integers"}
			if position < 0 || position >= arity {return {}, "E_INVARG", "functional key position is outside the relation arity"}
			positions[i] = u16(position)
			for previous in positions[:i] {
				if previous == positions[i] {return {}, "E_INVARG", "functional key positions must be distinct"}
			}
		}
		metadata.conflict = k.conflict_functional(positions)
	}
	if len(args) > minimum {
		durability, ok := v.value_as_symbol(args[minimum])
		if !ok {return {}, "E_TYPE", "relation durability must be a symbol"}
		text, _ := v.symbol_name(durability)
		switch text {
		case "durable": metadata.durability = .Durable
		case "volatile": metadata.durability = .Volatile
		case: return {}, "E_INVARG", "relation durability must be :durable or :volatile"
		}
	}
	return metadata, "", ""
}

@(private)
relation_definition_matches :: proc(existing, requested: k.Relation_Metadata) -> bool {
	if existing.tombstoned || existing.storage != .Tuple || existing.arity != requested.arity ||
	   existing.durability != requested.durability || existing.conflict.kind != requested.conflict.kind ||
	   len(existing.conflict.key_positions) != len(requested.conflict.key_positions) {return false}
	for position, i in existing.conflict.key_positions {
		if position != requested.conflict.key_positions[i] {return false}
	}
	return true
}

// The caller checks authority. Loader declarations run as trusted filein.
// The returned metadata borrows the transaction's catalogue storage.
@(private)
ensure_relation :: proc(env: ^Builtin_Env, tx: ^k.Transaction, requested: k.Relation_Metadata) -> (k.Relation_Metadata, Run_Result) {
	if existing, found := k.transaction_relation_metadata_named(tx, requested.name); found {
		if !relation_definition_matches(existing, requested) {
			name, _ := v.symbol_name(requested.name)
			return {}, Run_Result{message = fmt.aprintf("relation :%s already exists with different metadata", name, allocator = env.allocator)}
		}
		return existing, Run_Result{ok = true}
	}
	id, err := k.transaction_create_relation(tx, requested)
	if err != .None {return {}, catalog_error(env, "Relation", err)}
	metadata, _ := k.transaction_relation_metadata(tx, id)
	result := stage_relation_facts(env, tx, []k.Relation_Metadata{metadata})
	return metadata, result
}

@(private)
builtin_create_relation :: proc(state: ^vm.VM, args: []v.Value, functional: bool) -> (v.Value, bool) {
	metadata, code, message := relation_constructor_metadata(args, functional)
	if message != "" {return builtin_error(state, code, message)}
	if !k.authority_can_grant(state.authority) {return builtin_error(state, "E_PERMISSION", "relation creation requires administrative authority")}
	if state.transaction == nil {return builtin_error(state, "E_NO_TRANSACTION", "relation creation requires a task transaction")}
	if state.transaction.read_only {return builtin_error(state, "E_PERMISSION", "relation creation requires a writable transaction")}
	actual, result := ensure_relation(builtin_env(state), state.transaction, metadata)
	if !result.ok {return builtin_error(state, "E_INVARG", result.message)}
	identity, _ := v.value_identity_raw(u64(actual.id))
	return identity, true
}

@(private)
builtin_make_relation :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	return builtin_create_relation(state, args, false)
}

@(private)
builtin_make_functional_relation :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	return builtin_create_relation(state, args, true)
}

// Resolve names from the task's view, including its uncommitted creations.
// No constructor publishes entries in the shared compiler maps.
@(private)
runtime_relation_named :: proc(state: ^vm.VM, name: string) -> (u32, bool) {
	if state.transaction == nil {return 0, false}
	// Filein names are immutable after startup. Keep their existing fast path;
	// names created by tasks are resolved against the transaction catalogue.
	env := builtin_env(state)
	if env != nil && env.ctx != nil {
		if id, found := env.ctx.relations[name]; found {return id, true}
	}
	metadata, found := k.transaction_relation_metadata_named(state.transaction, v.symbol_intern(name))
	return u32(metadata.id), found
}

@(private)
transaction_field :: proc(state: ^vm.VM, name: string) -> (Field_Info, bool) {
	normalized := lower_first(name, context.temp_allocator)
	env := builtin_env(state)
	// Existing filein fields retain their fast lookup. Their metadata still
	// comes from the task snapshot, not the latest published snapshot.
	if info, found := env.fields[normalized]; found {
		metadata, ok := k.transaction_relation_metadata(state.transaction, info.relation)
		if ok && !metadata.tombstoned && metadata.arity == 2 {return info, true}
	}
	for change in state.transaction.catalog_changes {
		metadata := change.metadata
		field, _ := v.symbol_name(metadata.name)
		if metadata.arity == 2 && metadata.conflict.kind == .Functional && lower_first(field, context.temp_allocator) == normalized {
			visible, ok := k.transaction_relation_metadata(state.transaction, metadata.id)
			return Field_Info{relation = metadata.id, key_positions = metadata.conflict.key_positions}, ok && !visible.tombstoned
		}
	}
	for metadata in state.transaction.base.catalog {
		field, _ := v.symbol_name(metadata.name)
		if !metadata.tombstoned && metadata.arity == 2 && metadata.conflict.kind == .Functional && lower_first(field, context.temp_allocator) == normalized {
			return Field_Info{relation = metadata.id, key_positions = metadata.conflict.key_positions}, true
		}
	}
	return {}, false
}

// Only literal arguments participate in declaration prescan. Ordinary
// expressions are evaluated later by the VM, with the same validation.
@(private)
relation_declaration_literal :: proc(expr: ^c.Expr) -> (v.Value, bool) {
	#partial switch node in expr^ {
	case c.Symbol_Literal:
		return v.value_symbol(v.symbol_intern(c.unquote_string(node.name, context.temp_allocator))), true
	case c.Int_Literal:
		number, ok := strconv.parse_i64(node.text)
		if !ok {return {}, false}
		return v.value_int(number)
	case c.Bool_Literal:
		return v.value_bool(node.value), true
	case c.String_Literal:
		// The constructor rejects all strings, so decoding is unnecessary.
		return v.value_string(context.temp_allocator, node.text), true
	case c.List_Literal:
		values := make([]v.Value, len(node.elements), context.temp_allocator)
		for element, i in node.elements {
			value, ok := relation_declaration_literal(element)
			if !ok {return {}, false}
			values[i] = value
		}
		return v.value_list(context.temp_allocator, values), true
	case c.Unary:
		if node.op != .Neg {return {}, false}
		value, ok := relation_declaration_literal(node.operand)
		number, integer := v.value_as_int(value)
		if !ok || !integer {return {}, false}
		return v.value_int(-number)
	}
	return {}, false
}
