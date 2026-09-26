// Execution conformance for Mica applications (#81).
//
// For each case this loads a set of Mica files into a world and calls a verb
// twice: once with the Odin-compiled program installed by world_load, and once
// with the Mica emitter's program for the same sources swapped in. The results
// must be equal, or both must raise the same error code.
//
// The cases exercise constructs the benchmarks do not: role dispatch,
// try/catch/finally, match (including nested), DOM construction, structural
// literals, and field writes. A case's `setup` verb runs before its `call`,
// matching the benchmark convention.
//
//   odin run tools/appconformance
package main

import "core:fmt"
import "core:os"
import k "../../mica/kernel"
import r "../../mica/runtime"
import v "../../mica/var"
import vm "../../mica/vm"

COMPILER :: []string {
	"apps/compiler/lex.mica",
	"apps/compiler/parse.mica",
	"apps/compiler/emit.mica",
}

// One conformance case: load `files`, run `setup` if non-empty, then call
// `call` with `roles`. Each role's value names an identity in the world, so
// the harness can drive role-dispatched verbs without hard-coding values.
Case :: struct {
	name:  string,
	files: []string,
	setup: string,
	call:  string,
	// Verbs run in order, each in its own task and therefore its own
	// transaction, after `setup` and instead of `call`; the last result is
	// compared. A scenario that spans commits -- such as buffer reversion,
	// which needs published history -- needs more than one transaction.
	calls: []string,
	roles: []Role_Name,
}

Role_Name :: struct {
	role:     string,
	identity: string,
}

main :: proc() {
	editor_files := []string {
		"apps/shared/buffers.mica",
		"apps/editor/schema.mica",
		"apps/editor/windows.mica",
		"apps/editor/buffers.mica",
		"apps/editor/keymaps.mica",
		"apps/editor/undo.mica",
		"apps/editor/commands.mica",
		"apps/editor/session.mica",
		"apps/editor/picker.mica",
		"apps/editor/minibuffer.mica",
		"apps/editor/files.mica",
		"apps/editor/ui.mica",
		"apps/editor/defaults.mica",
		"apps/editor/tests/editor-scenarios.mica",
	}
	cases := []Case {
		{
			name = "equipment-service: record calibration",
			files = []string{"apps/examples/equipment-service.mica"},
			call = "record_calibration",
			roles = []Role_Name {
				{role = "actor", identity = "technician"},
				{role = "instrument", identity = "sensor_17"},
			},
		},
		{
			name = "equipment-service: transfer",
			files = []string{"apps/examples/equipment-service.mica"},
			call = "transfer",
			roles = []Role_Name {
				{role = "actor", identity = "alice"},
				{role = "instrument", identity = "sensor_17"},
				{role = "destination", identity = "north_office"},
			},
		},
		{
			name = "dependency-planner: mark unavailable",
			files = []string{"apps/examples/dependency-planner.mica"},
			call = "mark_unavailable",
			roles = []Role_Name {
				{role = "actor", identity = "olivia"},
				{role = "component", identity = "database"},
			},
		},
		{
			name = "approval-workflow: approve",
			files = []string{"apps/examples/approval-workflow.mica"},
			call = "approve",
			roles = []Role_Name {
				{role = "actor", identity = "sam"},
				{role = "request", identity = "office_supplies_request"},
				{role = "note", identity = "office_supplies_request"},
			},
		},
		{
			name = "mud core: loads and answers",
			files = []string {
				"apps/shared/string.mica",
				"apps/shared/list.mica",
				"apps/shared/events.mica",
				"apps/mud/core.mica",
				"apps/mud/command-parser.mica",
				"apps/mud/event-substitutions.mica",
			},
			call = "",
		},
		{
			name = "mud scenarios: substitutions only",
			files = []string {
				"apps/shared/string.mica",
				"apps/shared/list.mica",
				"apps/shared/events.mica",
				"apps/mud/core.mica",
				"apps/mud/event-substitutions.mica",
				"apps/mud/tests/event-scenarios.mica",
			},
			call = "test/event_substitutions_render_per_viewer",
		},
		{
			name = "mud scenarios: command parser and substitutions",
			files = []string {
				"apps/shared/string.mica",
				"apps/shared/list.mica",
				"apps/shared/events.mica",
				"apps/mud/core.mica",
				"apps/mud/command-parser.mica",
				"apps/mud/event-substitutions.mica",
				"apps/mud/tests/event-scenarios.mica",
			},
			call = "test/command_parser_records_structured_utility_events",
		},
		{
			name = "buffers: insert, read, measure",
			files = []string{"apps/buffers/tests/buffer-scenarios.mica"},
			call = "test/buffer_insert_read_and_measure",
		},
		{
			name = "buffers: view-relative offsets",
			files = []string{"apps/buffers/tests/buffer-scenarios.mica"},
			call = "test/buffer_offsets_are_view_relative",
		},
		{
			name = "buffers: line accounting",
			files = []string{"apps/buffers/tests/buffer-scenarios.mica"},
			call = "test/buffer_line_accounting",
		},
		{
			name = "buffers: scalars not bytes",
			files = []string{"apps/buffers/tests/buffer-scenarios.mica"},
			call = "test/buffer_scalars_not_bytes",
		},
		{
			name = "buffers: independent buffers",
			files = []string{"apps/buffers/tests/buffer-scenarios.mica"},
			call = "test/buffers_are_independent",
		},
		{
			name = "buffers: compaction is accepted",
			files = []string{"apps/buffers/tests/buffer-scenarios.mica"},
			call = "test/buffer_compaction_is_accepted",
		},
		{
			name = "buffers: apply checks revision and order",
			files = []string{"apps/buffers/tests/buffer-scenarios.mica"},
			call = "test/buffer_apply_checks_revision_and_order",
		},
		{
			name = "buffers: conflict policy is selectable",
			files = []string{"apps/buffers/tests/buffer-scenarios.mica"},
			call = "test/buffer_conflict_policy_is_selectable",
		},
		{
			name = "buffers: kill retires the name",
			files = []string{"apps/buffers/tests/buffer-scenarios.mica"},
			call = "test/kill_buffer_retires_the_name",
		},
		{
			// The completion is read on a later turn, so only the staging half
			// is comparable here; the runtime suite covers the pair.
			name  = "buffers: apply records a completion",
			files = []string{"apps/buffers/tests/buffer-scenarios.mica"},
			call  = "test/buffer_apply_records_completion",
		},
		{
			// Reversion needs published history, so this runs a sequence of
			// verbs, each its own transaction: three versions, a reversion, and
			// a summary read on a later turn.
			name  = "buffers: reversion splices an earlier revision",
			files = []string{"apps/buffers/tests/buffer-scenarios.mica"},
			calls = []string {
				"test/buffer_revert_seed",
				"test/buffer_revert_second_version",
				"test/buffer_revert_third_version",
				"test/buffer_revert_restores_an_earlier_revision",
				"test/buffer_revert_reports_status",
			},
		},
		{
			// Compaction describes committed content, so the sequence reaches a
			// committed buffer before checking that it may not share a
			// transaction with a change.
			name  = "buffers: compaction seals the view",
			files = []string{"apps/buffers/tests/buffer-scenarios.mica"},
			calls = []string {
				"test/buffer_compaction_seed",
				"test/buffer_compaction_refuses_a_moved_view",
				"test/buffer_compaction_seals_the_view",
			},
		},
		{
			name = "buffers: find locates and windows",
			files = []string{"apps/buffers/tests/buffer-scenarios.mica"},
			call = "test/buffer_find_locates_and_windows",
		},
		{
			name = "buffers: the line projection",
			files = []string{"apps/buffers/tests/buffer-scenarios.mica"},
			call = "test/buffer_lines_projects_spans",
		},
		{
			name = "buffers: line spans address lines",
			files = []string{"apps/buffers/tests/buffer-scenarios.mica"},
			call = "test/buffer_line_spans_address_lines",
		},
		{
			name = "buffers: positions convert to lines and columns",
			files = []string{"apps/buffers/tests/buffer-scenarios.mica"},
			call = "test/buffer_positions_convert_to_lines_and_columns",
		},
		{
			name = "buffers: line columns convert to offsets",
			files = []string{"apps/buffers/tests/buffer-scenarios.mica"},
			call = "test/buffer_line_columns_convert_to_offsets",
		},
		{
			name = "buffers: the viewport is bounded",
			files = []string{"apps/buffers/tests/buffer-scenarios.mica"},
			call = "test/buffer_viewport_is_bounded",
		},
		{
			// The editor core is a Mica application. These cases compare the
			// Odin compiler and the Mica emitter on its session, command
			// loop, window tree, undo, and M-x paths.
			name  = "editor: sessions and buffers",
			files = editor_files,
			call  = "test/editor_session_seeds_a_frame",
		},
		{
			name = "editor: typing and key resolution",
			files = editor_files,
			call = "test/editor_typing_inserts_at_point",
		},
		{
			name = "editor: consecutive Returns preserve the viewport",
			files = editor_files,
			calls = []string {
				"test/editor_consecutive_returns_seed",
				"test/editor_consecutive_returns_first",
				"test/editor_consecutive_returns_second",
			},
		},
		{
			name = "editor: prefix and undefined keys",
			files = editor_files,
			calls = []string {
				"test/editor_prefix_and_undefined_keys",
				"test/editor_text_clears_a_stale_prefix",
			},
		},
		{
			name = "editor: movement and numeric arguments",
			files = editor_files,
			calls = []string {
				"test/editor_movement_keeps_a_goal_column",
				"test/editor_numeric_arguments",
			},
		},
		{
			name = "editor: undo and redo across commits",
			files = editor_files,
			calls = []string {
				"test/editor_undo_seed",
				"test/editor_undo_types_b",
				"test/editor_undo_types_c",
				"test/editor_undo_reverts_one_group",
				"test/editor_undo_reports_nothing_left",
				"test/editor_redo_reapplies_the_group",
				"test/editor_redo_tail_undo",
				"test/editor_redo_tail_type",
				"test/editor_redo_tail_is_gone",
			},
		},
		{
			name = "editor: session and keymap invariants",
			files = editor_files,
			calls = []string {
				"test/editor_session_seeds_a_frame",
				"test/editor_session_create_is_idempotent",
				"test/editor_session_rejects_a_different_actor",
				"test/editor_word_and_keymap_invariants",
			},
		},
		{
			name = "editor: window split and independent points",
			files = editor_files,
			calls = []string {
				"test/editor_windows_seed",
				"test/editor_windows_split_and_points",
				"test/editor_windows_edit_rebases_both",
				"test/editor_window_tree_commands",
			},
		},
		{
			name = "editor: marks and regions",
			files = editor_files,
			calls = []string{"test/editor_marks_seed", "test/editor_marks_and_region"},
		},
		{
			name = "editor: M-x runs a registered command",
			files = editor_files,
			call = "test/editor_max_runs_a_registered_command",
		},
		{
			name = "editor: picker navigation and buffer switching",
			files = editor_files,
			call = "test/editor_picker_navigation_and_buffer_switch",
		},
		{
			name = "editor: minibuffer editing and escape",
			files = editor_files,
			calls = []string {
				"test/editor_minibuffer_editing",
				"test/editor_minibuffer_survives_a_broken_prompt",
			},
		},
		{
			name = "editor: staged results finalize",
			files = editor_files,
			calls = []string {
				"test/editor_staged_result_has_a_token",
				"test/editor_result_finalizes",
			},
		},
		{
			name = "editor: the snapshot payload",
			files = editor_files,
			calls = []string {
				"test/editor_snapshot_seed",
				"test/editor_snapshot_reports_the_viewport",
			},
		},
		{
			name = "editor: the JSON input bridge",
			files = editor_files,
			calls = []string {
				"test/editor_json_bridge_seed",
				"test/editor_json_bridge_runs_items",
				"test/editor_json_bridge_commits_tagged_items_in_one_call",
				"test/editor_json_bridge_rejects_bad_json",
			},
		},
		{
			name = "editor: pointer items move point",
			files = editor_files,
			calls = []string{"test/editor_snapshot_seed", "test/editor_pointer_items_move_point"},
		},
		{
			// The marker and annotation library spans commits: seed, a
			// token-tagged apply, then a rebase by the committed delta.
			name  = "buffers: markers rebase through a committed delta",
			files = []string {
				"apps/shared/buffers.mica",
				"apps/buffers/tests/marker-scenarios.mica",
			},
			calls = []string {
				"test/marker_rebase_insertion_types",
				"test/marker_rebase_shifts_and_collapses",
				"test/marker_seed",
				"test/marker_create_at_committed_revision",
				"test/marker_apply_with_token",
				"test/marker_rebases_from_the_recorded_delta",
				"test/annotation_follows_its_markers",
				"test/annotation_drop_collapsed",
			},
		},
		{
			name = "mud scenarios: social commands",
			files = []string {
				"apps/shared/string.mica",
				"apps/shared/list.mica",
				"apps/shared/events.mica",
				"apps/mud/core.mica",
				"apps/mud/command-parser.mica",
				"apps/mud/event-substitutions.mica",
				"apps/mud/tests/event-scenarios.mica",
			},
			call = "test/social_commands_emit_perspective_events",
		},
	}

	pass, fail := 0, 0
	for entry in cases {
		baseline, baseline_ok := run_case(entry, nil)
		emitted, emitted_ok := run_case(entry, compile_case(entry))
		switch {
		case !baseline_ok:
			fmt.printf("SKIP %s: odin baseline did not run\n", entry.name)
			fail += 1
		case !emitted_ok:
			fmt.printf("FAIL %s: mica program did not run\n", entry.name)
			fail += 1
		case v.value_eq(baseline, emitted):
			fmt.printf(
				"ok   %s (%s)\n",
				entry.name,
				v.value_to_string(baseline, context.temp_allocator),
			)
			pass += 1
		case:
			fmt.printf(
				"FAIL %s: differ (odin %s, mica %s)\n",
				entry.name,
				v.value_to_string(baseline, context.temp_allocator),
				v.value_to_string(emitted, context.temp_allocator),
			)
			fail += 1
		}
	}
	fmt.printf("\npass=%d fail=%d\n", pass, fail)
	if fail > 0 {
		os.exit(1)
	}
}

// Compiles the case's concatenated sources with the Mica emitter, returning
// the artifact bytes or nil.
compile_case :: proc(entry: Case) -> []u8 {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := r.world_start(&kernel, COMPILER, context.allocator)
	if !start.ok {
		fmt.eprintln("compiler load failed:", start.message)
		return nil
	}
	defer r.world_destroy(world)
	_ = r.world_wait(world, world.entry)

	source := ""
	for path in entry.files {
		data, read_err := os.read_entire_file_from_path(path, context.allocator)
		if read_err != nil {
			fmt.eprintln("cannot read", path)
			return nil
		}
		source = fmt.aprintf("%s\n%s", source, string(data))
	}
	outcome := r.world_call(
		world,
		"emit_source",
		[]k.Role_Pair {
			{
				role = v.value_symbol(v.symbol_intern("source")),
				value = v.value_string(context.allocator, source),
			},
		},
	)
	if outcome.kind != .Complete {
		return nil
	}
	fields, fields_ok := v.value_as_map(outcome.value)
	if !fields_ok {
		return nil
	}
	ok, _ := v.value_as_bool(map_get(fields, "ok"))
	if !ok {
		if errors := map_get(fields, "errors"); errors != 0 {
			if list, list_ok := v.value_as_list(errors); list_ok && len(list) > 0 {
				if s, s_ok := v.value_as_string(list[0]); s_ok {
					fmt.eprintln("emit error:", s)
				}
			}
		}
		return nil
	}
	artifact, artifact_ok := v.value_as_bytes(map_get(fields, "bytes"))
	if !artifact_ok {
		return nil
	}
	owned := make([]u8, len(artifact), context.allocator)
	copy(owned, artifact)
	return owned
}

// Loads the case's files, swaps in `artifact` when non-nil, runs setup then
// call, and returns [result, ok].
run_case :: proc(entry: Case, artifact: []u8) -> (v.Value, bool) {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	// A mis-emitted loop is unbounded; the budget turns that into a failed
	// case rather than a hung run.
	world, start := r.world_start(&kernel, entry.files, context.allocator, r.HARNESS_CONFIG)
	if !start.ok {
		return v.Value(0), false
	}
	defer r.world_destroy(world)
	started := r.world_wait(world, world.entry)
	if started.kind != .Complete {
		return v.Value(0), false
	}

	if artifact != nil {
		program, decode_error := vm.program_from_bytes(artifact, context.allocator)
		if decode_error != .None {
			fmt.eprintln("decode:", decode_error)
			return v.Value(0), false
		}
		if validation := vm.program_validate(program); validation != .None {
			fmt.eprintln(entry.name, "invalid program:", validation)
			return v.Value(0), false
		}
		replaced := r.world_replace_program(world, program, context.allocator)
		assert(replaced.ok, replaced.message)
	}

	if entry.setup != "" {
		if setup := r.world_call(world, entry.setup, nil); setup.kind != .Complete {
			return v.Value(0), false
		}
	}
	if len(entry.calls) > 0 {
		result: v.Value
		for call in entry.calls {
			outcome := r.world_call(world, call, nil)
			if outcome.kind != .Complete {
				detail := outcome.message
				if error_value, is_error := v.value_as_error(outcome.error); is_error {
					detail = error_value.message
				}
				fmt.eprintf(
					"  [%s] %s failed: kind=%v message=%s error=%s\n",
					entry.name,
					call,
					outcome.kind,
					outcome.message,
					detail,
				)
				return v.Value(0), false
			}
			result = outcome.value
		}
		return result, true
	}
	if entry.call == "" {
		return v.Value(0), true
	}
	if len(entry.roles) == 0 {
		// No roles: call with no arguments.
		outcome := r.world_call(world, entry.call, nil)
		if outcome.kind != .Complete {
			detail := outcome.message
			if error_value, is_error := v.value_as_error(outcome.error); is_error {
				detail = error_value.message
			}
			fmt.eprintf(
				"  [%s] call failed: kind=%v message=%s error=%s\n",
				entry.name,
				outcome.kind,
				outcome.message,
				detail,
			)
		}
		return outcome.value, outcome.kind == .Complete
	}
	roles := make([]k.Role_Pair, len(entry.roles), context.temp_allocator)
	for role_name, index in entry.roles {
		value, has_value := world.ctx.identities[role_name.identity]
		if !has_value {
			value = v.value_symbol(v.symbol_intern(role_name.identity))
		}
		roles[index] = k.Role_Pair {
			role  = v.value_symbol(v.symbol_intern(role_name.role)),
			value = value,
		}
	}
	outcome := r.world_call(world, entry.call, roles)
	if outcome.kind != .Complete {
		// A raised error is a result too: compare its code so both programs
		// failing the same way counts as agreement.
		if error_value, is_error := v.value_as_error(outcome.value); is_error {
			return v.value_error_code(error_value.code), true
		}
		detail := outcome.message
		if error_value, is_error := v.value_as_error(outcome.value); is_error {
			detail = error_value.message
		}
		fmt.eprintf(
			"  [%s] call failed: kind=%v message=%s detail=%s\n",
			entry.name,
			outcome.kind,
			outcome.message,
			detail,
		)
		return v.Value(0), false
	}
	return outcome.value, true
}

map_get :: proc(entries: []v.Map_Entry, name: string) -> v.Value {
	key := v.value_symbol(v.symbol_intern(name))
	for entry in entries {
		if entry.key == key {
			return entry.value
		}
	}
	return v.Value(0)
}
