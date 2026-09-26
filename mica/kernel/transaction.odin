// Transactions: staged writes over a base snapshot with read-your-own-writes
// and snapshot-isolation commit.
//
// A transaction owns an arena for values and tuples it creates. On commit the
// arena is handed to the new snapshot; on abort it is destroyed with the
// transaction. Commit either succeeds against the published snapshot, or
// validates conflicts for a rebase onto a newer published snapshot, matching
// the relation conflict policy.
package kernel

import buf "../buffer"
import v "../var"
import "base:runtime"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:sync"

// The kind of a staged write.
Write_Kind :: enum {
	Assert,
	Retract,
}

// A staged tuple change.
Pending_Write :: struct {
	tuple: v.Tuple,
	kind:  Write_Kind,
}

// Entry-index sentinel for the staging bucket chains.
@(private)
NO_ENTRY :: max(u32)

// Staged writes for one relation.
Relation_Writes :: struct {
	relation:       Relation_ID,
	entries:        [dynamic]Pending_Write,
	// Hash index over `entries` for duplicate lookup: `buckets` maps a tuple
	// hash to an entry index and `next_in_bucket` chains entries that share a
	// hash. Staging a write then costs O(1) expected instead of scanning every
	// prior entry. `transaction_prepare_writes` rebuilds the chains after its
	// compaction and sort.
	buckets:        map[u64]u32,
	next_in_bucket: [dynamic]u32,
	// Functional-key index over `entries`, maintained only for functional
	// relations: `key_buckets` maps the hash of the projected key to an entry
	// index and `next_key` chains entries whose key hashes collide. This keeps
	// the functional-key visibility check O(1) expected per assert. The
	// positions are a view into the base snapshot's cloned catalog metadata,
	// valid for the transaction's lifetime.
	functional:     bool,
	key_positions:  []u16,
	key_buckets:    map[u64]u32,
	next_key:       [dynamic]u32,
}

// A snapshot-isolated transaction over a base snapshot.
Transaction :: struct {
	kernel:              ^Kernel,
	base:                ^Snapshot,
	arena:               ^Frame_Arena,
	allocator:           mem.Allocator,
	writes:              [dynamic]Relation_Writes,
	buffer_writes:       [dynamic]Buffer_Writes,
	// Catalogue entries this transaction stages for creation. They become
	// visible only at publication, together with the facts and buffer content
	// written against them.
	catalog_changes:     [dynamic]Staged_Catalog_Change,
	// Set when a staged entry cannot be published, for example because a
	// concurrent transaction claimed the same name.
	catalog_conflict:    bool,
	rule_additions:      [dynamic]Rule_Definition,
	source_install:      bool,
	identity_names:      map[v.Symbol]v.Value,
	// Set when a buffer change could not be reconciled: overlapping edits, a
	// compaction boundary, or the rebase budget exhausted.
	buffer_conflict:     bool,
	buffer_rebase_usage: buf.Budget_Usage,
	derived:             []Derived_Relation,
	derived_valid:       bool,
	read_only:           bool,
}

// What a staged catalogue change does.
Staged_Change_Kind :: enum {
	Create,
	Kill,
}

// A catalogue change staged by a transaction.
Staged_Catalog_Change :: struct {
	kind:     Staged_Change_Kind,
	metadata: Relation_Metadata,
}

// Creates a transaction over the kernel's current snapshot. The transaction
// takes a reset staging arena from the kernel pool.
transaction_begin :: proc(kernel: ^Kernel) -> Transaction {
	arena := kernel_take_arena(kernel)
	base := kernel_snapshot(kernel)
	return Transaction {
		kernel = kernel,
		base = base,
		arena = arena,
		allocator = frame_arena_allocator(arena),
		read_only = false,
	}
}

// Releases transaction resources. Safe to call after commit.
transaction_destroy :: proc(transaction: ^Transaction) {
	delete(transaction.identity_names)
	transaction.identity_names = nil
	for &writes in transaction.writes {
		delete(writes.entries)
		delete(writes.buckets)
		delete(writes.next_in_bucket)
		delete(writes.key_buckets)
		delete(writes.next_key)
	}
	delete(transaction.writes)
	transaction.writes = nil

	// A client waiting on a tagged apply must learn that it never published.
	transaction_record_abandoned_applies(transaction)
	for &buffer_writes in transaction.buffer_writes {
		delete(buffer_writes.edits)
		// The staged private root and the retained base block are owned by the
		// write set, whether or not the transaction published.
		transaction_release_buffer_writes(transaction, &buffer_writes)
	}
	delete(transaction.buffer_writes)
	transaction.buffer_writes = nil
	delete(transaction.rule_additions)
	transaction.rule_additions = nil
	delete(transaction.catalog_changes)
	transaction.catalog_changes = nil

	if transaction.arena != nil {
		kernel_return_arena(transaction.kernel, transaction.arena)
		transaction.arena = nil
	}
	snapshot_release(transaction.base)
	transaction.base = nil
}

// Returns the base version of the transaction.
transaction_base_version :: proc(transaction: ^Transaction) -> u64 {
	return transaction.base.version
}

// Resolves a relation's metadata, consulting staged creations first so a
// transaction can use an entry it just staged.
transaction_relation_metadata :: proc(
	transaction: ^Transaction,
	relation: Relation_ID,
) -> (
	Relation_Metadata,
	bool,
) {
	// A kill later in the list wins over an earlier creation, so an entry
	// created and killed in one transaction reads as killed.
	metadata: Relation_Metadata
	found := false
	for change in transaction.catalog_changes {
		if change.metadata.id != relation {
			continue
		}
		metadata = change.metadata
		found = true
		if change.kind == .Kill {
			metadata.tombstoned = true
			return metadata, true
		}
	}
	if found {
		return metadata, true
	}
	return snapshot_relation_metadata(transaction.base, relation)
}

// Resolves metadata by name, consulting staged creations first. A transaction
// that already staged `name` must adopt its own entry rather than create a
// second one.
transaction_relation_metadata_named :: proc(
	transaction: ^Transaction,
	name: v.Symbol,
) -> (
	Relation_Metadata,
	bool,
) {
	metadata: Relation_Metadata
	found := false
	for change in transaction.catalog_changes {
		if change.metadata.name != name {
			continue
		}
		metadata = change.metadata
		found = true
		if change.kind == .Kill {
			metadata.tombstoned = true
			return metadata, true
		}
	}
	if found {
		return metadata, true
	}
	return snapshot_relation_metadata_named(transaction.base, name)
}

// Returns true when the transaction staged `relation` for creation.
transaction_has_staged_relation :: proc(transaction: ^Transaction, relation: Relation_ID) -> bool {
	for change in transaction.catalog_changes {
		if change.metadata.id == relation {
			return true
		}
	}
	return false
}

// Stages a new catalogue entry.
//
// The creating transaction can use the entry immediately: its metadata is
// resolved from the staged list, its facts stage normally, and a staged buffer
// can be edited. Nothing is visible to other transactions until publication.
// An id of 0 asks the kernel to reserve one. A duplicate name, against either
// the base catalogue or another staged entry, is rejected here; a duplicate
// that appears concurrently is detected at commit and reported as a conflict.
transaction_create_relation :: proc(
	transaction: ^Transaction,
	metadata: Relation_Metadata,
) -> (
	Relation_ID,
	Kernel_Error,
) {
	if transaction.read_only {return 0, .Read_Only}

	if err := validate_relation_metadata(metadata); err != .None {
		return 0, err
	}

	id := metadata.id
	if id == 0 {
		id = kernel_reserve_relation_id(transaction.kernel)
	}

	if _, exists := snapshot_relation_metadata_named(transaction.base, metadata.name); exists {
		return 0, .Duplicate_Relation_Name
	}
	for change in transaction.catalog_changes {
		if change.metadata.name == metadata.name {
			return 0, .Duplicate_Relation_Name
		}
		if change.metadata.id == id {
			return 0, .Invalid_Metadata
		}
	}
	if snapshot_has_relation(transaction.base, id) {
		return 0, .Invalid_Metadata
	}

	staged := metadata_clone(transaction.allocator, metadata)
	staged.id = id
	append(&transaction.catalog_changes, Staged_Catalog_Change{kind = .Create, metadata = staged})
	transaction.derived_valid = false
	return id, .None
}

// Stages a kill: the entry is tombstoned and its content released at
// publication. The id and name are not reused.
transaction_kill_relation :: proc(
	transaction: ^Transaction,
	relation: Relation_ID,
) -> Kernel_Error {
	metadata, known := transaction_relation_metadata(transaction, relation)
	if !known {
		return .Unknown_Relation
	}
	if metadata.tombstoned {
		return .None
	}

	append(
		&transaction.catalog_changes,
		Staged_Catalog_Change {
			kind = .Kill,
			metadata = metadata_clone(transaction.allocator, metadata),
		},
	)
	return .None
}

// Releases the references a staged buffer write holds.
@(private)
transaction_release_buffer_writes :: proc(transaction: ^Transaction, writes: ^Buffer_Writes) {
	if writes.private_root != nil {
		buf.tree_release(&transaction.kernel.buffer_store, writes.private_root)
		writes.private_root = nil
	}
	if writes.base_block != nil {
		buffer_block_release(writes.base_block)
		writes.base_block = nil
	}
}

@(private)
transaction_relation_writes :: proc(
	transaction: ^Transaction,
	relation: Relation_ID,
	create: bool,
) -> (
	^Relation_Writes,
	bool,
) {
	for &writes in transaction.writes {
		if writes.relation == relation {
			return &writes, true
		}
	}
	if !create {
		return nil, false
	}
	writes := Relation_Writes {
		relation = relation,
	}
	if metadata, ok := transaction_relation_metadata(transaction, relation);
	   ok && metadata.conflict.kind == .Functional {
		writes.functional = true
		writes.key_positions = metadata.conflict.key_positions
	}
	append(&transaction.writes, writes)
	return &transaction.writes[len(transaction.writes) - 1], true
}

// Finds the staged entry equal to `tuple` under a known `hash`, or -1. Walks
// only the bucket chain for the hash, not every prior entry.
@(private)
transaction_find_write :: proc(writes: ^Relation_Writes, tuple: v.Tuple, hash: u64) -> int {
	entry, found := writes.buckets[hash]
	if !found {
		return -1
	}
	for entry != NO_ENTRY {
		index := int(entry)
		if v.tuple_eq(writes.entries[index].tuple, tuple) {
			return index
		}
		entry = writes.next_in_bucket[index]
	}
	return -1
}

// Mixes one value into a key hash. Local to the kernel: equality consistency
// comes from `value_hash`, the mixing only needs to spread hashes.
@(private)
key_hash_mix :: proc(hash, value: u64) -> u64 {
	mixed := (hash ~ value) * 0xbf58_476d_1ce4_e5b9
	return mixed ~ (mixed >> 27)
}

@(private)
key_values_hash :: proc(key_values: []v.Value) -> u64 {
	hash := u64(0x9e37_79b9_7f4a_7c15)
	for value in key_values {
		hash = key_hash_mix(hash, v.value_hash(value))
	}
	return hash
}

@(private)
tuple_key_hash :: proc(tuple: v.Tuple, positions: []u16) -> u64 {
	values := v.tuple_values(tuple)
	hash := u64(0x9e37_79b9_7f4a_7c15)
	for position in positions {
		hash = key_hash_mix(hash, v.value_hash(values[int(position)]))
	}
	return hash
}

@(private)
same_positions :: proc(a, b: []u16) -> bool {
	if len(a) != len(b) {
		return false
	}
	for position, i in a {
		if position != b[i] {
			return false
		}
	}
	return true
}

@(private)
tuple_matches_key_values :: proc(tuple: v.Tuple, positions: []u16, key_values: []v.Value) -> bool {
	values := v.tuple_values(tuple)
	for key, i in key_values {
		if !v.value_eq(values[int(positions[i])], key) {
			return false
		}
	}
	return true
}

// Finds a staged assert whose projected key equals `key_values`, or -1. Walks
// only the key bucket chain for the hash.
@(private)
transaction_find_staged_assert_by_key :: proc(
	writes: ^Relation_Writes,
	key_values: []v.Value,
) -> int {
	entry, found := writes.key_buckets[key_values_hash(key_values)]
	if !found {
		return -1
	}
	for entry != NO_ENTRY {
		index := int(entry)
		if writes.entries[index].kind == .Assert &&
		   tuple_matches_key_values(
			   writes.entries[index].tuple,
			   writes.key_positions,
			   key_values,
		   ) {
			return index
		}
		entry = writes.next_key[index]
	}
	return -1
}

@(private)
transaction_record_write :: proc(
	transaction: ^Transaction,
	relation: Relation_ID,
	tuple: v.Tuple,
	kind: Write_Kind,
) {
	if relation == SYSTEM_NAMED_IDENTITY_ID {clear(&transaction.identity_names)}
	writes, _ := transaction_relation_writes(transaction, relation, true)
	hash := v.tuple_hash(tuple)
	if index := transaction_find_write(writes, tuple, hash); index >= 0 {
		writes.entries[index].kind = kind
		return
	}
	index := u32(len(writes.entries))
	previous, found := writes.buckets[hash]
	if !found {
		previous = NO_ENTRY
	}
	append(&writes.entries, Pending_Write{tuple = tuple, kind = kind})
	append(&writes.next_in_bucket, previous)
	writes.buckets[hash] = index

	if writes.functional {
		key_hash := tuple_key_hash(tuple, writes.key_positions)
		previous_key, key_found := writes.key_buckets[key_hash]
		if !key_found {
			previous_key = NO_ENTRY
		}
		append(&writes.next_key, previous_key)
		writes.key_buckets[key_hash] = index
	}
}

@(private)
tuple_key_values :: proc(tuple: v.Tuple, positions: []u16, alloc: mem.Allocator) -> []v.Value {
	values := make([]v.Value, len(positions), alloc)
	for position, i in positions {
		values[i] = v.tuple_values(tuple)[int(position)]
	}
	return values
}

// Returns the effective staged change for a tuple, if any.
transaction_effective_write :: proc(
	transaction: ^Transaction,
	relation: Relation_ID,
	tuple: v.Tuple,
) -> (
	Write_Kind,
	bool,
) {
	writes, ok := transaction_relation_writes(transaction, relation, false)
	if !ok {
		return .Assert, false
	}
	if index := transaction_find_write(writes, tuple, v.tuple_hash(tuple)); index >= 0 {
		return writes.entries[index].kind, true
	}
	return .Assert, false
}

// Stages an assertion. Fails for unknown relations, arity mismatches,
// non-persistable values, and functional-key violations against the visible
// transaction state.
transaction_assert :: proc(
	transaction: ^Transaction,
	relation: Relation_ID,
	tuple: v.Tuple,
) -> Kernel_Error {
	if transaction.read_only {
		return .Read_Only
	}
	if kernel_relation_is_computed(transaction.kernel, relation) {
		return .Read_Only
	}
	metadata, ok := transaction_relation_metadata(transaction, relation)
	if !ok {
		return .Unknown_Relation
	}
	if int(metadata.arity) != v.tuple_arity(tuple) {
		return .Arity_Mismatch
	}
	for cell in v.tuple_values(tuple) {
		if !v.value_is_storable(cell) {
			return .Non_Persistent_Value
		}
	}

	owned := v.tuple_deep_copy(transaction.allocator, tuple)
	if metadata.conflict.kind == .Functional {
		key_values := tuple_key_values(
			owned,
			metadata.conflict.key_positions,
			context.temp_allocator,
		)
		existing, found := transaction_tuple_for_key(
			transaction,
			relation,
			metadata.conflict.key_positions,
			key_values,
		)
		if found && !v.tuple_eq(existing, owned) {
			return .Functional_Key_Violation
		}
	}

	transaction_record_write(transaction, relation, owned, .Assert)
	transaction.derived_valid = false
	return .None
}

// Stages a retraction. Fails for unknown relations, arity mismatches, and
// non-persistable values.
transaction_retract :: proc(
	transaction: ^Transaction,
	relation: Relation_ID,
	tuple: v.Tuple,
) -> Kernel_Error {
	if transaction.read_only {
		return .Read_Only
	}
	if kernel_relation_is_computed(transaction.kernel, relation) {
		return .Read_Only
	}
	metadata, ok := transaction_relation_metadata(transaction, relation)
	if !ok {
		return .Unknown_Relation
	}
	if int(metadata.arity) != v.tuple_arity(tuple) {
		return .Arity_Mismatch
	}
	for cell in v.tuple_values(tuple) {
		if !v.value_is_storable(cell) {
			return .Non_Persistent_Value
		}
	}

	owned := v.tuple_deep_copy(transaction.allocator, tuple)
	transaction_record_write(transaction, relation, owned, .Retract)
	transaction.derived_valid = false
	return .None
}

// Visits transaction-visible extensional tuples matching a partial binding.
// The visitor returns false to stop.
transaction_visit_extensional :: proc(
	transaction: ^Transaction,
	relation: Relation_ID,
	bindings: []v.Binding,
	visit: proc(user: rawptr, row: v.Tuple) -> bool,
	user: rawptr,
) {
	if block, ok := snapshot_relation_block(transaction.base, relation); ok {
		ctx := Transaction_Base_Scan {
			transaction = transaction,
			relation    = relation,
			visit       = visit,
			user        = user,
		}
		relation_block_visit(block, bindings, transaction_base_visit, &ctx)
		if ctx.stopped {
			return
		}
	}

	writes, has_writes := transaction_relation_writes(transaction, relation, false)
	if !has_writes {
		return
	}
	for entry in writes.entries {
		if entry.kind != .Assert {
			continue
		}
		if snapshot_contains_extensional(transaction.base, relation, entry.tuple) {
			continue
		}
		if !v.tuple_matches_bindings(entry.tuple, bindings) {
			continue
		}
		if !visit(user, entry.tuple) {
			return
		}
	}
}

@(private)
Transaction_Base_Scan :: struct {
	transaction: ^Transaction,
	relation:    Relation_ID,
	visit:       proc(user: rawptr, row: v.Tuple) -> bool,
	user:        rawptr,
	stopped:     bool,
}

@(private)
transaction_base_visit :: proc(user: rawptr, row: v.Tuple) -> bool {
	ctx := (^Transaction_Base_Scan)(user)
	if kind, ok := transaction_effective_write(ctx.transaction, ctx.relation, row); ok {
		if kind == .Retract {
			return true
		}
	}
	if !ctx.visit(ctx.user, row) {
		ctx.stopped = true
		return false
	}
	return true
}

// Appends transaction-visible extensional tuples matching a partial binding.
transaction_scan_extensional_into :: proc(
	transaction: ^Transaction,
	relation: Relation_ID,
	bindings: []v.Binding,
	out: ^[dynamic]v.Tuple,
) {
	transaction_visit_extensional(
		transaction,
		relation,
		bindings,
		proc(user: rawptr, row: v.Tuple) -> bool {
			append((^[dynamic]v.Tuple)(user), row)
			return true
		},
		out,
	)
}

// Returns the tuple visible for an exact projected key in the transaction.
transaction_tuple_for_key :: proc(
	transaction: ^Transaction,
	relation: Relation_ID,
	positions: []u16,
	key_values: []v.Value,
) -> (
	v.Tuple,
	bool,
) {
	metadata, ok := transaction_relation_metadata(transaction, relation)
	if !ok {
		return nil, false
	}
	if len(key_values) != len(positions) {
		return nil, false
	}

	// Functional relations keep a staged key index, so the visibility check
	// does not walk every prior staged entry. A staged assert shadows the
	// base tuple; a base tuple hidden by a staged retract is not visible.
	if writes, has_writes := transaction_relation_writes(transaction, relation, false);
	   has_writes && writes.functional && same_positions(writes.key_positions, positions) {
		if index := transaction_find_staged_assert_by_key(writes, key_values); index >= 0 {
			return writes.entries[index].tuple, true
		}
		base_tuple, base_ok := snapshot_tuple_for_key(
			transaction.base,
			relation,
			positions,
			key_values,
		)
		if !base_ok {
			return nil, false
		}
		if kind, found := transaction_effective_write(transaction, relation, base_tuple);
		   found && kind == .Retract {
			return nil, false
		}
		return base_tuple, true
	}

	scan_bindings := make([]v.Binding, metadata.arity, context.temp_allocator)
	for position, i in positions {
		scan_bindings[int(position)] = v.binding_of(key_values[i])
	}

	found: v.Tuple
	transaction_visit_extensional(
		transaction,
		relation,
		scan_bindings,
		proc(user: rawptr, row: v.Tuple) -> bool {
			(^v.Tuple)(user)^ = row
			return false
		},
		&found,
	)
	return found, found != nil
}

// Returns transaction-stored derived rows for a relation.
transaction_derived_rows :: proc(transaction: ^Transaction, relation: Relation_ID) -> []v.Tuple {
	for derived in transaction.derived {
		if derived.relation == relation {
			return derived.tuples
		}
	}
	return nil
}

// Recomputes derived facts visible in the transaction, if stale. Evaluation
// runs in a short-lived arena; surviving tuples are deep-copied into the
// transaction arena.
transaction_evaluate_derived :: proc(transaction: ^Transaction) -> Kernel_Error {
	if transaction.derived_valid {
		return .None
	}

	// A transaction that has staged no writes sees exactly its base snapshot's
	// state, and that snapshot's derived rows were materialized when it was
	// published. Reference them instead of re-running the fixpoint: read-only
	// transactions are the common case (every task begins one), and recomputing
	// made each read of a derived relation cost a full closure evaluation.
	if len(transaction.writes) == 0 &&
	   len(transaction.buffer_writes) == 0 &&
	   len(transaction.catalog_changes) == 0 &&
	   len(transaction.rule_additions) == 0 {
		transaction.derived = transaction.base.derived
		transaction.derived_valid = true
		return .None
	}

	arena := new(virtual.Arena)
	if err := virtual.arena_init_growing(arena); err != nil {
		panic("failed to initialize rule evaluation arena")
	}
	defer {
		virtual.arena_destroy(arena)
		free(arena)
	}
	alloc := virtual.arena_allocator(arena)

	result := rules_derived_create_backed(alloc, runtime.heap_allocator())
	defer rules_derived_destroy(&result)
	source := Relation_Source {
		transaction = transaction,
		derived     = &result,
	}
	definitions := make([dynamic]Rule_Definition, alloc)
	append(&definitions, ..transaction.base.rules)
	append(&definitions, ..transaction.rule_additions[:])
	if err := rules_evaluate_source(alloc, definitions[:], &source, &result); err != .None {
		return err
	}

	transaction.derived = derived_relations_from(transaction.allocator, &result, arena)
	transaction.derived_valid = true
	return .None
}

// Validates a transaction's writes against a newer published snapshot.
@(private)
transaction_validate_conflicts :: proc(
	transaction: ^Transaction,
	current: ^Snapshot,
) -> Kernel_Error {
	if transaction.source_install {
		for relation in ([]Relation_ID{DISPATCH_METHOD_SELECTOR_ID, DISPATCH_METHOD_PROGRAM_ID, DISPATCH_PARAM_ID}) {
			before, _ := snapshot_relation_block(transaction.base, relation)
			now, _ := snapshot_relation_block(current, relation)
			if before != now {return .Conflict}
		}
	}
	if err := transaction_buffer_validate(transaction, current); err != .None {
		return err
	}

	for &writes in transaction.writes {
		metadata, ok := snapshot_relation_metadata(transaction.base, writes.relation)
		if !ok {
			continue
		}
		// Older stores described NamedIdentity as a set. Enforce name
		// uniqueness during rebase for those snapshots too.
		if writes.relation == SYSTEM_NAMED_IDENTITY_ID {
			metadata.conflict = conflict_functional([]u16{1})
		}
		switch metadata.conflict.kind {
		case .Event_Append:
			continue
		case .Reject, .Span, .Whole:
			// Buffer conflict is validated separately, against block
			// revisions; buffer writes never appear in `writes`.
			continue
		case .Set:
			for entry in writes.entries {
				if entry.kind != .Assert {
					continue
				}
				base_has := snapshot_contains_extensional(
					transaction.base,
					writes.relation,
					entry.tuple,
				)
				current_has := snapshot_contains_extensional(current, writes.relation, entry.tuple)
				if base_has && !current_has {
					return .Conflict
				}
			}
		case .Functional:
			keys: [dynamic][]v.Value
			defer delete(keys)
			for entry in writes.entries {
				key := make(
					[]v.Value,
					len(metadata.conflict.key_positions),
					context.temp_allocator,
				)
				for position, i in metadata.conflict.key_positions {
					key[i] = v.tuple_values(entry.tuple)[int(position)]
				}
				duplicate := false
				for existing in keys {
					if key_values_equal(existing, key) {
						duplicate = true
						break
					}
				}
				if !duplicate {
					append(&keys, key)
				}
			}

			for key in keys {
				base_tuple, base_ok := snapshot_tuple_for_key(
					transaction.base,
					writes.relation,
					metadata.conflict.key_positions,
					key,
				)
				current_tuple, current_ok := snapshot_tuple_for_key(
					current,
					writes.relation,
					metadata.conflict.key_positions,
					key,
				)
				if !optional_tuple_eq(base_tuple, base_ok, current_tuple, current_ok) {
					return .Conflict
				}
			}
		}
	}
	return .None
}

@(private)
key_values_equal :: proc(a, b: []v.Value) -> bool {
	if len(a) != len(b) {
		return false
	}
	for value, i in a {
		if !v.value_eq(value, b[i]) {
			return false
		}
	}
	return true
}

@(private)
optional_tuple_eq :: proc(a: v.Tuple, a_ok: bool, b: v.Tuple, b_ok: bool) -> bool {
	if a_ok != b_ok {
		return false
	}
	if !a_ok {
		return true
	}
	return v.tuple_eq(a, b)
}

// Commits the transaction, publishing a new snapshot. On success the returned
// snapshot is caller-owned. The transaction must be destroyed by the caller.
//
// A task owns one thread and one transaction. Commits to the same relation are
// Bounded rebuild-and-retry attempts when a publication fails under
// contention.
TRANSACTION_RETRY_LIMIT :: 8

// serialised by striped relation locks so a candidate is prepared against a
// stable relation block; commits to different relations proceed concurrently.
// Publication happens in groups: whichever task thread arrives first drains
// the queued candidates and merges them into one snapshot, so independent
// tasks do not invalidate one another's prepared work.
transaction_commit :: proc(transaction: ^Transaction) -> (^Snapshot, Kernel_Error) {
	kernel := transaction.kernel

	// A transaction that made no writes has nothing to publish. Forking would
	// advance the snapshot version, which makes read-only CLI `--eval` queries
	// grow the store on the shutdown checkpoint.
	if len(transaction.writes) == 0 &&
	   len(transaction.buffer_writes) == 0 &&
	   len(transaction.catalog_changes) == 0 &&
	   len(transaction.rule_additions) == 0 {
		return kernel_snapshot(kernel), .None
	}

	// Reserve durable capacity before the commit can publish. A store at its
	// budget blocks here, and a timeout fails the transaction without
	// publishing, so visible state never runs unboundedly ahead of the store.
	persist_ticket: Persist_Ticket
	persist_bytes := kernel_persist_bytes(transaction)
	if persist_bytes > 0 {
		admitted: bool
		persist_ticket, admitted = kernel_admit_persist(kernel, persist_bytes)
		if !admitted {
			return nil, .Overloaded
		}
	}

	write_stripes := transaction_write_stripes(transaction)
	for present, stripe in write_stripes {
		if present {
			sync.mutex_lock(&kernel.relation_locks[stripe])
		}
	}
	defer {
		for present, stripe in write_stripes {
			if present {
				sync.mutex_unlock(&kernel.relation_locks[stripe])
			}
		}
	}

	// A publication can fail after the committer's own rebase attempts are
	// exhausted. Rebuild the candidate against the newest snapshot and retry a
	// bounded number of times before reporting a conflict to the task.
	published: ^Snapshot
	for attempt in 0 ..< TRANSACTION_RETRY_LIMIT {
		current := kernel_snapshot(kernel)
		if current.version != transaction.base.version {
			if err := transaction_validate_conflicts(transaction, current); err != .None {
				snapshot_release(current)
				kernel_release_persist(kernel, persist_ticket)
				return nil, err
			}
		}

		transaction_prepare_writes(transaction)
		candidate := transaction_build_candidate(kernel, transaction, current)
		if transaction.catalog_conflict || transaction.buffer_conflict {
			snapshot_release(candidate)
			snapshot_release(current)
			kernel_release_persist(kernel, persist_ticket)
			return nil, .Conflict
		}

		// The entry owns its own reference to the base so the committer can
		// replace it while rebasing; the task keeps its `current` reference.
		snapshot_retain(current)
		entry := Commit_Entry {
			transaction = transaction,
			ticket      = persist_ticket,
			base        = current,
			candidate   = candidate,
		}
		if kernel_commit_enqueue(kernel, &entry) {
			kernel_committer_drain(kernel)
		} else {
			kernel_commit_wait(kernel, &entry)
		}

		snapshot_release(current)
		if entry.published != nil {
			published = entry.published
			break
		}
	}
	if published == nil {
		kernel_release_persist(kernel, persist_ticket)
		return nil, .Conflict
	}

	// Announce staged creations to subscribers once they are durable-visible.
	if len(transaction.catalog_changes) > 0 {
		changes := make([]Catalog_Change, len(transaction.catalog_changes), context.temp_allocator)
		for change, index in transaction.catalog_changes {
			changes[index] = Catalog_Change {
				kind     = .Relation_Created,
				relation = change.metadata.id,
				name     = change.metadata.name,
			}
		}
		changes_record_catalog(&kernel.changes, published.version, changes)
	}
	return published, .None
}

// Returns the lock stripes for the transaction's writes as a stack bitset.
@(private)
transaction_write_stripes :: proc(transaction: ^Transaction) -> [RELATION_LOCK_STRIPES]bool {
	stripes: [RELATION_LOCK_STRIPES]bool
	if len(transaction.rule_additions) >
	   0 {stripes[int(SYSTEM_RULE_ID) % RELATION_LOCK_STRIPES] = true}
	for writes in transaction.writes {
		stripes[int(writes.relation) % RELATION_LOCK_STRIPES] = true
	}
	for writes in transaction.buffer_writes {
		stripes[int(writes.relation) % RELATION_LOCK_STRIPES] = true
	}
	return stripes
}

// Builds an unpublished candidate snapshot from `current`. The caller owns the
// returned reference.
@(private)
transaction_build_candidate :: proc(
	kernel: ^Kernel,
	transaction: ^Transaction,
	current: ^Snapshot,
) -> ^Snapshot {
	fork := snapshot_create(kernel, current.version + 1, current)

	fork.catalog = make([]Relation_Metadata, len(current.catalog), fork.allocator)
	copy(fork.catalog, current.catalog)
	fork.blocks = make([]^Relation_Block, len(current.blocks), fork.allocator)
	for block, index in current.blocks {
		relation_block_retain(block)
		fork.blocks[index] = block
	}
	fork.buffers = make([]^Buffer_Block, len(current.buffers), fork.allocator)
	for block, index in current.buffers {
		buffer_block_retain(block)
		fork.buffers[index] = block
	}
	fork.rules = make([]Rule_Definition, len(current.rules), fork.allocator)
	copy(fork.rules, current.rules)

	// Apply staged catalogue creations before any write is materialized, so a
	// relation created and written in the same transaction is built against the
	// candidate's own catalogue.
	transaction.catalog_conflict = false
	transaction.buffer_conflict = false
	for change in transaction.catalog_changes {
		switch change.kind {
		case .Create:
			if _, exists := snapshot_relation_metadata_named(current, change.metadata.name);
			   exists {
				transaction.catalog_conflict = true
				return fork
			}
			if snapshot_has_relation(current, change.metadata.id) {
				transaction.catalog_conflict = true
				return fork
			}
			// Later snapshots shallow-copy catalogue metadata. Its nested slices
			// must outlive this candidate and the transaction staging arena.
			sync.mutex_lock(&kernel.catalog_lock)
			owned_metadata := metadata_clone(kernel.world_allocator, change.metadata)
			sync.mutex_unlock(&kernel.catalog_lock)
			snapshot_add_relation(fork, owned_metadata)
		case .Kill:
			// Tombstone the entry in the candidate and release its content.
			for &metadata in fork.catalog {
				if metadata.id != change.metadata.id {
					continue
				}
				metadata.tombstoned = true
				if metadata.storage == .Buffer {
					block := buffer_block_create(&kernel.buffer_store, metadata.id, nil, 0, 0)
					snapshot_set_buffer(fork, block)
				}
				break
			}
		}
	}

	for definition in transaction.rule_additions {
		sync.mutex_lock(&kernel.catalog_lock)
		owned := rule_definition_clone(kernel.world_allocator, definition)
		sync.mutex_unlock(&kernel.catalog_lock)
		snapshot_add_rule(fork, owned)
	}
	if len(transaction.rule_additions) > 0 {
		active := snapshot_active_rules(fork, context.temp_allocator)
		if _, ok := rules_stratify(active, context.temp_allocator);
		   !ok {transaction.catalog_conflict = true; return fork}
	}

	for &writes in transaction.writes {
		metadata, ok := snapshot_relation_metadata(fork, writes.relation)
		if !ok {
			continue
		}

		// Copy-on-write against the block in the snapshot we are committing
		// onto, so a rebase merges with the other transaction's changes.
		current_block, _ := snapshot_relation_block(current, writes.relation)
		block := relation_block_apply(kernel, current_block, metadata, writes.entries[:])
		snapshot_set_block(fork, block)
	}

	transaction_buffer_materialize(transaction, current, fork)

	kernel_compute_derived(kernel, fork)
	return fork
}

// Adopts the winner's state into an existing candidate in place: blocks the
// winner replaced for relations this transaction did not write are swapped in,
// catalog and rules are refreshed, and derived facts are recomputed. Returns
// false when the candidate's shape no longer matches the winner (for example a
// concurrent relation creation), in which case the caller rebuilds.
@(private)
transaction_rebase_in_place :: proc(
	kernel: ^Kernel,
	transaction: ^Transaction,
	candidate: ^Snapshot,
	winner: ^Snapshot,
) -> bool {
	if len(candidate.catalog) != len(winner.catalog) ||
	   len(candidate.rules) != len(winner.rules) ||
	   len(candidate.blocks) != len(winner.blocks) {
		return false
	}
	if !transaction_buffer_adopt(transaction, candidate, winner) {
		return false
	}

	for block, index in candidate.blocks {
		winner_block := winner.blocks[index]
		if winner_block.metadata.id != block.metadata.id {
			// The two snapshots materialized different relation blocks, so
			// positions are not comparable. Rebuild from the winner instead.
			return false
		}
		if winner_block == block {
			continue
		}
		if transaction_writes_relation(transaction, block.metadata.id) {
			// Our prepared block is authoritative for a relation whose stripe
			// we hold; the winner cannot have changed it.
			continue
		}
		relation_block_retain(winner_block)
		candidate.blocks[index] = winner_block
		relation_block_release(block)
	}

	copy(candidate.catalog, winner.catalog)
	copy(candidate.rules, winner.rules)
	candidate.version = winner.version + 1
	candidate.parent = winner
	kernel_compute_derived(kernel, candidate)
	return true
}

// Rebuilds the per-relation bucket chains from `entries`. Called after
// `transaction_prepare_writes` compacts and sorts them, since the chains store
// entry indices.
@(private)
transaction_reindex_writes :: proc(writes: ^Relation_Writes) {
	clear(&writes.buckets)
	resize(&writes.next_in_bucket, len(writes.entries))
	if writes.functional {
		clear(&writes.key_buckets)
		resize(&writes.next_key, len(writes.entries))
	}
	for &entry, index in writes.entries {
		hash := v.tuple_hash(entry.tuple)
		previous, found := writes.buckets[hash]
		if !found {
			previous = NO_ENTRY
		}
		writes.next_in_bucket[index] = previous
		writes.buckets[hash] = u32(index)

		if writes.functional {
			key_hash := tuple_key_hash(entry.tuple, writes.key_positions)
			previous_key, key_found := writes.key_buckets[key_hash]
			if !key_found {
				previous_key = NO_ENTRY
			}
			writes.next_key[index] = previous_key
			writes.key_buckets[key_hash] = u32(index)
		}
	}
}

// Filters and sorts staged writes once, before candidate construction. A
// rebased retract only removes tuples the transaction's base actually held; a
// concurrent assert of a tuple the base lacked survives. Asserts always apply.
@(private)
transaction_prepare_writes :: proc(transaction: ^Transaction) {
	for &writes in transaction.writes {
		base_block, _ := snapshot_relation_block(transaction.base, writes.relation)
		write := 0
		for entry in writes.entries {
			if entry.kind == .Retract &&
			   (base_block == nil || !relation_block_contains(base_block, entry.tuple)) {
				continue
			}
			writes.entries[write] = entry
			write += 1
		}
		if write != len(writes.entries) {
			resize(&writes.entries, write)
		}
		if len(writes.entries) > 1 {
			slice.sort_by(writes.entries[:], proc(a, b: Pending_Write) -> bool {
				return v.tuple_cmp(a.tuple, b.tuple) == .Less
			})
		}
		transaction_reindex_writes(&writes)
	}
}

transaction_writes_relation :: proc(transaction: ^Transaction, relation: Relation_ID) -> bool {
	for writes in transaction.writes {
		if writes.relation == relation {
			return true
		}
	}
	return false
}

@(private)
remove_tuple :: proc(rows: ^[dynamic]v.Tuple, tuple: v.Tuple) {
	for row, i in rows {
		if v.tuple_eq(row, tuple) {
			ordered_remove(rows, i)
			return
		}
	}
}

@(private)
ordered_remove :: proc(rows: ^[dynamic]v.Tuple, index: int) {
	for i in index ..< len(rows) - 1 {
		rows[i] = rows[i + 1]
	}
	pop(rows)
}
