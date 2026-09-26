package store

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import k "../kernel"
import v "../var"

@(private)
round_trip :: proc(t: ^testing.T, value: v.Value) {
	out: [dynamic]u8
	defer delete(out)
	encode_error := codec_encode_value(&out, value)
	testing.expectf(t, encode_error == .None, "encode failed: %v", encode_error)
	if encode_error != .None {
		return
	}
	cursor := 0
	decoded, decode_error := codec_decode_value(out[:], &cursor, context.temp_allocator)
	testing.expectf(t, decode_error == .None, "decode failed: %v", decode_error)
	if decode_error != .None {
		return
	}
	testing.expectf(t, v.value_eq(value, decoded), "value mismatch")
}

@(test)
test_codec_round_trip :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	round_trip(t, v.value_bool(true))
	integer, _ := v.value_int(-123456)
	round_trip(t, integer)
	float, _ := v.value_float(1.5)
	round_trip(t, float)
	identity, _ := v.value_identity_raw(0x1000)
	round_trip(t, identity)
	round_trip(t, v.value_symbol(v.symbol_intern("example")))
	round_trip(t, v.value_error_code(v.symbol_intern("E_TEST")))
	round_trip(t, v.value_string(context.temp_allocator, "hello \u00e9"))
	bytes := []u8{1, 2, 3, 255}
	round_trip(t, v.value_bytes(context.temp_allocator, bytes))

	list := v.value_list(context.temp_allocator, []v.Value{v.value_bool(false), v.value_symbol(v.symbol_intern("x"))})
	round_trip(t, list)
	one, _ := v.value_int(1)
	two, _ := v.value_int(2)
	map_value := v.value_map(context.temp_allocator, []v.Map_Entry{
		{key = v.value_symbol(v.symbol_intern("a")), value = one},
		{key = v.value_symbol(v.symbol_intern("b")), value = two},
	})
	round_trip(t, map_value)
	range_value := v.value_range(context.temp_allocator, one, two, true)
	round_trip(t, range_value)
	error_value := v.value_error(
		context.temp_allocator,
		v.symbol_intern("E_BAD"),
		"bad thing",
		true,
		one,
		true,
	)
	round_trip(t, error_value)
	frob := v.value_frob(context.temp_allocator, v.Identity(0x2000), two)
	round_trip(t, frob)

	heading := []v.Symbol{v.symbol_intern("a"), v.symbol_intern("b")}
	rows := []v.Tuple{v.tuple_new(context.temp_allocator, []v.Value{one, two})}
	relation, relation_error := v.value_relation(context.temp_allocator, heading, rows)
	testing.expect_value(t, relation_error, v.Relation_Value_Error.None)
	round_trip(t, relation)
	round_trip(t, v.value_empty_relation())
}

@(test)
test_codec_rejects_non_persistable :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	out: [dynamic]u8
	defer delete(out)
	capability, capability_ok := v.value_capability_raw(1)
	testing.expect(t, capability_ok)
	testing.expect_value(t, codec_encode_value(&out, capability), Codec_Error.Not_Persistable)
}

// A corrupt element count must be rejected before it drives a huge
// allocation. Regression: length prefixes were trusted.
@(test)
test_codec_count_bound :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	data := make([]u8, 16, context.temp_allocator)
	reader := Codec_Reader{data = data, cursor = 0}

	// A count larger than the bytes remaining is rejected.
	testing.expect(t, !codec_count_allowed(&reader, 0xffff_ffff, 1))
	testing.expect(t, !codec_count_allowed(&reader, 17, 1))
	testing.expect(t, codec_count_allowed(&reader, 16, 1))

	// A larger per-element minimum tightens the bound.
	testing.expect(t, !codec_count_allowed(&reader, 5, 4))
	testing.expect(t, codec_count_allowed(&reader, 4, 4))

	// A corrupt encoded count decodes as truncated, not a giant allocation.
	one, _ := v.value_int(1)
	list := v.value_list(context.temp_allocator, []v.Value{one})
	out: [dynamic]u8
	defer delete(out)
	testing.expect_value(t, codec_encode_value(&out, list), Codec_Error.None)
	// Claim more elements than the payload can hold.
	out[1] = 0x08
	out[2] = 0
	out[3] = 0
	out[4] = 0
	cursor := 0
	_, decode_error := codec_decode_value(out[:], &cursor, context.temp_allocator)
	testing.expect_value(t, decode_error, Codec_Error.Truncated)
}

@(test)
test_store_admission_budget :: proc(t: ^testing.T) {
	store: Store
	store_init(&store, Store_Options{budget_bytes = 100, timeout = 20 * time.Millisecond})
	defer store_destroy(&store)

	first, first_ok := store_admit_hook(&store, 80)
	testing.expect(t, first_ok)
	testing.expect(t, first != 0)

	// The budget is exhausted; a second reservation times out.
	_, second_ok := store_admit_hook(&store, 80)
	testing.expect(t, !second_ok)

	// Releasing the first reservation makes room again.
	store_release_hook(&store, first)
	third, third_ok := store_admit_hook(&store, 80)
	testing.expect(t, third_ok)
	store_release_hook(&store, third)
	testing.expect_value(t, store_reserved_bytes(&store), i64(0))
}

// A version that published nothing durable must still be covered once the
// writes queued ahead of it drain. Regression: `covered` was only advanced
// when the queue was already empty, so `wait_durable` on the empty version
// blocked forever.
@(test)
test_store_empty_publish_covered_after_drain :: proc(t: ^testing.T) {
	store: Store
	store_init(&store, Store_Options{})
	defer store_destroy(&store)

	// A durable write at version 1 is queued and still in flight.
	sync.mutex_lock(&store.lock)
	append(&store.queue, Queue_Entry{version = 1, bytes = 4})
	store.reserved_bytes = 4
	sync.mutex_unlock(&store.lock)

	// Version 2 publishes with nothing to persist while version 1 is queued:
	// it must not be reported covered yet.
	sync.mutex_lock(&store.lock)
	store.covered_target = 2
	store_update_covered_locked(&store)
	testing.expect(t, store.covered < 2)
	sync.mutex_unlock(&store.lock)

	// The writer drains version 1 and releases the reservation.
	sync.mutex_lock(&store.lock)
	clear(&store.queue)
	store.reserved_bytes = 0
	if store.durable < 1 {
		store.durable = 1
	}
	store_update_covered_locked(&store)
	testing.expect(t, store.covered >= 2)
	sync.mutex_unlock(&store.lock)

	// wait_durable(2) returns instead of blocking.
	store_wait_durable(&store, 2)
}

// The copy arena must be reclaimed across checkpoints; without rebasing, the
// payloads of superseded records and manifests accumulate for the process
// lifetime (long-run OOM).
@(test)
test_store_arena_rebase_reclaims :: proc(t: ^testing.T) {
	store: Store
	store_init(&store, Store_Options{})
	defer store_destroy(&store)

	sync.mutex_lock(&store.lock)
	// Dead payloads, as superseded records and manifests would leave behind.
	for _ in 0 ..< 256 {
		_ = make([]u8, 4096, store.copy_allocator)
	}
	// One live record whose payload must survive the migration.
	one, _ := v.value_int(42)
	writes := make([]Wal_Write, 1, store.copy_allocator)
	writes[0] = Wal_Write {
		relation = 1,
		assert   = true,
		tuple    = v.tuple_new(store.copy_allocator, []v.Value{one}),
	}
	append(&store.records, Wal_Record{version = 1, writes = writes})
	before := store.arena.total_used
	sync.mutex_unlock(&store.lock)

	store_rebase_copy_arena(&store)

	testing.expect(t, store.arena.total_used < before)
	testing.expect(t, len(store.records) == 1)
	values := v.tuple_values(store.records[0].writes[0].tuple)
	testing.expect(t, len(values) == 1)
	migrated, is_int := v.value_as_int(values[0])
	testing.expect(t, is_int)
	testing.expect_value(t, migrated, i64(42))
}

@(private)
create_named_relation :: proc(t: ^testing.T, kernel: ^k.Kernel, id: u32, name: string, arity: u16, durability: k.Relation_Durability) {
	metadata := k.relation_metadata(k.Relation_ID(id), v.symbol_intern(name), arity)
	metadata.durability = durability
	created, create_error := k.kernel_create_relation(kernel, metadata)
	testing.expectf(t, create_error == k.Kernel_Error.None, "create failed: %v", create_error)
	if create_error == k.Kernel_Error.None {
		k.snapshot_release(created)
	}
}

@(test)
test_kernel_persist_pipeline :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	store: Store
	store_init(&store)
	defer store_destroy(&store)
	store_attach(&store, &kernel)

	create_named_relation(t, &kernel, 1, "Durable", 1, .Durable)
	create_named_relation(t, &kernel, 2, "Volatile", 1, .Volatile)

	tx := k.kernel_begin(&kernel)
	one, _ := v.value_int(1)
	two, _ := v.value_int(2)
	testing.expect_value(
		t,
		k.transaction_assert(&tx, 1, v.tuple_new(context.temp_allocator, []v.Value{one})),
		k.Kernel_Error.None,
	)
	testing.expect_value(
		t,
		k.transaction_assert(&tx, 2, v.tuple_new(context.temp_allocator, []v.Value{two})),
		k.Kernel_Error.None,
	)
	committed, commit_error := k.transaction_commit(&tx)
	k.transaction_destroy(&tx)
	testing.expectf(t, commit_error == k.Kernel_Error.None, "commit failed: %v", commit_error)
	if commit_error != k.Kernel_Error.None {
		return
	}
	defer k.snapshot_release(committed)

	store_wait_durable(&store, committed.version)
	testing.expect(t, store_durable_version(&store) >= committed.version)

	// Catalogue records for the durable relation, plus the write record; the
	// volatile relation contributes nothing.
	testing.expect(t, store_record_count(&store) >= 1)
	sync.mutex_lock(&store.lock)
	write_records := 0
	wrote_durable := false
	for record in store.records {
		write_records += len(record.writes)
		for write in record.writes {
			if write.relation == k.Relation_ID(1) && write.assert {
				wrote_durable = true
			}
			testing.expect(t, write.relation != k.Relation_ID(2))
		}
	}
	testing.expect_value(t, write_records, 1)
	testing.expect(t, wrote_durable)
	sync.mutex_unlock(&store.lock)
}

@(test)
test_kernel_admission_overload :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	store: Store
	store_init(&store, Store_Options{budget_bytes = 1, timeout = 10 * time.Millisecond})
	defer store_destroy(&store)
	store_attach(&store, &kernel)

	create_named_relation(t, &kernel, 1, "TooBig", 1, .Durable)

	tx := k.kernel_begin(&kernel)
	one, _ := v.value_int(1)
	testing.expect_value(
		t,
		k.transaction_assert(&tx, 1, v.tuple_new(context.temp_allocator, []v.Value{one})),
		k.Kernel_Error.None,
	)
	before := kernel.current.version
	committed, commit_error := k.transaction_commit(&tx)
	k.transaction_destroy(&tx)
	if committed != nil {
		k.snapshot_release(committed)
	}
	testing.expect_value(t, commit_error, k.Kernel_Error.Overloaded)
	testing.expect_value(t, kernel.current.version, before)
}

// A durable buffer edit is durable work, so it is admitted against the store's
// budget exactly as a relation write is. When buffer writes were left out of the
// estimate, a paste could run the log past its budget without ever blocking.
@(test)
test_kernel_buffer_admission_overload :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	store: Store
	store_init(&store, Store_Options{budget_bytes = 1, timeout = 10 * time.Millisecond})
	defer store_destroy(&store)
	store_attach(&store, &kernel)

	tx := k.kernel_begin(&kernel)
	metadata := k.relation_metadata(1, v.symbol_intern("TooBig"), 0)
	metadata.storage = .Buffer
	metadata.conflict = k.Conflict_Policy{kind = .Reject}
	notes, create_error := k.transaction_create_relation(&tx, metadata)
	testing.expect_value(t, create_error, k.Kernel_Error.None)
	k.transaction_buffer_edit(&tx, notes, 0, 0, "a large paste")

	before := kernel.current.version
	committed, commit_error := k.transaction_commit(&tx)
	k.transaction_destroy(&tx)
	if committed != nil {
		k.snapshot_release(committed)
	}
	testing.expect_value(t, commit_error, k.Kernel_Error.Overloaded)
	testing.expect_value(t, kernel.current.version, before)
}

@(private)
temp_store_path :: proc(t: ^testing.T, name: string) -> string {
	directory, directory_error := os.temp_dir(context.temp_allocator)
	testing.expectf(t, directory_error == nil, "temp dir: %v", directory_error)
	if directory_error != nil {
		return ""
	}
	path, join_error := filepath.join(
		[]string{directory, name},
		context.temp_allocator,
	)
	testing.expectf(t, join_error == nil, "join: %v", join_error)
	return path
}

@(private)
file_relation_rows :: proc(t: ^testing.T, kernel: ^k.Kernel, name: string) -> int {
	snapshot := k.kernel_snapshot(kernel)
	metadata, found := k.snapshot_relation_metadata_named(snapshot, v.symbol_intern(name))
	k.snapshot_release(snapshot)
	if !found {
		return -1
	}
	rows: [dynamic]v.Tuple
	defer delete(rows)
	k.kernel_scan_into(kernel, metadata.id, []v.Binding{{}}, &rows)
	return len(rows)
}

@(test)
test_file_wal_round_trip :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := temp_store_path(t, "mica_store_round_trip")
	if path == "" {
		return
	}
	os.remove_all(path)
	defer os.remove_all(path)

	{
		kernel: k.Kernel
		k.kernel_init(&kernel)
		store: Store
		testing.expect(
			t,
			store_open(
				&store,
				Store_Options{mode = .File, path = path, durability = .Group},
			),
		)
		store_attach(&store, &kernel)
		create_named_relation(t, &kernel, 1, "Kept", 1, .Durable)
		create_named_relation(t, &kernel, 2, "Gone", 1, .Volatile)

		tx := k.kernel_begin(&kernel)
		one, _ := v.value_int(1)
		two, _ := v.value_int(2)
		testing.expect_value(
			t,
			k.transaction_assert(&tx, 1, v.tuple_new(context.temp_allocator, []v.Value{one})),
			k.Kernel_Error.None,
		)
		testing.expect_value(
			t,
			k.transaction_assert(&tx, 1, v.tuple_new(context.temp_allocator, []v.Value{two})),
			k.Kernel_Error.None,
		)
		testing.expect_value(
			t,
			k.transaction_assert(&tx, 2, v.tuple_new(context.temp_allocator, []v.Value{two})),
			k.Kernel_Error.None,
		)
		committed, commit_error := k.transaction_commit(&tx)
		k.transaction_destroy(&tx)
		testing.expectf(t, commit_error == k.Kernel_Error.None, "commit: %v", commit_error)
		if commit_error != k.Kernel_Error.None {
			store_destroy(&store)
			k.kernel_destroy(&kernel)
			return
		}
		latest := committed.version
		k.snapshot_release(committed)
		store_wait_durable(&store, latest)
		testing.expect(t, store_sync_count(&store) >= 1)
		k.kernel_detach_store(&kernel)
		store_destroy(&store)
		k.kernel_destroy(&kernel)
	}

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	store: Store
	testing.expect(
		t,
		store_open(&store, Store_Options{mode = .File, path = path, durability = .Group}),
	)
	defer store_destroy(&store)
	testing.expect(t, store_durable_version(&store) >= 1)
	testing.expect(t, store_restore(&store, &kernel))
	testing.expect_value(t, file_relation_rows(t, &kernel, "Kept"), 2)
	// Volatile schema is durable; its facts are not.
	testing.expect_value(t, file_relation_rows(t, &kernel, "Gone"), 0)
}

@(test)
test_file_wal_truncated_tail :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := temp_store_path(t, "mica_store_truncated")
	if path == "" {
		return
	}
	os.remove_all(path)
	defer os.remove_all(path)

	latest: u64
	{
		kernel: k.Kernel
		k.kernel_init(&kernel)
		store: Store
		testing.expect(
			t,
			store_open(
				&store,
				Store_Options{mode = .File, path = path, durability = .Group},
			),
		)
		store_attach(&store, &kernel)
		create_named_relation(t, &kernel, 1, "Kept", 1, .Durable)
		tx := k.kernel_begin(&kernel)
		one, _ := v.value_int(1)
		k.transaction_assert(&tx, 1, v.tuple_new(context.temp_allocator, []v.Value{one}))
		committed, commit_error := k.transaction_commit(&tx)
		k.transaction_destroy(&tx)
		testing.expect(t, commit_error == k.Kernel_Error.None)
		latest = committed.version
		k.snapshot_release(committed)
		store_wait_durable(&store, latest)
		k.kernel_detach_store(&kernel)
		store_destroy(&store)
		k.kernel_destroy(&kernel)
	}

	// Append a torn record header and reopening must drop it.
	wal_path, _ := filepath.join([]string{path, "wal"}, context.temp_allocator)
	wal_file, open_error := os.open(wal_path, os.O_WRONLY | os.O_APPEND)
	testing.expect(t, open_error == nil)
	if open_error == nil {
		garbage := []u8{0xde, 0xad, 0xbe}
		written, write_error := os.write(wal_file, garbage)
		testing.expect(t, write_error == nil && written == len(garbage))
		os.close(wal_file)
	}

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	store: Store
	testing.expect(
		t,
		store_open(&store, Store_Options{mode = .File, path = path, durability = .Group}),
	)
	testing.expect_value(t, store_durable_version(&store), latest)
	testing.expect(t, !store_failed(&store))
	store_destroy(&store)

	// The torn tail is truncated, so reopening again is clean.
	second: Store
	testing.expect(
		t,
		store_open(&second, Store_Options{mode = .File, path = path, durability = .Group}),
	)
	testing.expect_value(t, store_durable_version(&second), latest)
	store_destroy(&second)
}

// A crash while creating the WAL can leave a file shorter than its header.
// Opening the store must recover instead of indexing past the end.
@(test)
test_file_wal_short_header :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := temp_store_path(t, "mica_store_short_header")
	if path == "" {
		return
	}
	os.remove_all(path)
	defer os.remove_all(path)

	testing.expect(t, os.make_directory_all(path, os.Permissions_Default) == nil)
	wal_path, _ := filepath.join([]string{path, "wal"}, context.temp_allocator)
	wal_file, open_error := os.open(wal_path, os.O_RDWR | os.O_CREATE)
	testing.expect(t, open_error == nil)
	if open_error == nil {
		torn := []u8{0x4d, 0x49, 0x43, 0x41, 0x01}
		written, write_error := os.write(wal_file, torn)
		testing.expect(t, write_error == nil && written == len(torn))
		os.close(wal_file)
	}

	store: Store
	testing.expect(
		t,
		store_open(&store, Store_Options{mode = .File, path = path, durability = .Group}),
	)
	defer store_destroy(&store)
	testing.expect_value(t, store_durable_version(&store), u64(0))
	testing.expect(t, !store_failed(&store))
}

// A WAL written by an unknown format version is refused, not misread.
@(test)
test_file_wal_rejects_unknown_version :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := temp_store_path(t, "mica_store_wal_version")
	if path == "" {
		return
	}
	os.remove_all(path)
	defer os.remove_all(path)

	testing.expect(t, os.make_directory_all(path, os.Permissions_Default) == nil)
	wal_path, _ := filepath.join([]string{path, "wal"}, context.temp_allocator)
	wal_file, open_error := os.open(wal_path, os.O_RDWR | os.O_CREATE)
	testing.expect(t, open_error == nil)
	if open_error == nil {
		header: [WAL_HEADER_SIZE]u8
		copy(header[:8], WAL_MAGIC)
		header[8] = 2
		written, write_error := os.write(wal_file, header[:])
		testing.expect(t, write_error == nil && written == WAL_HEADER_SIZE)
		os.close(wal_file)
	}

	store: Store
	testing.expect(
		t,
		!store_open(&store, Store_Options{mode = .File, path = path, durability = .Group}),
	)
}

@(test)
test_file_wal_durability_none_does_not_sync :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := temp_store_path(t, "mica_store_no_sync")
	if path == "" {
		return
	}
	os.remove_all(path)
	defer os.remove_all(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	store: Store
	testing.expect(
		t,
		store_open(&store, Store_Options{mode = .File, path = path, durability = .None}),
	)
	defer store_destroy(&store)
	store_attach(&store, &kernel)
	create_named_relation(t, &kernel, 1, "NoSync", 1, .Durable)
	tx := k.kernel_begin(&kernel)
	one, _ := v.value_int(1)
	k.transaction_assert(&tx, 1, v.tuple_new(context.temp_allocator, []v.Value{one}))
	committed, commit_error := k.transaction_commit(&tx)
	k.transaction_destroy(&tx)
	testing.expect(t, commit_error == k.Kernel_Error.None)
	if commit_error == k.Kernel_Error.None {
		store_wait_durable(&store, committed.version)
		k.snapshot_release(committed)
	}
	testing.expect_value(t, store_sync_count(&store), u64(0))
}

@(test)
test_checkpoint_round_trip :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := temp_store_path(t, "mica_store_checkpoint")
	if path == "" {
		return
	}
	os.remove_all(path)
	defer os.remove_all(path)

	checkpoint_version: u64
	{
		kernel: k.Kernel
		k.kernel_init(&kernel)
		store: Store
		testing.expect(
			t,
			store_open(
				&store,
				Store_Options{mode = .File, path = path, durability = .Group},
			),
		)
		store_attach(&store, &kernel)
		create_named_relation(t, &kernel, 1, "Kept", 1, .Durable)
		create_named_relation(t, &kernel, 2, "Gone", 1, .Volatile)
		// Copy is derived from Kept by a rule: its rows are derived blocks and
		// must never be written to the checkpoint as facts.
		create_named_relation(t, &kernel, 3, "Copy", 1, .Durable)
		x := v.symbol_intern("x")
		rule := k.rule_new(3, []k.Term{k.term_var(x)}, []k.Rule_Body_Item{k.body_atom(k.atom_positive(1, []k.Term{k.term_var(x)}))})
		installed, install_error := k.kernel_install_rule(&kernel, v.Identity(960), rule, "checkpoint test")
		testing.expect_value(t, install_error, k.Kernel_Error.None)
		k.snapshot_release(installed)

		tx := k.kernel_begin(&kernel)
		for index in 0 ..< 300 {
			number, _ := v.value_int(i64(index))
			testing.expect_value(
				t,
				k.transaction_assert(&tx, 1, v.tuple_new(context.temp_allocator, []v.Value{number})),
				k.Kernel_Error.None,
			)
		}
		volatile_number, _ := v.value_int(7)
		testing.expect_value(
			t,
			k.transaction_assert(&tx, 2, v.tuple_new(context.temp_allocator, []v.Value{volatile_number})),
			k.Kernel_Error.None,
		)
		committed, commit_error := k.transaction_commit(&tx)
		k.transaction_destroy(&tx)
		testing.expect(t, commit_error == k.Kernel_Error.None)
		if commit_error != k.Kernel_Error.None {
			store_destroy(&store)
			k.kernel_destroy(&kernel)
			return
		}
		derived, has_derived := k.snapshot_derived_block(committed, 3)
		testing.expect(t, has_derived && k.relation_block_len(derived) == 300)
		k.snapshot_release(committed)

		testing.expect(t, store_checkpoint(&store, &kernel))
		checkpoint_version = store_checkpoint_version(&store)
		pages_after_checkpoint := store_page_count(&store)
		testing.expect(t, pages_after_checkpoint >= 1)

		// A small tail after the checkpoint.
		tx2 := k.kernel_begin(&kernel)
		tail_number, _ := v.value_int(999)
		k.transaction_assert(&tx2, 1, v.tuple_new(context.temp_allocator, []v.Value{tail_number}))
		tail, tail_error := k.transaction_commit(&tx2)
		k.transaction_destroy(&tx2)
		testing.expect(t, tail_error == k.Kernel_Error.None)
		if tail_error == k.Kernel_Error.None {
			store_wait_durable(&store, tail.version)
			k.snapshot_release(tail)
		}

		// A second checkpoint persists only the chunks the tail touched.
		testing.expect(t, store_checkpoint(&store, &kernel))
		checkpoint_version = store_checkpoint_version(&store)
		// The checkpoint truncates the log; nothing was committed after it.
		testing.expect_value(t, store_record_count(&store), 0)
		pages_after_tail := store_page_count(&store)
		testing.expectf(
			t,
			pages_after_tail - pages_after_checkpoint <= 2,
			"tail checkpoint added %d pages",
			pages_after_tail - pages_after_checkpoint,
		)

		k.kernel_detach_store(&kernel)
		store_destroy(&store)
		k.kernel_destroy(&kernel)
	}

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	store: Store
	testing.expect(
		t,
		store_open(&store, Store_Options{mode = .File, path = path, durability = .Group}),
	)
	defer store_destroy(&store)
	testing.expect_value(t, store_checkpoint_version(&store), checkpoint_version)
	testing.expect(t, store_restore(&store, &kernel))
	testing.expect_value(t, file_relation_rows(t, &kernel, "Kept"), 301)
	testing.expect_value(t, file_relation_rows(t, &kernel, "Gone"), 0)
	// No rule is installed after a store-level restore, so any Copy row here
	// would be a derived row that was persisted as a fact.
	testing.expect_value(t, file_relation_rows(t, &kernel, "Copy"), 0)
}

@(private)
commit_single :: proc(t: ^testing.T, kernel: ^k.Kernel, relation: k.Relation_ID, value: i64) {
	tx := k.kernel_begin(kernel)
	number, _ := v.value_int(value)
	testing.expect_value(
		t,
		k.transaction_assert(&tx, relation, v.tuple_new(context.temp_allocator, []v.Value{number})),
		k.Kernel_Error.None,
	)
	committed, commit_error := k.transaction_commit(&tx)
	k.transaction_destroy(&tx)
	testing.expect(t, commit_error == k.Kernel_Error.None)
	if commit_error == k.Kernel_Error.None {
		k.snapshot_release(committed)
	}
}

@(private)
restore_at_version :: proc(
	t: ^testing.T,
	path: string,
	version: u64,
) -> (
	k.Kernel,
	^Store,
	bool,
) {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	store := new(Store, context.allocator)
	if !store_open(store, Store_Options {
		mode    = .File,
		path    = path,
		version = version,
	}) {
		free(store, context.allocator)
		k.kernel_destroy(&kernel)
		return {}, nil, false
	}
	if !store_restore(store, &kernel) {
		store_destroy(store)
		free(store, context.allocator)
		k.kernel_destroy(&kernel)
		return {}, nil, false
	}
	return kernel, store, true
}

@(private)
count_rows :: proc(kernel: ^k.Kernel, name: string) -> int {
	snapshot := k.kernel_snapshot(kernel)
	metadata, found := k.snapshot_relation_metadata_named(snapshot, v.symbol_intern(name))
	k.snapshot_release(snapshot)
	if !found {
		return -1
	}
	rows: [dynamic]v.Tuple
	defer delete(rows)
	k.kernel_scan_into(kernel, metadata.id, []v.Binding{{}}, &rows)
	return len(rows)
}

@(test)
test_manifest_retention_and_point_in_time :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := temp_store_path(t, "mica_store_history")
	if path == "" {
		return
	}
	os.remove_all(path)
	defer os.remove_all(path)

	first_version: u64
	{
		kernel: k.Kernel
		k.kernel_init(&kernel)
		store: Store
		testing.expect(
			t,
			store_open(&store, Store_Options{mode = .File, path = path, durability = .Group}),
		)
		store_attach(&store, &kernel)
		create_named_relation(t, &kernel, 1, "K", 1, .Durable)

		// Six commits and checkpoints; retention keeps the last four.
		for index in 1 ..= 6 {
			commit_single(t, &kernel, 1, i64(index))
			testing.expect(t, store_checkpoint(&store, &kernel))
		}
		testing.expect_value(t, store_retained_version_count(&store), MANIFEST_RETENTION)
		first_version = store_oldest_retained_version(&store)
		testing.expect(t, first_version != 0)
		k.kernel_detach_store(&kernel)
		store_destroy(&store)
		k.kernel_destroy(&kernel)
	}

	// Point in time: the oldest retained checkpoint follows the third commit.
	kernel, store, restored := restore_at_version(t, path, first_version)
	if restored {
		testing.expect_value(t, count_rows(&kernel, "K"), 3)
		store_destroy(store)
		free(store, context.allocator)
		k.kernel_destroy(&kernel)
	}

	// Latest: every row.
	latest_kernel, latest_store, latest_ok := restore_at_version(t, path, 0)
	if latest_ok {
		testing.expect_value(t, count_rows(&latest_kernel, "K"), 6)
		store_destroy(latest_store)
		free(latest_store, context.allocator)
		k.kernel_destroy(&latest_kernel)
	}
}

@(test)
test_page_compaction :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := temp_store_path(t, "mica_store_compact")
	if path == "" {
		return
	}
	os.remove_all(path)
	defer os.remove_all(path)

	{
		kernel: k.Kernel
		k.kernel_init(&kernel)
		store: Store
		testing.expect(
			t,
			store_open(&store, Store_Options{mode = .File, path = path, durability = .Group}),
		)
		store_attach(&store, &kernel)
		create_named_relation(t, &kernel, 1, "K", 1, .Durable)

		tx := k.kernel_begin(&kernel)
		for index in 0 ..< 300 {
			number, _ := v.value_int(i64(index))
			k.transaction_assert(&tx, 1, v.tuple_new(context.temp_allocator, []v.Value{number}))
		}
		committed, commit_error := k.transaction_commit(&tx)
		k.transaction_destroy(&tx)
		testing.expect(t, commit_error == k.Kernel_Error.None)
		if commit_error == k.Kernel_Error.None {
			k.snapshot_release(committed)
		}
		testing.expect(t, store_checkpoint(&store, &kernel))

		// Churn enough that pruning leaves dead pages behind.
		for index in 0 ..< 6 {
			commit_single(t, &kernel, 1, i64(1000 + index))
			testing.expect(t, store_checkpoint(&store, &kernel))
			}
		pages_before := store_page_count(&store)
		testing.expect(t, store_pages_compact(&store))
		pages_after := store_page_count(&store)
		testing.expectf(t, pages_after < pages_before, "pages %d -> %d", pages_before, pages_after)

		// The store stays writable and checkpoints after compaction.
		commit_single(t, &kernel, 1, 2000)
		testing.expect(t, store_checkpoint(&store, &kernel))
		k.kernel_detach_store(&kernel)
		store_destroy(&store)
		k.kernel_destroy(&kernel)
	}

	kernel, store, restored := restore_at_version(t, path, 0)
	if restored {
		testing.expect_value(t, count_rows(&kernel, "K"), 307)
		store_destroy(store)
		free(store, context.allocator)
		k.kernel_destroy(&kernel)
	}
}

@(test)
test_store_lock :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := temp_store_path(t, "mica_store_lock")
	if path == "" {
		return
	}
	os.remove_all(path)
	defer os.remove_all(path)

	first: Store
	testing.expect(t, store_open(&first, Store_Options{mode = .File, path = path}))

	second: Store
	testing.expect(t, !store_open(&second, Store_Options{mode = .File, path = path}))
	testing.expect(
		t,
		strings.contains(store_last_error(&second), "locked"),
	)
	store_destroy(&first)

	third: Store
	testing.expect(t, store_open(&third, Store_Options{mode = .File, path = path}))
	store_destroy(&third)
}

@(test)
test_auto_checkpoint_on_wal_bytes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := temp_store_path(t, "mica_store_auto_checkpoint")
	if path == "" {
		return
	}
	os.remove_all(path)
	defer os.remove_all(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	store: Store
	testing.expect(
		t,
		store_open(&store, Store_Options {
			mode             = .File,
			path             = path,
			durability       = .Group,
			checkpoint_bytes = 1024,
		}),
	)
	defer store_destroy(&store)
	store_attach(&store, &kernel)
	create_named_relation(t, &kernel, 1, "Auto", 1, .Durable)

	for index in 0 ..< 60 {
		commit_single(t, &kernel, 1, i64(index))
	}
	deadline := time.tick_now()
	for time.tick_since(deadline) < 5 * time.Second {
		if store_checkpoint_version(&store) > 0 {
			break
		}
		time.sleep(2 * time.Millisecond)
	}
	testing.expect(t, store_checkpoint_version(&store) > 0)
	k.kernel_detach_store(&kernel)
}

// A functional replacement (retract the old key value, assert the new) must
// replay from the WAL. Sorting staged writes by tuple value puts the assert
// before the retract, which replays as a functional-key conflict.
@(test)
test_file_wal_replays_functional_replacement :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := temp_store_path(t, "mica_store_functional")
	if path == "" {
		return
	}
	os.remove_all(path)
	defer os.remove_all(path)

	{
		kernel: k.Kernel
		k.kernel_init(&kernel)
		store: Store
		testing.expect(
			t,
			store_open(&store, Store_Options{mode = .File, path = path, durability = .Group}),
		)
		store_attach(&store, &kernel)
		metadata := k.relation_metadata(1, v.symbol_intern("Current"), 2)
		metadata.conflict = k.conflict_functional([]u16{0})
		metadata.durability = .Durable
		created, create_error := k.kernel_create_relation(&kernel, metadata)
		testing.expect_value(t, create_error, k.Kernel_Error.None)
		k.snapshot_release(created)

		key, _ := v.value_int(1)
		old_value, _ := v.value_int(2)
		new_value, _ := v.value_int(1)

		tx := k.kernel_begin(&kernel)
		testing.expect_value(
			t,
			k.transaction_assert(
				&tx,
				1,
				v.tuple_new(context.temp_allocator, []v.Value{key, old_value}),
			),
			k.Kernel_Error.None,
		)
		committed, commit_error := k.transaction_commit(&tx)
		k.transaction_destroy(&tx)
		testing.expect_value(t, commit_error, k.Kernel_Error.None)
		latest := committed.version
		k.snapshot_release(committed)

		// Replace the key's value: retract (1,2), assert (1,1).
		tx2 := k.kernel_begin(&kernel)
		testing.expect_value(
			t,
			k.transaction_retract(
				&tx2,
				1,
				v.tuple_new(context.temp_allocator, []v.Value{key, old_value}),
			),
			k.Kernel_Error.None,
		)
		testing.expect_value(
			t,
			k.transaction_assert(
				&tx2,
				1,
				v.tuple_new(context.temp_allocator, []v.Value{key, new_value}),
			),
			k.Kernel_Error.None,
		)
		committed2, commit_error2 := k.transaction_commit(&tx2)
		k.transaction_destroy(&tx2)
		testing.expect_value(t, commit_error2, k.Kernel_Error.None)
		latest = committed2.version
		k.snapshot_release(committed2)

		store_wait_durable(&store, latest)
		k.kernel_detach_store(&kernel)
		store_destroy(&store)
		k.kernel_destroy(&kernel)
	}

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	store: Store
	testing.expect(
		t,
		store_open(&store, Store_Options{mode = .File, path = path, durability = .Group}),
	)
	defer store_destroy(&store)
	testing.expect(t, store_restore(&store, &kernel))
	rows: [dynamic]v.Tuple
	defer delete(rows)
	k.kernel_scan_into(&kernel, 1, []v.Binding{{}, {}}, &rows)
	testing.expect_value(t, len(rows), 1)
	if len(rows) == 1 {
		expected, _ := v.value_int(1)
		testing.expect(t, v.value_eq(v.tuple_values(rows[0])[1], expected))
	}
}

// Repeated replacement plus checkpointing recycles chunk arenas. A checkpoint
// cache keyed by the raw chunk address mistakes a new chunk for an already
// persisted one at the same address and references stale rows.
@(test)
test_file_checkpoint_survives_chunk_reuse :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := temp_store_path(t, "mica_store_chunk_reuse")
	if path == "" {
		return
	}
	os.remove_all(path)
	defer os.remove_all(path)

	value_count := 30
	{
		kernel: k.Kernel
		k.kernel_init(&kernel)
		store: Store
		testing.expect(
			t,
			store_open(&store, Store_Options{mode = .File, path = path, durability = .Group}),
		)
		store_attach(&store, &kernel)
		create_named_relation(t, &kernel, 1, "Counter", 1, .Durable)

		for i in 0 ..< value_count {
			value, _ := v.value_int(i64(i))
			tx := k.kernel_begin(&kernel)
			if i > 0 {
				previous, _ := v.value_int(i64(i - 1))
				k.transaction_retract(
					&tx,
					1,
					v.tuple_new(context.temp_allocator, []v.Value{previous}),
				)
			}
			k.transaction_assert(&tx, 1, v.tuple_new(context.temp_allocator, []v.Value{value}))
			committed, commit_error := k.transaction_commit(&tx)
			k.transaction_destroy(&tx)
			testing.expect_value(t, commit_error, k.Kernel_Error.None)
			k.snapshot_release(committed)
			testing.expect(t, store_checkpoint(&store, &kernel))
		}
		k.kernel_detach_store(&kernel)
		store_destroy(&store)
		k.kernel_destroy(&kernel)
	}

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	store: Store
	testing.expect(
		t,
		store_open(&store, Store_Options{mode = .File, path = path, durability = .Group}),
	)
	defer store_destroy(&store)
	testing.expect(t, store_restore(&store, &kernel))
	rows: [dynamic]v.Tuple
	defer delete(rows)
	k.kernel_scan_into(&kernel, 1, []v.Binding{{}}, &rows)
	testing.expect_value(t, len(rows), 1)
	if len(rows) == 1 {
		expected, _ := v.value_int(i64(value_count - 1))
		testing.expect(t, v.value_eq(v.tuple_values(rows[0])[0], expected))
	}
}

// A buffer's storage kind is catalogue state and must survive a store round
// trip. If the metadata codec dropped it, recovery would silently recreate the
// buffer as a tuple relation.
@(test)
test_checkpoint_preserves_buffer_storage :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := temp_store_path(t, "mica_store_buffer_storage")
	if path == "" {
		return
	}
	os.remove_all(path)
	defer os.remove_all(path)

	{
		kernel: k.Kernel
		k.kernel_init(&kernel)
		store: Store
		testing.expect(
			t,
			store_open(&store, Store_Options{mode = .File, path = path, durability = .Group}),
		)
		store_attach(&store, &kernel)

		metadata := k.relation_metadata(k.Relation_ID(7), v.symbol_intern("Notes"), 0)
		metadata.storage = .Buffer
		metadata.conflict = k.Conflict_Policy{kind = .Reject}
		published, create_error := k.kernel_create_relation(&kernel, metadata)
		testing.expect_value(t, create_error, k.Kernel_Error.None)
		if published != nil {
			k.snapshot_release(published)
		}

		testing.expect(t, store_checkpoint(&store, &kernel))
		k.kernel_detach_store(&kernel)
		store_destroy(&store)
		k.kernel_destroy(&kernel)
	}

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	store: Store
	testing.expect(
		t,
		store_open(&store, Store_Options{mode = .File, path = path, durability = .Group}),
	)
	defer store_destroy(&store)
	testing.expect(t, store_restore(&store, &kernel))

	snapshot := k.kernel_snapshot(&kernel)
	defer k.snapshot_release(snapshot)
	restored, found := k.snapshot_relation_metadata_named(snapshot, v.symbol_intern("Notes"))
	testing.expect(t, found)
	if found {
		testing.expect_value(t, restored.storage, k.Storage_Kind.Buffer)
		testing.expect_value(t, restored.conflict.kind, k.Conflict_Kind.Reject)
		testing.expect_value(t, restored.arity, u16(0))
	}
}

// Buffer content is durable through the log alone. No checkpoint is written, so
// restore depends entirely on replaying the recorded deltas into a fresh
// kernel, including a replacement (not just an append) so the delta is
// exercised as more than an insertion.
@(test)
test_wal_replays_buffer_content :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := temp_store_path(t, "mica_store_buffer_wal")
	if path == "" {
		return
	}
	os.remove_all(path)
	defer os.remove_all(path)

	{
		kernel: k.Kernel
		k.kernel_init(&kernel)
		store: Store
		testing.expect(
			t,
			store_open(&store, Store_Options{mode = .File, path = path, durability = .Group}),
		)
		store_attach(&store, &kernel)

		tx := k.kernel_begin(&kernel)
		metadata := k.relation_metadata(0, v.symbol_intern("Notes"), 0)
		metadata.storage = .Buffer
		metadata.conflict = k.Conflict_Policy{kind = .Reject}
		notes, create_error := k.transaction_create_relation(&tx, metadata)
		testing.expect_value(t, create_error, k.Kernel_Error.None)
		testing.expect_value(
			t,
			k.transaction_buffer_edit(&tx, notes, 0, 0, "hello"),
			k.Kernel_Error.None,
		)
		first, first_error := k.transaction_commit(&tx)
		k.transaction_destroy(&tx)
		testing.expect_value(t, first_error, k.Kernel_Error.None)
		if first != nil {
			k.snapshot_release(first)
		}

		tx2 := k.kernel_begin(&kernel)
		testing.expect_value(
			t,
			k.transaction_buffer_edit(&tx2, notes, 0, 5, "goodbye"),
			k.Kernel_Error.None,
		)
		second, second_error := k.transaction_commit(&tx2)
		k.transaction_destroy(&tx2)
		testing.expect_value(t, second_error, k.Kernel_Error.None)
		if second != nil {
			store_wait_durable(&store, second.version)
			k.snapshot_release(second)
		}

		k.kernel_detach_store(&kernel)
		store_destroy(&store)
		k.kernel_destroy(&kernel)
	}

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	store: Store
	testing.expect(
		t,
		store_open(&store, Store_Options{mode = .File, path = path, durability = .Group}),
	)
	defer store_destroy(&store)
	testing.expect(t, store_restore(&store, &kernel))

	snapshot := k.kernel_snapshot(&kernel)
	defer k.snapshot_release(snapshot)

	restored, found := k.snapshot_relation_metadata_named(snapshot, v.symbol_intern("Notes"))
	testing.expect(t, found)
	if !found {
		return
	}
	testing.expect_value(t, restored.storage, k.Storage_Kind.Buffer)
	block, has_block := k.snapshot_buffer(snapshot, restored.id)
	testing.expect(t, has_block)
	if has_block {
		testing.expect_value(t, block.revision, u64(2))
		testing.expect_value(
			t,
			k.snapshot_buffer_text(snapshot, restored.id, context.temp_allocator),
			"goodbye",
		)
	}
}

// The real durability path: content before a checkpoint comes back from the
// checkpoint page, and content after it comes back from the replayed log. A
// checkpoint truncates the log, so a buffer that is only in the log would be
// lost here.
@(test)
test_checkpoint_persists_buffer_content :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := temp_store_path(t, "mica_store_buffer_checkpoint")
	if path == "" {
		return
	}
	os.remove_all(path)
	defer os.remove_all(path)

	{
		kernel: k.Kernel
		k.kernel_init(&kernel)
		store: Store
		testing.expect(
			t,
			store_open(&store, Store_Options{mode = .File, path = path, durability = .Group}),
		)
		store_attach(&store, &kernel)

		tx := k.kernel_begin(&kernel)
		metadata := k.relation_metadata(0, v.symbol_intern("Notes"), 0)
		metadata.storage = .Buffer
		metadata.conflict = k.Conflict_Policy{kind = .Reject}
		notes, create_error := k.transaction_create_relation(&tx, metadata)
		testing.expect_value(t, create_error, k.Kernel_Error.None)
		k.transaction_buffer_edit(&tx, notes, 0, 0, "hello")
		first, first_error := k.transaction_commit(&tx)
		k.transaction_destroy(&tx)
		testing.expect_value(t, first_error, k.Kernel_Error.None)
		if first != nil {
			store_wait_durable(&store, first.version)
			k.snapshot_release(first)
		}

		// History: the pre-checkpoint state is snapshotted into pages.
		testing.expect(t, store_checkpoint(&store, &kernel))

		// Tail: only in the log.
		tx2 := k.kernel_begin(&kernel)
		k.transaction_buffer_edit(&tx2, notes, 5, 0, " world")
		second, second_error := k.transaction_commit(&tx2)
		k.transaction_destroy(&tx2)
		testing.expect_value(t, second_error, k.Kernel_Error.None)
		if second != nil {
			store_wait_durable(&store, second.version)
			k.snapshot_release(second)
		}

		k.kernel_detach_store(&kernel)
		store_destroy(&store)
		k.kernel_destroy(&kernel)
	}

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	store: Store
	testing.expect(
		t,
		store_open(&store, Store_Options{mode = .File, path = path, durability = .Group}),
	)
	defer store_destroy(&store)
	testing.expect(t, store_restore(&store, &kernel))

	snapshot := k.kernel_snapshot(&kernel)
	defer k.snapshot_release(snapshot)
	restored, found := k.snapshot_relation_metadata_named(snapshot, v.symbol_intern("Notes"))
	testing.expect(t, found)
	if !found {
		return
	}
	testing.expect_value(t, restored.storage, k.Storage_Kind.Buffer)
	block, has_block := k.snapshot_buffer(snapshot, restored.id)
	testing.expect(t, has_block)
	if has_block {
		testing.expect_value(t, block.revision, u64(2))
		testing.expect_value(
			t,
			k.snapshot_buffer_text(snapshot, restored.id, context.temp_allocator),
			"hello world",
		)
	}
}

// A compaction changes no content, so its log record carries an empty delta --
// but it still has to carry the new epoch, or a restarted world would compare
// provenance across a boundary it no longer knows about.
@(test)
test_wal_replays_buffer_compaction_epoch :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := temp_store_path(t, "mica_store_buffer_compaction")
	if path == "" {
		return
	}
	os.remove_all(path)
	defer os.remove_all(path)

	{
		kernel: k.Kernel
		k.kernel_init(&kernel)
		store: Store
		testing.expect(
			t,
			store_open(&store, Store_Options{mode = .File, path = path, durability = .Group}),
		)
		store_attach(&store, &kernel)

		tx := k.kernel_begin(&kernel)
		metadata := k.relation_metadata(0, v.symbol_intern("Notes"), 0)
		metadata.storage = .Buffer
		metadata.conflict = k.Conflict_Policy{kind = .Reject}
		notes, create_error := k.transaction_create_relation(&tx, metadata)
		testing.expect_value(t, create_error, k.Kernel_Error.None)
		k.transaction_buffer_edit(&tx, notes, 0, 0, "abc")
		first, first_error := k.transaction_commit(&tx)
		k.transaction_destroy(&tx)
		testing.expect_value(t, first_error, k.Kernel_Error.None)
		if first != nil {
			store_wait_durable(&store, first.version)
			k.snapshot_release(first)
		}

		compact := k.kernel_begin(&kernel)
		testing.expect_value(t, k.transaction_buffer_compact(&compact, notes), k.Kernel_Error.None)
		second, second_error := k.transaction_commit(&compact)
		k.transaction_destroy(&compact)
		testing.expect_value(t, second_error, k.Kernel_Error.None)
		if second != nil {
			store_wait_durable(&store, second.version)
			k.snapshot_release(second)
		}
		testing.expect_value(t, k.kernel_buffer_epoch(&kernel, notes), u64(1))

		k.kernel_detach_store(&kernel)
		store_destroy(&store)
		k.kernel_destroy(&kernel)
	}

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	store: Store
	testing.expect(
		t,
		store_open(&store, Store_Options{mode = .File, path = path, durability = .Group}),
	)
	defer store_destroy(&store)
	testing.expect(t, store_restore(&store, &kernel))

	snapshot := k.kernel_snapshot(&kernel)
	defer k.snapshot_release(snapshot)
	restored, found := k.snapshot_relation_metadata_named(snapshot, v.symbol_intern("Notes"))
	testing.expect(t, found)
	if !found {
		return
	}
	block, has_block := k.snapshot_buffer(snapshot, restored.id)
	testing.expect(t, has_block)
	if has_block {
		testing.expect_value(t, block.revision, u64(1))
		testing.expect_value(t, block.epoch, u64(1))
		testing.expect_value(
			t,
			k.snapshot_buffer_text(snapshot, restored.id, context.temp_allocator),
			"abc",
		)
	}
}

// A kill is catalogue state, so it has to survive a restart: the entry comes
// back as a tombstone with no content, and its id and name stay retired.
@(test)
test_wal_replays_buffer_kill :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := temp_store_path(t, "mica_store_buffer_kill")
	if path == "" {
		return
	}
	os.remove_all(path)
	defer os.remove_all(path)

	{
		kernel: k.Kernel
		k.kernel_init(&kernel)
		store: Store
		testing.expect(
			t,
			store_open(&store, Store_Options{mode = .File, path = path, durability = .Group}),
		)
		store_attach(&store, &kernel)

		tx := k.kernel_begin(&kernel)
		metadata := k.relation_metadata(0, v.symbol_intern("Notes"), 0)
		metadata.storage = .Buffer
		metadata.conflict = k.Conflict_Policy{kind = .Reject}
		notes, create_error := k.transaction_create_relation(&tx, metadata)
		testing.expect_value(t, create_error, k.Kernel_Error.None)
		k.transaction_buffer_edit(&tx, notes, 0, 0, "temporary")
		first, first_error := k.transaction_commit(&tx)
		k.transaction_destroy(&tx)
		testing.expect_value(t, first_error, k.Kernel_Error.None)
		if first != nil {
			store_wait_durable(&store, first.version)
			k.snapshot_release(first)
		}

		kill := k.kernel_begin(&kernel)
		testing.expect_value(t, k.transaction_kill_relation(&kill, notes), k.Kernel_Error.None)
		second, second_error := k.transaction_commit(&kill)
		k.transaction_destroy(&kill)
		testing.expect_value(t, second_error, k.Kernel_Error.None)
		if second != nil {
			store_wait_durable(&store, second.version)
			k.snapshot_release(second)
		}

		k.kernel_detach_store(&kernel)
		store_destroy(&store)
		k.kernel_destroy(&kernel)
	}

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	store: Store
	testing.expect(
		t,
		store_open(&store, Store_Options{mode = .File, path = path, durability = .Group}),
	)
	defer store_destroy(&store)
	testing.expect(t, store_restore(&store, &kernel))

	snapshot := k.kernel_snapshot(&kernel)
	defer k.snapshot_release(snapshot)
	restored, found := k.snapshot_relation_metadata_named(snapshot, v.symbol_intern("Notes"))
	testing.expect(t, found)
	if !found {
		return
	}
	testing.expect(t, restored.tombstoned)
	testing.expect_value(
		t,
		k.snapshot_buffer_text(snapshot, restored.id, context.temp_allocator),
		"",
	)
}

// A reversion is recorded as an ordinary base-relative delta, so replay
// reconstructs the spliced text and the new structure epoch. The replacement
// covers the whole buffer, which is what makes the record self-contained: it
// needs nothing from the version it discarded.
@(test)
test_wal_replays_buffer_reversion :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := temp_store_path(t, "mica_store_buffer_reversion")
	if path == "" {
		return
	}
	os.remove_all(path)
	defer os.remove_all(path)

	{
		kernel: k.Kernel
		k.kernel_init(&kernel)
		store: Store
		testing.expect(
			t,
			store_open(&store, Store_Options{mode = .File, path = path, durability = .Group}),
		)
		store_attach(&store, &kernel)

		tx := k.kernel_begin(&kernel)
		metadata := k.relation_metadata(0, v.symbol_intern("Notes"), 0)
		metadata.storage = .Buffer
		metadata.conflict = k.Conflict_Policy{kind = .Reject}
		notes, create_error := k.transaction_create_relation(&tx, metadata)
		testing.expect_value(t, create_error, k.Kernel_Error.None)
		k.transaction_buffer_edit(&tx, notes, 0, 0, "one")
		first, first_error := k.transaction_commit(&tx)
		k.transaction_destroy(&tx)
		testing.expect_value(t, first_error, k.Kernel_Error.None)
		if first != nil {
			store_wait_durable(&store, first.version)
			k.snapshot_release(first)
		}

		second_tx := k.kernel_begin(&kernel)
		k.transaction_buffer_edit(&second_tx, notes, 0, 3, "two")
		second, second_error := k.transaction_commit(&second_tx)
		k.transaction_destroy(&second_tx)
		testing.expect_value(t, second_error, k.Kernel_Error.None)
		if second != nil {
			store_wait_durable(&store, second.version)
			k.snapshot_release(second)
		}

		revert := k.kernel_begin(&kernel)
		testing.expect_value(
			t,
			k.transaction_buffer_revert(&revert, notes, 1, 2),
			k.Revert_Status.Reverted,
		)
		third, third_error := k.transaction_commit(&revert)
		k.transaction_destroy(&revert)
		testing.expect_value(t, third_error, k.Kernel_Error.None)
		if third != nil {
			store_wait_durable(&store, third.version)
			k.snapshot_release(third)
		}
		testing.expect_value(t, k.kernel_buffer_revision(&kernel, notes), u64(3))
		testing.expect_value(t, k.kernel_buffer_epoch(&kernel, notes), u64(1))
		testing.expect_value(t, k.kernel_buffer_text(&kernel, notes, context.temp_allocator), "one")

		k.kernel_detach_store(&kernel)
		store_destroy(&store)
		k.kernel_destroy(&kernel)
	}

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	store: Store
	testing.expect(
		t,
		store_open(&store, Store_Options{mode = .File, path = path, durability = .Group}),
	)
	defer store_destroy(&store)
	testing.expect(t, store_restore(&store, &kernel))

	snapshot := k.kernel_snapshot(&kernel)
	defer k.snapshot_release(snapshot)
	restored, found := k.snapshot_relation_metadata_named(snapshot, v.symbol_intern("Notes"))
	testing.expect(t, found)
	if !found {
		return
	}
	block, has_block := k.snapshot_buffer(snapshot, restored.id)
	testing.expect(t, has_block)
	if has_block {
		// The reversion published a new content revision and started a new
		// chunk lineage.
		testing.expect_value(t, block.revision, u64(3))
		testing.expect_value(t, block.epoch, u64(1))
		testing.expect_value(
			t,
			k.snapshot_buffer_text(snapshot, restored.id, context.temp_allocator),
			"one",
		)
	}
}

// A volatile buffer is scratch state. Its catalogue entry is durable, so its
// name and id stay stable across a restart, but its text is never written: a
// file-backed editor buffer can keep its working content out of the world's
// log while still using the world transactionally.
@(test)
test_volatile_buffer_content_is_not_persisted :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := temp_store_path(t, "mica_store_buffer_volatile")
	if path == "" {
		return
	}
	os.remove_all(path)
	defer os.remove_all(path)

	{
		kernel: k.Kernel
		k.kernel_init(&kernel)
		store: Store
		testing.expect(
			t,
			store_open(&store, Store_Options{mode = .File, path = path, durability = .Group}),
		)
		store_attach(&store, &kernel)

		tx := k.kernel_begin(&kernel)
		metadata := k.relation_metadata(0, v.symbol_intern("Scratch"), 0)
		metadata.storage = .Buffer
		metadata.durability = .Volatile
		metadata.conflict = k.Conflict_Policy{kind = .Reject}
		notes, create_error := k.transaction_create_relation(&tx, metadata)
		testing.expect_value(t, create_error, k.Kernel_Error.None)
		k.transaction_buffer_edit(&tx, notes, 0, 0, "scratch text")
		first, first_error := k.transaction_commit(&tx)
		k.transaction_destroy(&tx)
		testing.expect_value(t, first_error, k.Kernel_Error.None)
		if first != nil {
			store_wait_durable(&store, first.version)
			k.snapshot_release(first)
		}

		// A later edit is a volatile-only publish: it advances the in-memory
		// snapshot but writes no content record.
		second_tx := k.kernel_begin(&kernel)
		k.transaction_buffer_edit(&second_tx, notes, 0, 7, "edited")
		second, second_error := k.transaction_commit(&second_tx)
		k.transaction_destroy(&second_tx)
		testing.expect_value(t, second_error, k.Kernel_Error.None)
		if second != nil {
			store_wait_durable(&store, second.version)
			k.snapshot_release(second)
		}
		testing.expect_value(
			t,
			k.kernel_buffer_text(&kernel, notes, context.temp_allocator),
			"edited text",
		)

		k.kernel_detach_store(&kernel)
		store_destroy(&store)
		k.kernel_destroy(&kernel)
	}

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	store: Store
	testing.expect(
		t,
		store_open(&store, Store_Options{mode = .File, path = path, durability = .Group}),
	)
	defer store_destroy(&store)
	testing.expect(t, store_restore(&store, &kernel))

	snapshot := k.kernel_snapshot(&kernel)
	defer k.snapshot_release(snapshot)
	restored, found := k.snapshot_relation_metadata_named(snapshot, v.symbol_intern("Scratch"))
	testing.expect(t, found)
	if !found {
		return
	}
	testing.expect_value(t, restored.durability, k.Relation_Durability.Volatile)
	// The name and id survived; the working text did not.
	testing.expect_value(
		t,
		k.snapshot_buffer_text(snapshot, restored.id, context.temp_allocator),
		"",
	)
}

// The store's LOCK records its owner, so a lock left by a crashed process can
// be told apart from a live one and removed by an explicit unlock.
@(test)
test_lock_records_owner :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := temp_store_path(t, "mica_store_lock_owner")
	if path == "" {
		return
	}
	os.remove_all(path)
	defer os.remove_all(path)
	store: Store
	testing.expect(t, store_open(&store, Store_Options{mode = .File, path = path, durability = .Group}))
	defer store_destroy(&store)
	owner, known := lock_read_owner(path)
	testing.expect(t, known)
	testing.expect_value(t, owner.pid, os.get_pid())
	testing.expect(t, owner.host == lock_this_host())
}

@(private = "file")
write_lock :: proc(t: ^testing.T, path, text: string) {
	os.make_directory_all(path)
	lock_path, _ := filepath.join([]string{path, "LOCK"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(lock_path, transmute([]u8)text) == nil)
}

@(private = "file")
lock_exists :: proc(path: string) -> bool {
	lock_path, _ := filepath.join([]string{path, "LOCK"}, context.temp_allocator)
	return os.exists(lock_path)
}

// A lock whose owner is recorded on this host and no longer running is
// stale: opening names it as stale, and unlock removes it.
@(test)
test_unlock_removes_stale_lock :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := temp_store_path(t, "mica_store_lock_stale")
	if path == "" {
		return
	}
	os.remove_all(path)
	defer os.remove_all(path)
	// No process has pid 999999 on the test machines (pid_max is lower).
	write_lock(t, path, fmt.tprintf("pid 999999\nhost %s\n", lock_this_host()))
	store: Store
	testing.expect(t, !store_open(&store, Store_Options{mode = .File, path = path, durability = .Group}))
	testing.expectf(t, strings.contains(store.last_error, "stale"), "open error: %s", store.last_error)
	store_destroy(&store)

	testing.expect_value(t, store_unlock(path), Unlock_Result.Removed)
	testing.expect(t, !lock_exists(path))
	reopened: Store
	testing.expect(t, store_open(&reopened, Store_Options{mode = .File, path = path, durability = .Group}))
	store_destroy(&reopened)
}

// A live owner's lock is never removed without force; neither is one whose
// owner is unknown (an empty lock from an older version) or on another host.
@(test)
test_unlock_refuses_live_or_unknown_owner :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := temp_store_path(t, "mica_store_lock_live")
	if path == "" {
		return
	}
	os.remove_all(path)
	defer os.remove_all(path)

	write_lock(t, path, fmt.tprintf("pid %d\nhost %s\n", os.get_pid(), lock_this_host()))
	testing.expect_value(t, store_unlock(path), Unlock_Result.Owner_Running)
	testing.expect(t, lock_exists(path))

	write_lock(t, path, "")
	testing.expect_value(t, store_unlock(path), Unlock_Result.Owner_Unknown)
	testing.expect(t, lock_exists(path))

	write_lock(t, path, "pid 999999\nhost some-other-host\n")
	testing.expect_value(t, store_unlock(path), Unlock_Result.Owner_Elsewhere)
	testing.expect(t, lock_exists(path))

	testing.expect_value(t, store_unlock(path, force = true), Unlock_Result.Removed)
	testing.expect(t, !lock_exists(path))
	testing.expect_value(t, store_unlock(path), Unlock_Result.Not_Locked)
}
