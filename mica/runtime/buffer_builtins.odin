// Buffer builtins: the Mica-facing surface over transactional buffers.
//
// A buffer is named like a relation, so the Mica surface passes a symbol
// (`:notes`) and never a kernel id. `make_buffer` stages the catalogue entry in
// the current transaction, which means a buffer and its first content commit
// together; re-declaring an existing buffer is idempotent so a durable world
// can re-run its fileins on boot.
//
// Reads and writes go through the task's transaction, so a buffer edit is
// read-your-own-writes and invisible until commit, exactly like a fact write.
package mica_runtime

import "core:fmt"
import "core:mem"
import "core:strings"

import buf "../buffer"
import k "../kernel"
import v "../var"
import vm "../vm"

// Resolves a buffer name argument to its kernel relation id.
@(private)
buffer_relation_arg :: proc(state: ^vm.VM, value: v.Value) -> (k.Relation_ID, bool) {
	symbol, is_symbol := v.value_as_symbol(value)
	if !is_symbol {
		vm.vm_set_error(state, "E_TYPE", "a buffer name must be a symbol")
		return 0, false
	}
	name, has_name := v.symbol_name(symbol)
	if !has_name {
		vm.vm_set_error(state, "E_INVARG", "unknown buffer name")
		return 0, false
	}
	relation, known := runtime_relation_named(state, name)
	if !known {
		vm.vm_set_error(
			state,
			"E_INVARG",
			fmt.aprintf("unknown buffer :%s", name, allocator = state.allocator),
		)
		return 0, false
	}
	return k.Relation_ID(relation), true
}

// Resolves a name and checks it really is a buffer.
@(private)
buffer_argument :: proc(state: ^vm.VM, value: v.Value, writable: bool) -> (k.Relation_ID, bool) {
	if state.transaction == nil {
		vm.vm_set_error(state, "E_NO_TRANSACTION", "buffer access requires a task transaction")
		return 0, false
	}
	relation, ok := buffer_relation_arg(state, value)
	if !ok {
		return 0, false
	}
	metadata, known := k.transaction_relation_metadata(state.transaction, relation)
	if !known || metadata.storage != .Buffer {
		vm.vm_set_error(state, "E_INVARG", "name does not refer to a buffer")
		return 0, false
	}
	if metadata.tombstoned {
		vm.vm_set_error(state, "E_KILLED", "the buffer has been killed")
		return 0, false
	}
	if writable {
		if !k.authority_can_write(state.authority, relation) {
			vm.vm_set_error(state, "E_PERMISSION", "buffer write denied")
			return 0, false
		}
	} else if !k.authority_can_read(state.authority, relation) {
		vm.vm_set_error(state, "E_PERMISSION", "buffer read denied")
		return 0, false
	}
	return relation, true
}

@(private)
builtin_make_buffer :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) < 2 || len(args) > 3 {
		vm.vm_set_error(
			state,
			"E_INVARG",
			"make_buffer expects a name, a durability, and an optional conflict policy",
		)
		return v.Value(0), false
	}
	name_symbol, name_ok := v.value_as_symbol(args[0])
	if !name_ok {
		vm.vm_set_error(state, "E_TYPE", "make_buffer name must be a symbol")
		return v.Value(0), false
	}
	name, has_name := v.symbol_name(name_symbol)
	if !has_name {
		vm.vm_set_error(state, "E_INVARG", "make_buffer name is not interned")
		return v.Value(0), false
	}
	durability_symbol, durability_ok := v.value_as_symbol(args[1])
	if !durability_ok {
		vm.vm_set_error(state, "E_TYPE", "make_buffer durability must be a symbol")
		return v.Value(0), false
	}
	durability_name, _ := v.symbol_name(durability_symbol)
	durability: k.Relation_Durability
	switch durability_name {
	case "durable":
		durability = .Durable
	case "volatile":
		durability = .Volatile
	case:
		vm.vm_set_error(state, "E_INVARG", "make_buffer durability is :durable or :volatile")
		return v.Value(0), false
	}

	if state.transaction == nil {
		vm.vm_set_error(state, "E_NO_TRANSACTION", "make_buffer requires a task transaction")
		return v.Value(0), false
	}

	// Re-declaring an existing buffer adopts it. A durable world re-runs its
	// fileins on boot, so declarations must be idempotent.
	if existing, found := k.transaction_relation_metadata_named(state.transaction, name_symbol);
	   found {
		if existing.storage != .Buffer {
			vm.vm_set_error(
				state,
				"E_INVARG",
				fmt.aprintf(":%s is already a relation", name, allocator = state.allocator),
			)
			return v.Value(0), false
		}
		if existing.tombstoned {
			// Ids and names are never reused, so a retired name stays retired.
			vm.vm_set_error(
				state,
				"E_KILLED",
				fmt.aprintf(":%s was killed and is not reused", name, allocator = state.allocator),
			)
			return v.Value(0), false
		}
		return v.value_bool(true), true
	}

	// A shared buffer can opt into provenance merging; the default stays
	// conservative.
	conflict := k.Conflict_Kind.Reject
	if len(args) == 3 {
		policy_symbol, policy_ok := v.value_as_symbol(args[2])
		if !policy_ok {
			vm.vm_set_error(state, "E_TYPE", "make_buffer conflict policy must be a symbol")
			return v.Value(0), false
		}
		policy_name, _ := v.symbol_name(policy_symbol)
		switch policy_name {
		case "reject":
			conflict = .Reject
		case "span":
			conflict = .Span
		case "whole":
			conflict = .Whole
		case:
			vm.vm_set_error(
				state,
				"E_INVARG",
				"make_buffer conflict policy is :reject, :span, or :whole",
			)
			return v.Value(0), false
		}
	}

	metadata := k.relation_metadata(k.Relation_ID(0), name_symbol, 0)
	metadata.storage = .Buffer
	metadata.conflict = k.Conflict_Policy {
		kind = conflict,
	}
	metadata.durability = durability
	_, create_error := k.transaction_create_relation(state.transaction, metadata)
	if create_error != .None {
		vm.vm_set_error(state, "E_WRITE", "make_buffer could not create the buffer")
		return v.Value(0), false
	}
	return v.value_bool(true), true
}

@(private)
builtin_buffer_insert :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 3 {
		vm.vm_set_error(state, "E_INVARG", "buffer_insert expects a buffer, an offset, and text")
		return v.Value(0), false
	}
	relation, ok := buffer_argument(state, args[0], true)
	if !ok {
		return v.Value(0), false
	}
	at, at_ok := v.value_as_int(args[1])
	if !at_ok || at < 0 {
		vm.vm_set_error(state, "E_TYPE", "buffer_insert offset must be a non-negative integer")
		return v.Value(0), false
	}
	text, text_ok := v.value_as_string(args[2])
	if !text_ok {
		vm.vm_set_error(state, "E_TYPE", "buffer_insert text must be a string")
		return v.Value(0), false
	}
	if err := k.transaction_buffer_edit(state.transaction, relation, u64(at), 0, text);
	   err != .None {
		buffer_write_error(state, err, "buffer_insert failed")
		return v.Value(0), false
	}
	return v.value_bool(true), true
}

@(private)
builtin_buffer_delete :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 3 {
		vm.vm_set_error(
			state,
			"E_INVARG",
			"buffer_delete expects a buffer, an offset, and a count",
		)
		return v.Value(0), false
	}
	relation, ok := buffer_argument(state, args[0], true)
	if !ok {
		return v.Value(0), false
	}
	at, at_ok := v.value_as_int(args[1])
	count, count_ok := v.value_as_int(args[2])
	if !at_ok || !count_ok || at < 0 || count < 0 {
		vm.vm_set_error(state, "E_TYPE", "buffer_delete takes non-negative integers")
		return v.Value(0), false
	}
	if err := k.transaction_buffer_edit(state.transaction, relation, u64(at), u64(count), "");
	   err != .None {
		buffer_write_error(state, err, "buffer_delete failed")
		return v.Value(0), false
	}
	return v.value_bool(true), true
}

@(private)
builtin_buffer_replace :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 4 {
		vm.vm_set_error(
			state,
			"E_INVARG",
			"buffer_replace expects a buffer, a start, an end, and text",
		)
		return v.Value(0), false
	}
	relation, ok := buffer_argument(state, args[0], true)
	if !ok {
		return v.Value(0), false
	}
	start, start_ok := v.value_as_int(args[1])
	end, end_ok := v.value_as_int(args[2])
	if !start_ok || !end_ok || start < 0 || end < start {
		vm.vm_set_error(state, "E_INVARG", "buffer_replace range is invalid")
		return v.Value(0), false
	}
	text, text_ok := v.value_as_string(args[3])
	if !text_ok {
		vm.vm_set_error(state, "E_TYPE", "buffer_replace text must be a string")
		return v.Value(0), false
	}
	if err := k.transaction_buffer_edit(
		state.transaction,
		relation,
		u64(start),
		u64(end - start),
		text,
	); err != .None {
		buffer_write_error(state, err, "buffer_replace failed")
		return v.Value(0), false
	}
	return v.value_bool(true), true
}

@(private)
buffer_view :: proc(state: ^vm.VM, value: v.Value) -> (^buf.Piece_Node, bool) {
	relation, ok := buffer_argument(state, value, false)
	if !ok {
		return nil, false
	}
	return k.transaction_buffer_root(state.transaction, relation), true
}

@(private)
builtin_buffer_len :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 1 {
		vm.vm_set_error(state, "E_INVARG", "buffer_len expects a buffer")
		return v.Value(0), false
	}
	root, ok := buffer_view(state, args[0])
	if !ok {
		return v.Value(0), false
	}
	length, length_ok := v.value_int(i64(buf.tree_scalars(root)))
	if !length_ok {
		vm.vm_set_error(state, "E_RANGE", "buffer length is out of range")
		return v.Value(0), false
	}
	return length, true
}

@(private)
builtin_buffer_line_count :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 1 {
		vm.vm_set_error(state, "E_INVARG", "buffer_line_count expects a buffer")
		return v.Value(0), false
	}
	root, ok := buffer_view(state, args[0])
	if !ok {
		return v.Value(0), false
	}
	lines, lines_ok := v.value_int(i64(buf.tree_line_count(root)))
	if !lines_ok {
		vm.vm_set_error(state, "E_RANGE", "buffer line count is out of range")
		return v.Value(0), false
	}
	return lines, true
}

@(private)
builtin_buffer_revision :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 1 {
		vm.vm_set_error(state, "E_INVARG", "buffer_revision expects a buffer")
		return v.Value(0), false
	}
	if state.transaction == nil {
		vm.vm_set_error(state, "E_NO_TRANSACTION", "buffer_revision requires a task transaction")
		return v.Value(0), false
	}
	relation, ok := buffer_argument(state, args[0], false)
	if !ok {
		return v.Value(0), false
	}
	revision, revision_ok := v.value_int(
		i64(k.transaction_buffer_revision(state.transaction, relation)),
	)
	if !revision_ok {
		vm.vm_set_error(state, "E_RANGE", "buffer revision is out of range")
		return v.Value(0), false
	}
	return revision, true
}

@(private)
builtin_buffer_text :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 1 {
		vm.vm_set_error(state, "E_INVARG", "buffer_text expects a buffer")
		return v.Value(0), false
	}
	root, ok := buffer_view(state, args[0])
	if !ok {
		return v.Value(0), false
	}
	return v.value_string(state.allocator, buf.tree_text(root, state.allocator)), true
}

@(private)
builtin_buffer_slice :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 3 {
		vm.vm_set_error(state, "E_INVARG", "buffer_slice expects a buffer, a start, and an end")
		return v.Value(0), false
	}
	root, ok := buffer_view(state, args[0])
	if !ok {
		return v.Value(0), false
	}
	start, start_ok := v.value_as_int(args[1])
	end, end_ok := v.value_as_int(args[2])
	if !start_ok || !end_ok || start < 0 || end < start {
		vm.vm_set_error(state, "E_INVARG", "buffer_slice range is invalid")
		return v.Value(0), false
	}
	text, slice_error := buf.tree_slice(root, u64(start), u64(end), state.allocator)
	if slice_error != .None {
		vm.vm_set_error(state, "E_INDEX", "buffer_slice range is outside the buffer")
		return v.Value(0), false
	}
	return v.value_string(state.allocator, text), true
}

// Searches the buffer for `pattern` at or after scalar `from`, within at most
// `limit` scalars (`0` searches to the end). Returns the scalar offset of the
// first occurrence, or `none`.
@(private)
builtin_buffer_find :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 4 {
		vm.vm_set_error(
			state,
			"E_INVARG",
			"buffer_find expects a buffer, a pattern, a start, and a limit",
		)
		return v.Value(0), false
	}
	root, ok := buffer_view(state, args[0])
	if !ok {
		return v.Value(0), false
	}
	pattern, pattern_ok := v.value_as_string(args[1])
	if !pattern_ok {
		vm.vm_set_error(state, "E_TYPE", "buffer_find pattern must be a string")
		return v.Value(0), false
	}
	from, from_ok := v.value_as_int(args[2])
	limit, limit_ok := v.value_as_int(args[3])
	if !from_ok || !limit_ok || from < 0 || limit < 0 {
		vm.vm_set_error(
			state,
			"E_TYPE",
			"buffer_find start and limit must be non-negative integers",
		)
		return v.Value(0), false
	}
	offset, found := buf.tree_find(root, pattern, u64(from), u64(limit), state.allocator)
	if !found {
		return option_none_value(state.allocator), true
	}
	return buffer_int(i64(offset)), true
}

// Returns a relation value of consecutive line spans.
//
// `first` is a 0-based line index and `count` bounds the scan. Both are
// required: a read that ranges over every line of a buffer is a full document
// scan, so the bounded form is the only shape offered. Each row is
// `[:buffer, :line, :start, :stop, :text]`, and a span excludes the line's
// trailing newline while `stop` counts up to it. (`:end` is a reserved word in
// Mica source, hence the different column name.)
@(private)
builtin_buffer_lines :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 3 {
		vm.vm_set_error(
			state,
			"E_INVARG",
			"buffer_lines expects a buffer, a first line, and a count",
		)
		return v.Value(0), false
	}
	root, ok := buffer_view(state, args[0])
	if !ok {
		return v.Value(0), false
	}
	name, _ := v.value_as_symbol(args[0])
	first, first_ok := v.value_as_int(args[1])
	count, count_ok := v.value_as_int(args[2])
	if !first_ok || !count_ok || first < 0 || count < 0 {
		vm.vm_set_error(
			state,
			"E_TYPE",
			"buffer_lines first and count must be non-negative integers",
		)
		return v.Value(0), false
	}

	total_lines := buf.tree_line_count(root)
	total_scalars := buf.tree_scalars(root)
	last_line := u64(first) + u64(count)
	if last_line > total_lines {
		last_line = total_lines
	}

	rows: [dynamic]v.Tuple
	rows = make([dynamic]v.Tuple, 0, state.allocator)
	for line := u64(first); line < last_line; line += 1 {
		start := buf.tree_line_start(root, line)
		next := total_scalars
		if line + 1 < total_lines {
			next = buf.tree_line_start(root, line + 1)
		}
		raw, slice_error := buf.tree_slice(root, start, next, state.allocator)
		if slice_error != .None {
			vm.vm_set_error(state, "E_RANGE", "buffer_lines could not read a line")
			return v.Value(0), false
		}
		end := next
		text := raw
		if strings.has_suffix(raw, "\n") {
			end = next - 1
			text = raw[:len(raw) - 1]
		}
		row := make([]v.Value, 5, state.allocator)
		row[0] = v.value_symbol(name)
		row[1] = buffer_int(i64(line))
		row[2] = buffer_int(i64(start))
		row[3] = buffer_int(i64(end))
		row[4] = v.value_string(state.allocator, text)
		append(&rows, v.tuple_new(state.allocator, row))
	}

	heading := []v.Symbol {
		v.symbol_intern("buffer"),
		v.symbol_intern("line"),
		v.symbol_intern("start"),
		v.symbol_intern("stop"),
		v.symbol_intern("text"),
	}
	result, relation_error := v.value_relation(state.allocator, heading, rows[:])
	if relation_error != .None {
		vm.vm_set_error(state, "E_INVARG", "buffer_lines could not build a relation")
		return v.Value(0), false
	}
	return result, true
}

// --- Navigation -------------------------------------------------------------
//
// Cursor movement and viewport rendering need line and column arithmetic
// without materializing line text. These four builtins are that surface: line
// bounds, position conversion in both directions, and a bounded viewport read.

// Computes the scalar bounds of one logical line. `stop` excludes the trailing
// newline, so a buffer ending in a newline has a final empty line.
@(private)
buffer_line_bounds :: proc(root: ^buf.Piece_Node, line: u64) -> (start, stop: u64, found: bool) {
	total_lines := buf.tree_line_count(root)
	if line >= total_lines {
		return 0, 0, false
	}
	start = buf.tree_line_start(root, line)
	stop = buf.tree_scalars(root)
	if line + 1 < total_lines {
		stop = buf.tree_line_start(root, line + 1) - 1
	}
	return start, stop, true
}

// Returns the scalar span of one logical line without materializing its text,
// or `none` for a line past the end.
@(private)
builtin_buffer_line_span :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 2 {
		vm.vm_set_error(state, "E_INVARG", "buffer_line_span expects a buffer and a line")
		return v.Value(0), false
	}
	root, ok := buffer_view(state, args[0])
	if !ok {
		return v.Value(0), false
	}
	line, line_ok := v.value_as_int(args[1])
	if !line_ok || line < 0 {
		vm.vm_set_error(
			state,
			"E_TYPE",
			"buffer_line_span line must be a non-negative integer",
		)
		return v.Value(0), false
	}
	start, stop, found := buffer_line_bounds(root, u64(line))
	if !found {
		return option_none_value(state.allocator), true
	}
	entries := []v.Map_Entry {
		{key = buffer_status("start"), value = buffer_int(i64(start))},
		{key = buffer_status("stop"), value = buffer_int(i64(stop))},
	}
	return v.value_map(state.allocator, entries), true
}

// Converts a scalar offset to a logical line and a scalar column. An offset
// past the end clamps to the buffer end.
@(private)
builtin_buffer_position_line_column :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 2 {
		vm.vm_set_error(
			state,
			"E_INVARG",
			"buffer_position_line_column expects a buffer and an offset",
		)
		return v.Value(0), false
	}
	root, ok := buffer_view(state, args[0])
	if !ok {
		return v.Value(0), false
	}
	offset, offset_ok := v.value_as_int(args[1])
	if !offset_ok || offset < 0 {
		vm.vm_set_error(
			state,
			"E_TYPE",
			"buffer_position_line_column offset must be a non-negative integer",
		)
		return v.Value(0), false
	}
	position := min(u64(offset), buf.tree_scalars(root))
	line := buf.tree_line_of_scalar(root, position)
	start := buf.tree_line_start(root, line)
	entries := []v.Map_Entry {
		{key = buffer_status("line"), value = buffer_int(i64(line))},
		{key = buffer_status("column"), value = buffer_int(i64(position - start))},
	}
	return v.value_map(state.allocator, entries), true
}

// Converts a logical line and a scalar column to a scalar offset, clamping the
// column to the line. A line past the end clamps to the buffer end.
@(private)
builtin_buffer_line_column_offset :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 3 {
		vm.vm_set_error(
			state,
			"E_INVARG",
			"buffer_line_column_offset expects a buffer, a line, and a column",
		)
		return v.Value(0), false
	}
	root, ok := buffer_view(state, args[0])
	if !ok {
		return v.Value(0), false
	}
	line, line_ok := v.value_as_int(args[1])
	column, column_ok := v.value_as_int(args[2])
	if !line_ok || !column_ok || line < 0 || column < 0 {
		vm.vm_set_error(
			state,
			"E_TYPE",
			"buffer_line_column_offset line and column must be non-negative integers",
		)
		return v.Value(0), false
	}
	total := buf.tree_scalars(root)
	if u64(line) >= buf.tree_line_count(root) {
		return buffer_int(i64(total)), true
	}
	start, stop, _ := buffer_line_bounds(root, u64(line))
	offset := min(start + u64(column), stop)
	return buffer_int(i64(offset)), true
}

// Builds one `buffer_viewport` row.
@(private)
buffer_viewport_row :: proc(
	allocator: mem.Allocator,
	name: v.Symbol,
	line, start, stop: u64,
	text: string,
	complete: bool,
) -> v.Tuple {
	row := make([]v.Value, 6, allocator)
	row[0] = v.value_symbol(name)
	row[1] = buffer_int(i64(line))
	row[2] = buffer_int(i64(start))
	row[3] = buffer_int(i64(stop))
	row[4] = v.value_string(allocator, text)
	row[5] = v.value_bool(complete)
	return v.tuple_new(allocator, row)
}

// Projects a bounded viewport: at most `lines` rows and at most `max_scalars`
// scalars of text, in the shape `[:buffer, :line, :start, :stop, :text,
// :complete]`. A row the scalar budget cut has `:complete -> false` and ends
// the read. No text outside the budget is materialized.
@(private)
builtin_buffer_viewport :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 4 {
		vm.vm_set_error(
			state,
			"E_INVARG",
			"buffer_viewport expects a buffer, a first line, a line count, and a scalar budget",
		)
		return v.Value(0), false
	}
	root, ok := buffer_view(state, args[0])
	if !ok {
		return v.Value(0), false
	}
	name, _ := v.value_as_symbol(args[0])
	first, first_ok := v.value_as_int(args[1])
	lines, lines_ok := v.value_as_int(args[2])
	budget, budget_ok := v.value_as_int(args[3])
	if !first_ok || !lines_ok || !budget_ok || first < 0 || lines < 0 || budget < 0 {
		vm.vm_set_error(
			state,
			"E_TYPE",
			"buffer_viewport line and budget arguments must be non-negative integers",
		)
		return v.Value(0), false
	}

	total_lines := buf.tree_line_count(root)
	rows: [dynamic]v.Tuple
	rows = make([dynamic]v.Tuple, 0, state.allocator)
	used := u64(0)
	limit := u64(budget)
	line := u64(first)
	for line < total_lines && len(rows) < int(lines) {
		start, stop, _ := buffer_line_bounds(root, line)
		length := stop - start
		remaining := limit - used
		if length > remaining {
			fragment, slice_error := buf.tree_slice(
				root,
				start,
				start + remaining,
				state.allocator,
			)
			if slice_error != .None {
				vm.vm_set_error(state, "E_RANGE", "buffer_viewport could not read a line")
				return v.Value(0), false
			}
			append(
				&rows,
				buffer_viewport_row(
					state.allocator,
					name,
					line,
					start,
					start + remaining,
					fragment,
					false,
				),
			)
			break
		}
		text, slice_error := buf.tree_slice(root, start, stop, state.allocator)
		if slice_error != .None {
			vm.vm_set_error(state, "E_RANGE", "buffer_viewport could not read a line")
			return v.Value(0), false
		}
		append(
			&rows,
			buffer_viewport_row(state.allocator, name, line, start, stop, text, true),
		)
		used += length
		line += 1
	}

	heading := []v.Symbol {
		v.symbol_intern("buffer"),
		v.symbol_intern("line"),
		v.symbol_intern("start"),
		v.symbol_intern("stop"),
		v.symbol_intern("text"),
		v.symbol_intern("complete"),
	}
	result, relation_error := v.value_relation(state.allocator, heading, rows[:])
	if relation_error != .None {
		vm.vm_set_error(state, "E_INVARG", "buffer_viewport could not build a relation")
		return v.Value(0), false
	}
	return result, true
}

// Compacts a buffer: its text moves into fresh original chunks, so subsequent
// edits stop referencing superseded chunks. The content revision is preserved
// (clients see no change) while the structure epoch moves.
@(private)
builtin_buffer_compact :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 1 {
		vm.vm_set_error(state, "E_INVARG", "buffer_compact expects a buffer")
		return v.Value(0), false
	}
	relation, ok := buffer_argument(state, args[0], true)
	if !ok {
		return v.Value(0), false
	}
	if err := k.transaction_buffer_compact(state.transaction, relation); err != .None {
		buffer_write_error(state, err, "buffer_compact failed")
		return v.Value(0), false
	}
	return v.value_bool(true), true
}

// Reports a failed buffer mutation. A revision-checked apply has a distinct
// error so a caller can tell "you already applied" from "the write failed".
@(private)
buffer_write_error :: proc(state: ^vm.VM, err: k.Kernel_Error, what: string) {
	if err == .Already_Applied {
		vm.vm_set_error(state, "E_STATE", "this buffer was already applied in this transaction")
		return
	}
	vm.vm_set_error(state, "E_WRITE", what)
}

// Looks up a symbol-keyed field in a structural map value.
@(private)
buffer_map_field :: proc(fields: []v.Map_Entry, name: string) -> v.Value {
	key := v.value_symbol(v.symbol_intern(name))
	for entry in fields {
		if entry.key == key {
			return entry.value
		}
	}
	return v.Value(0)
}

@(private)
buffer_map_int :: proc(fields: []v.Map_Entry, name: string, default: i64) -> (i64, bool) {
	value := buffer_map_field(fields, name)
	if value == 0 {
		return default, true
	}
	number, is_int := v.value_as_int(value)
	if !is_int {
		return 0, false
	}
	return number, true
}

// Revision-checked batch staging: the shared-editing entry point.
//
// The result is the staging outcome only. What the committed revision and the
// authoritative delta turn out to be is not knowable here -- the commit has not
// happened, and later code in this transaction may still abort -- so the
// completion result is delivered after publication by the host.
@(private)
builtin_buffer_apply :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) < 3 || len(args) > 4 {
		vm.vm_set_error(
			state,
			"E_INVARG",
			"buffer_apply expects a buffer, a revision, a list of edits, and an optional token",
		)
		return v.Value(0), false
	}
	relation, ok := buffer_argument(state, args[0], true)
	if !ok {
		return v.Value(0), false
	}
	expected, expected_ok := v.value_as_int(args[1])
	if !expected_ok || expected < 0 {
		vm.vm_set_error(state, "E_TYPE", "buffer_apply revision must be a non-negative integer")
		return v.Value(0), false
	}
	edit_values, list_ok := v.value_as_list(args[2])
	if !list_ok {
		vm.vm_set_error(state, "E_TYPE", "buffer_apply edits must be a list")
		return v.Value(0), false
	}

	edits := make([]buf.Edit, len(edit_values), context.temp_allocator)
	for value, index in edit_values {
		fields, map_ok := v.value_as_map(value)
		if !map_ok {
			vm.vm_set_error(state, "E_TYPE", "each edit must be a map")
			return v.Value(0), false
		}
		at, at_ok := buffer_map_int(fields, "at", 0)
		remove, remove_ok := buffer_map_int(fields, "remove", 0)
		if !at_ok || !remove_ok || at < 0 || remove < 0 {
			vm.vm_set_error(state, "E_TYPE", "edit offsets must be non-negative integers")
			return v.Value(0), false
		}
		text_value := buffer_map_field(fields, "text")
		text := ""
		if text_value != 0 {
			resolved, text_ok := v.value_as_string(text_value)
			if !text_ok {
				vm.vm_set_error(state, "E_TYPE", "edit text must be a string")
				return v.Value(0), false
			}
			text = resolved
		}
		edits[index] = buf.Edit {
			at     = int(at),
			remove = int(remove),
			text   = text,
		}
	}

	// An optional token asks the server to record a completion the client can
	// read back after publication.
	token := u64(0)
	if len(args) == 4 {
		value, token_ok := v.value_as_int(args[3])
		if !token_ok || value < 0 {
			vm.vm_set_error(state, "E_TYPE", "buffer_apply token must be a non-negative integer")
			return v.Value(0), false
		}
		token = u64(value)
	}

	switch k.transaction_buffer_apply(state.transaction, relation, u64(expected), edits, token) {
	case .Applied:
		return v.value_symbol(v.symbol_intern("staged")), true
	case .Stale:
		return v.value_symbol(v.symbol_intern("stale")), true
	case .Already_Applied:
		vm.vm_set_error(state, "E_STATE", "this buffer was already applied in this transaction")
		return v.Value(0), false
	case .Unknown_Relation:
		vm.vm_set_error(state, "E_INVARG", "buffer_apply could not stage the edits")
		return v.Value(0), false
	}
	return v.Value(0), false
}

// Reverts a buffer to an earlier revision by staging a whole-buffer
// replacement built from fresh chunks.
//
// The status mirrors `buffer_apply`: `:staged` when the reversion is accepted,
// `:stale` when `expected_revision` is not the revision the transaction read,
// and `:unknown` when the target revision is no longer retained. Nothing is
// staged unless the status is `:staged`.
//
// Reverting discards every edit committed since the target revision, so it is
// its own builtin with its own invoke grant rather than a mode of
// `buffer_apply`; a world can authorize it separately.
@(private)
builtin_buffer_revert :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 3 {
		vm.vm_set_error(
			state,
			"E_INVARG",
			"buffer_revert expects a buffer, a revision, and an expected revision",
		)
		return v.Value(0), false
	}
	relation, ok := buffer_argument(state, args[0], true)
	if !ok {
		return v.Value(0), false
	}
	revision, revision_ok := v.value_as_int(args[1])
	expected, expected_ok := v.value_as_int(args[2])
	if !revision_ok || !expected_ok || revision < 0 || expected < 0 {
		vm.vm_set_error(state, "E_TYPE", "buffer_revert revisions must be non-negative integers")
		return v.Value(0), false
	}

	switch k.transaction_buffer_revert(state.transaction, relation, u64(revision), u64(expected)) {
	case .Reverted:
		return buffer_status("staged"), true
	case .Stale:
		return buffer_status("stale"), true
	case .Unknown_Revision:
		return buffer_status("unknown"), true
	case .Dirty:
		vm.vm_set_error(state, "E_STATE", "this buffer was already modified in this transaction")
		return v.Value(0), false
	case .Unknown_Relation:
		vm.vm_set_error(state, "E_INVARG", "buffer_revert could not stage the reversion")
		return v.Value(0), false
	}
	return v.Value(0), false
}

// Moves a position through a committed base-relative delta.
//
// `edits` is a delta in the same shape `buffer_apply_result` returns and the
// `:buffer` change feed delivers: `[{:at, :remove, :text}]`, expressed against
// the base the delta was computed from. The result is the position in the text
// after the delta is applied. `insertion_type` decides only the tie: text
// inserted exactly at the position lands after the marker when the type is
// `:stick_after`, and before it when the type is `:stick_before`.
//
// This is the explicit rebase step for markers. The buffer never moves them
// itself, because a marker is application state: the caller holds the delta (or
// receives it from the change feed) and decides what a collapsed span means.
@(private)
builtin_buffer_marker_rebase :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 3 {
		vm.vm_set_error(
			state,
			"E_INVARG",
			"buffer_marker_rebase expects edits, a position, and an insertion type",
		)
		return v.Value(0), false
	}
	edit_values, list_ok := v.value_as_list(args[0])
	if !list_ok {
		vm.vm_set_error(state, "E_TYPE", "buffer_marker_rebase edits must be a list")
		return v.Value(0), false
	}
	position, position_ok := v.value_as_int(args[1])
	if !position_ok || position < 0 {
		vm.vm_set_error(
			state,
			"E_TYPE",
			"buffer_marker_rebase position must be a non-negative integer",
		)
		return v.Value(0), false
	}
	kind_symbol, kind_ok := v.value_as_symbol(args[2])
	if !kind_ok {
		vm.vm_set_error(state, "E_TYPE", "buffer_marker_rebase insertion type must be a symbol")
		return v.Value(0), false
	}
	kind_name, _ := v.symbol_name(kind_symbol)
	insertion: buf.Marker_Insertion_Type
	switch kind_name {
	case "stick_after":
		insertion = .After
	case "stick_before":
		insertion = .Before
	case:
		vm.vm_set_error(
			state,
			"E_INVARG",
			"buffer_marker_rebase insertion type is :stick_after or :stick_before",
		)
		return v.Value(0), false
	}

	replacements := make([]buf.Replacement, len(edit_values), context.temp_allocator)
	for value, index in edit_values {
		fields, map_ok := v.value_as_map(value)
		if !map_ok {
			vm.vm_set_error(state, "E_TYPE", "each delta entry must be a map")
			return v.Value(0), false
		}
		at, at_ok := buffer_map_int(fields, "at", 0)
		remove, remove_ok := buffer_map_int(fields, "remove", 0)
		if !at_ok || !remove_ok || at < 0 || remove < 0 {
			vm.vm_set_error(state, "E_TYPE", "delta offsets must be non-negative integers")
			return v.Value(0), false
		}
		text_value := buffer_map_field(fields, "text")
		text := ""
		if text_value != 0 {
			resolved, text_ok := v.value_as_string(text_value)
			if !text_ok {
				vm.vm_set_error(state, "E_TYPE", "delta text must be a string")
				return v.Value(0), false
			}
			text = resolved
		}
		replacements[index] = buf.Replacement {
			start = int(at),
			end   = int(at + remove),
			text  = text,
		}
	}

	delta := buf.Delta {
		replacements = replacements,
	}
	rebase, _ := v.value_int(i64(buf.marker_rebase(delta, int(position), insertion)))
	return rebase, true
}

// Kills a buffer: the entry is tombstoned and its content released at// publication. The id and the name are never reused, so any reference a window,
// an undo ring, or a client still holds fails cleanly rather than pointing at
// something new.
@(private)
builtin_kill_buffer :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 1 {
		vm.vm_set_error(state, "E_INVARG", "kill_buffer expects a buffer")
		return v.Value(0), false
	}
	relation, ok := buffer_argument(state, args[0], true)
	if !ok {
		return v.Value(0), false
	}
	if err := k.transaction_kill_relation(state.transaction, relation); err != .None {
		vm.vm_set_error(state, "E_WRITE", "kill_buffer failed")
		return v.Value(0), false
	}
	return v.value_bool(true), true
}

// An integer value whose range is known to be fine.
@(private)
buffer_int :: proc(n: i64) -> v.Value {
	value, _ := v.value_int(n)
	return value
}

// A symbol value for a status name.
@(private)
buffer_status :: proc(name: string) -> v.Value {
	return v.value_symbol(v.symbol_intern(name))
}

@(private)
buffer_status_map :: proc(
	state: ^vm.VM,
	name: string,
	revision: u64,
	entries: []v.Map_Entry,
) -> v.Value {
	fields := make([dynamic]v.Map_Entry, 0, len(entries) + 2, state.allocator)
	append(&fields, v.Map_Entry{key = buffer_status("status"), value = buffer_status(name)})
	append(
		&fields,
		v.Map_Entry{key = buffer_status("revision"), value = buffer_int(i64(revision))},
	)
	append(&fields, ..entries)
	return v.value_map(state.allocator, fields[:])
}

// Reads the completion of a client-tagged apply.
//
// Nothing is known when the edits are staged, so the result is recorded at
// publication and read back here on a later turn. Until then it is `:pending`,
// and a transaction that never published leaves `:aborted`.
@(private)
builtin_buffer_apply_result :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 1 {
		vm.vm_set_error(state, "E_INVARG", "buffer_apply_result expects a token")
		return v.Value(0), false
	}
	token, token_ok := v.value_as_int(args[0])
	if !token_ok || token < 0 {
		vm.vm_set_error(
			state,
			"E_TYPE",
			"buffer_apply_result token must be a non-negative integer",
		)
		return v.Value(0), false
	}

	result, found := k.kernel_buffer_result(builtin_env(state).kernel, u64(token), state.allocator)
	if !found {
		return buffer_status("pending"), true
	}
	if !k.authority_can_read(state.authority, result.relation) {
		vm.vm_set_error(state, "E_PERMISSION", "buffer apply result read denied")
		return v.Value(0), false
	}

	switch result.outcome {
	case .Aborted:
		return buffer_status_map(state, "aborted", result.revision, nil), true
	case .Resync:
		return buffer_status_map(state, "resync", result.revision, nil), true
	case .Conflict:
		return buffer_status_map(state, "conflict", result.revision, nil), true
	case .Ok:
	}

	applied := make([]v.Value, len(result.delta.replacements), state.allocator)
	for replacement, index in result.delta.replacements {
		applied[index] = v.value_map(
			state.allocator,
			[]v.Map_Entry {
				{key = buffer_status("at"), value = buffer_int(i64(replacement.start))},
				{
					key = buffer_status("remove"),
					value = buffer_int(i64(replacement.end - replacement.start)),
				},
				{
					key = buffer_status("text"),
					value = v.value_string(state.allocator, replacement.text),
				},
			},
		)
	}
	entries := make([]v.Map_Entry, 1, state.allocator)
	entries[0] = v.Map_Entry {
		key   = buffer_status("applied"),
		value = v.value_list(state.allocator, applied),
	}
	return buffer_status_map(state, "ok", result.revision, entries), true
}
