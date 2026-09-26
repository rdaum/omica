// Kernel entry point: published world state and catalog changes.
//
// The kernel owns the current snapshot. Relation creation, rule installation,
// and rule disabling publish a new snapshot immediately. Ordinary fact changes
// go through transactions obtained from `kernel_begin`.
package kernel

import buf "../buffer"
import v "../var"
import "base:runtime"
import "core:mem"
import "core:mem/virtual"
import "core:sync"

// Published world state.
//
// `current` is published atomically. Readers load and retain the snapshot with
// no lock; this is safe because every snapshot retains its parent, so a
// snapshot loaded just before a concurrent publish stays alive through its
// descendant chain. Writers serialise validate-fork-publish on `commit_lock`,
// matching Rust mica's commit mutex. Loads are lock-free, so a long commit
// never blocks transaction begins or scans.
Kernel :: struct {
	current:              ^Snapshot,
	catalog_lock:         sync.Mutex,

	// One striped lock per relation id. Commits hold the stripes for the
	// relations they write, so candidates for the same relation are prepared
	// in order while writes to different relations proceed in parallel.
	relation_locks:       [RELATION_LOCK_STRIPES]sync.Mutex,

	// Group publication. Prepared candidates queue here; the first task
	// thread to enqueue drains the batch and publishes every candidate in one
	// snapshot. This stops independent tasks from invalidating each other's
	// candidates, which otherwise causes retry amplification under load.
	commit_queue_lock:    sync.Mutex,
	commit_queue_cond:    sync.Cond,
	pending_commits:      [dynamic]^Commit_Entry,
	committer_active:     bool,

	// Reader-count reclamation (RCU-style). A reader increments `readers`
	// around load-and-retain; a publisher swaps `current`, moves the previous
	// snapshot to `retired`, and frees retired snapshots only while no reader
	// is active. This closes the load-then-retain race without a lock on the
	// read path.
	readers:              [READER_SLOTS]Reader_Slot,
	retire_lock:          sync.Mutex,
	retired:              [dynamic]^Snapshot,
	// Number of snapshots awaiting reclamation. Zero lets reader exits skip
	// the retire lock entirely.
	retire_pending:       i32,

	// While true, commits apply extensional writes but skip derived-relation
	// maintenance. Bulk ingest suspends the fixpoint and resumes once at the
	// end instead of re-deriving per batch. Atomic: written by a controlling
	// task, read on every commit path.
	derivation_suspended: bool,
	// Rule fixpoints this kernel has run over a snapshot (see
	// kernel_derivation_count). Atomic: incremented on any commit path.
	derivations:          u64,

	// Relation metadata and rule definitions live here for the life of the
	// kernel; blocks and snapshots reference their slices.
	world:                ^virtual.Arena,
	world_allocator:      mem.Allocator,

	// Arenas for transaction staging, snapshot arrays, derived rows, and
	// block payloads. Arenas are reset on release and reused, so the hot path
	// performs no arena creation at all.
	arena_pool:           ^Arena_Pool,

	// Bearer capabilities minted for this world. Ephemeral; not persisted.
	capabilities:         Capability_Store,

	// Chunk and piece-node pools shared by every buffer in this world.
	buffer_store:         buf.Store,

	// Bounded per-buffer reversion history: the retained versions a
	// `buffer_revert` can splice back in.
	buffer_history:       Buffer_History,

	// Recent client-tagged buffer completions, read back after publication.
	buffer_results:       Buffer_Result_Ring,

	// Read-only relation implementations supplied by the runtime.
	computed:             Computed_Registry,

	// Highest id reserved by a transaction for a staged catalogue creation.
	// Reservations are never reused, so an aborted transaction merely leaves a
	// gap, which is preferable to two concurrent creators colliding.
	staged_id_high:       u32,

	// Bounded window of committed fact changes for subscriptions.
	changes:              Change_Feed,

	// Optional durable store hooks. Zero value means in-memory only.
	store:                Store_Hooks,
}

// A pool of reset-able virtual arenas shared by transactions, snapshots, and
// relation blocks. Sharded by thread so concurrent take/return paths do not
// convoy on a single lock.
ARENA_POOL_SHARDS :: 16

// Padded reader counters. Threads spread load-and-retain announcements
// across slots so snapshot acquisition under parallel load does not ping-pong
// one cache line. Sharing a slot is harmless for counters (increments
// compose); hazard pins below are claimed exclusively instead.
READER_SLOTS :: 16

// Number of relation commit stripes.
RELATION_LOCK_STRIPES :: 64

@(private)
Reader_Slot :: struct {
	count:   i32,
	// Hazard pointer for borrowed (non-retained) snapshot reads.
	hazard:  ^Snapshot,
	// Set while a thread holds this slot as its exclusive hazard pin. The
	// count field needs no exclusivity (concurrent increments compose), but
	// a hazard pin must never be shared: two borrowers on one slot would
	// overwrite each other's pin and let reclamation free a live snapshot.
	claimed: u32,
	_pad:    [12]i32,
}

@(private)
global_reader_slot_counter: u32

@(thread_local)
reader_slot_hint: u32

@(thread_local)
reader_slot_ready: bool

@(private)
reader_slot_index :: proc() -> u32 {
	if !reader_slot_ready {
		assigned := sync.atomic_add(&global_reader_slot_counter, 1)
		reader_slot_hint = assigned % READER_SLOTS
		reader_slot_ready = true
	}
	return reader_slot_hint
}

// Claims an unused hazard slot from `kernel` for the calling thread. At most
// READER_SLOTS threads can hold a hazard pin on one kernel at a time; when
// all slots are claimed the caller must retain instead (see
// kernel_snapshot_borrow). Lock-free: a single CAS per candidate slot.
@(private)
reader_slot_claim :: proc(kernel: ^Kernel) -> (^Reader_Slot, bool) {
	for &slot in kernel.readers {
		_, claimed := sync.atomic_compare_exchange_strong_explicit(
			&slot.claimed,
			u32(0),
			u32(1),
			.Acquire,
			.Acquire,
		)
		if claimed {
			return &slot, true
		}
	}
	return nil, false
}

// Releases a claimed hazard slot. Clears the pin before unclaiming so a
// concurrent claim can never observe a stale pin.
@(private)
reader_slot_release :: proc(slot: ^Reader_Slot) {
	sync.atomic_store_explicit(&slot.hazard, nil, .Release)
	sync.atomic_store_explicit(&slot.claimed, u32(0), .Release)
}

// The calling thread's outstanding hazard borrow, if any. Borrows are not
// nestable: at most one snapshot is borrowed per thread at a time.
@(thread_local)
hazard_borrow_slot: ^Reader_Slot

@(thread_local)
hazard_borrow_kernel: ^Kernel

// Non-nil when the borrow fell back to retain/release because every hazard
// slot was claimed. Cleared by releasing the snapshot.
@(thread_local)
hazard_borrow_retained: ^Snapshot

// Reports whether any hazard slot pins `snapshot`.
@(private)
kernel_snapshot_hazarded :: proc(kernel: ^Kernel, snapshot: ^Snapshot) -> bool {
	for &slot in kernel.readers {
		if sync.atomic_load(&slot.hazard) == snapshot {
			return true
		}
	}
	return false
}

// Reports whether any reader is inside a load-and-retain window.
@(private)
kernel_readers_idle :: proc(kernel: ^Kernel) -> bool {
	for &slot in kernel.readers {
		if sync.atomic_load(&slot.count) != 0 {
			return false
		}
	}
	return true
}

Arena_Pool_Shard :: struct {
	lock:   sync.Mutex,
	arenas: [dynamic]^Frame_Arena,
}

Arena_Pool :: struct {
	shards:      [ARENA_POOL_SHARDS]Arena_Pool_Shard,
	// Arenas currently checked out. Diagnostics only.
	live_arenas: i32,
}

// Each thread is assigned a stable shard once, avoiding a `gettid` syscall on
// every take and return.
@(private)
global_arena_shard_counter: u32

@(thread_local)
arena_pool_hint: u32

@(thread_local)
arena_pool_hint_ready: bool

@(private)
arena_pool_shard_index :: proc() -> u32 {
	if !arena_pool_hint_ready {
		assigned := sync.atomic_add(&global_arena_shard_counter, 1)
		arena_pool_hint = assigned % ARENA_POOL_SHARDS
		arena_pool_hint_ready = true
	}
	return arena_pool_hint
}

@(private)
arena_pool_shard :: proc(pool: ^Arena_Pool) -> ^Arena_Pool_Shard {
	return &pool.shards[arena_pool_shard_index()]
}

arena_pool_init :: proc(pool: ^Arena_Pool) {
	for index in 0 ..< ARENA_POOL_SHARDS {
		pool.shards[index].arenas = make([dynamic]^Frame_Arena)
	}
}

arena_pool_take :: proc(pool: ^Arena_Pool) -> ^Frame_Arena {
	hint := arena_pool_shard_index()

	// Prefer the local shard, then steal from siblings. Arenas are created and
	// released by different committing threads, so without stealing the hot
	// path falls back to a fresh arena (and mmap) on nearly every commit.
	for offset in 0 ..< ARENA_POOL_SHARDS {
		shard := &pool.shards[(hint + u32(offset)) % ARENA_POOL_SHARDS]
		sync.mutex_lock(&shard.lock)
		if len(shard.arenas) > 0 {
			arena := pop(&shard.arenas)
			sync.mutex_unlock(&shard.lock)
			sync.atomic_add(&pool.live_arenas, 1)
			return arena
		}
		sync.mutex_unlock(&shard.lock)
	}

	arena := new(Frame_Arena, runtime.default_allocator())
	frame_arena_init(arena)
	sync.atomic_add(&pool.live_arenas, 1)
	return arena
}

// Returns the number of arenas currently checked out of the pool.
arena_pool_live_count :: proc(pool: ^Arena_Pool) -> int {
	return int(sync.atomic_load(&pool.live_arenas))
}

// Returns the number of idle arenas held by the pool.
arena_pool_idle_count :: proc(pool: ^Arena_Pool) -> int {
	total := 0
	for index in 0 ..< ARENA_POOL_SHARDS {
		shard := &pool.shards[index]
		sync.mutex_lock(&shard.lock)
		total += len(shard.arenas)
		sync.mutex_unlock(&shard.lock)
	}
	return total
}

arena_pool_return :: proc(pool: ^Arena_Pool, arena: ^Frame_Arena) {
	if arena == nil {
		return
	}
	frame_arena_reset(arena)
	// A pooled arena keeps only a small budget: one that held a large derived
	// copy would otherwise stay that large while idle or under a small user.
	frame_arena_trim(arena, FRAME_POOL_KEEP)
	sync.atomic_sub(&pool.live_arenas, 1)

	// Return to the local shard; a thread's arenas tend to be reused by it.
	shard := arena_pool_shard(pool)
	sync.mutex_lock(&shard.lock)
	append(&shard.arenas, arena)
	sync.mutex_unlock(&shard.lock)
}

arena_pool_destroy :: proc(pool: ^Arena_Pool) {
	for index in 0 ..< ARENA_POOL_SHARDS {
		shard := &pool.shards[index]
		for arena in shard.arenas {
			frame_arena_destroy(arena)
			free(arena, runtime.default_allocator())
		}
		delete(shard.arenas)
	}
}

// Creates a kernel with an empty snapshot and an empty committed store.
kernel_init :: proc(kernel: ^Kernel) {
	kernel.world = new(virtual.Arena, runtime.default_allocator())
	if err := virtual.arena_init_growing(kernel.world); err != nil {
		panic("failed to initialize the committed store arena")
	}
	kernel.world_allocator = virtual.arena_allocator(kernel.world)
	kernel.arena_pool = new(Arena_Pool, runtime.default_allocator())
	arena_pool_init(kernel.arena_pool)
	kernel.retired = make([dynamic]^Snapshot)
	kernel.pending_commits = make([dynamic]^Commit_Entry)
	capability_store_init(&kernel.capabilities)
	changes_init(&kernel.changes)
	buf.store_init(&kernel.buffer_store, runtime.default_allocator())
	buffer_history_init(&kernel.buffer_history, runtime.default_allocator())
	buffer_result_ring_init(&kernel.buffer_results, runtime.default_allocator())
	computed_registry_init(&kernel.computed, runtime.default_allocator())
	kernel.current = snapshot_create(kernel, 0, nil)
}

// Releases the published snapshot, the committed store, and the staging pool.
// The caller must guarantee no other thread uses the kernel.
kernel_destroy :: proc(kernel: ^Kernel) {
	current := sync.atomic_load(&kernel.current)
	sync.atomic_store(&kernel.current, nil)
	snapshot_release(current)

	for retired in kernel.retired {
		snapshot_release(retired)
	}
	delete(kernel.retired)
	delete(kernel.pending_commits)
	capability_store_destroy(&kernel.capabilities)
	changes_destroy(&kernel.changes)
	buffer_result_ring_destroy(&kernel.buffer_results)
	computed_registry_destroy(&kernel.computed)
	// Retained history blocks keep piece trees alive, so release them before
	// the pools that own those chunks and nodes.
	buffer_history_destroy(&kernel.buffer_history)
	// Every snapshot that referenced a buffer block has been released, so the
	// pools are safe to tear down.
	buf.store_destroy(&kernel.buffer_store)

	if kernel.arena_pool != nil {
		arena_pool_destroy(kernel.arena_pool)
		free(kernel.arena_pool, runtime.default_allocator())
		kernel.arena_pool = nil
	}

	if kernel.world != nil {
		virtual.arena_destroy(kernel.world)
		free(kernel.world, runtime.default_allocator())
		kernel.world = nil
	}
}

// Returns a reset staging arena, creating one on demand.
@(private)
kernel_take_arena :: proc(kernel: ^Kernel) -> ^Frame_Arena {
	return arena_pool_take(kernel.arena_pool)
}

// Resets `arena` and returns it to the pool for reuse.
@(private)
kernel_return_arena :: proc(kernel: ^Kernel, arena: ^Frame_Arena) {
	arena_pool_return(kernel.arena_pool, arena)
}

// Replaces a relation block in the current snapshot. The new block must have
// the same relation id and arity as the catalog entry; the old block is
// released. `snapshot_set_block` takes ownership of the block reference on
// every path, so the caller must not release the block after the call — the
// fork releases it on `.Conflict`, and the published snapshot owns it on
// success.
//
// This is a direct publish that skips the normal transaction path, so it does
// not record a change-feed entry or admit persistence. It is intended for
// tests and benchmarks that need to reset a relation's state between samples.
// Derived facts that depend on the replaced relation are not recomputed; the
// caller must ensure no active rules read this relation, or call
// `snapshot_compute_derived` on the returned snapshot before publishing it.
kernel_replace_relation_block :: proc(
	kernel: ^Kernel,
	block: ^Relation_Block,
) -> (
	^Snapshot,
	Kernel_Error,
) {
	current := kernel_snapshot(kernel)
	metadata, ok := snapshot_relation_metadata(current, block.metadata.id)
	if !ok {
		snapshot_release(current)
		return nil, .Unknown_Relation
	}
	if metadata.arity != block.metadata.arity {
		snapshot_release(current)
		return nil, .Invalid_Metadata
	}

	next := snapshot_fork(kernel, current)
	// `snapshot_set_block` takes ownership of the block reference. If the
	// publish fails, the fork is released and the block is released with it;
	// the caller must not release the block on either path.
	snapshot_set_block(next, block)
	previous, published := kernel_try_publish(kernel, current, next)
	if !published {
		// The publish failed: another publisher won. The fork (and the block
		// it adopted) is released; the caller's reference is consumed.
		snapshot_release(next)
		snapshot_release(current)
		return nil, .Conflict
	}
	kernel_retire(kernel, previous)
	snapshot_release(current)
	return next, .None
}

// Returns a retained reference to the current snapshot. The caller must
// release it. Lock-free: the reader is announced in `readers` while it loads
// and retains, so a publisher cannot free the snapshot underneath it.
kernel_snapshot :: proc(kernel: ^Kernel) -> ^Snapshot {
	slot := &kernel.readers[reader_slot_index()]
	sync.atomic_add_explicit(&slot.count, 1, .Acq_Rel)
	current := sync.atomic_load(&kernel.current)
	snapshot_retain(current)
	if sync.atomic_sub_explicit(&slot.count, 1, .Acq_Rel) == 1 &&
	   sync.atomic_load(&kernel.retire_pending) > 0 &&
	   kernel_readers_idle(kernel) {
		kernel_reclaim(kernel)
	}
	return current
}

// Borrows the current snapshot without retaining it. The caller must use it
// only until `kernel_hazard_clear`, must not release it, and must not borrow
// again before clearing. Reclamation keeps a hazard-pinned snapshot alive.
//
// The pin lives in a hazard slot claimed exclusively by the calling thread,
// so concurrent borrowers can never overwrite each other's pin. When every
// slot is already claimed the borrow transparently retains instead, and the
// clear releases it; the caller cannot tell the difference.
kernel_snapshot_borrow :: proc(kernel: ^Kernel) -> ^Snapshot {
	slot, claimed := reader_slot_claim(kernel)
	if !claimed {
		snapshot := kernel_snapshot(kernel)
		hazard_borrow_slot = nil
		hazard_borrow_kernel = kernel
		hazard_borrow_retained = snapshot
		return snapshot
	}
	for {
		current := sync.atomic_load(&kernel.current)
		sync.atomic_store_explicit(&slot.hazard, current, .Release)
		// If a publisher swapped between the load and the hazard store, pin
		// the newer snapshot instead.
		if sync.atomic_load(&kernel.current) == current {
			hazard_borrow_slot = slot
			hazard_borrow_kernel = kernel
			hazard_borrow_retained = nil
			return current
		}
	}
}

// Clears the calling thread's hazard borrow. Releases the claimed slot, or
// the retained snapshot when the borrow fell back. Only acts on a borrow
// from `kernel`; clearing any other kernel is a no-op.
kernel_hazard_clear :: proc(kernel: ^Kernel) {
	if hazard_borrow_kernel != kernel {
		return
	}
	if hazard_borrow_slot != nil {
		reader_slot_release(hazard_borrow_slot)
	} else if hazard_borrow_retained != nil {
		snapshot_release(hazard_borrow_retained)
	}
	hazard_borrow_kernel = nil
	hazard_borrow_slot = nil
	hazard_borrow_retained = nil
}

// Begins a transaction over the current snapshot.
kernel_begin :: proc(kernel: ^Kernel) -> Transaction {
	return transaction_begin(kernel)
}

// Returns the next unused relation id.
// Reserves a catalogue id for a staged creation. Ids are monotonic and never
// reused; `kernel_next_relation_id` keeps its scan semantics for callers that
// want the next free slot rather than a reservation.
kernel_reserve_relation_id :: proc(kernel: ^Kernel) -> Relation_ID {
	sync.mutex_lock(&kernel.catalog_lock)
	defer sync.mutex_unlock(&kernel.catalog_lock)

	next := u32(kernel_next_relation_id(kernel))
	if kernel.staged_id_high + 1 > next {
		next = kernel.staged_id_high + 1
	}
	kernel.staged_id_high = next
	return Relation_ID(next)
}

kernel_next_relation_id :: proc(kernel: ^Kernel) -> Relation_ID {
	current := kernel_snapshot(kernel)
	defer snapshot_release(current)

	next := u32(1)
	for metadata in current.catalog {
		if u32(metadata.id) >= next {
			next = u32(metadata.id) + 1
		}
	}
	return Relation_ID(next)
}

// Publishes `next` if `expected` is still the published snapshot. Each task
// commits on its own thread, so this is a direct compare-exchange: on failure
// the caller holds the winner, rebases its prepared blocks in place, and tries
// again. On success the kernel holds a reference to `next` and the previous
// snapshot is returned for the caller to retire.
@(private)
kernel_try_publish :: proc(
	kernel: ^Kernel,
	expected, next: ^Snapshot,
) -> (
	previous: ^Snapshot,
	published: bool,
) {
	snapshot_retain(next)
	_, swapped := sync.atomic_compare_exchange_strong_explicit(
		&kernel.current,
		expected,
		next,
		.Acq_Rel,
		.Acquire,
	)
	if swapped {
		changes_note_version(&kernel.changes, next.version)
		return expected, true
	}
	snapshot_release(next)
	return nil, false
}

// Maximum rebase attempts for a solo publication before reporting a conflict.
PUBLISH_ATTEMPT_LIMIT :: 64

// A prepared commit waiting for a group publication.
Commit_Entry :: struct {
	transaction: ^Transaction,
	// Durable budget reservation from admission; consumed by the store on
	// successful publication.
	ticket:      Persist_Ticket,
	// The snapshot the candidate was prepared against, retained by the owner.
	base:        ^Snapshot,
	candidate:   ^Snapshot,
	published:   ^Snapshot,
	done:        bool,
}

// Adds a prepared candidate to the commit queue. Returns true when the caller
// should drain the queue.
@(private)
kernel_commit_enqueue :: proc(kernel: ^Kernel, entry: ^Commit_Entry) -> bool {
	sync.mutex_lock(&kernel.commit_queue_lock)
	append(&kernel.pending_commits, entry)
	become_committer := !kernel.committer_active
	if become_committer {
		kernel.committer_active = true
	}
	sync.mutex_unlock(&kernel.commit_queue_lock)
	return become_committer
}

// Blocks until `entry` has been published.
@(private)
kernel_commit_wait :: proc(kernel: ^Kernel, entry: ^Commit_Entry) {
	sync.mutex_lock(&kernel.commit_queue_lock)
	for !entry.done {
		sync.cond_wait(&kernel.commit_queue_cond, &kernel.commit_queue_lock)
	}
	sync.mutex_unlock(&kernel.commit_queue_lock)
}

// Drains and publishes commit batches until the queue is empty. Any task
// thread can be the committer; the role is not a dedicated thread.
@(private)
kernel_committer_drain :: proc(kernel: ^Kernel) {
	for {
		sync.mutex_lock(&kernel.commit_queue_lock)
		if len(kernel.pending_commits) == 0 {
			kernel.committer_active = false
			sync.mutex_unlock(&kernel.commit_queue_lock)
			return
		}
		batch := make([dynamic]^Commit_Entry, len(kernel.pending_commits))
		copy(batch[:], kernel.pending_commits[:])
		clear(&kernel.pending_commits)
		sync.mutex_unlock(&kernel.commit_queue_lock)

		kernel_publish_group(kernel, batch[:])

		sync.mutex_lock(&kernel.commit_queue_lock)
		for entry in batch {
			entry.done = true
		}
		sync.cond_broadcast(&kernel.commit_queue_cond)
		sync.mutex_unlock(&kernel.commit_queue_lock)
		delete(batch)
	}
}

// Merges every candidate's prepared blocks into one snapshot and publishes it
// once. Candidates are stripe-protected and write disjoint relations, so the
// merge adopts prepared blocks; only the surrounding snapshot arrays are
// rebuilt. A lone candidate publishes directly.
@(private)
kernel_publish_group :: proc(kernel: ^Kernel, batch: []^Commit_Entry) {
	if len(batch) == 1 {
		entry := batch[0]
		for _ in 0 ..< PUBLISH_ATTEMPT_LIMIT {
			previous, published := kernel_try_publish(kernel, entry.base, entry.candidate)
			if published {
				kernel_retire(kernel, previous)
				snapshot_release(entry.base)
				entry.base = nil
				entry.published = entry.candidate
				changes_record_writes(
					&kernel.changes,
					entry.candidate.version,
					entry.transaction.writes[:],
				)
				changes_record_buffers(
					&kernel.changes,
					entry.candidate.version,
					entry.transaction.buffer_writes[:],
				)
				kernel_store_persist(
					kernel,
					entry.ticket,
					entry.candidate.version,
					entry.candidate,
					entry.transaction.writes[:],
					entry.transaction.buffer_writes[:],
				)
				entry.ticket = 0
				kernel_record_buffer_completions(kernel, entry.transaction)
				kernel_sync_buffer_history(kernel, entry.candidate, entry.transaction)
				return
			}
			winner := kernel_snapshot(kernel)
			if transaction_rebase_in_place(kernel, entry.transaction, entry.candidate, winner) {
				snapshot_release(entry.base)
				entry.base = winner
				continue
			}
			// The winner's shape changed (a catalog operation). Adopt it as
			// the new base and rebuild the candidate from it.
			snapshot_release(entry.candidate)
			snapshot_release(entry.base)
			entry.base = winner
			entry.candidate = transaction_build_candidate(kernel, entry.transaction, entry.base)
			if entry.transaction.catalog_conflict || entry.transaction.buffer_conflict {
				// A staged entry now collides, or a buffer change could not be
				// reconciled; give up and let the owner re-read and retry.
				break
			}
		}
		// Give up rather than spin; the owner retries the transaction.
		snapshot_release(entry.candidate)
		snapshot_release(entry.base)
		entry.candidate = nil
		entry.base = nil
		entry.published = nil
		return
	}

	for {
		base := kernel_snapshot(kernel)
		merged := snapshot_fork(kernel, base)

		// A candidate whose staged catalogue entry now collides with a name
		// created concurrently is excluded from this publication. It is left
		// unpublished, so its owner retries and re-checks against the new base.
		publishable: [dynamic]^Commit_Entry
		publishable = make([dynamic]^Commit_Entry, context.temp_allocator)
		for entry in batch {
			collides := false
			for change in entry.transaction.catalog_changes {
				if change.kind != .Create {continue}
				_, name_exists := snapshot_relation_metadata_named(merged, change.metadata.name)
				if name_exists || snapshot_has_relation(merged, change.metadata.id) {
					collides = true
					break
				}
				// Accepted candidates have not been applied to merged yet. Check
				// them too, so two entries in one group cannot claim the same name.
				for accepted in publishable {
					for other in accepted.transaction.catalog_changes {
						if other.kind == .Create && (other.metadata.name == change.metadata.name || other.metadata.id == change.metadata.id) {
							collides = true
							break
						}
					}
					if collides {break}
				}
				if collides {break}
			}

			if !collides {
				append(&publishable, entry)
			}
		}
		if len(publishable) == 0 {
			snapshot_release(merged)
			snapshot_release(base)
			return
		}

		for entry in publishable {
			// A candidate is a full snapshot. Adopting all of it would let a
			// later candidate restore the old blocks for relations or buffers
			// changed by an earlier candidate in this same group. Merge only
			// the entries this transaction owns under its write stripes.
			for writes in entry.transaction.writes {
				if block, found := snapshot_relation_block(entry.candidate, writes.relation);
				   found {
					relation_block_retain(block)
					snapshot_set_block(merged, block)
				}
			}
			for writes in entry.transaction.buffer_writes {
				if block, found := snapshot_buffer(entry.candidate, writes.relation); found {
					buffer_block_retain(block)
					snapshot_set_buffer(merged, block)
				}
			}
			// Killing a buffer changes its block without creating a buffer
			// write set, so carry that candidate block explicitly.
			for change in entry.transaction.catalog_changes {
				if change.kind != .Kill || change.metadata.storage != .Buffer {
					continue
				}
				if block, found := snapshot_buffer(entry.candidate, change.metadata.id); found {
					buffer_block_retain(block)
					snapshot_set_buffer(merged, block)
				}
			}
			// Apply only this transaction's catalogue changes. Like blocks, a
			// candidate's full catalogue also contains stale copies of every
			// entry it did not change.
			for change in entry.transaction.catalog_changes {
				switch change.kind {
				case .Create:
					if metadata, found := snapshot_relation_metadata(
						entry.candidate,
						change.metadata.id,
					); found {
						// Candidate metadata already has kernel lifetime.
						snapshot_add_relation(merged, metadata)
					}
				case .Kill:
					for &metadata in merged.catalog {
						if metadata.id == change.metadata.id {
							metadata.tombstoned = true
							break
						}
					}
				}
			}
		}
		kernel_compute_derived(kernel, merged)

		previous, published := kernel_try_publish(kernel, base, merged)
		if published {
			kernel_retire(kernel, previous)
			merged_writes: [dynamic]Relation_Writes
			defer delete(merged_writes)
			merged_buffers: [dynamic]Buffer_Writes
			defer delete(merged_buffers)
			for entry in publishable {
				append(&merged_writes, ..entry.transaction.writes[:])
				append(&merged_buffers, ..entry.transaction.buffer_writes[:])
				snapshot_retain(merged)
				entry.published = merged
				snapshot_release(entry.candidate)
				snapshot_release(entry.base)
				entry.base = nil
			}
			changes_record_writes(&kernel.changes, merged.version, merged_writes[:])
			changes_record_buffers(&kernel.changes, merged.version, merged_buffers[:])
			// One record per published version: relation writes, buffer
			// writes, and catalogue changes from every batched transaction are
			// aggregated into a single durable record, so a torn tail can never
			// leave half a version applied. The remaining reservations are
			// released against that one publish.
			kernel_store_persist(
				kernel,
				publishable[0].ticket,
				merged.version,
				merged,
				merged_writes[:],
				merged_buffers[:],
			)
			publishable[0].ticket = 0
			for entry in publishable[1:] {
				kernel_release_persist(kernel, entry.ticket)
				entry.ticket = 0
			}
			for entry in publishable {
				kernel_record_buffer_completions(kernel, entry.transaction)
				kernel_sync_buffer_history(kernel, merged, entry.transaction)
			}
			snapshot_release(base)
			return
		}
		snapshot_release(merged)
		snapshot_release(base)
	}
}

// Moves `snapshot` to the retired list and reclaims retired snapshots when no
// reader is in its load-and-retain window.
@(private)
kernel_retire :: proc(kernel: ^Kernel, snapshot: ^Snapshot) {
	if snapshot == nil {
		return
	}
	sync.mutex_lock(&kernel.retire_lock)
	append(&kernel.retired, snapshot)
	sync.atomic_add(&kernel.retire_pending, 1)
	sync.mutex_unlock(&kernel.retire_lock)

	if kernel_readers_idle(kernel) {
		kernel_reclaim(kernel)
	}
}

// Releases every retired snapshot when no reader is active. Safe to call from
// any thread; the final reader out of its window calls it.
@(private)
kernel_reclaim :: proc(kernel: ^Kernel) {
	sync.mutex_lock(&kernel.retire_lock)
	defer sync.mutex_unlock(&kernel.retire_lock)

	// A reader may have entered while we waited for the lock.
	if !kernel_readers_idle(kernel) {
		return
	}
	write := 0
	released := 0
	for retired in kernel.retired {
		if kernel_snapshot_hazarded(kernel, retired) {
			kernel.retired[write] = retired
			write += 1
			continue
		}
		snapshot_release(retired)
		released += 1
	}
	resize(&kernel.retired, write)
	sync.atomic_sub(&kernel.retire_pending, i32(released))
}

// Creates a relation and publishes a new snapshot. The returned snapshot is
// caller-owned.
kernel_create_relation :: proc(
	kernel: ^Kernel,
	metadata: Relation_Metadata,
) -> (
	^Snapshot,
	Kernel_Error,
) {
	sync.mutex_lock(&kernel.catalog_lock)
	defer sync.mutex_unlock(&kernel.catalog_lock)

	for {
		current := kernel_snapshot(kernel)
		if _, exists := snapshot_relation_metadata_named(current, metadata.name); exists {
			snapshot_release(current)
			return nil, .Duplicate_Relation_Name
		}
		if snapshot_has_relation(current, metadata.id) {
			snapshot_release(current)
			return nil, .Invalid_Metadata
		}
		if err := validate_relation_metadata(metadata); err != .None {
			snapshot_release(current)
			return nil, err
		}

		next := snapshot_fork(kernel, current)
		snapshot_add_relation(next, metadata_clone(kernel.world_allocator, metadata))
		if metadata.storage == .Buffer {
			// A buffer starts empty; its first edit publishes revision 1.
			block := buffer_block_create(&kernel.buffer_store, metadata.id, nil, 0, 0)
			snapshot_set_buffer(next, block)
		}
		kernel_compute_derived(kernel, next)
		previous, published := kernel_try_publish(kernel, current, next)
		if published {
			kernel_retire(kernel, previous)
			snapshot_release(current)
			changes_record_catalog(
				&kernel.changes,
				next.version,
				[]Catalog_Change {
					{kind = .Relation_Created, relation = metadata.id, name = metadata.name},
				},
			)
			kernel_store_persist(kernel, 0, next.version, next, nil, nil)
			return next, .None
		}
		snapshot_release(next)
		snapshot_release(current)
	}
}

// Raises the current snapshot version to at least `minimum` without changing
// published state. Booting from a store uses this so new commits continue
// above the durable log's versions.
kernel_advance_version :: proc(kernel: ^Kernel, minimum: u64) -> bool {
	sync.mutex_lock(&kernel.catalog_lock)
	defer sync.mutex_unlock(&kernel.catalog_lock)
	for {
		current := kernel_snapshot(kernel)
		if current.version >= minimum {
			snapshot_release(current)
			return true
		}
		next := snapshot_fork(kernel, current)
		next.version = minimum
		kernel_compute_derived(kernel, next)
		previous, published := kernel_try_publish(kernel, current, next)
		if published {
			kernel_retire(kernel, previous)
			kernel_store_persist(kernel, 0, next.version, next, nil, nil)
			snapshot_release(current)
			return true
		}
		snapshot_release(next)
		snapshot_release(current)
	}
}

// Whether derived-relation maintenance is currently suspended. Read on every
// commit path; the atomic keeps the flag visible without a lock.
@(private)
kernel_derivation_suspended :: proc(kernel: ^Kernel) -> bool {
	return sync.atomic_load_explicit(&kernel.derivation_suspended, .Acquire)
}

// How many times the kernel has run the rule fixpoint over a snapshot.
kernel_derivation_count :: proc(kernel: ^Kernel) -> u64 {
	return sync.atomic_load_explicit(&kernel.derivations, .Acquire)
}

// Recomputes a snapshot's derived relations unless maintenance is suspended.
@(private)
kernel_compute_derived :: proc(kernel: ^Kernel, snapshot: ^Snapshot) {
	if kernel_derivation_suspended(kernel) {
		return
	}
	snapshot_compute_derived(snapshot, kernel)
}

// Enables or suspends derived-relation maintenance. While suspended, commits
// apply extensional writes only: derived relations stay empty (a fork starts
// with none) and the fixpoint runs on resume, once, over every installed rule
// instead of once per commit. Resuming publishes a snapshot with the derived
// rows materialized and returns false only when it cannot win a publication.
kernel_set_derivation :: proc(kernel: ^Kernel, enabled: bool) -> bool {
	if !enabled {
		sync.atomic_store_explicit(&kernel.derivation_suspended, true, .Release)
		return true
	}

	// Clear the flag before publishing: a commit that races the resume then
	// maintains derived state itself instead of publishing a fork with none.
	// The loop retries until it publishes on top of the winner.
	sync.atomic_store_explicit(&kernel.derivation_suspended, false, .Release)
	for {
		current := kernel_snapshot(kernel)
		next := snapshot_fork(kernel, current)
		snapshot_compute_derived(next, kernel)
		previous, published := kernel_try_publish(kernel, current, next)
		if published {
			kernel_retire(kernel, previous)
			kernel_store_persist(kernel, 0, next.version, next, nil, nil)
			snapshot_release(current)
			return true
		}
		snapshot_release(next)
		snapshot_release(current)
	}
}

// Installs a rule and publishes a new snapshot. The returned snapshot is
// caller-owned.
kernel_install_rule :: proc(
	kernel: ^Kernel,
	id: v.Identity,
	rule: Rule,
	source: string,
) -> (
	^Snapshot,
	Kernel_Error,
) {
	sync.mutex_lock(&kernel.catalog_lock)
	defer sync.mutex_unlock(&kernel.catalog_lock)

	scratch := new(virtual.Arena)
	if err := virtual.arena_init_growing(scratch); err != nil {
		panic("failed to initialize rule validation arena")
	}
	defer {
		virtual.arena_destroy(scratch)
		free(scratch)
	}
	scratch_alloc := virtual.arena_allocator(scratch)

	for {
		current := kernel_snapshot(kernel)
		if err := rule_validate_arity(rule, current); err != .None {
			snapshot_release(current)
			return nil, err
		}
		if err := rule_validate_safety(rule, scratch_alloc); err != .None {
			snapshot_release(current)
			return nil, err
		}

		next := snapshot_fork(kernel, current)
		snapshot_add_rule(
			next,
			rule_definition_clone(kernel.world_allocator, rule_definition(id, rule, source)),
		)

		active := snapshot_active_rules(next, scratch_alloc)
		if _, ok := rules_stratify(active, scratch_alloc); !ok {
			snapshot_release(next)
			snapshot_release(current)
			return nil, .Unstratified_Negation
		}

		kernel_compute_derived(kernel, next)
		previous, published := kernel_try_publish(kernel, current, next)
		if published {
			kernel_retire(kernel, previous)
			snapshot_release(current)
			changes_record_catalog(
				&kernel.changes,
				next.version,
				[]Catalog_Change {
					{kind = .Rule_Installed, relation = rule.head_relation, rule = id},
				},
			)
			kernel_store_persist(kernel, 0, next.version, next, nil, nil)
			return next, .None
		}
		snapshot_release(next)
		snapshot_release(current)
	}
}

// Sets a rule's active flag and publishes a new snapshot with recomputed
// derived relations. The returned snapshot is caller-owned.
kernel_set_rule_active :: proc(
	kernel: ^Kernel,
	rule_id: v.Identity,
	active: bool,
) -> (
	^Snapshot,
	Kernel_Error,
) {
	sync.mutex_lock(&kernel.catalog_lock)
	defer sync.mutex_unlock(&kernel.catalog_lock)

	for {
		current := kernel_snapshot(kernel)
		found := false
		head_relation: Relation_ID
		for definition in current.rules {
			if definition.id == rule_id {
				if definition.active == active {
					return current, .None
				}
				found = true
				head_relation = definition.rule.head_relation
				break
			}
		}
		if !found {
			snapshot_release(current)
			return nil, .No_Such_Rule
		}

		next := snapshot_fork(kernel, current)
		for &definition in next.rules {
			if definition.id == rule_id {
				definition.active = active
			}
		}
		kernel_compute_derived(kernel, next)
		previous, published := kernel_try_publish(kernel, current, next)
		if published {
			kernel_retire(kernel, previous)
			snapshot_release(current)
			kind := Catalog_Change_Kind.Rule_Installed
			if !active {
				kind = .Rule_Disabled
			}
			changes_record_catalog(
				&kernel.changes,
				next.version,
				[]Catalog_Change{{kind = kind, relation = head_relation, rule = rule_id}},
			)
			kernel_store_persist(kernel, 0, next.version, next, nil, nil)
			return next, .None
		}
		snapshot_release(next)
		snapshot_release(current)
	}
}

// Deactivates a rule and publishes a new snapshot. The returned snapshot is
// caller-owned.
kernel_disable_rule :: proc(kernel: ^Kernel, rule_id: v.Identity) -> (^Snapshot, Kernel_Error) {
	return kernel_set_rule_active(kernel, rule_id, false)
}

// Activates a rule and publishes a new snapshot. The returned snapshot is
// caller-owned.
kernel_enable_rule :: proc(kernel: ^Kernel, rule_id: v.Identity) -> (^Snapshot, Kernel_Error) {
	return kernel_set_rule_active(kernel, rule_id, true)
}

// Visits visible tuples of a relation in the current snapshot, including
// derived facts.
kernel_visit :: proc(
	kernel: ^Kernel,
	relation: Relation_ID,
	bindings: []v.Binding,
	visit: proc(user: rawptr, row: v.Tuple) -> bool,
	user: rawptr,
) -> bool {
	current := kernel_snapshot(kernel)
	defer snapshot_release(current)

	source := Relation_Source {
		kernel             = kernel,
		snapshot           = current,
		use_stored_derived = true,
	}
	return relation_source_visit(&source, relation, bindings, visit, user)
}

// Appends visible tuples of a relation in the current snapshot, including
// derived facts.
kernel_scan_into :: proc(
	kernel: ^Kernel,
	relation: Relation_ID,
	bindings: []v.Binding,
	out: ^[dynamic]v.Tuple,
) {
	current := kernel_snapshot(kernel)
	defer snapshot_release(current)

	relation_source_scan_into(
		&Relation_Source{kernel = kernel, snapshot = current, use_stored_derived = true},
		relation,
		bindings,
		out,
	)
}

// Reports whether a relation tuple is visible in the current snapshot.
kernel_contains :: proc(kernel: ^Kernel, relation: Relation_ID, tuple: v.Tuple) -> bool {
	current := kernel_snapshot(kernel)
	defer snapshot_release(current)
	return snapshot_contains(current, relation, tuple)
}
