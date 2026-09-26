// Change subscriptions.
//
// `subscribe_changes` registers a subject pattern and a mailbox sender handle.
// After every committed transaction the store drains the kernel change feed
// from each subscription's cursor and posts change messages to the mailbox.
// Subscription handles are capability-store entries, so they can be revoked
// like any other capability or cancelled explicitly.
//
// Subjects:
//   - :facts     matches extensional fact changes for a relation pattern.
//   - :relation  matches the full relation result, including derived rows.
//   - :buffer    matches buffer content changes for one buffer.
//   - :catalogue matches relation and rule catalog changes; requires root.
package mica_runtime

import "core:mem"
import "core:sync"
import "core:time"
import k "../kernel"
import v "../var"

// Default bound on queued messages per subscription in a mailbox.
DEFAULT_SUBSCRIPTION_QUEUE_BUDGET :: 64

Subscription_Subject :: enum {
	Facts,
	Relation,
	Buffer,
	Catalogue,
}

@(private)
Subscription :: struct {
	capability:              v.Value,
	id:                      u64,
	sender:                  v.Value,
	subject:                 Subscription_Subject,
	relation:                k.Relation_ID,
	bindings:                []v.Binding,
	cursor:                  u64,
	queue_budget:            int,
	needs_resynchronization: bool,
	revoked:                 bool,
	// Registered by a task but not yet committed; delivery is deferred until
	// the task commits (or discarded on abort).
	pending_commit:          bool,
	// Deliver an initial snapshot when the subscription activates.
	initial_snapshot:        bool,
	// Deep-copied rows for :relation subjects. The snapshot that produced them
	// may be reclaimed, so the subscription owns its baseline.
	baseline:                []v.Tuple,
}

@(private)
Subscription_Store :: struct {
	lock:      sync.Mutex,
	next_id:   u64,
	entries:   map[u64]^Subscription,
	allocator: mem.Allocator,
}

@(private)
subscriptions_init :: proc(store: ^Subscription_Store, allocator: mem.Allocator) {
	store.entries = make(map[u64]^Subscription, allocator)
	store.allocator = allocator
	store.next_id = 1
}

@(private)
subscriptions_destroy :: proc(store: ^Subscription_Store) {
	for _, subscription in store.entries {
		if subscription.bindings != nil {
			delete(subscription.bindings, store.allocator)
		}
		subscription_baseline_free(store.allocator, subscription.baseline)
		free(subscription, store.allocator)
	}
	delete(store.entries)
}

// Registers a subscription and returns its capability handle. When
// `initial_snapshot` is set and no cursor is given, the current matching rows
// are delivered before registration.
@(private)
subscriptions_register :: proc(
	env: ^Builtin_Env,
	sender: v.Value,
	subject: Subscription_Subject,
	relation: k.Relation_ID,
	bindings: []v.Binding,
	initial_snapshot: bool,
	cursor: u64,
	has_cursor: bool,
	queue_budget: int,
	pending: bool,
) -> (
	v.Value,
	^Subscription,
	bool,
) {
	if env.scheduler == nil {
		return v.Value(0), nil, false
	}
	snapshot := k.kernel_snapshot(env.kernel)
	defer k.snapshot_release(snapshot)
	version := snapshot.version

	cursor_value := version
	if has_cursor {
		cursor_value = cursor
	}

	baseline: []v.Tuple
	if subject == .Relation {
		rows := subscription_scan_rows(env, subject, relation, bindings)
		defer delete(rows)
		baseline = subscription_baseline_capture(env, rows[:])
	}

	sync.mutex_lock(&env.subscriptions.lock)
	env.subscriptions.next_id += 1
	subscription_id := env.subscriptions.next_id
	capability, minted := k.capability_store_mint_subscription(
		&env.kernel.capabilities,
		subscription_id,
	)
	if !minted {
		sync.mutex_unlock(&env.subscriptions.lock)
		subscription_baseline_free(env.subscriptions.allocator, baseline)
		return v.Value(0), nil, false
	}
	subscription := new(Subscription, env.subscriptions.allocator)
	subscription.capability = capability
	subscription.id = subscription_id
	subscription.sender = sender
	subscription.subject = subject
	subscription.relation = relation
	subscription.bindings = make([]v.Binding, len(bindings), env.subscriptions.allocator)
	copy(subscription.bindings, bindings)
	subscription.cursor = cursor_value
	subscription.queue_budget = queue_budget
	subscription.baseline = baseline
	subscription.pending_commit = pending
	subscription.initial_snapshot = initial_snapshot && !has_cursor
	// A relation subscription resumed from an older cursor cannot be given a
	// baseline as of that cursor, so its first delivery is a replacement
	// snapshot rather than a silent gap in the reported changes.
	if subject == .Relation && has_cursor {
		subscription.needs_resynchronization = true
	}
	env.subscriptions.entries[subscription_id] = subscription

	// The entry is live in the map before the snapshot goes out, so a
	// concurrent cancel finds it instead of racing the send. The lock is held
	// across the send: a cancel must tombstone (not free) the entry while it
	// is being read.
	if subscription.initial_snapshot && !pending {
		subscription_send_snapshot(env, subscription)
	}
	sync.mutex_unlock(&env.subscriptions.lock)
	return capability, subscription, true
}

// Sends a subscription's initial snapshot. Used at registration and when a
// task-staged subscription activates on commit.
@(private)
subscription_send_snapshot :: proc(env: ^Builtin_Env, subscription: ^Subscription) {
	snapshot := k.kernel_snapshot(env.kernel)
	version := snapshot.version
	defer k.snapshot_release(snapshot)
	switch subscription.subject {
	case .Catalogue:
		entries := subscription_catalogue_entries(env, snapshot)
		defer delete(entries)
		message := subscription_catalogue_message(
			env,
			subscription.capability,
			"snapshot",
			version,
			entries[:],
		)
		_ = scheduler_mailbox_send(env.scheduler, subscription.sender, message)
	case .Facts, .Relation:
		rows := subscription_scan_rows(
			env,
			subscription.subject,
			subscription.relation,
			subscription.bindings,
		)
		defer delete(rows)
		row_values := subscription_row_values(env, rows[:])
		defer delete(row_values)
		message := subscription_snapshot_message(
			env,
			subscription.capability,
			subscription_subject_name(subscription.subject),
			version,
			row_values[:],
		)
		_ = scheduler_mailbox_send(env.scheduler, subscription.sender, message)
	case .Buffer:
		revision := u64(0)
		if block, has_buffer := k.snapshot_buffer(snapshot, subscription.relation); has_buffer {
			revision = block.revision
		}
		text := k.snapshot_buffer_text(snapshot, subscription.relation, env.allocator)
		defer delete(text, env.allocator)
		message := subscription_buffer_snapshot_message(
			env,
			subscription.capability,
			version,
			revision,
			text,
		)
		_ = scheduler_mailbox_send(env.scheduler, subscription.sender, message)
	}
}

// Activates a task-staged subscription after its transaction commits. A
// subscription cancelled while staged was tombstoned, not freed; it is
// dropped here without sending. The lock is held across the snapshot send so
// a concurrent cancel cannot free the entry mid-send.
@(private)
subscriptions_activate :: proc(env: ^Builtin_Env, subscription: ^Subscription) {
	sync.mutex_lock(&env.subscriptions.lock)
	current, exists := env.subscriptions.entries[subscription.id]
	if !exists || current != subscription {
		// Already released; nothing to do.
		sync.mutex_unlock(&env.subscriptions.lock)
		return
	}
	subscription.pending_commit = false
	if subscription.revoked {
		subscriptions_remove_locked(&env.subscriptions, subscription.id)
		sync.mutex_unlock(&env.subscriptions.lock)
		return
	}
	if subscription.initial_snapshot {
		subscription.initial_snapshot = false
		subscription_send_snapshot(env, subscription)
	}
	sync.mutex_unlock(&env.subscriptions.lock)
}

// Discards a task-staged subscription when its transaction aborts. The
// aborting task owns the staging reference, so the entry is removed
// unconditionally, even if a concurrent cancel already tombstoned it.
@(private)
subscriptions_discard :: proc(env: ^Builtin_Env, subscription: ^Subscription) {
	_ = k.capability_store_revoke(&env.kernel.capabilities, subscription.capability)
	sync.mutex_lock(&env.subscriptions.lock)
	subscriptions_remove_locked(&env.subscriptions, subscription.id)
	sync.mutex_unlock(&env.subscriptions.lock)
}

// Cancels a subscription by its capability handle.
@(private)
subscriptions_cancel :: proc(env: ^Builtin_Env, capability: v.Value) -> bool {
	grant, found := k.capability_store_lookup_retained(&env.kernel.capabilities, capability)
	if !found {
		return false
	}
	defer k.capability_release(grant)
	subscription_id, is_subscription := k.capability_subscription_target(grant)
	if !is_subscription {
		return false
	}
	sync.mutex_lock(&env.subscriptions.lock)
	subscriptions_release_locked(&env.subscriptions, subscription_id)
	sync.mutex_unlock(&env.subscriptions.lock)
	k.capability_store_revoke(&env.kernel.capabilities, capability)
	return true
}

// Cancels every subscription that delivers to `receiver`'s mailbox.
@(private)
subscriptions_cancel_for_mailbox :: proc(env: ^Builtin_Env, receiver: v.Value) -> int {
	grant, found := k.capability_store_lookup_retained(&env.kernel.capabilities, receiver)
	if !found {
		return 0
	}
	defer k.capability_release(grant)
	mailbox, is_receiver := k.capability_mailbox_target(grant, false)
	if !is_receiver {
		return 0
	}
	sync.mutex_lock(&env.subscriptions.lock)
	removed := 0
	to_cancel: [dynamic]v.Value
	defer delete(to_cancel)
	for _, subscription in env.subscriptions.entries {
		sender_grant, sender_found := k.capability_store_lookup_retained(
			&env.kernel.capabilities,
			subscription.sender,
		)
		if !sender_found {
			continue
		}
		sender_mailbox, is_sender := k.capability_mailbox_target(sender_grant, true)
		k.capability_release(sender_grant)
		if !is_sender || sender_mailbox != mailbox {
			continue
		}
		append(&to_cancel, subscription.capability)
	}
	for capability in to_cancel {
		if grant_value, grant_found := k.capability_store_lookup_retained(
			&env.kernel.capabilities,
			capability,
		); grant_found {
			subscription_id, is_subscription := k.capability_subscription_target(
				grant_value,
			)
			k.capability_release(grant_value)
			if is_subscription {
				subscriptions_release_locked(&env.subscriptions, subscription_id)
				removed += 1
			}
		}
	}
	sync.mutex_unlock(&env.subscriptions.lock)
	for capability in to_cancel {
		k.capability_store_revoke(&env.kernel.capabilities, capability)
	}
	return removed
}

@(private)
subscriptions_release_locked :: proc(store: ^Subscription_Store, subscription_id: u64) {
	if subscription, exists := store.entries[subscription_id]; exists {
		if subscription.pending_commit {
			// A task still references this entry through its staging list
			// and will release it on commit or abort. Tombstone it instead
			// of freeing: it must never activate or deliver again.
			subscription.revoked = true
			return
		}
		subscriptions_remove_locked(store, subscription_id)
	}
}

// Removes the entry from the map and frees it, unconditionally. The caller
// holds the store lock and owns the entry: the staging task aborted or
// committed a revoked staging, neither of which leaves another reference.
@(private)
subscriptions_remove_locked :: proc(store: ^Subscription_Store, subscription_id: u64) {
	if subscription, exists := store.entries[subscription_id]; exists {
		if subscription.bindings != nil {
			delete(subscription.bindings, store.allocator)
		}
		subscription_baseline_free(store.allocator, subscription.baseline)
		free(subscription, store.allocator)
		delete_key(&store.entries, subscription_id)
	}
}

// Delivers pending changes for every live subscription. Runs after a
// transaction commits.
@(private)
subscriptions_dispatch :: proc(env: ^Builtin_Env) {
	if env == nil || env.scheduler == nil {
		return
	}
	store := &env.subscriptions
	sync.mutex_lock(&store.lock)
	to_release: [dynamic]u64
	defer delete(to_release)
	for subscription_id, subscription in store.entries {
		if subscription.pending_commit {
			continue
		}
		if !subscription_is_live(env, subscription) {
			// Replace whatever is queued with a final revoked marker so the
			// consumer learns the subscription ended.
			marker := subscription_marker_message(
				env,
				subscription.capability,
				"revoked",
				subscription.cursor,
			)
			_ = scheduler_mailbox_replace_subscription(
				env.scheduler,
				subscription.sender,
				subscription.capability,
				marker,
			)
			append(&to_release, subscription_id)
			continue
		}
		if !subscription_deliver(env, subscription) {
			append(&to_release, subscription_id)
		}
	}
	for subscription_id in to_release {
		subscriptions_release_locked(store, subscription_id)
	}
	sync.mutex_unlock(&store.lock)
}

@(private)
subscription_is_live :: proc(env: ^Builtin_Env, subscription: ^Subscription) -> bool {
	grant, found := k.capability_store_lookup_retained(
		&env.kernel.capabilities,
		subscription.capability,
	)
	if !found {
		return false
	}
	defer k.capability_release(grant)
	if _, is_subscription := k.capability_subscription_target(grant); !is_subscription {
		return false
	}
	return k.capability_live(grant, 0, time.tick_now())
}

@(private)
Subscription_Collector :: struct {
	env:          ^Builtin_Env,
	subscription: ^Subscription,
	asserted:     [dynamic]v.Value,
	retracted:    [dynamic]v.Value,
	catalogue:    [dynamic]k.Catalog_Change,
	// Buffer change values are built inside the feed's visit callback, while its
	// lock is still held, so no borrowed delta outlives the callback.
	buffers:      [dynamic]v.Value,
}

@(private)
subscription_deliver :: proc(env: ^Builtin_Env, subscription: ^Subscription) -> bool {
	if subscription.needs_resynchronization {
		return subscription_resynchronize(env, subscription)
	}
	collector := Subscription_Collector {
		env          = env,
		subscription = subscription,
	}
	defer delete(collector.asserted)
	defer delete(collector.retracted)
	defer delete(collector.catalogue)
	defer delete(collector.buffers)

	latest, within_window := k.changes_visit(
		&env.kernel.changes,
		subscription.cursor,
		&collector,
		subscription_collect,
	)
	if !within_window {
		return subscription_resynchronize(env, subscription)
	}

	switch subscription.subject {
	case .Catalogue:
		if len(collector.catalogue) == 0 {
			subscription.cursor = latest
			return true
		}
		entries: [dynamic]v.Value
		defer delete(entries)
		for change in collector.catalogue {
			append(&entries, subscription_catalogue_change_value(env, change))
		}
		message := subscription_catalogue_message(
			env,
			subscription.capability,
			"changes",
			latest,
			entries[:],
		)
		return subscription_enqueue(env, subscription, message, latest, len(entries))

	case .Facts:
		if len(collector.asserted) == 0 && len(collector.retracted) == 0 {
			subscription.cursor = latest
			return true
		}
		message := subscription_changes_message(
			env,
			subscription.capability,
			"facts",
			latest,
			collector.asserted[:],
			collector.retracted[:],
		)
		return subscription_enqueue(
			env,
			subscription,
			message,
			latest,
			len(collector.asserted) + len(collector.retracted),
		)

	case .Relation:
		rows := subscription_scan_rows(
			env,
			.Relation,
			subscription.relation,
			subscription.bindings,
		)
		defer delete(rows)
		assertions: [dynamic]v.Value
		retractions: [dynamic]v.Value
		defer delete(assertions)
		defer delete(retractions)
		subscription_baseline_diff(env, subscription, rows[:], &assertions, &retractions)
		subscription.cursor = latest
		if len(assertions) == 0 && len(retractions) == 0 {
			return true
		}
		message := subscription_changes_message(
			env,
			subscription.capability,
			"relation",
			latest,
			assertions[:],
			retractions[:],
		)
		return subscription_enqueue(
			env,
			subscription,
			message,
			latest,
			len(assertions) + len(retractions),
		)

	case .Buffer:
		if len(collector.buffers) == 0 {
			subscription.cursor = latest
			return true
		}
		message := subscription_buffer_changes_message(
			env,
			subscription.capability,
			latest,
			collector.buffers[:],
		)
		return subscription_enqueue(env, subscription, message, latest, len(collector.buffers))
	}
	return true
}

// Sends a fresh snapshot so a consumer that missed changes or overflowed its
// queue converges. Updates the baseline for :relation subjects.
@(private)
subscription_resynchronize :: proc(env: ^Builtin_Env, subscription: ^Subscription) -> bool {
	snapshot := k.kernel_snapshot(env.kernel)
	version := snapshot.version
	defer k.snapshot_release(snapshot)

	ok: bool
	switch subscription.subject {
	case .Catalogue:
		entries := subscription_catalogue_entries(env, snapshot)
		defer delete(entries)
		message := subscription_catalogue_message(env, subscription.capability, "snapshot", version, entries[:])
		ok = scheduler_mailbox_replace_subscription(
			env.scheduler,
			subscription.sender,
			subscription.capability,
			message,
		)
	case .Facts, .Relation:
		rows := subscription_scan_rows(
			env,
			subscription.subject,
			subscription.relation,
			subscription.bindings,
		)
		defer delete(rows)
		if subscription.subject == .Relation {
			subscription_baseline_reset(env, subscription, rows[:])
		}
		row_values := subscription_row_values(env, rows[:])
		defer delete(row_values)
		message := subscription_snapshot_message(
			env,
			subscription.capability,
			subscription_subject_name(subscription.subject),
			version,
			row_values[:],
		)
		ok = scheduler_mailbox_replace_subscription(
			env.scheduler,
			subscription.sender,
			subscription.capability,
			message,
		)
	case .Buffer:
		// A buffer cannot be diffed from a window like a row set, so the
		// resynchronization is the whole text at its current revision.
		revision := u64(0)
		if block, has_buffer := k.snapshot_buffer(snapshot, subscription.relation); has_buffer {
			revision = block.revision
		}
		text := k.snapshot_buffer_text(snapshot, subscription.relation, env.allocator)
		defer delete(text, env.allocator)
		message := subscription_buffer_snapshot_message(
			env,
			subscription.capability,
			version,
			revision,
			text,
		)
		ok = scheduler_mailbox_replace_subscription(
			env.scheduler,
			subscription.sender,
			subscription.capability,
			message,
		)
	}
	if ok {
		subscription.needs_resynchronization = false
		subscription.cursor = version
	}
	return ok
}

// Posts one message, enforcing the per-subscription queue budget.
@(private)
subscription_enqueue :: proc(
	env: ^Builtin_Env,
	subscription: ^Subscription,
	message: v.Value,
	cursor: u64,
	entry_count: int,
) -> bool {
	if entry_count > subscription.queue_budget {
		return subscription_resynchronize(env, subscription)
	}
	marker := subscription_marker_message(
		env,
		subscription.capability,
		"resynchronize",
		cursor,
	)
	ok, overflow := scheduler_mailbox_deliver_subscription(
		env.scheduler,
		subscription.sender,
		subscription.capability,
		message,
		marker,
		subscription.queue_budget,
	)
	if !ok {
		return false
	}
	subscription.needs_resynchronization = overflow
	subscription.cursor = cursor
	return true
}

@(private)
subscription_collect :: proc(user: rawptr, record: ^k.Change_Record) -> bool {
	collector := (^Subscription_Collector)(user)
	switch collector.subscription.subject {
	case .Relation:
		return true
	case .Catalogue:
		for change in record.catalogue {
			append(&collector.catalogue, change)
		}
		return true
	case .Buffer:
		for change in record.buffers {
			if change.relation == collector.subscription.relation {
				append(&collector.buffers, subscription_buffer_change_value(collector.env, change))
			}
		}
		return true
	case .Facts:
	}

	if record.relation != collector.subscription.relation {
		return true
	}
	for tuple in record.asserted {
		if subscription_row_matches(collector.subscription.bindings, tuple) {
			append(
				&collector.asserted,
				subscription_row_value(collector.env, tuple),
			)
		}
	}
	for tuple in record.retracted {
		if subscription_row_matches(collector.subscription.bindings, tuple) {
			append(
				&collector.retracted,
				subscription_row_value(collector.env, tuple),
			)
		}
	}
	return true
}

@(private)
subscription_row_matches :: proc(bindings: []v.Binding, tuple: v.Tuple) -> bool {
	cells := v.tuple_values(tuple)
	if len(bindings) > 0 && len(bindings) != len(cells) {
		return false
	}
	for binding, index in bindings {
		if binding.bound && !v.value_eq(binding.value, cells[index]) {
			return false
		}
	}
	return true
}

@(private)
subscription_row_value :: proc(env: ^Builtin_Env, tuple: v.Tuple) -> v.Value {
	// A message waits in a mailbox past the transaction the row came from, so
	// it owns its cells (strings and other heap values included).
	return v.value_list(env.allocator, v.tuple_values(v.tuple_deep_copy(env.allocator, tuple)))
}

@(private)
subscription_row_values :: proc(env: ^Builtin_Env, rows: []v.Tuple) -> [dynamic]v.Value {
	values: [dynamic]v.Value
	for row in rows {
		append(&values, subscription_row_value(env, row))
	}
	return values
}

@(private)
subscription_subject_name :: proc(subject: Subscription_Subject) -> string {
	switch subject {
	case .Facts:
		return "facts"
	case .Relation:
		return "relation"
	case .Buffer:
		return "buffer"
	case .Catalogue:
		return "catalogue"
	}
	return "facts"
}

// Scans the current rows for a subject. `:facts` reads extensional rows only;
// `:relation` includes derived rows.
@(private)
subscription_scan_rows :: proc(
	env: ^Builtin_Env,
	subject: Subscription_Subject,
	relation: k.Relation_ID,
	bindings: []v.Binding,
) -> [dynamic]v.Tuple {
	rows: [dynamic]v.Tuple
	snapshot := k.kernel_snapshot(env.kernel)
	defer k.snapshot_release(snapshot)
	source := k.Relation_Source {
		kernel             = env.kernel,
		snapshot           = snapshot,
		use_stored_derived = subject == .Relation,
	}
	k.relation_source_scan_into(&source, relation, bindings, &rows)
	// The rows point into the snapshot's chunks, which a concurrent commit can
	// free once the snapshot is released below: copy them while it is held.
	// Callers consume the copies within the call (baselines and messages make
	// their own long-lived copies).
	for &row in rows {
		row = v.tuple_deep_copy(context.temp_allocator, row)
	}
	return rows
}

// --- Relation baselines ----------------------------------------------------

@(private)
subscription_baseline_capture :: proc(env: ^Builtin_Env, rows: []v.Tuple) -> []v.Tuple {
	copies := make([]v.Tuple, len(rows), env.subscriptions.allocator)
	for row, index in rows {
		copies[index] = v.tuple_deep_copy(env.subscriptions.allocator, row)
	}
	return copies
}

@(private)
subscription_baseline_free :: proc(alloc: mem.Allocator, baseline: []v.Tuple) {
	for tuple in baseline {
		subscription_tuple_free(alloc, tuple)
	}
	if baseline != nil {
		delete(baseline, alloc)
	}
}

@(private)
subscription_tuple_free :: proc(alloc: mem.Allocator, tuple: v.Tuple) {
	values := v.tuple_values(tuple)
	for cell in values {
		v.value_deep_free(alloc, cell)
	}
	delete(values, alloc)
}

// Replaces the baseline after a resynchronization.
@(private)
subscription_baseline_reset :: proc(
	env: ^Builtin_Env,
	subscription: ^Subscription,
	rows: []v.Tuple,
) {
	alloc := env.subscriptions.allocator
	subscription_baseline_free(alloc, subscription.baseline)
	subscription.baseline = subscription_baseline_capture(env, rows)
}

// Diffs the current rows against the stored baseline, appending assertions and
// retractions and updating the baseline.
@(private)
subscription_baseline_diff :: proc(
	env: ^Builtin_Env,
	subscription: ^Subscription,
	rows: []v.Tuple,
	assertions: ^[dynamic]v.Value,
	retractions: ^[dynamic]v.Value,
) {
	alloc := env.subscriptions.allocator
	present: [dynamic]bool
	defer delete(present)
	for row in rows {
		found := false
		for old in subscription.baseline {
			if v.tuple_eq(old, row) {
				found = true
				break
			}
		}
		append(&present, found)
		if !found {
			append(assertions, subscription_row_value(env, row))
		}
	}
	kept: [dynamic]v.Tuple
	for old in subscription.baseline {
		found := false
		for row in rows {
			if v.tuple_eq(old, row) {
				found = true
				break
			}
		}
		if found {
			append(&kept, old)
		} else {
			append(retractions, subscription_row_value(env, old))
			subscription_tuple_free(alloc, old)
		}
	}
	for row, index in rows {
		if !present[index] {
			append(&kept, v.tuple_deep_copy(alloc, row))
		}
	}
	if subscription.baseline != nil {
		delete(subscription.baseline, alloc)
	}
	subscription.baseline = kept[:]
}

// --- Messages --------------------------------------------------------------

@(private)
subscription_message_key :: proc(name: string) -> v.Value {
	return v.value_symbol(v.symbol_intern(name))
}

@(private)
subscription_message :: proc(
	env: ^Builtin_Env,
	capability: v.Value,
	kind: string,
	cursor: u64,
	fields: []v.Map_Entry,
) -> v.Value {
	entries: [6]v.Map_Entry
	count := 0
	entries[count] = v.Map_Entry {
		key   = subscription_message_key("kind"),
		value = v.value_symbol(v.symbol_intern(kind)),
	}
	count += 1
	entries[count] = v.Map_Entry {
		key   = subscription_message_key("subscription"),
		value = capability,
	}
	count += 1
	entries[count] = v.Map_Entry {
		key   = subscription_message_key("cursor"),
		value = value_int_must(i64(cursor)),
	}
	count += 1
	for field in fields {
		entries[count] = field
		count += 1
	}
	return v.value_map(env.allocator, entries[:count])
}

@(private)
subscription_changes_message :: proc(
	env: ^Builtin_Env,
	capability: v.Value,
	subject: string,
	cursor: u64,
	assertions: []v.Value,
	retractions: []v.Value,
) -> v.Value {
	return subscription_message(env, capability, "changes", cursor, []v.Map_Entry {
		{
			key   = subscription_message_key("subject"),
			value = v.value_symbol(v.symbol_intern(subject)),
		},
		{
			key   = subscription_message_key("assertions"),
			value = v.value_list(env.allocator, assertions),
		},
		{
			key   = subscription_message_key("retractions"),
			value = v.value_list(env.allocator, retractions),
		},
	})
}

// One buffer change as a message value: the revisions it spans and the
// base-relative edits an observer applies to its own copy of the text.
@(private)
subscription_buffer_change_value :: proc(env: ^Builtin_Env, change: k.Buffer_Change) -> v.Value {
	edits := make([]v.Value, len(change.delta.replacements), env.allocator)
	for replacement, index in change.delta.replacements {
		edits[index] = v.value_map(env.allocator, []v.Map_Entry {
			{key = subscription_message_key("at"), value = value_int_must(i64(replacement.start))},
			{
				key   = subscription_message_key("remove"),
				value = value_int_must(i64(replacement.end - replacement.start)),
			},
			{
				key   = subscription_message_key("text"),
				value = v.value_string(env.allocator, replacement.text),
			},
		})
	}
	return v.value_map(env.allocator, []v.Map_Entry {
		{
			key   = subscription_message_key("base_revision"),
			value = value_int_must(i64(change.base_revision)),
		},
		{
			key   = subscription_message_key("new_revision"),
			value = value_int_must(i64(change.new_revision)),
		},
		{key = subscription_message_key("epoch"), value = value_int_must(i64(change.epoch))},
		{key = subscription_message_key("edits"), value = v.value_list(env.allocator, edits)},
	})
}

@(private)
subscription_buffer_changes_message :: proc(
	env: ^Builtin_Env,
	capability: v.Value,
	cursor: u64,
	changes: []v.Value,
) -> v.Value {
	return subscription_message(env, capability, "changes", cursor, []v.Map_Entry {
		{
			key   = subscription_message_key("subject"),
			value = v.value_symbol(v.symbol_intern("buffer")),
		},
		{
			key   = subscription_message_key("changes"),
			value = v.value_list(env.allocator, changes),
		},
	})
}

@(private)
subscription_buffer_snapshot_message :: proc(
	env: ^Builtin_Env,
	capability: v.Value,
	cursor: u64,
	revision: u64,
	text: string,
) -> v.Value {
	return subscription_message(env, capability, "snapshot", cursor, []v.Map_Entry {
		{
			key   = subscription_message_key("subject"),
			value = v.value_symbol(v.symbol_intern("buffer")),
		},
		{key = subscription_message_key("revision"), value = value_int_must(i64(revision))},
		{key = subscription_message_key("text"), value = v.value_string(env.allocator, text)},
	})
}

@(private)
subscription_snapshot_message :: proc(	env: ^Builtin_Env,
	capability: v.Value,
	subject: string,
	cursor: u64,
	assertions: []v.Value,
) -> v.Value {
	return subscription_message(env, capability, "snapshot", cursor, []v.Map_Entry {
		{
			key   = subscription_message_key("subject"),
			value = v.value_symbol(v.symbol_intern(subject)),
		},
		{
			key   = subscription_message_key("assertions"),
			value = v.value_list(env.allocator, assertions),
		},
		{
			key   = subscription_message_key("retractions"),
			value = v.value_list(env.allocator, []v.Value{}),
		},
	})
}

@(private)
subscription_catalogue_message :: proc(
	env: ^Builtin_Env,
	capability: v.Value,
	kind: string,
	cursor: u64,
	entries: []v.Value,
) -> v.Value {
	return subscription_message(env, capability, kind, cursor, []v.Map_Entry {
		{
			key   = subscription_message_key("subject"),
			value = v.value_symbol(v.symbol_intern("catalogue")),
		},
		{
			key   = subscription_message_key("entries"),
			value = v.value_list(env.allocator, entries),
		},
	})
}

@(private)
subscription_marker_message :: proc(
	env: ^Builtin_Env,
	capability: v.Value,
	kind: string,
	cursor: u64,
) -> v.Value {
	return subscription_message(env, capability, kind, cursor, nil)
}

// --- Catalogue -------------------------------------------------------------

@(private)
subscription_catalogue_entries :: proc(
	env: ^Builtin_Env,
	snapshot: ^k.Snapshot,
) -> [dynamic]v.Value {
	entries: [dynamic]v.Value
	for metadata in snapshot.catalog {
		identity, identity_ok := v.value_identity_raw(u64(metadata.id))
		if !identity_ok {
			continue
		}
		append(&entries, v.value_map(env.allocator, []v.Map_Entry {
			{
				key   = subscription_message_key("kind"),
				value = v.value_symbol(v.symbol_intern("relation_created")),
			},
			{key = subscription_message_key("relation"), value = identity},
			{key = subscription_message_key("name"), value = v.value_symbol(metadata.name)},
		}))
	}
	for definition in snapshot.rules {
		identity, identity_ok := v.value_identity_raw(u64(definition.id))
		if !identity_ok {
			continue
		}
		relation, relation_ok := v.value_identity_raw(u64(definition.rule.head_relation))
		if !relation_ok {
			continue
		}
		kind := "rule_installed"
		if !definition.active {
			kind = "rule_disabled"
		}
		append(&entries, v.value_map(env.allocator, []v.Map_Entry {
			{
				key   = subscription_message_key("kind"),
				value = v.value_symbol(v.symbol_intern(kind)),
			},
			{key = subscription_message_key("rule"), value = identity},
			{key = subscription_message_key("relation"), value = relation},
		}))
	}
	return entries
}

@(private)
subscription_catalogue_change_value :: proc(
	env: ^Builtin_Env,
	change: k.Catalog_Change,
) -> v.Value {
	identity, identity_ok := v.value_identity_raw(u64(change.rule))
	relation, relation_ok := v.value_identity_raw(u64(change.relation))
	switch change.kind {
	case .Relation_Created:
		if relation_ok {
			return v.value_map(env.allocator, []v.Map_Entry {
				{
					key   = subscription_message_key("kind"),
					value = v.value_symbol(v.symbol_intern("relation_created")),
				},
				{key = subscription_message_key("relation"), value = relation},
				{key = subscription_message_key("name"), value = v.value_symbol(change.name)},
			})
		}
	case .Rule_Installed:
		if identity_ok && relation_ok {
			return v.value_map(env.allocator, []v.Map_Entry {
				{
					key   = subscription_message_key("kind"),
					value = v.value_symbol(v.symbol_intern("rule_installed")),
				},
				{key = subscription_message_key("rule"), value = identity},
				{key = subscription_message_key("relation"), value = relation},
			})
		}
	case .Rule_Disabled:
		if identity_ok {
			return v.value_map(env.allocator, []v.Map_Entry {
				{
					key   = subscription_message_key("kind"),
					value = v.value_symbol(v.symbol_intern("rule_disabled")),
				},
				{key = subscription_message_key("rule"), value = identity},
			})
		}
	}
	return v.value_map(env.allocator, []v.Map_Entry {
		{
			key   = subscription_message_key("kind"),
			value = v.value_symbol(v.symbol_intern("unknown")),
		},
	})
}
