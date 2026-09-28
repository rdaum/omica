// Rule-visible, read-only projections over transactional buffers and markers.
package mica_runtime

import "core:slice"
import "core:strings"
import "core:sync"

import buf "../buffer"
import k "../kernel"
import v "../var"

@(private)
computed_source_metadata_named :: proc(
	source: ^k.Relation_Source,
	name: v.Symbol,
) -> (
	k.Relation_Metadata,
	bool,
) {
	if source.transaction != nil {
		return k.transaction_relation_metadata_named(source.transaction, name)
	}
	if source.snapshot != nil {
		return k.snapshot_relation_metadata_named(source.snapshot, name)
	}
	return {}, false
}

@(private)
computed_buffer_root :: proc(
	source: ^k.Relation_Source,
	name: v.Symbol,
) -> (
	^buf.Piece_Node,
	u64,
	bool,
	k.Kernel_Error,
) {
	metadata, found := computed_source_metadata_named(source, name)
	if !found || metadata.storage != .Buffer || metadata.tombstoned {
		return nil, 0, false, .None
	}
	if !k.authority_can_read(source.authority, metadata.id) {
		return nil, 0, false, .Permission_Denied
	}
	if source.transaction != nil {
		return k.transaction_buffer_root(source.transaction, metadata.id),
			k.transaction_buffer_projected_revision(source.transaction, metadata.id),
			true,
			.None
	}
	block, has_block := k.snapshot_buffer(source.snapshot, metadata.id)
	if !has_block {
		return nil, 0, false, .None
	}
	return block.root, block.revision, true, .None
}

@(private)
computed_bound_symbol :: proc(bindings: []v.Binding, position: int) -> (v.Symbol, bool) {
	if position >= len(bindings) || !bindings[position].bound {
		return v.Symbol(0), false
	}
	return v.value_as_symbol(bindings[position].value)
}

@(private)
computed_bound_nonnegative :: proc(bindings: []v.Binding, position: int) -> (u64, bool) {
	if position >= len(bindings) || !bindings[position].bound {
		return 0, false
	}
	value, ok := v.value_as_int(bindings[position].value)
	return u64(max(value, 0)), ok && value >= 0
}

@(private)
computed_int :: proc(value: u64) -> v.Value {
	result, ok := v.value_int(i64(value))
	return ok ? result : v.Value(0)
}

@(private)
buffer_stat_scan :: proc(
	user: rawptr,
	source: ^k.Relation_Source,
	bindings: []v.Binding,
	visit: k.Computed_Visit_Proc,
	visit_user: rawptr,
) -> k.Kernel_Error {
	name, ok := computed_bound_symbol(bindings, 0)
	if !ok {
		return .Computed_Binding_Required
	}
	root, revision, found, read_error := computed_buffer_root(source, name)
	if read_error != .None {
		return read_error
	}
	if !found {
		return .None
	}
	row := v.tuple_new(
		context.temp_allocator,
		[]v.Value {
			v.value_symbol(name),
			computed_int(buf.tree_scalars(root)),
			computed_int(buf.tree_line_count(root)),
			computed_int(revision),
		},
	)
	_ = visit(visit_user, row)
	return .None
}

// BufferLine(buffer, first, count, line, start, stop, text). `first` and
// `count` are required inputs, which keeps every scan bounded.
@(private)
buffer_line_scan :: proc(
	user: rawptr,
	source: ^k.Relation_Source,
	bindings: []v.Binding,
	visit: k.Computed_Visit_Proc,
	visit_user: rawptr,
) -> k.Kernel_Error {
	name, name_ok := computed_bound_symbol(bindings, 0)
	first, first_ok := computed_bound_nonnegative(bindings, 1)
	count, count_ok := computed_bound_nonnegative(bindings, 2)
	if !name_ok || !first_ok || !count_ok {
		return .Computed_Binding_Required
	}
	root, _, found, read_error := computed_buffer_root(source, name)
	if read_error != .None {
		return read_error
	}
	if !found || count == 0 {
		return .None
	}
	total_lines := buf.tree_line_count(root)
	total_scalars := buf.tree_scalars(root)
	last := first + min(count, max(u64) - first)
	last = min(last, total_lines)
	for line := first; line < last; line += 1 {
		start := buf.tree_line_start(root, line)
		next := total_scalars
		if line + 1 < total_lines {
			next = buf.tree_line_start(root, line + 1)
		}
		text, read_error := buf.tree_slice(root, start, next, context.temp_allocator)
		if read_error != .None {
			return .Arity_Mismatch
		}
		stop := next
		if strings.has_suffix(text, "\n") {
			stop -= 1
			text = text[:len(text) - 1]
		}
		row := v.tuple_new(
			context.temp_allocator,
			[]v.Value {
				v.value_symbol(name),
				computed_int(first),
				computed_int(count),
				computed_int(line),
				computed_int(start),
				computed_int(stop),
				v.value_string(context.temp_allocator, text),
			},
		)
		if !visit(visit_user, row) {
			break
		}
	}
	return .None
}

@(private)
Marker_Point :: struct {
	id:       v.Value,
	position: u64,
}

@(private)
computed_relation_id :: proc(source: ^k.Relation_Source, name: string) -> (k.Relation_ID, bool) {
	metadata, found := computed_source_metadata_named(source, v.symbol_intern(name))
	return metadata.id, found
}

@(private)
buffer_marker_points :: proc(
	source: ^k.Relation_Source,
	buffer_name: v.Symbol,
	revision: u64,
) -> [dynamic]Marker_Point {
	marker_buffer, has_buffer := computed_relation_id(source, "MarkerBuffer")
	marker_position, has_position := computed_relation_id(source, "MarkerPosition")
	marker_revision, has_revision := computed_relation_id(source, "MarkerRevision")
	points: [dynamic]Marker_Point
	if !has_buffer || !has_position || !has_revision {
		return points
	}

	markers: [dynamic]v.Tuple
	k.relation_source_scan_into(
		source,
		marker_buffer,
		[]v.Binding{{}, v.binding_of(v.value_symbol(buffer_name))},
		&markers,
	)
	defer delete(markers)
	for marker_row in markers {
		id := v.tuple_values(marker_row)[0]
		positions: [dynamic]v.Tuple
		revisions: [dynamic]v.Tuple
		k.relation_source_scan_into(
			source,
			marker_position,
			[]v.Binding{v.binding_of(id), {}},
			&positions,
		)
		k.relation_source_scan_into(
			source,
			marker_revision,
			[]v.Binding{v.binding_of(id), {}},
			&revisions,
		)
		if len(positions) == 1 && len(revisions) == 1 {
			position, position_ok := v.value_as_int(v.tuple_values(positions[0])[1])
			anchored, revision_ok := v.value_as_int(v.tuple_values(revisions[0])[1])
			if position_ok && revision_ok && position >= 0 && u64(anchored) == revision {
				append(&points, Marker_Point{id = id, position = u64(position)})
			}
		}
		delete(positions)
		delete(revisions)
	}
	slice.sort_by(points[:], proc(a, b: Marker_Point) -> bool {
		if a.position != b.position {
			return a.position < b.position
		}
		return v.value_cmp(a.id, b.id) == .Less
	})
	return points
}

@(private)
buffer_marker_points_indexed :: proc(
	env: ^Builtin_Env,
	source: ^k.Relation_Source,
	buffer_name: v.Symbol,
	revision: u64,
) -> [dynamic]Marker_Point {
	marker_buffer, has_buffer := computed_relation_id(source, "MarkerBuffer")
	marker_position, has_position := computed_relation_id(source, "MarkerPosition")
	marker_revision, has_revision := computed_relation_id(source, "MarkerRevision")
	cacheable := has_buffer && has_position && has_revision
	version := u64(0)
	if source.transaction != nil {
		version = source.transaction.base.version
		buffer_metadata, has_metadata := computed_source_metadata_named(source, buffer_name)
		cacheable =
			cacheable &&
			has_metadata &&
			!k.transaction_writes_buffer(source.transaction, buffer_metadata.id) &&
			!k.transaction_writes_relation(source.transaction, marker_buffer) &&
			!k.transaction_writes_relation(source.transaction, marker_position) &&
			!k.transaction_writes_relation(source.transaction, marker_revision)
	} else if source.snapshot != nil {
		version = source.snapshot.version
	} else {
		cacheable = false
	}
	if !cacheable {
		return buffer_marker_points(source, buffer_name, revision)
	}

	sync.mutex_lock(&env.marker_index_lock)
	if env.marker_index_initialized &&
	   env.marker_index_version == version &&
	   env.marker_index_revision == revision &&
	   env.marker_index_buffer == buffer_name {
		points := make([dynamic]Marker_Point, len(env.marker_index_points), context.temp_allocator)
		copy(points[:], env.marker_index_points[:])
		sync.mutex_unlock(&env.marker_index_lock)
		return points
	}
	sync.mutex_unlock(&env.marker_index_lock)

	points := buffer_marker_points(source, buffer_name, revision)
	sync.mutex_lock(&env.marker_index_lock)
	delete(env.marker_index_points)
	env.marker_index_points = make([dynamic]Marker_Point, len(points), env.allocator)
	copy(env.marker_index_points[:], points[:])
	env.marker_index_initialized = true
	env.marker_index_version = version
	env.marker_index_revision = revision
	env.marker_index_buffer = buffer_name
	sync.mutex_unlock(&env.marker_index_lock)
	return points
}

// BufferMarkers(buffer, window_start, window_end, marker, start, end). Markers
// are points, so start and end are equal; retaining both columns lets this join
// with interval-shaped consumers without a second projection.
@(private)
buffer_markers_scan :: proc(
	user: rawptr,
	source: ^k.Relation_Source,
	bindings: []v.Binding,
	visit: k.Computed_Visit_Proc,
	visit_user: rawptr,
) -> k.Kernel_Error {
	name, name_ok := computed_bound_symbol(bindings, 0)
	window_start, start_ok := computed_bound_nonnegative(bindings, 1)
	window_end, end_ok := computed_bound_nonnegative(bindings, 2)
	if !name_ok || !start_ok || !end_ok {
		return .Computed_Binding_Required
	}
	if window_end < window_start {
		return .Arity_Mismatch
	}
	_, revision, found, read_error := computed_buffer_root(source, name)
	if read_error != .None {
		return read_error
	}
	if !found {
		return .None
	}
	env := (^Builtin_Env)(user)
	points := buffer_marker_points_indexed(env, source, name, revision)
	defer delete(points)
	// Binary-search the sorted point index, then visit only the bounded window.
	low := 0
	high := len(points)
	for low < high {
		mid := (low + high) / 2
		if points[mid].position < window_start {
			low = mid + 1
		} else {
			high = mid
		}
	}
	for index := low; index < len(points); index += 1 {
		point := points[index]
		if point.position >= window_end {
			break
		}
		position := computed_int(point.position)
		row := v.tuple_new(
			context.temp_allocator,
			[]v.Value {
				v.value_symbol(name),
				computed_int(window_start),
				computed_int(window_end),
				point.id,
				position,
				position,
			},
		)
		if !visit(visit_user, row) {
			break
		}
	}
	return .None
}

// Registers whichever standard buffer projections exist in this world. A
// world that does not load the buffer library simply has nothing to register.
install_runtime_computed_relations :: proc(env: ^Builtin_Env) -> Run_Result {
	registrations := []struct {
		name:     string,
		required: []u16,
		scan:     k.Computed_Scan_Proc,
	} {
		{"BufferStat", []u16{0}, buffer_stat_scan},
		{"BufferLine", []u16{0, 1, 2}, buffer_line_scan},
		{"BufferMarkers", []u16{0, 1, 2}, buffer_markers_scan},
	}
	for registration in registrations {
		relation, found := env.ctx.relations[registration.name]
		if !found {
			continue
		}
		if err := k.kernel_register_computed_relation(
			env.kernel,
			k.Relation_ID(relation),
			registration.required,
			registration.scan,
			rawptr(env),
		); err != .None {
			return Run_Result{ok = false, message = "cannot register buffer computed relation"}
		}
	}
	if installed := install_neighbourhood_computed_relations(env); !installed.ok {
		return installed
	}
	if installed := install_error_hierarchy_computed_relation(env); !installed.ok {
		return installed
	}
	return install_retrieval_computed_relation(env)
}
