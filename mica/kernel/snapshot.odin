// Snapshot-published world state.
//
// A snapshot is immutable after publication. All snapshot data - values,
// tuples, blocks, metadata, and derived rows - lives in the kernel's shared
// committed store, so a snapshot holds no arena of its own. Each snapshot
// retains its parent so values inherited along the commit chain stay alive.
// Snapshots are reference-counted; the last release frees the header only,
// because the committed store outlives every snapshot.
package kernel

import v "../var"
import "base:runtime"
import "core:mem"
import "core:slice"
import "core:mem/virtual"
import "core:sync"

// A derived relation's rows, computed from rules at snapshot creation.
Derived_Relation :: struct {
	relation: Relation_ID,
	tuples:   []v.Tuple,
}

// Immutable world state at a version.
//
// A snapshot owns an arena for its catalog/blocks/rules arrays and derived
// rows, plus one reference to every block in `blocks`. It does not own its
// parent: `parent` is a borrowed link for version ancestry only, because block
// reference counts keep shared data alive independently of the version chain.
Snapshot :: struct {
	version:   u64,
	parent:    ^Snapshot,
	refs:      i32,
	arena:     ^Frame_Arena,
	pool:      ^Arena_Pool,
	allocator: mem.Allocator,
	catalog:   []Relation_Metadata,
	blocks:    []^Relation_Block,
	buffers:   []^Buffer_Block,
	rules:     []Rule_Definition,
	// Derived relations, one block per relation with rows, kept apart from
	// `blocks` so checkpoints, the log and restore never see derived rows.
	// The snapshot holds one reference to each; an unchanged relation shares
	// its block with the snapshot it was derived from.
	derived_blocks: []^Relation_Block,
}

// Creates an empty snapshot with arrays allocated from a pooled arena owned by
// the snapshot. `parent` is borrowed, not retained.
snapshot_create :: proc(kernel: ^Kernel, version: u64, parent: ^Snapshot) -> ^Snapshot {
	arena := arena_pool_take(kernel.arena_pool)
	snapshot := new(Snapshot, runtime.default_allocator())
	snapshot.version = version
	snapshot.refs = 1
	snapshot.parent = parent
	snapshot.arena = arena
	snapshot.pool = kernel.arena_pool
	snapshot.allocator = frame_arena_allocator(arena)
	// Callers that fork or add entries assign these arrays; leaving them nil
	// avoids four allocator round-trips per snapshot.
	snapshot.catalog = nil
	snapshot.blocks = nil
	snapshot.buffers = nil
	snapshot.rules = nil
	snapshot.derived_blocks = nil
	return snapshot
}

// Increments the reference count of a snapshot. Thread-safe. A relaxed
// increment is sufficient: the reference itself is acquired with acquire
// semantics elsewhere.
snapshot_retain :: proc(snapshot: ^Snapshot) {
	if snapshot == nil {
		return
	}
	sync.atomic_add_explicit(&snapshot.refs, 1, .Relaxed)
}

// Decrements the reference count of a snapshot, destroying it and its arenas
// when the last reference is released. Thread-safe: a snapshot can only reach
// zero once every holder has released it.
snapshot_release :: proc(snapshot: ^Snapshot) {
	if snapshot == nil {
		return
	}
	// Only the releaser that observed the last reference may free. Acq_Rel
	// pairs with earlier decrements so the freeing thread sees every write
	// made while other holders still had references; the other releasers must
	// not touch the snapshot after their decrement.
	if sync.atomic_sub_explicit(&snapshot.refs, 1, .Acq_Rel) != 1 {
		return
	}

	for block in snapshot.blocks {
		relation_block_release(block)
	}
	snapshot.blocks = nil
	for block in snapshot.buffers {
		buffer_block_release(block)
	}
	snapshot.buffers = nil
	snapshot_release_derived(snapshot)
	if snapshot.arena != nil {
		arena_pool_return(snapshot.pool, snapshot.arena)
		snapshot.arena = nil
	}
	free(snapshot, runtime.default_allocator())
}

// Creates a child snapshot that inherits the parent catalog, blocks, and
// rules. The child takes its own reference to every inherited block.
snapshot_fork :: proc(kernel: ^Kernel, parent: ^Snapshot) -> ^Snapshot {
	snapshot := snapshot_create(kernel, parent.version + 1, parent)

	snapshot.catalog = make([]Relation_Metadata, len(parent.catalog), snapshot.allocator)
	copy(snapshot.catalog, parent.catalog)
	snapshot.blocks = make([]^Relation_Block, len(parent.blocks), snapshot.allocator)
	for block, index in parent.blocks {
		relation_block_retain(block)
		snapshot.blocks[index] = block
	}
	snapshot.buffers = make([]^Buffer_Block, len(parent.buffers), snapshot.allocator)
	for block, index in parent.buffers {
		buffer_block_retain(block)
		snapshot.buffers[index] = block
	}
	snapshot.rules = make([]Rule_Definition, len(parent.rules), snapshot.allocator)
	copy(snapshot.rules, parent.rules)

	return snapshot
}

// Returns relation metadata by id.
snapshot_relation_metadata :: proc(
	snapshot: ^Snapshot,
	relation: Relation_ID,
) -> (
	Relation_Metadata,
	bool,
) {
	for metadata in snapshot.catalog {
		if metadata.id == relation {
			return metadata, true
		}
	}
	return {}, false
}

// Returns relation metadata by name.
snapshot_relation_metadata_named :: proc(
	snapshot: ^Snapshot,
	name: v.Symbol,
) -> (
	Relation_Metadata,
	bool,
) {
	for metadata in snapshot.catalog {
		if metadata.name == name {
			return metadata, true
		}
	}
	return {}, false
}

// Returns true when a relation exists in this snapshot's catalog.
snapshot_has_relation :: proc(snapshot: ^Snapshot, relation: Relation_ID) -> bool {
	for metadata in snapshot.catalog {
		if metadata.id == relation {
			return true
		}
	}
	return false
}

// Returns the materialized block for a relation, if any.
snapshot_relation_block :: proc(
	snapshot: ^Snapshot,
	relation: Relation_ID,
) -> (
	^Relation_Block,
	bool,
) {
	for block in snapshot.blocks {
		if block.metadata.id == relation {
			return block, true
		}
	}
	return nil, false
}

// The block holding a derived relation's rows on this snapshot.
snapshot_derived_block :: proc(snapshot: ^Snapshot, relation: Relation_ID) -> (^Relation_Block, bool) {
	for block in snapshot.derived_blocks {
		if block.metadata.id == relation {
			return block, true
		}
	}
	return nil, false
}

// The rows of a derived relation on this snapshot, materialized into `alloc`
// (the tuples still point into the block).
snapshot_derived_rows :: proc(
	snapshot: ^Snapshot,
	relation: Relation_ID,
	alloc := context.temp_allocator,
) -> []v.Tuple {
	block, ok := snapshot_derived_block(snapshot, relation)
	if !ok {
		return nil
	}
	rows := make([]v.Tuple, relation_block_len(block), alloc)
	for &row, index in rows {
		row = relation_block_row(block, index)
	}
	return rows
}

@(private)
snapshot_release_derived :: proc(snapshot: ^Snapshot) {
	for block in snapshot.derived_blocks {
		relation_block_release(block)
	}
	snapshot.derived_blocks = nil
}

// Reports whether a relation tuple is visible in this snapshot, including
// derived facts.
snapshot_contains :: proc(snapshot: ^Snapshot, relation: Relation_ID, tuple: v.Tuple) -> bool {
	if block, ok := snapshot_relation_block(snapshot, relation); ok {
		if relation_block_contains(block, tuple) {
			return true
		}
	}
	if block, ok := snapshot_derived_block(snapshot, relation); ok {
		return relation_block_contains(block, tuple)
	}
	return false
}

// Reports whether a relation tuple is stored extensionally in this snapshot.
snapshot_contains_extensional :: proc(
	snapshot: ^Snapshot,
	relation: Relation_ID,
	tuple: v.Tuple,
) -> bool {
	if block, ok := snapshot_relation_block(snapshot, relation); ok {
		return relation_block_contains(block, tuple)
	}
	return false
}

// Visits extensional tuples matching a partial binding.
snapshot_visit_extensional :: proc(
	snapshot: ^Snapshot,
	relation: Relation_ID,
	bindings: []v.Binding,
	visit: proc(user: rawptr, row: v.Tuple) -> bool,
	user: rawptr,
) {
	if block, ok := snapshot_relation_block(snapshot, relation); ok {
		relation_block_visit(block, bindings, visit, user)
	}
}

// Looks up the extensional tuple for an exact projected key.
snapshot_tuple_for_key :: proc(
	snapshot: ^Snapshot,
	relation: Relation_ID,
	positions: []u16,
	key_values: []v.Value,
) -> (
	v.Tuple,
	bool,
) {
	if block, ok := snapshot_relation_block(snapshot, relation); ok {
		return relation_block_tuple_for_key(block, positions, key_values)
	}
	return nil, false
}

// Replaces a relation block in a snapshot's block list, inserting in relation
// id order. The block list is reallocated from the snapshot allocator.
snapshot_set_block :: proc(snapshot: ^Snapshot, block: ^Relation_Block) {
	replaced := false
	for existing, i in snapshot.blocks {
		if existing.metadata.id == block.metadata.id {
			snapshot.blocks[i] = block
			relation_block_release(existing)
			replaced = true
			break
		}
	}
	if replaced {
		return
	}

	blocks := make([]^Relation_Block, len(snapshot.blocks) + 1, snapshot.allocator)
	write := 0
	inserted := false
	for existing in snapshot.blocks {
		if !inserted && existing.metadata.id > block.metadata.id {
			blocks[write] = block
			write += 1
			inserted = true
		}
		blocks[write] = existing
		write += 1
	}
	if !inserted {
		blocks[write] = block
	}
	snapshot.blocks = blocks
}

// Appends a relation to the catalog.
snapshot_add_relation :: proc(snapshot: ^Snapshot, metadata: Relation_Metadata) {
	catalog := make([]Relation_Metadata, len(snapshot.catalog) + 1, snapshot.allocator)
	copy(catalog, snapshot.catalog)
	catalog[len(snapshot.catalog)] = metadata
	snapshot.catalog = catalog
}

// Appends a rule definition to the snapshot.
snapshot_add_rule :: proc(snapshot: ^Snapshot, rule: Rule_Definition) {
	rules := make([]Rule_Definition, len(snapshot.rules) + 1, snapshot.allocator)
	copy(rules, snapshot.rules)
	rules[len(snapshot.rules)] = rule
	snapshot.rules = rules
}

// Returns active rules from a snapshot, allocated from `alloc`.
snapshot_active_rules :: proc(snapshot: ^Snapshot, alloc: mem.Allocator) -> []Rule {
	rules := make([]Rule, len(snapshot.rules), alloc)
	write := 0
	for definition in snapshot.rules {
		if definition.active {
			rules[write] = definition.rule
			write += 1
		}
	}
	return rules[:write]
}


// Converts an evaluation result into sorted relation row sets allocated from
// `alloc`: the canonical rows of each relation are deep-copied into one packed
// value array, so the result references no evaluation storage and `alloc` (a
// snapshot's frame arena, which never frees) holds only the rows. Sorting
// happens in a temporary region of `scratch`, rolled back after each
// relation, so its peak follows the largest relation.
derived_relations_from :: proc(
	alloc: mem.Allocator,
	derived: ^Rule_Derived,
	scratch: ^virtual.Arena,
) -> []Derived_Relation {
	relations := make([]Derived_Relation, len(derived.relations), alloc)
	for entry, i in derived.relations {
		temp := virtual.arena_temp_begin(scratch)
		order := derived_canonical_order(entry, virtual.arena_allocator(scratch))
		arity := entry.arity
		packed := make([]v.Value, len(order) * arity, alloc)
		tuples := make([]v.Tuple, len(order), alloc)
		for row, r in order {
			values := packed[r * arity:(r + 1) * arity]
			for c in 0 ..< arity {
				values[c] = v.value_deep_copy(alloc, entry.columns[c][row])
			}
			tuples[r] = v.Tuple(values)
		}
		virtual.arena_temp_end(temp)
		relations[i] = Derived_Relation {
			relation = entry.relation,
			tuples   = tuples,
		}
	}
	return relations
}

// The canonical order of a relation's rows (as `canonicalize_tuples` orders
// and deduplicates them), computed from its columns and allocated from
// `alloc`. Rows whose cells all have sort keys are radix-sorted by key;
// otherwise rows are compared with `value_cmp` column by column.
derived_canonical_order :: proc(entry: ^Derived_Columns, alloc: mem.Allocator) -> []u32 {
	rows := len(entry.hashes)
	arity := entry.arity
	order := make([]u32, rows, alloc)
	for r in 0 ..< rows {
		order[r] = u32(r)
	}
	keys := make([]u64, rows * arity, alloc)
	defer delete(keys, alloc)
	for c in 0 ..< arity {
		for value, r in entry.columns[c][:rows] {
			key, keyed := v.value_sort_key(value)
			if !keyed {
				return derived_compare_order(entry, order)
			}
			keys[r * arity + c] = key
		}
	}
	v.key_order_sort(order, keys, arity, alloc)
	return order[:v.key_order_dedup(order, keys, arity)]
}

// Sorts and deduplicates `order` by comparing rows column by column, for rows
// with heap values.
@(private)
derived_compare_order :: proc(entry: ^Derived_Columns, order: []u32) -> []u32 {
	slice.sort_by_with_data(order, proc(a, b: u32, user: rawptr) -> bool {
		return derived_row_cmp((^Derived_Columns)(user), a, b) == .Less
	}, entry)
	count := 0
	for row in order {
		if count > 0 && derived_row_cmp(entry, order[count - 1], row) == .Equal {
			continue
		}
		order[count] = row
		count += 1
	}
	return order[:count]
}

@(private)
derived_row_cmp :: proc(entry: ^Derived_Columns, a, b: u32) -> v.Ordering {
	for column in entry.columns {
		if order := v.value_cmp(column[a], column[b]); order != .Equal {
			return order
		}
	}
	return .Equal
}

// Computes all derived relations for a snapshot from its active rules and
// stores them on the snapshot. Evaluation runs in a short-lived arena; the
// surviving tuples are deep-copied into the snapshot arena.
snapshot_compute_derived :: proc(snapshot: ^Snapshot, kernel: ^Kernel = nil, base: ^Snapshot = nil) {
	snapshot_release_derived(snapshot)
	if len(snapshot.rules) == 0 {
		return
	}

	arena := new(virtual.Arena, runtime.default_allocator())
	if err := virtual.arena_init_growing(arena); err != nil {
		panic("failed to initialize rule evaluation arena")
	}
	defer {
		virtual.arena_destroy(arena)
		free(arena, runtime.default_allocator())
	}
	alloc := virtual.arena_allocator(arena)

	if kernel != nil {
		sync.atomic_add_explicit(&kernel.derivations, 1, .Release)
	}
	// Result rows on the heap: a growing relation frees each outgrown column,
	// where the evaluation arena would keep every copy until the end.
	derived := rules_derived_create_backed(alloc, runtime.heap_allocator())
	defer rules_derived_destroy(&derived)
	source := Relation_Source {
		kernel   = kernel,
		snapshot = snapshot,
		derived  = &derived,
	}
	if err := rules_evaluate_source(alloc, snapshot.rules, &source, &derived); err != .None {
		return
	}
	snapshot.derived_blocks = derived_blocks_from(snapshot, &derived, arena, base)
}

// One block per derived relation with rows, in canonical order. A relation
// whose rows equal `base`'s (a snapshot the caller holds) shares base's block
// instead of copying it. Sorting and row views use temporary regions of
// `scratch`, rolled back per relation.
@(private)
derived_blocks_from :: proc(
	snapshot: ^Snapshot,
	derived: ^Rule_Derived,
	scratch: ^virtual.Arena,
	base: ^Snapshot,
) -> []^Relation_Block {
	blocks := make([dynamic]^Relation_Block, 0, len(derived.relations), snapshot.allocator)
	for entry in derived.relations {
		temp := virtual.arena_temp_begin(scratch)
		defer virtual.arena_temp_end(temp)
		order := derived_canonical_order(entry, virtual.arena_allocator(scratch))
		if len(order) == 0 {
			continue
		}
		if base != nil {
			if shared, ok := snapshot_derived_block(base, entry.relation); ok && derived_block_matches(shared, entry, order) {
				relation_block_retain(shared)
				append(&blocks, shared)
				continue
			}
		}
		arity := entry.arity
		values := make([]v.Value, len(order) * arity, virtual.arena_allocator(scratch))
		rows := make([]v.Tuple, len(order), virtual.arena_allocator(scratch))
		for row, r in order {
			view := values[r * arity:(r + 1) * arity]
			for c in 0 ..< arity {
				view[c] = entry.columns[c][row]
			}
			rows[r] = v.Tuple(view)
		}
		metadata, found := snapshot_relation_metadata(snapshot, entry.relation)
		if !found {
			metadata = Relation_Metadata{id = entry.relation, arity = u16(arity)}
		}
		append(&blocks, relation_block_from_canonical(snapshot.pool, metadata, rows))
	}
	return blocks[:]
}

// Whether `block` holds exactly the rows of `entry` in canonical `order`.
@(private)
derived_block_matches :: proc(block: ^Relation_Block, entry: ^Derived_Columns, order: []u32) -> bool {
	if relation_block_len(block) != len(order) {
		return false
	}
	for row, r in order {
		stored := v.tuple_values(relation_block_row(block, r))
		for c in 0 ..< entry.arity {
			if !v.value_eq(stored[c], entry.columns[c][row]) {
				return false
			}
		}
	}
	return true
}

// Returns the buffer block for a relation, if any.
snapshot_buffer :: proc(snapshot: ^Snapshot, relation: Relation_ID) -> (^Buffer_Block, bool) {
	for block in snapshot.buffers {
		if block.relation == relation {
			return block, true
		}
	}
	return nil, false
}

// Replaces a buffer block in a snapshot's buffer list, inserting in relation id
// order. Mirrors `snapshot_set_block`.
snapshot_set_buffer :: proc(snapshot: ^Snapshot, block: ^Buffer_Block) {
	replaced := false
	for existing, i in snapshot.buffers {
		if existing.relation == block.relation {
			snapshot.buffers[i] = block
			buffer_block_release(existing)
			replaced = true
			break
		}
	}
	if replaced {
		return
	}

	buffers := make([]^Buffer_Block, len(snapshot.buffers) + 1, snapshot.allocator)
	write := 0
	inserted := false
	for existing in snapshot.buffers {
		if !inserted && existing.relation > block.relation {
			buffers[write] = block
			write += 1
			inserted = true
		}
		buffers[write] = existing
		write += 1
	}
	if !inserted {
		buffers[write] = block
	}
	snapshot.buffers = buffers
}
