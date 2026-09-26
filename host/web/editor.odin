// Editor bridge: authenticated sessions, ordered input, duplicate replay, and
// bounded viewport snapshots for the browser editor.
//
// The host validates transport metadata but does not interpret editor input.
// Workers forward each raw item to Mica's `editor_input_json`. That call also
// commits and finalizes staged edits, so one item needs one Mica execution.
// Snapshots also come from Mica, so keymaps and command policy stay there.
//
package web

import "base:runtime"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"

import k "../../mica/kernel"
import r "../../mica/runtime"
import v "../../mica/var"

EDITOR_SNAPSHOT_LINES :: 200
EDITOR_SNAPSHOT_SCALARS :: 262144
EDITOR_MAX_SNAPSHOT_LINES :: 1000
EDITOR_MAX_SNAPSHOT_SCALARS :: 1048576
EDITOR_RESULT_LIMIT :: 256
EDITOR_INPUT_LIMIT :: 1024
EDITOR_BATCH_LIMIT :: 256
EDITOR_ITEM_BYTES :: 64 * 1024
EDITOR_PENDING_BYTES :: 1024 * 1024
EDITOR_REQUEST_BYTES :: 256 * 1024
EDITOR_WORKERS :: 4
EDITOR_MAX_SAFE_INTEGER :: u64(9007199254740991)

Editor_Result :: struct {
	sequence: u64,
	body:     string,
}

Editor_Input :: struct {
	sequence:          u64,
	frame:             i64,
	lines:             i64,
	budget:            i64,
	keymap_generation: u64,
	text:              string,
}

Editor_Session :: struct {
	lock:          sync.Mutex,
	session_id:    u64,
	actor:         v.Value,
	next_sequence: u64,
	next_admitted: u64,
	processing:    bool,
	pending_bytes: int,
	inputs:        [dynamic]Editor_Input,
	results:       [dynamic]Editor_Result,
	allocator:     mem.Allocator,
}

Editor :: struct {
	lock:       sync.Mutex,
	cond:       sync.Cond,
	world:      ^r.World,
	sync_host:  ^Sync_Host,
	next_token: u64,
	sessions:   map[u64]^Editor_Session,
	allocator:  mem.Allocator,
	stopping:   bool,
	workers:    [dynamic]^thread.Thread,
}

editor_init :: proc(
	editor: ^Editor,
	world: ^r.World,
	sync_host: ^Sync_Host = nil,
	allocator := context.allocator,
) {
	editor.world = world
	editor.sync_host = sync_host
	editor.next_token = 1
	editor.allocator = allocator
	editor.sessions = make(map[u64]^Editor_Session, allocator)
	editor.workers = make([dynamic]^thread.Thread, allocator)
	if world != nil {
		for _ in 0 ..< EDITOR_WORKERS {
			append(&editor.workers, thread.create_and_start_with_data(editor, editor_pump_proc))
		}
	}
}

editor_destroy :: proc(editor: ^Editor) {
	if editor == nil || editor.sessions == nil {
		return
	}
	sync.mutex_lock(&editor.lock)
	editor.stopping = true
	sync.cond_broadcast(&editor.cond)
	sync.mutex_unlock(&editor.lock)
	for worker in editor.workers {
		thread.join(worker)
		thread.destroy(worker)
	}
	delete(editor.workers)
	for _, session in editor.sessions {
		for input in session.inputs {
			delete(input.text, session.allocator)
		}
		delete(session.inputs)
		for result in session.results {
			delete(result.body, session.allocator)
		}
		delete(session.results)
		free(session, session.allocator)
	}
	delete(editor.sessions)
}

@(private)
editor_ensure_session :: proc(
	editor: ^Editor,
	session_id: u64,
	actor: v.Value,
) -> ^Editor_Session {
	sync.mutex_lock(&editor.lock)
	defer sync.mutex_unlock(&editor.lock)
	if session, found := editor.sessions[session_id]; found {
		if session.actor != actor {
			return nil
		}
		return session
	}
	session := new(Editor_Session, editor.allocator)
	session.session_id = session_id
	session.actor = actor
	session.next_sequence = 1
	session.next_admitted = 1
	session.allocator = editor.allocator
	session.inputs = make([dynamic]Editor_Input, editor.allocator)
	session.results = make([dynamic]Editor_Result, editor.allocator)
	editor.sessions[session_id] = session
	return session
}

// Handles the editor's two routes. Returns false when the path is not an
// editor route, so the caller can continue its own dispatch.
editor_handle_request :: proc(
	editor: ^Editor,
	actor: v.Value,
	request: ^Http_Request,
	response: ^Http_Response,
) -> bool {
	if editor.world == nil {
		return false
	}
	principal := actor
	if v.value_is_empty_relation(principal) {
		principal = r.world_principal(editor.world)
	}
	path := http_request_path(request.target)
	switch {
	case request.method == "GET" && path == "/editor/snapshot":
		editor_handle_snapshot(editor, principal, request, response)
		return true
	case request.method == "POST" && path == "/editor/input":
		if _, has_sequence := editor_query_u64(request.target, "sequence"); has_sequence {
			editor_handle_input(editor, principal, request, response)
		} else {
			editor_handle_input_batch(editor, principal, request, response)
		}
		return true
	}
	return false
}

@(private)
editor_handle_snapshot :: proc(
	editor: ^Editor,
	actor: v.Value,
	request: ^Http_Request,
	response: ^Http_Response,
) {
	session_id, valid_session := editor_query_u64(request.target, "session")
	if !valid_session || session_id == 0 || session_id > EDITOR_MAX_SAFE_INTEGER {
		http_response_text(response, 400, "text/plain; charset=utf-8", "invalid editor session")
		return
	}
	host_session := editor_ensure_session(editor, session_id, actor)
	if host_session == nil {
		http_response_text(response, 403, "text/plain; charset=utf-8", "session actor mismatch")
		return
	}
	sync.mutex_lock(&host_session.lock)
	defer sync.mutex_unlock(&host_session.lock)
	session := editor_int(i64(session_id))
	lines := editor_query_bounded(
		request.target,
		"lines",
		EDITOR_SNAPSHOT_LINES,
		1,
		EDITOR_MAX_SNAPSHOT_LINES,
	)
	budget := editor_query_bounded(
		request.target,
		"max",
		EDITOR_SNAPSHOT_SCALARS,
		1,
		EDITOR_MAX_SNAPSHOT_SCALARS,
	)
	roles := []k.Role_Pair {
		{role = v.value_symbol(v.symbol_intern("session")), value = session},
		{role = v.value_symbol(v.symbol_intern("actor")), value = actor},
		{role = v.value_symbol(v.symbol_intern("lines")), value = editor_int(lines)},
		{role = v.value_symbol(v.symbol_intern("max_scalars")), value = editor_int(budget)},
	}
	text, ok, message := editor_call_text(editor, actor, "editor/snapshot_json", roles)
	if !ok {
		http_response_text(response, 500, "text/plain; charset=utf-8", message)
		return
	}
	editor_respond_json(response, text)
}

@(private)
editor_handle_input :: proc(
	editor: ^Editor,
	actor: v.Value,
	request: ^Http_Request,
	response: ^Http_Response,
) {
	session_id, valid_session := editor_query_u64(request.target, "session")
	sequence, valid_sequence := editor_query_u64(request.target, "sequence")
	if !valid_session ||
	   session_id == 0 ||
	   session_id > EDITOR_MAX_SAFE_INTEGER ||
	   !valid_sequence ||
	   sequence == 0 ||
	   sequence > EDITOR_MAX_SAFE_INTEGER {
		http_response_text(
			response,
			400,
			"text/plain; charset=utf-8",
			"invalid editor session or sequence",
		)
		return
	}
	host_session := editor_ensure_session(editor, session_id, actor)
	if host_session == nil {
		http_response_text(response, 403, "text/plain; charset=utf-8", "session actor mismatch")
		return
	}
	sync.mutex_lock(&host_session.lock)
	defer sync.mutex_unlock(&host_session.lock)
	if host_session.processing || len(host_session.inputs) > 0 {
		http_response_text(
			response,
			409,
			"text/plain; charset=utf-8",
			"editor has admitted asynchronous input",
		)
		return
	}

	if sequence < host_session.next_sequence {
		for result in host_session.results {
			if result.sequence == sequence {
				editor_respond_json(response, result.body)
				return
			}
		}
		http_response_text(
			response,
			409,
			"text/plain; charset=utf-8",
			"editor result replay window expired",
		)
		return
	}
	if sequence > host_session.next_sequence {
		http_response_text(response, 409, "text/plain; charset=utf-8", "editor input sequence gap")
		return
	}

	session := editor_int(i64(session_id))
	frame := editor_query_bounded(request.target, "frame", 1, 1, 0x7fffffff)
	lines := editor_query_bounded(
		request.target,
		"lines",
		EDITOR_SNAPSHOT_LINES,
		1,
		EDITOR_MAX_SNAPSHOT_LINES,
	)
	budget := editor_query_bounded(
		request.target,
		"max",
		EDITOR_SNAPSHOT_SCALARS,
		1,
		EDITOR_MAX_SNAPSHOT_SCALARS,
	)
	known_keymap_generation, _ := editor_query_u64(request.target, "keymap_generation")
	endpoint := r.world_endpoint(editor.world)
	endpoint_role := v.value_symbol(v.symbol_intern("endpoint"))
	session_role := v.value_symbol(v.symbol_intern("session"))
	token := sync.atomic_add(&editor.next_token, 1)
	input_roles := []k.Role_Pair {
		{role = endpoint_role, value = endpoint},
		{role = session_role, value = session},
		{role = v.value_symbol(v.symbol_intern("actor")), value = actor},
		{role = v.value_symbol(v.symbol_intern("frame")), value = editor_int(frame)},
		{
			role = v.value_symbol(v.symbol_intern("text")),
			value = v.value_string(context.temp_allocator, string(request.body)),
		},
		{role = v.value_symbol(v.symbol_intern("client_token")), value = editor_int(i64(token))},
		{
			role = v.value_symbol(v.symbol_intern("known_keymap_generation")),
			value = editor_int(i64(known_keymap_generation)),
		},
	}
	result_json, ok, message := editor_call_json(editor, actor, "editor_input_json", input_roles)
	if !ok {
		http_response_text(response, 500, "text/plain; charset=utf-8", message)
		return
	}

	// Ordinary commands carry enough authoritative state for the browser to
	// update its replica. Full snapshots are reserved for resynchronization or
	// commands that change the frame or viewport shape.
	needs_snapshot :=
		strings.contains(result_json, "\"snapshot_required\":true") ||
		strings.contains(result_json, "\"status\":\"resync\"")
	snapshot_json := ""
	if needs_snapshot {
		snapshot_roles := []k.Role_Pair {
			{role = session_role, value = session},
			{role = v.value_symbol(v.symbol_intern("actor")), value = actor},
			{role = v.value_symbol(v.symbol_intern("lines")), value = editor_int(lines)},
			{role = v.value_symbol(v.symbol_intern("max_scalars")), value = editor_int(budget)},
		}
		snapshot_ok: bool
		snapshot_message: string
		snapshot_json, snapshot_ok, snapshot_message = editor_call_text(
			editor,
			actor,
			"editor/snapshot_json",
			snapshot_roles,
		)
		if !snapshot_ok {
			http_response_text(response, 500, "text/plain; charset=utf-8", snapshot_message)
			return
		}
	}
	sequence_buffer: [32]byte
	sequence_text := strconv.write_uint(sequence_buffer[:], sequence, 10)
	body := ""
	if snapshot_json == "" {
		body = strings.concatenate(
			{"{\"through_sequence\":", sequence_text, ",\"result\":", result_json, "}"},
			context.temp_allocator,
		)
	} else {
		body = strings.concatenate(
			{
				"{\"through_sequence\":",
				sequence_text,
				",\"result\":",
				result_json,
				",\"snapshot\":",
				snapshot_json,
				"}",
			},
			context.temp_allocator,
		)
	}
	append(
		&host_session.results,
		Editor_Result{sequence = sequence, body = strings.clone(body, host_session.allocator)},
	)
	if len(host_session.results) > EDITOR_RESULT_LIMIT {
		delete(host_session.results[0].body, host_session.allocator)
		ordered_remove(&host_session.results, 0)
	}
	host_session.next_sequence += 1
	host_session.next_admitted = host_session.next_sequence
	editor_respond_json(response, body)
}

// Admits a bounded, contiguous batch and returns before Mica executes it.
// Results are delivered on the actor-bound /sync/events stream.
@(private)
editor_handle_input_batch :: proc(
	editor: ^Editor,
	actor: v.Value,
	request: ^Http_Request,
	response: ^Http_Response,
) {
	if len(request.body) > EDITOR_REQUEST_BYTES {
		http_response_text(
			response,
			413,
			"text/plain; charset=utf-8",
			"editor input batch is too large",
		)
		return
	}
	value, _, decoded := r.json_decode_text(context.temp_allocator, string(request.body))
	if !decoded {
		http_response_text(
			response,
			400,
			"text/plain; charset=utf-8",
			"invalid editor input batch",
		)
		return
	}
	entries, is_map := v.value_as_map(value)
	if !is_map {
		http_response_text(
			response,
			400,
			"text/plain; charset=utf-8",
			"editor input batch must be an object",
		)
		return
	}
	type_value, has_type := dom_event_get(entries, "type")
	type_text, type_is_text := v.value_as_string(type_value)
	session_id, has_session := dom_event_u64(entries, "session")
	items_value, has_items := dom_event_get(entries, "items")
	items, items_are_list := v.value_as_list(items_value)
	if !has_type ||
	   !type_is_text ||
	   type_text != "editor_input" ||
	   !has_session ||
	   session_id == 0 ||
	   session_id > EDITOR_MAX_SAFE_INTEGER ||
	   !has_items ||
	   !items_are_list ||
	   len(items) == 0 ||
	   len(items) > EDITOR_BATCH_LIMIT {
		http_response_text(
			response,
			400,
			"text/plain; charset=utf-8",
			"invalid editor input batch",
		)
		return
	}

	decoded_inputs := make([dynamic]Editor_Input, context.temp_allocator)
	defer delete(decoded_inputs)
	previous := u64(0)
	for item_value, index in items {
		item_entries, item_is_map := v.value_as_map(item_value)
		if !item_is_map {
			http_response_text(
				response,
				400,
				"text/plain; charset=utf-8",
				"editor input item must be an object",
			)
			return
		}
		sequence, has_sequence := dom_event_u64(item_entries, "sequence")
		depends_on, has_dependency := dom_event_u64(item_entries, "depends_on")
		if !has_sequence ||
		   sequence == 0 ||
		   sequence > EDITOR_MAX_SAFE_INTEGER ||
		   !has_dependency ||
		   depends_on != sequence - 1 ||
		   (index > 0 && sequence != previous + 1) {
			http_response_text(
				response,
				400,
				"text/plain; charset=utf-8",
				"editor input sequence is not contiguous",
			)
			return
		}
		encoded, encoded_ok := r.json_encode_text(context.temp_allocator, item_value)
		if !encoded_ok || len(encoded) > EDITOR_ITEM_BYTES {
			http_response_text(
				response,
				413,
				"text/plain; charset=utf-8",
				"editor input item is too large",
			)
			return
		}
		frame := i64(1)
		if frame_number, has_frame := dom_event_u64(item_entries, "frame"); has_frame {
			frame = i64(clamp(frame_number, u64(1), u64(0x7fffffff)))
		}
		known_generation, _ := dom_event_u64(item_entries, "keymap_generation")
		append(
			&decoded_inputs,
			Editor_Input {
				sequence = sequence,
				frame = frame,
				lines = EDITOR_SNAPSHOT_LINES,
				budget = EDITOR_SNAPSHOT_SCALARS,
				keymap_generation = known_generation,
				text = encoded,
			},
		)
		previous = sequence
	}

	host_session := editor_ensure_session(editor, session_id, actor)
	if host_session == nil {
		http_response_text(response, 403, "text/plain; charset=utf-8", "session actor mismatch")
		return
	}
	stream_session: ^Sync_Session
	if editor.sync_host != nil {
		stream_session = sync_host_ensure_session(editor.sync_host, session_id, actor)
		if stream_session == nil {
			http_response_text(
				response,
				403,
				"text/plain; charset=utf-8",
				"stream session actor mismatch",
			)
			return
		}
	}

	replays := make([dynamic]string, context.temp_allocator)
	defer delete(replays)
	sync.mutex_lock(&host_session.lock)
	new_count := 0
	new_bytes := 0
	for input in decoded_inputs {
		if input.sequence < host_session.next_admitted {
			found := false
			for result in host_session.results {
				if result.sequence == input.sequence {
					append(&replays, strings.clone(result.body, context.temp_allocator))
					found = true
					break
				}
			}
			// An admitted item can still be waiting in the queue or executing.
			if !found && input.sequence < host_session.next_sequence {
				sync.mutex_unlock(&host_session.lock)
				http_response_text(
					response,
					409,
					"text/plain; charset=utf-8",
					"editor result replay window expired",
				)
				return
			}
			continue
		}
		if input.sequence != host_session.next_admitted + u64(new_count) {
			sync.mutex_unlock(&host_session.lock)
			http_response_text(
				response,
				409,
				"text/plain; charset=utf-8",
				"editor input sequence gap",
			)
			return
		}
		new_count += 1
		new_bytes += len(input.text)
	}
	processing_count := 0
	if host_session.processing {
		processing_count = 1
	}
	if len(host_session.inputs) + processing_count + new_count > EDITOR_INPUT_LIMIT ||
	   host_session.pending_bytes + new_bytes > EDITOR_PENDING_BYTES {
		sync.mutex_unlock(&host_session.lock)
		http_response_text(
			response,
			429,
			"text/plain; charset=utf-8",
			"editor input queue is full",
		)
		return
	}
	for input in decoded_inputs {
		if input.sequence < host_session.next_admitted {
			continue
		}
		copy_input := input
		copy_input.text = strings.clone(input.text, host_session.allocator)
		append(&host_session.inputs, copy_input)
	}
	host_session.next_admitted += u64(new_count)
	host_session.pending_bytes += new_bytes
	sync.mutex_unlock(&host_session.lock)
	if new_count > 0 {
		sync.mutex_lock(&editor.lock)
		sync.cond_broadcast(&editor.cond)
		sync.mutex_unlock(&editor.lock)
	}

	if stream_session != nil {
		for body in replays {
			_ = sync_session_post_editor(stream_session, body)
		}
	}
	response.status = 202
	response.content_type = "application/json; charset=utf-8"
	response.body = transmute([]byte)strings.clone("{\"accepted\":true}", context.temp_allocator)
}

@(private)
editor_pump_proc :: proc(data: rawptr) {
	context = runtime.default_context()
	scratch_loop(editor_pump_step, data)
}

// Runs at most one queued input. Reports false once the editor is stopping.
@(private)
editor_pump_step :: proc(data: rawptr) -> bool {
	editor := (^Editor)(data)
	session: ^Editor_Session
	input: Editor_Input
	sync.mutex_lock(&editor.lock)
	stopping := editor.stopping
	if !stopping {
		for _, candidate in editor.sessions {
			sync.mutex_lock(&candidate.lock)
			if !candidate.processing && len(candidate.inputs) > 0 {
				session = candidate
				input = candidate.inputs[0]
				ordered_remove(&candidate.inputs, 0)
				candidate.processing = true
				sync.mutex_unlock(&candidate.lock)
				break
			}
			sync.mutex_unlock(&candidate.lock)
		}
	}
	if !stopping && session == nil {
		sync.cond_wait(&editor.cond, &editor.lock)
	}
	sync.mutex_unlock(&editor.lock)
	if stopping {
		return false
	}
	if session == nil {
		return true
	}

	body := editor_execute_input(editor, session, &input)
	sync.mutex_lock(&session.lock)
	append(
		&session.results,
		Editor_Result {
			sequence = input.sequence,
			body = strings.clone(body, session.allocator),
		},
	)
	if len(session.results) > EDITOR_RESULT_LIMIT {
		delete(session.results[0].body, session.allocator)
		ordered_remove(&session.results, 0)
	}
	session.next_sequence = input.sequence + 1
	session.pending_bytes -= len(input.text)
	// Store before publishing, and publish before another worker can take
	// the next item from this session. This preserves per-session order.
	if editor.sync_host != nil {
		if stream := sync_host_ensure_session(
			editor.sync_host,
			session.session_id,
			session.actor,
		); stream != nil {
			_ = sync_session_post_editor(stream, body)
		}
	}
	session.processing = false
	sync.mutex_unlock(&session.lock)
	delete(input.text, session.allocator)
	return true
}

@(private)
editor_execute_input :: proc(
	editor: ^Editor,
	host_session: ^Editor_Session,
	input: ^Editor_Input,
) -> string {
	session := editor_int(i64(host_session.session_id))
	endpoint := r.world_endpoint(editor.world)
	token := sync.atomic_add(&editor.next_token, 1)
	input_roles := []k.Role_Pair {
		{role = v.value_symbol(v.symbol_intern("endpoint")), value = endpoint},
		{role = v.value_symbol(v.symbol_intern("session")), value = session},
		{role = v.value_symbol(v.symbol_intern("actor")), value = host_session.actor},
		{role = v.value_symbol(v.symbol_intern("frame")), value = editor_int(input.frame)},
		{
			role = v.value_symbol(v.symbol_intern("text")),
			value = v.value_string(context.temp_allocator, input.text),
		},
		{role = v.value_symbol(v.symbol_intern("client_token")), value = editor_int(i64(token))},
		{
			role = v.value_symbol(v.symbol_intern("known_keymap_generation")),
			value = editor_int(i64(input.keymap_generation)),
		},
	}
	result_json, ok, _ := editor_call_json(
		editor,
		host_session.actor,
		"editor_input_json",
		input_roles,
	)
	if !ok {
		result_json = "{\"status\":\"resync\",\"message\":\"editor command failed\"}"
	}

	snapshot_json := ""
	if strings.contains(result_json, "\"snapshot_required\":true") ||
	   strings.contains(result_json, "\"status\":\"resync\"") {
		snapshot_roles := []k.Role_Pair {
			{role = v.value_symbol(v.symbol_intern("session")), value = session},
			{role = v.value_symbol(v.symbol_intern("actor")), value = host_session.actor},
			{role = v.value_symbol(v.symbol_intern("lines")), value = editor_int(input.lines)},
			{
				role = v.value_symbol(v.symbol_intern("max_scalars")),
				value = editor_int(input.budget),
			},
		}
		if snapshot, snapshot_ok, _ := editor_call_text(
			editor,
			host_session.actor,
			"editor/snapshot_json",
			snapshot_roles,
		); snapshot_ok {
			snapshot_json = snapshot
		}
	}
	sequence_buffer: [32]byte
	sequence_text := strconv.write_uint(sequence_buffer[:], input.sequence, 10)
	if snapshot_json == "" {
		return strings.concatenate(
			{"{\"through_sequence\":", sequence_text, ",\"result\":", result_json, "}"},
			context.temp_allocator,
		)
	}
	return strings.concatenate(
		{
			"{\"through_sequence\":",
			sequence_text,
			",\"result\":",
			result_json,
			",\"snapshot\":",
			snapshot_json,
			"}",
		},
		context.temp_allocator,
	)
}

// Submits one Mica call as `actor` and copies the encoded result before the
// task entry is released: Mica values are task-allocated, so they must not be
// read after `world_release`.
@(private)
editor_call_json :: proc(
	editor: ^Editor,
	actor: v.Value,
	selector: string,
	roles: []k.Role_Pair,
) -> (
	string,
	bool,
	string,
) {
	result := r.world_submit_call_with_options(
		editor.world,
		selector,
		roles,
		nil,
		0,
		r.World_Call_Options{actor = actor},
	)
	if result.id == 0 {
		return "", false, "cannot dispatch the editor call"
	}
	outcome := r.world_wait(editor.world, result.id)
	text := ""
	ok := false
	message := ""
	if outcome.kind != .Complete {
		message = outcome.message
		if error_value, is_error := v.value_as_error(outcome.error); is_error {
			message = error_value.message
		}
		if message == "" {
			message = "editor call failed"
		}
	} else if encoded, encoded_ok := r.json_encode_text(context.temp_allocator, outcome.value);
	   encoded_ok {
		text = encoded
		ok = true
	} else {
		message = "cannot encode the editor result"
	}
	r.world_release(editor.world, result.id)
	return text, ok, message
}

// Calls a selector that returns JSON text, copying the text before release.
@(private)
editor_call_text :: proc(
	editor: ^Editor,
	actor: v.Value,
	selector: string,
	roles: []k.Role_Pair,
) -> (
	string,
	bool,
	string,
) {
	result := r.world_submit_call_with_options(
		editor.world,
		selector,
		roles,
		nil,
		0,
		r.World_Call_Options{actor = actor},
	)
	if result.id == 0 {
		return "", false, "cannot dispatch the editor call"
	}
	outcome := r.world_wait(editor.world, result.id)
	text := ""
	ok := false
	message := ""
	if outcome.kind != .Complete {
		message = outcome.message
		if error_value, is_error := v.value_as_error(outcome.error); is_error {
			message = error_value.message
		}
		if message == "" {
			message = "editor call failed"
		}
	} else if borrowed, is_text := v.value_as_string(outcome.value); is_text {
		text = strings.clone(borrowed, context.temp_allocator)
		ok = true
	} else {
		message = "editor snapshot is not text"
	}
	r.world_release(editor.world, result.id)
	return text, ok, message
}

@(private)
editor_int :: proc(number: i64) -> v.Value {
	value, _ := v.value_int(number)
	return value
}

@(private)
editor_respond_json :: proc(response: ^Http_Response, text: string) {
	response.status = 200
	response.content_type = "application/json; charset=utf-8"
	response.body = transmute([]byte)strings.clone(text, context.temp_allocator)
}

// Reads `name` from the request target's query string, or returns `default`.
// Values arrived percent-encoded from the browser, so they are decoded: without
// this, `editor%2Fdefault` and the re-encoded `editor%252Fdefault` would each
// become different sessions.
@(private)
editor_query :: proc(target, name: string, default: string) -> string {
	query := strings.index_byte(target, '?')
	if query < 0 {
		return default
	}
	fields := strings.split(target[query + 1:], "&", context.temp_allocator)
	for field in fields {
		equals := strings.index_byte(field, '=')
		if equals < 0 {
			continue
		}
		if field[:equals] == name {
			return editor_url_decode(field[equals + 1:])
		}
	}
	return default
}

// Decodes percent escapes and `+` in one query value.
@(private)
editor_url_decode :: proc(text: string) -> string {
	if !strings.contains_any(text, "%+") {
		return text
	}
	out := make([dynamic]u8, 0, len(text), context.temp_allocator)
	for index := 0; index < len(text); index += 1 {
		byte := text[index]
		switch byte {
		case '%':
			if index + 2 < len(text) {
				high, high_ok := editor_hex_digit(text[index + 1])
				low, low_ok := editor_hex_digit(text[index + 2])
				if high_ok && low_ok {
					append(&out, high * 16 + low)
					index += 2
					continue
				}
			}
			append(&out, byte)
		case '+':
			append(&out, ' ')
		case:
			append(&out, byte)
		}
	}
	return string(out[:])
}

@(private)
editor_hex_digit :: proc(byte: u8) -> (u8, bool) {
	switch {
	case byte >= '0' && byte <= '9':
		return byte - '0', true
	case byte >= 'a' && byte <= 'f':
		return byte - 'a' + 10, true
	case byte >= 'A' && byte <= 'F':
		return byte - 'A' + 10, true
	}
	return 0, false
}

@(private)
editor_query_int :: proc(target, name: string, default: i64) -> i64 {
	text := editor_query(target, name, "")
	if text == "" {
		return default
	}
	parsed, ok := strconv.parse_i64(text)
	if !ok || parsed < 0 {
		return default
	}
	return parsed
}

@(private)
editor_query_bounded :: proc(target, name: string, default, minimum, maximum: i64) -> i64 {
	value := editor_query_int(target, name, default)
	return clamp(value, minimum, maximum)
}

@(private)
editor_query_u64 :: proc(target, name: string) -> (u64, bool) {
	text := editor_query(target, name, "")
	if text == "" {
		return 0, false
	}
	return strconv.parse_u64(text)
}
