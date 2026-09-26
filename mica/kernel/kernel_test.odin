package kernel

import "core:mem"
import "core:sync"
import "core:testing"
import "core:time"
import v "../var"
import accel "./accel"

@(private)
must_int :: proc(n: i64) -> v.Value {
	value, ok := v.value_int(n)
	assert(ok)
	return value
}

// A parameter's packed position and mode must survive positions beyond one
// byte. Regression: position was masked to 0xff, so 300 truncated to 44.
@(test)
test_dispatch_param_position_beyond_byte :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	modes := []int{PARAM_REQUIRED_MODE, PARAM_OPTIONAL_MODE, PARAM_REST_MODE}
	for mode in modes {
		packed, packed_ok := v.value_int(300 + i64(mode) * 65536)
		testing.expect(t, packed_ok)
		param := v.tuple_new(context.temp_allocator, []v.Value {
			v.Value(0),
			v.Value(0),
			v.Value(0),
			packed,
		})
		testing.expect_value(t, param_position(param), i64(300))
		testing.expect_value(t, param_mode(param), mode)
	}
}

@(private)
must_identity :: proc(raw: u64) -> v.Value {
	value, ok := v.value_identity_raw(raw)
	assert(ok)
	return value
}

@(private)
sym :: proc(name: string) -> v.Value {
	return v.value_symbol(v.symbol_intern(name))
}

@(private)
tuple_of :: proc(values: ..v.Value) -> v.Tuple {
	return v.tuple_new(context.temp_allocator, values)
}

@(private)
create_relation :: proc(
	kernel: ^Kernel,
	id: u32,
	name: string,
	arity: u16,
) -> Relation_ID {
	return create_relation_with(kernel, id, name, arity, conflict_set(), nil)
}

@(private)
create_relation_with :: proc(
	kernel: ^Kernel,
	id: u32,
	name: string,
	arity: u16,
	conflict: Conflict_Policy,
	indexes: []Index_Spec,
) -> Relation_ID {
	metadata := relation_metadata(Relation_ID(id), v.symbol_intern(name), arity)
	metadata.conflict = conflict
	metadata.indexes = indexes
	snapshot, err := kernel_create_relation(kernel, metadata)
	assert(err == .None)
	snapshot_release(snapshot)
	return Relation_ID(id)
}

@(private)
commit_transaction :: proc(t: ^testing.T, tx: ^Transaction) {
	snapshot, err := transaction_commit(tx)
	testing.expect_value(t, err, Kernel_Error.None)
	snapshot_release(snapshot)
	transaction_destroy(tx)
}

@(private)
kernel_rows :: proc(kernel: ^Kernel, relation: Relation_ID, arity: int) -> [dynamic]v.Tuple {
	bindings := make([]v.Binding, arity, context.temp_allocator)
	rows: [dynamic]v.Tuple
	kernel_scan_into(kernel, relation, bindings, &rows)
	return rows
}

@(private)
snapshot_rows :: proc(
	snapshot: ^Snapshot,
	relation: Relation_ID,
	arity: int,
) -> [dynamic]v.Tuple {
	bindings := make([]v.Binding, arity, context.temp_allocator)
	rows: [dynamic]v.Tuple
	source := Relation_Source{snapshot = snapshot, use_stored_derived = true}
	relation_source_scan_into(&source, relation, bindings, &rows)
	return rows
}

@(private)
transaction_rows :: proc(tx: ^Transaction, relation: Relation_ID, arity: int) -> [dynamic]v.Tuple {
	bindings := make([]v.Binding, arity, context.temp_allocator)
	rows: [dynamic]v.Tuple
	transaction_scan_extensional_into(tx, relation, bindings, &rows)
	if err := transaction_evaluate_derived(tx); err != .None {
		panic("transaction rule evaluation failed")
	}
	for row in transaction_derived_rows(tx, relation) {
		if v.tuple_matches_bindings(row, bindings) {
			append(&rows, row)
		}
	}
	return rows
}

@(private)
has_tuple :: proc(rows: []v.Tuple, tuple: v.Tuple) -> bool {
	for row in rows {
		if v.tuple_eq(row, tuple) {
			return true
		}
	}
	return false
}

@(private)
churn_temp :: proc() {
	for _ in 0 ..< 256 {
		data := make([]u8, 4096, context.temp_allocator)
		for i in 0 ..< len(data) {
			data[i] = 0xAA
		}
	}
}

@(test)
test_snapshot_retain_release_keeps_old_version_readable :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	relation := create_relation(&kernel, 1, "Flag", 1)
	first := must_int(1)
	second := must_int(2)

	tx := kernel_begin(&kernel)
	transaction_assert(&tx, relation, tuple_of(first))
	commit_transaction(t, &tx)

	// Retain the published version before the next commit.
	old := kernel_snapshot(&kernel)
	old_version := old.version

	tx2 := kernel_begin(&kernel)
	transaction_assert(&tx2, relation, tuple_of(second))
	commit_transaction(t, &tx2)

	testing.expect(t, kernel.current.version > old_version)

	// The retained version reads the old row set only.
	rows := snapshot_rows(old, relation, 1)
	testing.expect(t, has_tuple(rows[:], tuple_of(first)))
	testing.expect(t, !has_tuple(rows[:], tuple_of(second)))
	delete(rows)
	testing.expect(t, snapshot_contains(old, relation, tuple_of(first)))
	testing.expect(t, !snapshot_contains(old, relation, tuple_of(second)))

	// The published version reads both rows.
	current_rows := kernel_rows(&kernel, relation, 1)
	testing.expect(t, has_tuple(current_rows[:], tuple_of(first)))
	testing.expect(t, has_tuple(current_rows[:], tuple_of(second)))
	delete(current_rows)

	snapshot_release(old)

	// The kernel stays usable after the retained reference is released.
	after_release := kernel_rows(&kernel, relation, 1)
	testing.expect_value(t, len(after_release), 2)
	delete(after_release)
}

@(test)
test_transaction_owns_asserted_values :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	relation := create_relation(&kernel, 1, "Label", 2)
	lamp := must_identity(1)

	tx := kernel_begin(&kernel)
	// The tuple and its string are allocated from caller scratch memory. The
	// transaction must copy them so the snapshot does not reference scratch
	// storage.
	transaction_assert(
		&tx,
		relation,
		tuple_of(lamp, v.value_string(context.temp_allocator, "ephemeral label")),
	)
	churn_temp()
	commit_transaction(t, &tx)

	rows := kernel_rows(&kernel, relation, 2)
	testing.expect_value(t, len(rows), 1)
	if len(rows) == 1 {
		label, is_string := v.value_as_string(v.tuple_values(rows[0])[1])
		testing.expect(t, is_string)
		testing.expect_value(t, label, "ephemeral label")
	}
	delete(rows)
}

@(test)
test_transaction_assert_retract_and_read_your_writes :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	held_by := create_relation(&kernel, 1, "HeldBy", 2)
	alice := must_identity(1)
	lamp := must_identity(2)

	tx := kernel_begin(&kernel)
	testing.expect_value(
		t,
		transaction_assert(&tx, held_by, tuple_of(alice, lamp)),
		Kernel_Error.None,
	)

	uncommitted := kernel_rows(&kernel, held_by, 2)
	testing.expect_value(t, len(uncommitted), 0)
	delete(uncommitted)

	visible := transaction_rows(&tx, held_by, 2)
	testing.expect(t, has_tuple(visible[:], tuple_of(alice, lamp)))
	delete(visible)

	commit_transaction(t, &tx)

	committed := kernel_rows(&kernel, held_by, 2)
	testing.expect(t, has_tuple(committed[:], tuple_of(alice, lamp)))
	delete(committed)

	// Retraction is visible in the transaction and after commit.
	tx2 := kernel_begin(&kernel)
	testing.expect_value(
		t,
		transaction_retract(&tx2, held_by, tuple_of(alice, lamp)),
		Kernel_Error.None,
	)
	after_retract := transaction_rows(&tx2, held_by, 2)
	testing.expect_value(t, len(after_retract), 0)
	delete(after_retract)
	commit_transaction(t, &tx2)

	final := kernel_rows(&kernel, held_by, 2)
	testing.expect_value(t, len(final), 0)
	delete(final)
}

@(test)
test_transaction_write_last_kind_wins :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	relation := create_relation(&kernel, 1, "Flag", 1)
	value := must_int(7)

	tx := kernel_begin(&kernel)
	transaction_assert(&tx, relation, tuple_of(value))
	transaction_retract(&tx, relation, tuple_of(value))
	transaction_assert(&tx, relation, tuple_of(value))
	commit_transaction(t, &tx)

	rows := kernel_rows(&kernel, relation, 1)
	testing.expect(t, has_tuple(rows[:], tuple_of(value)))
	delete(rows)
}

@(test)
test_transaction_rebase_merges_non_conflicting_writes :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	relation := create_relation(&kernel, 1, "HeldBy", 2)
	tuple_a := tuple_of(must_identity(1), must_identity(2))
	tuple_b := tuple_of(must_identity(3), must_identity(4))

	slow := kernel_begin(&kernel)
	fast := kernel_begin(&kernel)

	transaction_assert(&fast, relation, tuple_a)
	commit_transaction(t, &fast)

	transaction_assert(&slow, relation, tuple_b)
	commit_transaction(t, &slow)

	rows := kernel_rows(&kernel, relation, 2)
	testing.expect(t, has_tuple(rows[:], tuple_a))
	testing.expect(t, has_tuple(rows[:], tuple_b))
	delete(rows)
}

@(test)
test_transaction_set_conflict_detects_concurrent_retract :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	relation := create_relation(&kernel, 1, "HeldBy", 2)
	tuple := tuple_of(must_identity(1), must_identity(2))

	seed := kernel_begin(&kernel)
	transaction_assert(&seed, relation, tuple)
	commit_transaction(t, &seed)

	slow := kernel_begin(&kernel)
	fast := kernel_begin(&kernel)

	transaction_retract(&fast, relation, tuple)
	commit_transaction(t, &fast)

	testing.expect_value(
		t,
		transaction_assert(&slow, relation, tuple),
		Kernel_Error.None,
	)
	snapshot, err := transaction_commit(&slow)
	testing.expect_value(t, err, Kernel_Error.Conflict)
	if snapshot != nil {
		snapshot_release(snapshot)
	}
	transaction_destroy(&slow)
}

@(test)
test_functional_relation_key_violation_and_replacement :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	keys := [1]u16{0}
	name := create_relation_with(&kernel, 1, "Name", 2, conflict_functional(keys[:]), nil)
	lamp := must_identity(1)

	tx := kernel_begin(&kernel)
	transaction_assert(&tx, name, tuple_of(lamp, v.value_string(context.temp_allocator, "brass lamp")))
	commit_transaction(t, &tx)

	tx2 := kernel_begin(&kernel)
	testing.expect_value(
		t,
		transaction_assert(&tx2, name, tuple_of(lamp, v.value_string(context.temp_allocator, "silver lamp"))),
		Kernel_Error.Functional_Key_Violation,
	)

	old := tuple_of(lamp, v.value_string(context.temp_allocator, "brass lamp"))
	new_value := v.value_string(context.temp_allocator, "silver lamp")
	transaction_retract(&tx2, name, old)
	testing.expect_value(
		t,
		transaction_assert(&tx2, name, tuple_of(lamp, new_value)),
		Kernel_Error.None,
	)
	commit_transaction(t, &tx2)

	rows := kernel_rows(&kernel, name, 2)
	testing.expect_value(t, len(rows), 1)
	testing.expect(t, has_tuple(rows[:], tuple_of(lamp, new_value)))
	delete(rows)
}

@(test)
test_functional_relation_conflict_on_key_change :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	keys := [1]u16{0}
	name := create_relation_with(&kernel, 1, "Name", 2, conflict_functional(keys[:]), nil)
	lamp := must_identity(1)
	old := tuple_of(lamp, v.value_string(context.temp_allocator, "old"))

	seed := kernel_begin(&kernel)
	transaction_assert(&seed, name, old)
	commit_transaction(t, &seed)

	slow := kernel_begin(&kernel)
	fast := kernel_begin(&kernel)

	transaction_retract(&fast, name, old)
	transaction_assert(&fast, name, tuple_of(lamp, v.value_string(context.temp_allocator, "fast")))
	commit_transaction(t, &fast)

	transaction_retract(&slow, name, old)
	transaction_assert(&slow, name, tuple_of(lamp, v.value_string(context.temp_allocator, "slow")))
	snapshot, err := transaction_commit(&slow)
	testing.expect_value(t, err, Kernel_Error.Conflict)
	if snapshot != nil {
		snapshot_release(snapshot)
	}
	transaction_destroy(&slow)
}

@(test)
test_secondary_index_scan_returns_matching_rows :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	indexes := [1]Index_Spec{index_spec([]u16{1, 2})}
	relation := create_relation_with(&kernel, 1, "Located", 3, conflict_set(), indexes[:])

	tx := kernel_begin(&kernel)
	transaction_assert(&tx, relation, tuple_of(must_identity(1), must_identity(10), must_int(0)))
	transaction_assert(&tx, relation, tuple_of(must_identity(2), must_identity(10), must_int(1)))
	transaction_assert(&tx, relation, tuple_of(must_identity(3), must_identity(20), must_int(0)))
	commit_transaction(t, &tx)

	bindings := []v.Binding{{}, v.binding_of(must_identity(10)), {}}
	rows: [dynamic]v.Tuple
	kernel_scan_into(&kernel, relation, bindings, &rows)
	testing.expect_value(t, len(rows), 2)
	delete(rows)
}

// Exercises the raw key columns: int keys include negatives, whose sign bit is
// flipped so word order matches numeric order.
@(test)
test_secondary_index_raw_int_keys :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	indexes := [1]Index_Spec{index_spec([]u16{1})}
	relation := create_relation_with(&kernel, 1, "Scored", 3, conflict_set(), indexes[:])

	tx := kernel_begin(&kernel)
	for row in 0 ..< 8 {
		transaction_assert(
			&tx,
			relation,
			tuple_of(must_identity(u64(row)), must_int(i64(row) * 7 - 20), must_int(0)),
		)
	}
	commit_transaction(t, &tx)

	// Keys: -20, -13, -6, 1, 8, 15, 22, 29.
	testing.expect_value(t, scan_count_for_key(&kernel, relation, must_int(-20)), 1)
	testing.expect_value(t, scan_count_for_key(&kernel, relation, must_int(8)), 1)
	testing.expect_value(t, scan_count_for_key(&kernel, relation, must_int(7)), 0)
}

// String keys have no raw word order, so the index takes the canonical
// comparison sort and the canonical bounds search.
@(test)
test_secondary_index_string_keys :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	indexes := [1]Index_Spec{index_spec([]u16{1})}
	relation := create_relation_with(&kernel, 1, "Tagged", 3, conflict_set(), indexes[:])

	blue := v.value_string(context.temp_allocator, "blue")
	green := v.value_string(context.temp_allocator, "green")
	red := v.value_string(context.temp_allocator, "red")

	tx := kernel_begin(&kernel)
	transaction_assert(&tx, relation, tuple_of(must_identity(1), blue, must_int(0)))
	transaction_assert(&tx, relation, tuple_of(must_identity(2), green, must_int(0)))
	transaction_assert(&tx, relation, tuple_of(must_identity(3), blue, must_int(0)))
	commit_transaction(t, &tx)

	testing.expect_value(t, scan_count_for_key(&kernel, relation, blue), 2)
	testing.expect_value(t, scan_count_for_key(&kernel, relation, green), 1)
	testing.expect_value(t, scan_count_for_key(&kernel, relation, red), 0)
}

// Floats carry a monotone sort key too: constructors reject non-finite values
// and canonicalize negative zero, so bit-pattern order is total.
@(test)
test_secondary_index_float_keys :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	indexes := [1]Index_Spec{index_spec([]u16{1})}
	relation := create_relation_with(&kernel, 1, "Measured", 3, conflict_set(), indexes[:])

	values := [?]f32{-3.5, -0.5, 0, 0.25, 2.75}
	tx := kernel_begin(&kernel)
	for value, row in values {
		transaction_assert(
			&tx,
			relation,
			tuple_of(must_identity(u64(row)), must_float(value), must_int(0)),
		)
	}
	commit_transaction(t, &tx)

	for value in values {
		count := scan_count_for_key(&kernel, relation, must_float(value))
		testing.expectf(t, count == 1, "float %v matched %d rows", value, count)
	}
	testing.expect_value(t, scan_count_for_key(&kernel, relation, must_float(1.5)), 0)
}

// A recycled pool arena must not hand a new block the previous block's index:
// the frame allocator returns non-zeroed memory, so the constructors must
// clear the fields `new` would otherwise have zeroed.
@(test)
test_pooled_block_recycled_arena_fresh_index :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	indexes := [1]Index_Spec{index_spec([]u16{1})}
	metadata := relation_metadata(Relation_ID(1), v.symbol_intern("Fresh"), 3)
	metadata.indexes = indexes[:]

	first_rows := make([]v.Tuple, 8, context.temp_allocator)
	for row in 0 ..< 8 {
		first_rows[row] = tuple_of(
			must_identity(u64(row)),
			must_identity(u64(row % 2)),
			must_int(0),
		)
	}
	second_rows := make([]v.Tuple, 8, context.temp_allocator)
	for row in 0 ..< 8 {
		second_rows[row] = tuple_of(must_identity(u64(row)), must_identity(5), must_int(0))
	}

	first := relation_block_build_pooled(&kernel, metadata, first_rows)
	testing.expect_value(t, index_scan_count_for_test(first, must_identity(1)), 4)
	relation_block_release(first)

	second := relation_block_build_pooled(&kernel, metadata, second_rows)
	count := index_scan_count_for_test(second, must_identity(5))
	relation_block_release(second)
	testing.expect_value(t, count, 8)
}

@(private)
index_scan_count_for_test :: proc(block: ^Relation_Block, key: v.Value) -> int {
	bindings := []v.Binding{{}, v.binding_of(key), {}}
	count := 0
	relation_block_visit(
		block,
		bindings,
		proc(user: rawptr, row: v.Tuple) -> bool {
			(^int)(user)^ += 1
			return true
		},
		&count,
	)
	return count
}

@(private)
scan_count_for_key :: proc(kernel: ^Kernel, relation: Relation_ID, key: v.Value) -> int {
	bindings := []v.Binding{{}, v.binding_of(key), {}}
	rows: [dynamic]v.Tuple
	defer delete(rows)
	kernel_scan_into(kernel, relation, bindings, &rows)
	return len(rows)
}

// #100: indexes are materialized lazily on first query and rebuilt per block,
// so results must stay identical across incremental commits and retracts.
@(test)
test_index_correct_across_incremental_commits :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	indexes := [1]Index_Spec{index_spec([]u16{1})}
	relation := create_relation_with(&kernel, 1, "Located", 3, conflict_set(), indexes[:])

	tx := kernel_begin(&kernel)
	transaction_assert(&tx, relation, tuple_of(must_identity(1), must_identity(10), must_int(0)))
	transaction_assert(&tx, relation, tuple_of(must_identity(2), must_identity(20), must_int(1)))
	commit_transaction(t, &tx)
	testing.expect_value(t, scan_count_for_key(&kernel, relation, must_identity(10)), 1)

	// An incremental commit onto the indexed block must not serve stale rows.
	tx2 := kernel_begin(&kernel)
	transaction_assert(&tx2, relation, tuple_of(must_identity(3), must_identity(10), must_int(2)))
	transaction_assert(&tx2, relation, tuple_of(must_identity(4), must_identity(30), must_int(3)))
	commit_transaction(t, &tx2)
	testing.expect_value(t, scan_count_for_key(&kernel, relation, must_identity(10)), 2)
	testing.expect_value(t, scan_count_for_key(&kernel, relation, must_identity(20)), 1)
	testing.expect_value(t, scan_count_for_key(&kernel, relation, must_identity(30)), 1)

	// A retract must drop the row from index results too.
	tx3 := kernel_begin(&kernel)
	transaction_retract(
		&tx3,
		relation,
		tuple_of(must_identity(1), must_identity(10), must_int(0)),
	)
	commit_transaction(t, &tx3)
	testing.expect_value(t, scan_count_for_key(&kernel, relation, must_identity(10)), 1)
}

@(test)
test_rule_rejects_atom_and_head_arity_mismatch :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	base := create_relation(&kernel, 1, "Base", 2)
	derived := create_relation(&kernel, 2, "Derived", 2)

	x := v.symbol_intern("x")
	y := v.symbol_intern("y")

	// The head has one term but the relation has arity 2.
	bad_head := rule_new(
		derived,
		[]Term{term_var(x)},
		[]Rule_Body_Item{body_atom(atom_positive(base, []Term{term_var(x), term_var(y)}))},
	)
	_, head_err := kernel_install_rule(&kernel, v.Identity(1), bad_head, "bad head")
	testing.expect_value(t, head_err, Kernel_Error.Arity_Mismatch)

	// The body atom has one term but the relation has arity 2.
	bad_body := rule_new(
		derived,
		[]Term{term_var(x), term_var(y)},
		[]Rule_Body_Item{body_atom(atom_positive(base, []Term{term_var(x)}))},
	)
	_, body_err := kernel_install_rule(&kernel, v.Identity(2), bad_body, "bad body")
	testing.expect_value(t, body_err, Kernel_Error.Arity_Mismatch)

	// A correct rule still installs.
	good := rule_new(
		derived,
		[]Term{term_var(x), term_var(y)},
		[]Rule_Body_Item{body_atom(atom_positive(base, []Term{term_var(x), term_var(y)}))},
	)
	snapshot, good_err := kernel_install_rule(&kernel, v.Identity(3), good, "good")
	testing.expect_value(t, good_err, Kernel_Error.None)
	snapshot_release(snapshot)
}

@(test)
test_transitive_rule_derives_reachable :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	exit := create_relation(&kernel, 1, "Exit", 2)
	reachable := create_relation(&kernel, 2, "Reachable", 2)

	from := v.symbol_intern("from")
	to := v.symbol_intern("to")
	mid := v.symbol_intern("mid")

	base_rule := rule_new(
		reachable,
		[]Term{term_var(from), term_var(to)},
		[]Rule_Body_Item {
			body_atom(atom_positive(exit, []Term{term_var(from), term_var(to)})),
		},
	)
	recursive_rule := rule_new(
		reachable,
		[]Term{term_var(from), term_var(to)},
		[]Rule_Body_Item {
			body_atom(atom_positive(exit, []Term{term_var(from), term_var(mid)})),
			body_atom(atom_positive(reachable, []Term{term_var(mid), term_var(to)})),
		},
	)

	snapshot, err := kernel_install_rule(&kernel, v.Identity(100), base_rule, "Reachable(f,t) :- Exit(f,t).")
	testing.expect_value(t, err, Kernel_Error.None)
	snapshot_release(snapshot)
	snapshot, err = kernel_install_rule(&kernel, v.Identity(101), recursive_rule, "Reachable(f,t) :- Exit(f,m), Reachable(m,t).")
	testing.expect_value(t, err, Kernel_Error.None)
	snapshot_release(snapshot)

	a := must_identity(1)
	b := must_identity(2)
	c := must_identity(3)
	d := must_identity(4)

	tx := kernel_begin(&kernel)
	transaction_assert(&tx, exit, tuple_of(a, b))
	transaction_assert(&tx, exit, tuple_of(b, c))
	transaction_assert(&tx, exit, tuple_of(c, d))

	// Derived facts are visible inside the transaction.
	in_tx := transaction_rows(&tx, reachable, 2)
	testing.expect(t, has_tuple(in_tx[:], tuple_of(a, c)))
	testing.expect(t, has_tuple(in_tx[:], tuple_of(a, d)))
	delete(in_tx)

	commit_transaction(t, &tx)

	rows := kernel_rows(&kernel, reachable, 2)
	testing.expect(t, has_tuple(rows[:], tuple_of(a, b)))
	testing.expect(t, has_tuple(rows[:], tuple_of(a, c)))
	testing.expect(t, has_tuple(rows[:], tuple_of(a, d)))
	testing.expect(t, has_tuple(rows[:], tuple_of(b, d)))
	testing.expect_value(t, len(rows), 6)
	delete(rows)
}

// #97: suspending derivation defers the fixpoint to the resume. While
// suspended, committed facts are extensional only and derived relations read
// empty; the resume computes every installed rule once and yields the same
// closure the unsuspended path would.
@(test)
test_suspended_derivation_defers_fixpoint_to_resume :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	edge := create_relation(&kernel, 1, "Edge", 2)
	reach := create_relation(&kernel, 2, "Reach", 2)

	from := v.symbol_intern("from")
	to := v.symbol_intern("to")
	mid := v.symbol_intern("mid")
	base_rule := rule_new(
		reach,
		[]Term{term_var(from), term_var(to)},
		[]Rule_Body_Item {
			body_atom(atom_positive(edge, []Term{term_var(from), term_var(to)})),
		},
	)
	recursive_rule := rule_new(
		reach,
		[]Term{term_var(from), term_var(to)},
		[]Rule_Body_Item {
			body_atom(atom_positive(edge, []Term{term_var(from), term_var(mid)})),
			body_atom(atom_positive(reach, []Term{term_var(mid), term_var(to)})),
		},
	)
	snapshot, err := kernel_install_rule(&kernel, v.Identity(100), base_rule, "base")
	testing.expect_value(t, err, Kernel_Error.None)
	snapshot_release(snapshot)
	snapshot, err = kernel_install_rule(&kernel, v.Identity(101), recursive_rule, "recursive")
	testing.expect_value(t, err, Kernel_Error.None)
	snapshot_release(snapshot)

	a := must_identity(1)
	b := must_identity(2)
	c := must_identity(3)
	d := must_identity(4)

	testing.expect(t, kernel_set_derivation(&kernel, false))

	tx := kernel_begin(&kernel)
	transaction_assert(&tx, edge, tuple_of(a, b))
	transaction_assert(&tx, edge, tuple_of(b, c))
	commit_transaction(t, &tx)

	tx2 := kernel_begin(&kernel)
	transaction_assert(&tx2, edge, tuple_of(c, d))
	commit_transaction(t, &tx2)

	// Suspended commits materialize nothing.
	rows := kernel_rows(&kernel, reach, 2)
	testing.expect_value(t, len(rows), 0)
	delete(rows)

	// The resume derives the whole chain once: six pairs.
	testing.expect(t, kernel_set_derivation(&kernel, true))
	rows = kernel_rows(&kernel, reach, 2)
	testing.expect_value(t, len(rows), 6)
	testing.expect(t, has_tuple(rows[:], tuple_of(a, b)))
	testing.expect(t, has_tuple(rows[:], tuple_of(a, d)))
	testing.expect(t, has_tuple(rows[:], tuple_of(b, d)))
	delete(rows)
}

// A transaction that has staged no writes sees exactly its base snapshot's
// derived facts, so reads must reuse the snapshot's already-materialized rows
// rather than re-running the fixpoint. Read-only transactions are the common
// case (every task begins one), and recomputing on each read made a derived
// scan cost a full closure evaluation.
@(test)
test_read_only_transaction_reuses_snapshot_derived :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	edge := create_relation(&kernel, 1, "Edge", 2)
	reach := create_relation(&kernel, 2, "Reach", 2)

	from := v.symbol_intern("from")
	to := v.symbol_intern("to")
	mid := v.symbol_intern("mid")

	base_rule := rule_new(
		reach,
		[]Term{term_var(from), term_var(to)},
		[]Rule_Body_Item {
			body_atom(atom_positive(edge, []Term{term_var(from), term_var(to)})),
		},
	)
	recursive_rule := rule_new(
		reach,
		[]Term{term_var(from), term_var(to)},
		[]Rule_Body_Item {
			body_atom(atom_positive(edge, []Term{term_var(from), term_var(mid)})),
			body_atom(atom_positive(reach, []Term{term_var(mid), term_var(to)})),
		},
	)
	snapshot, err := kernel_install_rule(&kernel, v.Identity(400), base_rule, "Reach(f,t) :- Edge(f,t).")
	testing.expect_value(t, err, Kernel_Error.None)
	snapshot_release(snapshot)
	snapshot, err = kernel_install_rule(&kernel, v.Identity(401), recursive_rule, "Reach(f,t) :- Edge(f,m), Reach(m,t).")
	testing.expect_value(t, err, Kernel_Error.None)
	snapshot_release(snapshot)

	a := must_identity(1)
	b := must_identity(2)
	c := must_identity(3)
	tx := kernel_begin(&kernel)
	transaction_assert(&tx, edge, tuple_of(a, b))
	transaction_assert(&tx, edge, tuple_of(b, c))
	commit_transaction(t, &tx)

	// A fresh transaction with no staged writes must observe the derived facts
	// and must alias the snapshot's rows instead of allocating its own.
	reader := kernel_begin(&kernel)
	defer transaction_destroy(&reader)
	rows := transaction_rows(&reader, reach, 2)
	testing.expect(t, has_tuple(rows[:], tuple_of(a, c)))
	delete(rows)

	base_rows := snapshot_derived_rows(reader.base, reach)
	tx_rows := transaction_derived_rows(&reader, reach)
	testing.expect(t, len(base_rows) > 0 && len(tx_rows) == len(base_rows))
	testing.expect(t, reader.derived_from_base)
	testing.expect(t, raw_data(v.tuple_values(base_rows[0])) == raw_data(v.tuple_values(tx_rows[0])))

	// Staging a write invalidates the reuse and the transaction sees its own
	// facts derived over the overlay.
	transaction_assert(&reader, edge, tuple_of(a, c))
	overlay_rows := transaction_rows(&reader, reach, 2)
	testing.expect(t, has_tuple(overlay_rows[:], tuple_of(a, b)))
	test_rows := transaction_derived_rows(&reader, reach)
	testing.expect(t, !reader.derived_from_base)
	testing.expect(t, raw_data(v.tuple_values(snapshot_derived_rows(reader.base, reach)[0])) != raw_data(v.tuple_values(test_rows[0])))
	delete(overlay_rows)
}

// A bound leading column must return exactly the rows with that prefix, across
// chunk boundaries, and none for a missing prefix. This exercises the
// binary-search path that replaced a linear walk of the whole chunk.
@(test)
test_prefix_scan_across_chunk_boundaries :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	point := create_relation(&kernel, 1, "Point", 2)

	tx := kernel_begin(&kernel)
	// 300 distinct keys span three 128-row chunks.
	for key in 0 ..< 300 {
		transaction_assert(&tx, point, tuple_of(must_int(i64(key)), must_int(i64(key) * 2)))
	}
	commit_transaction(t, &tx)

	// A duplicate of the last key in the first chunk, so that prefix has rows
	// on both sides of a chunk boundary.
	tx2 := kernel_begin(&kernel)
	transaction_assert(&tx2, point, tuple_of(must_int(127), must_int(1)))
	commit_transaction(t, &tx2)

	scan_key :: proc(kernel: ^Kernel, relation: Relation_ID, key: i64) -> [dynamic]v.Tuple {
		bindings := make([]v.Binding, 2, context.temp_allocator)
		bindings[0] = v.binding_of(must_int(key))
		rows := make([dynamic]v.Tuple, 0, 4, context.temp_allocator)
		kernel_scan_into(kernel, relation, bindings, &rows)
		return rows
	}

	for key in ([]int{0, 1, 127, 128, 129, 255, 256, 299}) {
		rows := scan_key(&kernel, point, i64(key))
		want := key == 127 ? 2 : 1
		testing.expectf(t, len(rows) == want, "key %d: got %d rows, want %d", key, len(rows), want)
	}

	for key in ([]int{-1, 300, 1000}) {
		rows := scan_key(&kernel, point, i64(key))
		testing.expectf(t, len(rows) == 0, "missing key %d: got %d rows, want 0", key, len(rows))
	}
}

@(test)
test_stratified_negation_updates_with_facts :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	item := create_relation(&kernel, 1, "Item", 1)
	held := create_relation(&kernel, 2, "Held", 1)
	free := create_relation(&kernel, 3, "Free", 1)

	x := v.symbol_intern("x")
	rule := rule_new(
		free,
		[]Term{term_var(x)},
		[]Rule_Body_Item {
			body_atom(atom_positive(item, []Term{term_var(x)})),
			body_atom(atom_negated(held, []Term{term_var(x)})),
		},
	)
	snapshot, err := kernel_install_rule(&kernel, v.Identity(200), rule, "Free(x) :- Item(x), not Held(x).")
	testing.expect_value(t, err, Kernel_Error.None)
	snapshot_release(snapshot)

	coin := must_identity(1)
	tx := kernel_begin(&kernel)
	transaction_assert(&tx, item, tuple_of(coin))
	commit_transaction(t, &tx)

	rows := kernel_rows(&kernel, free, 1)
	testing.expect(t, has_tuple(rows[:], tuple_of(coin)))
	delete(rows)

	tx2 := kernel_begin(&kernel)
	transaction_assert(&tx2, held, tuple_of(coin))
	commit_transaction(t, &tx2)

	rows2 := kernel_rows(&kernel, free, 1)
	testing.expect(t, !has_tuple(rows2[:], tuple_of(coin)))
	delete(rows2)
}

@(test)
test_rule_guard_comparisons :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	number := create_relation(&kernel, 1, "Number", 1)
	big := create_relation(&kernel, 2, "Big", 1)

	x := v.symbol_intern("x")
	rule := rule_new(
		big,
		[]Term{term_var(x)},
		[]Rule_Body_Item {
			body_atom(atom_positive(number, []Term{term_var(x)})),
			body_guard(rule_guard(.Gt, term_var(x), term_value(must_int(10)))),
		},
	)
	snapshot, err := kernel_install_rule(&kernel, v.Identity(300), rule, "Big(x) :- Number(x), x > 10.")
	testing.expect_value(t, err, Kernel_Error.None)
	snapshot_release(snapshot)

	tx := kernel_begin(&kernel)
	transaction_assert(&tx, number, tuple_of(must_int(5)))
	transaction_assert(&tx, number, tuple_of(must_int(11)))
	transaction_assert(&tx, number, tuple_of(must_int(100)))
	commit_transaction(t, &tx)

	rows := kernel_rows(&kernel, big, 1)
	testing.expect_value(t, len(rows), 2)
	testing.expect(t, has_tuple(rows[:], tuple_of(must_int(11))))
	testing.expect(t, has_tuple(rows[:], tuple_of(must_int(100))))
	testing.expect(t, !has_tuple(rows[:], tuple_of(must_int(5))))
	delete(rows)
}

@(test)
test_unsafe_and_unstratified_rules_are_rejected :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	base := create_relation(&kernel, 1, "Base", 1)
	derived := create_relation(&kernel, 2, "Derived", 1)

	x := v.symbol_intern("x")

	unsafe := rule_new(
		derived,
		[]Term{term_var(x)},
		[]Rule_Body_Item {
			body_atom(atom_negated(base, []Term{term_var(x)})),
		},
	)
	_, unsafe_err := kernel_install_rule(&kernel, v.Identity(1), unsafe, "Derived(x) :- not Base(x).")
	testing.expect_value(t, unsafe_err, Kernel_Error.Unsafe_Negation)

	unstratified := rule_new(
		derived,
		[]Term{term_var(x)},
		[]Rule_Body_Item {
			body_atom(atom_positive(base, []Term{term_var(x)})),
			body_atom(atom_negated(derived, []Term{term_var(x)})),
		},
	)
	_, unstratified_err := kernel_install_rule(
		&kernel,
		v.Identity(2),
		unstratified,
		"Derived(x) :- Base(x), not Derived(x).",
	)
	testing.expect_value(t, unstratified_err, Kernel_Error.Unstratified_Negation)
}

@(test)
test_delegates_star_and_reaches :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	delegates := create_relation(&kernel, 1, "Delegates", 3)

	tx := kernel_begin(&kernel)
	transaction_assert(&tx, delegates, tuple_of(must_identity(1), must_identity(2), must_int(0)))
	transaction_assert(&tx, delegates, tuple_of(must_identity(2), must_identity(3), must_int(0)))
	transaction_assert(&tx, delegates, tuple_of(must_identity(4), must_identity(5), must_int(0)))
	commit_transaction(t, &tx)

	source := Relation_Source{snapshot = kernel.current, use_stored_derived = true}
	testing.expect(
		t,
		delegates_reaches(&source, delegates, must_identity(1), must_identity(3)),
	)
	testing.expect(
		t,
		!delegates_reaches(&source, delegates, must_identity(1), must_identity(4)),
	)

	prototypes := delegates_star_from(&source, delegates, must_identity(1), context.temp_allocator)
	testing.expect_value(t, len(prototypes), 2)
}

@(test)
test_dispatch_matches_through_delegation :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	method_selector := create_relation(&kernel, 40, "MethodSelector", 2)
	param := create_relation(&kernel, 41, "Param", 4)
	delegates := create_relation(&kernel, 42, "Delegates", 3)
	relations := Dispatch_Relations {
		method_selector = method_selector,
		param           = param,
		delegates       = delegates,
	}

	tx := kernel_begin(&kernel)
	method := must_int(100)
	actor := must_identity(10)
	item := must_identity(1)
	player := must_identity(11)
	thing := must_identity(2)

	transaction_assert(&tx, method_selector, tuple_of(method, sym("take")))
	transaction_assert(&tx, param, tuple_of(method, sym("actor"), player, must_int(0)))
	transaction_assert(&tx, param, tuple_of(method, sym("item"), thing, must_int(1)))
	transaction_assert(&tx, delegates, tuple_of(actor, player, must_int(0)))
	transaction_assert(&tx, delegates, tuple_of(item, thing, must_int(0)))

	source := Relation_Source{transaction = &tx, use_stored_derived = true}
	roles := []Role_Pair {
		{role = sym("actor"), value = actor},
		{role = sym("item"), value = item},
	}
	methods := applicable_methods(&source, relations, sym("take"), roles, context.temp_allocator)
	testing.expect_value(t, len(methods), 1)
	if len(methods) == 1 {
		testing.expect(t, v.value_eq(methods[0], method))
	}
	commit_transaction(t, &tx)
}

// Dispatching repeatedly with an explicit allocator must not accumulate
// memory: every intermediate the resolver allocates is released. Regression
// for #74, where the resolver allocated its scratch from the never-reset
// ambient temporary arena.
@(test)
test_dispatch_resolution_is_allocation_balanced :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	method_selector := create_relation(&kernel, 40, "MethodSelector", 2)
	param := create_relation(&kernel, 41, "Param", 4)
	delegates := create_relation(&kernel, 42, "Delegates", 3)
	relations := Dispatch_Relations {
		method_selector = method_selector,
		param           = param,
		delegates       = delegates,
	}

	tx := kernel_begin(&kernel)
	method := must_int(100)
	transaction_assert(&tx, method_selector, tuple_of(method, sym("take")))
	transaction_assert(&tx, param, tuple_of(method, sym("actor"), must_identity(10), must_int(0)))
	transaction_assert(&tx, param, tuple_of(method, sym("item"), must_identity(20), must_int(1)))
	source := Relation_Source{transaction = &tx, use_stored_derived = true}
	roles := []Role_Pair {
		{role = sym("actor"), value = must_identity(10)},
		{role = sym("item"), value = must_identity(20)},
	}

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)

	// Resolve many times with a tracking allocator: any scratch that is not
	// released shows up as a live allocation. This is the shape the worker
	// path runs in, and the old code accumulated one entry per dispatch.
	for _ in 0 ..< 1_000 {
		entries := applicable_method_entries(&source, relations, sym("take"), roles, alloc)
		testing.expect_value(t, len(entries), 1)
		applicable_methods_destroy(&entries, alloc)
	}

	testing.expectf(
		t,
		len(track.allocation_map) == 0,
		"dispatch resolution left %d allocation(s) live",
		len(track.allocation_map),
	)
	commit_transaction(t, &tx)
}

@(test)
test_dispatch_open_signature_and_unrestricted_params :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	method_selector := create_relation(&kernel, 40, "MethodSelector", 2)
	param := create_relation(&kernel, 41, "Param", 4)
	delegates := create_relation(&kernel, 42, "Delegates", 3)
	relations := Dispatch_Relations {
		method_selector = method_selector,
		param           = param,
		delegates       = delegates,
	}

	tx := kernel_begin(&kernel)
	method := must_int(100)
	transaction_assert(&tx, method_selector, tuple_of(method, sym("say")))
	transaction_assert(
		&tx,
		param,
		tuple_of(method, sym("message"), unrestricted_dispatch_restriction(), must_int(0)),
	)

	source := Relation_Source{transaction = &tx, use_stored_derived = true}

	// Missing role means not applicable (open signature).
	missing := applicable_methods(
		&source,
		relations,
		sym("say"),
		[]Role_Pair{{role = sym("actor"), value = must_identity(10)}},
		context.temp_allocator,
	)
	testing.expect_value(t, len(missing), 0)

	// Extra roles are ignored.
	present := applicable_methods(
		&source,
		relations,
		sym("say"),
		[]Role_Pair {
			{role = sym("actor"), value = must_identity(10)},
			{role = sym("message"), value = v.value_string(context.temp_allocator, "hi")},
			{role = sym("extra"), value = must_int(3)},
		},
		context.temp_allocator,
	)
	testing.expect_value(t, len(present), 1)
	commit_transaction(t, &tx)
}

@(test)
test_dispatch_matches_primitive_prototype :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	method_selector := create_relation(&kernel, 40, "MethodSelector", 2)
	param := create_relation(&kernel, 41, "Param", 4)
	delegates := create_relation(&kernel, 42, "Delegates", 3)
	relations := Dispatch_Relations {
		method_selector = method_selector,
		param           = param,
		delegates       = delegates,
	}

	tx := kernel_begin(&kernel)
	method := must_int(100)
	integer_restriction := v.value_identity(v.INTEGER_PROTOTYPE)
	transaction_assert(&tx, method_selector, tuple_of(method, sym("bump")))
	transaction_assert(&tx, param, tuple_of(method, sym("amount"), integer_restriction, must_int(0)))

	source := Relation_Source{transaction = &tx, use_stored_derived = true}
	matches := applicable_methods(
		&source,
		relations,
		sym("bump"),
		[]Role_Pair{{role = sym("amount"), value = must_int(5)}},
		context.temp_allocator,
	)
	testing.expect_value(t, len(matches), 1)

	rejects := applicable_methods(
		&source,
		relations,
		sym("bump"),
		[]Role_Pair{{role = sym("amount"), value = v.value_string(context.temp_allocator, "five")}},
		context.temp_allocator,
	)
	testing.expect_value(t, len(rejects), 0)
	commit_transaction(t, &tx)
}

@(private)
must_float :: proc(f: f32) -> v.Value {
	value, ok := v.value_float(f)
	assert(ok)
	return value
}

@(test)
test_transaction_error_matrix :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	relation := create_relation(&kernel, 1, "HeldBy", 2)

	tx := kernel_begin(&kernel)
	defer transaction_destroy(&tx)

	testing.expect_value(
		t,
		transaction_assert(&tx, Relation_ID(99), tuple_of(must_identity(1), must_identity(2))),
		Kernel_Error.Unknown_Relation,
	)
	testing.expect_value(
		t,
		transaction_assert(&tx, relation, tuple_of(must_identity(1))),
		Kernel_Error.Arity_Mismatch,
	)
	testing.expect_value(
		t,
		transaction_retract(&tx, relation, tuple_of(must_identity(1))),
		Kernel_Error.Arity_Mismatch,
	)

	// Capabilities are storable in live tuples, but function values are not.
	capability := v.value_capability(v.Capability_ID(1))
	testing.expect_value(
		t,
		transaction_assert(&tx, relation, tuple_of(must_identity(1), capability)),
		Kernel_Error.None,
	)
	function := v.value_function(v.Function_ID(1))
	testing.expect_value(
		t,
		transaction_assert(&tx, relation, tuple_of(must_identity(1), function)),
		Kernel_Error.Non_Persistent_Value,
	)
}

@(test)
test_create_relation_rejects_duplicates_and_invalid_metadata :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	create_relation(&kernel, 1, "HeldBy", 2)

	duplicate_name := relation_metadata(Relation_ID(2), v.symbol_intern("HeldBy"), 2)
	_, name_err := kernel_create_relation(&kernel, duplicate_name)
	testing.expect_value(t, name_err, Kernel_Error.Duplicate_Relation_Name)

	duplicate_id := relation_metadata(Relation_ID(1), v.symbol_intern("Other"), 2)
	_, id_err := kernel_create_relation(&kernel, duplicate_id)
	testing.expect_value(t, id_err, Kernel_Error.Invalid_Metadata)

	bad_index := relation_metadata(Relation_ID(3), v.symbol_intern("BadIndex"), 2)
	bad_index.indexes = []Index_Spec{index_spec([]u16{5})}
	_, index_err := kernel_create_relation(&kernel, bad_index)
	testing.expect_value(t, index_err, Kernel_Error.Invalid_Metadata)

	keys := [1]u16{7}
	bad_key := relation_metadata(Relation_ID(4), v.symbol_intern("BadKey"), 2)
	bad_key.conflict = conflict_functional(keys[:])
	_, key_err := kernel_create_relation(&kernel, bad_key)
	testing.expect_value(t, key_err, Kernel_Error.Invalid_Metadata)
}

@(test)
test_retract_ignores_tuple_absent_from_base :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	relation := create_relation(&kernel, 1, "HeldBy", 2)
	held := tuple_of(must_identity(1), must_identity(2))

	// The slow transaction retracts a tuple that its base does not hold.
	slow := kernel_begin(&kernel)
	testing.expect_value(
		t,
		transaction_retract(&slow, relation, held),
		Kernel_Error.None,
	)

	// Another transaction asserts the tuple first.
	fast := kernel_begin(&kernel)
	transaction_assert(&fast, relation, held)
	commit_transaction(t, &fast)

	// The rebased retract must not remove the tuple that the base lacked.
	commit_transaction(t, &slow)

	rows := kernel_rows(&kernel, relation, 2)
	testing.expect(t, has_tuple(rows[:], held))
	delete(rows)
}

@(test)
test_multi_stratum_rules_negate_derived_relation :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	exit := create_relation(&kernel, 1, "Exit", 2)
	node := create_relation(&kernel, 2, "Node", 1)
	reachable := create_relation(&kernel, 3, "Reachable", 2)
	unreachable := create_relation(&kernel, 4, "Unreachable", 2)

	from := v.symbol_intern("from")
	to := v.symbol_intern("to")
	mid := v.symbol_intern("mid")

	base_rule := rule_new(
		reachable,
		[]Term{term_var(from), term_var(to)},
		[]Rule_Body_Item {
			body_atom(atom_positive(exit, []Term{term_var(from), term_var(to)})),
		},
	)
	recursive_rule := rule_new(
		reachable,
		[]Term{term_var(from), term_var(to)},
		[]Rule_Body_Item {
			body_atom(atom_positive(exit, []Term{term_var(from), term_var(mid)})),
			body_atom(atom_positive(reachable, []Term{term_var(mid), term_var(to)})),
		},
	)
	// The negated atom reads a derived relation from the stratum below.
	negation_rule := rule_new(
		unreachable,
		[]Term{term_var(from), term_var(to)},
		[]Rule_Body_Item {
			body_atom(atom_positive(node, []Term{term_var(from)})),
			body_atom(atom_positive(node, []Term{term_var(to)})),
			body_atom(atom_negated(reachable, []Term{term_var(from), term_var(to)})),
		},
	)

	rules := []Rule{base_rule, recursive_rule, negation_rule}
	for rule, index in rules {
		snapshot, err := kernel_install_rule(&kernel, v.Identity(400 + index), rule, "multi stratum")
		testing.expect_value(t, err, Kernel_Error.None)
		snapshot_release(snapshot)
	}

	a := must_identity(1)
	b := must_identity(2)
	c := must_identity(3)

	tx := kernel_begin(&kernel)
	transaction_assert(&tx, node, tuple_of(a))
	transaction_assert(&tx, node, tuple_of(b))
	transaction_assert(&tx, node, tuple_of(c))
	transaction_assert(&tx, exit, tuple_of(a, b))
	transaction_assert(&tx, exit, tuple_of(b, c))
	commit_transaction(t, &tx)

	rows := kernel_rows(&kernel, unreachable, 2)
	testing.expect_value(t, len(rows), 6)
	testing.expect(t, !has_tuple(rows[:], tuple_of(a, b)))
	testing.expect(t, has_tuple(rows[:], tuple_of(a, a)))
	testing.expect(t, has_tuple(rows[:], tuple_of(c, b)))
	delete(rows)

	// A new edge closes the cycle, so no pair stays unreachable.
	tx2 := kernel_begin(&kernel)
	transaction_assert(&tx2, exit, tuple_of(c, a))
	commit_transaction(t, &tx2)

	rows2 := kernel_rows(&kernel, unreachable, 2)
	testing.expect_value(t, len(rows2), 0)
	delete(rows2)
}

@(test)
test_disable_rule_removes_derived_facts :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	base := create_relation(&kernel, 1, "Base", 1)
	derived := create_relation(&kernel, 2, "Derived", 1)

	x := v.symbol_intern("x")
	rule := rule_new(
		derived,
		[]Term{term_var(x)},
		[]Rule_Body_Item{body_atom(atom_positive(base, []Term{term_var(x)}))},
	)
	snapshot, err := kernel_install_rule(&kernel, v.Identity(500), rule, "Derived(x) :- Base(x).")
	testing.expect_value(t, err, Kernel_Error.None)
	snapshot_release(snapshot)

	value := must_identity(1)
	tx := kernel_begin(&kernel)
	transaction_assert(&tx, base, tuple_of(value))
	commit_transaction(t, &tx)

	before := kernel_rows(&kernel, derived, 1)
	testing.expect(t, has_tuple(before[:], tuple_of(value)))
	delete(before)

	disabled, disable_err := kernel_disable_rule(&kernel, v.Identity(500))
	testing.expect_value(t, disable_err, Kernel_Error.None)
	snapshot_release(disabled)

	after := kernel_rows(&kernel, derived, 1)
	testing.expect_value(t, len(after), 0)
	delete(after)

	_, missing_err := kernel_disable_rule(&kernel, v.Identity(501))
	testing.expect_value(t, missing_err, Kernel_Error.No_Such_Rule)
}

@(test)
test_guard_operators :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	number := create_relation(&kernel, 1, "Number", 1)
	selected := create_relation(&kernel, 2, "Selected", 2)

	ops := [6]Rule_Comparison_Op{.Eq, .Ne, .Lt, .Le, .Gt, .Ge}
	x := v.symbol_intern("x")

	for op, index in ops {
		rule := rule_new(
			selected,
			[]Term{term_value(must_int(i64(index))), term_var(x)},
			[]Rule_Body_Item {
				body_atom(atom_positive(number, []Term{term_var(x)})),
				body_guard(rule_guard(op, term_var(x), term_value(must_int(2)))),
			},
		)
		snapshot, err := kernel_install_rule(&kernel, v.Identity(600 + index), rule, "guard op")
		testing.expect_value(t, err, Kernel_Error.None)
		snapshot_release(snapshot)
	}

	tx := kernel_begin(&kernel)
	transaction_assert(&tx, number, tuple_of(must_int(1)))
	transaction_assert(&tx, number, tuple_of(must_int(2)))
	transaction_assert(&tx, number, tuple_of(must_int(3)))
	transaction_assert(&tx, number, tuple_of(must_float(2.0)))
	commit_transaction(t, &tx)

	rows := kernel_rows(&kernel, selected, 2)
	testing.expect_value(t, len(rows), 12)

	// Eq matches both numeric forms of two.
	testing.expect(t, has_tuple(rows[:], tuple_of(must_int(0), must_int(2))))
	testing.expect(t, has_tuple(rows[:], tuple_of(must_int(0), must_float(2.0))))
	// Ne rejects both.
	testing.expect(t, !has_tuple(rows[:], tuple_of(must_int(1), must_int(2))))
	testing.expect(t, !has_tuple(rows[:], tuple_of(must_int(1), must_float(2.0))))
	// Lt keeps one.
	testing.expect(t, has_tuple(rows[:], tuple_of(must_int(2), must_int(1))))
	// Le keeps three.
	testing.expect(t, has_tuple(rows[:], tuple_of(must_int(3), must_float(2.0))))
	testing.expect(t, has_tuple(rows[:], tuple_of(must_int(3), must_int(1))))
	// Gt keeps one.
	testing.expect(t, has_tuple(rows[:], tuple_of(must_int(4), must_int(3))))
	// Ge keeps three.
	testing.expect(t, has_tuple(rows[:], tuple_of(must_int(5), must_int(3))))
	testing.expect(t, has_tuple(rows[:], tuple_of(must_int(5), must_float(2.0))))
	delete(rows)
}

@(private)
Stop_State :: struct {
	visited: int,
	limit:   int,
}

@(private)
stopping_visit :: proc(user: rawptr, row: v.Tuple) -> bool {
	state := (^Stop_State)(user)
	state.visited += 1
	return state.visited < state.limit
}

@(test)
test_store_search_paths_match_linear_filter :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	metadata := relation_metadata(Relation_ID(1), v.symbol_intern("store-search"), 3)
	metadata.indexes = []Index_Spec {
		index_spec([]u16{2}),
		index_spec([]u16{1, 0}),
		index_spec([]u16{0}),
	}

	rows: [dynamic]v.Tuple
	for i in 0 ..< 200 {
		cells := []v.Value {
			must_int(i64(i % 10)),
			must_int(i64((i / 10) % 5)),
			must_int(i64(i)),
		}
		append(&rows, v.tuple_new(alloc, cells))
	}
	block := relation_block_build(alloc, metadata, rows[:])
	testing.expect_value(t, relation_block_len(block), 200)
	delete(rows)

	patterns := [][3]int {
		{1, 0, 0}, // position 0 bound
		{0, 1, 0}, // position 1 bound
		{1, 0, 1}, // positions 0 and 2 bound, non-contiguous
		{0, 0, 1}, // position 2 bound, secondary index path
		{1, 1, 1}, // fully bound
		{0, 0, 0}, // unbound
	}

	source_row := relation_block_row(block, 17)
	for pattern in patterns {
		bindings: [3]v.Binding
		for bound, i in pattern {
			if bound == 1 {
				bindings[i] = v.binding_of(v.tuple_values(source_row)[i])
			}
		}

		visited: [dynamic]v.Tuple
		relation_block_scan_into(block, bindings[:], &visited)

		expected: [dynamic]v.Tuple
		for row_index in 0 ..< relation_block_len(block) {
			row := relation_block_row(block, row_index)
			if v.tuple_matches_bindings(row, bindings[:]) {
				append(&expected, row)
			}
		}

		testing.expect_value(t, len(visited), len(expected))
		for row in expected {
			testing.expect(t, has_tuple(visited[:], row))
		}
		delete(visited)
		delete(expected)
	}

	// A visitor that returns false ends the scan.
	state := Stop_State{limit = 5}
	relation_block_visit(block, []v.Binding{{}, {}, {}}, stopping_visit, &state)
	testing.expect_value(t, state.visited, 5)
}

@(test)
test_dispatch_prefers_more_specific_method :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	method_selector := create_relation(&kernel, 40, "MethodSelector", 2)
	param := create_relation(&kernel, 41, "Param", 4)
	delegates := create_relation(&kernel, 42, "Delegates", 3)
	relations := Dispatch_Relations {
		method_selector = method_selector,
		param           = param,
		delegates       = delegates,
	}

	child := must_identity(2)
	parent := must_identity(11)
	specific := must_int(100)
	general := must_int(101)

	tx := kernel_begin(&kernel)
	transaction_assert(&tx, method_selector, tuple_of(specific, sym("take")))
	transaction_assert(&tx, method_selector, tuple_of(general, sym("take")))
	transaction_assert(&tx, param, tuple_of(specific, sym("item"), child, must_int(0)))
	transaction_assert(&tx, param, tuple_of(general, sym("item"), parent, must_int(0)))
	transaction_assert(&tx, delegates, tuple_of(child, parent, must_int(0)))

	source := Relation_Source{transaction = &tx, use_stored_derived = true}
	roles := []Role_Pair{{role = sym("item"), value = child}}
	methods := applicable_methods(&source, relations, sym("take"), roles, context.temp_allocator)
	testing.expect_value(t, len(methods), 1)
	if len(methods) == 1 {
		testing.expect(t, v.value_eq(methods[0], specific))
	}
	commit_transaction(t, &tx)
}

@(test)
test_closure_handles_cycles :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	delegates := create_relation(&kernel, 1, "Delegates", 3)

	tx := kernel_begin(&kernel)
	transaction_assert(&tx, delegates, tuple_of(must_identity(1), must_identity(2), must_int(0)))
	transaction_assert(&tx, delegates, tuple_of(must_identity(2), must_identity(3), must_int(0)))
	transaction_assert(&tx, delegates, tuple_of(must_identity(3), must_identity(1), must_int(0)))
	commit_transaction(t, &tx)

	source := Relation_Source{snapshot = kernel.current, use_stored_derived = true}
	testing.expect(t, delegates_reaches(&source, delegates, must_identity(1), must_identity(3)))
	testing.expect(t, delegates_reaches(&source, delegates, must_identity(3), must_identity(2)))
	testing.expect(t, delegates_reaches(&source, delegates, must_identity(3), must_identity(1)))

	prototypes := delegates_star_from(&source, delegates, must_identity(1), context.temp_allocator)
	testing.expect_value(t, len(prototypes), 3)

	// A cycle makes the starting child reachable again, so each of the three
	// children contributes three pairs.
	pairs := delegates_star(&source, delegates, context.temp_allocator)
	testing.expect_value(t, len(pairs), 9)
	testing.expect(t, has_tuple(pairs, tuple_of(must_identity(1), must_identity(3))))
	testing.expect(t, has_tuple(pairs, tuple_of(must_identity(3), must_identity(2))))
	testing.expect(t, has_tuple(pairs, tuple_of(must_identity(2), must_identity(2))))
}

@(test)
test_rule_validation_errors :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	base := create_relation(&kernel, 1, "Base", 1)
	derived := create_relation(&kernel, 2, "Derived", 1)

	x := v.symbol_intern("x")
	y := v.symbol_intern("y")

	// Unknown head relation.
	unknown_head := rule_new(
		Relation_ID(99),
		[]Term{term_var(x)},
		[]Rule_Body_Item{body_atom(atom_positive(base, []Term{term_var(x)}))},
	)
	_, unknown_head_err := kernel_install_rule(&kernel, v.Identity(1), unknown_head, "unknown head")
	testing.expect_value(t, unknown_head_err, Kernel_Error.Unknown_Relation)

	// Unknown body relation.
	unknown_body := rule_new(
		derived,
		[]Term{term_var(x)},
		[]Rule_Body_Item{body_atom(atom_positive(Relation_ID(99), []Term{term_var(x)}))},
	)
	_, unknown_body_err := kernel_install_rule(&kernel, v.Identity(2), unknown_body, "unknown body")
	testing.expect_value(t, unknown_body_err, Kernel_Error.Unknown_Relation)

	// The guard reads a variable that no positive atom binds.
	unsafe_guard := rule_new(
		derived,
		[]Term{term_var(x)},
		[]Rule_Body_Item {
			body_atom(atom_positive(base, []Term{term_var(x)})),
			body_guard(rule_guard(.Eq, term_var(y), term_value(must_int(1)))),
		},
	)
	_, unsafe_guard_err := kernel_install_rule(&kernel, v.Identity(3), unsafe_guard, "unsafe guard")
	testing.expect_value(t, unsafe_guard_err, Kernel_Error.Unsafe_Guard)

	// The head reads a variable that no positive atom binds.
	unbound_head := rule_new(
		derived,
		[]Term{term_var(y)},
		[]Rule_Body_Item{body_atom(atom_positive(base, []Term{term_var(x)}))},
	)
	_, unbound_head_err := kernel_install_rule(&kernel, v.Identity(4), unbound_head, "unbound head")
	testing.expect_value(t, unbound_head_err, Kernel_Error.Unbound_Head_Variable)
}

@(test)
test_rule_terms_constants_and_repeated_variables :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	query := create_relation(&kernel, 1, "Query", 2)
	selected := create_relation(&kernel, 2, "Selected", 1)
	pair := create_relation(&kernel, 3, "Pair", 2)
	same := create_relation(&kernel, 4, "Same", 1)

	x := v.symbol_intern("x")

	// Selected(x) :- Query(x, 5), a constant in the body.
	constant_rule := rule_new(
		selected,
		[]Term{term_var(x)},
		[]Rule_Body_Item {
			body_atom(atom_positive(query, []Term{term_var(x), term_value(must_int(5))})),
		},
	)
	snapshot, constant_err := kernel_install_rule(&kernel, v.Identity(700), constant_rule, "constant")
	testing.expect_value(t, constant_err, Kernel_Error.None)
	snapshot_release(snapshot)

	// Same(x) :- Pair(x, x), a repeated variable in one atom.
	repeated_rule := rule_new(
		same,
		[]Term{term_var(x)},
		[]Rule_Body_Item {
			body_atom(atom_positive(pair, []Term{term_var(x), term_var(x)})),
		},
	)
	snapshot2, repeated_err := kernel_install_rule(&kernel, v.Identity(701), repeated_rule, "repeated")
	testing.expect_value(t, repeated_err, Kernel_Error.None)
	snapshot_release(snapshot2)

	tx := kernel_begin(&kernel)
	transaction_assert(&tx, query, tuple_of(must_int(1), must_int(5)))
	transaction_assert(&tx, query, tuple_of(must_int(2), must_int(6)))
	transaction_assert(&tx, query, tuple_of(must_int(3), must_int(5)))
	transaction_assert(&tx, pair, tuple_of(must_int(1), must_int(1)))
	transaction_assert(&tx, pair, tuple_of(must_int(1), must_int(2)))
	transaction_assert(&tx, pair, tuple_of(must_int(3), must_int(3)))
	commit_transaction(t, &tx)

	selected_rows := kernel_rows(&kernel, selected, 1)
	testing.expect_value(t, len(selected_rows), 2)
	testing.expect(t, has_tuple(selected_rows[:], tuple_of(must_int(1))))
	testing.expect(t, has_tuple(selected_rows[:], tuple_of(must_int(3))))
	delete(selected_rows)

	same_rows := kernel_rows(&kernel, same, 1)
	testing.expect_value(t, len(same_rows), 2)
	testing.expect(t, has_tuple(same_rows[:], tuple_of(must_int(1))))
	testing.expect(t, has_tuple(same_rows[:], tuple_of(must_int(3))))
	delete(same_rows)
}

@(test)
test_empty_commit_and_idempotent_writes :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	relation := create_relation(&kernel, 1, "HeldBy", 2)
	present := tuple_of(must_identity(1), must_identity(2))
	absent := tuple_of(must_identity(3), must_identity(4))

	version_before := kernel.current.version
	empty := kernel_begin(&kernel)
	commit_transaction(t, &empty)
	// An empty commit publishes nothing and must not advance the version.
	testing.expect_value(t, kernel.current.version, version_before)

	seed := kernel_begin(&kernel)
	transaction_assert(&seed, relation, present)
	commit_transaction(t, &seed)

	// Assert of a present tuple and retract of an absent tuple change nothing.
	tx := kernel_begin(&kernel)
	testing.expect_value(t, transaction_assert(&tx, relation, present), Kernel_Error.None)
	testing.expect_value(t, transaction_retract(&tx, relation, absent), Kernel_Error.None)
	commit_transaction(t, &tx)

	rows := kernel_rows(&kernel, relation, 2)
	testing.expect_value(t, len(rows), 1)
	testing.expect(t, has_tuple(rows[:], present))
	delete(rows)
}

@(test)
test_conflict_in_one_relation_rolls_back_the_others :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	first := create_relation(&kernel, 1, "First", 2)
	second := create_relation(&kernel, 2, "Second", 2)
	contested := tuple_of(must_identity(1), must_identity(2))
	other := tuple_of(must_identity(3), must_identity(4))

	seed := kernel_begin(&kernel)
	transaction_assert(&seed, first, contested)
	commit_transaction(t, &seed)

	slow := kernel_begin(&kernel)
	transaction_assert(&slow, first, contested)
	transaction_assert(&slow, second, other)

	fast := kernel_begin(&kernel)
	transaction_retract(&fast, first, contested)
	commit_transaction(t, &fast)

	snapshot, err := transaction_commit(&slow)
	testing.expect_value(t, err, Kernel_Error.Conflict)
	if snapshot != nil {
		snapshot_release(snapshot)
	}
	transaction_destroy(&slow)

	// The write to the second relation must not appear.
	rows := kernel_rows(&kernel, second, 2)
	testing.expect_value(t, len(rows), 0)
	delete(rows)
}

@(test)
test_dispatch_frob_only_restrictions :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	method_selector := create_relation(&kernel, 40, "MethodSelector", 2)
	param := create_relation(&kernel, 41, "Param", 4)
	delegates := create_relation(&kernel, 42, "Delegates", 3)
	relations := Dispatch_Relations {
		method_selector = method_selector,
		param           = param,
		delegates       = delegates,
	}

	method := must_int(100)
	required_delegate_id, _ := v.identity_new(11)
	child_delegate_id, _ := v.identity_new(2)
	required_delegate := v.value_identity(required_delegate_id)
	child_delegate := v.value_identity(child_delegate_id)

	tx := kernel_begin(&kernel)
	restriction := frob_only_dispatch_restriction(context.temp_allocator, v.Identity(11))
	transaction_assert(&tx, method_selector, tuple_of(method, sym("take")))
	transaction_assert(&tx, param, tuple_of(method, sym("item"), restriction, must_int(0)))
	transaction_assert(&tx, delegates, tuple_of(child_delegate, required_delegate, must_int(0)))

	source := Relation_Source{transaction = &tx, use_stored_derived = true}

	matches := applicable_methods(
		&source,
		relations,
		sym("take"),
		[]Role_Pair {
			{
				role  = sym("item"),
				value = v.value_frob(context.temp_allocator, required_delegate_id, must_int(1)),
			},
		},
		context.temp_allocator,
	)
	testing.expect_value(t, len(matches), 1)

	// The frob delegate can reach the required delegate through delegation.
	inherited := applicable_methods(
		&source,
		relations,
		sym("take"),
		[]Role_Pair {
			{
				role  = sym("item"),
				value = v.value_frob(context.temp_allocator, child_delegate_id, must_int(1)),
			},
		},
		context.temp_allocator,
	)
	testing.expect_value(t, len(inherited), 1)

	// A plain value is not a frob, so the frob-only restriction rejects it.
	rejected := applicable_methods(
		&source,
		relations,
		sym("take"),
		[]Role_Pair{{role = sym("item"), value = required_delegate}},
		context.temp_allocator,
	)
	testing.expect_value(t, len(rejected), 0)
	commit_transaction(t, &tx)
}

@(test)
test_snapshot_metadata_lookup_by_name :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	relation := create_relation(&kernel, 1, "HeldBy", 2)

	metadata, found := snapshot_relation_metadata_named(kernel.current, v.symbol_intern("HeldBy"))
	testing.expect(t, found)
	testing.expect_value(t, metadata.id, relation)

	_, missing := snapshot_relation_metadata_named(kernel.current, v.symbol_intern("NoSuchRelation"))
	testing.expect(t, !missing)
}

@(test)
test_metadata_defaults :: proc(t: ^testing.T) {
	metadata := relation_metadata(Relation_ID(1), v.symbol_intern("Defaults"), 3)
	testing.expect_value(t, metadata.id, Relation_ID(1))
	testing.expect_value(t, metadata.arity, u16(3))
	testing.expect_value(t, len(metadata.indexes), 0)
	testing.expect_value(t, metadata.conflict.kind, Conflict_Kind.Set)
	testing.expect_value(t, metadata.durability, Relation_Durability.Durable)
	testing.expect_value(t, len(metadata.argument_names), 0)
}

@(test)
test_system_endpoint_relations_are_volatile :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	metadata := system_relation_metadata(context.temp_allocator)
	volatile_ids := [?]Relation_ID {
		SYSTEM_ENDPOINT_ID,
		SYSTEM_ENDPOINT_ACTOR_ID,
		SYSTEM_ENDPOINT_PRINCIPAL_ID,
		SYSTEM_ENDPOINT_PROTOCOL_ID,
		SYSTEM_ENDPOINT_OPEN_ID,
	}
	for entry in metadata {
		for id in volatile_ids {
			if entry.id != id {
				continue
			}
			testing.expectf(
				t,
				entry.durability == .Volatile,
				"relation %v should be volatile",
				entry.id,
			)
		}
		if entry.id == SYSTEM_RELATION_ID {
			testing.expect_value(t, entry.durability, Relation_Durability.Durable)
		}
	}
}

@(test)
test_dispatch_method_entries_expose_params :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	method_selector := create_relation(&kernel, 40, "MethodSelector", 2)
	param := create_relation(&kernel, 41, "Param", 4)
	delegates := create_relation(&kernel, 42, "Delegates", 3)
	relations := Dispatch_Relations {
		method_selector = method_selector,
		param           = param,
		delegates       = delegates,
	}

	method := must_int(100)
	actor := must_identity(10)
	item := must_identity(1)
	player := must_identity(11)
	thing := must_identity(2)

	tx := kernel_begin(&kernel)
	transaction_assert(&tx, method_selector, tuple_of(method, sym("take")))
	transaction_assert(&tx, param, tuple_of(method, sym("actor"), player, must_int(0)))
	transaction_assert(&tx, param, tuple_of(method, sym("item"), thing, must_int(1)))
	transaction_assert(&tx, delegates, tuple_of(actor, player, must_int(0)))
	transaction_assert(&tx, delegates, tuple_of(item, thing, must_int(0)))

	source := Relation_Source{transaction = &tx, use_stored_derived = true}
	roles := []Role_Pair {
		{role = sym("actor"), value = actor},
		{role = sym("item"), value = item},
	}
	entries := applicable_method_entries(
		&source,
		relations,
		sym("take"),
		roles,
		context.temp_allocator,
	)
	testing.expect_value(t, len(entries), 1)
	if len(entries) == 1 {
		testing.expect(t, v.value_eq(entries[0].method, method))
		testing.expect_value(t, len(entries[0].params), 2)

		actor_found := false
		item_found := false
		for param_row in entries[0].params {
			values := v.tuple_values(param_row)
			role := values[1]
			if v.value_eq(role, sym("actor")) {
				actor_found = true
				testing.expect(t, v.value_eq(values[2], player))
				testing.expect_value(t, values[3], must_int(0))
			}
			if v.value_eq(role, sym("item")) {
				item_found = true
				testing.expect(t, v.value_eq(values[2], thing))
				testing.expect_value(t, values[3], must_int(1))
			}
		}
		testing.expect(t, actor_found)
		testing.expect(t, item_found)
	}
	commit_transaction(t, &tx)
}

@(test)
test_rule_evaluation_error_path :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	base := create_relation(&kernel, 1, "Base", 1)
	derived := create_relation(&kernel, 2, "Derived", 1)

	snapshot := kernel_snapshot(&kernel)
	defer snapshot_release(snapshot)
	alloc := context.temp_allocator

	x := v.symbol_intern("x")

	// Safety validation rejects this rule at install. Evaluating it directly
	// must report the same error.
	unsafe := rule_definition(
		v.Identity(1),
		rule_new(
			derived,
			[]Term{term_var(x)},
			[]Rule_Body_Item{body_atom(atom_negated(base, []Term{term_var(x)}))},
		),
		"unsafe",
	)
	_, unsafe_err := rules_evaluate(alloc, []Rule_Definition{unsafe}, snapshot)
	testing.expect_value(t, unsafe_err, Kernel_Error.Unsafe_Negation)

	// Stratification rejects this rule at install. Evaluating it directly
	// must report the same error.
	unstratified := rule_definition(
		v.Identity(2),
		rule_new(
			derived,
			[]Term{term_var(x)},
			[]Rule_Body_Item {
				body_atom(atom_positive(base, []Term{term_var(x)})),
				body_atom(atom_negated(derived, []Term{term_var(x)})),
			},
		),
		"unstratified",
	)
	_, unstratified_err := rules_evaluate(alloc, []Rule_Definition{unstratified}, snapshot)
	testing.expect_value(t, unstratified_err, Kernel_Error.Unstratified_Negation)
}

@(private)
Visit_Collect :: struct {
	rows: [dynamic]v.Tuple,
}

@(private)
visit_collect :: proc(user: rawptr, row: v.Tuple) -> bool {
	append(&(^Visit_Collect)(user).rows, row)
	return true
}

@(private)
Visit_Stop :: struct {
	seen: int,
}

@(private)
visit_stop :: proc(user: rawptr, row: v.Tuple) -> bool {
	(^Visit_Stop)(user).seen += 1
	return false
}

@(test)
test_frob_prototype_fallback :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	method_selector := create_relation(&kernel, 40, "MethodSelector", 2)
	param := create_relation(&kernel, 41, "Param", 4)
	delegates := create_relation(&kernel, 42, "Delegates", 3)
	relations := Dispatch_Relations {
		method_selector = method_selector,
		param           = param,
		delegates       = delegates,
	}

	method := must_int(100)
	tx := kernel_begin(&kernel)
	restriction := v.value_identity(v.FROB_PROTOTYPE)
	transaction_assert(&tx, method_selector, tuple_of(method, sym("take")))
	transaction_assert(&tx, param, tuple_of(method, sym("item"), restriction, must_int(0)))

	source := Relation_Source{transaction = &tx, use_stored_derived = true}
	delegate, _ := v.identity_new(5)

	// A frob value matches through the frob prototype.
	frob_value := v.value_frob(context.temp_allocator, delegate, must_int(1))
	matches := applicable_methods(
		&source,
		relations,
		sym("take"),
		[]Role_Pair{{role = sym("item"), value = frob_value}},
		context.temp_allocator,
	)
	testing.expect_value(t, len(matches), 1)

	// A plain identity value does not match the frob prototype.
	plain := applicable_methods(
		&source,
		relations,
		sym("take"),
		[]Role_Pair{{role = sym("item"), value = v.value_identity(delegate)}},
		context.temp_allocator,
	)
	testing.expect_value(t, len(plain), 0)
	commit_transaction(t, &tx)
}

@(test)
test_kernel_visit_and_contains :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	relation := create_relation(&kernel, 1, "HeldBy", 2)
	actor := must_identity(1)
	other := must_identity(3)
	lamp := must_identity(2)
	coin := must_identity(4)

	tx := kernel_begin(&kernel)
	transaction_assert(&tx, relation, tuple_of(actor, lamp))
	transaction_assert(&tx, relation, tuple_of(actor, coin))
	transaction_assert(&tx, relation, tuple_of(other, lamp))
	commit_transaction(t, &tx)

	testing.expect(t, kernel_contains(&kernel, relation, tuple_of(actor, lamp)))
	testing.expect(t, !kernel_contains(&kernel, relation, tuple_of(lamp, actor)))

	unbound := []v.Binding{{}, {}}
	collector := Visit_Collect{}
	stopped := kernel_visit(&kernel, relation, unbound, visit_collect, &collector)
	testing.expect(t, !stopped)
	testing.expect_value(t, len(collector.rows), 3)
	delete(collector.rows)

	filtered := []v.Binding{v.binding_of(actor), {}}
	filtered_collector := Visit_Collect{}
	kernel_visit(&kernel, relation, filtered, visit_collect, &filtered_collector)
	testing.expect_value(t, len(filtered_collector.rows), 2)
	delete(filtered_collector.rows)

	state := Visit_Stop{}
	stop_result := kernel_visit(&kernel, relation, unbound, visit_stop, &state)
	testing.expect(t, stop_result)
	testing.expect_value(t, state.seen, 1)
}

@(test)
test_dispatch_role_duplicates_use_first_role :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	method_selector := create_relation(&kernel, 40, "MethodSelector", 2)
	param := create_relation(&kernel, 41, "Param", 4)
	delegates := create_relation(&kernel, 42, "Delegates", 3)
	relations := Dispatch_Relations {
		method_selector = method_selector,
		param           = param,
		delegates       = delegates,
	}

	method := must_int(100)
	expected := must_identity(1)
	other := must_identity(2)

	tx := kernel_begin(&kernel)
	transaction_assert(&tx, method_selector, tuple_of(method, sym("take")))
	transaction_assert(&tx, param, tuple_of(method, sym("item"), expected, must_int(0)))

	source := Relation_Source{transaction = &tx, use_stored_derived = true}

	// The first role entry wins when the role repeats.
	first_match := applicable_methods(
		&source,
		relations,
		sym("take"),
		[]Role_Pair {
			{role = sym("item"), value = expected},
			{role = sym("item"), value = other},
		},
		context.temp_allocator,
	)
	testing.expect_value(t, len(first_match), 1)

	second_match := applicable_methods(
		&source,
		relations,
		sym("take"),
		[]Role_Pair {
			{role = sym("item"), value = other},
			{role = sym("item"), value = expected},
		},
		context.temp_allocator,
	)
	testing.expect_value(t, len(second_match), 0)
	commit_transaction(t, &tx)
}

@(test)
test_metadata_helpers :: proc(t: ^testing.T) {
	positions := []u16{0, 1}
	key_positions := []u16{0}
	names := []v.Symbol{v.symbol_intern("meta-first"), v.symbol_intern("meta-second")}

	metadata := relation_metadata(Relation_ID(1), v.symbol_intern("MetaHelpers"), 2)
	metadata.indexes = []Index_Spec{index_spec(positions)}
	metadata.conflict = conflict_functional(key_positions)
	metadata.argument_names = names

	cloned := metadata_clone(context.temp_allocator, metadata)
	testing.expect_value(t, cloned.id, metadata.id)
	testing.expect_value(t, cloned.arity, metadata.arity)
	testing.expect_value(t, len(cloned.indexes), 1)
	testing.expect_value(t, cloned.indexes[0].positions[0], u16(0))
	testing.expect_value(t, cloned.conflict.kind, Conflict_Kind.Functional)
	testing.expect_value(t, cloned.conflict.key_positions[0], u16(0))

	// Mutating the source does not change the clone.
	positions[0] = 1
	key_positions[0] = 1
	testing.expect_value(t, cloned.indexes[0].positions[0], u16(0))
	testing.expect_value(t, cloned.conflict.key_positions[0], u16(0))

	testing.expect(t, index_is_natural_full_tuple(index_spec([]u16{0, 1}), 2))
	testing.expect(t, !index_is_natural_full_tuple(index_spec([]u16{1, 0}), 2))
	testing.expect(t, !index_is_natural_full_tuple(index_spec([]u16{0}), 2))

	bindings := []v.Binding {
		v.binding_of(must_int(1)),
		v.Binding{},
		v.binding_of(must_int(2)),
	}
	testing.expect_value(t, index_leading_bound_count(index_spec([]u16{0, 2, 1}), bindings), 2)
	testing.expect_value(t, index_leading_bound_count(index_spec([]u16{0, 1}), bindings), 1)
	testing.expect_value(t, index_leading_bound_count(index_spec([]u16{1, 0}), bindings), 0)

	name, name_ok := metadata_argument_name(cloned, 0)
	testing.expect(t, name_ok)
	testing.expect_value(t, name, names[0])
	_, missing_name := metadata_argument_name(cloned, 7)
	testing.expect(t, !missing_name)
}

@(test)
test_snapshot_fork_and_version_inheritance :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	relation := create_relation(&kernel, 1, "Forked", 2)

	base := kernel_snapshot(&kernel)
	testing.expect_value(t, base.version, u64(1))

	fork := snapshot_fork(&kernel, base)
	testing.expect_value(t, fork.version, base.version + 1)
	testing.expect(t, fork.parent == base)
	testing.expect(t, snapshot_has_relation(fork, relation))
	_, metadata_found := snapshot_relation_metadata(fork, relation)
	testing.expect(t, metadata_found)

	// A block materialized by a commit is visible in a later snapshot.
	tx := kernel_begin(&kernel)
	transaction_assert(&tx, relation, tuple_of(must_identity(1), must_identity(2)))
	commit_transaction(t, &tx)

	published := kernel_snapshot(&kernel)
	block, block_found := snapshot_relation_block(published, relation)
	testing.expect(t, block_found)
	testing.expect_value(t, relation_block_len(block), 1)

	row, row_found := snapshot_tuple_for_key(
		published,
		relation,
		[]u16{0},
		[]v.Value{must_identity(1)},
	)
	testing.expect(t, row_found)
	testing.expect_value(t, v.tuple_arity(row), 2)
	_, missing_row := snapshot_tuple_for_key(
		published,
		relation,
		[]u16{0},
		[]v.Value{must_identity(9)},
	)
	testing.expect(t, !missing_row)

	snapshot_release(published)
	snapshot_release(fork)
	snapshot_release(base)
}

@(test)
test_transaction_derived_invalidation :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	item := create_relation(&kernel, 1, "Item", 1)
	held := create_relation(&kernel, 2, "Held", 1)
	free := create_relation(&kernel, 3, "Free", 1)

	x := v.symbol_intern("x")
	rule := rule_new(
		free,
		[]Term{term_var(x)},
		[]Rule_Body_Item {
			body_atom(atom_positive(item, []Term{term_var(x)})),
			body_atom(atom_negated(held, []Term{term_var(x)})),
		},
	)
	snapshot, err := kernel_install_rule(&kernel, v.Identity(800), rule, "Free(x) :- Item(x), not Held(x).")
	testing.expect_value(t, err, Kernel_Error.None)
	snapshot_release(snapshot)

	coin := must_identity(1)

	tx := kernel_begin(&kernel)
	testing.expect_value(t, transaction_base_version(&tx), kernel.current.version)

	transaction_assert(&tx, item, tuple_of(coin))
	before := transaction_rows(&tx, free, 1)
	testing.expect(t, has_tuple(before[:], tuple_of(coin)))
	delete(before)

	// A write to a negated relation invalidates the derived cache.
	transaction_assert(&tx, held, tuple_of(coin))
	during := transaction_rows(&tx, free, 1)
	testing.expect_value(t, len(during), 0)
	delete(during)

	// A retraction restores the derived fact.
	transaction_retract(&tx, held, tuple_of(coin))
	after := transaction_rows(&tx, free, 1)
	testing.expect(t, has_tuple(after[:], tuple_of(coin)))
	delete(after)

	transaction_destroy(&tx)
}

// The negated single-column identity atom is the accelerator's first kernel
// caller: `apply_negated_columns` routes it through `membership_select` as one
// batch instead of one existence scan per binding. This test pins the wiring
// with enough bindings to matter; the operator thresholds still apply, so it
// passes on both CPU and Metal strategies.
@(test)
test_negated_atom_batch_path :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	item := create_relation(&kernel, 1, "Item", 1)
	held := create_relation(&kernel, 2, "Held", 1)
	free := create_relation(&kernel, 3, "Free", 1)

	x := v.symbol_intern("x")
	rule := rule_new(
		free,
		[]Term{term_var(x)},
		[]Rule_Body_Item {
			body_atom(atom_positive(item, []Term{term_var(x)})),
			body_atom(atom_negated(held, []Term{term_var(x)})),
		},
	)
	snapshot, err := kernel_install_rule(&kernel, v.Identity(810), rule, "Free(x) :- Item(x), not Held(x).")
	testing.expect_value(t, err, Kernel_Error.None)
	snapshot_release(snapshot)

	// 64 items, even ones held: Free must be exactly the odd ones however
	// the negated atom is evaluated.
	tx := kernel_begin(&kernel)
	for i in 1 ..= 64 {
		transaction_assert(&tx, item, tuple_of(must_identity(u64(i))))
		if i % 2 == 0 {
			transaction_assert(&tx, held, tuple_of(must_identity(u64(i))))
		}
	}
	commit_transaction(t, &tx)

	rows := kernel_rows(&kernel, free, 1)
	defer delete(rows)
	testing.expect_value(t, len(rows), 32)
	for i in 1 ..= 64 {
		has := has_tuple(rows[:], tuple_of(must_identity(u64(i))))
		testing.expectf(t, has == (i % 2 == 1), "item %d: has=%v", i, has)
	}
}

// The accelerator strategy is process-wide and tests run on parallel threads.
// Tests that install a strategy, or assert counts that depend on which one is
// active, hold this lock.
@(private)
strategy_tests_lock: sync.Mutex

// A negated computed relation that requires its column bound: the batch path's
// unbound scan fails, so it must decline and let the row path probe each
// binding (bound). Before the fix every item came out "odd".
@(test)
test_negated_batch_declines_on_computed_scan_error :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	item := create_relation(&kernel, 1, "Item", 1)
	even := create_relation(&kernel, 2, "Even", 1)
	odd := create_relation(&kernel, 3, "Odd", 1)
	testing.expect_value(
		t,
		kernel_register_computed_relation(
			&kernel,
			even,
			[]u16{0},
			proc(user: rawptr, source: ^Relation_Source, bindings: []v.Binding, visit: Computed_Visit_Proc, visit_user: rawptr) -> Kernel_Error {
				id, ok := v.value_as_identity(bindings[0].value)
				if ok && u64(id) % 2 == 0 {
					visit(visit_user, v.tuple_new(context.temp_allocator, []v.Value{bindings[0].value}))
				}
				return .None
			},
		),
		Kernel_Error.None,
	)

	x := v.symbol_intern("x")
	rule := rule_new(
		odd,
		[]Term{term_var(x)},
		[]Rule_Body_Item {
			body_atom(atom_positive(item, []Term{term_var(x)})),
			body_atom(atom_negated(even, []Term{term_var(x)})),
		},
	)
	snapshot, err := kernel_install_rule(&kernel, v.Identity(811), rule, "Odd(x) :- Item(x), not Even(x).")
	testing.expect_value(t, err, Kernel_Error.None)
	snapshot_release(snapshot)

	tx := kernel_begin(&kernel)
	for i in 1 ..= 64 {
		transaction_assert(&tx, item, tuple_of(must_identity(u64(i))))
	}
	commit_transaction(t, &tx)

	rows := kernel_rows(&kernel, odd, 1)
	defer delete(rows)
	testing.expect_value(t, len(rows), 32)
	for i in 1 ..= 64 {
		has := has_tuple(rows[:], tuple_of(must_identity(u64(i))))
		testing.expectf(t, has == (i % 2 == 1), "item %d: has=%v", i, has)
	}
}

// The batch path records its outcome: with the CPU reference strategy active,
// the 64-item negation of test_negated_atom_batch_path completes on the batch
// path at least once per evaluation.
@(test)
test_negated_batch_records_placement :: proc(t: ^testing.T) {
	sync.mutex_lock(&strategy_tests_lock)
	defer sync.mutex_unlock(&strategy_tests_lock)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	item := create_relation(&kernel, 1, "Item", 1)
	held := create_relation(&kernel, 2, "Held", 1)
	free := create_relation(&kernel, 3, "Free", 1)
	x := v.symbol_intern("x")
	rule := rule_new(
		free,
		[]Term{term_var(x)},
		[]Rule_Body_Item {
			body_atom(atom_positive(item, []Term{term_var(x)})),
			body_atom(atom_negated(held, []Term{term_var(x)})),
		},
	)
	snapshot, err := kernel_install_rule(&kernel, v.Identity(812), rule, "Free(x) :- Item(x), not Held(x).")
	testing.expect_value(t, err, Kernel_Error.None)
	snapshot_release(snapshot)

	before := placement_counts_this_thread()
	tx := kernel_begin(&kernel)
	for i in 1 ..= 64 {
		transaction_assert(&tx, item, tuple_of(must_identity(u64(i))))
		if i % 2 == 0 {
			transaction_assert(&tx, held, tuple_of(must_identity(u64(i))))
		}
	}
	commit_transaction(t, &tx)
	delta := placement_counts_delta(before, placement_counts_this_thread())
	testing.expect(t, delta[.Negated_Membership][.Completed] >= 1)
}

// Two-position negation (visible_items shape) on the batch path, identical to
// the row path's answer.
@(test)
test_negated_batch_two_positions :: proc(t: ^testing.T) {
	sync.mutex_lock(&strategy_tests_lock)
	defer sync.mutex_unlock(&strategy_tests_lock)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)
	sees := create_relation(&kernel, 1, "Sees", 2)
	hidden := create_relation(&kernel, 2, "Hidden", 2)
	visible := create_relation(&kernel, 3, "Visible", 2)
	a, i := v.symbol_intern("a"), v.symbol_intern("i")
	rule := rule_new(visible, []Term{term_var(a), term_var(i)}, []Rule_Body_Item {
		body_atom(atom_positive(sees, []Term{term_var(a), term_var(i)})),
		body_atom(atom_negated(hidden, []Term{term_var(a), term_var(i)})),
	})
	snapshot, err := kernel_install_rule(&kernel, v.Identity(813), rule, "Visible(a, i) :- Sees(a, i), not Hidden(a, i).")
	testing.expect_value(t, err, Kernel_Error.None)
	snapshot_release(snapshot)
	before := placement_counts_this_thread()
	tx := kernel_begin(&kernel)
	for actor in 1 ..= 8 {
		for item in 100 ..< 132 {
			transaction_assert(&tx, sees, tuple_of(must_identity(u64(actor)), must_identity(u64(item))))
			if (actor + item) % 5 == 0 {
				transaction_assert(&tx, hidden, tuple_of(must_identity(u64(actor)), must_identity(u64(item))))
			}
		}
	}
	commit_transaction(t, &tx)
	rows := kernel_rows(&kernel, visible, 2)
	defer delete(rows)
	expected := 0
	for actor in 1 ..= 8 {
		for item in 100 ..< 132 {
			shown := (actor + item) % 5 != 0
			if shown {
				expected += 1
			}
			has := has_tuple(rows[:], tuple_of(must_identity(u64(actor)), must_identity(u64(item))))
			testing.expectf(t, has == shown, "actor %d item %d: has=%v", actor, item, has)
		}
	}
	testing.expect_value(t, len(rows), expected)
	delta := placement_counts_delta(before, placement_counts_this_thread())
	testing.expect(t, delta[.Negated_Membership][.Completed] >= 1)
}

// Integer probes pack now (Stage 0 counted them Not_Packable); string probes
// still take the row path and give the same answer.
@(test)
test_negated_batch_ints_pack_strings_do_not :: proc(t: ^testing.T) {
	sync.mutex_lock(&strategy_tests_lock)
	defer sync.mutex_unlock(&strategy_tests_lock)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)
	item := create_relation(&kernel, 1, "Item", 1)
	held := create_relation(&kernel, 2, "Held", 1)
	free := create_relation(&kernel, 3, "Free", 1)
	x := v.symbol_intern("x")
	rule := rule_new(free, []Term{term_var(x)}, []Rule_Body_Item {
		body_atom(atom_positive(item, []Term{term_var(x)})),
		body_atom(atom_negated(held, []Term{term_var(x)})),
	})
	snapshot, err := kernel_install_rule(&kernel, v.Identity(814), rule, "Free(x) :- Item(x), not Held(x).")
	testing.expect_value(t, err, Kernel_Error.None)
	snapshot_release(snapshot)

	before := placement_counts_this_thread()
	tx := kernel_begin(&kernel)
	for i in 1 ..= 40 {
		n, _ := v.value_int(i64(i))
		transaction_assert(&tx, item, tuple_of(n))
		if i % 4 == 0 {
			transaction_assert(&tx, held, tuple_of(n))
		}
	}
	commit_transaction(t, &tx)
	ints := placement_counts_delta(before, placement_counts_this_thread())
	testing.expect(t, ints[.Negated_Membership][.Completed] >= 1)
	rows := kernel_rows(&kernel, free, 1)
	testing.expect_value(t, len(rows), 30)
	delete(rows)

	before = placement_counts_this_thread()
	tx = kernel_begin(&kernel)
	word := v.value_string(context.temp_allocator, "word")
	transaction_assert(&tx, item, tuple_of(word))
	commit_transaction(t, &tx)
	strs := placement_counts_delta(before, placement_counts_this_thread())
	testing.expect(t, strs[.Negated_Membership][.Not_Packable] >= 1)
	rows = kernel_rows(&kernel, free, 1)
	testing.expect_value(t, len(rows), 31)
	delete(rows)
	free_all(context.temp_allocator)
}

// Three-position negation declines, counted.
@(test)
test_negated_batch_three_positions_counted_unsupported :: proc(t: ^testing.T) {
	sync.mutex_lock(&strategy_tests_lock)
	defer sync.mutex_unlock(&strategy_tests_lock)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)
	base := create_relation(&kernel, 1, "Base", 3)
	block := create_relation(&kernel, 2, "Block", 3)
	out := create_relation(&kernel, 3, "Out", 3)
	a, b, c := v.symbol_intern("a"), v.symbol_intern("b"), v.symbol_intern("c")
	rule := rule_new(out, []Term{term_var(a), term_var(b), term_var(c)}, []Rule_Body_Item {
		body_atom(atom_positive(base, []Term{term_var(a), term_var(b), term_var(c)})),
		body_atom(atom_negated(block, []Term{term_var(a), term_var(b), term_var(c)})),
	})
	snapshot, err := kernel_install_rule(&kernel, v.Identity(815), rule, "Out(a,b,c) :- Base(a,b,c), not Block(a,b,c).")
	testing.expect_value(t, err, Kernel_Error.None)
	snapshot_release(snapshot)
	before := placement_counts_this_thread()
	tx := kernel_begin(&kernel)
	transaction_assert(&tx, base, tuple_of(must_identity(1), must_identity(2), must_identity(3)))
	transaction_assert(&tx, base, tuple_of(must_identity(1), must_identity(2), must_identity(4)))
	transaction_assert(&tx, block, tuple_of(must_identity(1), must_identity(2), must_identity(4)))
	commit_transaction(t, &tx)
	delta := placement_counts_delta(before, placement_counts_this_thread())
	testing.expect(t, delta[.Negated_Membership][.Unsupported] >= 1)
	rows := kernel_rows(&kernel, out, 3)
	defer delete(rows)
	testing.expect_value(t, len(rows), 1)
}

// A strategy that declines after the keys are packed must not throw them
// away: the CPU reference finishes the step on the packed keys (Cpu_Fallback),
// with the same answer.
@(test)
test_negated_batch_strategy_decline_falls_back_to_cpu_on_packed_keys :: proc(t: ^testing.T) {
	sync.mutex_lock(&strategy_tests_lock)
	defer sync.mutex_unlock(&strategy_tests_lock)
	declining := accel.cpu_strategy()
	declining.name = "declining"
	declining.membership_select = proc(left: []u64, right: []u64, keep: bool, allocator: mem.Allocator) -> ([]bool, bool) {
		return nil, false
	}
	declining.prepare_column = nil
	accel.select_strategy(declining)
	defer accel.use_cpu()

	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)
	item := create_relation(&kernel, 1, "Item", 1)
	held := create_relation(&kernel, 2, "Held", 1)
	free := create_relation(&kernel, 3, "Free", 1)
	x := v.symbol_intern("x")
	rule := rule_new(free, []Term{term_var(x)}, []Rule_Body_Item {
		body_atom(atom_positive(item, []Term{term_var(x)})),
		body_atom(atom_negated(held, []Term{term_var(x)})),
	})
	snapshot, err := kernel_install_rule(&kernel, v.Identity(816), rule, "Free(x) :- Item(x), not Held(x).")
	testing.expect_value(t, err, Kernel_Error.None)
	snapshot_release(snapshot)
	before := placement_counts_this_thread()
	tx := kernel_begin(&kernel)
	for i in 1 ..= 30 {
		transaction_assert(&tx, item, tuple_of(must_identity(u64(i))))
		if i % 3 == 0 {
			transaction_assert(&tx, held, tuple_of(must_identity(u64(i))))
		}
	}
	commit_transaction(t, &tx)
	delta := placement_counts_delta(before, placement_counts_this_thread())
	testing.expect_value(t, delta[.Negated_Membership][.Completed], 0)
	testing.expect_value(t, delta[.Negated_Membership][.Cpu_Fallback], 1)
	rows := kernel_rows(&kernel, free, 1)
	defer delete(rows)
	testing.expect_value(t, len(rows), 20)
}

// Constants in a negated atom pack like variables.
@(test)
test_negated_batch_constant_term :: proc(t: ^testing.T) {
	sync.mutex_lock(&strategy_tests_lock)
	defer sync.mutex_unlock(&strategy_tests_lock)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)
	item := create_relation(&kernel, 1, "Item", 1)
	tag := create_relation(&kernel, 2, "Tag", 2)
	untagged := create_relation(&kernel, 3, "Untagged", 1)
	x := v.symbol_intern("x")
	fixed := must_identity(999)
	rule := rule_new(untagged, []Term{term_var(x)}, []Rule_Body_Item {
		body_atom(atom_positive(item, []Term{term_var(x)})),
		body_atom(atom_negated(tag, []Term{term_var(x), term_value(fixed)})),
	})
	snapshot, err := kernel_install_rule(&kernel, v.Identity(817), rule, "Untagged(x) :- Item(x), not Tag(x, #fixed).")
	testing.expect_value(t, err, Kernel_Error.None)
	snapshot_release(snapshot)
	before := placement_counts_this_thread()
	tx := kernel_begin(&kernel)
	for i in 1 ..= 20 {
		transaction_assert(&tx, item, tuple_of(must_identity(u64(i))))
		if i % 4 == 0 {
			transaction_assert(&tx, tag, tuple_of(must_identity(u64(i)), fixed))
		}
		if i % 5 == 0 {
			transaction_assert(&tx, tag, tuple_of(must_identity(u64(i)), must_identity(7)))
		}
	}
	commit_transaction(t, &tx)
	delta := placement_counts_delta(before, placement_counts_this_thread())
	testing.expect_value(t, delta[.Negated_Membership][.Completed], 1)
	rows := kernel_rows(&kernel, untagged, 1)
	defer delete(rows)
	testing.expect_value(t, len(rows), 15)
	for i in 1 ..= 20 {
		has := has_tuple(rows[:], tuple_of(must_identity(u64(i))))
		testing.expectf(t, has == (i % 4 != 0), "item %d: has=%v", i, has)
	}
}

@(test)
test_derived_dedupe :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	pair := create_relation(&kernel, 1, "Pair", 2)
	first := create_relation(&kernel, 2, "First", 1)

	x := v.symbol_intern("x")
	y := v.symbol_intern("y")
	rule := rule_new(
		first,
		[]Term{term_var(x)},
		[]Rule_Body_Item{body_atom(atom_positive(pair, []Term{term_var(x), term_var(y)}))},
	)
	snapshot, err := kernel_install_rule(&kernel, v.Identity(900), rule, "First(x) :- Pair(x, y).")
	testing.expect_value(t, err, Kernel_Error.None)
	snapshot_release(snapshot)

	tx := kernel_begin(&kernel)
	transaction_assert(&tx, pair, tuple_of(must_identity(1), must_identity(1)))
	transaction_assert(&tx, pair, tuple_of(must_identity(1), must_identity(2)))
	transaction_assert(&tx, pair, tuple_of(must_identity(2), must_identity(3)))
	commit_transaction(t, &tx)

	// First(1) is derivable twice, but it appears once.
	rows := kernel_rows(&kernel, first, 1)
	testing.expect_value(t, len(rows), 2)
	testing.expect(t, has_tuple(rows[:], tuple_of(must_identity(1))))
	testing.expect(t, has_tuple(rows[:], tuple_of(must_identity(2))))
	delete(rows)
}

@(test)
test_kernel_next_relation_id :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	testing.expect_value(t, kernel_next_relation_id(&kernel), Relation_ID(1))
	create_relation(&kernel, 1, "First", 1)
	testing.expect_value(t, kernel_next_relation_id(&kernel), Relation_ID(2))
	create_relation(&kernel, 5, "Fifth", 1)
	testing.expect_value(t, kernel_next_relation_id(&kernel), Relation_ID(6))
}

@(test)
test_semi_naive_recursion_branching_and_cycles :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	exit := create_relation(&kernel, 1, "Exit", 2)
	reachable := create_relation(&kernel, 2, "Reachable", 2)

	from := v.symbol_intern("from")
	to := v.symbol_intern("to")
	mid := v.symbol_intern("mid")

	base_rule := rule_new(
		reachable,
		[]Term{term_var(from), term_var(to)},
		[]Rule_Body_Item {
			body_atom(atom_positive(exit, []Term{term_var(from), term_var(to)})),
		},
	)
	recursive_rule := rule_new(
		reachable,
		[]Term{term_var(from), term_var(to)},
		[]Rule_Body_Item {
			body_atom(atom_positive(reachable, []Term{term_var(from), term_var(mid)})),
			body_atom(atom_positive(exit, []Term{term_var(mid), term_var(to)})),
		},
	)
	snapshot, base_err := kernel_install_rule(&kernel, v.Identity(1), base_rule, "base")
	testing.expect_value(t, base_err, Kernel_Error.None)
	snapshot_release(snapshot)
	recursive_snapshot, recursive_err := kernel_install_rule(
		&kernel,
		v.Identity(2),
		recursive_rule,
		"recursive",
	)
	testing.expect_value(t, recursive_err, Kernel_Error.None)
	snapshot_release(recursive_snapshot)

	// a->b, a->c, b->d, c->d, d->e, e->b. The b/d/e component is a cycle.
	a := must_identity(1)
	b := must_identity(2)
	c := must_identity(3)
	d := must_identity(4)
	e := must_identity(5)

	edges := [][2]v.Value{{a, b}, {a, c}, {b, d}, {c, d}, {d, e}, {e, b}}
	tx := kernel_begin(&kernel)
	for edge in edges {
		testing.expect_value(
			t,
			transaction_assert(&tx, exit, tuple_of(edge[0], edge[1])),
			Kernel_Error.None,
		)
	}
	commit_transaction(t, &tx)

	expected := [][2]v.Value {
		{a, b},
		{a, c},
		{a, d},
		{a, e},
		{b, b},
		{b, d},
		{b, e},
		{c, b},
		{c, d},
		{c, e},
		{d, b},
		{d, d},
		{d, e},
		{e, b},
		{e, d},
		{e, e},
	}

	rows := kernel_rows(&kernel, reachable, 2)
	testing.expect_value(t, len(rows), len(expected))
	for pair in expected {
		testing.expect(t, has_tuple(rows[:], tuple_of(pair[0], pair[1])))
	}
	delete(rows)
}

@(test)
test_event_append_ignores_retract_conflicts :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	set_relation := create_relation_with(
		&kernel,
		60,
		"SetRel",
		1,
		conflict_set(),
		nil,
	)
	append_relation := create_relation_with(
		&kernel,
		61,
		"AppendRel",
		1,
		conflict_event_append(),
		nil,
	)

	seed := kernel_begin(&kernel)
	testing.expect_value(
		t,
		transaction_assert(&seed, set_relation, tuple_of(must_int(1))),
		Kernel_Error.None,
	)
	testing.expect_value(
		t,
		transaction_assert(&seed, append_relation, tuple_of(must_int(1))),
		Kernel_Error.None,
	)
	commit_transaction(t, &seed)

	// A transaction that asserted a tuple in its base conflicts when another
	// transaction removed it first under the set policy.
	set_first := kernel_begin(&kernel)
	set_second := kernel_begin(&kernel)
	testing.expect_value(
		t,
		transaction_retract(&set_first, set_relation, tuple_of(must_int(1))),
		Kernel_Error.None,
	)
	testing.expect_value(
		t,
		transaction_assert(&set_second, set_relation, tuple_of(must_int(1))),
		Kernel_Error.None,
	)
	commit_transaction(t, &set_first)
	_, set_err := transaction_commit(&set_second)
	testing.expect_value(t, set_err, Kernel_Error.Conflict)
	transaction_destroy(&set_second)

	// The same sequence succeeds under the event-append policy.
	append_first := kernel_begin(&kernel)
	append_second := kernel_begin(&kernel)
	testing.expect_value(
		t,
		transaction_retract(
			&append_first,
			append_relation,
			tuple_of(must_int(1)),
		),
		Kernel_Error.None,
	)
	testing.expect_value(
		t,
		transaction_assert(
			&append_second,
			append_relation,
			tuple_of(must_int(1)),
		),
		Kernel_Error.None,
	)
	commit_transaction(t, &append_first)
	commit_transaction(t, &append_second)

	rows := kernel_rows(&kernel, append_relation, 1)
	defer delete(rows)
	testing.expect_value(t, len(rows), 1)
}

@(test)
test_rule_planner_prefers_selective_atom :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	big := create_relation(&kernel, 80, "Big", 2)
	small := create_relation(&kernel, 81, "Small", 1)
	head := create_relation(&kernel, 82, "Head", 1)

	tx := kernel_begin(&kernel)
	for index in 0 ..< 100 {
		testing.expect_value(
			t,
			transaction_assert(
				&tx,
				big,
				tuple_of(must_int(i64(index)), must_int(i64(index) + 1)),
			),
			Kernel_Error.None,
		)
	}
	testing.expect_value(
		t,
		transaction_assert(&tx, small, tuple_of(must_int(1))),
		Kernel_Error.None,
	)
	commit_transaction(t, &tx)

	x := v.symbol_intern("x")
	y := v.symbol_intern("y")
	rule := rule_new(
		head,
		[]Term{term_var(x)},
		[]Rule_Body_Item {
			body_atom(atom_positive(big, []Term{term_var(x), term_var(y)})),
			body_atom(atom_positive(small, []Term{term_var(y)})),
		},
	)
	slots: Slot_Map
	slot_map_init(&slots, rule, context.temp_allocator)
	batch := column_batch_unit(len(slots.symbols), context.temp_allocator)
	used := make([]bool, len(rule.body), context.temp_allocator)
	source := Relation_Source{snapshot = kernel.current}

	// Neither atom is bound, so the smaller relation drives the join.
	index, err := pick_body_item(rule, used, &batch, &slots, &source)
	testing.expect_value(t, err, Kernel_Error.None)
	testing.expect_value(t, index, 1)

	// Once Small binds y, Big remains the only unbound atom.
	used[1] = true
	column_batch_set(&batch, slot_map_slot(&slots, y), []v.Value{must_int(1)})
	index, err = pick_body_item(rule, used, &batch, &slots, &source)
	testing.expect_value(t, err, Kernel_Error.None)
	testing.expect_value(t, index, 0)
}

// slot_map_init must not leak the scratch symbol list it builds.
@(test)
test_slot_map_init_no_leak :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)

	rule := rule_new(Relation_ID(1), []Term{term_var(v.symbol_intern("x"))}, nil)
	mapping: Slot_Map

	previous := context.allocator
	context.allocator = alloc
	slot_map_init(&mapping, rule, alloc)
	context.allocator = previous

	// `mapping.symbols` is caller-owned; free it before checking for leaks.
	delete(mapping.symbols, alloc)
	testing.expectf(
		t,
		len(track.allocation_map) == 0,
		"slot_map_init leaked %d allocation(s)",
		len(track.allocation_map),
	)
}

// A transaction that makes no writes must not publish a new version. A
// read-only commit advancing the version makes read-only CLI evals grow the
// store on the shutdown checkpoint.
@(test)
test_replace_relation_block_replaces_and_owns_block :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	relation := create_relation(&kernel, 1, "Replaced", 2)

	// Seed a base block through the normal transaction path.
	tx := kernel_begin(&kernel)
	transaction_assert(&tx, relation, tuple_of(must_identity(1), must_identity(2)))
	commit_transaction(t, &tx)

	base := kernel_snapshot(&kernel)
	base_block, base_found := snapshot_relation_block(base, relation)
	testing.expect(t, base_found)
	testing.expect_value(t, relation_block_len(base_block), 1)
	snapshot_release(base)

	// Build a replacement block with two rows and publish it. The block is
	// owned by the kernel after the call; the caller must not release it.
	alloc := context.temp_allocator
	rows := make([]v.Tuple, 2, alloc)
	rows[0] = tuple_of(must_identity(10), must_identity(20))
	rows[1] = tuple_of(must_identity(11), must_identity(21))
	base_snapshot := kernel_snapshot(&kernel)
	metadata, _ := snapshot_relation_metadata(base_snapshot, relation)
	snapshot_release(base_snapshot)
	block := relation_block_build(alloc, metadata, rows)

	replaced, err := kernel_replace_relation_block(&kernel, block)
	testing.expect_value(t, err, Kernel_Error.None)
	if replaced != nil {
		new_block, new_found := snapshot_relation_block(replaced, relation)
		testing.expect(t, new_found)
		testing.expect_value(t, relation_block_len(new_block), 2)
		snapshot_release(replaced)
	}

	// The old block is gone; the new block is visible in a fresh snapshot.
	after := kernel_snapshot(&kernel)
	after_block, after_found := snapshot_relation_block(after, relation)
	testing.expect(t, after_found)
	testing.expect_value(t, relation_block_len(after_block), 2)
	snapshot_release(after)
}

@(test)
test_replace_relation_block_rejects_arity_mismatch :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	relation := create_relation(&kernel, 1, "ArityMismatch", 2)

	// A block with the wrong arity must be rejected.
	alloc := context.temp_allocator
	rows := make([]v.Tuple, 1, alloc)
	rows[0] = tuple_of(must_identity(1))
	wrong_arity_metadata := relation_metadata(relation, v.symbol_intern("ArityMismatch"), 1)
	block := relation_block_build(alloc, wrong_arity_metadata, rows)

	replaced, err := kernel_replace_relation_block(&kernel, block)
	testing.expect_value(t, err, Kernel_Error.Invalid_Metadata)
	testing.expect(t, replaced == nil)
	// The block was not adopted; the caller still owns it and must release it.
	relation_block_release(block)
}

@(test)
test_replace_relation_block_unknown_relation :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	create_relation(&kernel, 1, "Known", 2)

	// A block for an unregistered relation id must be rejected.
	alloc := context.temp_allocator
	rows := make([]v.Tuple, 1, alloc)
	rows[0] = tuple_of(must_identity(1), must_identity(2))
	unknown_metadata := relation_metadata(Relation_ID(99), v.symbol_intern("Unknown"), 2)
	block := relation_block_build(alloc, unknown_metadata, rows)

	replaced, err := kernel_replace_relation_block(&kernel, block)
	testing.expect_value(t, err, Kernel_Error.Unknown_Relation)
	testing.expect(t, replaced == nil)
	// The block was not adopted; the caller still owns it.
	relation_block_release(block)
}

 @(test)
test_read_only_commit_does_not_advance_version :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	before := kernel_snapshot(&kernel)
	before_version := before.version
	snapshot_release(before)

	tx := transaction_begin(&kernel)
	committed, err := transaction_commit(&tx)
	testing.expect_value(t, err, Kernel_Error.None)
	if committed != nil {
		testing.expect_value(t, committed.version, before_version)
		snapshot_release(committed)
	}
	transaction_destroy(&tx)
}

// #102 regression guard: staging k writes must not scan every prior entry.
// Before the per-relation bucket index, 100k distinct asserts took tens of
// seconds; the bound is loose enough for a slow machine but catches the
// quadratic path. The duplicate pair pins the last-write-wins semantics the
// index replaced.
@(test)
test_staging_scales_linearly_and_last_write_wins :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	relation := create_relation(&kernel, 1, "Staging", 2)

	dup := kernel_begin(&kernel)
	defer transaction_destroy(&dup)
	first := tuple_of(must_identity(1), must_identity(2))
	transaction_assert(&dup, relation, first)
	kind, found := transaction_effective_write(&dup, relation, first)
	testing.expect(t, found)
	testing.expect_value(t, kind, Write_Kind.Assert)
	transaction_retract(&dup, relation, first)
	kind, found = transaction_effective_write(&dup, relation, first)
	testing.expect(t, found)
	testing.expect_value(t, kind, Write_Kind.Retract)
	testing.expect_value(t, len(dup.writes), 1)
	if len(dup.writes) == 1 {
		testing.expect_value(t, len(dup.writes[0].entries), 1)
	}

	start := time.tick_now()
	tx := transaction_begin(&kernel)
	defer transaction_destroy(&tx)
	for i in 0 ..< 100_000 {
		left, left_ok := v.value_identity_raw(u64(i))
		right, right_ok := v.value_identity_raw(u64(i) + 1)
		testing.expect(t, left_ok && right_ok)
		if err := transaction_assert(&tx, relation, tuple_of(left, right)); err != .None {
			testing.fail_now(t, "staging failed before 100k writes")
		}
	}
	testing.expect_value(t, len(tx.writes), 1)
	if len(tx.writes) == 1 {
		testing.expect_value(t, len(tx.writes[0].entries), 100_000)
	}
	testing.expect(t, time.tick_since(start) < 5 * time.Second)
}

// #102 regression guard for functional relations: the key visibility check
// used to scan every prior staged entry as well. The bound is loose; the
// pre-index path took minutes at this size.
@(test)
test_functional_staging_scales_linearly :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	key_positions := []u16{0}
	relation := create_relation_with(
		&kernel,
		1,
		"Keyed",
		2,
		conflict_functional(key_positions),
		nil,
	)

	start := time.tick_now()
	tx := kernel_begin(&kernel)
	defer transaction_destroy(&tx)
	for i in 0 ..< 100_000 {
		key := must_identity(u64(i))
		value := must_identity(u64(i) + 100_000)
		if err := transaction_assert(&tx, relation, tuple_of(key, value)); err != .None {
			testing.fail_now(t, "functional staging failed before 100k writes")
		}
	}
	testing.expect(t, time.tick_since(start) < 5 * time.Second)

	// The staged tuple for a key is visible, a second value for the key is a
	// functional violation, and a retract followed by a new value works.
	first := tuple_of(must_identity(0), must_identity(100_000))
	if existing, found := transaction_tuple_for_key(
		&tx,
		relation,
		key_positions,
		[]v.Value{must_identity(0)},
	); found {
		testing.expect(t, v.tuple_eq(existing, first))
	} else {
		testing.fail_now(t, "staged key is not visible")
	}
	testing.expect_value(
		t,
		transaction_assert(&tx, relation, tuple_of(must_identity(0), must_identity(999_999))),
		Kernel_Error.Functional_Key_Violation,
	)
	transaction_retract(&tx, relation, first)
	if _, found := transaction_tuple_for_key(
		&tx,
		relation,
		key_positions,
		[]v.Value{must_identity(0)},
	); found {
		testing.fail_now(t, "retracted key is still visible")
	}
	replacement := tuple_of(must_identity(0), must_identity(999_999))
	testing.expect_value(t, transaction_assert(&tx, relation, replacement), Kernel_Error.None)
	if existing, found := transaction_tuple_for_key(
		&tx,
		relation,
		key_positions,
		[]v.Value{must_identity(0)},
	); found {
		testing.expect(t, v.tuple_eq(existing, replacement))
	} else {
		testing.fail_now(t, "replacement key is not visible")
	}
}

// A block's chunk arenas hold about the rows they store: each 128-row chunk
// used to take a pooled arena with a 64 KB first block (16x its data), which
// would make 17.9M derived rows cost ~9 GB.
@(test)
test_chunk_arenas_fit_their_rows :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)
	defer free_all(context.temp_allocator)
	ROWS :: 100_000
	rows := make([]v.Tuple, ROWS, context.temp_allocator)
	for r in 0 ..< ROWS {
		rows[r] = tuple_of(must_int(i64(r)), must_int(i64(r % 97)))
	}
	block := relation_block_build_pooled(&kernel, Relation_Metadata{id = 1, arity = 2}, rows)
	defer relation_block_release(block)
	capacity := 0
	for chunk in block.chunks {
		capacity += frame_arena_capacity(chunk.arena)
	}
	data := ROWS * (size_of(v.Tuple) + 2 * size_of(v.Value))
	testing.expectf(t, capacity <= data * 3 / 2, "chunk arenas hold %d bytes for %d of rows", capacity, data)
}


// kernel_scan_into releases the snapshot it scanned before returning, and a
// concurrent commit can then free that snapshot's chunks: the rows it returns
// are copies taken while the snapshot was held.
@(test)
test_kernel_scan_into_rows_outlive_the_snapshot :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)
	note := create_relation(&kernel, 1, "Note", 2)
	tx := kernel_begin(&kernel)
	transaction_assert(&tx, note, tuple_of(must_int(1), v.value_string(context.temp_allocator, "scanned-text")))
	commit_transaction(t, &tx)

	block, _ := snapshot_relation_block(kernel.current, note)
	stored, _ := v.value_as_string(v.tuple_values(relation_block_row(block, 0))[1])
	rows: [dynamic]v.Tuple
	defer delete(rows)
	kernel_scan_into(&kernel, note, []v.Binding{{}, {}}, &rows)
	testing.expect_value(t, len(rows), 1)
	if len(rows) != 1 {
		return
	}
	scanned, _ := v.value_as_string(v.tuple_values(rows[0])[1])
	testing.expect(t, scanned == "scanned-text")
	testing.expect(t, raw_data(scanned) != raw_data(stored))
}
