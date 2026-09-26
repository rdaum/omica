// Programs are addressed by durable artifact identity. Function values use a
// process-unique program serial, so the same local callable index cannot alias
// another program (or a program loaded by another world).
package vm

import k "../kernel"
import v "../var"
import "core:mem"
import "core:mem/virtual"
import "core:sync"

Program_Registry :: struct {
	lock:                sync.Mutex,
	artifacts:           map[v.Value]^Program,
	serials:             map[u64]^Program,
	allocator:           mem.Allocator,
	unused_serials:      [dynamic]u64,
	catalogue_version:   u64,
	installed_artifacts: map[v.Value]bool,
}

@(private)
program_serial: u64

program_registry_init :: proc(registry: ^Program_Registry, allocator: mem.Allocator) {
	registry.allocator = allocator
	registry.artifacts = make(map[v.Value]^Program, allocator)
	registry.serials = make(map[u64]^Program, allocator)
	registry.installed_artifacts = make(map[v.Value]bool, allocator)
}

// The returned program carries one caller reference. Registration consumes
// `program`, including when an identical artifact is already cached.
program_registry_add :: proc(
	registry: ^Program_Registry,
	program: ^Program,
	artifact: v.Value,
	allocator: mem.Allocator,
	installed := false,
) -> ^Program {
	sync.mutex_lock(&registry.lock)
	defer sync.mutex_unlock(&registry.lock)
	if artifact != v.Value(0) {
		if existing, found := registry.artifacts[artifact]; found {
			existing.references += 1
			existing.installed =
				existing.installed || installed || registry.installed_artifacts[artifact]
			program_destroy(program, allocator)
			return existing
		}
	}
	serial: u64
	if len(registry.unused_serials) >
	   0 {serial = pop(&registry.unused_serials)} else {serial = sync.atomic_add(&program_serial, 1) + 1}
	if serial >= 1 << 24 {panic("program serial space exhausted")}
	program.serial = serial
	program.registry = registry
	program.storage_allocator = allocator
	program.artifact = artifact
	program.references = 1
	program.installed = installed || registry.installed_artifacts[artifact]
	registry.serials[serial] = program
	if artifact != v.Value(0) {registry.artifacts[artifact] = program}
	return program
}

program_retain :: proc(program: ^Program) {
	if program.registry == nil {return}
	sync.mutex_lock(&program.registry.lock)
	program.references += 1
	sync.mutex_unlock(&program.registry.lock)
}

program_release :: proc(program: ^Program) {
	registry := program.registry
	if registry == nil {return}
	sync.mutex_lock(&registry.lock)
	defer sync.mutex_unlock(&registry.lock)
	program.references -= 1
	registry_reclaim(registry, program)
}

@(private)
registry_reclaim :: proc(registry: ^Program_Registry, program: ^Program) {
	// Function values are immediate handles with world lifetime. An interned
	// callable is a registry root; it can be held by a host or a mailbox even
	// after its producing task has been released.
	if program.references != 0 ||
	   program.installed ||
	   sync.atomic_load(&program.has_callable) {return}
	delete_key(&registry.serials, program.serial)
	// No function handle was created for this serial, so it can be reused.
	append(&registry.unused_serials, program.serial)
	if program.artifact != v.Value(0) {delete_key(&registry.artifacts, program.artifact)}
	program_destroy(program, program.storage_allocator)
}

program_registry_destroy :: proc(registry: ^Program_Registry) {
	for _, program in registry.serials {program_destroy(program, program.storage_allocator)}
	delete(registry.installed_artifacts)
	delete(registry.unused_serials)
	delete(registry.serials)
	delete(registry.artifacts)
}

// Call after source publication. Old task snapshots can reload an evicted
// artifact from their ProgramBytes facts; running frames retain their image.
program_registry_refresh :: proc(registry: ^Program_Registry, source: ^k.Relation_Source) {
	rows: [dynamic]v.Tuple
	defer delete(rows)
	k.relation_source_scan_into(source, k.DISPATCH_METHOD_PROGRAM_ID, []v.Binding{{}, {}}, &rows)
	live := make(map[v.Value]bool)
	defer delete(live)
	for row in rows {
		if reference, ok := v.value_as_list(v.tuple_values(row)[1]);
		   ok && len(reference) == 2 {live[reference[0]] = true}
	}
	sync.mutex_lock(&registry.lock)
	defer sync.mutex_unlock(&registry.lock)
	if source.snapshot.version < registry.catalogue_version {return}
	registry.catalogue_version = source.snapshot.version
	clear(&registry.installed_artifacts)
	for artifact, present in live {registry.installed_artifacts[artifact] = present}
	retired: [dynamic]^Program
	defer delete(retired)
	for _, program in registry.serials {
		program.installed = live[program.artifact]
		if !program.installed {append(&retired, program)}
	}
	for program in retired {registry_reclaim(registry, program)}
}

// Acquire from the cache, or decode from this transaction's artifact view.
program_registry_resolve :: proc(
	registry: ^Program_Registry,
	source: ^k.Relation_Source,
	artifact: v.Value,
) -> ^Program {
	sync.mutex_lock(&registry.lock)
	if program, found := registry.artifacts[artifact]; found {
		program.references += 1
		sync.mutex_unlock(&registry.lock)
		return program
	}
	sync.mutex_unlock(&registry.lock)
	if source == nil {return nil}
	rows: [dynamic]v.Tuple
	defer delete(rows)
	artifact_source := source^
	artifact_source.authority = nil
	k.relation_source_scan_into(
		&artifact_source,
		k.SYSTEM_PROGRAM_BYTES_ID,
		[]v.Binding{v.binding_of(artifact), {}},
		&rows,
	)
	if len(rows) != 1 {return nil}
	bytes, ok := v.value_as_bytes(v.tuple_values(rows[0])[1])
	if !ok {return nil}
	arena := new(virtual.Arena, registry.allocator)
	if virtual.arena_init_growing(arena) != nil {free(arena, registry.allocator); return nil}
	alloc := virtual.arena_allocator(arena)
	program, err := program_from_bytes(bytes, alloc)
	if err != .None || program_validate(program) != .None {
		virtual.arena_destroy(arena)
		free(arena, registry.allocator)
		return nil
	}
	program.storage_arena = arena
	program.arena_allocator = registry.allocator
	return program_registry_add(registry, program, artifact, alloc)
}

// Legacy MethodProgram integers belong to the bootstrap image. New rows use
// [artifact identity, function index]. The returned pointer is retained.
program_resolve_reference :: proc(
	registry: ^Program_Registry,
	source: ^k.Relation_Source,
	fallback: ^Program,
	value: v.Value,
) -> (
	^Program,
	i32,
	bool,
) {
	if index, ok := v.value_as_int(value); ok {
		if index < 0 || index >= i64(len(fallback.functions)) {return nil, 0, false}
		program_retain(fallback)
		return fallback, i32(index), true
	}
	reference, ok := v.value_as_list(value)
	if !ok || len(reference) != 2 || registry == nil {return nil, 0, false}
	index, valid := v.value_as_int(reference[1])
	if !valid || index < 0 || index > i64(max(i32)) {return nil, 0, false}
	program := program_registry_resolve(registry, source, reference[0])
	if program == nil {return nil, 0, false}
	if index >= i64(len(program.functions)) {program_release(program); return nil, 0, false}
	return program, i32(index), true
}

vm_pin_program :: proc(state: ^VM, program: ^Program) {
	for existing in state.program_pins {if existing == program {return}}
	program_retain(program)
	append(&state.program_pins, program)
}

@(private)
vm_select_program :: proc(state: ^VM, program: ^Program) {
	if program == state.program {return}
	vm_pin_program(state, program)
	state.program = program
	vm_resolve_builtins(state)
}

@(private)
vm_callable_value :: proc(program: ^Program, index: u64) -> (v.Value, bool) {
	if index > u64(max(u32)) {return {}, false}
	sync.atomic_store(&program.has_callable, true)
	return v.value_function_raw((program.serial << 32) | index)
}
