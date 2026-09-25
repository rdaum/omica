// Transactional buffers in the kernel.
//
// A buffer occupies a catalogue entry with `storage = .Buffer` and holds its
// text in a `Buffer_Block` alongside the relation blocks of a snapshot, so
// buffer content commits atomically with relation writes and is isolated by the
// same snapshot rules.
//
// Staging keeps a *private root*: each view-relative edit is applied to it
// immediately, which makes read-your-own-writes a root read rather than an
// overlay scan. At commit the transaction publishes that private root when its
// base is unchanged, or re-applies the normalized delta when compaction moved
// the chunk lineage under it.
//
// Conflict is conservative by default: a `Reject` buffer any of whose content
// moved under the transaction conflicts. A buffer can opt into provenance
// merging (`Span`) or last-writer-wins (`Whole`) at creation.
//
// Reversion is a whole-buffer splice, not the adoption of a historical root: a
// bounded per-buffer history of retained versions supplies the text to splice
// in, so the result is an ordinary, conflict-checkable delta.
package kernel

import buf "../buffer"
import "core:mem"
import "core:strings"
import "core:sync"

// A buffer's committed text at one version.
Buffer_Block :: struct {
	store:    ^buf.Store,
	relation: Relation_ID,
	root:     ^buf.Piece_Node,
	// Logical content revision. Persisted; what clients and the log check.
	revision: u64,
	// Chunk-lineage epoch. Bumped by compaction, not by an edit.
	epoch:    u64,
	refs:     i32,
}

buffer_block_create :: proc(
	store: ^buf.Store,
	relation: Relation_ID,
	root: ^buf.Piece_Node,
	revision, epoch: u64,
) -> ^Buffer_Block {
	block := new(Buffer_Block, store.allocator)
	block.store = store
	block.relation = relation
	block.root = root
	block.revision = revision
	block.epoch = epoch
	block.refs = 1
	return block
}

buffer_block_retain :: proc(block: ^Buffer_Block) -> ^Buffer_Block {
	if block != nil {
		sync.atomic_add_explicit(&block.refs, 1, .Relaxed)
	}
	return block
}

buffer_block_release :: proc(block: ^Buffer_Block) {
	if block == nil {
		return
	}
	if sync.atomic_sub_explicit(&block.refs, 1, .Acq_Rel) != 1 {
		return
	}
	store := block.store
	buf.tree_release(store, block.root)
	free(block, store.allocator)
}

// A bounded per-buffer reversion history.
//
// Retained roots make the text of an earlier revision readable, which is what
// reversion needs, and retaining a version is only a refcount bump. Each buffer
// keeps its most recent published versions, newest last. The ring lives in the
// kernel rather than in a snapshot because it serves reversion, not readers: a
// reader never observes a historical version unless it explicitly reverts to
// one.
//
// The cap is what bounds the memory a document's history pins; versions that
// fall out are reclaimed through the ordinary chunk and node pools once no
// snapshot still references them.
Buffer_History_Ring :: struct {
	relation: Relation_ID,
	// Oldest first. The newest entry is the buffer's latest published version.
	blocks:   [dynamic]^Buffer_Block,
	// Publish counter of the last version recorded here, for eviction.
	touched:  u64,
}

Buffer_History :: struct {
	lock:      sync.Mutex,
	rings:     [dynamic]Buffer_History_Ring,
	// Versions retained per buffer.
	depth:     int,
	// Buffers allowed to retain history at once.
	max_rings: int,
	// Monotonic count of versions recorded, used to age rings for eviction.
	clock:     u64,
	allocator: mem.Allocator,
}

// Enough versions for a client to notice a mistake and revert it, short of
// pinning a document's whole edit history.
BUFFER_HISTORY_DEPTH :: 32
BUFFER_HISTORY_MAX_RINGS :: 256

buffer_history_init :: proc(history: ^Buffer_History, allocator := context.allocator) {
	history.allocator = allocator
	history.depth = BUFFER_HISTORY_DEPTH
	history.max_rings = BUFFER_HISTORY_MAX_RINGS
	history.rings = make([dynamic]Buffer_History_Ring, allocator)
}

@(private)
buffer_history_ring_destroy :: proc(history: ^Buffer_History, ring: ^Buffer_History_Ring) {
	for block in ring.blocks {
		buffer_block_release(block)
	}
	delete(ring.blocks)
	ring.blocks = nil
}

buffer_history_destroy :: proc(history: ^Buffer_History) {
	for &ring in history.rings {
		buffer_history_ring_destroy(history, &ring)
	}
	delete(history.rings)
	history.rings = nil
}

@(private)
buffer_history_find :: proc(
	history: ^Buffer_History,
	relation: Relation_ID,
) -> ^Buffer_History_Ring {
	for &ring in history.rings {
		if ring.relation == relation {
			return &ring
		}
	}
	return nil
}

@(private)
buffer_history_remove :: proc(history: ^Buffer_History, index: int) {
	for position := index; position < len(history.rings) - 1; position += 1 {
		history.rings[position] = history.rings[position + 1]
	}
	pop(&history.rings)
}

// Drops a buffer's retained versions. Called when the entry is killed, so a
// retired buffer's content is released instead of pinned by its history.
buffer_history_forget :: proc(history: ^Buffer_History, relation: Relation_ID) {
	sync.mutex_lock(&history.lock)
	defer sync.mutex_unlock(&history.lock)
	for index in 0 ..< len(history.rings) {
		if history.rings[index].relation != relation {
			continue
		}
		buffer_history_ring_destroy(history, &history.rings[index])
		buffer_history_remove(history, index)
		return
	}
}

// Retains a just-published version.
//
// Re-recording a revision that is already retained -- a compaction republishes
// the same content under a new epoch -- replaces the older block, so a ring
// holds at most one entry per revision and lookup resolves to the freshest
// lineage.
buffer_history_record :: proc(history: ^Buffer_History, block: ^Buffer_Block) {
	if block == nil {
		return
	}
	sync.mutex_lock(&history.lock)
	defer sync.mutex_unlock(&history.lock)

	history.clock += 1

	ring := buffer_history_find(history, block.relation)
	if ring == nil {
		if len(history.rings) >= history.max_rings {
			// Evict the buffer that has gone longest without publishing, so the
			// global cap costs the least likely target rather than an arbitrary
			// one.
			oldest := 0
			oldest_touched := max(u64)
			for &candidate, index in history.rings {
				if candidate.touched < oldest_touched {
					oldest_touched = candidate.touched
					oldest = index
				}
			}
			buffer_history_ring_destroy(history, &history.rings[oldest])
			buffer_history_remove(history, oldest)
		}
		append(
			&history.rings,
			Buffer_History_Ring {
				relation = block.relation,
				blocks = make([dynamic]^Buffer_Block, 0, history.depth, history.allocator),
				touched = history.clock,
			},
		)
		ring = &history.rings[len(history.rings) - 1]
	} else {
		ring.touched = history.clock
	}

	if len(ring.blocks) > 0 && ring.blocks[len(ring.blocks) - 1].revision == block.revision {
		buffer_block_release(ring.blocks[len(ring.blocks) - 1])
		ring.blocks[len(ring.blocks) - 1] = buffer_block_retain(block)
		return
	}
	for len(ring.blocks) >= history.depth {
		buffer_block_release(ring.blocks[0])
		for index := 1; index < len(ring.blocks); index += 1 {
			ring.blocks[index - 1] = ring.blocks[index]
		}
		pop(&ring.blocks)
	}
	append(&ring.blocks, buffer_block_retain(block))
}

// Returns a retained reference to the version at `revision`, or nil when it is
// outside the retained window. The caller releases the block.
buffer_history_lookup :: proc(
	history: ^Buffer_History,
	relation: Relation_ID,
	revision: u64,
) -> ^Buffer_Block {
	sync.mutex_lock(&history.lock)
	defer sync.mutex_unlock(&history.lock)
	ring := buffer_history_find(history, relation)
	if ring == nil {
		return nil
	}
	// Newest first, so a revision republished by compaction resolves to the
	// freshest lineage.
	for index := len(ring.blocks) - 1; index >= 0; index -= 1 {
		if ring.blocks[index].revision == revision {
			return buffer_block_retain(ring.blocks[index])
		}
	}
	return nil
}

// Coarse framing charge for one persisted buffer write: the relation id, the
// revision bracket, the epoch, and the replacement count. The replacement texts
// are charged separately from the write's staged material.
BUFFER_RECORD_OVERHEAD :: 64

// Why a tagged apply never published.
//
// The distinction is what the client should do next: a resync means the server
// could not express the change against the baseline the client holds (a crossed
// structure epoch, exhausted reconciliation budget, or a composition that
// failed), while a conflict means a concurrent edit overlapped. Both leave
// nothing applied.
Buffer_Client_Failure :: enum {
	// Not classified: the transaction aborted for some other reason.
	None,
	// Re-read and reconcile unsaved edits locally.
	Resync,
	// Re-read and resubmit.
	Conflict,
}

// Staged writes for one buffer.
Buffer_Writes :: struct {
	relation:           Relation_ID,
	// Staged edits, view-relative and in application order.
	edits:              [dynamic]buf.Edit,
	// The tree after staging applied those edits. Owned by the write set.
	private_root:       ^buf.Piece_Node,
	// The base block, retained so provenance can be computed at commit even
	// after a rebase moved the transaction's base.
	base_block:         ^Buffer_Block,
	// True once the write set has been anchored, so a staged buffer (which has
	// no base block) is not re-anchored on every edit.
	initialized:        bool,
	// True when the buffer is created by this transaction, in which case
	// there is no base block and its content publishes at revision 1.
	staged:             bool,
	// Set when this write carries a client token, so a completion result can
	// be reported after publication.
	has_client:         bool,
	client_token:       u64,
	client_revision:    u64,
	// The change relative to the client's baseline, composed before publication
	// when the published version superseded something newer. `writes.delta` is
	// relative to the version actually superseded, which after a rebase is not
	// what the client read.
	client_delta:       buf.Delta,
	client_delta_ready: bool,
	// Why a tagged apply did not publish. Classified where the failure is
	// detected so the client learns whether to resync or to resubmit.
	client_failure:     Buffer_Client_Failure,
	// True once a revision-checked operation or a compaction has claimed this
	// buffer for the transaction. Client offsets are only safe before the view
	// moves, and compaction only describes committed content, so once sealed no
	// further staging is allowed: a second apply or reversion, a compaction
	// alongside an edit, and a bare mutation after either, are all rejected.
	sealed:             bool,
	// True when the staged root was rebuilt into fresh chunks that share no
	// lineage with the base, so the published root begins a new structure
	// epoch. Set by reversion, which replaces the whole content in one splice.
	fresh_lineage:      bool,
	// Upper bound on the text bytes this write will make durable: the inserted
	// material of every staged edit, accumulated as it is staged. Admission
	// runs before the base-relative delta exists, so it sizes from this rather
	// than from the private root, which would charge a whole document for one
	// keystroke. Intermediate inserts later deleted make it an over-estimate,
	// which is the safe direction for a budget.
	inserted_bytes:     u64,

	// Filled at commit. `delta` is the normalized base-relative change, which
	// is both what persistence records and what a client reconciles against.
	// The revisions bracket the change.
	committed:          bool,
	base_revision:      u64,
	new_revision:       u64,
	epoch:              u64,
	delta:              buf.Delta,

	// Absolute publication values, used where the default "current + 1"
	// revision does not apply: compaction preserves the revision and bumps the
	// epoch, and replay restores the exact values the log recorded.
	has_target:         bool,
	target_revision:    u64,
	target_epoch:       u64,
}

@(private)
transaction_buffer_writes :: proc(
	transaction: ^Transaction,
	relation: Relation_ID,
	create: bool,
) -> (
	^Buffer_Writes,
	bool,
) {
	for &writes in transaction.buffer_writes {
		if writes.relation == relation {
			return &writes, true
		}
	}
	if !create {
		return nil, false
	}
	append(&transaction.buffer_writes, Buffer_Writes{relation = relation})
	return &transaction.buffer_writes[len(transaction.buffer_writes) - 1], true
}

transaction_writes_buffer :: proc(transaction: ^Transaction, relation: Relation_ID) -> bool {
	_, found := transaction_buffer_writes(transaction, relation, false)
	return found
}

// Stages a view-relative edit. Offsets address the current transaction view of
// the buffer, never the base version.
transaction_buffer_edit :: proc(
	transaction: ^Transaction,
	relation: Relation_ID,
	at, remove: u64,
	text: string,
) -> Kernel_Error {
	kernel := transaction.kernel

	metadata, known := transaction_relation_metadata(transaction, relation)
	if !known || metadata.storage != .Buffer || metadata.tombstoned {
		return .Unknown_Relation
	}

	writes, _ := transaction_buffer_writes(transaction, relation, true)
	if !writes.initialized {
		writes.initialized = true
		block, has_block := snapshot_buffer(transaction.base, relation)
		switch {
		case has_block:
			// Anchor the private root at the base version and remember the
			// block it came from, so provenance is computable at commit.
			writes.base_block = buffer_block_retain(block)
			writes.private_root = buf.tree_retain(block.root)
		case transaction_has_staged_relation(transaction, relation):
			// The buffer is created by this transaction, so it has no base
			// block; its content starts empty.
			writes.staged = true
		case:
			// A published buffer with no block is an empty buffer: content is
			// materialized only once a buffer is first written. Treat it as
			// empty, exactly as `transaction_buffer_apply` does.
			writes.staged = true
		}
	}

	if writes.sealed {
		return .Already_Applied
	}
	if at > buf.tree_scalars(writes.private_root) ||
	   remove > buf.tree_scalars(writes.private_root) - at {
		return .Arity_Mismatch
	}

	next := buf.tree_edit(&kernel.buffer_store, writes.private_root, at, remove, text, .Added)
	buf.tree_release(&kernel.buffer_store, writes.private_root)
	writes.private_root = next

	append(
		&writes.edits,
		buf.Edit {
			at = int(at),
			remove = int(remove),
			text = strings.clone(text, transaction.allocator),
		},
	)
	writes.inserted_bytes += u64(len(text))
	return .None
}

// Stages a compaction: re-chunk the buffer's text into fresh original chunks,
// preserving the logical revision and bumping the structure epoch.
//
// The content is unchanged, so the recorded delta is empty. What changes is the
// chunk lineage, which is why the epoch moves: a transaction whose base predates
// the compaction no longer shares provenance with the current root, and must
// conflict rather than compare across the boundary.
transaction_buffer_compact :: proc(
	transaction: ^Transaction,
	relation: Relation_ID,
) -> Kernel_Error {
	kernel := transaction.kernel
	metadata, known := transaction_relation_metadata(transaction, relation)
	if !known || metadata.storage != .Buffer || metadata.tombstoned {
		return .Unknown_Relation
	}

	writes, _ := transaction_buffer_writes(transaction, relation, true)
	if !writes.initialized {
		writes.initialized = true
		block, has_block := snapshot_buffer(transaction.base, relation)
		if has_block {
			writes.base_block = buffer_block_retain(block)
			writes.private_root = buf.tree_retain(block.root)
		} else {
			writes.staged = true
		}
	}
	if writes.staged {
		// A buffer created by this transaction has no superseded chunks: its
		// content already lives in fresh chunks, so there is nothing to do and
		// the view stays open for edits.
		return .None
	}
	if writes.sealed || len(writes.edits) > 0 || writes.has_target {
		// Compaction rewrites *committed* content, so it cannot share a
		// transaction with a content change. Applying it to a moved view would
		// either discard the staged change with the old root or publish it
		// under a revision that does not account for it.
		return .Already_Applied
	}

	text := buf.tree_text(writes.private_root, transaction.allocator)
	fresh := buf.tree_from_text(&kernel.buffer_store, text, .Original)
	buf.tree_release(&kernel.buffer_store, writes.private_root)
	writes.private_root = fresh

	writes.has_target = true
	writes.target_revision = writes.base_block.revision
	writes.target_epoch = writes.base_block.epoch + 1
	// Content is unchanged; the epoch carries the change. Sealing the view is
	// what keeps that true: an edit after this point would be a content change
	// published at the preserved revision.
	writes.delta = buf.Delta{}
	writes.committed = true
	writes.base_revision = writes.base_block.revision
	writes.new_revision = writes.target_revision
	writes.epoch = writes.target_epoch
	writes.sealed = true
	return .None
}

// The root a reader of this transaction should see: the private staged root
// when the buffer has been edited, otherwise the base root.
transaction_buffer_root :: proc(
	transaction: ^Transaction,
	relation: Relation_ID,
) -> ^buf.Piece_Node {
	// An uninitialized write set means nothing has been staged for this buffer
	// yet, so the base root is still the truth.
	if writes, found := transaction_buffer_writes(transaction, relation, false);
	   found && writes.initialized {
		return writes.private_root
	}
	block, ok := snapshot_buffer(transaction.base, relation)
	if !ok {
		return nil
	}
	return block.root
}

// Read-your-own-writes text.
transaction_buffer_text :: proc(
	transaction: ^Transaction,
	relation: Relation_ID,
	allocator := context.allocator,
) -> string {
	return buf.tree_text(transaction_buffer_root(transaction, relation), allocator)
}

// The revision the transaction read. This is what a client's
// `expected_revision` is checked against.
transaction_buffer_revision :: proc(transaction: ^Transaction, relation: Relation_ID) -> u64 {
	if writes, found := transaction_buffer_writes(transaction, relation, false);
	   found && writes.base_block != nil {
		return writes.base_block.revision
	}
	block, ok := snapshot_buffer(transaction.base, relation)
	if !ok {
		return 0
	}
	return block.revision
}

// Revision the transaction's current buffer view will have if it publishes.
// Computed projections use this to join staged text with marker coordinates
// rebased in the same transaction.
transaction_buffer_projected_revision :: proc(
	transaction: ^Transaction,
	relation: Relation_ID,
) -> u64 {
	writes, found := transaction_buffer_writes(transaction, relation, false)
	if !found || !writes.initialized {
		return transaction_buffer_revision(transaction, relation)
	}
	if writes.staged {
		return 1
	}
	if writes.has_target {
		return writes.target_revision
	}
	if writes.base_block != nil {
		return writes.base_block.revision + 1
	}
	return 0
}

// Conservative conflict validation: a buffer whose committed revision moved
// since the transaction read it conflicts.
@(private)
transaction_buffer_validate :: proc(
	transaction: ^Transaction,
	current: ^Snapshot,
) -> Kernel_Error {
	for &writes in transaction.buffer_writes {
		if writes.staged {
			// Nothing exists to conflict with; the entry is created by this
			// transaction.
			continue
		}
		metadata, known := transaction_relation_metadata(transaction, writes.relation)
		if !known {
			continue
		}
		current_block, has_block := snapshot_buffer(current, writes.relation)
		if !has_block {
			continue
		}
		switch metadata.conflict.kind {
		case .Whole:
			// Last-writer-wins: never conflicts.
			continue
		case .Reject:
			if writes.base_block == nil || current_block.revision != writes.base_block.revision {
				writes.client_failure = .Conflict
				return .Conflict
			}
		case .Span:
		// Disjoint changes merge in materialization; only a compaction
		// boundary or an overlap is refused there.
		case .Set, .Functional, .Event_Append:
			continue
		}
	}
	return .None
}

// Expresses a just-built published root relative to the revision the client
// read, and records it on the write set as the authoritative delta.
//
// A transaction's own delta is relative to the version it superseded, which
// after a rebase is not the client's baseline; sending it would corrupt the
// client's state. The client's baseline is the base block the transaction
// anchored at, so walking provenance from it to the published root yields
// exactly the change the client must apply. Composing here -- before
// publication -- is what lets a failure abort the commit rather than report
// `:resync` for an edit that was already made durable.
//
// Returns false when the delta cannot be composed or does not fit the rebase
// budget; the caller then abandons the commit.
@(private)
transaction_buffer_compose_client_delta :: proc(
	transaction: ^Transaction,
	writes: ^Buffer_Writes,
	superseded_revision: u64,
	root: ^buf.Piece_Node,
) -> bool {
	if writes.base_block == nil {
		return false
	}
	if writes.base_block.revision == superseded_revision {
		// The published version superseded exactly what the client read, so
		// the transaction's own delta is already in the client's coordinates.
		writes.client_delta = writes.delta
		writes.client_delta_ready = true
		return true
	}

	steps := transaction.buffer_rebase_usage.comparison_steps
	composed, compose_error := buf.tree_provenance_counted(
		&transaction.kernel.buffer_store,
		writes.base_block.root,
		root,
		&steps,
		transaction.allocator,
		buf.DEFAULT_REBASE_BUDGET.comparison_steps,
	)
	if compose_error != .None {
		return false
	}
	transaction.buffer_rebase_usage.comparison_steps = steps
	transaction.buffer_rebase_usage.text_bytes += buffer_delta_bytes(composed)
	transaction.buffer_rebase_usage.hunks += u64(len(composed.replacements))
	transaction.buffer_rebase_usage.alloc_bytes +=
		buffer_delta_bytes(composed) + u64(len(composed.replacements) * size_of(buf.Replacement))
	if buf.budget_exceeded(buf.DEFAULT_REBASE_BUDGET, transaction.buffer_rebase_usage) {
		return false
	}
	writes.client_delta = composed
	writes.client_delta_ready = true
	return true
}

// Writes the transaction's buffers into `fork`, a candidate for `current`.
//
// The conflict policy decides what a moved base means: `Reject` has already
// failed validation, `Span` merges disjoint changes, and `Whole` overwrites.
// Whatever the policy, the recorded delta is the change relative to the block
// that is actually being published onto, so replay and client reconciliation
// both see a change against their own predecessor.
@(private)
transaction_buffer_materialize :: proc(
	transaction: ^Transaction,
	current: ^Snapshot,
	fork: ^Snapshot,
) {
	kernel := transaction.kernel
	store := &kernel.buffer_store

	for &writes in transaction.buffer_writes {
		// A killed entry publishes no content, even if it was created and
		// killed in this same transaction: the tombstone is the outcome.
		if entry_metadata, entry_known := transaction_relation_metadata(
			transaction,
			writes.relation,
		); entry_known && entry_metadata.tombstoned {
			continue
		}

		if writes.staged {
			// Content of a buffer created by this transaction publishes with
			// the entry, at revision 1, and its delta is the whole content.
			delta, delta_error := buf.tree_provenance(
				store,
				nil,
				writes.private_root,
				transaction.allocator,
			)
			if delta_error != .None {
				continue
			}
			writes.delta = delta
			writes.committed = true
			writes.base_revision = 0
			writes.new_revision = 1
			writes.epoch = 0
			if writes.has_client {
				// A tagged apply on a buffer created in this transaction read
				// revision 0, so the whole content is already its delta.
				writes.client_delta = delta
				writes.client_delta_ready = true
			}

			block := buffer_block_create(
				store,
				writes.relation,
				buf.tree_retain(writes.private_root),
				1,
				0,
			)
			snapshot_set_buffer(fork, block)
			continue
		}

		current_block, has_block := snapshot_buffer(current, writes.relation)
		if !has_block || writes.base_block == nil {
			continue
		}
		metadata, known := transaction_relation_metadata(transaction, writes.relation)
		if !known {
			continue
		}

		revision_moved := current_block.revision != writes.base_block.revision
		switch metadata.conflict.kind {
		case .Set, .Functional, .Event_Append:
			continue
		case .Reject:
			if revision_moved {
				continue
			}
		case .Span:
		// Disjoint changes merge below.
		case .Whole:
		// Last-writer-wins: our view replaces the current content.
		}

		if (writes.has_target || writes.fresh_lineage) && revision_moved {
			// Neither a compaction nor a reversion can merge with a concurrent
			// edit; retry rather than discard the other change.
			writes.client_failure = .Resync
			transaction.buffer_conflict = true
			continue
		}

		// This transaction's own change, in base coordinates. A compaction
		// already set an empty delta and its target values.
		normalize_steps := u64(0)
		if !writes.has_target {
			normalized, normalize_error := buf.tree_provenance_counted(
				store,
				writes.base_block.root,
				writes.private_root,
				&normalize_steps,
				transaction.allocator,
			)
			if normalize_error != .None {
				continue
			}
			writes.delta = normalized
		}

		publish_revision := current_block.revision + 1
		publish_epoch := current_block.epoch
		if writes.fresh_lineage {
			// A reversion's chunks share no lineage with anything before them,
			// so the published root begins a new epoch.
			publish_epoch = current_block.epoch + 1
		}
		if writes.has_target {
			publish_revision = writes.target_revision
			publish_epoch = writes.target_epoch
		}

		merge :=
			!writes.has_target &&
			!writes.fresh_lineage &&
			metadata.conflict.kind == .Span &&
			revision_moved
		root: ^buf.Piece_Node

		if merge {
			if current_block.epoch != writes.base_block.epoch {
				// Provenance cannot compare across a compaction boundary.
				writes.client_failure = .Resync
				transaction.buffer_conflict = true
				continue
			}
			steps := transaction.buffer_rebase_usage.comparison_steps
			winner_delta, winner_error := buf.tree_provenance_counted(
				store,
				writes.base_block.root,
				current_block.root,
				&steps,
				transaction.allocator,
				buf.DEFAULT_REBASE_BUDGET.comparison_steps,
			)
			if winner_error != .None {
				writes.client_failure = .Resync
				transaction.buffer_conflict = true
				continue
			}
			transaction.buffer_rebase_usage.comparison_steps = steps
			text_bytes := buffer_delta_bytes(winner_delta) + buffer_delta_bytes(writes.delta)
			hunks := len(winner_delta.replacements) + len(writes.delta.replacements)
			transaction.buffer_rebase_usage.text_bytes += text_bytes
			transaction.buffer_rebase_usage.hunks += u64(hunks)
			transaction.buffer_rebase_usage.alloc_bytes +=
				text_bytes + u64(hunks * size_of(buf.Replacement))
			if buf.budget_exceeded(buf.DEFAULT_REBASE_BUDGET, transaction.buffer_rebase_usage) {
				// Reconciling is the work being bounded; failing closed is the
				// safe answer, and a client can resynchronize and retry.
				writes.client_failure = .Resync
				transaction.buffer_conflict = true
				continue
			}
			if buf.deltas_conflict(winner_delta, writes.delta) {
				writes.client_failure = .Conflict
				transaction.buffer_conflict = true
				continue
			}
			transformed := buf.delta_transform(winner_delta, writes.delta, transaction.allocator)
			applied, apply_error := buf.tree_apply_delta(store, current_block.root, transformed)
			if apply_error != .None {
				writes.client_failure = .Resync
				transaction.buffer_conflict = true
				continue
			}
			root = applied
			writes.delta = transformed
		} else if metadata.conflict.kind == .Whole && revision_moved {
			// Whole-buffer last-writer-wins replaces the actual predecessor.
			// Its recorded delta must therefore be relative to `current_block`,
			// even when both roots still share an epoch.
			text := buf.tree_text(writes.private_root, transaction.allocator)
			replacements := make([]buf.Replacement, 1, transaction.allocator)
			replacements[0] = buf.Replacement {
				start = 0,
				end   = int(buf.tree_scalars(current_block.root)),
				text  = text,
			}
			whole := buf.Delta {
				replacements = replacements,
			}
			applied, apply_error := buf.tree_apply_delta(store, current_block.root, whole)
			if apply_error != .None {
				writes.client_failure = .Resync
				transaction.buffer_conflict = true
				continue
			}
			root = applied
			writes.delta = whole
		} else if current_block.epoch == writes.base_block.epoch {
			// Same chunk lineage: the private root is publishable as built.
			root = buf.tree_retain(writes.private_root)
		} else if metadata.conflict.kind == .Whole {
			// Lineage moved and this policy overwrites, so replace the whole
			// buffer rather than transforming offsets that no longer
			// correspond.
			text := buf.tree_text(writes.private_root, transaction.allocator)
			replacements := make([]buf.Replacement, 1, transaction.allocator)
			replacements[0] = buf.Replacement {
				start = 0,
				end   = int(buf.tree_scalars(current_block.root)),
				text  = text,
			}
			whole := buf.Delta {
				replacements = replacements,
			}
			applied, apply_error := buf.tree_apply_delta(store, current_block.root, whole)
			if apply_error != .None {
				writes.client_failure = .Resync
				transaction.buffer_conflict = true
				continue
			}
			root = applied
			writes.delta = whole
		} else {
			// Compaction moved the lineage. Re-apply the normalized delta so
			// the published root carries the current epoch's chunks.
			applied, apply_error := buf.tree_apply_delta(store, current_block.root, writes.delta)
			if apply_error != .None {
				writes.client_failure = .Resync
				transaction.buffer_conflict = true
				continue
			}
			root = applied
		}

		// A tagged apply must be able to describe the published change relative
		// to the revision its client read. Compose that now, before publication:
		// once the version is durable, no failure may turn into an uncommitted
		// `:resync`.
		if writes.has_client &&
		   !transaction_buffer_compose_client_delta(
				   transaction,
				   &writes,
				   current_block.revision,
				   root,
			   ) {
			writes.client_failure = .Resync
			transaction.buffer_conflict = true
			buf.tree_release(store, root)
			continue
		}

		writes.committed = true
		writes.base_revision = current_block.revision
		writes.new_revision = publish_revision
		writes.epoch = publish_epoch

		block := buffer_block_create(store, writes.relation, root, publish_revision, publish_epoch)
		snapshot_set_buffer(fork, block)
	}
}

// Total inserted scalars across a delta, for budget accounting.
@(private)
buffer_delta_bytes :: proc(delta: buf.Delta) -> u64 {
	total := u64(0)
	for replacement in delta.replacements {
		total += u64(len(replacement.text))
	}
	return total
}

// Adopts the winner's buffer blocks for buffers this transaction did not write.
// Returns false when the two snapshots are not comparable, in which case the
// caller rebuilds the candidate.
@(private)
transaction_buffer_adopt :: proc(
	transaction: ^Transaction,
	candidate: ^Snapshot,
	winner: ^Snapshot,
) -> bool {
	if len(candidate.buffers) != len(winner.buffers) {
		return false
	}
	for block, index in candidate.buffers {
		winner_block := winner.buffers[index]
		if winner_block.relation != block.relation {
			return false
		}
		if winner_block == block {
			continue
		}
		if transaction_writes_buffer(transaction, block.relation) {
			// We hold the stripe, so the winner cannot have changed it.
			continue
		}
		buffer_block_retain(winner_block)
		candidate.buffers[index] = winner_block
		buffer_block_release(block)
	}
	return true
}

// --- Committed-state reads -------------------------------------------------

// Renders a buffer as of a snapshot.
snapshot_buffer_text :: proc(
	snapshot: ^Snapshot,
	relation: Relation_ID,
	allocator := context.allocator,
) -> string {
	block, ok := snapshot_buffer(snapshot, relation)
	if !ok {
		return ""
	}
	return buf.tree_text(block.root, allocator)
}

// Renders a buffer as of the kernel's current snapshot.
kernel_buffer_text :: proc(
	kernel: ^Kernel,
	relation: Relation_ID,
	allocator := context.allocator,
) -> string {
	snapshot := kernel_snapshot(kernel)
	defer snapshot_release(snapshot)
	return snapshot_buffer_text(snapshot, relation, allocator)
}

// The committed content revision of a buffer.
kernel_buffer_revision :: proc(kernel: ^Kernel, relation: Relation_ID) -> u64 {
	snapshot := kernel_snapshot(kernel)
	defer snapshot_release(snapshot)
	block, ok := snapshot_buffer(snapshot, relation)
	if !ok {
		return 0
	}
	return block.revision
}

// The committed chunk-lineage epoch of a buffer.
kernel_buffer_epoch :: proc(kernel: ^Kernel, relation: Relation_ID) -> u64 {
	snapshot := kernel_snapshot(kernel)
	defer snapshot_release(snapshot)
	block, ok := snapshot_buffer(snapshot, relation)
	if !ok {
		return 0
	}
	return block.epoch
}

// Outcome of a revision-checked apply.
Apply_Status :: enum {
	// The edits are staged in the transaction view; no commit yet.
	Applied,
	// `expected_revision` did not match; nothing was staged.
	Stale,
	// A revision-checked apply already ran for this buffer in this transaction.
	Already_Applied,
	Unknown_Relation,
}

// Outcome of a revision-checked reversion.
Revert_Status :: enum {
	// The historical text is staged as a whole-buffer replacement.
	Reverted,
	// `expected_revision` did not match; nothing was staged.
	Stale,
	// The requested revision is not retained, or is newer than the current one.
	Unknown_Revision,
	// The buffer already has staged changes in this transaction, so a
	// reversion would silently discard them.
	Dirty,
	// The name is not a buffer.
	Unknown_Relation,
}

// How a client-tagged apply ended.
Buffer_Apply_Outcome :: enum {
	// Published, and the change is expressed relative to the revision the
	// client read, so the client can reconcile against the baseline it knew.
	Ok,
	// Nothing was published, and the server could not express the change
	// against the client's baseline: a crossed structure epoch, an exhausted
	// reconciliation budget, or a composition that failed. The client re-reads
	// and reconciles its unsaved edits locally.
	Resync,
	// Nothing was published because a concurrent edit overlapped. The client
	// re-reads and resubmits.
	Conflict,
	// The transaction did not publish for some other reason.
	Aborted,
}

// What a client-tagged apply produced.
Buffer_Apply_Result :: struct {
	token:    u64,
	relation: Relation_ID,
	outcome:  Buffer_Apply_Outcome,
	revision: u64,
	// The authoritative change relative to the client's revision. Empty unless
	// the outcome is `Ok`.
	delta:    buf.Delta,
}

// A bounded ring of recent completions, keyed by client token.
//
// A staging builtin cannot report what the commit produced: the commit has not
// happened yet, and the transaction may still abort. So the result is recorded
// when the outcome is known -- at publication, or at teardown for a transaction
// that never published -- and read back by the client on a later turn.
Buffer_Result_Ring :: struct {
	lock:      sync.Mutex,
	entries:   [dynamic]Buffer_Apply_Result,
	capacity:  int,
	allocator: mem.Allocator,
}

BUFFER_RESULT_CAPACITY :: 256

buffer_result_ring_init :: proc(ring: ^Buffer_Result_Ring, allocator := context.allocator) {
	ring.allocator = allocator
	ring.capacity = BUFFER_RESULT_CAPACITY
	ring.entries = make([dynamic]Buffer_Apply_Result, allocator)
}

@(private)
buffer_result_free :: proc(ring: ^Buffer_Result_Ring, entry: ^Buffer_Apply_Result) {
	for replacement in entry.delta.replacements {
		if replacement.text != "" {
			delete(replacement.text, ring.allocator)
		}
	}
	if entry.delta.replacements != nil {
		delete(entry.delta.replacements, ring.allocator)
	}
	entry.delta = {}
}

buffer_result_ring_destroy :: proc(ring: ^Buffer_Result_Ring) {
	for &entry in ring.entries {
		buffer_result_free(ring, &entry)
	}
	delete(ring.entries)
}

// Records a completion, cloning the delta into the ring's own storage.
kernel_record_buffer_result :: proc(kernel: ^Kernel, result: Buffer_Apply_Result) {
	ring := &kernel.buffer_results
	sync.mutex_lock(&ring.lock)
	defer sync.mutex_unlock(&ring.lock)

	cloned := result
	if len(result.delta.replacements) > 0 {
		replacements := make([]buf.Replacement, len(result.delta.replacements), ring.allocator)
		for replacement, index in result.delta.replacements {
			text := replacement.text
			if text != "" {
				text = strings.clone(replacement.text, ring.allocator)
			}
			replacements[index] = buf.Replacement {
				start = replacement.start,
				end   = replacement.end,
				text  = text,
			}
		}
		cloned.delta = buf.Delta {
			replacements = replacements,
		}
	}

	for len(ring.entries) >= ring.capacity {
		buffer_result_free(ring, &ring.entries[0])
		for index := 1; index < len(ring.entries); index += 1 {
			ring.entries[index - 1] = ring.entries[index]
		}
		resize(&ring.entries, len(ring.entries) - 1)
	}
	append(&ring.entries, cloned)
}

// Reads a completion by token.
kernel_buffer_result :: proc(
	kernel: ^Kernel,
	token: u64,
	allocator := context.temp_allocator,
) -> (
	Buffer_Apply_Result,
	bool,
) {
	ring := &kernel.buffer_results
	sync.mutex_lock(&ring.lock)
	defer sync.mutex_unlock(&ring.lock)
	for &entry in ring.entries {
		if entry.token == token {
			cloned := entry
			if len(entry.delta.replacements) > 0 {
				replacements := make([]buf.Replacement, len(entry.delta.replacements), allocator)
				for replacement, index in entry.delta.replacements {
					text := replacement.text
					if text != "" {
						text = strings.clone(text, allocator)
					}
					replacements[index] = buf.Replacement {
						start = replacement.start,
						end   = replacement.end,
						text  = text,
					}
				}
				cloned.delta = buf.Delta {
					replacements = replacements,
				}
			}
			return cloned, true
		}
	}
	return {}, false
}

// Records `Aborted` for every client-tagged apply that never published.
@(private)
transaction_record_abandoned_applies :: proc(transaction: ^Transaction) {
	for &writes in transaction.buffer_writes {
		if !writes.has_client || writes.committed {
			continue
		}
		outcome: Buffer_Apply_Outcome = .Aborted
		switch writes.client_failure {
		case .Resync:
			outcome = .Resync
		case .Conflict:
			outcome = .Conflict
		case .None:
		}
		kernel_record_buffer_result(
			transaction.kernel,
			Buffer_Apply_Result {
				token = writes.client_token,
				relation = writes.relation,
				outcome = outcome,
				revision = writes.client_revision,
			},
		)
	}
}

// Stages a batch of view-relative edits, first checking that the client read the
// revision it thinks it did.
//
// A stale client offset is not a transaction conflict: a submission computed
// against revision 41 that arrives after 42 committed would begin on the new
// snapshot, find nothing to conflict with, and silently edit the wrong
// position. This check is what catches that, and it must happen before any
// offset is interpreted.
transaction_buffer_apply :: proc(
	transaction: ^Transaction,
	relation: Relation_ID,
	expected_revision: u64,
	edits: []buf.Edit,
	client_token: u64 = 0,
) -> Apply_Status {
	metadata, known := transaction_relation_metadata(transaction, relation)
	if !known || metadata.storage != .Buffer || metadata.tombstoned {
		return .Unknown_Relation
	}

	// Check the revision before creating a write set: a refused apply must
	// leave the transaction, and the buffer's readable state, untouched.
	if expected_revision != transaction_buffer_revision(transaction, relation) {
		return .Stale
	}

	writes, _ := transaction_buffer_writes(transaction, relation, true)
	if writes.sealed {
		return .Already_Applied
	}

	if !writes.initialized {
		writes.initialized = true
		block, has_block := snapshot_buffer(transaction.base, relation)
		if has_block {
			writes.base_block = buffer_block_retain(block)
			writes.private_root = buf.tree_retain(block.root)
		} else {
			writes.staged = true
		}
	} else if len(writes.edits) > 0 {
		// A bare mutation already moved the view, so the client's offsets --
		// which are relative to the revision it read -- no longer address what
		// it meant. Applying them anyway would edit the wrong positions.
		return .Already_Applied
	}

	for edit in edits {
		if edit.at < 0 || edit.remove < 0 {
			return .Unknown_Relation
		}
		at := u64(edit.at)
		remove := u64(edit.remove)
		if at > buf.tree_scalars(writes.private_root) ||
		   remove > buf.tree_scalars(writes.private_root) - at {
			return .Unknown_Relation
		}
		next := buf.tree_edit(
			&transaction.kernel.buffer_store,
			writes.private_root,
			at,
			remove,
			edit.text,
			.Added,
		)
		buf.tree_release(&transaction.kernel.buffer_store, writes.private_root)
		writes.private_root = next
		writes.inserted_bytes += u64(len(edit.text))
	}

	if client_token != 0 {
		writes.has_client = true
		writes.client_token = client_token
		writes.client_revision = expected_revision
	}
	writes.sealed = true
	return .Applied
}

// Stages a reversion to an earlier revision.
//
// Reversion is a whole-buffer splice, not the adoption of a historical root.
// Adopting the retained root would resurrect chunk intervals absent from the
// transaction's base -- violating the retained-material rule and producing a
// meaningless delta -- and would inject an older epoch's lineage into the
// current one. Reading the historical text and rebuilding it into fresh chunks
// stays inside the splice model: the result is an ordinary delta that the
// conflict policy can check, and the published root simply starts a new epoch.
//
// The operation is destructive in a shared buffer: it discards every edit
// committed since `revision`, including other writers', which is why it is a
// separately authorized operation and why `expected_revision` is mandatory.
// Inverting one writer's edit while preserving later ones is selective undo,
// and is explicitly out of scope.
transaction_buffer_revert :: proc(
	transaction: ^Transaction,
	relation: Relation_ID,
	revision: u64,
	expected_revision: u64,
) -> Revert_Status {
	metadata, known := transaction_relation_metadata(transaction, relation)
	if !known || metadata.storage != .Buffer || metadata.tombstoned {
		return .Unknown_Relation
	}

	// The revision check comes before any other work: a refused reversion must
	// leave the transaction, and the buffer's readable state, untouched.
	current := transaction_buffer_revision(transaction, relation)
	if expected_revision != current {
		return .Stale
	}
	if revision > current {
		return .Unknown_Revision
	}
	if revision == current {
		// Reverting to the version in hand changes nothing; do not burn a
		// revision on it.
		return .Reverted
	}

	// A reversion replaces the view wholesale, so it is only meaningful on a
	// pristine view. Anything already staged -- a bare edit or an earlier
	// revision-checked operation -- would be silently discarded.
	if writes, found := transaction_buffer_writes(transaction, relation, false); found {
		if writes.initialized || writes.sealed {
			return .Dirty
		}
	}

	// The target is older than the version in hand, so it can only come from the
	// retained history. The base block is still required: a reversion always
	// publishes against it.
	base, has_base := snapshot_buffer(transaction.base, relation)
	if !has_base {
		return .Unknown_Revision
	}
	historical := buffer_history_lookup(&transaction.kernel.buffer_history, relation, revision)
	if historical == nil {
		return .Unknown_Revision
	}
	defer buffer_block_release(historical)
	text := buf.tree_text(historical.root, transaction.allocator)

	writes, _ := transaction_buffer_writes(transaction, relation, true)
	writes.initialized = true
	writes.base_block = buffer_block_retain(base)
	// Fresh chunks, so provenance normalizes the whole view to one replacement
	// and the published root shares no lineage with the base.
	writes.private_root = buf.tree_from_text(&transaction.kernel.buffer_store, text, .Original)
	// A reversion's durable payload is the whole restored text: the recorded
	// delta is one full-buffer replacement.
	writes.inserted_bytes += u64(len(text))
	writes.fresh_lineage = true
	writes.sealed = true
	return .Reverted
}

// Stages a base-relative delta, applying it to the transaction's base root.
//
// This is how a replayed log record re-applies buffer content: the record
// carries the delta and the revision it was written against, so replay does not
// need the original view-relative edits. A base revision that does not match
// the replayed state is a gap and is refused rather than guessed at.
transaction_buffer_apply_delta :: proc(
	transaction: ^Transaction,
	relation: Relation_ID,
	base_revision: u64,
	new_revision: u64,
	new_epoch: u64,
	delta: buf.Delta,
) -> Kernel_Error {
	writes, _ := transaction_buffer_writes(transaction, relation, true)
	if !writes.initialized {
		writes.initialized = true
		block, has_block := snapshot_buffer(transaction.base, relation)
		if !has_block {
			return .Unknown_Relation
		}
		if block.revision != base_revision {
			return .Conflict
		}
		writes.base_block = buffer_block_retain(block)
		writes.private_root = buf.tree_retain(block.root)
	}

	applied, apply_error := buf.tree_apply_delta(
		&transaction.kernel.buffer_store,
		writes.private_root,
		delta,
	)
	if apply_error != .None {
		return .Arity_Mismatch
	}
	buf.tree_release(&transaction.kernel.buffer_store, writes.private_root)
	writes.private_root = applied
	for replacement in delta.replacements {
		writes.inserted_bytes += u64(len(replacement.text))
	}

	// The log records the revision and epoch that were published, so replay
	// restores them exactly rather than assuming an edit.
	writes.has_target = true
	writes.target_revision = new_revision
	writes.target_epoch = new_epoch
	return .None
}

// Applies a replayed kill: tombstones the entry and releases its content.
// Called only during store restore, against a kernel with no other writers.
kernel_tombstone_relation :: proc(kernel: ^Kernel, metadata: Relation_Metadata) -> Kernel_Error {
	sync.mutex_lock(&kernel.catalog_lock)
	defer sync.mutex_unlock(&kernel.catalog_lock)
	for {
		current := kernel_snapshot(kernel)
		existing, found := snapshot_relation_metadata(current, metadata.id)
		if !found {
			// Nothing to tombstone; a later record may create it.
			snapshot_release(current)
			return .None
		}
		next := snapshot_fork(kernel, current)
		for &entry in next.catalog {
			if entry.id == metadata.id {
				entry.tombstoned = true
				break
			}
		}
		if existing.storage == .Buffer {
			block := buffer_block_create(&kernel.buffer_store, metadata.id, nil, 0, 0)
			snapshot_set_buffer(next, block)
			// A tombstoned entry keeps no reversion history.
			buffer_history_forget(&kernel.buffer_history, metadata.id)
		}
		kernel_compute_derived(kernel, next, current)
		previous, published := kernel_try_publish(kernel, current, next)
		if published {
			kernel_retire(kernel, previous)
			snapshot_release(current)
			return .None
		}
		snapshot_release(next)
		snapshot_release(current)
	}
}

// Reports completions for a transaction whose buffer writes have just become
// visible.
//
// The delta reported is the one composed against the client's own baseline
// before publication, so a committed apply is never reported as an uncommitted
// `:resync`. A tagged apply that could not be composed never reaches here: the
// commit was abandoned and its completion was recorded as `:resync`.
@(private)
kernel_record_buffer_completions :: proc(kernel: ^Kernel, transaction: ^Transaction) {
	for &writes in transaction.buffer_writes {
		if !writes.has_client || !writes.committed {
			continue
		}
		delta := writes.delta
		if writes.client_delta_ready {
			delta = writes.client_delta
		}
		kernel_record_buffer_result(
			kernel,
			Buffer_Apply_Result {
				token = writes.client_token,
				relation = writes.relation,
				outcome = .Ok,
				revision = writes.new_revision,
				delta = delta,
			},
		)
	}
}

// Retains the versions a transaction just published so a later reversion can
// read them back, and drops the history of any entry the transaction killed.
// Called after publication, when `published` is the new current snapshot.
@(private)
kernel_sync_buffer_history :: proc(
	kernel: ^Kernel,
	published: ^Snapshot,
	transaction: ^Transaction,
) {
	for &writes in transaction.buffer_writes {
		if !writes.committed {
			continue
		}
		if block, found := snapshot_buffer(published, writes.relation); found {
			buffer_history_record(&kernel.buffer_history, block)
		}
	}
	for change in transaction.catalog_changes {
		if change.kind == .Kill {
			buffer_history_forget(&kernel.buffer_history, change.metadata.id)
		}
	}
}
