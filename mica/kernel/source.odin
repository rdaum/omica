// Read sources for rules and dispatch.
//
// A `Relation_Source` layers the visible extensional tuples of a snapshot or
// transaction with derived facts. During rule evaluation the derived layer is
// the in-progress accumulator; for ordinary reads it is the stored derived set
// of the snapshot or transaction.
package kernel

import "core:mem"
import v "../var"

// A source of relation tuples for rule evaluation and dispatch matching.
//
// When `delta_active` is true, reads of `delta_relation` come from `delta`
// plus extensional facts only. This serves semi-naive rule evaluation, where
// one body atom reads the facts derived in the previous round.
Relation_Source :: struct {
	// Registry owner for snapshot-only reads. Transaction sources obtain the
	// same pointer from the transaction itself.
	kernel:              ^Kernel,
	// Nil means root authority. Computed scanners inherit this authority when
	// they read their backing relations.
	authority:           ^Authority,
	snapshot:           ^Snapshot,
	transaction:        ^Transaction,
	derived:            ^Rule_Derived,
	use_stored_derived: bool,
	delta:              ^Rule_Derived,
	delta_relation:     Relation_ID,
	delta_active:       bool,
	// Per-evaluation packed keys for negated membership (and later joins).
	// Set by rules_evaluate_source for the duration of one evaluation; nil
	// elsewhere, where operators use the row path.
	packed:             ^Packed_Cache,
	// Set when a computed scan cannot execute, for example because a required
	// access key was unbound. Callers translate it to their query error.
	error:              Kernel_Error,
}

relation_source_kernel :: proc(source: ^Relation_Source) -> ^Kernel {
	if source == nil {
		return nil
	}
	if source.transaction != nil {
		return source.transaction.kernel
	}
	return source.kernel
}

@(private)
Visit_State :: struct {
	visit:   proc(user: rawptr, row: v.Tuple) -> bool,
	user:    rawptr,
	stopped: bool,
}

@(private)
visit_state_trampoline :: proc(user: rawptr, row: v.Tuple) -> bool {
	state := (^Visit_State)(user)
	if !state.visit(state.user, row) {
		state.stopped = true
		return false
	}
	return true
}

// Visits tuples from a source matching a partial binding. Returns true when
// the visitor stopped the scan.
relation_source_visit :: proc(
	source: ^Relation_Source,
	relation: Relation_ID,
	bindings: []v.Binding,
	visit: proc(user: rawptr, row: v.Tuple) -> bool,
	user: rawptr,
) -> bool {
	if !authority_can_read(source.authority, relation) {
		source.error = .Permission_Denied
		return false
	}
	state := Visit_State {
		visit = visit,
		user  = user,
	}
	if computed, computed_error := computed_relation_visit(
		source,
		relation,
		bindings,
		visit_state_trampoline,
		&state,
	); computed {
		if computed_error != .None {
			source.error = computed_error
		}
		return state.stopped
	}

	if source.snapshot != nil {
		snapshot_visit_extensional(
			source.snapshot,
			relation,
			bindings,
			visit_state_trampoline,
			&state,
		)
	} else if source.transaction != nil {
		transaction_visit_extensional(
			source.transaction,
			relation,
			bindings,
			visit_state_trampoline,
			&state,
		)
	}
	if state.stopped {
		return true
	}

	// Stored derived rows are evaluated lazily per transaction, so reads see
	// both committed rules and this transaction's writes.
	if source.use_stored_derived && source.transaction != nil {
		_ = transaction_evaluate_derived(source.transaction)
	}

	delta_active := source.delta_active && source.delta != nil && relation == source.delta_relation
	if delta_active {
		if rules_derived_visit(source.delta, relation, bindings, visit, user) {
			return true
		}
		return false
	}

	if source.derived != nil {
		if rules_derived_visit(source.derived, relation, bindings, visit, user) {
			return true
		}
	}

	if source.use_stored_derived {
		if source.snapshot != nil {
			if block, ok := snapshot_derived_block(source.snapshot, relation); ok {
				stored := Visit_State{visit = visit, user = user}
				relation_block_visit(block, bindings, visit_state_trampoline, &stored)
				if stored.stopped {
					return true
				}
			}
		} else if source.transaction != nil {
			if transaction_visit_derived(source.transaction, relation, bindings, visit, user) {
				return true
			}
		}
	}
	return false
}

// Visits tuples from a source matching a partial binding and appends them to
// `out`.
relation_source_scan_into :: proc(
	source: ^Relation_Source,
	relation: Relation_ID,
	bindings: []v.Binding,
	out: ^[dynamic]v.Tuple,
) {
	relation_source_visit(source, relation, bindings, proc(user: rawptr, row: v.Tuple) -> bool {
			append((^[dynamic]v.Tuple)(user), row)
			return true
		}, out)
}

// Appends the tuples `relation_source_visit` would visit to `sink`, one
// column per position, under the same layering and precedence: the authority
// check first (Permission_Denied), computed relations, extensional rows (the
// snapshot's block or the transaction overlay), lazy derivation for
// transactions, then either the delta alone for a delta-restricted atom or the
// evaluation's derived rows followed by stored derived rows. Derived and delta
// rows are appended from their columns. Errors are also stored in
// `source.error`, as the visit path does.
relation_source_scan_append :: proc(
	source: ^Relation_Source,
	relation: Relation_ID,
	bindings: []v.Binding,
	sink: ^Column_Sink,
) -> Kernel_Error {
	if !authority_can_read(source.authority, relation) {
		source.error = .Permission_Denied
		return .Permission_Denied
	}
	if computed, computed_error := computed_relation_visit(source, relation, bindings, column_sink_visit, sink);
	   computed {
		if computed_error != .None {
			source.error = computed_error
		}
		// A scanner that reads its backing relations through this source
		// reports their failures (a denied read) only in source.error.
		return source.error
	}

	if source.snapshot != nil {
		snapshot_visit_extensional(source.snapshot, relation, bindings, column_sink_visit, sink)
	} else if source.transaction != nil {
		transaction_visit_extensional(source.transaction, relation, bindings, column_sink_visit, sink)
	}

	if source.use_stored_derived && source.transaction != nil {
		_ = transaction_evaluate_derived(source.transaction)
	}

	if source.delta_active && source.delta != nil && relation == source.delta_relation {
		column_sink_append_derived(sink, source.delta, relation, bindings)
		return .None
	}
	if source.derived != nil {
		column_sink_append_derived(sink, source.derived, relation, bindings)
	}
	if source.use_stored_derived {
		if source.snapshot != nil {
			if block, ok := snapshot_derived_block(source.snapshot, relation); ok {
				relation_block_visit(block, bindings, column_sink_visit, sink)
			}
		} else if source.transaction != nil {
			transaction_visit_derived(source.transaction, relation, bindings, column_sink_visit, sink)
		}
	}
	return .None
}

// `relation_source_scan_append` into a fresh sink; the batch has one bound
// column per position. Empty on error.
relation_source_scan_columns :: proc(
	source: ^Relation_Source,
	relation: Relation_ID,
	bindings: []v.Binding,
	alloc: mem.Allocator,
) -> (
	Column_Batch,
	Kernel_Error,
) {
	sink := column_sink_make(len(bindings), alloc)
	if err := relation_source_scan_append(source, relation, bindings, &sink); err != .None {
		return column_batch_make(len(bindings), alloc), err
	}
	return column_sink_batch(&sink), .None
}

// Appends the rows of `entry` matching `bindings` (value_eq on bound
// positions); all rows at once when nothing is bound.
@(private)
column_sink_append_derived :: proc(sink: ^Column_Sink, d: ^Rule_Derived, relation: Relation_ID, bindings: []v.Binding) {
	entry := rules_derived_find(d, relation)
	if entry == nil || len(bindings) != entry.arity {
		return
	}
	rows := rules_derived_visible(d, entry)
	any_bound := false
	for binding in bindings {
		if binding.bound {
			any_bound = true
			break
		}
	}
	if !any_bound {
		for c in 0 ..< entry.arity {
			append(&sink.columns[c], ..entry.columns[c][:rows])
		}
		sink.count += rows
		return
	}
	for r in 0 ..< rows {
		matches := true
		for binding, c in bindings {
			if binding.bound && !v.value_eq(entry.columns[c][r], binding.value) {
				matches = false
				break
			}
		}
		if matches {
			for c in 0 ..< entry.arity {
				append(&sink.columns[c], entry.columns[c][r])
			}
			sink.count += 1
		}
	}
}

// The longest bound prefix the relation's visible block can serve for
// `bindings`, through its primary order or a secondary index, as
// `relation_block_visit` chooses. 0 means a scan.
relation_source_index_prefix :: proc(source: ^Relation_Source, relation: Relation_ID, bindings: []v.Binding) -> int {
	snapshot := source.snapshot
	if snapshot == nil && source.transaction != nil {
		snapshot = source.transaction.base
	}
	if snapshot == nil {
		return 0
	}
	block, ok := snapshot_relation_block(snapshot, relation)
	if !ok {
		return 0
	}
	best := v.binding_leading_bound_count(bindings)
	for spec in block.metadata.indexes {
		if index_is_natural_full_tuple(spec, block.metadata.arity) {
			continue
		}
		best = max(best, index_leading_bound_count(spec, bindings))
	}
	return best
}
