// Compilation uses a private context built from the caller's transaction.
package mica_runtime

import c "../compiler"
import k "../kernel"
import v "../var"
import vm "../vm"
import "core:mem"
import "core:mem/virtual"
import "core:strings"

@(private)
runtime_compile_context :: proc(
	world: ^World,
	tx: ^k.Transaction,
	allocator: mem.Allocator,
) -> c.Compile_Context {
	ctx := world.ctx
	ctx.identities = make(map[string]v.Value, allocator)
	ctx.relations = make(map[string]u32, allocator)
	install_primitive_identities(&ctx)
	for metadata in tx.base.catalog {
		if metadata.tombstoned || metadata.storage != .Tuple {continue}
		name, ok := v.symbol_name(metadata.name)
		if ok {ctx.relations[name] = u32(metadata.id)}
	}
	for change in tx.catalog_changes {
		name, _ := v.symbol_name(change.metadata.name)
		if change.kind ==
		   .Create {ctx.relations[name] = u32(change.metadata.id)} else {delete_key(&ctx.relations, name)}
	}
	source := k.Relation_Source {
		transaction = tx,
	}
	names: [dynamic]v.Tuple
	defer delete(names)
	k.relation_source_scan_into(&source, k.SYSTEM_NAMED_IDENTITY_ID, []v.Binding{{}, {}}, &names)
	for row in names {
		values := v.tuple_values(row)
		if symbol, ok := v.value_as_symbol(values[1]); ok {
			if name, valid := v.symbol_name(symbol); valid {ctx.identities[name] = values[0]}
		}
	}
	return ctx
}

@(private)
runtime_compile :: proc(
	world: ^World,
	tx: ^k.Transaction,
	source: string,
	definitions: bool,
) -> (
	^vm.Program,
	string,
) {
	arena := new(virtual.Arena, world.allocator)
	if virtual.arena_init_growing(arena) !=
	   nil {free(arena, world.allocator); return nil, "cannot allocate compiler arena"}
	alloc := virtual.arena_allocator(arena)
	keep := false
	defer {if !keep {virtual.arena_destroy(arena); free(arena, world.allocator)}}
	ast, errors := c.parse_program(source, alloc)
	if len(errors) > 0 {return nil, strings.clone(errors[0].message, world.allocator)}
	if !definitions {
		for item in ast.items {
			if _, expression := item.(c.Expr_Item);
			   !expression {return nil, "definitions require administrative installation"}
		}
	}
	ctx := runtime_compile_context(world, tx, alloc)
	compiled := c.compile_program(ast, &ctx, alloc)
	if len(compiled.errors) >
	   0 {return nil, strings.clone(compiled.errors[0].message, world.allocator)}
	compiled.program.storage_arena = arena
	compiled.program.arena_allocator = world.allocator
	keep = true
	return vm.program_registry_add(&world.programs, compiled.program, {}, alloc), ""
}

@(private)
builtin_compile :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 1 {return builtin_error(state, "E_INVARG", "compile expects source text")}
	source, ok := v.value_as_string(args[0])
	if !ok {return builtin_error(state, "E_TYPE", "compile expects source text")}
	env := builtin_env(state)
	if env.world == nil ||
	   state.transaction ==
		   nil {return builtin_error(state, "E_NO_TRANSACTION", "compile requires a live world")}
	program, message := runtime_compile(
		env.world,
		state.transaction,
		source,
		k.authority_can_grant(state.authority),
	)
	if program == nil {return builtin_error(state, "E_COMPILE", message)}
	defer vm.program_release(program)
	bytes: [dynamic]u8
	defer delete(bytes)
	if vm.program_to_bytes(program, &bytes) !=
	   .None {return builtin_error(state, "E_COMPILE", "cannot encode program")}
	return v.value_bytes(state.allocator, bytes[:]), true
}

// Install definitions, without executing arbitrary top-level expressions.
// Successful staging joins the caller's commit/abort boundary.
@(private)
builtin_install_source :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) !=
	   1 {return builtin_error(state, "E_INVARG", "install_source expects source text")}
	text, is_text := v.value_as_string(args[0])
	if !is_text {return builtin_error(state, "E_TYPE", "install_source expects source text")}
	// Check before parsing, reserving IDs, or touching the catalogue.
	if !k.authority_can_grant(
		state.authority,
	) {return builtin_error(state, "E_PERMISSION", "source installation requires administrative authority")}
	if state.transaction ==
	   nil {return builtin_error(state, "E_NO_TRANSACTION", "source installation requires a transaction")}
	if state.transaction.read_only {return builtin_error(state, "E_PERMISSION", "source installation requires a writable transaction")}
	env := builtin_env(state)
	if env.world ==
	   nil {return builtin_error(state, "E_INVARG", "source installation requires a live world")}
	child := k.transaction_fork_staging(state.transaction)
	child.source_install = true
	if err := stage_legacy_program_references(env.world, &child); err != .None {
		k.transaction_destroy(&child)
		return builtin_error(state, "E_COMPILE", "cannot upgrade method references")
	}
	defer k.transaction_destroy(&child)
	arena := new(virtual.Arena, env.world.allocator)
	if virtual.arena_init_growing(arena) !=
	   nil {free(arena, env.world.allocator); return builtin_error(state, "E_COMPILE", "cannot allocate compiler arena")}
	alloc := virtual.arena_allocator(arena)
	keep := false
	defer {if !keep {virtual.arena_destroy(arena); free(arena, env.world.allocator)}}
	ast, errors := c.parse_program(text, alloc)
	if len(errors) > 0 {return builtin_error(state, "E_COMPILE", errors[0].message)}
	for item in ast.items {
		#partial switch node in item {
		case c.Expr_Item:
			expr := node.expr
			if binding, ok := expr^.(c.Binding); ok {expr = binding.value}
			call, ok := expr^.(c.Call)
			if !ok {return builtin_error(state, "E_COMPILE", "installation accepts definitions and literal declarations only")}
			name, named := call.callee^.(c.Name)
			if !named ||
			   (name_text(name) != "make_identity" &&
					   name_text(name) != "make_relation" &&
					   name_text(name) != "make_functional_relation") {
				return builtin_error(
					state,
					"E_COMPILE",
					"installation accepts definitions and literal declarations only",
				)
			}
			for arg in call.args {
				if _, constant := relation_declaration_literal(arg.expr);
				   !constant {return builtin_error(state, "E_COMPILE", "installation declarations require literal arguments")}
			}
		case c.Grant_Item:
			return builtin_error(state, "E_COMPILE", "install grants in the caller transaction")
		}
	}
	ctx := runtime_compile_context(env.world, &child, alloc)
	local_env := env^
	local_env.ctx = &ctx
	local_env.allocator = alloc
	declarations: Declarations
	metadata: [dynamic]k.Relation_Metadata
	defer delete(metadata)
	if result := stage_declarations(&local_env, ast, &child, &declarations, &metadata);
	   !result.ok {return builtin_error(state, "E_COMPILE", result.message)}
	compiled := c.compile_program(ast, &ctx, alloc)
	if len(compiled.errors) >
	   0 {return builtin_error(state, "E_COMPILE", compiled.errors[0].message)}
	bytes: [dynamic]u8
	defer delete(bytes)
	if vm.program_to_bytes(compiled.program, &bytes) !=
	   .None {return builtin_error(state, "E_COMPILE", "cannot encode installed program")}
	artifact, _ := vm.program_artifact_id(bytes[:])
	if err := k.transaction_assert(
		&child,
		k.SYSTEM_PROGRAM_BYTES_ID,
		v.tuple_new(
			context.temp_allocator,
			[]v.Value{artifact, v.value_bytes(context.temp_allocator, bytes[:])},
		),
	); err != .None {
		return builtin_error(state, "E_COMPILE", "cannot stage program artifact")
	}
	if result := stage_methods(
		&local_env,
		&child,
		[]^c.Program_AST{ast},
		[]string{text},
		artifact,
		true,
	); !result.ok {return builtin_error(state, "E_COMPILE", result.message)}
	for item in ast.items {
		if node, is_rule := item.(c.Rule_Item); is_rule {
			rule, ok := convert_rule(node, &ctx)
			if !ok {return builtin_error(state, "E_COMPILE", "cannot lower installed rule")}
			value, reserved := k.kernel_reserve_identity(env.kernel)
			if !reserved {return builtin_error(state, "E_COMPILE", "rule identity space exhausted")}
			identity, _ := v.value_as_identity(value)
			if err := k.transaction_install_rule(&child, identity, rule, node.source);
			   err != .None {return builtin_error(state, "E_COMPILE", "invalid installed rule")}
			result := stage_rule_facts(
				&local_env,
				&child,
				[]Rule_Fact {
					{
						id = identity,
						head = rule.head_relation,
						source = node.source,
						active = true,
					},
				},
			)
			if !result.ok {return builtin_error(state, "E_COMPILE", result.message)}
		}
	}
	// Keep the decoded image ready for same-transaction dispatch. A failed
	// outer task drops this cache root; ProgramBytes follows normal rollback.
	compiled.program.storage_arena = arena
	compiled.program.arena_allocator = env.world.allocator
	keep = true
	program := vm.program_registry_add(&env.world.programs, compiled.program, artifact, alloc)
	vm.vm_pin_program(state, program)
	vm.program_release(program)
	k.transaction_accept_staging(state.transaction, &child)
	if task := task_from_state(state); task != nil {task.programs_changed = true}
	return artifact, true
}

// Trusted host replacement used by compiler conformance/bootstrapping tools.
// Consumes program on success. Existing tasks retain their original image.
world_replace_program :: proc(
	world: ^World,
	program: ^vm.Program,
	allocator := context.allocator,
) -> Run_Result {
	if vm.program_validate(program) !=
	   .None {return Run_Result{message = "invalid replacement program"}}
	bytes: [dynamic]u8
	defer delete(bytes)
	if vm.program_to_bytes(program, &bytes) !=
	   .None {return Run_Result{message = "cannot encode replacement program"}}
	artifact, _ := vm.program_artifact_id(bytes[:])
	tx := k.kernel_begin(world.kernel)
	defer k.transaction_destroy(&tx)
	tx.source_install = true
	source := k.Relation_Source {
		transaction = &tx,
	}
	rows: [dynamic]v.Tuple
	defer delete(rows)
	k.relation_source_scan_into(&source, k.DISPATCH_METHOD_PROGRAM_ID, []v.Binding{{}, {}}, &rows)
	for row in rows {
		cells := v.tuple_values(row)
		index, legacy := v.value_as_int(cells[1])
		if !legacy {
			reference, ok := v.value_as_list(cells[1])
			if !ok || len(reference) != 2 || reference[0] != world.program.artifact {continue}
			index, _ = v.value_as_int(reference[1])
		}
		if index < 0 ||
		   index >=
			   i64(
				   len(program.functions),
			   ) {return Run_Result{message = "replacement has incompatible function indices"}}
		if index >= i64(len(world.program.functions)) ||
		   program.functions[index].name != world.program.functions[index].name {
			return Run_Result{message = "replacement has incompatible function names"}
		}
		if k.transaction_retract(&tx, k.DISPATCH_METHOD_PROGRAM_ID, row) !=
		   .None {return Run_Result{message = "cannot retract old program reference"}}
		replacement := v.value_list(
			context.temp_allocator,
			[]v.Value{artifact, value_int_must(index)},
		)
		if k.transaction_assert(
			   &tx,
			   k.DISPATCH_METHOD_PROGRAM_ID,
			   v.tuple_new(context.temp_allocator, []v.Value{cells[0], replacement}),
		   ) !=
		   .None {return Run_Result{message = "cannot stage replacement reference"}}
	}
	if k.transaction_assert(
		   &tx,
		   k.SYSTEM_PROGRAM_BYTES_ID,
		   v.tuple_new(
			   context.temp_allocator,
			   []v.Value{artifact, v.value_bytes(context.temp_allocator, bytes[:])},
		   ),
	   ) !=
	   .None {return Run_Result{message = "cannot stage replacement artifact"}}
	committed, err := k.transaction_commit(&tx)
	if err != .None {return Run_Result{message = "replacement commit conflicted"}}
	k.snapshot_release(committed)
	old := world.program
	world.program = vm.program_registry_add(&world.programs, program, artifact, allocator, true)
	vm.program_release(old)
	snapshot := k.kernel_snapshot(world.kernel)
	source = k.Relation_Source {
		snapshot = snapshot,
	}
	vm.program_registry_refresh(&world.programs, &source)
	k.snapshot_release(snapshot)
	return Run_Result{ok = true}
}

@(private)
stage_legacy_program_references :: proc(world: ^World, tx: ^k.Transaction) -> k.Kernel_Error {
	source := k.Relation_Source {
		transaction = tx,
	}
	rows: [dynamic]v.Tuple
	defer delete(rows)
	k.relation_source_scan_into(&source, k.DISPATCH_METHOD_PROGRAM_ID, []v.Binding{{}, {}}, &rows)
	for row in rows {
		cells := v.tuple_values(row)
		if _, legacy := v.value_as_int(cells[1]); legacy {
			if err := k.transaction_retract(tx, k.DISPATCH_METHOD_PROGRAM_ID, row);
			   err != .None {return err}
			reference := v.value_list(
				context.temp_allocator,
				[]v.Value{world.program.artifact, cells[1]},
			)
			if err := k.transaction_assert(
				tx,
				k.DISPATCH_METHOD_PROGRAM_ID,
				v.tuple_new(context.temp_allocator, []v.Value{cells[0], reference}),
			); err != .None {return err}
		}
	}
	return .None
}

@(private)
world_upgrade_program_references :: proc(world: ^World) -> Run_Result {
	tx := k.kernel_begin(world.kernel)
	defer k.transaction_destroy(&tx)
	if stage_legacy_program_references(world, &tx) !=
	   .None {return Run_Result{message = "cannot upgrade stored method references"}}
	snapshot, err := k.transaction_commit(&tx)
	if err != .None {return Run_Result{message = "cannot commit stored method references"}}
	k.snapshot_release(snapshot)
	source := k.Relation_Source {
		snapshot = tx.base,
	}
	// Refresh from the committed catalogue, rather than the pre-upgrade view.
	current := k.kernel_snapshot(world.kernel)
	defer k.snapshot_release(current)
	source.snapshot = current
	vm.program_registry_refresh(&world.programs, &source)
	return Run_Result{ok = true}
}
