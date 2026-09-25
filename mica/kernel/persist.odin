// Persistence hooks.
//
// The durable store lives outside the kernel (`mica/store`); the kernel calls
// these hooks at admission and publication time. Keeping the interface here
// avoids a kernel-to-store import cycle.
package kernel

import "core:sync"
import buf "../buffer"
import v "../var"

// Identifies one reserved share of the store's durable budget.
Persist_Ticket :: u64

Store_Hooks :: struct {
	user: rawptr,
	// Reserves `bytes` of durable capacity. Returns false on timeout or when
	// the store is closed; the caller must not publish.
	admit: proc(user: rawptr, bytes: i64) -> (Persist_Ticket, bool),
	// Returns an unused reservation.
	release: proc(user: rawptr, ticket: Persist_Ticket),
	// Hands a published version's writes to the store. The store copies what
	// it needs before returning; it must not retain the slices.
	publish: proc(
		user: rawptr,
		ticket: Persist_Ticket,
		version: u64,
		snapshot: ^Snapshot,
		writes: []Relation_Writes,
		buffers: []Buffer_Writes,
	),
	// Blocks until `version` is durable.
	wait_durable:    proc(user: rawptr, version: u64),
	durable_version: proc(user: rawptr) -> u64,
}

kernel_attach_store :: proc(kernel: ^Kernel, hooks: Store_Hooks) {
	kernel.store = hooks
}

kernel_detach_store :: proc(kernel: ^Kernel) {
	kernel.store = {}
}

kernel_store_attached :: proc(kernel: ^Kernel) -> bool {
	return kernel.store.publish != nil
}

kernel_admit_persist :: proc(kernel: ^Kernel, bytes: i64) -> (Persist_Ticket, bool) {
	if kernel.store.admit == nil || bytes <= 0 {
		return 0, true
	}
	return kernel.store.admit(kernel.store.user, bytes)
}

kernel_release_persist :: proc(kernel: ^Kernel, ticket: Persist_Ticket) {
	if kernel.store.release == nil || ticket == 0 {
		return
	}
	kernel.store.release(kernel.store.user, ticket)
}

kernel_store_persist :: proc(
	kernel: ^Kernel,
	ticket: Persist_Ticket,
	version: u64,
	snapshot: ^Snapshot,
	writes: []Relation_Writes,
	buffers: []Buffer_Writes,
) {
	if kernel.store.publish == nil {
		return
	}
	kernel.store.publish(kernel.store.user, ticket, version, snapshot, writes, buffers)
}

kernel_wait_durable :: proc(kernel: ^Kernel, version: u64) {
	if kernel.store.wait_durable == nil {
		return
	}
	kernel.store.wait_durable(kernel.store.user, version)
}

kernel_durable_version :: proc(kernel: ^Kernel) -> u64 {
	if kernel.store.durable_version == nil {
		return 0
	}
	return kernel.store.durable_version(kernel.store.user)
}

// Estimates the durable bytes one transaction will produce. Volatile entries
// are excluded. The estimate is intentionally coarse; the store only needs a
// deterministic, monotonic sizing for its budget.
//
// Buffer writes are sized from the material staged for them rather than from
// the private root: the base-relative delta does not exist until the candidate
// is built, and charging the whole document for one keystroke would make the
// budget useless for editing. Each write also carries record framing, so an
// empty-delta write (a compaction) is still admitted.
kernel_persist_bytes :: proc(transaction: ^Transaction) -> i64 {
	total := i64(0)
	for relation_writes in transaction.writes {
		metadata, found := snapshot_relation_metadata(
			transaction.base,
			relation_writes.relation,
		)
		if !found || metadata.durability == .Volatile {
			continue
		}
		for entry in relation_writes.entries {
			total += 64 + i64(v.tuple_arity(entry.tuple)) * 24
		}
	}
	for buffer_writes in transaction.buffer_writes {
		// A staged entry is not in the base snapshot, so resolve through the
		// transaction, which also consults catalogue changes staged here.
		metadata, found := transaction_relation_metadata(
			transaction,
			buffer_writes.relation,
		)
		if !found || metadata.durability == .Volatile {
			continue
		}
		total += BUFFER_RECORD_OVERHEAD + i64(buffer_writes.inserted_bytes)
	}
	return total
}

// A restored relation with its materialized block.
Checkpoint_Relation :: struct {
	metadata: Relation_Metadata,
	block:    ^Relation_Block,
}

// Installs restored relations and their blocks with one publication. Used
// when booting from a checkpoint. Takes ownership of each block reference.
// A restored buffer with its materialized root.
Buffer_Checkpoint :: struct {
	metadata: Relation_Metadata,
	root:     ^buf.Piece_Node,
	revision: u64,
	epoch:    u64,
}

// Installs restored buffer content, creating catalogue entries that are not
// already present. Mirrors `kernel_install_checkpoint` for tuple relations.
kernel_install_buffer_checkpoint :: proc(
	kernel: ^Kernel,
	entries: []Buffer_Checkpoint,
) -> bool {
	sync.mutex_lock(&kernel.catalog_lock)
	defer sync.mutex_unlock(&kernel.catalog_lock)
	for {
		current := kernel_snapshot(kernel)
		next := snapshot_fork(kernel, current)
		for entry in entries {
			metadata, exists := snapshot_relation_metadata(current, entry.metadata.id)
			if !exists {
				snapshot_add_relation(
					next,
					metadata_clone(kernel.world_allocator, entry.metadata),
				)
				metadata = entry.metadata
			}
			block := buffer_block_create(
				&kernel.buffer_store,
				metadata.id,
				buf.tree_retain(entry.root),
				entry.revision,
				entry.epoch,
			)
			snapshot_set_buffer(next, block)
		}
		snapshot_compute_derived(next, kernel, current)
		previous, published := kernel_try_publish(kernel, current, next)
		if published {
			kernel_retire(kernel, previous)
			snapshot_release(current)
			return true
		}
		snapshot_release(next)
		snapshot_release(current)
	}
}

kernel_install_checkpoint :: proc(kernel: ^Kernel, entries: []Checkpoint_Relation) -> bool {
	sync.mutex_lock(&kernel.catalog_lock)
	defer sync.mutex_unlock(&kernel.catalog_lock)
	for {
		current := kernel_snapshot(kernel)
		next := snapshot_fork(kernel, current)
		for entry in entries {
			if _, exists := snapshot_relation_metadata(current, entry.metadata.id); !exists {
				snapshot_add_relation(next, metadata_clone(kernel.world_allocator, entry.metadata))
			}
			snapshot_set_block(next, entry.block)
		}
		snapshot_compute_derived(next, kernel, current)
		previous, published := kernel_try_publish(kernel, current, next)
		if published {
			kernel_retire(kernel, previous)
			snapshot_release(current)
			return true
		}
		snapshot_release(next)
		snapshot_release(current)
	}
}
