// Filein driver: compile a `.mica` file and run it against a kernel
// transaction.
//
// The driver pre-scans top-level `make_identity`, `make_relation`, and
// `make_functional_relation` declarations, installs parsed rules, compiles the
// program, registers the builtins the runtime provides, and commits at the
// end or at a `commit()` boundary.
package mica_runtime

import c "../compiler"
import k "../kernel"
import s "../store"
import v "../var"
import vm "../vm"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"

Run_Result :: struct {
	ok:      bool,
	message: string,
}

@(private)
Field_Info :: struct {
	relation:      k.Relation_ID,
	key_positions: []u16,
}

@(private)
Builtin_Env :: struct {
	kernel:                   ^k.Kernel,
	ctx:                      ^c.Compile_Context,
	fields:                   map[string]Field_Info,
	allocator:                mem.Allocator,
	// The scheduler that owns this world's mailboxes. Nil for a bare task.
	scheduler:                ^Scheduler,
	// When true, tasks mint authority for `actor` at init. The entry task in
	// `run_files` stays root so declarations and grants can load.
	enforce_authority:        bool,
	// Change subscriptions registered by this world.
	subscriptions:            Subscription_Store,

	// Source text per filein unit, keyed by unit name.
	unit_sources:             map[string]string,

	// Runtime context identities returned by `endpoint()`, `actor()`, and
	// `principal()`.
	endpoint:                 v.Value,
	actor:                    v.Value,
	principal:                v.Value,

	// One committed marker-position index, rebuilt lazily for the requested
	// buffer and snapshot version. Transactional marker writes bypass it.
	marker_index_lock:        sync.Mutex,
	marker_index_initialized: bool,
	marker_index_version:     u64,
	marker_index_revision:    u64,
	marker_index_buffer:      v.Symbol,
	marker_index_points:      [dynamic]Marker_Point,
}

// Writes `text` as a double-quoted Mica string literal with escapes.
@(private)
write_mica_string_literal :: proc(builder: ^strings.Builder, text: string) {
	strings.write_byte(builder, '"')
	for ch in text {
		switch ch {
		case '\\':
			strings.write_string(builder, "\\\\")
		case '"':
			strings.write_string(builder, "\\\"")
		case '\n':
			strings.write_string(builder, "\\n")
		case '\r':
			strings.write_string(builder, "\\r")
		case '\t':
			strings.write_string(builder, "\\t")
		case:
			strings.write_rune(builder, ch)
		}
	}
	strings.write_byte(builder, '"')
}

// Rewrites `grant [role] subject` blocks into policy assertions, mirroring the
// Rust source task. `read:`/`write:`/`invoke:` targets are symbols; `effect`
// takes no targets.
@(private)
expand_grant_blocks :: proc(source: string, allocator: mem.Allocator) -> (string, Run_Result) {
	if !strings.contains(source, "grant ") {
		return source, Run_Result{ok = true}
	}
	lines := strings.split(source, "\n", context.temp_allocator)
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	index := 0
	for index < len(lines) {
		line := lines[index]
		trimmed := strings.trim_space(line)
		kind, subject, is_grant := grant_header(trimmed)
		if !is_grant {
			strings.write_string(&builder, line)
			strings.write_byte(&builder, '\n')
			index += 1
			continue
		}

		index += 1
		operation := ""
		closed := false
		for index < len(lines) {
			body := strings.trim_space(lines[index])
			if body == "end" {
				closed = true
				index += 1
				break
			}
			if body == "" || strings.has_prefix(body, "//") {
				index += 1
				continue
			}
			if section, rest, is_section := grant_section(body); is_section {
				operation = section
				if !write_grant_assertions(&builder, kind, subject, operation, rest, allocator) {
					return "", Run_Result{ok = false, message = "malformed grant target"}
				}
				index += 1
				continue
			}
			if operation != "" {
				if !write_grant_assertions(&builder, kind, subject, operation, body, allocator) {
					return "", Run_Result{ok = false, message = "malformed grant target"}
				}
			}
			index += 1
		}
		if !closed {
			return "", Run_Result{ok = false, message = "unterminated grant block"}
		}
	}
	return strings.to_string(builder), Run_Result{ok = true}
}

@(private)
grant_header :: proc(line: string) -> (kind: string, subject: string, ok: bool) {
	if !strings.has_prefix(line, "grant ") {
		return "", "", false
	}
	rest := strings.trim_space(strings.trim_prefix(line, "grant "))
	if strings.has_prefix(rest, "role ") {
		role := strings.trim_space(strings.trim_prefix(rest, "role "))
		if role == "" {
			return "", "", false
		}
		return "role", role, true
	}
	if rest == "" {
		return "", "", false
	}
	return "actor", rest, true
}

@(private)
grant_section :: proc(line: string) -> (operation: string, rest: string, ok: bool) {
	if line == "read" {
		return "read", "", true
	}
	if strings.has_prefix(line, "read:") {
		return "read", strings.trim_space(strings.trim_prefix(line, "read:")), true
	}
	if line == "write" {
		return "write", "", true
	}
	if strings.has_prefix(line, "write:") {
		return "write", strings.trim_space(strings.trim_prefix(line, "write:")), true
	}
	if line == "invoke" {
		return "invoke", "", true
	}
	if strings.has_prefix(line, "invoke:") {
		return "invoke", strings.trim_space(strings.trim_prefix(line, "invoke:")), true
	}
	if line == "effect" {
		return "effect", "", true
	}
	return "", "", false
}

@(private)
write_grant_assertions :: proc(
	builder: ^strings.Builder,
	kind: string,
	subject: string,
	operation: string,
	targets: string,
	allocator: mem.Allocator,
) -> bool {
	relation: string
	if operation == "read" {
		relation = "RoleCanRead" if kind == "role" else "CanRead"
	} else if operation == "write" {
		relation = "RoleCanWrite" if kind == "role" else "CanWrite"
	} else if operation == "invoke" {
		relation = "RoleCanInvoke" if kind == "role" else "CanInvoke"
	} else if operation == "effect" {
		relation = "RoleCanEffect" if kind == "role" else "CanEffect"
		strings.write_string(builder, "assert ")
		strings.write_string(builder, relation)
		strings.write_byte(builder, '(')
		strings.write_string(builder, subject)
		strings.write_string(builder, ")\n")
		return true
	} else {
		return false
	}

	tokens := strings.split(targets, ",", context.temp_allocator)
	for token in tokens {
		for raw_target in strings.split(token, " ", context.temp_allocator) {
			target := strings.trim_space(raw_target)
			if target == "" {
				continue
			}
			if target[0] != ':' {
				return false
			}
			strings.write_string(builder, "assert ")
			strings.write_string(builder, relation)
			strings.write_byte(builder, '(')
			strings.write_string(builder, subject)
			strings.write_string(builder, ", ")
			strings.write_string(builder, target)
			strings.write_string(builder, ")\n")
		}
	}
	_ = allocator
	return true
}

// Replaces `include_text("relative/path")` calls with string literals holding
// the referenced file's contents, resolved against the including file. This
// matches the Rust source task's load-time substitution.
@(private)
substitute_include_text :: proc(
	source: string,
	base_directory: string,
	allocator: mem.Allocator,
) -> (
	string,
	Run_Result,
) {
	if !strings.contains(source, "include_text") {
		return source, Run_Result{ok = true}
	}

	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	index := 0
	for index < len(source) {
		offset := strings.index(source[index:], "include_text")
		if offset < 0 {
			strings.write_string(&builder, source[index:])
			break
		}
		start := index + offset
		strings.write_string(&builder, source[index:start])

		cursor := start + len("include_text")
		for cursor < len(source) && (source[cursor] == ' ' || source[cursor] == '\t') {
			cursor += 1
		}
		if cursor >= len(source) || source[cursor] != '(' {
			strings.write_string(&builder, "include_text")
			index = start + len("include_text")
			continue
		}
		cursor += 1
		for cursor < len(source) && (source[cursor] == ' ' || source[cursor] == '\t') {
			cursor += 1
		}
		if cursor >= len(source) || source[cursor] != '"' {
			strings.write_string(&builder, "include_text")
			index = start + len("include_text")
			continue
		}
		end_quote := cursor + 1
		for end_quote < len(source) && source[end_quote] != '"' {
			end_quote += 1
		}
		if end_quote >= len(source) {
			return "", Run_Result{ok = false, message = "unterminated include_text path"}
		}
		closing := end_quote + 1
		for closing < len(source) && (source[closing] == ' ' || source[closing] == '\t') {
			closing += 1
		}
		if closing >= len(source) || source[closing] != ')' {
			strings.write_string(&builder, "include_text")
			index = start + len("include_text")
			continue
		}

		relative := source[cursor + 1:end_quote]
		full := relative
		joined_allocated := false
		if !filepath.is_abs(relative) {
			joined, join_err := filepath.join([]string{base_directory, relative}, allocator)
			if join_err != nil {
				return "", Run_Result {
					ok = false,
					message = "include_text cannot join the source path",
				}
			}
			full = joined
			joined_allocated = true
		}
		contents, read_err := os.read_entire_file(full, allocator)
		if read_err != nil {
			message := fmt.aprintf("include_text cannot read %s", full, allocator = allocator)
			if joined_allocated {
				delete(full, allocator)
			}
			return "", Run_Result{ok = false, message = message}
		}
		if joined_allocated {
			delete(full, allocator)
		}
		write_mica_string_literal(&builder, string(contents))
		index = closing + 1
	}
	return strings.to_string(builder), Run_Result{ok = true}
}

// Options for loading and running a world.
Run_Options :: struct {
	// Name of the declared identity that spawned tasks run as. Empty keeps
	// every task at root.
	actor:      string,
	// Filein unit name for `fileout`. Empty derives one unit per file.
	unit:       string,
	// Durable store directory; empty runs in memory.
	store_path: string,
	// Store fsync policy. Defaults to group commit.
	durability: s.Durability,
}

// Compiles and runs a set of fileins as one world against `kernel`. On success
// the transaction is committed. The world is destroyed on return; use
// `world_start` to keep one alive.
run_files :: proc(
	kernel: ^k.Kernel,
	paths: []string,
	allocator := context.allocator,
	options := Run_Options{},
) -> Run_Result {
	world, start_result := world_start(
		kernel,
		paths,
		allocator,
		World_Config {
			actor = options.actor,
			unit = options.unit,
			workers = 1,
			store_path = options.store_path,
			durability = options.durability,
		},
	)
	if !start_result.ok {
		return start_result
	}
	defer world_destroy(world)

	outcome := world_wait(world, world.entry)
	// Let any children the entry spawned finish before the world is torn
	// down; otherwise a still-ready child can be dropped at shutdown.
	scheduler_wait_quiescent(&world.scheduler)
	#partial switch outcome.kind {
	case .Complete:
		return Run_Result{ok = true, message = "loaded"}

	case .Aborted:
		if entry, found := world.scheduler.entries[world.entry]; found {
			if entry.task.state.error != v.Value(0) {
				return Run_Result {
					ok = false,
					message = format_error(entry.task.state.error, allocator),
				}
			}
		}
		return Run_Result{ok = false, message = outcome.message}

	case .Pending:
		return Run_Result{ok = false, message = "task did not finish"}
	}
	return Run_Result{ok = false, message = "task did not finish"}
}

// Compiles and runs one filein against `kernel`. On success the transaction is
// committed.
run_filein :: proc(kernel: ^k.Kernel, path: string, allocator := context.allocator) -> Run_Result {
	return run_files(kernel, []string{path}, allocator)
}

@(private)
Declarations :: struct {
	next_relation:    u32,
	next_identity:    u64,
	next_rule:        u64,
	// Named identities declared by the loaded files, recorded as NamedIdentity
	// facts once every file is prescanned.
	named_identities: [dynamic]Named_Identity,
}

// A declared identity and its source name.
Named_Identity :: struct {
	identity: v.Value,
	name:     v.Symbol,
}

// Assert the catalog facts that describe relations: Relation, RelationName, and
// Arity. The system relations are installed empty, so the runtime records the
// facts as the world loads.
@(private)
assert_relation_facts :: proc(env: ^Builtin_Env, relations: []k.Relation_Metadata) -> Run_Result {
	// NOTE: the transient tuple arrays below use the temp allocator.
	// transaction_assert deep-copies synchronously, so nothing outlives the
	// call; allocating them in env.allocator would leak one array per fact.
	if len(relations) == 0 {
		return Run_Result{ok = true, message = "loaded"}
	}
	tx := k.kernel_begin(env.kernel)
	defer k.transaction_destroy(&tx)
	result := stage_relation_facts(env, &tx, relations)
	if !result.ok {return result}

	committed, commit_err := k.transaction_commit(&tx)
	if commit_err != k.Kernel_Error.None {
		return catalog_error(env, "Relation", commit_err)
	}
	k.snapshot_release(committed)
	return Run_Result{ok = true, message = "loaded"}
}

// Stages reflection facts in the same transaction as their catalogue entries.
@(private)
stage_relation_facts :: proc(env: ^Builtin_Env, tx: ^k.Transaction, relations: []k.Relation_Metadata) -> Run_Result {
	for metadata in relations {
		identity, identity_ok := v.value_identity_raw(u64(metadata.id))
		if !identity_ok {
			return Run_Result{ok = false, message = "relation identity is out of range"}
		}
		arity_value, arity_ok := v.value_int(i64(metadata.arity))
		if !arity_ok {
			return Run_Result{ok = false, message = "relation arity is out of range"}
		}
		if err := k.transaction_assert(
			tx,
			k.SYSTEM_RELATION_ID,
			v.tuple_new(context.temp_allocator, []v.Value{identity}),
		); err != k.Kernel_Error.None {
			return catalog_error(env, "Relation", err)
		}
		if err := k.transaction_assert(
			tx,
			k.SYSTEM_RELATION_NAME_ID,
			v.tuple_new(
				context.temp_allocator,
				[]v.Value{identity, v.value_symbol(metadata.name)},
			),
		); err != k.Kernel_Error.None {
			return catalog_error(env, "RelationName", err)
		}
		if err := k.transaction_assert(
			tx,
			k.SYSTEM_ARITY_ID,
			v.tuple_new(context.temp_allocator, []v.Value{identity, arity_value}),
		); err != k.Kernel_Error.None {
			return catalog_error(env, "Arity", err)
		}
		durability_name := "durable"
		if metadata.durability == .Volatile {
			durability_name = "volatile"
		}
		if err := k.transaction_assert(
			tx,
			k.SYSTEM_RELATION_DURABILITY_ID,
			v.tuple_new(
				context.temp_allocator,
				[]v.Value{identity, v.value_symbol(v.symbol_intern(durability_name))},
			),
		); err != k.Kernel_Error.None {
			return catalog_error(env, "RelationDurability", err)
		}
		for position in 0 ..< int(metadata.arity) {
			name, has_name := k.metadata_argument_name(metadata, u16(position))
			if !has_name {
				continue
			}
			if err := k.transaction_assert(
				tx,
				k.SYSTEM_ARGUMENT_NAME_ID,
				v.tuple_new(
					context.temp_allocator,
					[]v.Value{identity, value_int_must(i64(position)), v.value_symbol(name)},
				),
			); err != k.Kernel_Error.None {
				return catalog_error(env, "ArgumentName", err)
			}
		}
		policy_name := "set"
		#partial switch metadata.conflict.kind {
		case .Functional:
			policy_name = "functional"
		case .Event_Append:
			policy_name = "event_append"
		case .Set:
		}
		if err := k.transaction_assert(
			tx,
			k.SYSTEM_CONFLICT_POLICY_ID,
			v.tuple_new(
				context.temp_allocator,
				[]v.Value{identity, v.value_symbol(v.symbol_intern(policy_name))},
			),
		); err != k.Kernel_Error.None {
			return catalog_error(env, "ConflictPolicy", err)
		}
		if metadata.conflict.kind == .Functional {
			for position, slot in metadata.conflict.key_positions {
				if err := k.transaction_assert(
					tx,
					k.SYSTEM_FUNCTIONAL_KEY_ID,
					v.tuple_new(
						context.temp_allocator,
						[]v.Value {
							identity,
							value_int_must(i64(slot)),
							value_int_must(i64(position)),
						},
					),
				); err != k.Kernel_Error.None {
					return catalog_error(env, "FunctionalKey", err)
				}
			}
		}
		// Ordinal 0 is the natural full-tuple index; explicit metadata indexes
		// follow, matching the Rust catalogue's ordinal numbering.
		for ordinal in 0 ..< 1 + len(metadata.indexes) {
			index_value, index_ok := relation_index_identity(metadata.id, u16(ordinal))
			if !index_ok {
				return Run_Result{ok = false, message = "index identity is out of range"}
			}
			if err := k.transaction_assert(
				tx,
				k.SYSTEM_INDEX_ID,
				v.tuple_new(context.temp_allocator, []v.Value{identity, index_value}),
			); err != k.Kernel_Error.None {
				return catalog_error(env, "Index", err)
			}
			positions: []u16
			storage := "radix"
			if ordinal == 0 {
				natural := make([]u16, int(metadata.arity), context.temp_allocator)
				for position in 0 ..< int(metadata.arity) {
					natural[position] = u16(position)
				}
				positions = natural
				storage = "btree"
			} else {
				positions = metadata.indexes[ordinal - 1].positions
			}
			for position, slot in positions {
				if err := k.transaction_assert(
					tx,
					k.SYSTEM_INDEX_POSITION_ID,
					v.tuple_new(
						context.temp_allocator,
						[]v.Value {
							index_value,
							value_int_must(i64(slot)),
							value_int_must(i64(position)),
						},
					),
				); err != k.Kernel_Error.None {
					return catalog_error(env, "IndexPosition", err)
				}
			}
			if err := k.transaction_assert(
				tx,
				k.SYSTEM_INDEX_STORAGE_KIND_ID,
				v.tuple_new(
					context.temp_allocator,
					[]v.Value{index_value, v.value_symbol(v.symbol_intern(storage))},
				),
			); err != k.Kernel_Error.None {
				return catalog_error(env, "IndexStorageKind", err)
			}
		}
	}
	return Run_Result{ok = true, message = "loaded"}
}

// Derives the identity of a relation's index at `ordinal`, mirroring the Rust
// catalogue: raw * 65537 + ordinal, truncated to the identity payload.
@(private)
relation_index_identity :: proc(relation: k.Relation_ID, ordinal: u16) -> (v.Value, bool) {
	raw := (u64(relation) * 65537 + u64(ordinal)) & v.IDENTITY_MAX
	return v.value_identity_raw(raw)
}

@(private)
Rule_Fact :: struct {
	id:     v.Identity,
	head:   k.Relation_ID,
	source: string,
	active: bool,
}

// Records declared identity names as NamedIdentity facts so a later boot can
// resolve `#name` without the source files.
@(private)
assert_named_identities :: proc(env: ^Builtin_Env, entries: []Named_Identity) -> Run_Result {
	if len(entries) == 0 {
		return Run_Result{ok = true, message = "loaded"}
	}
	tx := k.kernel_begin(env.kernel)
	defer k.transaction_destroy(&tx)
	for entry in entries {
		if err := k.transaction_assert(
			&tx,
			k.SYSTEM_NAMED_IDENTITY_ID,
			v.tuple_new(
				context.temp_allocator,
				[]v.Value{entry.identity, v.value_symbol(entry.name)},
			),
		); err != k.Kernel_Error.None {
			return Run_Result {
				ok = false,
				message = fmt.aprintf(
					"cannot record named identity: %v",
					err,
					allocator = env.allocator,
				),
			}
		}
	}
	committed, commit_err := k.transaction_commit(&tx)
	if commit_err != k.Kernel_Error.None {
		return Run_Result {
			ok = false,
			message = fmt.aprintf(
				"cannot record named identities: %v",
				commit_err,
				allocator = env.allocator,
			),
		}
	}
	k.snapshot_release(committed)
	return Run_Result{ok = true, message = "loaded"}
}

// Records the loaded unit sources so a later boot can recompile code and serve
// `fileout` without the source files.
@(private)
assert_unit_sources :: proc(env: ^Builtin_Env, entries: []Unit_Source_Fact) -> Run_Result {
	if len(entries) == 0 {
		return Run_Result{ok = true, message = "loaded"}
	}
	tx := k.kernel_begin(env.kernel)
	defer k.transaction_destroy(&tx)
	for entry in entries {
		ordinal, ordinal_ok := v.value_int(entry.ordinal)
		if !ordinal_ok {
			return Run_Result{ok = false, message = "unit ordinal is out of range"}
		}
		if err := k.transaction_assert(
			&tx,
			k.SYSTEM_UNIT_SOURCE_ID,
			v.tuple_new(
				context.temp_allocator,
				[]v.Value {
					ordinal,
					v.value_symbol(entry.unit),
					v.value_string(context.temp_allocator, entry.source),
				},
			),
		); err != k.Kernel_Error.None {
			return Run_Result {
				ok = false,
				message = fmt.aprintf(
					"cannot record unit source: %v",
					err,
					allocator = env.allocator,
				),
			}
		}
	}
	committed, commit_err := k.transaction_commit(&tx)
	if commit_err != k.Kernel_Error.None {
		return Run_Result {
			ok = false,
			message = fmt.aprintf(
				"cannot record unit sources: %v",
				commit_err,
				allocator = env.allocator,
			),
		}
	}
	k.snapshot_release(committed)
	return Run_Result{ok = true, message = "loaded"}
}

@(private)
Unit_Source_Fact :: struct {
	ordinal: i64,
	unit:    v.Symbol,
	source:  string,
}

// Encodes the freshly compiled program and records it as a ProgramBytes
// row keyed by content identity, so a later boot can resolve methods
// without recompiling sources (#77).
@(private)
assert_program_bytes :: proc(env: ^Builtin_Env, program: ^vm.Program) -> Run_Result {
	bytes: [dynamic]u8
	defer delete(bytes)
	if error := vm.program_to_bytes(program, &bytes); error != .None {
		return Run_Result {
			ok = false,
			message = fmt.aprintf(
				"cannot encode program artifact: %v",
				error,
				allocator = env.allocator,
			),
		}
	}
	id, id_ok := vm.program_artifact_id(bytes[:])
	if !id_ok {
		return Run_Result{ok = false, message = "program identity is out of range"}
	}
	tx := k.kernel_begin(env.kernel)
	defer k.transaction_destroy(&tx)
	if err := k.transaction_assert(
		&tx,
		k.SYSTEM_PROGRAM_BYTES_ID,
		v.tuple_new(context.temp_allocator, []v.Value{id, v.value_bytes(env.allocator, bytes[:])}),
	); err != k.Kernel_Error.None {
		return Run_Result {
			ok = false,
			message = fmt.aprintf(
				"cannot record program bytes: %v",
				err,
				allocator = env.allocator,
			),
		}
	}
	committed, commit_err := k.transaction_commit(&tx)
	if commit_err != k.Kernel_Error.None {
		return Run_Result {
			ok = false,
			message = fmt.aprintf(
				"cannot record program bytes: %v",
				commit_err,
				allocator = env.allocator,
			),
		}
	}
	k.snapshot_release(committed)
	return Run_Result{ok = true, message = "loaded"}
}

// Assert the catalog facts that describe rules: Rule, RuleHead, and RuleSource.
@(private)
assert_rule_facts :: proc(env: ^Builtin_Env, rules: []Rule_Fact) -> Run_Result {
	if len(rules) == 0 {
		return Run_Result{ok = true, message = "loaded"}
	}
	tx := k.kernel_begin(env.kernel)
	defer k.transaction_destroy(&tx)
	for rule_fact in rules {
		identity, identity_ok := v.value_identity_raw(u64(rule_fact.id))
		if !identity_ok {
			return Run_Result{ok = false, message = "rule identity is out of range"}
		}
		head, head_ok := v.value_identity_raw(u64(rule_fact.head))
		if !head_ok {
			return Run_Result{ok = false, message = "rule head identity is out of range"}
		}
		if err := k.transaction_assert(
			&tx,
			k.SYSTEM_RULE_ID,
			v.tuple_new(context.temp_allocator, []v.Value{identity}),
		); err != k.Kernel_Error.None {
			return catalog_error(env, "Rule", err)
		}
		if err := k.transaction_assert(
			&tx,
			k.SYSTEM_RULE_HEAD_ID,
			v.tuple_new(context.temp_allocator, []v.Value{identity, head}),
		); err != k.Kernel_Error.None {
			return catalog_error(env, "RuleHead", err)
		}
		if err := k.transaction_assert(
			&tx,
			k.SYSTEM_RULE_SOURCE_ID,
			v.tuple_new(
				context.temp_allocator,
				[]v.Value{identity, v.value_string(context.temp_allocator, rule_fact.source)},
			),
		); err != k.Kernel_Error.None {
			return catalog_error(env, "RuleSource", err)
		}
		if err := k.transaction_assert(
			&tx,
			k.SYSTEM_ACTIVE_RULE_ID,
			v.tuple_new(
				context.temp_allocator,
				[]v.Value{identity, v.value_bool(rule_fact.active)},
			),
		); err != k.Kernel_Error.None {
			return catalog_error(env, "ActiveRule", err)
		}
	}
	committed, commit_err := k.transaction_commit(&tx)
	if commit_err != k.Kernel_Error.None {
		return catalog_error(env, "Rule", commit_err)
	}
	k.snapshot_release(committed)
	return Run_Result{ok = true, message = "loaded"}
}

@(private)
catalog_error :: proc(env: ^Builtin_Env, name: string, err: k.Kernel_Error) -> Run_Result {
	return Run_Result {
		ok = false,
		message = fmt.aprintf(
			"cannot record catalog facts for %s: %v",
			name,
			err,
			allocator = env.allocator,
		),
	}
}

// Pre-scans one file's top-level declarations into the shared compile context.
@(private)
prescan_file :: proc(
	env: ^Builtin_Env,
	ast: ^c.Program_AST,
	declarations: ^Declarations,
) -> Run_Result {
	ctx := env.ctx
	tx := k.kernel_begin(env.kernel)
	defer k.transaction_destroy(&tx)
	created_metadata: [dynamic]k.Relation_Metadata
	defer delete(created_metadata)
	for item in ast.items {
		expression: ^c.Expr
		#partial switch matched in item {
		case c.Expr_Item:
			expression = matched.expr
		case:
			continue
		}

		if binding, is_binding := expression^.(c.Binding); is_binding {
			expression = binding.value
		}
		call, is_call := expression^.(c.Call)
		if !is_call {
			continue
		}
		callee, is_name := call.callee^.(c.Name)
		if !is_name {
			continue
		}
		declared := name_text(callee)

		switch declared {
		case "make_identity":
			if len(call.args) < 1 {
				continue
			}
			symbol_name := symbol_text(call.args[0].expr)
			if symbol_name == "" {
				continue
			}
			if _, exists := ctx.identities[symbol_name]; exists {
				continue
			}
			identity_value, identity_ok := v.value_identity_raw(declarations.next_identity)
			if identity_ok {
				ctx.identities[symbol_name] = identity_value
				declarations.next_identity += 1
				append(
					&declarations.named_identities,
					Named_Identity{identity = identity_value, name = v.symbol_intern(symbol_name)},
				)
			}

		case "make_relation", "make_functional_relation":
			args := make([]v.Value, len(call.args), context.temp_allocator)
			constant := true
			for arg, i in call.args {
				value, ok := relation_declaration_literal(arg.expr)
				if !ok {constant = false; break}
				args[i] = value
			}
			// Computed arguments execute in the entry task, after compilation.
			if !constant {continue}
			metadata, _, message := relation_constructor_metadata(args, declared == "make_functional_relation")
			if message != "" {return Run_Result{message = message}}
			metadata.id = k.Relation_ID(declarations.next_relation)
			actual, result := ensure_relation(env, &tx, metadata)
			if !result.ok {return result}
			if actual.id == metadata.id {declarations.next_relation += 1}
			append(&created_metadata, actual)
		}
	}
	committed, err := k.transaction_commit(&tx)
	if err != .None {return catalog_error(env, "Relation", err)}
	k.snapshot_release(committed)
	for metadata in created_metadata {
		name, _ := v.symbol_name(metadata.name)
		ctx.relations[name] = u32(metadata.id)
		if metadata.conflict.kind == .Functional {
			field := lower_first(name, context.temp_allocator)
			if _, exists := env.fields[field]; !exists {
				keys := make([]u16, len(metadata.conflict.key_positions), env.allocator)
				copy(keys, metadata.conflict.key_positions)
				env.fields[lower_first(name, env.allocator)] = Field_Info{relation = metadata.id, key_positions = keys}
			}
		}
	}

	return Run_Result{ok = true, message = "loaded"}
}

// Installs one file's rules into the kernel.
@(private)
install_rules :: proc(
	env: ^Builtin_Env,
	kernel: ^k.Kernel,
	ast: ^c.Program_AST,
	declarations: ^Declarations,
	path: string,
	source: string,
) -> Run_Result {
	facts: [dynamic]Rule_Fact
	defer delete(facts)
	for item in ast.items {
		rule_item, is_rule := item.(c.Rule_Item)
		if !is_rule {
			continue
		}
		rule_source := rule_item.source
		if rule_source == "" {
			rule_source = source
		}
		rule, rule_ok := convert_rule(rule_item, env.ctx)
		if !rule_ok {
			return Run_Result {
				ok = false,
				message = fmt.aprintf(
					"%s: could not lower a rule",
					path,
					allocator = env.allocator,
				),
			}
		}
		installed, install_err := k.kernel_install_rule(
			kernel,
			v.Identity(declarations.next_rule),
			rule,
			rule_source,
		)
		if install_err != k.Kernel_Error.None {
			return Run_Result {
				ok = false,
				message = fmt.aprintf(
					"%s: rule install failed: %v",
					path,
					install_err,
					allocator = env.allocator,
				),
			}
		}
		k.snapshot_release(installed)
		append(
			&facts,
			Rule_Fact {
				id = v.Identity(declarations.next_rule),
				head = rule.head_relation,
				source = rule_source,
				active = true,
			},
		)
		declarations.next_rule += 1
	}
	fact_result := assert_rule_facts(env, facts[:])
	if !fact_result.ok {
		return fact_result
	}
	return Run_Result{ok = true, message = "loaded"}
}

@(private)
builtin_env :: proc(state: ^vm.VM) -> ^Builtin_Env {
	return (^Builtin_Env)(state.user)
}

@(private)
builtin_make_identity :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	env := builtin_env(state)
	symbol, is_symbol := v.value_as_symbol(args[0])
	if !is_symbol {
		vm.vm_set_error(state, "E_TYPE", "make_identity expects a symbol")
		return v.Value(0), false
	}
	name, name_ok := v.symbol_name(symbol)
	if !name_ok {
		vm.vm_set_error(state, "E_IDENTITY", "unknown identity name")
		return v.Value(0), false
	}
	value, found := env.ctx.identities[name]
	if !found {
		vm.vm_set_error(state, "E_IDENTITY", "identity was not declared")
		return v.Value(0), false
	}
	return value, true
}

// Retracts every stored fact whose first column is the identity. This mirrors
// the Rust `destroy_identity` subject scan. The read-only catalogue relations
// are never touched.
@(private)
builtin_destroy_identity :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 1 {
		vm.vm_set_error(state, "E_INVARG", "destroy_identity expects destroy_identity(#identity)")
		return v.Value(0), false
	}
	if !k.authority_can_grant(state.authority) {
		vm.vm_set_error(state, "E_PERMISSION", "destroy_identity is not permitted")
		return v.Value(0), false
	}
	identity_value := args[0]
	if _, is_identity := v.value_as_identity(identity_value); !is_identity {
		vm.vm_set_error(state, "E_TYPE", "destroy_identity expects an identity")
		return v.Value(0), false
	}
	if state.transaction == nil {
		vm.vm_set_error(state, "E_INVARG", "destroy_identity requires a task transaction")
		return v.Value(0), false
	}

	env := builtin_env(state)
	snapshot := k.kernel_snapshot(env.kernel)
	defer k.snapshot_release(snapshot)
	source := k.Relation_Source {
		transaction = state.transaction,
	}
	count := i64(0)
	for metadata in snapshot.catalog {
		if metadata.arity == 0 || read_only_system_relation(metadata.id) {
			continue
		}
		bindings := make([]v.Binding, int(metadata.arity), context.temp_allocator)
		bindings[0] = v.binding_of(identity_value)
		rows: [dynamic]v.Tuple
		rows = make([dynamic]v.Tuple, 0, 8, context.temp_allocator)
		k.relation_source_scan_into(&source, metadata.id, bindings, &rows)
		for row in rows {
			if err := k.transaction_retract(state.transaction, metadata.id, row);
			   err != k.Kernel_Error.None {
				vm.vm_set_error(state, "E_KERNEL", "destroy_identity could not retract a fact")
				return v.Value(0), false
			}
			count += 1
		}
	}

	// The identity's name binding lives in NamedIdentity and is removed too,
	// so the reflection surface no longer reports the name.
	name_rows: [dynamic]v.Tuple
	name_rows = make([dynamic]v.Tuple, 0, 4, context.temp_allocator)
	k.relation_source_scan_into(
		&source,
		k.SYSTEM_NAMED_IDENTITY_ID,
		[]v.Binding{v.binding_of(identity_value), {}},
		&name_rows,
	)
	for row in name_rows {
		if err := k.transaction_retract(state.transaction, k.SYSTEM_NAMED_IDENTITY_ID, row);
		   err != k.Kernel_Error.None {
			vm.vm_set_error(state, "E_KERNEL", "destroy_identity could not retract a name")
			return v.Value(0), false
		}
		count += 1
	}
	result, _ := v.value_int(count)
	return result, true
}

// Relations owned by the catalogue and reflection surface. Retracting them
// directly is never allowed.
@(private)
read_only_system_relation :: proc(id: k.Relation_ID) -> bool {
	switch id {
	case k.SYSTEM_RELATION_ID,
	     k.SYSTEM_RELATION_NAME_ID,
	     k.SYSTEM_ARITY_ID,
	     k.SYSTEM_RELATION_DURABILITY_ID,
	     k.SYSTEM_RULE_ID,
	     k.SYSTEM_RULE_HEAD_ID,
	     k.SYSTEM_RULE_SOURCE_ID,
	     k.SYSTEM_ACTIVE_RULE_ID,
	     k.SYSTEM_ARGUMENT_NAME_ID,
	     k.SYSTEM_CONFLICT_POLICY_ID,
	     k.SYSTEM_FUNCTIONAL_KEY_ID,
	     k.SYSTEM_INDEX_ID,
	     k.SYSTEM_INDEX_POSITION_ID,
	     k.SYSTEM_INDEX_STORAGE_KIND_ID,
	     k.SYSTEM_SUBJECT_FACT_ID,
	     k.SYSTEM_MENTIONED_FACT_ID,
	     k.SYSTEM_EXTENSIONAL_MENTIONED_FACT_ID,
	     k.SYSTEM_NAMED_IDENTITY_ID,
	     k.SYSTEM_UNIT_SOURCE_ID:
		return true
	}
	return false
}

@(private)
builtin_frob :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	delegate, is_identity := v.value_as_identity(args[0])
	if !is_identity {
		vm.vm_set_error(state, "E_TYPE", "frob delegate must be an identity")
		return v.Value(0), false
	}
	env := builtin_env(state)
	return v.value_frob(env.allocator, delegate, args[1]), true
}

@(private)
builtin_noop :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	return v.value_empty_relation(), true
}

@(private)
builtin_require :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if !vm.vm_truthy(args[0]) {
		vm.vm_set_error(state, "E_REQUIRE", "required condition is not satisfied")
		return v.Value(0), false
	}
	return v.value_bool(true), true
}

@(private)
builtin_set_field :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if state.transaction == nil {
		vm.vm_set_error(state, "E_NO_TRANSACTION", "field write outside a transaction")
		return v.Value(0), false
	}

	symbol, is_symbol := v.value_as_symbol(args[1])
	if !is_symbol {
		vm.vm_set_error(state, "E_TYPE", "field name must be a symbol")
		return v.Value(0), false
	}
	name, name_ok := v.symbol_name(symbol)
	if !name_ok {
		vm.vm_set_error(state, "E_FIELD", "unknown field")
		return v.Value(0), false
	}
	// Field declarations register the lowercased last path segment
	// (`session/SteeringQueue` is stored as `session/steeringQueue`), so the
	// access does the same normalization.
	info, found := transaction_field(state, name)
	if !found || len(info.key_positions) == 0 {
		vm.vm_set_error(
			state,
			"E_FIELD",
			fmt.aprintf("unknown functional field: %s", name, allocator = context.temp_allocator),
		)
		return v.Value(0), false
	}
	// Field syntax is an ordinary relation write: enforce the same relation
	// authority the direct assert/retract path requires.
	if !k.authority_can_write(state.authority, info.relation) {
		vm.vm_set_error(state, "E_PERMISSION", "relation write denied")
		return v.Value(0), false
	}

	receiver := args[0]
	value := args[2]
	key_values := make([]v.Value, len(info.key_positions), context.temp_allocator)
	for position, index in info.key_positions {
		if position != 0 {
			vm.vm_set_error(state, "E_FIELD", "only a first-position key is supported")
			return v.Value(0), false
		}
		key_values[index] = receiver
	}

	existing, has_existing := k.transaction_tuple_for_key(
		state.transaction,
		info.relation,
		info.key_positions,
		key_values,
	)

	metadata, metadata_found := k.transaction_relation_metadata(state.transaction, info.relation)
	if !metadata_found || metadata.arity != 2 {
		vm.vm_set_error(state, "E_FIELD", "only binary functional relations are supported")
		return v.Value(0), false
	}

	new_tuple := v.tuple_new(context.temp_allocator, []v.Value{receiver, value})
	if has_existing {
		if v.tuple_eq(existing, new_tuple) {
			return value, true
		}
		if err := k.transaction_retract(state.transaction, info.relation, existing); err != .None {
			vm.vm_set_error(state, "E_FIELD", "could not replace the functional tuple")
			return v.Value(0), false
		}
	}
	if err := k.transaction_assert(state.transaction, info.relation, new_tuple); err != .None {
		vm.vm_set_error(state, "E_FIELD", "could not assert the functional tuple")
		return v.Value(0), false
	}
	return value, true
}

@(private)
builtin_get_field :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if state.transaction == nil {
		vm.vm_set_error(state, "E_NO_TRANSACTION", "field read outside a transaction")
		return v.Value(0), false
	}
	symbol, is_symbol := v.value_as_symbol(args[1])
	if !is_symbol {
		vm.vm_set_error(state, "E_TYPE", "field name must be a symbol")
		return v.Value(0), false
	}
	name, name_ok := v.symbol_name(symbol)
	if !name_ok {
		vm.vm_set_error(state, "E_FIELD", "unknown field")
		return v.Value(0), false
	}
	if error_value, is_error := v.value_as_error(args[0]); is_error {
		switch name {
		case "code":
			return v.value_error_code(error_value.code), true
		case "message":
			if error_value.has_message {
				return option_some_value(
						state.allocator,
						v.value_string(state.allocator, error_value.message),
					),
					true
			}
			return option_none_value(state.allocator), true
		case "value":
			if error_value.has_value {
				return option_some_value(state.allocator, error_value.value), true
			}
			return option_none_value(state.allocator), true
		}
	}
	info, found := transaction_field(state, name)
	if !found || len(info.key_positions) != 1 || info.key_positions[0] != 0 {
		vm.vm_set_error(
			state,
			"E_FIELD",
			fmt.aprintf("unknown functional field: %s", name, allocator = context.temp_allocator),
		)
		return v.Value(0), false
	}
	// Field syntax is an ordinary relation read: enforce the same relation
	// authority the direct scan path requires.
	if !k.authority_can_read(state.authority, info.relation) {
		vm.vm_set_error(state, "E_PERMISSION", "relation read denied")
		return v.Value(0), false
	}

	key_values := []v.Value{args[0]}
	existing, has_existing := k.transaction_tuple_for_key(
		state.transaction,
		info.relation,
		info.key_positions,
		key_values,
	)
	if !has_existing {
		vm.vm_set_error(state, "E_KEY", "no field value")
		return v.Value(0), false
	}
	return v.tuple_values(existing)[1], true
}

// --- Helpers ---------------------------------------------------------------

@(private)
symbol_text :: proc(expr: ^c.Expr) -> string {
	symbol, is_symbol := expr^.(c.Symbol_Literal)
	if !is_symbol {
		return ""
	}
	if strings.has_prefix(symbol.name, "\"") && len(symbol.name) >= 2 {
		return symbol.name[1:len(symbol.name) - 1]
	}
	return symbol.name
}

@(private)
lower_first :: proc(name: string, allocator: mem.Allocator) -> string {
	if len(name) == 0 {
		return name
	}
	start := 0
	if slash := strings.last_index_byte(name, '/'); slash >= 0 {
		start = slash + 1
	}
	if start >= len(name) {
		return name
	}
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	strings.write_string(&builder, name[:start])
	first := name[start]
	if first >= 'A' && first <= 'Z' {
		first += 'a' - 'A'
	}
	strings.write_byte(&builder, first)
	strings.write_string(&builder, name[start + 1:])
	return strings.to_string(builder)
}

@(private)
format_error :: proc(error_value: v.Value, allocator: mem.Allocator) -> string {
	if error, is_error := v.value_as_error(error_value); is_error {
		code_name := "E_UNKNOWN"
		if name, name_ok := v.symbol_name(error.code); name_ok {
			code_name = name
		}
		if error.has_message {
			return fmt.aprintf("%s: %s", code_name, error.message, allocator = allocator)
		}
		return strings.clone(code_name, allocator)
	}
	return v.value_to_string(error_value, allocator)
}
