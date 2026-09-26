// Relation-driven method dispatch.
//
// Methods are ordinary relations installed by the runtime:
//
//   MethodSelector(method, selector)
//   Param(method, role, restriction, position)
//   MethodProgram(method, function index)
//   Delegates(child, prototype, ...)
//
// A dispatch site supplies a selector plus role values; a method applies when
// every parameter role is present and the value satisfies the parameter
// restriction. The most specific applicable method wins.
package kernel

import "core:mem"
import "core:slice"
import v "../var"

// Reserved relation ids for the dispatch tables. These sit in the high
// reserved range above the ids the runtime assigns to user relations.
DISPATCH_METHOD_SELECTOR_ID :: Relation_ID(0x7fff_ff01)
DISPATCH_PARAM_ID :: Relation_ID(0x7fff_ff02)
DISPATCH_DELEGATES_ID :: Relation_ID(0x7fff_ff03)
DISPATCH_METHOD_PROGRAM_ID :: Relation_ID(0x7fff_ff04)

Dispatch_Relations :: struct {
	method_selector: Relation_ID,
	param:           Relation_ID,
	delegates:       Relation_ID,
}

// A role binding supplied at a dispatch site.
Role_Pair :: struct {
	role:  v.Value,
	value: v.Value,
}

// A method whose parameters all accept the call's roles.
Applicable_Method :: struct {
	method: v.Value,
	params: []v.Tuple,
}

@(private)
unrestricted_marker :: proc() -> v.Value {
	return v.value_symbol(v.symbol_intern("dispatch/unrestricted"))
}

@(private)
frob_only_marker :: proc() -> v.Value {
	return v.value_symbol(v.symbol_intern("dispatch/frob_only"))
}

PARAM_REQUIRED_MODE :: 0
PARAM_OPTIONAL_MODE :: 1
PARAM_REST_MODE :: 2

@(private)
rest_marker :: proc() -> v.Value {
	return v.value_symbol(v.symbol_intern("dispatch/rest"))
}

// The parameter mode is packed into the high byte of the position cell so the
// method relation keeps its four-column shape.
@(private)
param_mode :: proc(param: v.Tuple) -> int {
	values := v.tuple_values(param)
	position, is_int := v.value_as_int(values[3])
	if !is_int || position < 0 {
		return PARAM_REQUIRED_MODE
	}
	return int(position >> 16)
}

// The restriction meaning "a rest parameter": it absorbs trailing arguments
// and never requires a role of its own.
rest_dispatch_restriction :: proc() -> v.Value {
	return rest_marker()
}

@(private)
is_rest_restriction :: proc(restriction: v.Value) -> bool {
	return v.value_eq(restriction, rest_marker())
}

// Creates the metadata for the dispatch relations, in id order.
dispatch_relation_metadata :: proc(allocator := context.allocator) -> []Relation_Metadata {
	metadata := make([]Relation_Metadata, 4, allocator)
	metadata[0] = relation_metadata(
		DISPATCH_METHOD_SELECTOR_ID,
		v.symbol_intern("MethodSelector"),
		2,
	)
	metadata[1] = relation_metadata(DISPATCH_PARAM_ID, v.symbol_intern("Param"), 4)
	metadata[2] = relation_metadata(DISPATCH_DELEGATES_ID, v.symbol_intern("Delegates"), 3)
	metadata[3] = relation_metadata(
		DISPATCH_METHOD_PROGRAM_ID,
		v.symbol_intern("MethodProgram"),
		2,
	)
	return metadata
}

// Reserved ids for the system reflection relations. Relation ids are u32 in
// this runtime, so these use the reserved range below the dispatch tables.
SYSTEM_RELATION_ID :: Relation_ID(0x7fff_fe01)
SYSTEM_RELATION_NAME_ID :: Relation_ID(0x7fff_fe02)
SYSTEM_ARITY_ID :: Relation_ID(0x7fff_fe03)
SYSTEM_RELATION_DURABILITY_ID :: Relation_ID(0x7fff_fe1b)
SYSTEM_NAMED_IDENTITY_ID :: Relation_ID(0x7fff_fe1c)
SYSTEM_UNIT_SOURCE_ID :: Relation_ID(0x7fff_fe1d)
SYSTEM_RULE_ID :: Relation_ID(0x7fff_fe04)
SYSTEM_RULE_HEAD_ID :: Relation_ID(0x7fff_fe05)
SYSTEM_RULE_SOURCE_ID :: Relation_ID(0x7fff_fe06)
SYSTEM_ACTIVE_RULE_ID :: Relation_ID(0x7fff_fe07)
SYSTEM_ARGUMENT_NAME_ID :: Relation_ID(0x7fff_fe08)
SYSTEM_CONFLICT_POLICY_ID :: Relation_ID(0x7fff_fe09)
SYSTEM_FUNCTIONAL_KEY_ID :: Relation_ID(0x7fff_fe0a)
SYSTEM_INDEX_ID :: Relation_ID(0x7fff_fe0b)
SYSTEM_INDEX_POSITION_ID :: Relation_ID(0x7fff_fe0c)
SYSTEM_INDEX_STORAGE_KIND_ID :: Relation_ID(0x7fff_fe0d)
SYSTEM_SUBJECT_FACT_ID :: Relation_ID(0x7fff_fe0e)
SYSTEM_MENTIONED_FACT_ID :: Relation_ID(0x7fff_fe14)
SYSTEM_EXTENSIONAL_MENTIONED_FACT_ID :: Relation_ID(0x7fff_fe15)
SYSTEM_ENDPOINT_ID :: Relation_ID(0x7fff_fe16)
SYSTEM_ENDPOINT_ACTOR_ID :: Relation_ID(0x7fff_fe17)
SYSTEM_ENDPOINT_PRINCIPAL_ID :: Relation_ID(0x7fff_fe18)
SYSTEM_ENDPOINT_PROTOCOL_ID :: Relation_ID(0x7fff_fe19)
SYSTEM_ENDPOINT_OPEN_ID :: Relation_ID(0x7fff_fe1a)
SYSTEM_PROGRAM_BYTES_ID :: Relation_ID(0x7fff_fe0f)
SYSTEM_METHOD_SOURCE_ID :: Relation_ID(0x7fff_fe10)
SYSTEM_SOURCE_OWNS_FACT_ID :: Relation_ID(0x7fff_fe11)
SYSTEM_SOURCE_OWNS_RULE_ID :: Relation_ID(0x7fff_fe12)
SYSTEM_SOURCE_OWNS_RELATION_ID :: Relation_ID(0x7fff_fe13)

// Metadata for the system reflection relations: Relation, RelationName, Arity,
// Rule, RuleHead, RuleSource, and friends. Installed empty; the kernel and
// runtime populate them as declarations are loaded.
system_relation_metadata :: proc(allocator := context.allocator) -> []Relation_Metadata {
	entries := [?]Relation_Metadata {
		relation_metadata(SYSTEM_RELATION_ID, v.symbol_intern("Relation"), 1),
		relation_metadata(SYSTEM_RELATION_NAME_ID, v.symbol_intern("RelationName"), 2),
		relation_metadata(SYSTEM_ARITY_ID, v.symbol_intern("Arity"), 2),
		relation_metadata(SYSTEM_RELATION_DURABILITY_ID, v.symbol_intern("RelationDurability"), 2),
		relation_metadata(SYSTEM_RULE_ID, v.symbol_intern("Rule"), 1),
		relation_metadata(SYSTEM_RULE_HEAD_ID, v.symbol_intern("RuleHead"), 2),
		relation_metadata(SYSTEM_RULE_SOURCE_ID, v.symbol_intern("RuleSource"), 2),
		relation_metadata(SYSTEM_ACTIVE_RULE_ID, v.symbol_intern("ActiveRule"), 2),
		relation_metadata(SYSTEM_ARGUMENT_NAME_ID, v.symbol_intern("ArgumentName"), 3),
		relation_metadata(SYSTEM_CONFLICT_POLICY_ID, v.symbol_intern("ConflictPolicy"), 2),
		relation_metadata(SYSTEM_FUNCTIONAL_KEY_ID, v.symbol_intern("FunctionalKey"), 3),
		relation_metadata(SYSTEM_INDEX_ID, v.symbol_intern("Index"), 2),
		relation_metadata(SYSTEM_INDEX_POSITION_ID, v.symbol_intern("IndexPosition"), 3),
		relation_metadata(SYSTEM_INDEX_STORAGE_KIND_ID, v.symbol_intern("IndexStorageKind"), 2),
		relation_metadata(SYSTEM_SUBJECT_FACT_ID, v.symbol_intern("SubjectFact"), 3),
		relation_metadata(SYSTEM_MENTIONED_FACT_ID, v.symbol_intern("MentionedFact"), 4),
		relation_metadata(
			SYSTEM_EXTENSIONAL_MENTIONED_FACT_ID,
			v.symbol_intern("ExtensionalMentionedFact"),
			4,
		),
		relation_metadata(SYSTEM_NAMED_IDENTITY_ID, v.symbol_intern("NamedIdentity"), 2),
		relation_metadata(SYSTEM_UNIT_SOURCE_ID, v.symbol_intern("UnitSource"), 3),
		relation_metadata(SYSTEM_PROGRAM_BYTES_ID, v.symbol_intern("ProgramBytes"), 2),
		relation_metadata(SYSTEM_METHOD_SOURCE_ID, v.symbol_intern("MethodSource"), 2),
		relation_metadata(SYSTEM_SOURCE_OWNS_FACT_ID, v.symbol_intern("SourceOwnsFact"), 3),
		relation_metadata(SYSTEM_SOURCE_OWNS_RULE_ID, v.symbol_intern("SourceOwnsRule"), 2),
		relation_metadata(
			SYSTEM_SOURCE_OWNS_RELATION_ID,
			v.symbol_intern("SourceOwnsRelation"),
			2,
		),
		metadata_with_durability(
			relation_metadata(SYSTEM_ENDPOINT_ID, v.symbol_intern("Endpoint"), 1),
			.Volatile,
		),
		metadata_with_durability(
			relation_metadata(SYSTEM_ENDPOINT_ACTOR_ID, v.symbol_intern("EndpointActor"), 2),
			.Volatile,
		),
		metadata_with_durability(
			relation_metadata(
				SYSTEM_ENDPOINT_PRINCIPAL_ID,
				v.symbol_intern("EndpointPrincipal"),
				2,
			),
			.Volatile,
		),
		metadata_with_durability(
			relation_metadata(SYSTEM_ENDPOINT_PROTOCOL_ID, v.symbol_intern("EndpointProtocol"), 2),
			.Volatile,
		),
		metadata_with_durability(
			relation_metadata(SYSTEM_ENDPOINT_OPEN_ID, v.symbol_intern("EndpointOpen"), 1),
			.Volatile,
		),
	}
	metadata := make([]Relation_Metadata, len(entries), allocator)
	copy(metadata, entries[:])
	for &entry in metadata {
		if entry.id == SYSTEM_NAMED_IDENTITY_ID {
			keys := make([]u16, 1, allocator)
			keys[0] = 1
			entry.conflict = conflict_functional(keys)
			entry.indexes = make([]Index_Spec, 1, allocator)
			entry.indexes[0] = index_spec(keys)
		}
	}
	return metadata
}

// The restriction meaning "any value".
unrestricted_dispatch_restriction :: proc() -> v.Value {
	return unrestricted_marker()
}

// The restriction meaning "a frob delegating to `delegate`".
frob_only_dispatch_restriction :: proc(allocator: mem.Allocator, delegate: v.Identity) -> v.Value {
	return v.value_frob(allocator, delegate, frob_only_marker())
}

// Frees the slices in an applicable-method result. The dynamic array itself
// and each entry's parameter slice are allocated from `allocator`, so a caller
// that owns the result must release both. Does nothing for a nil result.
applicable_methods_destroy :: proc(
	methods: ^[dynamic]Applicable_Method,
	allocator: mem.Allocator,
) {
	if methods == nil {
		return
	}
	for method in methods {
		delete(method.params, allocator)
	}
	delete(methods^)
	methods^ = nil
}

// Returns the method values applicable to `selector` with the given roles.
applicable_methods :: proc(
	source: ^Relation_Source,
	relations: Dispatch_Relations,
	selector: v.Value,
	roles: []Role_Pair,
	allocator: mem.Allocator,
) -> [dynamic]v.Value {
	entries := applicable_method_entries(source, relations, selector, roles, allocator)
	methods := make([dynamic]v.Value, 0, len(entries), allocator)
	for entry in entries {
		append(&methods, entry.method)
	}
	applicable_methods_destroy(&entries, allocator)
	return methods
}

// Returns applicable methods with their parameter rows, most specific first.
applicable_method_entries :: proc(
	source: ^Relation_Source,
	relations: Dispatch_Relations,
	selector: v.Value,
	roles: []Role_Pair,
	allocator: mem.Allocator,
) -> [dynamic]Applicable_Method {
	methods := make([dynamic]Applicable_Method, 0, 4, allocator)
	selector_rows: [dynamic]v.Tuple
	defer delete(selector_rows)
	relation_source_scan_into(
		source,
		relations.method_selector,
		[]v.Binding{{}, v.binding_of(selector)},
		&selector_rows,
	)
	for row in selector_rows {
		method := v.tuple_values(row)[0]
		param_rows: [dynamic]v.Tuple
		relation_source_scan_into(
			source,
			relations.param,
			[]v.Binding{v.binding_of(method), {}, {}, {}},
			&param_rows,
		)
		if !params_match(source, relations.delegates, roles, param_rows[:]) {
			delete(param_rows)
			continue
		}
		params := make([]v.Tuple, len(param_rows), allocator)
		copy(params, param_rows[:])
		delete(param_rows)
		append(&methods, Applicable_Method{method = method, params = params})
	}

	slice.sort_by(methods[:], proc(a, b: Applicable_Method) -> bool {
		return v.value_cmp(a.method, b.method) == .Less
	})
	prune_duplicate_methods(&methods, allocator)
	return prune_dominated_methods(source, relations.delegates, methods, allocator)
}

// Returns applicable methods for a positional call: arguments are matched to
// method parameters in position order, starting with the receiver.
applicable_positional_method_entries :: proc(
	source: ^Relation_Source,
	relations: Dispatch_Relations,
	selector: v.Value,
	args: []v.Value,
	allocator: mem.Allocator,
) -> [dynamic]Applicable_Method {
	methods := make([dynamic]Applicable_Method, 0, 4, allocator)
	selector_rows: [dynamic]v.Tuple
	defer delete(selector_rows)
	relation_source_scan_into(
		source,
		relations.method_selector,
		[]v.Binding{{}, v.binding_of(selector)},
		&selector_rows,
	)
	for row in selector_rows {
		method := v.tuple_values(row)[0]
		param_rows: [dynamic]v.Tuple
		relation_source_scan_into(
			source,
			relations.param,
			[]v.Binding{v.binding_of(method), {}, {}, {}},
			&param_rows,
		)
		slice.sort_by(param_rows[:], proc(a, b: v.Tuple) -> bool {
			a_values := v.tuple_values(a)
			b_values := v.tuple_values(b)
			a_position, _ := v.value_as_int(a_values[3])
			b_position, _ := v.value_as_int(b_values[3])
			return a_position < b_position
		})
		if !positional_params_match(
			source,
			relations.delegates,
			args,
			param_rows[:],
		) {
			delete(param_rows)
			continue
		}
		params := make([]v.Tuple, len(param_rows), allocator)
		copy(params, param_rows[:])
		delete(param_rows)
		append(&methods, Applicable_Method{method = method, params = params})
	}

	slice.sort_by(methods[:], proc(a, b: Applicable_Method) -> bool {
		return v.value_cmp(a.method, b.method) == .Less
	})
	prune_duplicate_methods(&methods, allocator)
	return prune_dominated_methods(source, relations.delegates, methods, allocator)
}

@(private)
positional_params_match :: proc(
	source: ^Relation_Source,
	delegates: Relation_ID,
	args: []v.Value,
	params: []v.Tuple,
) -> bool {
	fixed := len(params)
	has_rest := false
	if len(params) > 0 && param_mode(params[len(params) - 1]) == PARAM_REST_MODE {
		has_rest = true
		fixed -= 1
	}
	required := fixed
	for index in 0 ..< fixed {
		if param_mode(params[index]) == PARAM_OPTIONAL_MODE {
			required = index
			break
		}
	}
	if len(args) < required {
		return false
	}
	if !has_rest && len(args) > fixed {
		return false
	}
	for argument, index in args {
		if index >= fixed {
			break
		}
		restriction := v.tuple_values(params[index])[2]
		if !matches_restriction(source, delegates, argument, restriction) {
			return false
		}
	}
	return true
}

// Drops duplicate entries in place, keeping the first of each method. The
// parameter slice of every dropped entry is freed.
@(private)
prune_duplicate_methods :: proc(methods: ^[dynamic]Applicable_Method, allocator: mem.Allocator) {
	write := 0
	for method in methods {
		if write > 0 && v.value_eq(methods[write - 1].method, method.method) {
			delete(method.params, allocator)
			continue
		}
		methods[write] = method
		write += 1
	}
	resize(methods, write)
}

// Returns a copy of `methods` with dominated entries removed, most specific
// first. The parameter slice of every dropped entry is freed, and the input
// array's storage is freed once its surviving entries have moved to the
// result. A dominated entry cannot hide another entry's domination, so
// checking against the full input set is correct.
@(private)
prune_dominated_methods :: proc(
	source: ^Relation_Source,
	delegates: Relation_ID,
	methods: [dynamic]Applicable_Method,
	allocator: mem.Allocator,
) -> [dynamic]Applicable_Method {
	pruned := make([dynamic]Applicable_Method, 0, len(methods), allocator)
	for candidate in methods {
		dominated := false
		for other in methods {
			if v.value_eq(candidate.method, other.method) {
				continue
			}
			if method_more_specific(source, delegates, other, candidate) {
				dominated = true
				break
			}
		}
		if dominated {
			delete(candidate.params, allocator)
			continue
		}
		append(&pruned, candidate)
	}
	delete(methods)
	return pruned
}

@(private)
method_more_specific :: proc(
	source: ^Relation_Source,
	delegates: Relation_ID,
	left, right: Applicable_Method,
) -> bool {
	stricter := len(left.params) > len(right.params)
	for right_param in right.params {
		right_values := v.tuple_values(right_param)
		left_param := param_for_role(left.params, right_values[1])
		if left_param == nil {
			return false
		}
		left_values := v.tuple_values(left_param)
		if !restriction_implies(source, delegates, left_values[2], right_values[2]) {
			return false
		}
		if !restriction_implies(source, delegates, right_values[2], left_values[2]) {
			stricter = true
		}
	}
	return stricter
}

@(private)
param_for_role :: proc(params: []v.Tuple, role: v.Value) -> v.Tuple {
	for param in params {
		if v.value_eq(v.tuple_values(param)[1], role) {
			return param
		}
	}
	return nil
}

@(private)
restriction_implies :: proc(
	source: ^Relation_Source,
	delegates: Relation_ID,
	specific, general: v.Value,
) -> bool {
	if v.value_eq(specific, general) || v.value_eq(general, unrestricted_marker()) {
		return true
	}
	if v.value_eq(specific, unrestricted_marker()) {
		return false
	}
	return matches_restriction(source, delegates, specific, general)
}

@(private)
params_match :: proc(
	source: ^Relation_Source,
	delegates: Relation_ID,
	roles: []Role_Pair,
	params: []v.Tuple,
) -> bool {
	for param in params {
		if param_mode(param) == PARAM_REST_MODE {
			continue
		}
		values := v.tuple_values(param)
		value, found := role_value(roles, values[1])
		if !found {
			return false
		}
		if !matches_restriction(source, delegates, value, values[2]) {
			return false
		}
	}
	return true
}

// Returns the first value bound to `role`.
role_value :: proc(roles: []Role_Pair, role: v.Value) -> (v.Value, bool) {
	for binding in roles {
		if v.value_eq(binding.role, role) {
			return binding.value, true
		}
	}
	return v.Value(0), false
}

@(private)
matches_restriction :: proc(
	source: ^Relation_Source,
	delegates: Relation_ID,
	value, restriction: v.Value,
) -> bool {
	if v.value_eq(restriction, unrestricted_marker()) {
		return true
	}
	if required_delegate, is_frob_only := restriction_frob_delegate(restriction); is_frob_only {
		delegate, is_frob := v.value_frob_delegate(value)
		if !is_frob {
			return false
		}
		return identity_matches(
			source,
			delegates,
			delegate,
			v.value_identity(required_delegate),
		)
	}
	if v.value_eq(value, restriction) {
		return true
	}

	if _, is_frob := v.value_as_frob(value); !is_frob {
		if delegates_reaches(source, delegates, value, restriction) {
			return true
		}
	}

	if identity, is_identity := v.value_as_identity(value); is_identity {
		if identity_matches(source, delegates, identity, restriction) {
			return true
		}
		return identity_matches(
			source,
			delegates,
			v.primitive_prototype_for_kind(v.value_kind(value)),
			restriction,
		)
	}

	if delegate, is_frob := v.value_frob_delegate(value); is_frob {
		if identity_matches(source, delegates, delegate, restriction) {
			return true
		}
		return identity_matches(source, delegates, v.FROB_PROTOTYPE, restriction)
	}

	prototype := v.primitive_prototype_for_kind(v.value_kind(value))
	return identity_matches(source, delegates, prototype, restriction)
}

// Returns the required delegate when `restriction` is a frob-only marker.
@(private)
restriction_frob_delegate :: proc(restriction: v.Value) -> (v.Identity, bool) {
	delegate, is_frob := v.value_frob_delegate(restriction)
	if !is_frob {
		return v.Identity(0), false
	}
	payload, has_payload := v.value_frob_value(restriction)
	if !has_payload || !v.value_eq(payload, frob_only_marker()) {
		return v.Identity(0), false
	}
	return delegate, true
}

@(private)
identity_matches :: proc(
	source: ^Relation_Source,
	delegates: Relation_ID,
	identity: v.Identity,
	restriction: v.Value,
) -> bool {
	prototype := v.value_identity(identity)
	if v.value_eq(prototype, restriction) {
		return true
	}
	return delegates_reaches(source, delegates, prototype, restriction)
}

// Returns the function index registered for `method`.
dispatch_method_program :: proc(
	source: ^Relation_Source,
	method_program: Relation_ID,
	method: v.Value,
) -> (v.Value, bool) {
	rows: [dynamic]v.Tuple
	defer delete(rows)
	relation_source_scan_into(
		source,
		method_program,
		[]v.Binding{v.binding_of(method), {}},
		&rows,
	)
	if len(rows) == 0 {
		return v.Value(0), false
	}
	return v.tuple_values(rows[0])[1], true
}

// Orders the call's role values by each parameter's declared position.
dispatch_method_args :: proc(
	params: []v.Tuple,
	roles: []Role_Pair,
	allocator: mem.Allocator,
) -> ([]v.Value, bool) {
	ordered := make([]v.Tuple, len(params), allocator)
	copy(ordered, params)
	slice.sort_by(ordered, proc(a, b: v.Tuple) -> bool {
		return param_position(a) < param_position(b)
	})
	arguments := make([dynamic]v.Value, 0, len(ordered), allocator)
	for param in ordered {
		if param_mode(param) == PARAM_REST_MODE {
			continue
		}
		role := v.tuple_values(param)[1]
		value, found := role_value(roles, role)
		if !found {
			return nil, false
		}
		append(&arguments, value)
	}
	return arguments[:], true
}

@(private)
param_position :: proc(param: v.Tuple) -> i64 {
	values := v.tuple_values(param)
	if len(values) < 4 {
		return i64(0x7fff_ffff_ffff_ffff)
	}
	position, ok := v.value_as_int(values[3])
	if !ok {
		return i64(0x7fff_ffff_ffff_ffff)
	}
	return position & 0xffff
}
