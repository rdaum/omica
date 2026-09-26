// Private construction views let a source installer validate everything before
// adding any definition to its caller's transaction.
package kernel

import v "../var"

transaction_fork_staging :: proc(parent: ^Transaction) -> Transaction {
	child := transaction_begin(parent.kernel)
	child.source_install = parent.source_install
	snapshot_release(child.base)
	child.base = parent.base
	snapshot_retain(child.base)
	for change in parent.catalog_changes {
		append(
			&child.catalog_changes,
			Staged_Catalog_Change {
				kind = change.kind,
				metadata = metadata_clone(child.allocator, change.metadata),
			},
		)
	}
	for definition in parent.rule_additions {
		append(&child.rule_additions, rule_definition_clone(child.allocator, definition))
	}
	for writes in parent.writes {
		for entry in writes.entries {
			transaction_record_write(
				&child,
				writes.relation,
				v.tuple_deep_copy(child.allocator, entry.tuple),
				entry.kind,
			)
		}
	}
	return child
}

// The child extends the parent's catalogue and tuple state. Buffer edits stay
// in the parent; source installation does not execute buffer operations.
transaction_accept_staging :: proc(parent, child: ^Transaction) {
	parent.source_install = child.source_install
	for change in child.catalog_changes[len(parent.catalog_changes):] {
		append(
			&parent.catalog_changes,
			Staged_Catalog_Change {
				kind = change.kind,
				metadata = metadata_clone(parent.allocator, change.metadata),
			},
		)
	}
	for definition in child.rule_additions[len(parent.rule_additions):] {
		append(&parent.rule_additions, rule_definition_clone(parent.allocator, definition))
	}
	for writes in child.writes {
		for entry in writes.entries {
			transaction_record_write(
				parent,
				writes.relation,
				v.tuple_deep_copy(parent.allocator, entry.tuple),
				entry.kind,
			)
		}
	}
	parent.derived_valid = false
}

transaction_install_rule :: proc(
	tx: ^Transaction,
	id: v.Identity,
	rule: Rule,
	source: string,
) -> Kernel_Error {
	if tx.read_only {return .Read_Only}
	if err := rule_validate_safety(rule, context.temp_allocator); err != .None {return err}
	// Build only the validation catalogue; no facts or derived rows publish.
	preview := snapshot_fork(tx.kernel, tx.base)
	defer snapshot_release(preview)
	for change in tx.catalog_changes {
		if change.kind == .Create {snapshot_add_relation(preview, change.metadata)}
	}
	if err := rule_validate_arity(rule, preview); err != .None {return err}
	for definition in tx.rule_additions {snapshot_add_rule(preview, definition)}
	definition := rule_definition_clone(tx.allocator, rule_definition(id, rule, source))
	snapshot_add_rule(preview, definition)
	active := snapshot_active_rules(preview, context.temp_allocator)
	if _, ok := rules_stratify(active, context.temp_allocator); !ok {return .Unstratified_Negation}
	append(&tx.rule_additions, definition)
	tx.derived_valid = false
	return .None
}
