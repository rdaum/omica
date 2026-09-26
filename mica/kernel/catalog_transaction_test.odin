package kernel

import "core:testing"
import v "../var"

@(test)
test_staged_functional_relation_keys_and_metadata_lifetime :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)
	tx := kernel_begin(&kernel)
	metadata := relation_metadata(0, v.symbol_intern("Dynamic"), 3)
	metadata.conflict = conflict_functional([]u16{0, 2})
	metadata.indexes = []Index_Spec{index_spec([]u16{1})}
	metadata.argument_names = []v.Symbol{v.symbol_intern("a"), v.symbol_intern("b"), v.symbol_intern("c")}
	id, err := transaction_create_relation(&tx, metadata)
	testing.expect_value(t, err, Kernel_Error.None)
	row := tuple_of(must_int(1), must_int(2), must_int(3))
	testing.expect_value(t, transaction_assert(&tx, id, row), Kernel_Error.None)
	_, visible := transaction_tuple_for_key(&tx, id, []u16{0, 2}, []v.Value{must_int(1), must_int(3)})
	testing.expect(t, visible)
	testing.expect_value(t, transaction_assert(&tx, id, tuple_of(must_int(1), must_int(9), must_int(3))), Kernel_Error.Functional_Key_Violation)
	commit_transaction(t, &tx)
	// Retire and reuse the original publication's arena. Descendant catalogues
	// must retain valid keys, indexes, and argument names after repeated commits.
	for i in 0..<40 {
		churn := kernel_begin(&kernel)
		testing.expect_value(t, transaction_assert(&churn, id, tuple_of(must_int(i64(i)+10), must_int(i64(i)), must_int(3))), Kernel_Error.None)
		commit_transaction(t, &churn)
		snapshot := kernel_snapshot(&kernel)
		actual, found := snapshot_relation_metadata(snapshot, id)
		testing.expect(t, found)
		testing.expect_value(t, actual.conflict.key_positions[0], u16(0))
		testing.expect_value(t, actual.conflict.key_positions[1], u16(2))
		testing.expect_value(t, actual.indexes[0].positions[0], u16(1))
		testing.expect_value(t, actual.argument_names[1], v.symbol_intern("b"))
		snapshot_release(snapshot)
	}
}

@(test)
test_read_only_transaction_rejects_catalogue_creation :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)
	tx := kernel_begin(&kernel)
	defer transaction_destroy(&tx)
	tx.read_only = true
	_, err := transaction_create_relation(&tx, relation_metadata(0, v.symbol_intern("Denied"), 1))
	testing.expect_value(t, err, Kernel_Error.Read_Only)
	testing.expect_value(t, len(tx.catalog_changes), 0)
}

@(test)
test_catalogue_same_name_in_one_commit_group :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)
	left := kernel_begin(&kernel)
	defer transaction_destroy(&left)
	right := kernel_begin(&kernel)
	defer transaction_destroy(&right)
	metadata := relation_metadata(0, v.symbol_intern("SameName"), 1)
	first, first_err := transaction_create_relation(&left, metadata)
	second, second_err := transaction_create_relation(&right, metadata)
	testing.expect_value(t, first_err, Kernel_Error.None)
	testing.expect_value(t, second_err, Kernel_Error.None)
	testing.expect(t, first != second)
	a := Commit_Entry{transaction = &left, base = kernel_snapshot(&kernel)}
	a.candidate = transaction_build_candidate(&kernel, &left, a.base)
	b := Commit_Entry{transaction = &right, base = kernel_snapshot(&kernel)}
	b.candidate = transaction_build_candidate(&kernel, &right, b.base)
	// Force both prepared candidates into the same group, independent of
	// scheduling. Only one of their catalogue entries may be published.
	kernel_publish_group(&kernel, []^Commit_Entry{&a, &b})
	for entry in ([]^Commit_Entry{&a, &b}) {
		if entry.published != nil {
			snapshot_release(entry.published)
		} else {
			snapshot_release(entry.candidate)
			snapshot_release(entry.base)
		}
	}
	testing.expect(t, a.published != nil)
	testing.expect(t, b.published == nil)
	snapshot := kernel_snapshot(&kernel)
	defer snapshot_release(snapshot)
	testing.expect_value(t, len(snapshot.catalog), 1)
	testing.expect_value(t, snapshot.catalog[0].id, first)
}
