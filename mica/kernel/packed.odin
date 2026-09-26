// Packed keys: one or two relation positions as sorted-unique raw 64-bit
// value words, for batched equality operators (membership now, joins in
// Stage 3). Only fixed-width (immediate) values pack: for them raw-word
// equality is value equality. Heap values (strings, lists, ...) do not, and
// their operators stay on the row path.
package kernel

import "base:runtime"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:sync"
import accel "./accel"
import v "../var"

Packed_Keys :: struct {
	width:   int,
	count:   int,
	// One column per key position, each `count` long. Two-position keys are
	// the pairs (columns[0][i], columns[1][i]), sorted lexicographically.
	columns: [][]u64,
}

// Packs rows 0..count-1 of `columns` (one per key position, 1 or 2) into
// sorted-unique keys. Fails when a value is not fixed-width or a column is
// shorter than `count`.
packed_keys_from_columns :: proc(columns: [][]v.Value, count: int, allocator: mem.Allocator) -> (keys: Packed_Keys, ok: bool) {
	width := len(columns)
	if width < 1 || width > 2 {
		return {}, false
	}
	for column in columns {
		if len(column) < count {
			return {}, false
		}
		for value in column[:count] {
			if !v.value_is_immediate(value) {
				return {}, false
			}
		}
	}
	out := make([][]u64, width, allocator)
	if width == 1 {
		words := make([]u64, count, allocator)
		copy(words, slice.reinterpret([]u64, columns[0][:count]))
		slice.sort(words)
		n := 0
		for w in words {
			if n == 0 || words[n - 1] != w {
				words[n] = w
				n += 1
			}
		}
		out[0] = words[:n]
		return Packed_Keys{width = 1, count = n, columns = out}, true
	}
	pairs := make([][2]u64, count, allocator)
	for i in 0 ..< count {
		pairs[i] = {u64(columns[0][i]), u64(columns[1][i])}
	}
	slice.sort_by(pairs, proc(a, b: [2]u64) -> bool {
		return a[0] < b[0] || (a[0] == b[0] && a[1] < b[1])
	})
	n := 0
	for p in pairs {
		if n == 0 || pairs[n - 1] != p {
			pairs[n] = p
			n += 1
		}
	}
	a := make([]u64, n, allocator)
	b := make([]u64, n, allocator)
	for i in 0 ..< n {
		a[i], b[i] = pairs[i][0], pairs[i][1]
	}
	out[0], out[1] = a, b
	return Packed_Keys{width = 2, count = n, columns = out}, true
}

// Keys packed for one relation at positions 0..width-1, plus an optional
// device-resident copy prepared for the strategy that was active when first
// requested.
Packed_Entry :: struct {
	relation: Relation_ID,
	width:    int,
	ok:       bool,
	keys:     Packed_Keys,
	prepared: accel.Prepared,
	strategy: accel.Strategy,
	// A prepare was attempted (successful or not): never retried in this
	// evaluation.
	prepare_tried: bool,
}

// Lives for one rules_evaluate_source call. A negated atom reads a relation
// from a strictly lower, finished stratum, so its rows cannot change during
// the evaluation and one gather serves every rule and round.
Packed_Cache :: struct {
	entries:   [dynamic]^Packed_Entry,
	joins:     [dynamic]^Packed_Join_Entry,
	// Cross-commit entries this evaluation reads, pinned until destroy.
	shared:    [dynamic]^Shared_Packed_Entry,
	allocator: mem.Allocator,
	builds:    int,
	prepares:  int,
}

@(thread_local, private)
packed_last_builds: int

@(thread_local, private)
packed_last_prepares: int

// Prepare attempts in the calling thread's most recent evaluation (tests).
packed_last_evaluation_prepares :: proc() -> int {
	return packed_last_prepares
}

// Gathers performed by the calling thread's most recent evaluation (tests).
packed_last_evaluation_builds :: proc() -> int {
	return packed_last_builds
}

packed_cache_create :: proc(allocator: mem.Allocator) -> ^Packed_Cache {
	cache := new(Packed_Cache, allocator)
	cache^ = Packed_Cache {
		entries   = make([dynamic]^Packed_Entry, allocator),
		joins     = make([dynamic]^Packed_Join_Entry, allocator),
		shared    = make([dynamic]^Shared_Packed_Entry, allocator),
		allocator = allocator,
	}
	return cache
}

// Releases prepared (device) copies; memory belongs to the evaluation arena.
packed_cache_destroy :: proc(cache: ^Packed_Cache) {
	if cache == nil {
		return
	}
	for entry in cache.entries {
		accel.release_prepared(entry.strategy, &entry.prepared)
	}
	shared_packed_unpin(cache.shared[:])
	packed_last_builds = cache.builds
	packed_last_prepares = cache.prepares
}

// The entry for (relation, positions 0..width-1), gathered and packed on first
// use. found=false when the source has no cache or the scan errors (entry
// nil; source.error is cleared), or the rows do not pack (entry.ok=false,
// cached so the gather is not repeated).
packed_cache_lookup :: proc(source: ^Relation_Source, relation: Relation_ID, width: int) -> (entry: ^Packed_Entry, found: bool) {
	cache := source.packed
	if cache == nil || width < 1 || width > 2 {
		return nil, false
	}
	for e in cache.entries {
		if e.relation == relation && e.width == width {
			return e, e.ok
		}
	}
	serial := shared_packed_serial(source, relation)
	if serial != 0 {
		if shared, hit := shared_packed_acquire(serial, width); hit {
			append(&cache.shared, shared)
			e := new(Packed_Entry, cache.allocator)
			e^ = Packed_Entry{relation = relation, width = width, ok = shared.ok, keys = shared.keys}
			append(&cache.entries, e)
			return e, shared.ok
		}
	}
	unbound := make([]v.Binding, width, cache.allocator)
	batch, err := relation_source_scan_columns(source, relation, unbound, cache.allocator)
	if err != .None {
		// A computed relation that needs bound keys (or an unreadable one): no
		// column; the caller's other paths handle each row.
		source.error = .None
		return nil, false
	}
	keys, ok := packed_keys_from_columns(batch.columns[:width], batch.count, cache.allocator)
	cache.builds += 1
	if serial != 0 {
		if shared := shared_packed_insert(serial, width, ok, keys); shared != nil {
			append(&cache.shared, shared)
			keys = shared.keys
		}
	}
	e := new(Packed_Entry, cache.allocator)
	e^ = Packed_Entry{relation = relation, width = width, ok = ok, keys = keys}
	append(&cache.entries, e)
	return e, ok
}

// --- Cross-commit packed keys --------------------------------------------------
//
// Keys of a relation read purely from its extensional block depend only on
// that block, which is immutable and shared by every snapshot that does not
// change the relation. They are kept across evaluations and commits, keyed by
// the block's process-unique serial (Relation_Block.serial) and the key
// width. The table is static storage: entries live from insertion until
// eviction, owned by the table's allocator (never an evaluation's arena), and
// each evaluation pins the entries it reads until packed_cache_destroy.

SHARED_PACKED_ENTRIES :: 16

Shared_Packed_Entry :: struct {
	serial: u64,
	width:  int,
	ok:     bool,
	keys:   Packed_Keys,
	arena:  ^virtual.Arena,
	used:   u64,
	pins:   int,
}

@(private)
shared_packed: struct {
	lock:      sync.Mutex,
	entries:   [SHARED_PACKED_ENTRIES]Shared_Packed_Entry,
	clock:     u64,
	allocator: runtime.Allocator,
}

// The block serial when `relation` is read purely from its extensional block
// on this source (a snapshot, readable, not computed, no derived or delta
// rows); 0 otherwise, meaning "do not share".
@(private)
shared_packed_serial :: proc(source: ^Relation_Source, relation: Relation_ID) -> u64 {
	if source.snapshot == nil || source.transaction != nil || !authority_can_read(source.authority, relation) {
		return 0
	}
	if kernel := relation_source_kernel(source); kernel != nil && kernel_relation_is_computed(kernel, relation) {
		return 0
	}
	if source.delta_active && source.delta != nil && relation == source.delta_relation {
		return 0
	}
	if rules_derived_find(source.derived, relation) != nil {
		return 0
	}
	if source.use_stored_derived {
		if block, ok := snapshot_derived_block(source.snapshot, relation); ok && relation_block_len(block) > 0 {
			return 0
		}
	}
	block, ok := snapshot_relation_block(source.snapshot, relation)
	if !ok {
		return 0
	}
	return block.serial
}

@(private)
shared_packed_acquire :: proc(serial: u64, width: int) -> (^Shared_Packed_Entry, bool) {
	sync.mutex_lock(&shared_packed.lock)
	defer sync.mutex_unlock(&shared_packed.lock)
	shared_packed.clock += 1
	for &e in shared_packed.entries {
		if e.arena != nil && e.serial == serial && e.width == width {
			e.used = shared_packed.clock
			e.pins += 1
			return &e, true
		}
	}
	return nil, false
}

// Copies `keys` into a new pinned entry, evicting the least recently used
// unpinned one; nil when every entry is pinned (the caller keeps its copy).
@(private)
shared_packed_insert :: proc(serial: u64, width: int, ok: bool, keys: Packed_Keys) -> ^Shared_Packed_Entry {
	sync.mutex_lock(&shared_packed.lock)
	defer sync.mutex_unlock(&shared_packed.lock)
	if shared_packed.allocator.procedure == nil {
		shared_packed.allocator = runtime.heap_allocator()
	}
	owner := shared_packed.allocator
	victim := -1
	for e, i in shared_packed.entries {
		if e.arena == nil {
			victim = i
			break
		}
		if e.pins == 0 && (victim < 0 || e.used < shared_packed.entries[victim].used) {
			victim = i
		}
	}
	if victim < 0 {
		return nil
	}
	arena := new(virtual.Arena, owner)
	if virtual.arena_init_growing(arena) != nil {
		free(arena, owner)
		return nil
	}
	e := &shared_packed.entries[victim]
	if e.arena != nil {
		virtual.arena_destroy(e.arena)
		free(e.arena, owner)
	}
	alloc := virtual.arena_allocator(arena)
	copied := Packed_Keys{width = keys.width, count = keys.count, columns = make([][]u64, len(keys.columns), alloc)}
	for column, c in keys.columns {
		copied.columns[c] = slice.clone(column, alloc)
	}
	shared_packed.clock += 1
	e^ = Shared_Packed_Entry {
		serial = serial,
		width  = width,
		ok     = ok,
		keys   = copied,
		arena  = arena,
		used   = shared_packed.clock,
		pins   = 1,
	}
	return e
}

@(private)
shared_packed_unpin :: proc(entries: []^Shared_Packed_Entry) {
	if len(entries) == 0 {
		return
	}
	sync.mutex_lock(&shared_packed.lock)
	defer sync.mutex_unlock(&shared_packed.lock)
	for e in entries {
		e.pins -= 1
	}
}

// Sorted key columns (one or two relation positions) with each entry's source
// row, for batched equality joins (accel.join_pairs). Entries are sorted by
// key, then row.
Packed_Join_Keys :: struct {
	columns: [][]u64,
	rows:    []u32,
}

@(private)
Packed_Join_Sort_Entry :: struct {
	k0, k1: u64,
	row:    u32,
}

// Packs `rows` (increasing) of the fixed-width key `columns` (1 or 2) into
// sorted keys, ordered by key then row. A stable LSD radix sort over 8-bit
// digits, low column first; digits equal across every key are skipped, which
// drops most passes for identities that share their high bytes. Rows start
// in increasing order and every pass is stable, so equal keys keep row order.
packed_join_keys :: proc(columns: [][]v.Value, rows: []u32, allocator: mem.Allocator) -> Packed_Join_Keys {
	width, n := len(columns), len(rows)
	a := make([]Packed_Join_Sort_Entry, n, allocator)
	b := make([]Packed_Join_Sort_Entry, n, allocator)
	defer delete(a, allocator)
	defer delete(b, allocator)
	for r, i in rows {
		a[i] = {u64(columns[0][r]), width == 2 ? u64(columns[1][r]) : 0, r}
	}
	for c := width - 1; c >= 0; c -= 1 {
		all_or, all_and := u64(0), ~u64(0)
		for e in a {
			k := c == 0 ? e.k0 : e.k1
			all_or |= k
			all_and &= k
		}
		varying := all_or ~ all_and
		for shift := uint(0); shift < 64; shift += 8 {
			if (varying >> shift) & 0xff == 0 {
				continue
			}
			counts: [256]int
			for e in a {
				k := c == 0 ? e.k0 : e.k1
				counts[(k >> shift) & 0xff] += 1
			}
			total := 0
			for d in 0 ..< 256 {
				counts[d], total = total, total + counts[d]
			}
			for e in a {
				k := c == 0 ? e.k0 : e.k1
				d := (k >> shift) & 0xff
				b[counts[d]] = e
				counts[d] += 1
			}
			a, b = b, a
		}
	}
	keys := Packed_Join_Keys {
		columns = make([][]u64, width, allocator),
		rows    = make([]u32, n, allocator),
	}
	for c in 0 ..< width {
		keys.columns[c] = make([]u64, n, allocator)
	}
	for e, i in a {
		keys.columns[0][i] = e.k0
		if width == 2 {
			keys.columns[1][i] = e.k1
		}
		keys.rows[i] = e.row
	}
	return keys
}

// Sorted join keys for (relation, positions) at a given row count. Rows only
// accumulate during an evaluation, so an equal count means the same rows.
Packed_Join_Entry :: struct {
	relation:  Relation_ID,
	positions: [2]int,
	width:     int,
	count:     int,
	keys:      Packed_Join_Keys,
}

packed_join_lookup :: proc(cache: ^Packed_Cache, relation: Relation_ID, positions: []int, count: int) -> ^Packed_Join_Entry {
	if cache == nil {
		return nil
	}
	for e in cache.joins {
		if e.relation == relation && e.width == len(positions) && e.count == count &&
		   e.positions[0] == positions[0] && (e.width == 1 || e.positions[1] == positions[1]) {
			return e
		}
	}
	return nil
}

packed_join_store :: proc(cache: ^Packed_Cache, relation: Relation_ID, positions: []int, count: int, keys: Packed_Join_Keys) {
	e := new(Packed_Join_Entry, cache.allocator)
	e^ = Packed_Join_Entry{relation = relation, width = len(positions), count = count, keys = keys}
	for p, i in positions {
		e.positions[i] = p
	}
	append(&cache.joins, e)
}
