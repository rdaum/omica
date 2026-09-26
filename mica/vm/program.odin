// Bytecode program format for the Mica virtual machine.
//
// A program is a flat array of fixed-size instructions, a constant pool, and a
// function table. Instructions use register operands and are designed for a
// simple switch dispatch in the execution loop. The format is deliberately
// compact and easy to validate, disassemble, and later serialise.
//
// This is an Odin-first design; it does not mirror the Rust opcode set.
package vm

import v "../var"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:sync"

Op :: enum u8 {
	// Load_Const: a = dst register, b = constant index.
	Load_Const,
	// Move: a = dst, b = src.
	Move,
	// Binary: a = dst, b = lhs, c = rhs; flags hold a Bin_Op.
	Binary,
	// Unary: a = dst, b = src; flags hold an Un_Op.
	Unary,
	// Branch: a = condition register, b = relative offset.
	Branch,
	// Jump: b = relative offset.
	Jump,
	// Call: a = dst, b = function index, c = first argument register.
	Call,
	// Return: a = source register.
	Return,
	// Build_List: a = dst, b = first element register, c = element count.
	Build_List,
	// Build_Map: a = dst, b = first entry register, c = entry count. Each
	// entry occupies two consecutive registers, key then value.
	Build_Map,
	// Build_Range: a = dst, b = start register, c = end register. flags bit 0
	// marks a bound end.
	Build_Range,
	// Len: a = dst, b = collection register.
	Len,
	// Scan_Collect: a = dst, b = pattern index. Binds nothing; the result is
	// a relation value with one row per match.
	Scan_Collect,
	// Scan_Exists: a = dst (bool), b = pattern index.
	Scan_Exists,
	// Scan_First: a = dst (bool), b = pattern index. Writes bind cells from
	// the first match; returns false when there is no match.
	Scan_First,
	// Assert: a = relation id, b = register holding a single-row relation
	// value.
	Assert,
	// Retract: a = relation id, b = register holding a single-row relation
	// value.
	Retract,
	// Retract_Where: b = pattern index. Retracts every matching row.
	Retract_Where,
	// Build_Relation: a = dst, b = relation shape index, c = first cell
	// register. Builds a single-row relation value.
	Build_Relation,
	// Index: a = dst, b = collection register, c = key register.
	Index,
	// Collection_Key_At: a = dst, b = collection register, c = ordinal index
	// register. Yields the map key at that position, or the ordinal itself for
	// lists and relations.
	Collection_Key_At,
	// Collection_Value_At: a = dst, b = collection register, c = ordinal index
	// register.
	Collection_Value_At,
	// Builtin_Call: a = dst, b = builtin index, c = first argument register.
	Builtin_Call,
	// Commit: requests a transaction commit from the host.
	Commit,
	// Is_Truthy: a = dst (bool), b = source.
	Is_Truthy,
	// Scan_One: a = dst (bool), b = pattern index. Fails unless exactly one
	// row matches, then writes output cells.
	Scan_One,
	// Dispatch: a = dst, b = dispatch spec index. Resolves a method from the
	// selector and role arguments, then calls its program.
	Dispatch,
	// Yield: suspends the task and makes it runnable again. a = destination
	// register for the resume value.
	Yield,
	// Sleep: a = destination register for the resume value, b = register
	// holding an integer number of milliseconds.
	Sleep,
	// Spawn: a = destination register for the child task id, b = dispatch spec
	// index, c = delay register (-1 when absent). flags bit 0 marks a delay.
	Spawn,
	// Raise: a = error code register, b = message register (-1 when absent),
	// c = value register (-1 when absent). Aborts the VM with an error value.
	Raise,
	// Dynamic_Dispatch: a = dst, b = selector register, c = roles map register.
	// Resolves a method from a runtime selector symbol and role map.
	Dynamic_Dispatch,
	// Positional_Dispatch: a = dst, b = selector register, c = first argument
	// register. flags holds the argument count (the receiver is first).
	Positional_Dispatch,
	// Mailbox_Recv: a = dst, b = receivers list register, c = timeout register
	// (when flags bit 0 is set). Suspends until a message is ready.
	Mailbox_Recv,
	// External_Request: a = dst, b = service symbol register, c = payload
	// register. Suspends until the host resolves the request.
	External_Request,
	// Read: a = destination register for the input value, b = metadata
	// register (-1 when absent). Suspends until the host supplies input.
	Read,
	// Push_Handler: a = absolute catch target offset, b = register that
	// receives the raised error (-1 when the handler takes no value).
	Push_Handler,
	// Push_Finally: a = absolute finally target offset. A `return` inside the
	// protected region diverts through the finally before returning.
	Push_Finally,
	// Pop_Handler: removes the innermost handler.
	Pop_Handler,
	// Resume_Return: completes a diverted return once its finally has run, or
	// continues when no return is pending.
	Resume_Return,
	// Make_Function: a = dst, b = function index. Wraps a program function as
	// a first-class function value.
	Make_Function,
	// Make_Self_Function: like Make_Function, but the last capture slot is
	// overwritten with the new function value so it can call itself.
	Make_Self_Function,
	// Call_Value: a = dst, b = function value register, c = first argument
	// register. flags holds the argument count.
	Call_Value,
	// Call_Splice: a = dst, b = function index, c = argument list register.
	Call_Splice,
	// Builtin_Call_Splice: a = dst, b = builtin index, c = argument list.
	Builtin_Call_Splice,
	// Call_Value_Splice: a = dst, b = function value register, c = argument
	// list register.
	Call_Value_Splice,
}

// A cell in a relation scan pattern.
Pattern_Cell_Kind :: enum u8 {
	// A constant constant-pool value.
	Const,
	// A register holding a join input value.
	Bind,
	// A register that receives the matched cell value.
	Output,
	// Any value.
	Wildcard,
}

Pattern_Cell :: struct {
	kind:    Pattern_Cell_Kind,
	operand: i32,
}

// A relation scan pattern. Column names head the relation value produced by
// Scan_Collect.
//
// `relation` is the resolved kernel id. When it is zero the scan resolves
// `relation_name` against the live snapshot instead: user relations start at
// id 1 and system relations at 0x7fff_fe00, so zero is never a valid id.
// Name resolution lets an assembled artifact stay valid across worlds whose
// relation ids differ.
Scan_Pattern :: struct {
	relation:      u32,
	relation_name: v.Symbol,
	column_names:  []v.Symbol,
	cells:         []Pattern_Cell,
}

// The heading of a relation value built at runtime.
Relation_Shape :: struct {
	heading: []v.Symbol,
}

// A role binding at a dispatch site. `register` is relative to the function
// frame.
Dispatch_Role :: struct {
	role:     v.Symbol,
	register: i32,
}

// A dispatch site: a selector symbol plus its role arguments.
Dispatch_Spec :: struct {
	selector: v.Symbol,
	roles:    []Dispatch_Role,
}

Bin_Op :: enum u8 {
	Add,
	Sub,
	Mul,
	Div,
	Rem,
	Eq,
	Ne,
	Lt,
	Le,
	Gt,
	Ge,
}

Un_Op :: enum u8 {
	Neg,
	Not,
}

Instruction :: struct {
	op:    Op,
	flags: u8,
	a:     i32,
	b:     i32,
	c:     i32,
}

Function :: struct {
	name:           v.Symbol,
	code_offset:    int,
	code_len:       int,
	register_count: int,
	param_count:    int,
	// Parameters before `required_count` must be supplied by the caller.
	// Optional parameters fall back to their constant default (or an empty
	// relation); a rest parameter collects trailing arguments into a list.
	required_count: u16,
	has_rest:       bool,
	defaults:       []i32,
}

// An interned callable: a program function plus the values captured when its
// fn literal was evaluated. Callables live on the program so function values
// remain valid across tasks that share the program.
Callable_Info :: struct {
	function: i32,
	captures: []v.Value,
}

Program :: struct {
	registry:                          ^Program_Registry,
	serial:                            u64,
	artifact:                          v.Value,
	references:                        int,
	installed:                         bool,
	has_callable:                      bool,
	storage_allocator:                 mem.Allocator,
	storage_arena:                     ^virtual.Arena,
	arena_allocator:                   mem.Allocator,
	callables_mutex: sync.Mutex,
	callables:       [dynamic]Callable_Info,
	code:      []Instruction,
	constants: []v.Value,
	functions: []Function,
	patterns:        []Scan_Pattern,
	relation_shapes: []Relation_Shape,
	dispatch_specs:  []Dispatch_Spec,
	builtins:        []v.Symbol,
	entry:           int,
	// Kernel relation ids used to resolve dispatch. Zero disables dispatch.
	dispatch_method_selector_relation: u32,
	dispatch_param_relation:           u32,
	dispatch_delegates_relation:       u32,
	dispatch_method_program_relation:  u32,
}

Program_Error :: enum {
	None,
	No_Entry,
	Bad_Register,
	Bad_Constant,
	Bad_Jump,
	Bad_Function,
	Bad_Arguments,
}

// --- Builder ---------------------------------------------------------------

Builder :: struct {
	// Allocator that owns every slice reachable from the builder. Stored so
	// that `builder_destroy` frees through the same allocator the compiler
	// used to allocate (notably `Function.defaults`).
	allocator:     mem.Allocator,
	code:          [dynamic]Instruction,
	constants:     [dynamic]v.Value,
	functions:     [dynamic]Function,
	patterns:        [dynamic]Scan_Pattern,
	relation_shapes: [dynamic]Relation_Shape,
	dispatch_specs:  [dynamic]Dispatch_Spec,
	builtins:        [dynamic]v.Symbol,
	entry:           int,
	open_function:   int,
	open_offset:     int,
	dispatch_method_selector_relation: u32,
	dispatch_param_relation:           u32,
	dispatch_delegates_relation:       u32,
	dispatch_method_program_relation:  u32,
}

builder_init :: proc(builder: ^Builder, allocator := context.allocator) {
	builder.allocator = allocator
	builder.code = make([dynamic]Instruction, allocator)
	builder.constants = make([dynamic]v.Value, allocator)
	builder.functions = make([dynamic]Function, allocator)
	builder.patterns = make([dynamic]Scan_Pattern, allocator)
	builder.relation_shapes = make([dynamic]Relation_Shape, allocator)
	builder.dispatch_specs = make([dynamic]Dispatch_Spec, allocator)
	builder.builtins = make([dynamic]v.Symbol, allocator)
	builder.entry = -1
	builder.open_function = -1
}

builder_destroy :: proc(builder: ^Builder) {
	// Dynamic arrays remember the allocator they were made with; plain slices
	// do not, so they are freed with `builder.allocator` explicitly.
	delete(builder.code)
	delete(builder.constants)
	for function in builder.functions {
		if function.defaults != nil {
			delete(function.defaults, builder.allocator)
		}
	}
	delete(builder.functions)
	for pattern in builder.patterns {
		delete(pattern.column_names, builder.allocator)
		delete(pattern.cells, builder.allocator)
	}
	delete(builder.patterns)
	for shape in builder.relation_shapes {
		delete(shape.heading, builder.allocator)
	}
	delete(builder.relation_shapes)
	for spec in builder.dispatch_specs {
		delete(spec.roles, builder.allocator)
	}
	delete(builder.dispatch_specs)
	delete(builder.builtins)
}

// Adds a relation value heading, copying it. Returns the shape index.
builder_add_relation_shape :: proc(builder: ^Builder, heading: []v.Symbol) -> i32 {
	names := make([]v.Symbol, len(heading), builder.allocator)
	copy(names, heading)
	append(&builder.relation_shapes, Relation_Shape{heading = names})
	return i32(len(builder.relation_shapes) - 1)
}

// Adds a builtin reference by name. Returns the builtin index.
builder_add_builtin :: proc(builder: ^Builder, name: v.Symbol) -> i32 {
	append(&builder.builtins, name)
	return i32(len(builder.builtins) - 1)
}

// Adds a scan pattern, copying its slices. Returns the pattern index. Pass a
// zero `relation` with a `relation_name` to defer resolution to scan time.
builder_add_pattern :: proc(
	builder: ^Builder,
	relation: u32,
	relation_name: v.Symbol,
	column_names: []v.Symbol,
	cells: []Pattern_Cell,
) -> i32 {
	names := make([]v.Symbol, len(column_names), builder.allocator)
	copy(names, column_names)
	pattern_cells := make([]Pattern_Cell, len(cells), builder.allocator)
	copy(pattern_cells, cells)
	append(&builder.patterns, Scan_Pattern {
		relation      = relation,
		relation_name = relation_name,
		column_names  = names,
		cells         = pattern_cells,
	})
	return i32(len(builder.patterns) - 1)
}

// Adds a name-resolved scan pattern: the relation name is interned and the
// id left zero, so the scan resolves it against the live snapshot.
builder_add_named_pattern :: proc(
	builder: ^Builder,
	relation_name: string,
	column_names: []v.Symbol,
	cells: []Pattern_Cell,
) -> i32 {
	return builder_add_pattern(
		builder,
		0,
		v.symbol_intern(relation_name),
		column_names,
		cells,
	)
}

builder_add_dispatch_spec :: proc(
	builder: ^Builder,
	selector: v.Symbol,
	roles: []Dispatch_Role,
) -> i32 {
	owned := make([]Dispatch_Role, len(roles), builder.allocator)
	copy(owned, roles)
	append(&builder.dispatch_specs, Dispatch_Spec {
		selector = selector,
		roles    = owned,
	})
	return i32(len(builder.dispatch_specs) - 1)
}

// Adds a function with an explicit code range and signature, copying
// defaults. Returns the function index. Used by assemble, where the code
// layout is fixed before functions are described (unlike the streaming
// begin/emit/end path the compiler uses).
builder_add_function :: proc(
	builder: ^Builder,
	name: v.Symbol,
	code_offset: int,
	code_len: int,
	register_count: int,
	param_count: int,
	required_count: u16,
	has_rest: bool,
	defaults: []i32,
) -> int {
	owned: []i32
	if len(defaults) > 0 {
		owned = make([]i32, len(defaults), builder.allocator)
		copy(owned, defaults)
	}
	append(&builder.functions, Function {
		name           = name,
		code_offset    = code_offset,
		code_len       = code_len,
		register_count = register_count,
		param_count    = param_count,
		required_count = required_count,
		has_rest       = has_rest,
		defaults       = owned,
	})
	return len(builder.functions) - 1
}

builder_add_constant :: proc(builder: ^Builder, value: v.Value) -> int {
	append(&builder.constants, value)
	return len(builder.constants) - 1
}

builder_begin_function :: proc(
	builder: ^Builder,
	name: v.Symbol,
	param_count: int,
	register_count: int,
	entry := false,
) -> int {
	index := len(builder.functions)
	append(&builder.functions, Function {
		name           = name,
		code_offset    = len(builder.code),
		code_len       = 0,
		register_count = register_count,
		param_count    = param_count,
	})
	builder.open_function = index
	builder.open_offset = len(builder.code)
	if entry {
		builder.entry = index
	}
	return index
}

// Reopens an existing function slot so its body can be emitted later.
builder_reopen_function :: proc(builder: ^Builder, index: int) {
	builder.open_function = index
	builder.open_offset = len(builder.code)
	builder.functions[index].code_offset = builder.open_offset
}

builder_end_function :: proc(builder: ^Builder) {
	if builder.open_function < 0 {
		return
	}
	builder.functions[builder.open_function].code_len =
		len(builder.code) - builder.open_offset
	builder.open_function = -1
}

builder_emit :: proc(builder: ^Builder, op: Op, flags: u8, a, b, c: i32) {
	append(&builder.code, Instruction{op = op, flags = flags, a = a, b = b, c = c})
}

// Moves the built program into `alloc`.
builder_build :: proc(builder: ^Builder, alloc: mem.Allocator) -> ^Program {
	program := new(Program, alloc)
	program.code = make([]Instruction, len(builder.code), alloc)
	copy(program.code, builder.code[:])
	program.constants = make([]v.Value, len(builder.constants), alloc)
	copy(program.constants, builder.constants[:])
	program.functions = make([]Function, len(builder.functions), alloc)
	copy(program.functions, builder.functions[:])
	for function, index in builder.functions {
		if function.defaults != nil {
			defaults := make([]i32, len(function.defaults), alloc)
			copy(defaults, function.defaults)
			program.functions[index].defaults = defaults
		}
	}
	program.patterns = make([]Scan_Pattern, len(builder.patterns), alloc)
	program.relation_shapes = make([]Relation_Shape, len(builder.relation_shapes), alloc)
	for pattern, i in builder.patterns {
		names := make([]v.Symbol, len(pattern.column_names), alloc)
		copy(names, pattern.column_names)
		cells := make([]Pattern_Cell, len(pattern.cells), alloc)
		copy(cells, pattern.cells)
		program.patterns[i] = Scan_Pattern {
			relation      = pattern.relation,
			relation_name = pattern.relation_name,
			column_names  = names,
			cells         = cells,
		}
	}
	for shape, i in builder.relation_shapes {
		heading := make([]v.Symbol, len(shape.heading), alloc)
		copy(heading, shape.heading)
		program.relation_shapes[i] = Relation_Shape{heading = heading}
	}
	program.dispatch_specs = make([]Dispatch_Spec, len(builder.dispatch_specs), alloc)
	for spec, i in builder.dispatch_specs {
		roles := make([]Dispatch_Role, len(spec.roles), alloc)
		copy(roles, spec.roles)
		program.dispatch_specs[i] = Dispatch_Spec {
			selector = spec.selector,
			roles    = roles,
		}
	}
	program.builtins = make([]v.Symbol, len(builder.builtins), alloc)
	copy(program.builtins, builder.builtins[:])
	program.callables = make([dynamic]Callable_Info, alloc)
	program.entry = builder.entry
	program.dispatch_method_selector_relation = builder.dispatch_method_selector_relation
	program.dispatch_param_relation = builder.dispatch_param_relation
	program.dispatch_delegates_relation = builder.dispatch_delegates_relation
	program.dispatch_method_program_relation = builder.dispatch_method_program_relation
	return program
}

program_destroy :: proc(program: ^Program, alloc: mem.Allocator) {
	if program.storage_arena != nil {
		arena, owner := program.storage_arena, program.arena_allocator
		virtual.arena_destroy(arena)
		free(arena, owner)
		return
	}
	for callable in program.callables {
		if callable.captures != nil {
			for capture in callable.captures {v.value_deep_free(alloc, capture)}
			free(raw_data(callable.captures), alloc)
		}
	}
	// `callables` is a dynamic array, so it frees through the allocator it was
	// created with (`alloc` in `builder_build`).
	delete(program.callables)
	free(raw_data(program.code), alloc)
	free(raw_data(program.constants), alloc)
	for function in program.functions {
		if function.defaults != nil {
			free(raw_data(function.defaults), alloc)
		}
	}
	free(raw_data(program.functions), alloc)
	for pattern in program.patterns {
		free(raw_data(pattern.column_names), alloc)
		free(raw_data(pattern.cells), alloc)
	}
	free(raw_data(program.patterns), alloc)
	for shape in program.relation_shapes {
		free(raw_data(shape.heading), alloc)
	}
	free(raw_data(program.relation_shapes), alloc)
	for spec in program.dispatch_specs {
		free(raw_data(spec.roles), alloc)
	}
	free(raw_data(program.dispatch_specs), alloc)
	free(raw_data(program.builtins), alloc)
	free(program, alloc)
}

// --- Validation ------------------------------------------------------------

// Validates register, constant, jump, and function references.
program_validate :: proc(program: ^Program) -> Program_Error {
	if program.entry < 0 || program.entry >= len(program.functions) {
		return .No_Entry
	}
	for function, function_index in program.functions {
		if function.code_offset < 0 ||
		   function.code_len < 0 ||
		   function.code_offset + function.code_len > len(program.code) {
			return .Bad_Function
		}
		// Parameter binding writes registers `0 ..< param_count` before the
		// body runs, so a function must reserve at least that many. A smaller
		// count would write past the frame.
		if function.param_count < 0 || function.register_count < function.param_count {
			return .Bad_Register
		}

		code_end := function.code_offset + function.code_len
		for offset in function.code_offset ..< code_end {
			instr := program.code[offset]
			register_count := function.register_count

			switch instr.op {
			case .Load_Const:
				if !valid_register(instr.a, register_count) {
					return .Bad_Register
				}
				if instr.b < 0 || int(instr.b) >= len(program.constants) {
					return .Bad_Constant
				}
			case .Move:
				if !valid_register(instr.a, register_count) ||
				   !valid_register(instr.b, register_count) {
					return .Bad_Register
				}
			case .Binary:
				if !valid_register(instr.a, register_count) ||
				   !valid_register(instr.b, register_count) ||
				   !valid_register(instr.c, register_count) {
					return .Bad_Register
				}
				if u8(instr.flags) > u8(Bin_Op.Ge) {
					return .Bad_Function
				}
			case .Unary:
				if !valid_register(instr.a, register_count) ||
				   !valid_register(instr.b, register_count) {
					return .Bad_Register
				}
				if u8(instr.flags) > u8(Un_Op.Not) {
					return .Bad_Function
				}
			case .Branch:
				if !valid_register(instr.a, register_count) {
					return .Bad_Register
				}
				target := offset + 1 + int(instr.b)
				if target < function.code_offset || target >= code_end {
					return .Bad_Jump
				}
			case .Jump:
				target := offset + 1 + int(instr.b)
				if target < function.code_offset || target >= code_end {
					return .Bad_Jump
				}
			case .Call:
				if !valid_register(instr.a, register_count) {
					return .Bad_Register
				}
				if instr.b < 0 || int(instr.b) >= len(program.functions) {
					return .Bad_Function
				}
				// flags hold the supplied argument count; optional parameters
				// may be omitted.
				argument_count := int(instr.flags)
				if instr.c < 0 ||
				   int(instr.c) + argument_count > register_count {
					return .Bad_Arguments
				}
				// Direct recursion is allowed; depth is a runtime concern.
			case .Return:
				if !valid_register(instr.a, register_count) {
					return .Bad_Register
				}
			case .Build_List:
				if !valid_register(instr.a, register_count) {
					return .Bad_Register
				}
				if instr.c < 0 {
					return .Bad_Arguments
				}
				for item in 0 ..< int(instr.c) {
					if !valid_register(instr.b + i32(item), register_count) {
						return .Bad_Register
					}
				}
			case .Build_Map:
				if !valid_register(instr.a, register_count) {
					return .Bad_Register
				}
				if instr.c < 0 {
					return .Bad_Arguments
				}
				for item in 0 ..< int(instr.c) * 2 {
					if !valid_register(instr.b + i32(item), register_count) {
						return .Bad_Register
					}
				}
			case .Build_Range:
				if !valid_register(instr.a, register_count) ||
				   !valid_register(instr.b, register_count) ||
				   !valid_register(instr.c, register_count) {
					return .Bad_Register
				}
			case .Len:
				if !valid_register(instr.a, register_count) ||
				   !valid_register(instr.b, register_count) {
					return .Bad_Register
				}
			case .Scan_Collect, .Scan_Exists, .Scan_First, .Scan_One:
				if !valid_register(instr.a, register_count) {
					return .Bad_Register
				}
				if instr.b < 0 || int(instr.b) >= len(program.patterns) {
					return .Bad_Function
				}
			case .Retract_Where:
				if instr.b < 0 || int(instr.b) >= len(program.patterns) {
					return .Bad_Function
				}
			case .Assert, .Retract:
				if instr.a < 0 {
					return .Bad_Function
				}
				if !valid_register(instr.b, register_count) {
					return .Bad_Register
				}
			case .Build_Relation:
				if !valid_register(instr.a, register_count) {
					return .Bad_Register
				}
				if instr.b < 0 || int(instr.b) >= len(program.relation_shapes) {
					return .Bad_Function
				}
				arity := len(program.relation_shapes[instr.b].heading)
				for cell in 0 ..< arity {
					if !valid_register(instr.c + i32(cell), register_count) {
						return .Bad_Register
					}
				}
			case .Index:
				if !valid_register(instr.a, register_count) ||
				   !valid_register(instr.b, register_count) ||
				   !valid_register(instr.c, register_count) {
					return .Bad_Register
				}
			case .Collection_Key_At, .Collection_Value_At:
				if !valid_register(instr.a, register_count) ||
				   !valid_register(instr.b, register_count) ||
				   !valid_register(instr.c, register_count) {
					return .Bad_Register
				}
			case .Builtin_Call:
				if !valid_register(instr.a, register_count) {
					return .Bad_Register
				}
				if instr.b < 0 || int(instr.b) >= len(program.builtins) {
					return .Bad_Function
				}
				if !valid_register(instr.c, register_count) {
					return .Bad_Register
				}
				// The VM reads the argument registers `c .. c+flags-1`.
				if int(instr.c) + int(instr.flags) > register_count {
					return .Bad_Arguments
				}
			case .Commit:
			case .Is_Truthy:
				if !valid_register(instr.a, register_count) ||
				   !valid_register(instr.b, register_count) {
					return .Bad_Register
				}
			case .Dispatch:
				if !valid_register(instr.a, register_count) {
					return .Bad_Register
				}
				if instr.b < 0 || int(instr.b) >= len(program.dispatch_specs) {
					return .Bad_Function
				}
				for role in program.dispatch_specs[instr.b].roles {
					if !valid_register(role.register, register_count) {
						return .Bad_Register
					}
				}
			case .Yield:
				if !valid_register(instr.a, register_count) {
					return .Bad_Register
				}
			case .Sleep:
				if !valid_register(instr.a, register_count) ||
				   !valid_register(instr.b, register_count) {
					return .Bad_Register
				}
			case .Spawn:
				if !valid_register(instr.a, register_count) {
					return .Bad_Register
				}
				if instr.b < 0 || int(instr.b) >= len(program.dispatch_specs) {
					return .Bad_Function
				}
				if instr.flags & 1 != 0 && !valid_register(instr.c, register_count) {
					return .Bad_Register
				}
				for role in program.dispatch_specs[instr.b].roles {
					if !valid_register(role.register, register_count) {
						return .Bad_Register
					}
				}
			case .Raise:
				if !valid_register(instr.a, register_count) {
					return .Bad_Register
				}
				if instr.b >= 0 && !valid_register(instr.b, register_count) {
					return .Bad_Register
				}
				if instr.c >= 0 && !valid_register(instr.c, register_count) {
					return .Bad_Register
				}
			case .Dynamic_Dispatch:
				if !valid_register(instr.a, register_count) ||
				   !valid_register(instr.b, register_count) ||
				   !valid_register(instr.c, register_count) {
					return .Bad_Register
				}
			case .Positional_Dispatch:
				if !valid_register(instr.a, register_count) ||
				   !valid_register(instr.b, register_count) {
					return .Bad_Register
				}
				if instr.flags > 0 {
					if !valid_register(instr.c, register_count) {
						return .Bad_Register
					}
					// The VM reads the argument registers `c .. c+flags-1`.
					if int(instr.c) + int(instr.flags) > register_count {
						return .Bad_Arguments
					}
				}
			case .Mailbox_Recv:
				if !valid_register(instr.a, register_count) ||
				   !valid_register(instr.b, register_count) {
					return .Bad_Register
				}
				if instr.flags & 1 != 0 && !valid_register(instr.c, register_count) {
					return .Bad_Register
				}
			case .External_Request:
				if !valid_register(instr.a, register_count) ||
				   !valid_register(instr.b, register_count) ||
				   !valid_register(instr.c, register_count) {
					return .Bad_Register
				}
			case .Read:
				if !valid_register(instr.a, register_count) {
					return .Bad_Register
				}
				if instr.b >= 0 && !valid_register(instr.b, register_count) {
					return .Bad_Register
				}
			case .Push_Handler:
				if instr.a < 0 {
					return .Bad_Function
				}
				if int(instr.a) < function.code_offset || int(instr.a) >= code_end {
					return .Bad_Jump
				}
				if instr.b >= 0 && !valid_register(instr.b, register_count) {
					return .Bad_Register
				}
			case .Push_Finally:
				if instr.a < 0 {
					return .Bad_Function
				}
				if int(instr.a) < function.code_offset || int(instr.a) >= code_end {
					return .Bad_Jump
				}
			case .Pop_Handler:
			case .Resume_Return:
			case .Make_Function:
				if !valid_register(instr.a, register_count) {
					return .Bad_Register
				}
				if instr.b < 0 || int(instr.b) >= len(program.functions) {
					return .Bad_Function
				}
				for offset in 0 ..< int(instr.flags) {
					if !valid_register(instr.c + i32(offset), register_count) {
						return .Bad_Register
					}
				}
			case .Make_Self_Function:
				if instr.flags == 0 {
					return .Bad_Register
				}
				if !valid_register(instr.a, register_count) {
					return .Bad_Register
				}
				if instr.b < 0 || int(instr.b) >= len(program.functions) {
					return .Bad_Function
				}
				for offset in 0 ..< int(instr.flags) {
					if !valid_register(instr.c + i32(offset), register_count) {
						return .Bad_Register
					}
				}
			case .Call_Value:
				if !valid_register(instr.a, register_count) ||
				   !valid_register(instr.b, register_count) {
					return .Bad_Register
				}
				if instr.flags > 0 {
					if !valid_register(instr.c, register_count) {
						return .Bad_Register
					}
					// The VM reads the argument registers `c .. c+flags-1`.
					if int(instr.c) + int(instr.flags) > register_count {
						return .Bad_Arguments
					}
				}
			case .Call_Splice:
				if !valid_register(instr.a, register_count) ||
				   !valid_register(instr.c, register_count) {
					return .Bad_Register
				}
				if instr.b < 0 || int(instr.b) >= len(program.functions) {
					return .Bad_Function
				}
			case .Builtin_Call_Splice:
				if !valid_register(instr.a, register_count) ||
				   !valid_register(instr.c, register_count) {
					return .Bad_Register
				}
				if instr.b < 0 || int(instr.b) >= len(program.builtins) {
					return .Bad_Function
				}
			case .Call_Value_Splice:
				if !valid_register(instr.a, register_count) ||
				   !valid_register(instr.b, register_count) ||
				   !valid_register(instr.c, register_count) {
					return .Bad_Register
				}
			}
		}
	}
	return .None
}

@(private)
valid_register :: proc(index: i32, count: int) -> bool {
	return index >= 0 && int(index) < count
}

// --- Disassembly -----------------------------------------------------------

// Formats a program listing into a newly allocated string.
program_disassemble :: proc(program: ^Program, alloc := context.allocator) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, alloc)
	defer strings.builder_destroy(&builder)

	for function, function_index in program.functions {
		entry_mark := function_index == program.entry ? " entry" : ""
		name, _ := v.symbol_name(function.name)
		fmt.sbprintf(
			&builder,
			"function %s params=%d regs=%d%s\n",
			name,
			function.param_count,
			function.register_count,
			entry_mark,
		)
		for offset in function.code_offset ..< function.code_offset + function.code_len {
			instr := program.code[offset]
			op_name := op_name(instr.op)
			fmt.sbprintf(&builder, "  %04d  %-12s", offset, op_name)
			switch instr.op {
			case .Load_Const:
				fmt.sbprintf(&builder, " r%d c%d", instr.a, instr.b)
			case .Move:
				fmt.sbprintf(&builder, " r%d r%d", instr.a, instr.b)
			case .Binary:
				fmt.sbprintf(
					&builder,
					" %s r%d r%d r%d",
					bin_op_name(Bin_Op(instr.flags)),
					instr.a,
					instr.b,
					instr.c,
				)
			case .Unary:
				fmt.sbprintf(
					&builder,
					" %s r%d r%d",
					un_op_name(Un_Op(instr.flags)),
					instr.a,
					instr.b,
				)
			case .Branch:
				fmt.sbprintf(
					&builder,
					" r%d -> %d",
					instr.a,
					offset + 1 + int(instr.b),
				)
			case .Jump:
				fmt.sbprintf(&builder, " -> %d", offset + 1 + int(instr.b))
			case .Call:
				fmt.sbprintf(&builder, " r%d fn%d args@r%d", instr.a, instr.b, instr.c)
			case .Return:
				fmt.sbprintf(&builder, " r%d", instr.a)
			case .Build_List:
				fmt.sbprintf(&builder, " r%d r%d..%d", instr.a, instr.b, instr.b + instr.c)
			case .Build_Map:
				fmt.sbprintf(
					&builder,
					" r%d r%d..%d",
					instr.a,
					instr.b,
					instr.b + instr.c * 2,
				)
			case .Build_Range:
				fmt.sbprintf(&builder, " r%d r%d..r%d", instr.a, instr.b, instr.c)
			case .Len:
				fmt.sbprintf(&builder, " r%d r%d", instr.a, instr.b)
			case .Scan_Collect, .Scan_Exists, .Scan_First:
				fmt.sbprintf(&builder, " r%d pat%d", instr.a, instr.b)
			case .Assert:
				fmt.sbprintf(&builder, " rel%d r%d", instr.a, instr.b)
			case .Retract:
				fmt.sbprintf(&builder, " rel%d r%d", instr.a, instr.b)
			case .Retract_Where:
				fmt.sbprintf(&builder, " pat%d", instr.b)
			case .Build_Relation:
				fmt.sbprintf(&builder, " r%d shape%d r%d..", instr.a, instr.b, instr.c)
			case .Index:
				fmt.sbprintf(&builder, " r%d r%d r%d", instr.a, instr.b, instr.c)
			case .Collection_Key_At, .Collection_Value_At:
				fmt.sbprintf(&builder, " r%d r%d r%d", instr.a, instr.b, instr.c)
			case .Builtin_Call:
				builtin_name, _ := v.symbol_name(program.builtins[instr.b])
				fmt.sbprintf(&builder, " r%d %s args@r%d", instr.a, builtin_name, instr.c)
			case .Commit:
				fmt.sbprintf(&builder, "")
			case .Is_Truthy:
				fmt.sbprintf(&builder, " r%d r%d", instr.a, instr.b)
			case .Scan_One:
				fmt.sbprintf(&builder, " r%d pat%d", instr.a, instr.b)
			case .Dispatch:
				fmt.sbprintf(&builder, " r%d spec%d", instr.a, instr.b)
			case .Yield:
				fmt.sbprintf(&builder, " r%d", instr.a)
			case .Sleep:
				fmt.sbprintf(&builder, " r%d r%d", instr.a, instr.b)
			case .Spawn:
				fmt.sbprintf(&builder, " r%d spec%d", instr.a, instr.b)
			case .Raise:
				fmt.sbprintf(&builder, " r%d r%d r%d", instr.a, instr.b, instr.c)
			case .Dynamic_Dispatch:
				fmt.sbprintf(&builder, " r%d <- r%d roles@r%d", instr.a, instr.b, instr.c)
			case .Positional_Dispatch:
				fmt.sbprintf(&builder, " r%d <- r%d args@r%d", instr.a, instr.b, instr.c)
			case .Mailbox_Recv:
				fmt.sbprintf(&builder, " r%d receivers@r%d", instr.a, instr.b)
			case .External_Request:
				fmt.sbprintf(&builder, " r%d %d@r%d", instr.a, instr.b, instr.c)
			case .Read:
				fmt.sbprintf(&builder, " r%d meta@r%d", instr.a, instr.b)
			case .Push_Handler:
				fmt.sbprintf(&builder, " ->%d r%d", instr.a, instr.b)
			case .Push_Finally:
				fmt.sbprintf(&builder, " ->%d", instr.a)
			case .Pop_Handler:
				fmt.sbprintf(&builder, "")
			case .Resume_Return:
				fmt.sbprintf(&builder, "")
			case .Make_Function:
				fmt.sbprintf(&builder, " r%d fn%d", instr.a, instr.b)
			case .Make_Self_Function:
				fmt.sbprintf(&builder, " r%d fn%d captures@r%d", instr.a, instr.b, instr.c)
			case .Call_Value:
				fmt.sbprintf(&builder, " r%d r%d args@r%d", instr.a, instr.b, instr.c)
			case .Call_Splice:
				fmt.sbprintf(&builder, " r%d fn%d args@r%d", instr.a, instr.b, instr.c)
			case .Builtin_Call_Splice:
				fmt.sbprintf(&builder, " r%d builtin%d args@r%d", instr.a, instr.b, instr.c)
			case .Call_Value_Splice:
				fmt.sbprintf(&builder, " r%d r%d args@r%d", instr.a, instr.b, instr.c)
			}
			strings.write_byte(&builder, '\n')
		}
	}
	return strings.to_string(builder)
}

@(private)
op_name :: proc(op: Op) -> string {
	switch op {
	case .Load_Const:
		return "load_const"
	case .Move:
		return "move"
	case .Binary:
		return "binary"
	case .Unary:
		return "unary"
	case .Branch:
		return "branch"
	case .Jump:
		return "jump"
	case .Call:
		return "call"
	case .Return:
		return "return"
	case .Build_List:
		return "build_list"
	case .Build_Map:
		return "build_map"
	case .Build_Range:
		return "build_range"
	case .Len:
		return "len"
	case .Scan_Collect:
		return "scan_collect"
	case .Scan_Exists:
		return "scan_exists"
	case .Scan_First:
		return "scan_first"
	case .Assert:
		return "assert"
	case .Retract:
		return "retract"
	case .Retract_Where:
		return "retract_where"
	case .Build_Relation:
		return "build_relation"
	case .Index:
		return "index"
	case .Collection_Key_At:
		return "collection_key_at"
	case .Collection_Value_At:
		return "collection_value_at"
	case .Builtin_Call:
		return "builtin_call"
	case .Commit:
		return "commit"
	case .Is_Truthy:
		return "is_truthy"
	case .Scan_One:
		return "scan_one"
	case .Dispatch:
		return "dispatch"
	case .Yield:
		return "yield"
	case .Sleep:
		return "sleep"
	case .Spawn:
		return "spawn"
	case .Raise:
		return "raise"
	case .Dynamic_Dispatch:
		return "dynamic_dispatch"
	case .Positional_Dispatch:
		return "positional_dispatch"
	case .Mailbox_Recv:
		return "mailbox_recv"
	case .External_Request:
		return "external_request"
	case .Read:
		return "read"
	case .Push_Handler:
		return "push_handler"
	case .Pop_Handler:
		return "pop_handler"
	case .Push_Finally:
		return "push_finally"
	case .Resume_Return:
		return "resume_return"
	case .Make_Function:
		return "make_function"
	case .Make_Self_Function:
		return "make_self_function"
	case .Call_Value:
		return "call_value"
	case .Call_Splice:
		return "call_splice"
	case .Builtin_Call_Splice:
		return "builtin_call_splice"
	case .Call_Value_Splice:
		return "call_value_splice"
	}
	return "?"
}

@(private)
bin_op_name :: proc(op: Bin_Op) -> string {
	switch op {
	case .Add:
		return "add"
	case .Sub:
		return "sub"
	case .Mul:
		return "mul"
	case .Div:
		return "div"
	case .Rem:
		return "rem"
	case .Eq:
		return "eq"
	case .Ne:
		return "ne"
	case .Lt:
		return "lt"
	case .Le:
		return "le"
	case .Gt:
		return "gt"
	case .Ge:
		return "ge"
	}
	return "?"
}

@(private)
un_op_name :: proc(op: Un_Op) -> string {
	switch op {
	case .Neg:
		return "neg"
	case .Not:
		return "not"
	}
	return "?"
}
