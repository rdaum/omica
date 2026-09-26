// Host builtin library: the low-level verbs fileins call by name.
//
// The scalar string surface mirrors the Rust runtime's `builtins/scalar.rs`;
// strings are indexed by Unicode scalar position, not bytes.
package mica_runtime

import "core:encoding/base64"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import c "../compiler"
import k "../kernel"
import dom "../dom"
import vm "../vm"
import v "../var"

@(private)
Builtin_Spec :: struct {
	name: string,
	argc: int,
	run:  vm.Builtin_Proc,
}

// A negative arity is variadic: the VM reads the argument count from the
// calling instruction.
@(private)
runtime_builtins := [?]Builtin_Spec {
	{"make_identity", -1, builtin_make_identity},
	{"compile", -1, builtin_compile},
	{"install_source", -1, builtin_install_source},
	{"destroy_identity", 1, builtin_destroy_identity},
	{"make_relation", -1, builtin_make_relation},
	{"make_functional_relation", -1, builtin_make_functional_relation},
	// Variadic: the third argument is the conflict policy.
	{"make_buffer", -1, builtin_make_buffer},
	{"buffer_insert", 3, builtin_buffer_insert},
	{"buffer_delete", 3, builtin_buffer_delete},
	{"buffer_replace", 4, builtin_buffer_replace},
	{"buffer_len", 1, builtin_buffer_len},
	{"buffer_line_count", 1, builtin_buffer_line_count},
	{"buffer_revision", 1, builtin_buffer_revision},
	{"buffer_compact", 1, builtin_buffer_compact},
	// Variadic: the optional fourth argument is a client token whose completion
	// can be read back with `buffer_apply_result`.
	{"buffer_apply", -1, builtin_buffer_apply},
	{"buffer_apply_result", 1, builtin_buffer_apply_result},
	// Reversion is its own builtin so a world can grant it separately from
	// ordinary writes: it discards every edit committed since the target.
	{"buffer_revert", 3, builtin_buffer_revert},
	// A pure helper over a committed delta: move a position through it.
	{"buffer_marker_rebase", 3, builtin_buffer_marker_rebase},
	{"kill_buffer", 1, builtin_kill_buffer},
	{"buffer_text", 1, builtin_buffer_text},
	{"buffer_slice", 3, builtin_buffer_slice},
	{"buffer_find", 4, builtin_buffer_find},
	{"buffer_lines", 3, builtin_buffer_lines},
	// Navigation: bounded line and column arithmetic for cursor movement and
	// viewport rendering, without materializing line text.
	{"buffer_line_span", 2, builtin_buffer_line_span},
	{"buffer_position_line_column", 2, builtin_buffer_position_line_column},
	{"buffer_line_column_offset", 3, builtin_buffer_line_column_offset},
	{"buffer_viewport", 4, builtin_buffer_viewport},
	{"__set_field", 3, builtin_set_field},
	{"__get_field", 2, builtin_get_field},
	// `emit` is a no-op in this port: effects are not recorded (see
	// mdbook/src/language/effects-hosts.md). It stays callable so existing
	// fileins load, but it discards its arguments.
	{"emit", 2, builtin_noop},
	{"require", 1, builtin_require},
	{"frob", 2, builtin_frob},
	{"frob_delegate", 1, builtin_frob_delegate},
	{"frob_value", 1, builtin_frob_value},
	{"is_frob", 1, builtin_is_frob},
	{"string_len", 1, builtin_string_len},
	{"string_chars", 1, builtin_string_chars},
	{"string_slice", 3, builtin_string_slice},
	{"string_span", 3, builtin_string_span},
	{"string_find_any", 3, builtin_string_find_any},
	{"string_from_chars", 1, builtin_string_from_chars},
	{"string_concat", -1, builtin_string_concat},
	{"string_append", 2, builtin_string_append},
	{"string_join", 2, builtin_string_join},
	{"string_starts_with", 2, builtin_string_starts_with},
	{"string_contains", 2, builtin_string_contains},
	{"string_equal_fold", 2, builtin_string_equal_fold},
	{"lower", 1, builtin_lower},
	{"words", 1, builtin_words},
	{"sort", 1, builtin_sort},
	{"edit_distance", 2, builtin_edit_distance},
	{"parse_ordinal", 1, builtin_parse_ordinal},
	{"__list_concat", -1, builtin_list_concat},
	{"__list_append", 2, builtin_list_append},
	{"__list_slice", 3, builtin_list_slice},
	{"__index_option", 2, builtin_index_option},
	{"__len_option", 1, builtin_len_option},
	{"__set_index", 3, builtin_set_index},
	{"to_symbol", 1, builtin_to_symbol},
	{"to_float", 1, builtin_to_float},
	{"to_int", 1, builtin_to_int},
	{"parse_int", 1, builtin_parse_int},
	{"parse_float", 1, builtin_parse_float},
	{"map_pairs", 1, builtin_map_pairs},
	{"index_or", 3, builtin_index_or},
	{"url_encode_component", 1, builtin_url_encode_component},
	{"url_decode_component", 1, builtin_url_decode_component},
	{"os_getenv", 1, builtin_os_getenv},
	{"to_literal", 1, builtin_to_literal},
	{"endpoint", 0, builtin_endpoint},
	{"actor", 0, builtin_actor},
	{"principal", 0, builtin_principal},
	{"dom_text", 1, builtin_dom_text},
	{"dom_raw", 1, builtin_dom_raw},
	{"dom_element", 3, builtin_dom_element},
	{"dom_diff", 2, builtin_dom_diff},
	{"dom_html", 1, builtin_dom_html},
	{"from_xml", 1, builtin_from_xml},
	{"to_xml", 1, builtin_to_xml},
	{"sync_signature", 2, builtin_sync_signature},
	{"dom_snapshot_payload", 3, builtin_dom_snapshot_payload},
	{"embed_text", 2, builtin_embed_text},
	{"from_literal", 1, builtin_from_literal},
	{"mint_capability", -1, builtin_mint_capability},
	{"use_capability", 1, builtin_use_capability},
	{"restrict_capability", 2, builtin_restrict_capability},
	{"revoke_capability", 1, builtin_revoke_capability},
	{"drop_capability", 1, builtin_drop_capability},
	{"assume_actor", 1, builtin_assume_actor},
	{"enable_rule", 1, builtin_enable_rule},
	{"disable_rule", 1, builtin_disable_rule},
	{"rules", 1, builtin_rules},
	{"__is_builtin", 1, builtin_is_builtin},
	{"__identity", 1, builtin_named_identity},
	{"__bytes", 1, builtin_bytes_literal},
	{"describe_rule", 1, builtin_describe_rule},
	{"fileout", 1, builtin_fileout},
	{"fileout_rules", -1, builtin_fileout_rules},
	{"tasks", 0, builtin_tasks},
	{"log", -1, builtin_log},
	{"__relation_literal", 2, builtin_relation_literal},
	{"__relation_assert", 2, builtin_relation_assert},
	{"__relation_retract", 2, builtin_relation_retract},
	{"assemble", 1, builtin_assemble},
	{"project", -1, builtin_project},
	{"union", 2, builtin_union},
	{"difference", 2, builtin_difference},
	{"natural_join", 2, builtin_natural_join},
	{"json_encode", 1, builtin_json_encode},
	{"json_decode", 1, builtin_json_decode},
	{"json_null", 0, builtin_json_null},
	{"json_is_null", 1, builtin_json_is_null},
	{"subscribe_changes", -1, builtin_subscribe_changes},
	{"cancel_subscription", 1, builtin_cancel_subscription},
	{"mailbox", 0, builtin_mailbox},
	{"mailbox_send", 2, builtin_mailbox_send},
	{"mailbox_close", 1, builtin_mailbox_close},
	{"mailbox_recv", 1, builtin_mailbox_recv},
	{"external_request", 2, builtin_external_request},
	{"openai_chat_completion", 2, builtin_host_request},
	{"openai_chat_completion_with_options", 3, builtin_host_request},
	{"llm_chat_stream_to", 5, builtin_host_request},
	{"llm_responses_stream", 6, builtin_host_request},
}

@(private)
install_builtin_names :: proc(ctx: ^c.Compile_Context) {
	for spec in runtime_builtins {
		ctx.builtins[spec.name] = true
	}
}

primitive_identities :: [?]struct {
	name: string,
	id:   v.Identity,
} {
	{"bool", v.BOOL_PROTOTYPE},
	{"integer", v.INTEGER_PROTOTYPE},
	{"float", v.FLOAT_PROTOTYPE},
	{"identity", v.IDENTITY_PROTOTYPE},
	{"symbol", v.SYMBOL_PROTOTYPE},
	{"error_code", v.ERROR_CODE_PROTOTYPE},
	{"string", v.STRING_PROTOTYPE},
	{"bytes", v.BYTES_PROTOTYPE},
	{"list", v.LIST_PROTOTYPE},
	{"map", v.MAP_PROTOTYPE},
	{"range", v.RANGE_PROTOTYPE},
	{"error", v.ERROR_PROTOTYPE},
	{"capability", v.CAPABILITY_PROTOTYPE},
	{"frob", v.FROB_PROTOTYPE},
	{"function", v.FUNCTION_PROTOTYPE},
	{"relation", v.RELATION_PROTOTYPE},
}

// Primitive prototype identities such as `#string` and `#identity` are always
// available to source, independent of any `make_identity` declarations.
@(private)
install_primitive_identities :: proc(ctx: ^c.Compile_Context) {

	for prototype in primitive_identities {
		ctx.identities[prototype.name] = v.value_identity(prototype.id)
	}
}

@(private)
register_runtime_builtins :: proc(state: ^vm.VM) {
	for spec in runtime_builtins {
		vm.vm_register_builtin(state, v.symbol_intern(spec.name), spec.argc, spec.run)
	}
	vm.vm_resolve_builtins(state)
}

@(private)
builtin_endpoint :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 0 {
		return builtin_error(state, "E_INVARG", "endpoint expects no arguments")
	}
	return state.endpoint, true
}

@(private)
builtin_actor :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 0 {
		return builtin_error(state, "E_INVARG", "actor expects no arguments")
	}
	if v.value_is_empty_relation(state.actor) {
		return option_none_value(state.allocator), true
	}
	return option_some_value(state.allocator, state.actor), true
}

@(private)
builtin_principal :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 0 {
		return builtin_error(state, "E_INVARG", "principal expects no arguments")
	}
	if v.value_is_empty_relation(state.principal) {
		return option_none_value(state.allocator), true
	}
	return option_some_value(state.allocator, state.principal), true
}

@(private)
builtin_assume_actor :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	env := builtin_env(state)
	if len(args) != 1 {
		return builtin_error(state, "E_INVARG", "assume_actor expects one identity")
	}
	actor_value, is_identity := v.value_as_identity(args[0])
	if !is_identity {
		return builtin_error(state, "E_TYPE", "assume_actor expects an identity")
	}
	if !actor_assumption_allowed(state, actor_value) {
		return builtin_error(state, "E_PERMISSION", "actor assumption denied")
	}

	previous_actor := state.actor
	state.actor = args[0]

	// Refresh the task's authority for the new actor, preserving adopted
	// capability grants.
	if state.authority != nil && !state.authority.root {
		previous_epoch := state.authority.epoch
		previous_now := state.authority.now
		adopted: [dynamic]^k.Capability_Grant
		defer delete(adopted)
		for grant in state.authority.capabilities {
			k.capability_retain(grant)
			append(&adopted, grant)
		}
		snapshot := k.kernel_snapshot(env.kernel)
		source := k.Relation_Source {
			kernel   = env.kernel,
			snapshot = snapshot,
		}
		k.authority_destroy(state.authority)
		state.authority^ = k.authority_from_actor(
			&source,
			actor_value,
			env.allocator,
		)
		// Keep the execution clock: a fresh authority starts at epoch/now 0,
		// which would make already-expired grants appear live again.
		k.authority_set_clock(state.authority, previous_epoch, previous_now)
		k.snapshot_release(snapshot)
		for grant in adopted {
			k.authority_adopt_capability(state.authority, grant)
			k.capability_release(grant)
		}
	}

	// Record the endpoint binding for the current endpoint.
	if state.transaction != nil && !v.value_is_empty_relation(state.endpoint) {
		if err := k.transaction_retract(
			state.transaction,
			k.SYSTEM_ENDPOINT_ACTOR_ID,
			v.tuple_new(context.temp_allocator, []v.Value{state.endpoint, previous_actor}),
		); err != .None {
			return builtin_error(
				state,
				"E_KERNEL",
				"assume_actor could not retract the previous endpoint binding",
			)
		}
		if err := k.transaction_assert(
			state.transaction,
			k.SYSTEM_ENDPOINT_ACTOR_ID,
			v.tuple_new(context.temp_allocator, []v.Value{state.endpoint, args[0]}),
		); err != .None {
			return builtin_error(
				state,
				"E_KERNEL",
				"assume_actor could not record the endpoint binding",
			)
		}
	}
	return v.value_bool(true), true
}

// The caller may assume an actor when it has grant authority or when the
// principal policy allows it.
@(private)
actor_assumption_allowed :: proc(state: ^vm.VM, actor: v.Identity) -> bool {
	if k.authority_can_grant(state.authority) {
		return true
	}
	relation, found := runtime_relation_named(state, "session/CanAssumeActor")
	if !found || state.transaction == nil {
		return false
	}
	rows: [dynamic]v.Tuple
	defer delete(rows)
	source := k.Relation_Source {
		transaction = state.transaction,
	}
	k.relation_source_scan_into(
		&source,
		k.Relation_ID(relation),
		[]v.Binding{
			v.binding_of(state.principal),
			v.binding_of(v.value_identity(actor)),
		},
		&rows,
	)
	return len(rows) > 0
}

@(private)
builtin_dom_text :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	text, is_string := v.value_as_string(args[0])
	if !is_string {
		return builtin_error(state, "E_TYPE", "dom_text expects a string")
	}
	return v.value_map(state.allocator, []v.Map_Entry {
		{
			key   = v.value_symbol(v.symbol_intern("text")),
			value = v.value_string(state.allocator, text),
		},
	}), true
}

@(private)
builtin_dom_raw :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	text, is_string := v.value_as_string(args[0])
	if !is_string {
		return builtin_error(state, "E_TYPE", "dom_raw expects a string")
	}
	return v.value_map(state.allocator, []v.Map_Entry {
		{
			key   = v.value_symbol(v.symbol_intern("raw")),
			value = v.value_string(state.allocator, text),
		},
	}), true
}

@(private)
builtin_dom_element :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	tag, is_string := v.value_as_string(args[0])
	if !is_string {
		return builtin_error(state, "E_TYPE", "dom_element tag is not a string")
	}
	if _, is_map := v.value_as_map(args[1]); !is_map {
		return builtin_error(state, "E_TYPE", "dom_element attrs are not a map")
	}
	if _, is_list := v.value_as_list(args[2]); !is_list {
		return builtin_error(state, "E_TYPE", "dom_element children are not a list")
	}
	return v.value_map(state.allocator, []v.Map_Entry {
		{key = v.value_symbol(v.symbol_intern("attrs")), value = args[1]},
		{key = v.value_symbol(v.symbol_intern("children")), value = args[2]},
		{
			key   = v.value_symbol(v.symbol_intern("tag")),
			value = v.value_string(state.allocator, tag),
		},
	}), true
}

@(private)
write_xml_text :: proc(builder: ^strings.Builder, text: string) {
	for ch in text {
		switch ch {
		case '&':
			strings.write_string(builder, "&amp;")
		case '<':
			strings.write_string(builder, "&lt;")
		case '>':
			strings.write_string(builder, "&gt;")
		case:
			strings.write_rune(builder, ch)
		}
	}
}

@(private)
write_xml_attribute :: proc(builder: ^strings.Builder, text: string) {
	for ch in text {
		switch ch {
		case '&':
			strings.write_string(builder, "&amp;")
		case '<':
			strings.write_string(builder, "&lt;")
		case '>':
			strings.write_string(builder, "&gt;")
		case '"':
			strings.write_string(builder, "&quot;")
		case:
			strings.write_rune(builder, ch)
		}
	}
}

@(private)
write_xml_value :: proc(builder: ^strings.Builder, value: v.Value) -> bool {
	if text, is_string := v.value_as_string(value); is_string {
		write_xml_text(builder, text)
		return true
	}
	if boolean, is_bool := v.value_as_bool(value); is_bool {
		strings.write_string(builder, boolean ? "true" : "false")
		return true
	}
	if integer, is_int := v.value_as_int(value); is_int {
		fmt.sbprintf(builder, "%d", integer)
		return true
	}
	return false
}

// Writes a DOM value as XML or HTML. In HTML mode, tags and attributes are
// restricted to the supported DOM surface, matching `dom_html` in the Rust
// runtime. Attribute names may be strings or named symbols.
@(private)
write_markup_node :: proc(builder: ^strings.Builder, value: v.Value, html: bool) -> bool {
	if _, is_list := v.value_as_list(value); is_list {
		nodes, _ := v.value_as_list(value)
		for node in nodes {
			if !write_markup_node(builder, node, html) {
				return false
			}
		}
		return true
	}

	entries, is_map := v.value_as_map(value)
	if !is_map {
		return write_xml_value(builder, value)
	}

	text: v.Value
	has_text := false
	raw: v.Value
	has_raw := false
	tag: v.Value
	has_tag := false
	attrs: v.Value
	has_attrs := false
	children: v.Value
	has_children := false
	for entry in entries {
		name, _ := v.value_as_symbol(entry.key)
		name_text, name_ok := v.symbol_name(name)
		if !name_ok {
			continue
		}
		switch name_text {
		case "text":
			text, has_text = entry.value, true
		case "raw":
			raw, has_raw = entry.value, true
		case "tag":
			tag, has_tag = entry.value, true
		case "attrs":
			attrs, has_attrs = entry.value, true
		case "children":
			children, has_children = entry.value, true
		}
	}

	if has_text {
		contents, _ := v.value_as_string(text)
		write_xml_text(builder, contents)
		return true
	}
	if has_raw {
		contents, _ := v.value_as_string(raw)
		strings.write_string(builder, contents)
		return true
	}
	if !has_tag {
		return false
	}
	tag_text, tag_ok := v.value_as_string(tag)
	if !tag_ok {
		return false
	}
	if html && !dom.is_supported_dom_tag(tag_text) {
		return false
	}
	strings.write_byte(builder, '<')
	strings.write_string(builder, tag_text)
	if has_attrs {
		attribute_entries, is_attrs := v.value_as_map(attrs)
		if !is_attrs {
			return false
		}
		for entry in attribute_entries {
			name_text, name_ok := markup_attribute_name(entry.key)
			if !name_ok {
				return false
			}
			if html && !dom.is_supported_dom_attribute(name_text) {
				return false
			}
			strings.write_byte(builder, ' ')
			strings.write_string(builder, name_text)
			strings.write_string(builder, "=\"")
			if contents, is_string := v.value_as_string(entry.value); is_string {
				write_xml_attribute(builder, contents)
			} else if !write_xml_value(builder, entry.value) {
				return false
			}
			strings.write_byte(builder, '"')
		}
	}
	strings.write_byte(builder, '>')
	if has_children {
		if !write_markup_node(builder, children, html) {
			return false
		}
	}
	strings.write_string(builder, "</")
	strings.write_string(builder, tag_text)
	strings.write_byte(builder, '>')
	return true
}

// Attribute names are strings or named symbols, matching the Rust host.
@(private)
markup_attribute_name :: proc(value: v.Value) -> (string, bool) {
	if text, is_string := v.value_as_string(value); is_string {
		return text, true
	}
	if symbol, is_symbol := v.value_as_symbol(value); is_symbol {
		return v.symbol_name(symbol)
	}
	return "", false
}

@(private)
builtin_dom_html :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	builder: strings.Builder
	strings.builder_init(&builder, state.allocator)
	if !write_markup_node(&builder, args[0], true) {
		strings.builder_destroy(&builder)
		return builtin_error(
			state,
			"E_TYPE",
			"dom_html expects DOM text, element, or node list with supported tags and attributes",
		)
	}
	return v.value_string(state.allocator, strings.to_string(builder)), true
}

@(private)
builtin_from_xml :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	text, is_string := v.value_as_string(args[0])
	if !is_string {
		return builtin_error(state, "E_TYPE", "from_xml expects XML text")
	}
	value, parse_error := dom.dom_parse_xml_value(text, state.allocator)
	if parse_error != "" {
		return builtin_error(state, "E_INVARG", parse_error)
	}
	return value, true
}

@(private)
builtin_to_xml :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	builder: strings.Builder
	strings.builder_init(&builder, state.allocator)
	if !write_markup_node(&builder, args[0], false) {
		strings.builder_destroy(&builder)
		return builtin_error(state, "E_TYPE", "to_xml expects DOM text, element, or node list")
	}
	return v.value_string(state.allocator, strings.to_string(builder)), true
}

@(private)
builtin_sync_signature :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	revision, is_int := v.value_as_int(args[0])
	if !is_int || revision < 0 {
		return builtin_error(
			state,
			"E_INVARG",
			"sync_signature revision must be a non-negative integer",
		)
	}
	payload, is_string := v.value_as_string(args[1])
	if !is_string {
		return builtin_error(state, "E_TYPE", "sync_signature payload must be a string")
	}
	hash := u64(0xcbf2_9ce4_8422_2325)
	raw_revision := u64(revision)
	for index in 0 ..< 8 {
		byte := u8(raw_revision >> (8 * u32(index)))
		hash = (hash ~ u64(byte)) * u64(0x0000_0100_0000_01b3)
	}
	for byte in transmute([]u8)payload {
		hash = (hash ~ u64(byte)) * u64(0x0000_0100_0000_01b3)
	}
	// Mica integers are 56-bit; the mask matches Rust's SIGNATURE_MASK.
	hash &= 0x007f_ffff_ffff_ffff
	result, _ := v.value_int(i64(hash))
	return result, true
}

@(private)
builtin_dom_snapshot_payload :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	view, view_ok := v.value_as_int(args[0])
	revision, revision_ok := v.value_as_int(args[1])
	if !view_ok || !revision_ok || view < 0 || revision < 0 {
		return builtin_error(
			state,
			"E_INVARG",
			"dom_snapshot_payload expects non-negative view and revision",
		)
	}
	node, node_error := dom.dom_node_from_value(args[2], state.allocator)
	if node_error != "" {
		return builtin_error(state, "E_TYPE", node_error)
	}
	payload := dom.dom_snapshot_payload_json(
		u64(view),
		u64(revision),
		node,
		state.allocator,
	)
	return v.value_string(state.allocator, payload), true
}

// A deterministic stand-in for a host embedding provider: hashes the text into
// eight floats so retrieval plans are reproducible without a model.
@(private)
builtin_embed_text :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	model, model_ok := v.value_as_string(args[0])
	if !model_ok {
		return builtin_error(state, "E_TYPE", "embed_text model must be a string")
	}
	text, text_ok := v.value_as_string(args[1])
	if !text_ok {
		return builtin_error(state, "E_TYPE", "embed_text text must be a string")
	}
	values := make([]v.Value, 8, context.temp_allocator)
	hash := u64(0xcbf2_9ce4_8422_2325)
	input := strings.concatenate([]string{model, "\x00", text}, context.temp_allocator)
	for byte in transmute([]u8)input {
		hash = (hash ~ u64(byte)) * u64(0x0000_0100_0000_01b3)
	}
	for index in 0 ..< len(values) {
		hash = (hash ~ u64(index)) * u64(0x0000_0100_0000_01b3)
		scaled := f32(f64(hash & 0xffff) / 65535.0)
		converted, converted_ok := v.value_float(scaled)
		if !converted_ok {
			return builtin_error(state, "E_RANGE", "embed_text produced a non-finite value")
		}
		values[index] = converted
	}
	return v.value_list(state.allocator, values), true
}

// Converts a DOM node back into the map shape `dom_element` and `dom_text`
// produce, matching `DomNode::to_mica_value` in the Rust host protocol.
@(private)
dom_node_to_value :: proc(node: dom.Dom_Node, allocator: mem.Allocator) -> v.Value {
	#partial switch n in node {
	case dom.Dom_Text:
		return v.value_map(allocator, []v.Map_Entry {
			{
				key   = v.value_symbol(v.symbol_intern("text")),
				value = v.value_string(allocator, n.text),
			},
		})
	case dom.Dom_Element:
		attrs := make([]v.Map_Entry, len(n.attrs), allocator)
		for attribute, index in n.attrs {
			attrs[index] = v.Map_Entry {
				key   = v.value_string(allocator, attribute.name),
				value = v.value_string(allocator, attribute.value),
			}
		}
		children := make([]v.Value, len(n.children), allocator)
		for child, index in n.children {
			children[index] = dom_node_to_value(child, allocator)
		}
		return v.value_map(allocator, []v.Map_Entry {
			{
				key   = v.value_symbol(v.symbol_intern("attrs")),
				value = v.value_map(allocator, attrs),
			},
			{
				key   = v.value_symbol(v.symbol_intern("children")),
				value = v.value_list(allocator, children),
			},
			{
				key   = v.value_symbol(v.symbol_intern("tag")),
				value = v.value_string(allocator, n.tag),
			},
		})
	}
	return v.value_map(allocator, []v.Map_Entry{})
}

// Converts one DOM patch into the map shape `DomPatch::to_mica_value` uses.
@(private)
dom_patch_to_value :: proc(patch: ^dom.Dom_Patch, allocator: mem.Allocator) -> v.Value {
	op: string
	extra: []v.Map_Entry
	path: []u64
	switch value in patch^ {
	case dom.Dom_Patch_Replace:
		op = "replace"
		path = value.path
		extra = []v.Map_Entry {{
			key   = v.value_symbol(v.symbol_intern("node")),
			value = dom_node_to_value(value.node, allocator),
		}}
	case dom.Dom_Patch_Set_Text:
		op = "set_text"
		path = value.path
		extra = []v.Map_Entry {{
			key   = v.value_symbol(v.symbol_intern("text")),
			value = v.value_string(allocator, value.text),
		}}
	case dom.Dom_Patch_Set_Attr:
		op = "set_attr"
		path = value.path
		extra = []v.Map_Entry {
			{
				key   = v.value_symbol(v.symbol_intern("name")),
				value = v.value_string(allocator, value.name),
			},
			{
				key   = v.value_symbol(v.symbol_intern("value")),
				value = v.value_string(allocator, value.value),
			},
		}
	case dom.Dom_Patch_Remove_Attr:
		op = "remove_attr"
		path = value.path
		extra = []v.Map_Entry {{
			key   = v.value_symbol(v.symbol_intern("name")),
			value = v.value_string(allocator, value.name),
		}}
	case dom.Dom_Patch_Append_Child:
		op = "append_child"
		path = value.path
		extra = []v.Map_Entry {{
			key   = v.value_symbol(v.symbol_intern("node")),
			value = dom_node_to_value(value.node, allocator),
		}}
	case dom.Dom_Patch_Insert_Child:
		op = "insert_child"
		path = value.path
		index, _ := v.value_int(i64(value.index))
		extra = []v.Map_Entry {
			{key = v.value_symbol(v.symbol_intern("index")), value = index},
			{
				key   = v.value_symbol(v.symbol_intern("node")),
				value = dom_node_to_value(value.node, allocator),
			},
		}
	case dom.Dom_Patch_Remove_Child:
		op = "remove_child"
		path = value.path
	}
	path_values := make([]v.Value, len(path), allocator)
	for position, index in path {
		path_values[index], _ = v.value_int(i64(position))
	}
	entries := make([]v.Map_Entry, 2 + len(extra), allocator)
	entries[0] = v.Map_Entry {
		key   = v.value_symbol(v.symbol_intern("op")),
		value = v.value_string(allocator, op),
	}
	entries[1] = v.Map_Entry {
		key   = v.value_symbol(v.symbol_intern("path")),
		value = v.value_list(allocator, path_values),
	}
	for entry, index in extra {
		entries[2 + index] = entry
	}
	return v.value_map(allocator, entries)
}

@(private)
builtin_dom_diff :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	before, before_error := dom.dom_node_from_value(args[0], state.allocator)
	if before_error != "" {
		return builtin_error(state, "E_TYPE", before_error)
	}
	defer dom.dom_node_release(before, state.allocator)
	after, after_error := dom.dom_node_from_value(args[1], state.allocator)
	if after_error != "" {
		return builtin_error(state, "E_TYPE", after_error)
	}
	defer dom.dom_node_release(after, state.allocator)

	path: [dynamic]u64
	path = make([dynamic]u64, state.allocator)
	defer delete(path)
	patches: [dynamic]dom.Dom_Patch
	patches = make([dynamic]dom.Dom_Patch, state.allocator)
	defer {
		for &patch in patches {
			dom.dom_patch_release(&patch, state.allocator)
		}
		delete(patches)
	}
	dom.dom_diff_nodes(before, after, &path, &patches, state.allocator)
	values := make([]v.Value, len(patches), state.allocator)
	for &patch, index in patches {
		values[index] = dom_patch_to_value(&patch, state.allocator)
	}
	return v.value_list(state.allocator, values), true
}

// `log(message)` and `log(:level, message)`: records a host-facing log line.
// Levels are `:trace`, `:debug`, `:info`, `:warn`, and `:error`.
@(private)
builtin_log :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 1 && len(args) != 2 {
		return builtin_error(state, "E_INVARG", "log expects log(message) or log(:level, message)")
	}
	if !k.authority_can_effect(state.authority) {
		return builtin_error(state, "E_PERMISSION", "log is not permitted")
	}
	level := "info"
	message_index := 0
	if len(args) == 2 {
		level_symbol, is_symbol := v.value_as_symbol(args[0])
		if !is_symbol {
			return builtin_error(state, "E_TYPE", "log level must be a symbol")
		}
		level_name, has_name := v.symbol_name(level_symbol)
		if !has_name {
			return builtin_error(state, "E_INVARG", "log level must be named")
		}
		level = level_name
		message_index = 1
	}
	message, is_string := v.value_as_string(args[message_index])
	if !is_string {
		return builtin_error(state, "E_TYPE", "log message must be a string")
	}
	switch level {
	case "trace", "debug", "info", "warn", "error":
	case:
		return builtin_error(
			state,
			"E_INVARG",
			"log level must be one of :trace, :debug, :info, :warn, or :error",
		)
	}
	fmt.eprintf("mica log [%s] %s\n", level, message)
	return v.value_empty_relation(), true
}

@(private)
literal_value :: proc(env: ^Builtin_Env, expr: ^c.Expr) -> (v.Value, bool) {
	#partial switch node in expr^ {
	case c.Int_Literal:
		number, parsed := strconv.parse_i64(node.text)
		if !parsed {
			return v.Value(0), false
		}
		converted, converted_ok := v.value_int(number)
		return converted, converted_ok

	case c.Float_Literal:
		number, parsed := strconv.parse_f64(node.text)
		if !parsed {
			return v.Value(0), false
		}
		converted, converted_ok := v.value_float(f32(number))
		return converted, converted_ok

	case c.String_Literal:
		return v.value_string(env.allocator, unquote(node.text)), true

	case c.Bool_Literal:
		return v.value_bool(node.value), true

	case c.Symbol_Literal:
		return v.value_symbol(v.symbol_intern(unquote(node.name))), true

	case c.Identity_Literal:
		if raw, parsed := strconv.parse_u64(node.name); parsed {
			return v.value_identity_raw(raw)
		}
		if value, found := env.ctx.identities[node.name]; found {
			return value, true
		}
		return v.Value(0), false

	case c.Error_Code_Literal:
		return v.value_error_code(v.symbol_intern(node.name)), true

	case c.Name:
		if len(node.parts) == 1 && node.parts[0] == "none" {
			empty, _ := v.value_relation(
				env.allocator,
				[]v.Symbol{v.symbol_intern("value")},
				nil,
			)
			return empty, true
		}
		return v.Value(0), false

	case c.List_Literal:
		values := make([]v.Value, len(node.elements), context.temp_allocator)
		for element, index in node.elements {
			value, element_ok := literal_value(env, element)
			if !element_ok {
				return v.Value(0), false
			}
			values[index] = value
		}
		return v.value_list(env.allocator, values), true

	case c.Map_Literal:
		entries := make([]v.Map_Entry, len(node.entries), context.temp_allocator)
		for entry, index in node.entries {
			key, key_ok := literal_value(env, entry.key)
			if !key_ok {
				return v.Value(0), false
			}
			value, value_ok := literal_value(env, entry.value)
			if !value_ok {
				return v.Value(0), false
			}
			entries[index] = v.Map_Entry{key = key, value = value}
		}
		return v.value_map(env.allocator, entries), true
	}
	return v.Value(0), false
}

@(private)
builtin_from_literal :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	text, is_string := string_argument(state, args, 0, "from_literal")
	if !is_string {
		return builtin_error(state, "E_TYPE", "from_literal expects a string")
	}
	ast, parse_errors := c.parse_program(text, context.temp_allocator)
	if len(parse_errors) > 0 {
		problem := v.value_error(
			state.allocator,
			v.symbol_intern("E_PARSE"),
			parse_errors[0].message,
			true,
			v.value_string(state.allocator, text),
			true,
		)
		return result_value(state.allocator, "error", problem), true
	}
	if len(ast.items) != 1 {
		problem := v.value_error(
			state.allocator,
			v.symbol_intern("E_PARSE"),
			"expected one literal expression",
			true,
			v.value_string(state.allocator, text),
			true,
		)
		return result_value(state.allocator, "error", problem), true
	}
	item, is_expr := ast.items[0].(c.Expr_Item)
	if !is_expr {
		problem := v.value_error(
			state.allocator,
			v.symbol_intern("E_TYPE"),
			"expected a literal expression",
			true,
			v.value_string(state.allocator, text),
			true,
		)
		return result_value(state.allocator, "error", problem), true
	}
	value, value_ok := literal_value(builtin_env(state), item.expr)
	if !value_ok {
		problem := v.value_error(
			state.allocator,
			v.symbol_intern("E_TYPE"),
			"unsupported literal expression",
			true,
			v.value_string(state.allocator, text),
			true,
		)
		return result_value(state.allocator, "error", problem), true
	}
	return result_value(state.allocator, "ok", value), true
}

@(private)
builtin_mailbox :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	env := builtin_env(state)
	if env.scheduler == nil {
		return builtin_error(state, "E_MAILBOX", "mailboxes need a running scheduler")
	}
	receiver, sender, ok := scheduler_mailbox_create(env.scheduler)
	if !ok {
		return builtin_error(state, "E_MAILBOX", "cannot create a mailbox")
	}
	return v.value_list(state.allocator, []v.Value{receiver, sender}), true
}

@(private)
builtin_mailbox_send :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	env := builtin_env(state)
	if env.scheduler == nil {
		return builtin_error(state, "E_MAILBOX", "mailboxes need a running scheduler")
	}
	// Stage the send until the task commits; an aborted task publishes nothing.
	if task := task_from_state(state); task != nil && task.has_tx {
		append(&task.pending_sends, Pending_Send {
			sender = args[0],
			value  = args[1],
		})
		return args[1], true
	}
	if !scheduler_mailbox_send(env.scheduler, args[0], args[1]) {
		return builtin_error(state, "E_MAILBOX", "mailbox_send expects a live sender capability")
	}
	return args[1], true
}

@(private)
builtin_mailbox_close :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	env := builtin_env(state)
	if env.scheduler == nil {
		return builtin_error(state, "E_MAILBOX", "mailboxes need a running scheduler")
	}
	if !scheduler_mailbox_close(env.scheduler, args[0]) {
		return builtin_error(state, "E_MAILBOX", "mailbox_close expects a live receiver capability")
	}
	_ = subscriptions_cancel_for_mailbox(env, args[0])
	return v.value_empty_relation(), true
}

@(private)
builtin_mailbox_recv :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	return builtin_error(state, "E_VM_FAULT", "mailbox_recv must be lowered to a VM op")
}

@(private)
builtin_external_request :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	return builtin_error(state, "E_VM_FAULT", "external_request must be lowered to a VM op")
}

// Host-request builtins such as `llm_responses_stream`. The compiler lowers
// them to `.External_Request`; reaching this body means the call was not
// recognized (for example because the name was invoked dynamically).
@(private)
builtin_host_request :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	return builtin_error(state, "E_VM_FAULT", "host request must be lowered to a VM op")
}

@(private)
builtin_mint_capability :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	env := builtin_env(state)
	if !k.authority_can_grant(state.authority) {
		return builtin_error(state, "E_PERMISSION", "capability minting denied")
	}
	if len(args) < 1 || len(args) > 3 {
		return builtin_error(
			state,
			"E_INVARG",
			"mint_capability expects rights, optional targets, and optional limits",
		)
	}
	rights, rights_ok := capability_rights_argument(state, args[0])
	if !rights_ok {
		return v.Value(0), false
	}
	scope := k.Capability_Scope.All
	relations: []k.Relation_ID
	selectors: []v.Symbol
	if len(args) >= 2 {
		parsed_scope, parsed_relations, parsed_selectors, targets_ok := capability_target_argument(
			state,
			env,
			args[1],
			rights,
		)
		if !targets_ok {
			return v.Value(0), false
		}
		scope = parsed_scope
		relations = parsed_relations
		selectors = parsed_selectors
	} else if !capability_rights_allow_all(rights) {
		// Absolute scopes (effect/grant) are fine without targets; read,
		// write, and invoke without targets mean "all".
	}
	limits := k.Capability_Limits{}
	if len(args) == 3 {
		parsed_limits, limits_ok := capability_limits_argument(state, env, args[2])
		if !limits_ok {
			return v.Value(0), false
		}
		limits = parsed_limits
	}
	value, minted := k.capability_store_mint(
		&env.kernel.capabilities,
		rights,
		scope,
		relations,
		selectors,
		limits,
	)
	if !minted {
		return builtin_error(state, "E_CAPABILITY", "cannot create capability")
	}
	return value, true
}

@(private)
builtin_use_capability :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	env := builtin_env(state)
	grant, found := k.capability_store_lookup_retained(&env.kernel.capabilities, args[0])
	if !found {
		return builtin_error(state, "E_INVARG", "unknown capability")
	}
	defer k.capability_release(grant)
	if grant.scope == .Mailbox || grant.scope == .Subscription {
		return builtin_error(state, "E_INVARG", "handle is not an authority capability")
	}
	if !k.capability_live(grant, kernel_version(env), time.tick_now()) {
		return builtin_error(state, "E_INVARG", "capability is revoked or expired")
	}
	k.authority_adopt_capability(state.authority, grant)
	return v.value_bool(true), true
}

@(private)
builtin_restrict_capability :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	env := builtin_env(state)
	parent, found := k.capability_store_lookup_retained(&env.kernel.capabilities, args[0])
	if !found {
		return builtin_error(state, "E_INVARG", "unknown capability")
	}
	defer k.capability_release(parent)
	if parent.scope == .Mailbox || parent.scope == .Subscription {
		return builtin_error(state, "E_INVARG", "handles cannot be restricted")
	}
	if !k.authority_holds_capability(state.authority, parent) &&
	   !k.authority_can_grant(state.authority) {
		return builtin_error(state, "E_PERMISSION", "capability restriction denied")
	}
	rights, rights_ok := capability_rights_argument(state, args[1])
	if !rights_ok {
		return v.Value(0), false
	}
	value, restricted := k.capability_store_restrict(
		&env.kernel.capabilities,
		args[0],
		rights,
	)
	if !restricted {
		return builtin_error(state, "E_INVARG", "cannot restrict capability")
	}
	return value, true
}

@(private)
builtin_revoke_capability :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	env := builtin_env(state)
	grant, found := k.capability_store_lookup_retained(&env.kernel.capabilities, args[0])
	if !found {
		return builtin_error(state, "E_INVARG", "unknown capability")
	}
	defer k.capability_release(grant)
	if !k.authority_holds_capability(state.authority, grant) &&
	   !k.authority_can_grant(state.authority) {
		return builtin_error(state, "E_PERMISSION", "capability revocation denied")
	}
	if !k.capability_store_revoke(&env.kernel.capabilities, args[0]) {
		return builtin_error(state, "E_INVARG", "capability is already revoked")
	}
	return v.value_bool(true), true
}

@(private)
builtin_drop_capability :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	env := builtin_env(state)
	grant, found := k.capability_store_lookup_retained(&env.kernel.capabilities, args[0])
	if !found {
		return builtin_error(state, "E_INVARG", "unknown capability")
	}
	defer k.capability_release(grant)
	return v.value_bool(k.authority_drop_capability(state.authority, grant)), true
}

// Parses a rights argument: a symbol or a list of symbols.
@(private)
capability_rights_argument :: proc(state: ^vm.VM, value: v.Value) -> (k.Rights, bool) {
	rights: k.Rights
	if list, is_list := v.value_as_list(value); is_list {
		for item in list {
			item_right, item_ok := capability_right(state, item)
			if !item_ok {
				return {}, false
			}
			rights += item_right
		}
	} else {
		right, right_ok := capability_right(state, value)
		if !right_ok {
			return {}, false
		}
		rights = right
	}
	if card(rights) == 0 {
		vm.vm_set_error(state, "E_INVARG", "capability needs at least one right")
		return {}, false
	}
	return rights, true
}

@(private)
capability_right :: proc(state: ^vm.VM, value: v.Value) -> (k.Rights, bool) {
	symbol, is_symbol := v.value_as_symbol(value)
	if !is_symbol {
		vm.vm_set_error(state, "E_TYPE", "capability rights must be symbols")
		return {}, false
	}
	name, name_ok := v.symbol_name(symbol)
	if !name_ok {
		vm.vm_set_error(state, "E_TYPE", "capability right is unknown")
		return {}, false
	}
	switch name {
	case "read":
		return {.Read}, true
	case "write":
		return {.Write}, true
	case "invoke":
		return {.Invoke}, true
	case "effect":
		return {.Effect}, true
	case "grant":
		return {.Grant}, true
	case "all":
		return {.Read, .Write, .Invoke, .Effect, .Grant}, true
	}
	vm.vm_set_error(state, "E_INVARG", "unknown capability right")
	return {}, false
}

@(private)
capability_rights_allow_all :: proc(rights: k.Rights) -> bool {
	return card(rights) > 0
}

// Parses a target argument. Read/write rights take relation names; invoke
// takes selectors; effect/grant take no targets.
@(private)
capability_target_argument :: proc(
	state: ^vm.VM,
	env: ^Builtin_Env,
	value: v.Value,
	rights: k.Rights,
) -> (
	scope: k.Capability_Scope,
	relations: []k.Relation_ID,
	selectors: []v.Symbol,
	ok: bool,
) {
	targets: [dynamic]v.Symbol
	defer delete(targets)
	if list, is_list := v.value_as_list(value); is_list {
		for item in list {
			symbol, is_symbol := v.value_as_symbol(item)
			if !is_symbol {
				vm.vm_set_error(state, "E_TYPE", "capability targets must be symbols")
				return .All, nil, nil, false
			}
			append(&targets, symbol)
		}
	} else if symbol, is_symbol := v.value_as_symbol(value); is_symbol {
		append(&targets, symbol)
	} else if v.value_is_empty_relation(value) {
		return .All, nil, nil, true
	} else {
		vm.vm_set_error(state, "E_TYPE", "capability targets must be symbols")
		return .All, nil, nil, false
	}
	if len(targets) == 0 {
		return .All, nil, nil, true
	}

	has_relation_rights := .Read in rights || .Write in rights
	has_selector_rights := .Invoke in rights
	if has_relation_rights && has_selector_rights {
		vm.vm_set_error(
			state,
			"E_INVARG",
			"cannot combine read/write and invoke rights on named targets",
		)
		return .All, nil, nil, false
	}
	if has_relation_rights {
		relation_targets := make([]k.Relation_ID, len(targets), context.temp_allocator)
		for target, index in targets {
			name, name_ok := v.symbol_name(target)
			if !name_ok {
				vm.vm_set_error(state, "E_TYPE", "capability target is unknown")
				return .All, nil, nil, false
			}
			relation, found := runtime_relation_named(state, name)
			if !found {
				vm.vm_set_error(state, "E_INVARG", "capability target is not a relation")
				return .All, nil, nil, false
			}
			relation_targets[index] = k.Relation_ID(relation)
		}
		return .Relations, relation_targets, nil, true
	}
	if has_selector_rights {
		selector_targets := make([]v.Symbol, len(targets), context.temp_allocator)
		copy(selector_targets, targets[:])
		return .Selectors, nil, selector_targets, true
	}
	vm.vm_set_error(state, "E_INVARG", "effect and grant capabilities take no targets")
	return .All, nil, nil, false
}

// Parses a limits map: `:ttl_millis`, `:epochs`, or `:epoch_limit`.
@(private)
capability_limits_argument :: proc(
	state: ^vm.VM,
	env: ^Builtin_Env,
	value: v.Value,
) -> (
	limits: k.Capability_Limits,
	ok: bool,
) {
	entries, is_map := v.value_as_map(value)
	if !is_map {
		vm.vm_set_error(state, "E_TYPE", "capability limits must be a map")
		return {}, false
	}
	version := kernel_version(env)
	for entry in entries {
		key, key_ok := v.value_as_symbol(entry.key)
		if !key_ok {
			vm.vm_set_error(state, "E_TYPE", "capability limit keys must be symbols")
			return {}, false
		}
		name, name_ok := v.symbol_name(key)
		if !name_ok {
			continue
		}
		number, number_ok := v.value_as_int(entry.value)
		if !number_ok || number < 0 {
			vm.vm_set_error(state, "E_INVARG", "capability limits must be non-negative integers")
			return {}, false
		}
		switch name {
		case "ttl_millis":
			limits.deadline = time.tick_add(
				time.tick_now(),
				time.Duration(number) * time.Millisecond,
			)
		case "epochs":
			limits.epoch_limit = version + u64(number)
		case "epoch_limit":
			limits.epoch_limit = u64(number)
		}
	}
	return limits, true
}

@(private)
kernel_version :: proc(env: ^Builtin_Env) -> u64 {
	snapshot := k.kernel_snapshot(env.kernel)
	defer k.snapshot_release(snapshot)
	return snapshot.version
}

@(private)
builtin_enable_rule :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	return rule_active_builtin(state, args, true)
}

@(private)
builtin_disable_rule :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	return rule_active_builtin(state, args, false)
}

@(private)
rule_active_builtin :: proc(
	state: ^vm.VM,
	args: []v.Value,
	active: bool,
) -> (v.Value, bool) {
	env := builtin_env(state)
	if !k.authority_can_grant(state.authority) {
		return builtin_error(state, "E_PERMISSION", "rule administration denied")
	}
	if len(args) != 1 {
		return builtin_error(state, "E_INVARG", "rule administration expects a rule id")
	}
	rule_value := args[0]
	raw: u64
	if identity, is_identity := v.value_as_identity(rule_value); is_identity {
		raw = v.identity_raw(identity)
	} else if number, is_int := v.value_as_int(rule_value); is_int && number >= 0 {
		raw = u64(number)
	} else {
		return builtin_error(state, "E_TYPE", "rule id must be an identity or integer")
	}

	updated, err := k.kernel_set_rule_active(env.kernel, v.Identity(raw), active)
	if err != k.Kernel_Error.None {
		if err == .No_Such_Rule {
			return builtin_error(state, "E_INVARG", "unknown rule")
		}
		return builtin_error(state, "E_RULE", "rule update failed")
	}
	k.snapshot_release(updated)

	if state.transaction != nil {
		if err := k.transaction_retract(
			state.transaction,
			k.SYSTEM_ACTIVE_RULE_ID,
			v.tuple_new(context.temp_allocator, []v.Value{rule_value, v.value_bool(!active)}),
		); err != .None {
			return builtin_error(
				state,
				"E_KERNEL",
				"rule update could not retract the previous state",
			)
		}
		if err := k.transaction_assert(
			state.transaction,
			k.SYSTEM_ACTIVE_RULE_ID,
			v.tuple_new(context.temp_allocator, []v.Value{rule_value, v.value_bool(active)}),
		); err != .None {
			return builtin_error(
				state,
				"E_KERNEL",
				"rule update could not record the new state",
			)
		}
	}
	return v.value_bool(true), true
}


// Decodes a base64url byte literal (`b"3q2-7w=="`) at execution time. The
// Mica emitter has no base64 facility, so emitted code calls this.
@(private)
builtin_bytes_literal :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 1 {
		return builtin_error(state, "E_INVARG", "__bytes expects a literal")
	}
	text, is_string := v.value_as_string(args[0])
	if !is_string || len(text) < 3 || text[0] != 'b' || text[1] != '"' || text[len(text) - 1] != '"' {
		return builtin_error(state, "E_INVARG", "__bytes expects a byte literal")
	}
	decoded, decode_err := base64.decode(
		text[2:len(text) - 1],
		base64.DEC_URL_TABLE,
		nil,
		state.allocator,
	)
	if decode_err != nil {
		return builtin_error(state, "E_INVARG", "byte literal is not valid base64url")
	}
	return v.value_bytes(state.allocator, decoded), true
}

// Resolves a named identity (`#alice`) at execution time against the running
// world. The Mica emitter cannot resolve identity literals while emitting: it
// runs in a compiler world that does not know the target's identities, so
// emitted code calls this instead. A raw numeric identity (`#123`) needs no
// world. Tolerates a bare VM with no environment, which the differential
// harness uses.
@(private)
builtin_named_identity :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 1 {
		return builtin_error(state, "E_INVARG", "__identity expects a name")
	}
	name_symbol, is_symbol := v.value_as_symbol(args[0])
	if !is_symbol {
		return builtin_error(state, "E_TYPE", "__identity expects a symbol")
	}
	name, has_name := v.symbol_name(name_symbol)
	if !has_name {
		return builtin_error(state, "E_INVARG", "__identity expects an interned symbol")
	}
	if raw, parsed := strconv.parse_u64(name); parsed {
		return v.value_identity_raw(raw)
	}
	env := builtin_env(state)
	if env == nil || env.ctx == nil {
		return builtin_error(
			state,
			"E_INVARG",
			fmt.aprintf("unknown identity literal: %s", name, allocator = state.allocator),
		)
	}
	if value, found := env.ctx.identities[name]; found {
		return value, true
	}
	return builtin_error(
		state,
		"E_INVARG",
		fmt.aprintf("unknown identity literal: %s", name, allocator = state.allocator),
	)
}

// Reports whether a symbol names a runtime builtin. Unlike a relation, the
// builtin set is fixed and global, so the Mica emitter can call this at emit
// time to choose Builtin_Call over a relation scan.
@(private)
builtin_is_builtin :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 1 {
		return builtin_error(state, "E_INVARG", "__is_builtin expects a name")
	}
	name_symbol, is_symbol := v.value_as_symbol(args[0])
	if !is_symbol {
		return builtin_error(state, "E_TYPE", "__is_builtin expects a symbol")
	}
	name, has_name := v.symbol_name(name_symbol)
	if !has_name {
		return builtin_error(state, "E_INVARG", "__is_builtin expects an interned symbol")
	}
	env := builtin_env(state)
	return v.value_bool(env.ctx.builtins[name]), true
}

builtin_rules :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 1 {
		return builtin_error(state, "E_INVARG", "rules expects rules(:Relation)")
	}
	name_symbol, is_symbol := v.value_as_symbol(args[0])
	if !is_symbol {
		return builtin_error(state, "E_TYPE", "rules expects a relation name symbol")
	}
	name, has_name := v.symbol_name(name_symbol)
	if !has_name {
		return builtin_error(state, "E_INVARG", "rules expects a named relation symbol")
	}
	env := builtin_env(state)
	relation_id, known := runtime_relation_named(state, name)
	if !known {
		return builtin_error(
			state,
			"E_INVARG",
			fmt.aprintf("unknown relation :%s", name, allocator = state.allocator),
		)
	}
	snapshot := k.kernel_snapshot(env.kernel)
	defer k.snapshot_release(snapshot)
	rule_ids: [dynamic]v.Value
	rule_ids = make([dynamic]v.Value, state.allocator)
	for definition in snapshot.rules {
		if !definition.active || definition.rule.head_relation != k.Relation_ID(relation_id) {
			continue
		}
		identity, identity_ok := v.value_identity_raw(u64(definition.id))
		if identity_ok {
			append(&rule_ids, identity)
		}
	}
	return v.value_list(state.allocator, rule_ids[:]), true
}

@(private)
builtin_describe_rule :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 1 {
		return builtin_error(state, "E_INVARG", "describe_rule expects describe_rule(#rule)")
	}
	rule_value := args[0]
	raw: u64
	if identity, is_identity := v.value_as_identity(rule_value); is_identity {
		raw = v.identity_raw(identity)
	} else if number, is_int := v.value_as_int(rule_value); is_int && number >= 0 {
		raw = u64(number)
	} else {
		return builtin_error(state, "E_TYPE", "rule id must be an identity or integer")
	}
	env := builtin_env(state)
	snapshot := k.kernel_snapshot(env.kernel)
	defer k.snapshot_release(snapshot)
	for definition in snapshot.rules {
		if v.identity_raw(definition.id) != raw {
			continue
		}
		return v.value_string(state.allocator, definition.source), true
	}
	return builtin_error(state, "E_INVARG", "rule does not exist")
}

// `fileout(:unit)`: the source text loaded for a filein unit.
@(private)
builtin_fileout :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 1 {
		return builtin_error(state, "E_INVARG", "fileout expects fileout(:unit)")
	}
	name_symbol, is_symbol := v.value_as_symbol(args[0])
	if !is_symbol {
		return builtin_error(state, "E_TYPE", "fileout expects a unit symbol")
	}
	name, has_name := v.symbol_name(name_symbol)
	if !has_name {
		return builtin_error(state, "E_INVARG", "fileout expects a named unit symbol")
	}
	env := builtin_env(state)
	source, found := env.unit_sources[name]
	if !found {
		return builtin_error(
			state,
			"E_INVARG",
			fmt.aprintf("unknown filein unit :%s", name, allocator = state.allocator),
		)
	}
	return v.value_string(state.allocator, source), true
}

// `fileout_rules([:Relation])`: active rule source, optionally filtered to one
// head relation. Rules are separated by a blank line.
@(private)
builtin_fileout_rules :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) > 1 {
		return builtin_error(
			state,
			"E_INVARG",
			"fileout_rules expects fileout_rules() or fileout_rules(:Relation)",
		)
	}
	env := builtin_env(state)
	relation_id := k.Relation_ID(0)
	filter := false
	if len(args) == 1 {
		name_symbol, is_symbol := v.value_as_symbol(args[0])
		if !is_symbol {
			return builtin_error(state, "E_TYPE", "fileout_rules expects a relation name symbol")
		}
		name, has_name := v.symbol_name(name_symbol)
		if !has_name {
			return builtin_error(state, "E_INVARG", "fileout_rules expects a named relation symbol")
		}
		known_id, known := runtime_relation_named(state, name)
		if !known {
			return builtin_error(
				state,
				"E_INVARG",
				fmt.aprintf("unknown relation :%s", name, allocator = state.allocator),
			)
		}
		relation_id = k.Relation_ID(known_id)
		filter = true
	}
	snapshot := k.kernel_snapshot(env.kernel)
	defer k.snapshot_release(snapshot)
	builder: strings.Builder
	strings.builder_init(&builder, state.allocator)
	first := true
	for definition in snapshot.rules {
		if !definition.active {
			continue
		}
		if filter && definition.rule.head_relation != relation_id {
			continue
		}
		if !first {
			strings.write_string(&builder, "\n\n")
		}
		first = false
		strings.write_string(&builder, definition.source)
	}
	return v.value_string(state.allocator, strings.to_string(builder)), true
}

// `tasks()`: snapshots of managed tasks as `[:id, :state]` maps.
@(private)
builtin_tasks :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 0 {
		return builtin_error(state, "E_INVARG", "tasks expects tasks()")
	}
	env := builtin_env(state)
	if env.scheduler == nil {
		return v.value_list(state.allocator, nil), true
	}
	return v.value_list(
		state.allocator,
		scheduler_task_values(env.scheduler, state.allocator),
	), true
}

@(private)
builtin_json_encode :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	builder: strings.Builder
	strings.builder_init(&builder, state.allocator)
	if !json_encode_value(&builder, args[0]) {
		strings.builder_destroy(&builder)
		return builtin_error(state, "E_INVARG", "value cannot be encoded as JSON")
	}
	return v.value_string(state.allocator, strings.to_string(builder)), true
}

@(private)
builtin_json_decode :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	text, text_ok := string_argument(state, args, 0, "json_decode")
	if !text_ok {
		return builtin_error(state, "E_TYPE", "json_decode expects a string")
	}
	value, message, decoded := json_decode_text(state.allocator, text)
	if !decoded {
		return builtin_error(state, "E_INVARG", message)
	}
	return value, true
}

@(private)
builtin_json_null :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 0 {
		return builtin_error(state, "E_INVARG", "json_null expects no arguments")
	}
	return json_null(state.allocator), true
}

@(private)
builtin_json_is_null :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 1 {
		return builtin_error(state, "E_INVARG", "json_is_null expects one argument")
	}
	return v.value_bool(json_value_is_null(args[0])), true
}

@(private)
builtin_subscribe_changes :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	env := builtin_env(state)
	if env.scheduler == nil {
		return builtin_error(state, "E_INVARG", "subscriptions need a running scheduler")
	}
	if len(args) < 5 || len(args) > 7 {
		return builtin_error(
			state,
			"E_INVARG",
			"subscribe_changes expects sender, subject, relation, bindings, initial[, cursor[, queue_budget]]",
		)
	}
	sender := args[0]
	if !scheduler_mailbox_sender_handle_live(env.scheduler, sender) {
		return builtin_error(state, "E_INVARG", "subscription sender must be a live mailbox sender")
	}

	subject_symbol, subject_ok := v.value_as_symbol(args[1])
	if !subject_ok {
		return builtin_error(state, "E_TYPE", "subscription subject must be a symbol")
	}
	subject_name, subject_name_ok := v.symbol_name(subject_symbol)
	subject: Subscription_Subject
	switch subject_name {
	case "facts":
		subject = .Facts
	case "relation":
		subject = .Relation
	case "buffer":
		subject = .Buffer
	case "catalogue":
		subject = .Catalogue
	case:
		subject_name_ok = false
	}
	if !subject_name_ok {
		return builtin_error(state, "E_INVARG", "unsupported subscription subject")
	}
	if subject == .Catalogue && !(state.authority == nil || state.authority.root) {
		return builtin_error(state, "E_PERMISSION", "catalogue subscriptions require root authority")
	}

	relation_value, has_relation := option_payload(args[2])
	relation_id: k.Relation_ID
	if subject == .Catalogue {
		if has_relation {
			return builtin_error(state, "E_INVARG", "catalogue subscriptions take no relation")
		}
	} else {
		if !has_relation {
			return builtin_error(state, "E_INVARG", "subscription needs a relation")
		}
		relation_symbol, relation_ok := v.value_as_symbol(relation_value)
		if !relation_ok {
			return builtin_error(state, "E_TYPE", "subscription relation must be a symbol")
		}
		relation_name, relation_name_ok := v.symbol_name(relation_symbol)
		if !relation_name_ok {
			return builtin_error(state, "E_INVARG", "unknown subscription relation")
		}
		relation, found := runtime_relation_named(state, relation_name)
		if !found {
			return builtin_error(state, "E_INVARG", "unknown subscription relation")
		}
		if subject == .Buffer {
			snapshot := k.kernel_snapshot(env.kernel)
			metadata, known := k.snapshot_relation_metadata(snapshot, k.Relation_ID(relation))
			k.snapshot_release(snapshot)
			if !known || metadata.storage != .Buffer {
				return builtin_error(state, "E_INVARG", "the name is not a buffer")
			}
		}
		if !k.authority_can_read(state.authority, k.Relation_ID(relation)) {
			return builtin_error(state, "E_PERMISSION", "subscription relation read denied")
		}
		relation_id = k.Relation_ID(relation)
	}

	binding_list, bindings_ok := v.value_as_list(args[3])
	if !bindings_ok {
		return builtin_error(state, "E_TYPE", "subscription bindings must be a list")
	}
	if subject == .Catalogue && len(binding_list) != 0 {
		return builtin_error(state, "E_INVARG", "catalogue subscriptions take no bindings")
	}
	if subject == .Buffer && len(binding_list) != 0 {
		return builtin_error(state, "E_INVARG", "buffer subscriptions take no bindings")
	}
	bindings := make([]v.Binding, len(binding_list), context.temp_allocator)
	for item, index in binding_list {
		payload, has_payload := option_payload(item)
		if has_payload {
			bindings[index] = v.binding_of(payload)
		} else {
			bindings[index] = v.Binding{}
		}
	}

	initial_symbol, initial_ok := v.value_as_symbol(args[4])
	if !initial_ok {
		return builtin_error(state, "E_TYPE", "subscription initial mode must be a symbol")
	}
	initial, initial_name_ok := v.symbol_name(initial_symbol)
	if !initial_name_ok || (initial != "changes" && initial != "snapshot") {
		return builtin_error(state, "E_INVARG", "unsupported subscription initial mode")
	}

	cursor := u64(0)
	has_cursor := false
	if len(args) >= 6 {
		if value, has := option_payload(args[5]); has {
			cursor_value, is_int := v.value_as_int(value)
			if !is_int || cursor_value < 0 {
				return builtin_error(state, "E_INVARG", "subscription cursor must be non-negative")
			}
			cursor = u64(cursor_value)
			has_cursor = true
		}
	}

	queue_budget := DEFAULT_SUBSCRIPTION_QUEUE_BUDGET
	if len(args) >= 7 && !v.value_is_empty_relation(args[6]) {
		budget_value, is_int := v.value_as_int(args[6])
		if !is_int || budget_value < 1 {
			return builtin_error(state, "E_INVARG", "queue budget must be positive")
		}
		queue_budget = int(budget_value)
	}

	task := task_from_state(state)
	pending := task != nil && task.has_tx
	capability, subscription, registered := subscriptions_register(
		env,
		sender,
		subject,
		relation_id,
		bindings,
		initial == "snapshot",
		cursor,
		has_cursor,
		queue_budget,
		pending,
	)
	if !registered {
		return builtin_error(state, "E_SUBSCRIPTION", "cannot register subscription")
	}
	if pending {
		append(&task.pending_subscriptions, subscription)
	}
	return capability, true
}

@(private)
builtin_cancel_subscription :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	env := builtin_env(state)
	// Stage the cancellation until the task commits; an aborted task
	// publishes nothing.
	if task := task_from_state(state); task != nil && task.has_tx {
		append(&task.pending_cancels, args[0])
		return v.value_bool(true), true
	}
	if !subscriptions_cancel(env, args[0]) {
		return builtin_error(state, "E_INVARG", "unknown subscription")
	}
	return v.value_bool(true), true
}

// Unwraps a standard option value: some(x) yields (x, true), none false.
@(private)
option_payload :: proc(value: v.Value) -> (v.Value, bool) {
	relation, is_relation := v.value_as_relation(value)
	if !is_relation || len(relation.rows) == 0 {
		return v.Value(0), false
	}
	cells := v.tuple_values(relation.rows[0])
	if len(cells) == 0 {
		return v.Value(0), false
	}
	return cells[0], true
}

// --- Helpers ---------------------------------------------------------------
@(private)
builtin_error :: proc(state: ^vm.VM, code, message: string) -> (v.Value, bool) {
	vm.vm_set_error(state, code, message)
	return v.Value(0), false
}

@(private)
string_argument :: proc(
	state: ^vm.VM,
	args: []v.Value,
	index: int,
	name: string,
) -> (string, bool) {
	text, ok := v.value_as_string(args[index])
	if !ok {
		return "", false
	}
	_ = name
	return text, true
}

@(private)
option_none_value :: proc(alloc: mem.Allocator) -> v.Value {
	value, _ := v.value_relation(alloc, []v.Symbol{v.symbol_intern("value")}, nil)
	return value
}

@(private)
option_some_value :: proc(alloc: mem.Allocator, inner: v.Value) -> v.Value {
	value, _ := v.value_relation(
		alloc,
		[]v.Symbol{v.symbol_intern("value")},
		[]v.Tuple{v.tuple_new(alloc, []v.Value{inner})},
	)
	return value
}

@(private)
result_value :: proc(alloc: mem.Allocator, case_name: string, inner: v.Value) -> v.Value {
	value, _ := v.value_relation(
		alloc,
		[]v.Symbol{v.symbol_intern("case"), v.symbol_intern("value")},
		[]v.Tuple {
			v.tuple_new(alloc, []v.Value{v.value_symbol(v.symbol_intern(case_name)), inner}),
		},
	)
	return value
}

// --- Frob accessors --------------------------------------------------------

@(private)
builtin_frob_delegate :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	delegate, ok := v.value_frob_delegate(args[0])
	if !ok {
		return builtin_error(state, "E_TYPE", "frob_delegate expected a frob")
	}
	return v.value_identity(delegate), true
}

@(private)
builtin_frob_value :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	inner, ok := v.value_frob_value(args[0])
	if !ok {
		return builtin_error(state, "E_TYPE", "frob_value expected a frob")
	}
	return inner, true
}

@(private)
builtin_is_frob :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	_, ok := v.value_as_frob(args[0])
	return v.value_bool(ok), true
}

// --- Strings ---------------------------------------------------------------

@(private)
builtin_string_len :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if _, ok := v.value_as_string(args[0]); !ok {
		return builtin_error(state, "E_TYPE", "string_len expects a string")
	}
	count, count_ok := v.string_scalar_count(args[0])
	if !count_ok {
		return builtin_error(state, "E_TYPE", "string_len expects a string")
	}
	result, value_ok := v.value_int(i64(count))
	if !value_ok {
		return builtin_error(state, "E_RANGE", "string length is out of range")
	}
	return result, true
}

@(private)
builtin_string_chars :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	text, ok := string_argument(state, args, 0, "string_chars")
	if !ok {
		return builtin_error(state, "E_TYPE", "string_chars expects a string")
	}
	values := make([dynamic]v.Value, 0, utf8.rune_count_in_string(text), state.allocator)
	for ch in text {
		buf, size := utf8.encode_rune(ch)
		append(&values, v.value_string(state.allocator, string(buf[:size])))
	}
	return v.value_list(state.allocator, values[:]), true
}

@(private)
builtin_string_span :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if _, ok := v.value_as_string(args[0]); !ok {
		return builtin_error(state, "E_TYPE", "string_span expects a string")
	}
	start, start_ok := v.value_as_int(args[1])
	if !start_ok {
		return builtin_error(state, "E_TYPE", "string_span expects an integer start")
	}
	set, set_ok := v.value_as_string(args[2])
	if !set_ok {
		return builtin_error(state, "E_TYPE", "string_span expects a string of member bytes")
	}
	end, span_ok := v.string_span(args[0], int(start), set)
	if !span_ok {
		return builtin_error(state, "E_INDEX", "string_span start is out of range")
	}
	result, value_ok := v.value_int(i64(end))
	if !value_ok {
		return builtin_error(state, "E_RANGE", "string_span result is out of range")
	}
	return result, true
}

@(private)
builtin_string_find_any :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if _, ok := v.value_as_string(args[0]); !ok {
		return builtin_error(state, "E_TYPE", "string_find_any expects a string")
	}
	start, start_ok := v.value_as_int(args[1])
	if !start_ok {
		return builtin_error(state, "E_TYPE", "string_find_any expects an integer start")
	}
	stop, stop_ok := v.value_as_string(args[2])
	if !stop_ok {
		return builtin_error(state, "E_TYPE", "string_find_any expects a string of stop bytes")
	}
	found, find_ok := v.string_find_any(args[0], int(start), stop)
	if !find_ok {
		return builtin_error(state, "E_INDEX", "string_find_any start is out of range")
	}
	result, value_ok := v.value_int(i64(found))
	if !value_ok {
		return builtin_error(state, "E_RANGE", "string_find_any result is out of range")
	}
	return result, true
}

@(private)
builtin_string_slice :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	text, ok := v.value_as_string(args[0])
	if !ok {
		return builtin_error(state, "E_TYPE", "string_slice expects a string")
	}
	start, start_ok := v.value_as_int(args[1])
	end, end_ok := v.value_as_int(args[2])
	if !start_ok || !end_ok {
		return builtin_error(state, "E_TYPE", "string_slice expects integer positions")
	}
	char_len, count_ok := v.string_scalar_count(args[0])
	if !count_ok {
		return builtin_error(state, "E_TYPE", "string_slice expects a string")
	}
	if start < 0 || start > end || end > i64(char_len) {
		return builtin_error(state, "E_INDEX", "string_slice bounds are invalid")
	}

	// A scalar range maps to a boundary-aligned byte range, so the slice can
	// never split a scalar. ASCII and indexed strings locate in O(1)/O(stride)
	// instead of walking from the start.
	byte_start, byte_end, range_ok := v.string_byte_range(args[0], int(start), int(end))
	if !range_ok {
		return builtin_error(state, "E_INDEX", "string_slice bounds are invalid")
	}
	return v.value_string(state.allocator, text[byte_start:byte_end]), true
}

@(private)
builtin_string_from_chars :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	chars, ok := v.value_as_list(args[0])
	if !ok {
		return builtin_error(state, "E_TYPE", "string_from_chars expects a list")
	}
	builder: strings.Builder
	strings.builder_init(&builder, state.allocator)
	defer strings.builder_destroy(&builder)
	for ch in chars {
		part, part_ok := v.value_as_string(ch)
		if !part_ok {
			return builtin_error(state, "E_TYPE", "string_from_chars expects string elements")
		}
		strings.write_string(&builder, part)
	}
	return v.value_string(state.allocator, strings.to_string(builder)), true
}

@(private)
builtin_string_concat :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	// Validate every part and total the length before allocating anything, so
	// a bad argument is reported without a partial result.
	total := 0
	for part in args {
		text, ok := v.value_as_string(part)
		if !ok {
			return builtin_error(state, "E_TYPE", "string_concat expects strings")
		}
		total += len(text)
	}
	if total == 0 {
		return v.value_string_owned(state.allocator, nil), true
	}
	if len(args) == 1 {
		text, _ := v.value_as_string(args[0])
		return v.value_string(state.allocator, text), true
	}

	// Grow the result through the append primitive rather than sizing an exact
	// buffer and copying every part. When the accumulator owns the tail of a
	// buffer with room, the next part is written past its visible prefix, so
	// the common self-concat idiom `s = string_concat(s, x)` is linear instead
	// of O(n^2). This mirrors CPython, which resizes an unshared left operand
	// in place. Parts are appended left to right, so the bytes are identical to
	// a single exact-sized copy; the result carries spare capacity.
	parts := make([]string, len(args) - 1, context.temp_allocator)
	for index in 1 ..< len(args) {
		text, _ := v.value_as_string(args[index])
		parts[index - 1] = text
	}
	return v.value_string_concat(state.allocator, args[0], parts), true
}

@(private)
builtin_string_append :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	base, base_ok := v.value_as_string(args[0])
	if !base_ok {
		return builtin_error(state, "E_TYPE", "string_append expects a string")
	}
	text, text_ok := v.value_as_string(args[1])
	if !text_ok {
		return builtin_error(state, "E_TYPE", "string_append expects a string")
	}
	return v.value_string_append(state.allocator, args[0], text), true
}

@(private)
builtin_string_join :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	parts, ok := v.value_as_list(args[0])
	if !ok {
		return builtin_error(state, "E_TYPE", "string_join expects a string list")
	}
	separator, separator_ok := v.value_as_string(args[1])
	if !separator_ok {
		return builtin_error(state, "E_TYPE", "string_join expects a string separator")
	}
	// Size the buffer once, then hand it to the value without a second copy.
	total := 0
	if len(parts) > 1 {
		total += len(separator) * (len(parts) - 1)
	}
	for part in parts {
		text, part_ok := v.value_as_string(part)
		if !part_ok {
			return builtin_error(state, "E_TYPE", "string_join expects string elements")
		}
		total += len(text)
	}
	buffer := make([]u8, total, state.allocator)
	write := 0
	for part, index in parts {
		if index > 0 {
			copy(buffer[write:], transmute([]u8)separator)
			write += len(separator)
		}
		text, _ := v.value_as_string(part)
		copy(buffer[write:], transmute([]u8)text)
		write += len(text)
	}
	return v.value_string_owned(state.allocator, buffer), true
}

@(private)
builtin_string_starts_with :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	text, text_ok := v.value_as_string(args[0])
	prefix, prefix_ok := v.value_as_string(args[1])
	if !text_ok || !prefix_ok {
		return builtin_error(state, "E_TYPE", "string_starts_with expects strings")
	}
	return v.value_bool(strings.has_prefix(text, prefix)), true
}

@(private)
builtin_string_contains :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	text, text_ok := v.value_as_string(args[0])
	subject, subject_ok := v.value_as_string(args[1])
	if !text_ok || !subject_ok {
		return builtin_error(state, "E_TYPE", "string_contains expects strings")
	}
	return v.value_bool(strings.contains(text, subject)), true
}

@(private)
builtin_string_equal_fold :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	left, left_ok := v.value_as_string(args[0])
	right, right_ok := v.value_as_string(args[1])
	if !left_ok || !right_ok {
		return builtin_error(state, "E_TYPE", "string_equal_fold expects strings")
	}
	folded_left, _ := strings.to_lower(left, state.allocator)
	folded_right, _ := strings.to_lower(right, state.allocator)
	return v.value_bool(folded_left == folded_right), true
}

@(private)
builtin_lower :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	text, ok := string_argument(state, args, 0, "lower")
	if !ok {
		return builtin_error(state, "E_TYPE", "lower expects a string")
	}
	lowered, _ := strings.to_lower(text, state.allocator)
	return v.value_string(state.allocator, lowered), true
}

// --- Collections -----------------------------------------------------------

@(private)
builtin_words :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	text, ok := string_argument(state, args, 0, "words")
	if !ok {
		return builtin_error(state, "E_TYPE", "words expects a string")
	}
	words := make([dynamic]v.Value, state.allocator)
	current: strings.Builder
	strings.builder_init(&current, state.allocator)
	defer strings.builder_destroy(&current)
	in_quotes := false
	escaped := false
	flush :: proc(
		state: ^vm.VM,
		current: ^strings.Builder,
		words: ^[dynamic]v.Value,
	) {
		if strings.builder_len(current^) == 0 {
			return
		}
		append(words, v.value_string(state.allocator, strings.to_string(current^)))
		strings.builder_reset(current)
	}
	for ch in text {
		if escaped {
			strings.write_rune(&current, ch)
			escaped = false
			continue
		}
		if ch == '\\' {
			escaped = true
			continue
		}
		if ch == '"' {
			in_quotes = !in_quotes
			continue
		}
		if unicode_is_space(ch) && !in_quotes {
			flush(state, &current, &words)
			continue
		}
		strings.write_rune(&current, ch)
	}
	if escaped {
		strings.write_rune(&current, '\\')
	}
	flush(state, &current, &words)
	return v.value_list(state.allocator, words[:]), true
}

@(private)
unicode_is_space :: proc(ch: rune) -> bool {
	switch ch {
	case ' ', '\t', '\n', '\r', '\v', '\f', 0x85, 0xA0:
		return true
	}
	return false
}

@(private)
builtin_sort :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	values, ok := v.value_as_list(args[0])
	if !ok {
		return builtin_error(state, "E_TYPE", "sort expects a list")
	}
	// Homogeneous-int lists are the common case and sort far faster as raw
	// i64: the tagged comparator decodes two tags plus two payloads and calls
	// value_cmp per comparison, and slice.sort_by reaches it through a
	// function pointer. Canonical order for ints is numeric order, so an
	// i64 sort is equivalent.
	if values != nil && all_values_are_int(values) {
		numbers := make([]i64, len(values), state.allocator)
		for value, index in values {
			numbers[index] = v.value_int_unchecked(value)
		}
		// Sort the raw integers with a direct comparison sort: both core
		// sorts reach the comparator through a function pointer (and
		// smoothsort is comparison-heavy besides), which dominated an
		// all-integer sort.
		sort_i64(numbers)
		result := make([]v.Value, len(numbers), state.allocator)
		for number, index in numbers {
			result[index] = v.value_int_unchecked_pack(number)
		}
		delete(numbers, state.allocator)
		return v.value_list_owned(state.allocator, result), true
	}
	sorted := make([]v.Value, len(values), state.allocator)
	copy(sorted, values)
	// Mixed-kind lists fall back to the canonical comparator. slice.sort_by
	// reaches it through a function pointer, so this path stays relatively
	// slow; the named comparator at least avoids allocating a capture for
	// the inline closure form. Canonical order is value_cmp's order.
	sort_values(sorted)
	return v.value_list_owned(state.allocator, sorted), true
}

@(private)
all_values_are_int :: proc(values: []v.Value) -> bool {
	for value in values {
		if v.value_tag(value) != .Int {
			return false
		}
	}
	return true
}

// Sorts a slice of integers: median-of-three quicksort with insertion sort for
// small ranges, falling back to heapsort past a depth limit (introsort). No
// function pointers, so every comparison is a direct integer compare.
@(private)
sort_i64 :: proc(values: []i64) {
	INSERTION_LIMIT :: 12
	if len(values) < 2 {
		return
	}
	// Introsort depth bound: 2 * floor(log2(n)), so quicksort degenerating on
	// adversarial input falls back to heapsort rather than recursing deeply.
	depth: u32 = 0
	remaining := len(values)
	for remaining > 1 {
		remaining >>= 1
		depth += 2
	}
	intro_sort_i64(values, 0, len(values) - 1, depth, INSERTION_LIMIT)
}

@(private)
intro_sort_i64 :: proc(values: []i64, low, high: int, depth: u32, insertion_limit: int) {
	if high <= low {
		return
	}
	if high - low < insertion_limit {
		insertion_sort_i64(values, low, high)
		return
	}
	if depth == 0 {
		heap_sort_i64(values, low, high)
		return
	}
	// Hoare partitioning: `pivot` is the last index of the lower partition, so
	// the recursions are (low, pivot) and (pivot + 1, high). Using
	// (low, pivot - 1) would drop the pivot's own partition.
	pivot := partition_i64(values, low, high)
	intro_sort_i64(values, low, pivot, depth - 1, insertion_limit)
	intro_sort_i64(values, pivot + 1, high, depth - 1, insertion_limit)
}

@(private)
insertion_sort_i64 :: proc(values: []i64, low, high: int) {
	for index in low + 1 ..= high {
		current := values[index]
		position := index
		for position > low && values[position - 1] > current {
			values[position] = values[position - 1]
			position -= 1
		}
		values[position] = current
	}
}

@(private)
partition_i64 :: proc(values: []i64, low, high: int) -> int {
	// Median of three, then Hoare-style partitioning around the pivot value.
	mid := low + (high - low) / 2
	if values[mid] < values[low] {
		values[low], values[mid] = values[mid], values[low]
	}
	if values[high] < values[low] {
		values[low], values[high] = values[high], values[low]
	}
	if values[high] < values[mid] {
		values[mid], values[high] = values[high], values[mid]
	}
	pivot := values[mid]
	left := low
	right := high
	for {
		for values[left] < pivot {
			left += 1
		}
		for values[right] > pivot {
			right -= 1
		}
		if left >= right {
			return right
		}
		values[left], values[right] = values[right], values[left]
		left += 1
		right -= 1
	}
}

@(private)
heap_sort_i64 :: proc(values: []i64, low, high: int) {
	count := high - low + 1
	for start := count / 2 - 1; start >= 0; start -= 1 {
		sift_down_i64(values, low, start, count)
	}
	for end := count - 1; end > 0; end -= 1 {
		values[low], values[low + end] = values[low + end], values[low]
		sift_down_i64(values, low, 0, end)
	}
}

@(private)
sift_down_i64 :: proc(values: []i64, base, start, count: int) {
	root := start
	for {
		child := 2 * root + 1
		if child >= count {
			return
		}
		if child + 1 < count && values[base + child] < values[base + child + 1] {
			child += 1
		}
		if values[base + root] >= values[base + child] {
			return
		}
		values[base + root], values[base + child] = values[base + child], values[base + root]
		root = child
	}
}

// Sorts values by the canonical ordering. Kept as a named proc so the
// comparator body is visible to the optimizer.
@(private)
sort_values :: proc(values: []v.Value) {
	slice.sort_by(values, value_less)
}

@(private)
value_less :: proc(a, b: v.Value) -> bool {
	return v.value_cmp(a, b) == .Less
}

@(private)
builtin_list_slice :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	items, is_list := v.value_as_list(args[0])
	if !is_list {
		return v.value_list(state.allocator, nil), true
	}
	start, start_ok := v.value_as_int(args[1])
	end, end_ok := v.value_as_int(args[2])
	if !start_ok || !end_ok {
		return builtin_error(state, "E_TYPE", "__list_slice bounds must be integers")
	}
	length := i64(len(items))
	if end < 0 {
		end = length
	}
	if start < 0 || start > length || end < start || end > length {
		return v.value_list(state.allocator, nil), true
	}
	return v.value_list(state.allocator, items[int(start):int(end)]), true
}

// Returns some(length) for a list, map, or relation, and none otherwise.
@(private)
builtin_len_option :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	length := 0
	#partial switch v.value_kind(args[0]) {
	case .List:
		values, _ := v.value_as_list(args[0])
		length = len(values)
	case .Map:
		entries, _ := v.value_as_map(args[0])
		length = len(entries)
	case .Relation:
		relation, _ := v.value_as_relation(args[0])
		length = len(relation.rows)
	case:
		return option_none_value(state.allocator), true
	}
	converted, converted_ok := v.value_int(i64(length))
	if !converted_ok {
		return option_none_value(state.allocator), true
	}
	return option_some_value(state.allocator, converted), true
}

// Looks up a collection element for pattern matching. Returns some(value)
// when present and none otherwise; never raises.
@(private)
builtin_index_option :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	collection := args[0]
	key := args[1]
	#partial switch v.value_kind(collection) {
	case .List:
		items, _ := v.value_as_list(collection)
		index, index_ok := v.value_as_int(key)
		if index_ok && index >= 0 && int(index) < len(items) {
			return option_some_value(state.allocator, items[index]), true
		}
	case .Map:
		entries, _ := v.value_as_map(collection)
		for entry in entries {
			if v.value_eq(entry.key, key) {
				return option_some_value(state.allocator, entry.value), true
			}
		}
	case .Relation:
		relation, _ := v.value_as_relation(collection)
		if len(relation.rows) == 0 {
			return option_none_value(state.allocator), true
		}
		symbol, symbol_ok := v.value_as_symbol(key)
		if symbol_ok {
			for column, position in relation.heading {
				if column == symbol {
					values := v.tuple_values(relation.rows[0])
					return option_some_value(state.allocator, values[position]), true
				}
			}
		}
	case:
	}
	return option_none_value(state.allocator), true
}

@(private)
builtin_list_append :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	_, is_list := v.value_as_list(args[0])
	if !is_list {
		return builtin_error(state, "E_TYPE", "__list_append expects a list")
	}
	return v.value_list_append(state.allocator, args[0], args[1]), true
}

@(private)
builtin_list_concat :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	// Size the result once from the summed part lengths and fill it directly,
	// then hand the buffer to the value: the previous version grew a dynamic
	// array (reallocating and copying the growing prefix) and then value_list
	// copied the whole result again.
	total := 0
	for part in args {
		items, ok := v.value_as_list(part)
		if !ok {
			return builtin_error(state, "E_TYPE", "__list_concat expects lists")
		}
		total += len(items)
	}
	result := make([]v.Value, total, state.allocator)
	write := 0
	for part in args {
		items, _ := v.value_as_list(part)
		copy(result[write:], items)
		write += len(items)
	}
	return v.value_list_owned(state.allocator, result), true
}

@(private)
builtin_set_index :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	collection := args[0]
	index := args[1]
	value := args[2]

	if values, is_list := v.value_as_list(collection); is_list {
		position, ok := v.value_as_int(index)
		if !ok || position < 0 || position >= i64(len(values)) {
			return builtin_error(state, "E_INDEX", "list index is missing or invalid")
		}
		updated := make([]v.Value, len(values), state.allocator)
		copy(updated, values)
		updated[position] = value
		return v.value_list(state.allocator, updated), true
	}

	if entries, is_map := v.value_as_map(collection); is_map {
		updated := make([dynamic]v.Map_Entry, 0, len(entries) + 1, state.allocator)
		replaced := false
		for entry in entries {
			if v.value_eq(entry.key, index) {
				append(&updated, v.Map_Entry{key = entry.key, value = value})
				replaced = true
			} else {
				append(&updated, entry)
			}
		}
		if !replaced {
			append(&updated, v.Map_Entry{key = index, value = value})
		}
		return v.value_map(state.allocator, updated[:]), true
	}

	return builtin_error(state, "E_INDEX", "collection index is missing or invalid")
}

@(private)
builtin_map_pairs :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	entries, ok := v.value_as_map(args[0])
	if !ok {
		return builtin_error(state, "E_TYPE", "map_pairs expects a map")
	}
	pairs := make([]v.Value, len(entries), state.allocator)
	for entry, index in entries {
		pairs[index] = v.value_list(state.allocator, []v.Value{entry.key, entry.value})
	}
	return v.value_list(state.allocator, pairs), true
}

@(private)
builtin_index_or :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	collection := args[0]
	index := args[1]
	default := args[2]

	if entries, is_map := v.value_as_map(collection); is_map {
		// Entries are canonicalized sorted by key, so use the same cheap
		// ordered probe as map indexing instead of a linear scan. Keyword
		// tables make this the hot path for identifier lexing.
		position, found := v.map_entry_index(entries, index)
		if found {
			return entries[position].value, true
		}
		return default, true
	}

	if values, is_list := v.value_as_list(collection); is_list {
		position, ok := v.value_as_int(index)
		if !ok || position < 0 {
			return builtin_error(state, "E_TYPE", "list indexes must be non-negative integers")
		}
		if position >= i64(len(values)) {
			return default, true
		}
		return values[position], true
	}

	if relation, is_relation := v.value_as_relation(collection); is_relation {
		position, ok := v.value_as_int(index)
		if !ok || position < 0 {
			return builtin_error(state, "E_TYPE", "relation indexes must be non-negative integers")
		}
		if position >= i64(len(relation.rows)) {
			return default, true
		}
		row := v.tuple_values(relation.rows[position])
		entries := make([]v.Map_Entry, len(relation.heading), state.allocator)
		for column, column_index in relation.heading {
			entries[column_index] = v.Map_Entry {
				key   = v.value_symbol(column),
				value = row[column_index],
			}
		}
		return v.value_map(state.allocator, entries), true
	}

	return builtin_error(state, "E_TYPE", "index_or expects a map, list, or relation")
}

// --- Relation value algebra ------------------------------------------------

// Reports whether two relation values have the same heading.
@(private)
relation_headings_equal :: proc(left, right: ^v.Relation_Value) -> bool {
	if len(left.heading) != len(right.heading) {
		return false
	}
	for column, index in left.heading {
		if column != right.heading[index] {
			return false
		}
	}
	return true
}

@(private)
relation_argument :: proc(args: []v.Value, index: int) -> (^v.Relation_Value, bool) {
	relation, is_relation := v.value_as_relation(args[index])
	if !is_relation {
		return nil, false
	}
	return relation, true
}

// Builds a relation value from a heading list and a list of row lists.
@(private)
builtin_relation_literal :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	heading_values, heading_ok := v.value_as_list(args[0])
	if !heading_ok {
		return builtin_error(state, "E_TYPE", "relation literal heading must be a list")
	}
	heading := make([]v.Symbol, len(heading_values), context.temp_allocator)
	for value, index in heading_values {
		symbol, is_symbol := v.value_as_symbol(value)
		if !is_symbol {
			return builtin_error(
				state,
				"E_TYPE",
				"relation literal headings must be symbols",
			)
		}
		heading[index] = symbol
	}
	row_values, rows_ok := v.value_as_list(args[1])
	if !rows_ok {
		return builtin_error(state, "E_TYPE", "relation literal rows must be a list")
	}
	rows := make([]v.Tuple, len(row_values), context.temp_allocator)
	for value, index in row_values {
		cells, is_list := v.value_as_list(value)
		if !is_list {
			return builtin_error(state, "E_TYPE", "relation literal rows must be lists")
		}
		rows[index] = v.tuple_new(state.allocator, cells)
	}
	result, relation_error := v.value_relation(state.allocator, heading, rows)
	if relation_error != .None {
		return builtin_error(state, "E_INVARG", "relation literal shape is invalid")
	}
	return result, true
}

// Asserts or retracts one row of a relation addressed by name, resolving the
// relation id at execution time through the task catalogue. This is
// the runtime-resolution path for relation writes: an emitted program names
// the relation instead of baking a kernel id, so the same artifact stays
// valid across worlds whose relation ids differ.
@(private)
builtin_relation_write :: proc(
	state: ^vm.VM,
	args: []v.Value,
	assert_write: bool,
) -> (v.Value, bool) {
	if len(args) != 2 {
		return builtin_error(state, "E_INVARG", "a relation write takes a name and a row")
	}
	name_symbol, is_symbol := v.value_as_symbol(args[0])
	if !is_symbol {
		return builtin_error(state, "E_TYPE", "a relation write name must be a symbol")
	}
	name, has_name := v.symbol_name(name_symbol)
	if !has_name {
		return builtin_error(state, "E_INVARG", "a relation write name must be interned")
	}
	if state.transaction == nil {
		return builtin_error(state, "E_NO_TRANSACTION", "relation write has no transaction")
	}
	relation, known := runtime_relation_named(state, name)
	if !known {
		return builtin_error(
			state,
			"E_INVARG",
			fmt.aprintf("unknown relation :%s", name, allocator = state.allocator),
		)
	}
	row, is_relation := v.value_as_relation(args[1])
	if !is_relation || len(row.rows) != 1 {
		return builtin_error(
			state,
			"E_TYPE",
			"relation write expects a single-row relation value",
		)
	}
	relation_id := k.Relation_ID(relation)
	if !k.authority_can_write(state.authority, relation_id) {
		return builtin_error(state, "E_PERMISSION", "relation write denied")
	}
	err: k.Kernel_Error
	if assert_write {
		err = k.transaction_assert(state.transaction, relation_id, row.rows[0])
	} else {
		err = k.transaction_retract(state.transaction, relation_id, row.rows[0])
	}
	if err != .None {
		return builtin_error(state, "E_WRITE", "relation write failed")
	}
	return args[1], true
}

@(private)
builtin_relation_assert :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	return builtin_relation_write(state, args, true)
}

@(private)
builtin_relation_retract :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	return builtin_relation_write(state, args, false)
}

// Assembles a program description value into artifact bytes (#81).
//
// The description is a map with an `:entry` integer plus optional `:header`,
// `:code`, `:constants`, `:functions`, `:patterns`, `:shapes`, `:specs`, and
// `:builtins` lists; missing sections default to empty. Opcodes and pattern
// cell kinds are symbols (`:Load_Const`, `:Const`) resolved by name, and
// names accept strings or symbols. The header is four dispatch relation ids
// defaulting to the running program's. The result feeds ProgramBytes rows
// and the boot resolver directly.
@(private)
builtin_assemble :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	entries, is_map := v.value_as_map(args[0])
	if !is_map {
		return builtin_error(state, "E_TYPE", "assemble expects a description map")
	}
	builder: vm.Builder
	vm.builder_init(&builder, context.temp_allocator)
	defer vm.builder_destroy(&builder)

	entry_value, has_entry := assemble_map_get(entries, "entry")
	entry, entry_ok := assemble_int(entry_value)
	if !has_entry || !entry_ok {
		return builtin_error(
			state,
			"E_INVARG",
			"assemble description needs an :entry integer",
		)
	}
	builder.entry = entry

	if header_value, has_header := assemble_map_get(entries, "header"); has_header {
		header_values, header_is_list := v.value_as_list(header_value)
		if !header_is_list || len(header_values) != 4 {
			return builtin_error(
				state,
				"E_INVARG",
				"assemble :header must be four relation ids",
			)
		}
		header: [4]u32
		for value, index in header_values {
			id, id_ok := assemble_int(value)
			if !id_ok || i64(id) > i64(max(u32)) {
				return builtin_error(
					state,
					"E_INVARG",
					"assemble :header ids must fit u32",
				)
			}
			header[index] = u32(id)
		}
		builder.dispatch_method_selector_relation = header[0]
		builder.dispatch_param_relation = header[1]
		builder.dispatch_delegates_relation = header[2]
		builder.dispatch_method_program_relation = header[3]
	} else if state.program != nil {
		builder.dispatch_method_selector_relation =
			state.program.dispatch_method_selector_relation
		builder.dispatch_param_relation = state.program.dispatch_param_relation
		builder.dispatch_delegates_relation = state.program.dispatch_delegates_relation
		builder.dispatch_method_program_relation =
			state.program.dispatch_method_program_relation
	}

	if code_value, has_code := assemble_map_get(entries, "code"); has_code {
		code_values, code_is_list := v.value_as_list(code_value)
		if !code_is_list {
			return builtin_error(state, "E_TYPE", "assemble :code must be a list")
		}
		for item in code_values {
			if !assemble_instruction(&builder, item) {
				return builtin_error(
					state,
					"E_INVARG",
					"assemble :code entries need :op, :flags, :a, :b, :c",
				)
			}
		}
	}

	if constant_value, has_constants := assemble_map_get(entries, "constants"); has_constants {
		constant_values, constants_is_list := v.value_as_list(constant_value)
		if !constants_is_list {
			return builtin_error(state, "E_TYPE", "assemble :constants must be a list")
		}
		for constant in constant_values {
			vm.builder_add_constant(&builder, constant)
		}
	}

	if function_value, has_functions := assemble_map_get(entries, "functions"); has_functions {
		function_values, functions_is_list := v.value_as_list(function_value)
		if !functions_is_list {
			return builtin_error(state, "E_TYPE", "assemble :functions must be a list")
		}
		for item in function_values {
			if !assemble_function(&builder, item) {
				return builtin_error(
					state,
					"E_INVARG",
					"assemble :functions need :name, :code_offset, :code_len, :registers, :params",
				)
			}
		}
	}

	if pattern_value, has_patterns := assemble_map_get(entries, "patterns"); has_patterns {
		pattern_values, patterns_is_list := v.value_as_list(pattern_value)
		if !patterns_is_list {
			return builtin_error(state, "E_TYPE", "assemble :patterns must be a list")
		}
		for item in pattern_values {
			if !assemble_pattern(&builder, item) {
				return builtin_error(
					state,
					"E_INVARG",
					"assemble :patterns need :relation, :columns, :cells",
				)
			}
		}
	}

	if shape_value, has_shapes := assemble_map_get(entries, "shapes"); has_shapes {
		shape_values, shapes_is_list := v.value_as_list(shape_value)
		if !shapes_is_list {
			return builtin_error(state, "E_TYPE", "assemble :shapes must be a list")
		}
		for item in shape_values {
			columns, columns_ok := v.value_as_list(item)
			if !columns_ok {
				return builtin_error(
					state,
					"E_TYPE",
					"assemble :shapes entries must be symbol lists",
				)
			}
			heading := make([]v.Symbol, len(columns), context.temp_allocator)
			for column, index in columns {
				symbol, symbol_ok := assemble_name(column)
				if !symbol_ok {
					return builtin_error(
						state,
						"E_TYPE",
						"assemble :shapes entries must be symbol lists",
					)
				}
				heading[index] = v.symbol_intern(symbol)
			}
			vm.builder_add_relation_shape(&builder, heading)
		}
	}

	if spec_value, has_specs := assemble_map_get(entries, "specs"); has_specs {
		spec_values, specs_is_list := v.value_as_list(spec_value)
		if !specs_is_list {
			return builtin_error(state, "E_TYPE", "assemble :specs must be a list")
		}
		for item in spec_values {
			if !assemble_spec(&builder, item) {
				return builtin_error(
					state,
					"E_INVARG",
					"assemble :specs need :selector and :roles",
				)
			}
		}
	}

	if builtin_value, has_builtins := assemble_map_get(entries, "builtins"); has_builtins {
		builtin_values, builtins_is_list := v.value_as_list(builtin_value)
		if !builtins_is_list {
			return builtin_error(state, "E_TYPE", "assemble :builtins must be a list")
		}
		for item in builtin_values {
			name, name_ok := assemble_name(item)
			if !name_ok {
				return builtin_error(
					state,
					"E_TYPE",
					"assemble :builtins must be names",
				)
			}
			vm.builder_add_builtin(&builder, v.symbol_intern(name))
		}
	}

	program := vm.builder_build(&builder, context.temp_allocator)
	defer vm.program_destroy(program, context.temp_allocator)
	if validation := vm.program_validate(program); validation != .None {
		return builtin_error(state, "E_INVARG", fmt.aprintf(
			"assembled program failed validation: %v",
			validation,
			allocator = context.temp_allocator,
		))
	}
	bytes: [dynamic]u8
	defer delete(bytes)
	if artifact_error := vm.program_to_bytes(program, &bytes); artifact_error != .None {
		return builtin_error(state, "E_INVARG", fmt.aprintf(
			"assembled program does not encode: %v",
			artifact_error,
			allocator = context.temp_allocator,
		))
	}
	return v.value_bytes(state.allocator, bytes[:]), true
}

// Looks up a description map entry by field name.
@(private)
assemble_map_get :: proc(entries: []v.Map_Entry, name: string) -> (v.Value, bool) {
	key := v.value_symbol(v.symbol_intern(name))
	for entry in entries {
		if v.value_eq(entry.key, key) {
			return entry.value, true
		}
	}
	return v.Value(0), false
}

// Reads a non-negative integer field.
@(private)
assemble_int :: proc(value: v.Value) -> (int, bool) {
	number, is_int := v.value_as_int(value)
	if !is_int || number < 0 {
		return 0, false
	}
	return int(number), true
}

// Reads a name field spelled as a string or a symbol.
@(private)
assemble_name :: proc(value: v.Value) -> (string, bool) {
	if text, is_string := v.value_as_string(value); is_string {
		return text, true
	}
	if symbol, is_symbol := v.value_as_symbol(value); is_symbol {
		return v.symbol_name(symbol)
	}
	return "", false
}

// Resolves an opcode symbol to its Op by spelling.
@(private)
assemble_op :: proc(value: v.Value) -> (vm.Op, bool) {
	name, name_ok := assemble_name(value)
	if !name_ok {
		return vm.Op.Load_Const, false
	}
	switch name {
	case "Load_Const":
		return vm.Op.Load_Const, true
	case "Move":
		return vm.Op.Move, true
	case "Binary":
		return vm.Op.Binary, true
	case "Unary":
		return vm.Op.Unary, true
	case "Branch":
		return vm.Op.Branch, true
	case "Jump":
		return vm.Op.Jump, true
	case "Call":
		return vm.Op.Call, true
	case "Return":
		return vm.Op.Return, true
	case "Build_List":
		return vm.Op.Build_List, true
	case "Build_Map":
		return vm.Op.Build_Map, true
	case "Build_Range":
		return vm.Op.Build_Range, true
	case "Len":
		return vm.Op.Len, true
	case "Scan_Collect":
		return vm.Op.Scan_Collect, true
	case "Scan_Exists":
		return vm.Op.Scan_Exists, true
	case "Scan_First":
		return vm.Op.Scan_First, true
	case "Assert":
		return vm.Op.Assert, true
	case "Retract":
		return vm.Op.Retract, true
	case "Retract_Where":
		return vm.Op.Retract_Where, true
	case "Build_Relation":
		return vm.Op.Build_Relation, true
	case "Index":
		return vm.Op.Index, true
	case "Collection_Key_At":
		return vm.Op.Collection_Key_At, true
	case "Collection_Value_At":
		return vm.Op.Collection_Value_At, true
	case "Builtin_Call":
		return vm.Op.Builtin_Call, true
	case "Commit":
		return vm.Op.Commit, true
	case "Is_Truthy":
		return vm.Op.Is_Truthy, true
	case "Scan_One":
		return vm.Op.Scan_One, true
	case "Dispatch":
		return vm.Op.Dispatch, true
	case "Yield":
		return vm.Op.Yield, true
	case "Sleep":
		return vm.Op.Sleep, true
	case "Spawn":
		return vm.Op.Spawn, true
	case "Raise":
		return vm.Op.Raise, true
	case "Dynamic_Dispatch":
		return vm.Op.Dynamic_Dispatch, true
	case "Positional_Dispatch":
		return vm.Op.Positional_Dispatch, true
	case "Mailbox_Recv":
		return vm.Op.Mailbox_Recv, true
	case "External_Request":
		return vm.Op.External_Request, true
	case "Read":
		return vm.Op.Read, true
	case "Push_Handler":
		return vm.Op.Push_Handler, true
	case "Push_Finally":
		return vm.Op.Push_Finally, true
	case "Pop_Handler":
		return vm.Op.Pop_Handler, true
	case "Resume_Return":
		return vm.Op.Resume_Return, true
	case "Make_Function":
		return vm.Op.Make_Function, true
	case "Make_Self_Function":
		return vm.Op.Make_Self_Function, true
	case "Call_Value":
		return vm.Op.Call_Value, true
	case "Call_Splice":
		return vm.Op.Call_Splice, true
	case "Builtin_Call_Splice":
		return vm.Op.Builtin_Call_Splice, true
	case "Call_Value_Splice":
		return vm.Op.Call_Value_Splice, true
	}
	return vm.Op.Load_Const, false
}

// Emits one description-map instruction into the builder.
@(private)
assemble_instruction :: proc(builder: ^vm.Builder, item: v.Value) -> bool {
	fields, is_map := v.value_as_map(item)
	if !is_map {
		return false
	}
	op_value, has_op := assemble_map_get(fields, "op")
	op, op_ok := assemble_op(op_value)
	flags_value, has_flags := assemble_map_get(fields, "flags")
	a_value, has_a := assemble_map_get(fields, "a")
	b_value, has_b := assemble_map_get(fields, "b")
	c_value, has_c := assemble_map_get(fields, "c")
	flags, flags_ok := assemble_int(flags_value)
	a, a_ok := assemble_i32(a_value)
	b, b_ok := assemble_i32(b_value)
	c, c_ok := assemble_i32(c_value)
	if !has_op || !op_ok || !has_flags || !flags_ok || flags > int(max(u8)) {
		return false
	}
	if !has_a || !a_ok || !has_b || !b_ok || !has_c || !c_ok {
		return false
	}
	vm.builder_emit(builder, op, u8(flags), a, b, c)
	return true
}

// Reads a signed 32-bit operand, covering sentinel values like -1.
@(private)
assemble_i32 :: proc(value: v.Value) -> (i32, bool) {
	number, is_int := v.value_as_int(value)
	if !is_int || number < i64(min(i32)) || number > i64(max(i32)) {
		return 0, false
	}
	return i32(number), true
}

// Adds one function description to the builder.
@(private)
assemble_function :: proc(builder: ^vm.Builder, item: v.Value) -> bool {
	fields, is_map := v.value_as_map(item)
	if !is_map {
		return false
	}
	name_value, has_name := assemble_map_get(fields, "name")
	name, name_ok := assemble_name(name_value)
	offset_value, has_offset := assemble_map_get(fields, "code_offset")
	code_offset, offset_ok := assemble_int(offset_value)
	length_value, has_length := assemble_map_get(fields, "code_len")
	code_len, length_ok := assemble_int(length_value)
	registers_value, has_registers := assemble_map_get(fields, "registers")
	registers, registers_ok := assemble_int(registers_value)
	params_value, has_params := assemble_map_get(fields, "params")
	params, params_ok := assemble_int(params_value)
	if !has_name || !name_ok || !has_offset || !offset_ok || !has_length || !length_ok {
		return false
	}
	if !has_registers || !registers_ok || !has_params || !params_ok {
		return false
	}
	required := 0
	if required_value, has_required := assemble_map_get(fields, "required"); has_required {
		required_value, required_ok := assemble_int(required_value)
		if !required_ok || required_value > int(max(u16)) {
			return false
		}
		required = required_value
	}
	rest := false
	if rest_value, has_rest := assemble_map_get(fields, "rest"); has_rest {
		rest_flag, rest_ok := v.value_as_bool(rest_value)
		if !rest_ok {
			return false
		}
		rest = rest_flag
	}
	defaults: []i32
	if defaults_value, has_defaults := assemble_map_get(fields, "defaults"); has_defaults {
		default_values, defaults_is_list := v.value_as_list(defaults_value)
		if !defaults_is_list {
			return false
		}
		owned := make([]i32, len(default_values), context.temp_allocator)
		for default, index in default_values {
			operand, operand_ok := assemble_i32(default)
			if !operand_ok {
				return false
			}
			owned[index] = operand
		}
		defaults = owned
	}
	vm.builder_add_function(
		builder,
		v.symbol_intern(name),
		code_offset,
		code_len,
		registers,
		params,
		u16(required),
		rest,
		defaults,
	)
	return true
}

// Adds one scan pattern description to the builder.
@(private)
assemble_pattern :: proc(builder: ^vm.Builder, item: v.Value) -> bool {
	fields, is_map := v.value_as_map(item)
	if !is_map {
		return false
	}
	relation_value, has_relation := assemble_map_get(fields, "relation")
	relation, relation_ok := assemble_int(relation_value)
	columns_value, has_columns := assemble_map_get(fields, "columns")
	columns, columns_ok := v.value_as_list(columns_value)
	cells_value, has_cells := assemble_map_get(fields, "cells")
	cells, cells_ok := v.value_as_list(cells_value)
	// A pattern may name its relation instead of giving an id; the name is
	// resolved at scan time against the live snapshot. `:relation` then
	// defaults to zero, the unresolved marker.
	name_value, has_name := assemble_map_get(fields, "name")
	relation_name := v.Symbol(0)
	if has_name {
		name_text, name_text_ok := assemble_name(name_value)
		if !name_text_ok {
			return false
		}
		relation_name = v.symbol_intern(name_text)
	}
	if !has_relation && !has_name {
		return false
	}
	if has_relation && (!relation_ok || i64(relation) > i64(max(u32))) {
		return false
	}
	if !has_columns || !columns_ok || !has_cells || !cells_ok {
		return false
	}
	names := make([]v.Symbol, len(columns), context.temp_allocator)
	for column, index in columns {
		name, name_ok := assemble_name(column)
		if !name_ok {
			return false
		}
		names[index] = v.symbol_intern(name)
	}
	pattern_cells := make([]vm.Pattern_Cell, len(cells), context.temp_allocator)
	for cell, index in cells {
		cell_fields, cell_is_map := v.value_as_map(cell)
		if !cell_is_map {
			return false
		}
		kind_value, has_kind := assemble_map_get(cell_fields, "kind")
		kind_name, kind_name_ok := assemble_name(kind_value)
		kind := vm.Pattern_Cell_Kind.Wildcard
		if !has_kind || !kind_name_ok {
			return false
		}
		switch kind_name {
		case "Const":
			kind = vm.Pattern_Cell_Kind.Const
		case "Bind":
			kind = vm.Pattern_Cell_Kind.Bind
		case "Output":
			kind = vm.Pattern_Cell_Kind.Output
		case "Wildcard":
			kind = vm.Pattern_Cell_Kind.Wildcard
		case:
			return false
		}
		operand_value, has_operand := assemble_map_get(cell_fields, "operand")
		operand, operand_ok := assemble_i32(operand_value)
		if !has_operand || !operand_ok {
			return false
		}
		pattern_cells[index] = vm.Pattern_Cell{kind = kind, operand = operand}
	}
	vm.builder_add_pattern(builder, u32(relation), relation_name, names, pattern_cells)
	return true
}

// Adds one dispatch spec description to the builder.
@(private)
assemble_spec :: proc(builder: ^vm.Builder, item: v.Value) -> bool {
	fields, is_map := v.value_as_map(item)
	if !is_map {
		return false
	}
	selector_value, has_selector := assemble_map_get(fields, "selector")
	selector, selector_ok := assemble_name(selector_value)
	roles_value, has_roles := assemble_map_get(fields, "roles")
	roles, roles_ok := v.value_as_list(roles_value)
	if !has_selector || !selector_ok || !has_roles || !roles_ok {
		return false
	}
	assembled := make([]vm.Dispatch_Role, len(roles), context.temp_allocator)
	for role, index in roles {
		role_fields, role_is_map := v.value_as_map(role)
		if !role_is_map {
			return false
		}
		name_value, has_name := assemble_map_get(role_fields, "role")
		name, name_ok := assemble_name(name_value)
		register_value, has_register := assemble_map_get(role_fields, "register")
		register, register_ok := assemble_i32(register_value)
		if !has_name || !name_ok || !has_register || !register_ok {
			return false
		}
		assembled[index] = vm.Dispatch_Role {
			role     = v.symbol_intern(name),
			register = register,
		}
	}
	vm.builder_add_dispatch_spec(builder, v.symbol_intern(selector), assembled)
	return true
}

@(private)
builtin_project :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) < 1 {
		return builtin_error(state, "E_INVARG", "project expects project(relation, :column, ...)")
	}
	relation, is_relation := v.value_as_relation(args[0])
	if !is_relation {
		return builtin_error(state, "E_TYPE", "project expects a relation argument")
	}
	if len(args) == 1 {
		// The zero-column projection: an existence test as a relation.
		rows := make([]v.Tuple, len(relation.rows), context.temp_allocator)
		for _, index in relation.rows {
			rows[index] = v.tuple_new(state.allocator, nil)
		}
		empty_heading := make([]v.Symbol, 0, context.temp_allocator)
		value, relation_error := v.value_relation(state.allocator, empty_heading, rows)
		if relation_error != .None {
			return builtin_error(state, "E_INVARG", "project could not build a relation")
		}
		return value, true
	}

	positions := make([]int, len(args) - 1, context.temp_allocator)
	for argument, index in args[1:] {
		column, is_symbol := v.value_as_symbol(argument)
		if !is_symbol {
			return builtin_error(state, "E_TYPE", "project expects symbol column arguments")
		}
		position := -1
		for name, name_index in relation.heading {
			if name == column {
				position = name_index
				break
			}
		}
		if position < 0 {
			column_name, _ := v.symbol_name(column)
			return builtin_error(
				state,
				"E_INVARG",
				fmt.aprintf(
					"relation has no column :%s",
					column_name,
					allocator = state.allocator,
				),
			)
		}
		positions[index] = position
	}

	heading := make([]v.Symbol, len(positions), context.temp_allocator)
	for position, index in positions {
		heading[index] = relation.heading[position]
	}
	rows := make([]v.Tuple, len(relation.rows), context.temp_allocator)
	for row, row_index in relation.rows {
		values := v.tuple_values(row)
		selected := make([]v.Value, len(positions), context.temp_allocator)
		for position, index in positions {
			selected[index] = values[position]
		}
		rows[row_index] = v.tuple_new(state.allocator, selected)
	}
	value, relation_error := v.value_relation(state.allocator, heading, rows)
	if relation_error != .None {
		return builtin_error(state, "E_INVARG", "project could not build a relation")
	}
	return value, true
}

@(private)
builtin_union :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 2 {
		return builtin_error(state, "E_INVARG", "union expects union(left, right)")
	}
	left, left_ok := relation_argument(args, 0)
	if !left_ok {
		return builtin_error(state, "E_TYPE", "union expects relation arguments")
	}
	right, right_ok := relation_argument(args, 1)
	if !right_ok {
		return builtin_error(state, "E_TYPE", "union expects relation arguments")
	}
	if !relation_headings_equal(left, right) {
		return builtin_error(state, "E_INVARG", "relation headings are incompatible")
	}
	rows: [dynamic]v.Tuple
	rows = make([dynamic]v.Tuple, 0, len(left.rows) + len(right.rows), context.temp_allocator)
	append(&rows, ..left.rows)
	append(&rows, ..right.rows)
	value, relation_error := v.value_relation(state.allocator, left.heading, rows[:])
	if relation_error != .None {
		return builtin_error(state, "E_INVARG", "union could not build a relation")
	}
	return value, true
}

@(private)
builtin_difference :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 2 {
		return builtin_error(state, "E_INVARG", "difference expects difference(left, right)")
	}
	left, left_ok := relation_argument(args, 0)
	if !left_ok {
		return builtin_error(state, "E_TYPE", "difference expects relation arguments")
	}
	right, right_ok := relation_argument(args, 1)
	if !right_ok {
		return builtin_error(state, "E_TYPE", "difference expects relation arguments")
	}
	if !relation_headings_equal(left, right) {
		return builtin_error(state, "E_INVARG", "relation headings are incompatible")
	}
	rows: [dynamic]v.Tuple
	rows = make([dynamic]v.Tuple, 0, len(left.rows), context.temp_allocator)
	for row in left.rows {
		found := false
		for other in right.rows {
			if v.tuple_cmp(row, other) == .Equal {
				found = true
				break
			}
		}
		if !found {
			append(&rows, row)
		}
	}
	value, relation_error := v.value_relation(state.allocator, left.heading, rows[:])
	if relation_error != .None {
		return builtin_error(state, "E_INVARG", "difference could not build a relation")
	}
	return value, true
}

@(private)
builtin_natural_join :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 2 {
		return builtin_error(state, "E_INVARG", "natural_join expects natural_join(left, right)")
	}
	left, left_ok := relation_argument(args, 0)
	if !left_ok {
		return builtin_error(state, "E_TYPE", "natural_join expects relation arguments")
	}
	right, right_ok := relation_argument(args, 1)
	if !right_ok {
		return builtin_error(state, "E_TYPE", "natural_join expects relation arguments")
	}

	left_positions := make([dynamic]int, 0, len(left.heading), context.temp_allocator)
	right_positions := make([dynamic]int, 0, len(left.heading), context.temp_allocator)
	for column, left_position in left.heading {
		for name, right_position in right.heading {
			if name != column {
				continue
			}
			append(&left_positions, left_position)
			append(&right_positions, right_position)
			break
		}
	}
	right_only := make([dynamic]int, 0, len(right.heading), context.temp_allocator)
	for column, right_position in right.heading {
		shared := false
		for name in left.heading {
			if name == column {
				shared = true
				break
			}
		}
		if !shared {
			append(&right_only, right_position)
		}
	}

	heading: [dynamic]v.Symbol
	heading = make([dynamic]v.Symbol, 0, len(left.heading) + len(right_only), context.temp_allocator)
	append(&heading, ..left.heading)
	for position in right_only {
		append(&heading, right.heading[position])
	}

	rows: [dynamic]v.Tuple
	rows = make([dynamic]v.Tuple, 0, 16, context.temp_allocator)
	for left_row in left.rows {
		left_values := v.tuple_values(left_row)
		for right_row in right.rows {
			right_values := v.tuple_values(right_row)
			matched := true
			for shared_index in 0 ..< len(left_positions) {
				left_value := left_values[left_positions[shared_index]]
				right_value := right_values[right_positions[shared_index]]
				if !v.value_eq(left_value, right_value) {
					matched = false
					break
				}
			}
			if !matched {
				continue
			}
			combined: [dynamic]v.Value
			combined = make([dynamic]v.Value, 0, len(left_values) + len(right_only), context.temp_allocator)
			append(&combined, ..left_values)
			for position in right_only {
				append(&combined, right_values[position])
			}
			append(&rows, v.tuple_new(state.allocator, combined[:]))
		}
	}
	value, relation_error := v.value_relation(state.allocator, heading[:], rows[:])
	if relation_error != .None {
		return builtin_error(state, "E_INVARG", "natural_join could not build a relation")
	}
	return value, true
}

// --- Text utilities --------------------------------------------------------

@(private)
builtin_edit_distance :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	left, left_ok := v.value_as_string(args[0])
	right, right_ok := v.value_as_string(args[1])
	if !left_ok || !right_ok {
		return builtin_error(state, "E_TYPE", "edit_distance expects strings")
	}
	distance := levenshtein_chars(left, right)
	result, value_ok := v.value_int(i64(distance))
	if !value_ok {
		return builtin_error(state, "E_RANGE", "edit distance is out of range")
	}
	return result, true
}

@(private)
levenshtein_chars :: proc(left, right: string) -> int {
	left_runes := utf8.string_to_runes(left, context.temp_allocator)
	right_runes := utf8.string_to_runes(right, context.temp_allocator)
	if len(left_runes) == 0 {
		return len(right_runes)
	}
	if len(right_runes) == 0 {
		return len(left_runes)
	}

	previous := make([]int, len(right_runes) + 1, context.temp_allocator)
	current := make([]int, len(right_runes) + 1, context.temp_allocator)
	for index in 0 ..= len(right_runes) {
		previous[index] = index
	}
	for left_index in 0 ..< len(left_runes) {
		current[0] = left_index + 1
		for right_index in 0 ..< len(right_runes) {
			substitution := 0
			if left_runes[left_index] != right_runes[right_index] {
				substitution = 1
			}
			insert := previous[right_index + 1] + 1
			delete := current[right_index] + 1
			substitute := previous[right_index] + substitution
			best := min(insert, delete)
			current[right_index + 1] = min(best, substitute)
		}
		swap := previous
		previous = current
		current = swap
	}
	return previous[len(right_runes)]
}

@(private)
builtin_parse_ordinal :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	text, ok := string_argument(state, args, 0, "parse_ordinal")
	if !ok {
		return builtin_error(state, "E_TYPE", "parse_ordinal expects a string")
	}
	lowered, _ := strings.to_lower(strings.trim_space(text), state.allocator)
	if value, found := parse_ordinal_text(lowered); found {
		return result_value(state.allocator, "ok", value_int_must(value)), true
	}
	problem := v.value_error(
		state.allocator,
		v.symbol_intern("E_PARSE"),
		"invalid ordinal",
		true,
		v.value_string(state.allocator, text),
		true,
	)
	return result_value(state.allocator, "error", problem), true
}

@(private)
value_int_must :: proc(value: i64) -> v.Value {
	result, _ := v.value_int(value)
	return result
}

@(private)
parse_ordinal_text :: proc(text: string) -> (i64, bool) {
	if len(text) == 0 {
		return 0, false
	}
	if number, numeric := parse_numeric_ordinal(text); numeric {
		return number, true
	}
	total := i64(0)
	remaining := text
	for len(remaining) > 0 {
		part := remaining
		if index := strings.index_byte(remaining, '-'); index >= 0 {
			part = remaining[:index]
			remaining = remaining[index + 1:]
		} else {
			remaining = ""
		}
		value, known := simple_ordinal_value(part)
		if !known {
			return 0, false
		}
		total += value
	}
	if total <= 0 {
		return 0, false
	}
	return total, true
}

@(private)
parse_numeric_ordinal :: proc(text: string) -> (i64, bool) {
	trimmed := text
	for suffix in ([]string{"st", "nd", "rd", "th"}) {
		if strings.has_suffix(trimmed, suffix) {
			trimmed = trimmed[:len(trimmed) - len(suffix)]
			break
		}
	}
	if strings.has_suffix(trimmed, ".") {
		trimmed = trimmed[:len(trimmed) - 1]
	}
	value, _ := strconv_parse_i64(trimmed)
	if value <= 0 {
		return 0, false
	}
	return value, true
}

@(private)
strconv_parse_i64 :: proc(text: string) -> (i64, bool) {
	value: i64
	negative := false
	for index in 0 ..< len(text) {
		ch := text[index]
		if index == 0 && ch == '-' {
			negative = true
			continue
		}
		if ch < '0' || ch > '9' {
			return 0, false
		}
		value = value * 10 + i64(ch - '0')
	}
	if negative {
		value = -value
	}
	return value, true
}

@(private)
simple_ordinal_value :: proc(text: string) -> (i64, bool) {
	switch text {
	case "first":
		return 1, true
	case "second":
		return 2, true
	case "third":
		return 3, true
	case "fourth":
		return 4, true
	case "fifth":
		return 5, true
	case "sixth":
		return 6, true
	case "seventh":
		return 7, true
	case "eighth":
		return 8, true
	case "ninth":
		return 9, true
	case "tenth":
		return 10, true
	case "eleventh":
		return 11, true
	case "twelfth":
		return 12, true
	case "thirteenth":
		return 13, true
	case "fourteenth":
		return 14, true
	case "fifteenth":
		return 15, true
	case "sixteenth":
		return 16, true
	case "seventeenth":
		return 17, true
	case "eighteenth":
		return 18, true
	case "nineteenth":
		return 19, true
	case "twentieth":
		return 20, true
	case "thirtieth":
		return 30, true
	case "fortieth":
		return 40, true
	case "fiftieth":
		return 50, true
	case "sixtieth":
		return 60, true
	case "seventieth":
		return 70, true
	case "eightieth":
		return 80, true
	case "ninetieth":
		return 90, true
	case "hundred":
		return 100, true
	case "thousand":
		return 1000, true
	}
	return 0, false
}

@(private)
builtin_to_symbol :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if _, already := v.value_as_symbol(args[0]); already {
		return args[0], true
	}
	text, ok := v.value_as_string(args[0])
	if !ok {
		return builtin_error(state, "E_TYPE", "to_symbol expects a string")
	}
	return v.value_symbol(v.symbol_intern(text)), true
}

// Converts a numeric value to a float. Integers round to the nearest binary32
// value; floats pass through. Non-numeric values raise E_TYPE.
@(private)
builtin_to_float :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	converted, ok := v.value_to_float(args[0])
	if !ok {
		return builtin_error(state, "E_TYPE", "to_float expects a numeric value")
	}
	return converted, true
}

// Converts a numeric value to an integer. A float converts only when it is
// exactly integral and within the Mica integer range. Other values raise
// E_TYPE.
@(private)
builtin_to_int :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	converted, ok := v.value_to_int(args[0])
	if !ok {
		return builtin_error(state, "E_TYPE", "to_int expects an exactly integral numeric value")
	}
	return converted, true
}

// Parses a decimal integer spelling (optional leading `-`). Anything else,
// including out-of-range values, raises E_INVARG.
@(private)
builtin_parse_int :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	text, ok := string_argument(state, args, 0, "parse_int")
	if !ok {
		return builtin_error(state, "E_TYPE", "parse_int expects a string")
	}
	digits := text
	negative := false
	if strings.has_prefix(digits, "-") {
		negative = true
		digits = digits[1:]
	}
	if len(digits) == 0 {
		return builtin_error(state, "E_INVARG", "parse_int found no digits")
	}
	parsed := i64(0)
	for byte in transmute([]u8)digits {
		if byte < '0' || byte > '9' {
			return builtin_error(state, "E_INVARG", "parse_int found no digits")
		}
		digit := i64(byte - '0')
		if parsed > (max(i64) - digit) / 10 {
			return builtin_error(state, "E_INVARG", "parse_int is out of range")
		}
		parsed = parsed * 10 + digit
	}
	if negative {
		parsed = -parsed
	}
	value, value_ok := v.value_int(parsed)
	if !value_ok {
		return builtin_error(state, "E_INVARG", "parse_int is out of range")
	}
	return value, true
}

// Parses a decimal float spelling as the lexer produces it. Anything else
// raises E_INVARG.
@(private)
builtin_parse_float :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	text, ok := string_argument(state, args, 0, "parse_float")
	if !ok {
		return builtin_error(state, "E_TYPE", "parse_float expects a string")
	}
	parsed, parsed_ok := strconv.parse_f32(text)
	if !parsed_ok {
		return builtin_error(state, "E_INVARG", "parse_float found no float")
	}
	value, value_ok := v.value_float(parsed)
	if !value_ok {
		return builtin_error(state, "E_INVARG", "parse_float is out of range")
	}
	return value, true
}

// --- URL components --------------------------------------------------------

@(private)
builtin_url_encode_component :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	text, ok := string_argument(state, args, 0, "url_encode_component")
	if !ok {
		return builtin_error(state, "E_TYPE", "url_encode_component expects a string")
	}
	builder: strings.Builder
	strings.builder_init(&builder, state.allocator)
	defer strings.builder_destroy(&builder)
	for index in 0 ..< len(text) {
		byte := text[index]
		if is_url_unreserved(byte) {
			strings.write_byte(&builder, byte)
		} else {
			fmt.sbprintf(&builder, "%%%02X", byte)
		}
	}
	return v.value_string(state.allocator, strings.to_string(builder)), true
}

@(private)
is_url_unreserved :: proc(byte: u8) -> bool {
	if byte >= 'a' && byte <= 'z' {
		return true
	}
	if byte >= 'A' && byte <= 'Z' {
		return true
	}
	if byte >= '0' && byte <= '9' {
		return true
	}
	return byte == '-' || byte == '_' || byte == '.' || byte == '~'
}

@(private)
builtin_url_decode_component :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	text, ok := string_argument(state, args, 0, "url_decode_component")
	if !ok {
		return builtin_error(state, "E_TYPE", "url_decode_component expects a string")
	}
	bytes := make([dynamic]u8, 0, len(text), state.allocator)
	defer delete(bytes)
	index := 0
	for index < len(text) {
		byte := text[index]
		switch byte {
		case '%':
			if index + 2 >= len(text) {
				return builtin_error(state, "E_URL", "incomplete percent escape")
			}
			high, high_ok := hex_value(text[index + 1])
			low, low_ok := hex_value(text[index + 2])
			if !high_ok || !low_ok {
				return builtin_error(state, "E_URL", "invalid percent escape")
			}
			append(&bytes, high << 4 | low)
			index += 3
		case '+':
			append(&bytes, ' ')
			index += 1
		case:
			append(&bytes, byte)
			index += 1
		}
	}
	if !utf8.valid_string(string(bytes[:])) {
		return builtin_error(state, "E_URL", "decoded component is not valid UTF-8")
	}
	return v.value_string(state.allocator, string(bytes[:])), true
}

@(private)
hex_value :: proc(byte: u8) -> (u8, bool) {
	switch byte {
	case '0' ..= '9':
		return byte - '0', true
	case 'a' ..= 'f':
		return byte - 'a' + 10, true
	case 'A' ..= 'F':
		return byte - 'A' + 10, true
	}
	return 0, false
}

// --- Host ------------------------------------------------------------------

@(private)
builtin_os_getenv :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	name, ok := string_argument(state, args, 0, "os_getenv")
	if !ok {
		return builtin_error(state, "E_TYPE", "os_getenv expects a string")
	}
	value, found := os.lookup_env(name, state.allocator)
	if !found {
		return option_none_value(state.allocator), true
	}
	return option_some_value(state.allocator, v.value_string(state.allocator, value)), true
}

// --- Literals --------------------------------------------------------------

@(private)
builtin_to_literal :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if !v.value_is_persistable(args[0]) {
		return builtin_error(state, "E_TYPE", "this value does not have a source literal")
	}
	env := builtin_env(state)
	builder: strings.Builder
	strings.builder_init(&builder, state.allocator)
	defer strings.builder_destroy(&builder)
	write_source_literal(&builder, env, args[0])
	return v.value_string(state.allocator, strings.to_string(builder)), true
}

@(private)
write_source_literal :: proc(builder: ^strings.Builder, env: ^Builtin_Env, value: v.Value) {
	tag := v.value_tag(value)
	#partial switch tag {
	case .Bool:
		flag, _ := v.value_as_bool(value)
		strings.write_string(builder, flag ? "true" : "false")
	case .Int:
		number, _ := v.value_as_int(value)
		fmt.sbprintf(builder, "%d", number)
	case .Float:
		number, _ := v.value_as_float(value)
		fmt.sbprintf(builder, "%v", number)
	case .Identity:
		identity, _ := v.value_as_identity(value)
		if name, found := identity_name(env, identity); found {
			strings.write_string(builder, "#")
			strings.write_string(builder, name)
		} else {
			fmt.sbprintf(builder, "#%d", v.identity_raw(identity))
		}
	case .Symbol:
		symbol, _ := v.value_as_symbol(value)
		name, _ := v.symbol_name(symbol)
		strings.write_string(builder, ":")
		strings.write_string(builder, name)
	case .String:
		text, _ := v.value_as_string(value)
		write_quoted_string(builder, text)
	case .List:
		values, _ := v.value_as_list(value)
		strings.write_string(builder, "[")
		for item, index in values {
			if index > 0 {
				strings.write_string(builder, ", ")
			}
			write_source_literal(builder, env, item)
		}
		strings.write_string(builder, "]")
	case .Map:
		entries, _ := v.value_as_map(value)
		strings.write_string(builder, "{")
		for entry, index in entries {
			if index > 0 {
				strings.write_string(builder, ", ")
			}
			write_source_literal(builder, env, entry.key)
			strings.write_string(builder, " -> ")
			write_source_literal(builder, env, entry.value)
		}
		strings.write_string(builder, "}")
	case .Frob:
		delegate, _ := v.value_frob_delegate(value)
		inner, _ := v.value_frob_value(value)
		strings.write_string(builder, "#")
		if name, found := identity_name(env, delegate); found {
			strings.write_string(builder, name)
		} else {
			fmt.sbprintf(builder, "%d", v.identity_raw(delegate))
		}
		strings.write_string(builder, "<")
		write_source_literal(builder, env, inner)
		strings.write_string(builder, ">")
	case .Range:
		start, end, has_end, _ := v.value_as_range(value)
		write_source_literal(builder, env, start)
		strings.write_string(builder, "..")
		if has_end {
			write_source_literal(builder, env, end)
		} else {
			strings.write_string(builder, "_")
		}
	case .Relation:
		relation, _ := v.value_as_relation(value)
		strings.write_string(builder, "[")
		for column, index in relation.heading {
			if index > 0 {
				strings.write_string(builder, ", ")
			}
			strings.write_string(builder, ":")
			name, _ := v.symbol_name(column)
			strings.write_string(builder, name)
		}
		strings.write_string(builder, "] {")
		for row, row_index in relation.rows {
			if row_index > 0 {
				strings.write_string(builder, ", ")
			}
			strings.write_string(builder, "[")
			for cell, cell_index in v.tuple_values(row) {
				if cell_index > 0 {
					strings.write_string(builder, ", ")
				}
				write_source_literal(builder, env, cell)
			}
			strings.write_string(builder, "]")
		}
		strings.write_string(builder, "}")
	case:
		strings.write_string(builder, v.value_to_string(value, context.temp_allocator))
	}
}

@(private)
write_quoted_string :: proc(builder: ^strings.Builder, text: string) {
	strings.write_byte(builder, '"')
	for ch in text {
		switch ch {
		case '"':
			strings.write_string(builder, "\\\"")
		case '\\':
			strings.write_string(builder, "\\\\")
		case '\n':
			strings.write_string(builder, "\\n")
		case '\r':
			strings.write_string(builder, "\\r")
		case '\t':
			strings.write_string(builder, "\\t")
		case:
			strings.write_rune(builder, ch)
		}
	}
	strings.write_byte(builder, '"')
}

@(private)
identity_name :: proc(env: ^Builtin_Env, identity: v.Identity) -> (string, bool) {
	for name, value in env.ctx.identities {
		candidate, ok := v.value_as_identity(value)
		if ok && candidate == identity {
			return name, true
		}
	}
	return "", false
}
