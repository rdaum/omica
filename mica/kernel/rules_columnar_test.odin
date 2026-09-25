package kernel

import "core:mem"
import "core:mem/virtual"
import "core:sync"
import accel "./accel"
import "core:testing"
import v "../var"

@(private = "file")
evaluate_rows :: proc(t: ^testing.T, kernel: ^Kernel, source: ^Relation_Source, relation: Relation_ID) -> (rows: []v.Tuple, err: Kernel_Error) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	alloc := virtual.arena_allocator(&arena)
	result := rules_derived_create(alloc)
	source.derived = &result
	err = rules_evaluate_source(alloc, kernel.current.rules, source, &result)
	rows = rules_derived_tuples(&result, relation, context.temp_allocator)
	source.derived = nil
	return
}

@(private = "file")
install :: proc(t: ^testing.T, kernel: ^Kernel, id: u64, rule: Rule) {
	snapshot, err := kernel_install_rule(kernel, v.Identity(id), rule, "columnar test")
	testing.expect_value(t, err, Kernel_Error.None)
	snapshot_release(snapshot)
}

// Review Focus 1: a scanner that ignores its binding and returns every
// candidate; the index path re-checks keys with value_eq.
@(test)
test_columnar_computed_candidates_rechecked :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)
	item := create_relation(&kernel, 1, "Item", 1)
	candidates := create_relation(&kernel, 2, "Candidates", 1)
	out := create_relation(&kernel, 3, "Out", 1)
	testing.expect_value(t, kernel_register_computed_relation(&kernel, candidates, []u16{0},
		proc(user: rawptr, source: ^Relation_Source, bindings: []v.Binding, visit: Computed_Visit_Proc, visit_user: rawptr) -> Kernel_Error {
			for n in 1 ..= 4 {
				value, _ := v.value_int(i64(n))
				visit(visit_user, v.tuple_new(context.temp_allocator, []v.Value{value}))
			}
			return .None
		}), Kernel_Error.None)
	x := v.symbol_intern("x")
	install(t, &kernel, 900, rule_new(out, []Term{term_var(x)}, []Rule_Body_Item {
		body_atom(atom_positive(item, []Term{term_var(x)})),
		body_atom(atom_positive(candidates, []Term{term_var(x)})),
	}))
	tx := kernel_begin(&kernel)
	transaction_assert(&tx, item, tuple_of(must_int(2)))
	transaction_assert(&tx, item, tuple_of(must_int(9)))
	commit_transaction(t, &tx)
	source := Relation_Source{kernel = &kernel, snapshot = kernel.current}
	rows, err := evaluate_rows(t, &kernel, &source, out)
	testing.expect_value(t, err, Kernel_Error.None)
	testing.expect_value(t, len(rows), 1)
	testing.expect(t, has_tuple(rows, tuple_of(must_int(2))))
}

// Review Focus 2.
@(test)
test_columnar_zero_arity_head :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)
	item := create_relation(&kernel, 1, "Item", 1)
	flag := create_relation(&kernel, 2, "Flag", 0)
	x := v.symbol_intern("x")
	install(t, &kernel, 901, rule_new(flag, nil, []Rule_Body_Item{body_atom(atom_positive(item, []Term{term_var(x)}))}))
	tx := kernel_begin(&kernel)
	for i in 1 ..= 40 {
		transaction_assert(&tx, item, tuple_of(must_int(i64(i))))
	}
	commit_transaction(t, &tx)
	testing.expect_value(t, len(snapshot_derived_rows(kernel.current, flag)), 1)
}

// Review Focus 3.
@(test)
test_columnar_permission_denied_in_body :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)
	item := create_relation(&kernel, 1, "Item", 1)
	held := create_relation(&kernel, 2, "Held", 1)
	free := create_relation(&kernel, 3, "Free", 1)
	x := v.symbol_intern("x")
	install(t, &kernel, 902, rule_new(free, []Term{term_var(x)}, []Rule_Body_Item {
		body_atom(atom_positive(item, []Term{term_var(x)})),
		body_atom(atom_negated(held, []Term{term_var(x)})),
	}))
	tx := kernel_begin(&kernel)
	transaction_assert(&tx, item, tuple_of(must_int(1)))
	commit_transaction(t, &tx)

	authority := Authority{allocator = context.allocator}
	authority.read = make(map[Relation_ID]bool, context.temp_allocator)
	authority.read[item] = true // Held is unreadable
	source := Relation_Source{kernel = &kernel, snapshot = kernel.current, authority = &authority}
	_, err := evaluate_rows(t, &kernel, &source, free)
	testing.expect_value(t, err, Kernel_Error.Permission_Denied)

	delete_key(&authority.read, item) // now the positive atom is unreadable too
	source = Relation_Source{kernel = &kernel, snapshot = kernel.current, authority = &authority}
	_, err = evaluate_rows(t, &kernel, &source, free)
	testing.expect_value(t, err, Kernel_Error.Permission_Denied)
}

// Review Focus 4: Item is empty, so the batch empties before Even (whose key
// Item would bind) runs; like the row evaluator, no error and no rows.
@(test)
test_columnar_empty_batch_skips_remaining_steps :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)
	item := create_relation(&kernel, 1, "Item", 1)
	even := create_relation(&kernel, 2, "Even", 1)
	out := create_relation(&kernel, 3, "Out", 1)
	testing.expect_value(t, kernel_register_computed_relation(&kernel, even, []u16{0},
		proc(user: rawptr, source: ^Relation_Source, bindings: []v.Binding, visit: Computed_Visit_Proc, visit_user: rawptr) -> Kernel_Error {
			return .None
		}), Kernel_Error.None)
	x := v.symbol_intern("x")
	install(t, &kernel, 903, rule_new(out, []Term{term_var(x)}, []Rule_Body_Item {
		body_atom(atom_positive(item, []Term{term_var(x)})),
		body_atom(atom_positive(even, []Term{term_var(x)})),
	}))
	source := Relation_Source{kernel = &kernel, snapshot = kernel.current}
	rows, err := evaluate_rows(t, &kernel, &source, out)
	testing.expect_value(t, err, Kernel_Error.None)
	testing.expect_value(t, len(rows), 0)
}

// Review Focus 5: heap-value keys are Not_Packable and take the hashed path;
// equal strings from distinct allocations negate each other.
@(test)
test_columnar_negation_heap_values :: proc(t: ^testing.T) {
	sync.mutex_lock(&strategy_tests_lock)
	defer sync.mutex_unlock(&strategy_tests_lock)
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)
	name := create_relation(&kernel, 1, "Name", 1)
	banned := create_relation(&kernel, 2, "Banned", 1)
	ok := create_relation(&kernel, 3, "Ok", 1)
	x := v.symbol_intern("x")
	install(t, &kernel, 904, rule_new(ok, []Term{term_var(x)}, []Rule_Body_Item {
		body_atom(atom_positive(name, []Term{term_var(x)})),
		body_atom(atom_negated(banned, []Term{term_var(x)})),
	}))
	before := placement_counts_this_thread()
	tx := kernel_begin(&kernel)
	transaction_assert(&tx, name, tuple_of(v.value_string(context.temp_allocator, "ann")))
	transaction_assert(&tx, name, tuple_of(v.value_string(context.temp_allocator, "bob")))
	transaction_assert(&tx, banned, tuple_of(v.value_string(context.temp_allocator, "bob")))
	commit_transaction(t, &tx)
	delta := placement_counts_delta(before, placement_counts_this_thread())
	testing.expect(t, delta[.Negated_Membership][.Not_Packable] >= 1)
	rows := snapshot_derived_rows(kernel.current, ok)
	testing.expect_value(t, len(rows), 1)
	testing.expect(t, has_tuple(rows, tuple_of(v.value_string(context.temp_allocator, "ann"))))
}

// A join keyed on a bound slot gives the same rows on the hash-join and the
// per-row index path.
@(test)
test_columnar_join_paths_agree :: proc(t: ^testing.T) {
	sync.mutex_lock(&strategy_tests_lock)
	defer sync.mutex_unlock(&strategy_tests_lock)
	defer free_all(context.temp_allocator)
	previous := rules_small_batch_rows
	defer rules_small_batch_rows = previous
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)
	edge := create_relation(&kernel, 1, "Edge", 2)
	two := create_relation(&kernel, 2, "Two", 2)
	x, y, z := v.symbol_intern("x"), v.symbol_intern("y"), v.symbol_intern("z")
	install(t, &kernel, 905, rule_new(two, []Term{term_var(x), term_var(z)}, []Rule_Body_Item {
		body_atom(atom_positive(edge, []Term{term_var(x), term_var(y)})),
		body_atom(atom_positive(edge, []Term{term_var(y), term_var(z)})),
	}))
	tx := kernel_begin(&kernel)
	for i in 0 ..< 60 {
		transaction_assert(&tx, edge, tuple_of(must_int(i64(i % 20)), must_int(i64((i * 7) % 20))))
	}
	commit_transaction(t, &tx)
	want := len(snapshot_derived_rows(kernel.current, two))
	testing.expect(t, want > 0)
	for threshold in ([]int{0, max(int)}) {
		rules_small_batch_rows = threshold
		source := Relation_Source{kernel = &kernel, snapshot = kernel.current}
		rows, err := evaluate_rows(t, &kernel, &source, two)
		testing.expect_value(t, err, Kernel_Error.None)
		testing.expect_value(t, len(rows), want)
	}
}

@(private = "file")
Hidden_User :: struct {
	hidden: Relation_ID,
}

// A computed relation whose scanner reads a backing relation the authority
// cannot read reports the denial only through source.error; the columnar scan
// must surface it, for positive and negated atoms alike (the row evaluator
// checked source.error after every visit).
@(test)
test_columnar_nested_denial_in_computed_scanner :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for negated in ([]bool{false, true}) {
		kernel: Kernel
		kernel_init(&kernel)
		item := create_relation(&kernel, 1, "Item", 1)
		hidden := create_relation(&kernel, 2, "Hidden", 1)
		c := create_relation(&kernel, 3, "C", 1)
		out := create_relation(&kernel, 4, "Out", 1)
		user := new(Hidden_User, context.temp_allocator)
		user.hidden = hidden
		testing.expect_value(t, kernel_register_computed_relation(&kernel, c, nil,
			proc(u: rawptr, source: ^Relation_Source, bindings: []v.Binding, visit: Computed_Visit_Proc, visit_user: rawptr) -> Kernel_Error {
				rows := make([dynamic]v.Tuple, context.temp_allocator)
				relation_source_scan_into(source, (^Hidden_User)(u).hidden, []v.Binding{{}}, &rows)
				for row in rows {
					visit(visit_user, row)
				}
				return .None
			}, user), Kernel_Error.None)
		x := v.symbol_intern("x")
		atom := negated ? atom_negated(c, []Term{term_var(x)}) : atom_positive(c, []Term{term_var(x)})
		install(t, &kernel, 906, rule_new(out, []Term{term_var(x)}, []Rule_Body_Item {
			body_atom(atom_positive(item, []Term{term_var(x)})),
			body_atom(atom),
		}))
		tx := kernel_begin(&kernel)
		transaction_assert(&tx, item, tuple_of(must_int(1)))
		transaction_assert(&tx, hidden, tuple_of(must_int(1)))
		commit_transaction(t, &tx)

		authority := Authority{allocator = context.allocator}
		authority.read = make(map[Relation_ID]bool, context.temp_allocator)
		authority.read[item] = true
		authority.read[c] = true
		source := Relation_Source{kernel = &kernel, snapshot = kernel.current, authority = &authority}
		_, err := evaluate_rows(t, &kernel, &source, out)
		testing.expectf(t, err == .Permission_Denied, "negated=%v: got %v", negated, err)
		kernel_destroy(&kernel)
	}
}

@(private = "file")
Join_Fixture :: struct {
	kernel:    Kernel,
	out, out2: Relation_ID,
}

// A(x,y) 300 rows, B(y,z) 200 rows with duplicate y on both sides, Hidden(x)
// every third x; Out(x,z) :- A(x,y), B(y,z) and Out2(x,z) :- A(x,y),
// not Hidden(x), B(y,z) (the negation leaves a selection before the join).
@(private = "file")
join_fixture :: proc(t: ^testing.T, f: ^Join_Fixture) {
	kernel_init(&f.kernel)
	a := create_relation(&f.kernel, 1, "A", 2)
	b := create_relation(&f.kernel, 2, "B", 2)
	hidden := create_relation(&f.kernel, 3, "Hidden", 1)
	f.out = create_relation(&f.kernel, 4, "Out", 2)
	f.out2 = create_relation(&f.kernel, 5, "Out2", 2)
	x, y, z := v.symbol_intern("x"), v.symbol_intern("y"), v.symbol_intern("z")
	install(t, &f.kernel, 910, rule_new(f.out, []Term{term_var(x), term_var(z)}, []Rule_Body_Item {
		body_atom(atom_positive(a, []Term{term_var(x), term_var(y)})),
		body_atom(atom_positive(b, []Term{term_var(y), term_var(z)})),
	}))
	install(t, &f.kernel, 911, rule_new(f.out2, []Term{term_var(x), term_var(z)}, []Rule_Body_Item {
		body_atom(atom_positive(a, []Term{term_var(x), term_var(y)})),
		body_atom(atom_negated(hidden, []Term{term_var(x)})),
		body_atom(atom_positive(b, []Term{term_var(y), term_var(z)})),
	}))
	tx := kernel_begin(&f.kernel)
	for i in 0 ..< 300 {
		transaction_assert(&tx, a, tuple_of(must_identity(u64(1000 + i)), must_int(i64(i % 40))))
		if i % 3 == 0 {
			transaction_assert(&tx, hidden, tuple_of(must_identity(u64(1000 + i))))
		}
	}
	for j in 0 ..< 200 {
		transaction_assert(&tx, b, tuple_of(must_int(i64(j % 50)), must_identity(u64(5000 + j))))
	}
	commit_transaction(t, &tx)
}

@(private = "file")
expect_same_rows :: proc(t: ^testing.T, got, want: []v.Tuple, loc := #caller_location) {
	testing.expect_value(t, len(got), len(want), loc = loc)
	for row in got {
		testing.expect(t, has_tuple(want, row), loc = loc)
	}
}

@(test)
test_positive_join_accelerated_matches_hash_join :: proc(t: ^testing.T) {
	sync.mutex_lock(&strategy_tests_lock)
	defer sync.mutex_unlock(&strategy_tests_lock)
	defer accel.use_cpu()
	defer free_all(context.temp_allocator)
	f: Join_Fixture
	join_fixture(t, &f)
	defer kernel_destroy(&f.kernel)

	accel.use_cpu()
	before := placement_counts_this_thread()
	source := Relation_Source{kernel = &f.kernel, snapshot = f.kernel.current}
	want, _ := evaluate_rows(t, &f.kernel, &source, f.out)
	want2, _ := evaluate_rows(t, &f.kernel, &source, f.out2)
	reference := placement_counts_delta(before, placement_counts_this_thread())
	testing.expect(t, len(want) > 0 && len(want2) > 0)
	for outcome in Placement_Outcome {
		testing.expect_value(t, reference[.Positive_Join][outcome], 0)
	}

	s := accel.cpu_strategy()
	s.join_min_probes = 1
	accel.select_strategy(s)
	before = placement_counts_this_thread()
	got, err := evaluate_rows(t, &f.kernel, &source, f.out)
	got2, err2 := evaluate_rows(t, &f.kernel, &source, f.out2)
	delta := placement_counts_delta(before, placement_counts_this_thread())
	testing.expect_value(t, err, Kernel_Error.None)
	testing.expect_value(t, err2, Kernel_Error.None)
	expect_same_rows(t, got, want)
	expect_same_rows(t, got2, want2)
	testing.expect(t, delta[.Positive_Join][.Completed] >= 2)
}

@(test)
test_positive_join_invalid_result_falls_back :: proc(t: ^testing.T) {
	sync.mutex_lock(&strategy_tests_lock)
	defer sync.mutex_unlock(&strategy_tests_lock)
	defer accel.use_cpu()
	defer free_all(context.temp_allocator)
	f: Join_Fixture
	join_fixture(t, &f)
	defer kernel_destroy(&f.kernel)

	accel.use_cpu()
	source := Relation_Source{kernel = &f.kernel, snapshot = f.kernel.current}
	want, _ := evaluate_rows(t, &f.kernel, &source, f.out)

	s := accel.cpu_strategy()
	s.join_min_probes = 1
	s.join_equality = proc(left, right: [][]u64, right_rows: []u32, allocator: mem.Allocator) -> ([]u32, []u32, bool) {
		l := make([]u32, 1, allocator)
		r := make([]u32, 1, allocator)
		l[0] = u32(len(left[0])) // out of range
		return l, r, true
	}
	accel.select_strategy(s)
	before := placement_counts_this_thread()
	got, err := evaluate_rows(t, &f.kernel, &source, f.out)
	delta := placement_counts_delta(before, placement_counts_this_thread())
	testing.expect_value(t, err, Kernel_Error.None)
	expect_same_rows(t, got, want)
	testing.expect(t, delta[.Positive_Join][.Invalid_Result] >= 1)
	testing.expect(t, delta[.Positive_Join][.Cpu_Fallback] >= 1)
}

// A relation that grows within its stratum on the relation side of a forced
// join: P and Q are mutually recursive, so the delta variant restricting P
// reads Q whole (and growing). Cached sorted keys must follow its row count;
// both closures are complete on the CPU hash join and the forced join.
@(test)
test_positive_join_growing_relation_side :: proc(t: ^testing.T) {
	sync.mutex_lock(&strategy_tests_lock)
	defer sync.mutex_unlock(&strategy_tests_lock)
	defer accel.use_cpu()
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)
	e := create_relation(&kernel, 1, "E", 2)
	p := create_relation(&kernel, 2, "P", 2)
	q := create_relation(&kernel, 3, "Q", 2)
	x, y, z := v.symbol_intern("x"), v.symbol_intern("y"), v.symbol_intern("z")
	X, Y, Z := term_var(x), term_var(y), term_var(z)
	install(t, &kernel, 920, rule_new(p, []Term{X, Y}, []Rule_Body_Item{body_atom(atom_positive(e, []Term{X, Y}))}))
	install(t, &kernel, 921, rule_new(q, []Term{X, Y}, []Rule_Body_Item{body_atom(atom_positive(e, []Term{X, Y}))}))
	install(t, &kernel, 922, rule_new(p, []Term{X, Z}, []Rule_Body_Item {
		body_atom(atom_positive(p, []Term{X, Y})),
		body_atom(atom_positive(q, []Term{Y, Z})),
	}))
	install(t, &kernel, 923, rule_new(q, []Term{X, Z}, []Rule_Body_Item {
		body_atom(atom_positive(q, []Term{X, Y})),
		body_atom(atom_positive(p, []Term{Y, Z})),
	}))
	N :: 30
	tx := kernel_begin(&kernel)
	for i in 0 ..< N - 1 {
		transaction_assert(&tx, e, tuple_of(must_identity(u64(100 + i)), must_identity(u64(101 + i))))
	}
	commit_transaction(t, &tx)
	closure := N * (N - 1) / 2

	for forced in ([]bool{false, true}) {
		s := accel.cpu_strategy()
		if forced {
			s.join_min_probes = 1
		}
		accel.select_strategy(s)
		before := placement_counts_this_thread()
		source := Relation_Source{kernel = &kernel, snapshot = kernel.current}
		prows, perr := evaluate_rows(t, &kernel, &source, p)
		qrows, qerr := evaluate_rows(t, &kernel, &source, q)
		delta := placement_counts_delta(before, placement_counts_this_thread())
		testing.expect_value(t, perr, Kernel_Error.None)
		testing.expect_value(t, qerr, Kernel_Error.None)
		testing.expectf(t, len(prows) == closure && len(qrows) == closure, "forced=%v: P %d Q %d rows, want %d", forced, len(prows), len(qrows), closure)
		if forced {
			testing.expect(t, delta[.Positive_Join][.Completed] > 0)
		}
	}
}

// Two atoms of the same recursive relation: each delta variant restricts one
// occurrence to the previous round's rows and reads the other whole. A chain
// of 41 nodes has 41*40/2 = 820 paths.
@(test)
test_recursion_two_atoms_same_relation :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)
	e := create_relation(&kernel, 1, "E", 2)
	path := create_relation(&kernel, 2, "T", 2)
	x, y, z := v.symbol_intern("x"), v.symbol_intern("y"), v.symbol_intern("z")
	X, Y, Z := term_var(x), term_var(y), term_var(z)
	install(t, &kernel, 930, rule_new(path, []Term{X, Y}, []Rule_Body_Item{body_atom(atom_positive(e, []Term{X, Y}))}))
	install(t, &kernel, 931, rule_new(path, []Term{X, Z}, []Rule_Body_Item {
		body_atom(atom_positive(path, []Term{X, Y})),
		body_atom(atom_positive(path, []Term{Y, Z})),
	}))
	tx := kernel_begin(&kernel)
	for i in 0 ..< 40 {
		transaction_assert(&tx, e, tuple_of(must_int(i64(i)), must_int(i64(i + 1))))
	}
	commit_transaction(t, &tx)
	testing.expect_value(t, len(snapshot_derived_rows(kernel.current, path)), 820)
}

// Strict semi-naive: every round reads the previous round's frozen result, so
// a chain of 20 nodes takes the seed pass (length-1 paths), one round per
// further length (18), and a final round that derives nothing: 20 rounds.
@(test)
test_strict_semi_naive_rounds :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)
	e := create_relation(&kernel, 1, "Edge", 2)
	path := create_relation(&kernel, 2, "Path", 2)
	x, y, z := v.symbol_intern("x"), v.symbol_intern("y"), v.symbol_intern("z")
	X, Y, Z := term_var(x), term_var(y), term_var(z)
	install(t, &kernel, 940, rule_new(path, []Term{X, Y}, []Rule_Body_Item{body_atom(atom_positive(e, []Term{X, Y}))}))
	install(t, &kernel, 941, rule_new(path, []Term{X, Z}, []Rule_Body_Item {
		body_atom(atom_positive(path, []Term{X, Y})),
		body_atom(atom_positive(e, []Term{Y, Z})),
	}))
	tx := kernel_begin(&kernel)
	for i in 0 ..< 19 {
		transaction_assert(&tx, e, tuple_of(must_int(i64(i)), must_int(i64(i + 1))))
	}
	commit_transaction(t, &tx)
	source := Relation_Source{kernel = &kernel, snapshot = kernel.current}
	rows, err := evaluate_rows(t, &kernel, &source, path)
	testing.expect_value(t, err, Kernel_Error.None)
	testing.expect_value(t, len(rows), 190)
	testing.expect_value(t, rules_last_evaluation_rounds(), 20)
}

// Semi-naive rounds keep only the previous round's delta: a long chain runs
// hundreds of rounds, and every round's delta held in the evaluation arena
// until the end added a second copy of every derived row (the full OpenCyc
// derivation held 3.5 GB for 17.9M rows).
@(test)
test_rounds_release_old_deltas :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)
	e := create_relation(&kernel, 1, "E", 2)
	path := create_relation(&kernel, 2, "T", 2)
	x, y, z := v.symbol_intern("x"), v.symbol_intern("y"), v.symbol_intern("z")
	X, Y, Z := term_var(x), term_var(y), term_var(z)
	install(t, &kernel, 940, rule_new(path, []Term{X, Y}, []Rule_Body_Item{body_atom(atom_positive(e, []Term{X, Y}))}))
	install(t, &kernel, 941, rule_new(path, []Term{X, Z}, []Rule_Body_Item {
		body_atom(atom_positive(e, []Term{X, Y})),
		body_atom(atom_positive(path, []Term{Y, Z})),
	}))
	NODES :: 300
	tx := kernel_begin(&kernel)
	for i in 0 ..< NODES - 1 {
		transaction_assert(&tx, e, tuple_of(must_int(i64(i)), must_int(i64(i + 1))))
	}
	commit_transaction(t, &tx)

	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		testing.fail_now(t, "arena init failed")
	}
	defer virtual.arena_destroy(&arena)
	derived, err := rules_evaluate(virtual.arena_allocator(&arena), kernel.current.rules, kernel.current, &kernel)
	testing.expect_value(t, err, Kernel_Error.None)
	rows := rules_derived_count(&derived, path)
	testing.expect_value(t, rows, NODES * (NODES - 1) / 2)
	entry := rules_derived_find(&derived, path)
	live := rows * (2 * size_of(v.Value) + size_of(u64)) + len(entry.index) * size_of(u32)
	testing.expectf(t, int(arena.total_used) < 3 * live, "evaluation arena holds %d bytes (%.2fx) for %d live", arena.total_used, f64(arena.total_used) / f64(live), live)
}

// Derived relations are blocks: a commit that changes nothing a rule reads
// shares the base snapshot's derived block; one that changes an input gets a
// new block with the new rows; derived rows never enter snapshot.blocks.
@(test)
test_derived_blocks_shared_until_inputs_change :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)
	e := create_relation(&kernel, 1, "E", 2)
	other := create_relation(&kernel, 3, "Other", 1)
	path := create_relation(&kernel, 2, "T", 2)
	x, y, z := v.symbol_intern("x"), v.symbol_intern("y"), v.symbol_intern("z")
	X, Y, Z := term_var(x), term_var(y), term_var(z)
	install(t, &kernel, 950, rule_new(path, []Term{X, Y}, []Rule_Body_Item{body_atom(atom_positive(e, []Term{X, Y}))}))
	install(t, &kernel, 951, rule_new(path, []Term{X, Z}, []Rule_Body_Item {
		body_atom(atom_positive(e, []Term{X, Y})),
		body_atom(atom_positive(path, []Term{Y, Z})),
	}))
	tx := kernel_begin(&kernel)
	for i in 0 ..< 3 {
		transaction_assert(&tx, e, tuple_of(must_int(i64(i)), must_int(i64(i + 1))))
	}
	commit_transaction(t, &tx)
	first, ok := snapshot_derived_block(kernel.current, path)
	testing.expect(t, ok)
	testing.expect_value(t, relation_block_len(first), 6)
	_, in_blocks := snapshot_relation_block(kernel.current, path)
	testing.expect(t, !in_blocks)

	tx = kernel_begin(&kernel)
	transaction_assert(&tx, other, tuple_of(must_int(9)))
	commit_transaction(t, &tx)
	second, _ := snapshot_derived_block(kernel.current, path)
	testing.expect(t, second == first)

	tx = kernel_begin(&kernel)
	transaction_assert(&tx, e, tuple_of(must_int(3), must_int(4)))
	commit_transaction(t, &tx)
	third, _ := snapshot_derived_block(kernel.current, path)
	testing.expect(t, third != first)
	testing.expect_value(t, relation_block_len(third), 10)
	testing.expect_value(t, len(snapshot_derived_rows(kernel.current, path)), 10)
}

// A derived relation that loses all its rows has no rows in the next
// snapshot, not the base's.
@(test)
test_derived_block_emptied_by_retract :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)
	e := create_relation(&kernel, 1, "E", 2)
	path := create_relation(&kernel, 2, "T", 2)
	x, y := v.symbol_intern("x"), v.symbol_intern("y")
	install(t, &kernel, 952, rule_new(path, []Term{term_var(x), term_var(y)}, []Rule_Body_Item{body_atom(atom_positive(e, []Term{term_var(x), term_var(y)}))}))
	row := tuple_of(must_int(1), must_int(2))
	tx := kernel_begin(&kernel)
	transaction_assert(&tx, e, row)
	commit_transaction(t, &tx)
	testing.expect_value(t, len(snapshot_derived_rows(kernel.current, path)), 1)
	tx = kernel_begin(&kernel)
	transaction_retract(&tx, e, row)
	commit_transaction(t, &tx)
	testing.expect_value(t, len(snapshot_derived_rows(kernel.current, path)), 0)
	testing.expect(t, !snapshot_contains(kernel.current, path, row))
}

// A relation with asserted and derived rows: scans with a bound column and
// snapshot_contains see both kinds, through the derived block.
@(test)
test_scan_sees_asserted_and_derived_block_rows :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)
	e := create_relation(&kernel, 1, "E", 2)
	path := create_relation(&kernel, 2, "T", 2)
	x, y := v.symbol_intern("x"), v.symbol_intern("y")
	install(t, &kernel, 953, rule_new(path, []Term{term_var(x), term_var(y)}, []Rule_Body_Item{body_atom(atom_positive(e, []Term{term_var(x), term_var(y)}))}))
	tx := kernel_begin(&kernel)
	transaction_assert(&tx, e, tuple_of(must_int(1), must_int(2)))
	transaction_assert(&tx, path, tuple_of(must_int(1), must_int(5)))
	commit_transaction(t, &tx)
	_, has_derived := snapshot_derived_block(kernel.current, path)
	testing.expect(t, has_derived)
	source := Relation_Source{kernel = &kernel, snapshot = kernel.current, use_stored_derived = true}
	rows: [dynamic]v.Tuple
	defer delete(rows)
	relation_source_scan_into(&source, path, []v.Binding{v.binding_of(must_int(1)), {}}, &rows)
	testing.expect_value(t, len(rows), 2)
	testing.expect(t, snapshot_contains(kernel.current, path, tuple_of(must_int(1), must_int(2))))
	testing.expect(t, snapshot_contains(kernel.current, path, tuple_of(must_int(1), must_int(5))))
}
