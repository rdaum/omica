// View state, rendering, dependency subscriptions, and the change pump.
//
// Rendering keeps the last DOM tree per session view. A dependency change
// marks the view dirty; the next render diffs the new tree against the last
// and sends a `ViewDelta`, or a full snapshot after a resynchronize.
package web

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:sync"
import "core:time"
import dom "../../mica/dom"
import k "../../mica/kernel"
import r "../../mica/runtime"
import v "../../mica/var"

@(private)
View_Key :: struct {
	session_id: u64,
	view_id:    u64,
}

@(private)
View_State :: struct {
	render_lock:         sync.Mutex,
	tree:                dom.Dom_Node,
	has_tree:            bool,
	revision:            u64,
	signature:           u64,
	subscriptions:       [dynamic]v.Value,
	dependencies_loaded: bool,
	deps_error:          string,
	// `dirty` and `force_snapshot` are signaling flags shared between the
	// render path (under `render_lock`) and the pump (under `session.lock`);
	// they are atomic so the two paths cannot race on them.
	dirty:               bool,
	force_snapshot:      bool,
	allocator:           mem.Allocator,
}

// Returns the view state for `view_id`, creating it when needed.
@(private)
sync_view_state :: proc(session: ^Sync_Session, view_id: u64) -> ^View_State {
	sync.mutex_lock(&session.lock)
	if view, found := session.views[view_id]; found {
		sync.mutex_unlock(&session.lock)
		return view
	}
	view := new(View_State, session.allocator)
	view.allocator = session.allocator
	view.subscriptions = make([dynamic]v.Value, session.allocator)
	session.views[view_id] = view
	sync.mutex_unlock(&session.lock)
	return view
}

@(private)
sync_view_destroy :: proc(host: ^Sync_Host, view: ^View_State) {
	if host.world != nil {
		for capability in view.subscriptions {
			_ = r.world_cancel_subscription(host.world, capability)
		}
	}
	delete(view.subscriptions)
	if view.has_tree {
		dom.dom_node_release(view.tree, view.allocator)
	}
	free(view, view.allocator)
}

// Renders `view_id` and posts a snapshot or delta. Returns false when the
// world cannot render the view.
@(private)
sync_render_view :: proc(
	host: ^Sync_Host,
	session_id: u64,
	actor: v.Value,
	view_id: u64,
	client_revision: u64,
	client_signature: u64,
	force_snapshot: bool,
) -> bool {
	if !sync_host_ready(host) {
		return false
	}
	sync.mutex_lock(&host.lock)
	session, session_found := host.sessions[session_id]
	actor_matches := session_found && session.actor == actor
	sync.mutex_unlock(&host.lock)
	if !actor_matches {
		return false
	}
	// `closed` is guarded by `session.lock` (see `sync_session_close`).
	sync.mutex_lock(&session.lock)
	closed := session.closed
	sync.mutex_unlock(&session.lock)
	if closed {
		return false
	}
	view := sync_view_state(session, view_id)

	sync.mutex_lock(&view.render_lock)
	defer sync.mutex_unlock(&view.render_lock)

	// Consume the invalidation flags now. An invalidation that arrives during
	// the render re-sets them and triggers another render. Clearing them at the
	// end could instead wipe a newer invalidation (a lost update).
	force := force_snapshot || sync.atomic_load(&view.force_snapshot) || !view.has_tree
	sync.atomic_store(&view.force_snapshot, false)
	sync.atomic_store(&view.dirty, false)
	render_ok := false
	defer {
		if !render_ok {
			// The render did not complete; keep the invalidation so the pump
			// retries.
			sync.atomic_store(&view.dirty, true)
			if force {
				sync.atomic_store(&view.force_snapshot, true)
			}
		}
	}

	view_value, view_ok := v.value_int(i64(view_id))
	if !view_ok {
		return false
	}
	roles := []k.Role_Pair {
		{role = v.value_symbol(v.symbol_intern("view")), value = view_value},
	}
	outcome := sync_world_call(host, session, "sync_view_tree", roles)
	if outcome.kind != .Complete {
		return false
	}
	node, node_error := dom.dom_node_from_value(outcome.value, view.allocator)
	if node_error != "" {
		return false
	}
	if !view.dependencies_loaded {
		view.dependencies_loaded = sync_ensure_view_subscriptions(host, session, view, view_id)
	}

	revision := view.revision + 1
	if !view.has_tree {
		revision = 1
	}
	full := force

	kind: Sync_Kind
	payload: string
	if full {
		kind = .View_Snapshot
		payload = dom.dom_snapshot_payload_json(view_id, revision, node, view.allocator)
	} else {
		path: [dynamic]u64
		path = make([dynamic]u64, view.allocator)
		defer delete(path)
		patches: [dynamic]dom.Dom_Patch
		patches = make([dynamic]dom.Dom_Patch, view.allocator)
		defer delete(patches)
		dom.dom_diff_nodes(view.tree, node, &path, &patches, view.allocator)
		if len(patches) == 0 {
			dom.dom_node_release(node, view.allocator)
			render_ok = true
			return true
		}
		kind = .View_Delta
		payload = dom.dom_patch_payload_json(view_id, revision, patches[:], view.allocator)
		for &patch in patches {
			dom.dom_patch_release(&patch, view.allocator)
		}
	}

	payload_bytes := transmute([]u8)payload
	envelope := Sync_Envelope {
		kind             = kind,
		session_id       = session_id,
		view_id          = view_id,
		client_revision  = client_revision,
		client_signature = client_signature,
		server_revision  = revision,
		server_signature = sync_payload_signature(revision, payload_bytes),
		payload          = payload_bytes,
	}
	posted := sync_session_post(session, &envelope)
	delete(payload, view.allocator)
	if !posted {
		return false
	}

	if view.has_tree {
		dom.dom_node_release(view.tree, view.allocator)
	}
	view.tree = node
	view.has_tree = true
	view.revision = revision
	view.signature = envelope.server_signature
	render_ok = true
	return true
}

// Calls `sync_view_dependencies` and subscribes to each dependency. Returns
// false when the dependencies cannot be read yet, so the next render retries.
@(private)
sync_ensure_view_subscriptions :: proc(
	host: ^Sync_Host,
	session: ^Sync_Session,
	view: ^View_State,
	view_id: u64,
) -> bool {
	if !session.has_mailbox || !sync_host_ready(host) {
		view.deps_error = "no mailbox"
		return false
	}
	view_value, view_ok := v.value_int(i64(view_id))
	if !view_ok {
		view.deps_error = "invalid view id"
		return false
	}
	roles := []k.Role_Pair {
		{role = v.value_symbol(v.symbol_intern("view")), value = view_value},
	}
	outcome := sync_world_call(host, session, "sync_view_dependencies", roles)
	if outcome.kind != .Complete {
		view.deps_error = fmt.aprintf(
			"call %v: %s",
			outcome.kind,
			outcome.message,
			allocator = view.allocator,
		)
		return false
	}
	dependencies, is_list := v.value_as_list(outcome.value)
	if !is_list {
		view.deps_error = "not a list"
		return false
	}

	snapshot := k.kernel_snapshot(host.world.kernel)
	defer k.snapshot_release(snapshot)

	for dependency in dependencies {
		entries, is_map := v.value_as_map(dependency)
		if !is_map {
			continue
		}
		subject_value, has_subject := response_map_get(entries, "subject")
		subject_symbol, has_subject_symbol := v.value_as_symbol(subject_value)
		relation_value, has_relation := response_map_get(entries, "relation")
		bindings_value, has_bindings := response_map_get(entries, "bindings")
		if !has_subject || !has_subject_symbol || !has_relation || !has_bindings {
			view.deps_error = "missing dependency fields"
			continue
		}
		subject_name, subject_name_ok := v.symbol_name(subject_symbol)
		if !subject_name_ok {
			continue
		}
		subject: r.Subscription_Subject
		switch subject_name {
		case "facts":
			subject = .Facts
		case "relation":
			subject = .Relation
		case:
			continue
		}
		relation, relation_ok := sync_dependency_relation(snapshot, relation_value)
		if !relation_ok {
			view.deps_error = "unknown dependency relation"
			continue
		}
		binding_list, bindings_are_list := v.value_as_list(bindings_value)
		if !bindings_are_list {
			continue
		}
		bindings := make([]v.Binding, len(binding_list), context.temp_allocator)
		for item, index in binding_list {
			payload, has_payload := sync_option_payload(item)
			if has_payload {
				bindings[index] = v.binding_of(payload)
			} else {
				bindings[index] = v.Binding{}
			}
		}
		capability, subscribed := r.world_subscribe_changes(
			host.world,
			session.sender,
			subject,
			relation,
			bindings,
			false,
			0,
			false,
			64,
		)
		if !subscribed {
			view.deps_error = "subscribe failed"
			continue
		}
		append(&view.subscriptions, capability)
		sync.mutex_lock(&host.lock)
		host.subscription_views[u64(capability)] = View_Key {
			session_id = session.session_id,
			view_id    = view_id,
		}
		sync.mutex_unlock(&host.lock)
	}
	return true
}

// Calls a world verb as the session actor (when one is bound).
@(private)
sync_world_call :: proc(
	host: ^Sync_Host,
	session: ^Sync_Session,
	selector: string,
	roles: []k.Role_Pair,
) -> r.Task_Outcome {
	result := r.world_submit_call_with_options(
		host.world,
		selector,
		roles,
		nil,
		0,
		r.World_Call_Options{actor = session.actor},
	)
	if result.id == 0 {
		return r.Task_Outcome{kind = .Aborted, message = "no applicable method"}
	}
	outcome := r.world_wait(host.world, result.id)
	r.world_release(host.world, result.id)
	return outcome
}

@(private)
sync_option_payload :: proc(value: v.Value) -> (v.Value, bool) {
	relation, is_relation := v.value_as_relation(value)
	if !is_relation || len(relation.rows) == 0 {
		return v.Value(0), false
	}
	cells := v.tuple_values(relation.rows[0])
	if len(cells) == 0 {
		return v.Value(0), false
	}
	return cells[0], true
}

@(private)
sync_dependency_relation :: proc(
	snapshot: ^k.Snapshot,
	value: v.Value,
) -> (
	k.Relation_ID,
	bool,
) {
	if symbol, is_symbol := v.value_as_symbol(value); is_symbol {
		metadata, found := k.snapshot_relation_metadata_named(snapshot, symbol)
		return metadata.id, found
	}
	if identity, is_identity := v.value_as_identity(value); is_identity {
		raw := v.identity_raw(identity)
		if raw > u64(max(u32)) {
			return 0, false
		}
		return k.Relation_ID(u32(raw)), true
	}
	return 0, false
}

// --- Pump ------------------------------------------------------------------

@(private)
sync_pump_proc :: proc(data: rawptr) {
	context = runtime.default_context()
	scratch_loop(sync_pump_step, data)
}

// Pumps every session once, then waits for the next round. Reports false once
// the host is stopping.
@(private)
sync_pump_step :: proc(data: rawptr) -> bool {
	host := (^Sync_Host)(data)
	sync.mutex_lock(&host.lock)
	stopping := host.stopping
	sessions := make([dynamic]^Sync_Session, context.temp_allocator)
	for _, session in host.sessions {
		append(&sessions, session)
	}
	sync.mutex_unlock(&host.lock)
	if stopping {
		return false
	}
	for session in sessions {
		sync_pump_session(host, session)
	}
	time.sleep(25 * time.Millisecond)
	return true
}

@(private)
sync_pump_session :: proc(host: ^Sync_Host, session: ^Sync_Session) {
	if !session.has_mailbox {
		return
	}
	sync.mutex_lock(&session.lock)
	closed := session.closed
	sync.mutex_unlock(&session.lock)
	if closed {
		return
	}
	messages, drained := r.world_mailbox_drain(host.world, session.receiver)
	if !drained {
		return
	}
	defer delete(messages)

	for message in messages {
		entries, is_map := v.value_as_map(message)
		if !is_map {
			continue
		}
		kind_value, has_kind := response_map_get(entries, "kind")
		subscription_value, has_subscription := response_map_get(entries, "subscription")
		if !has_kind || !has_subscription {
			continue
		}
		kind_symbol, has_kind_symbol := v.value_as_symbol(kind_value)
		kind_name := ""
		if has_kind_symbol {
			kind_name, _ = v.symbol_name(kind_symbol)
		}
		sync.mutex_lock(&host.lock)
		key, key_found := host.subscription_views[u64(subscription_value)]
		sync.mutex_unlock(&host.lock)
		if !key_found || key.session_id != session.session_id {
			continue
		}
		sync.mutex_lock(&session.lock)
		if view, found := session.views[key.view_id]; found {
			sync.atomic_store(&view.dirty, true)
			if kind_name == "resynchronize" || kind_name == "revoked" {
				sync.atomic_store(&view.force_snapshot, true)
			}
		}
		sync.mutex_unlock(&session.lock)
	}

	// Re-render dirty views.
	to_render: [dynamic]u64
	to_render = make([dynamic]u64, context.temp_allocator)
	defer delete(to_render)
	sync.mutex_lock(&session.lock)
	for view_id, view in session.views {
		if sync.atomic_load(&view.dirty) {
			append(&to_render, view_id)
		}
	}
	sync.mutex_unlock(&session.lock)
	for view_id in to_render {
		view := sync_view_state(session, view_id)
		sync.mutex_lock(&view.render_lock)
		client_revision := view.revision
		client_signature := view.signature
		sync.mutex_unlock(&view.render_lock)
		_ = sync_render_view(
			host,
			session.session_id,
			session.actor,
			view_id,
			client_revision,
			client_signature,
			false,
		)
	}
}
