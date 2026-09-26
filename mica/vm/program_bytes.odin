// Program artifact encoding: a compiled Program as bytes.
//
// The artifact is the durable form of a program for `ProgramBytes` rows and
// boot without recompilation (#77). Layout, all little-endian:
//
//   magic[8]      "MICAPO10" (Odin program artifact; the Rust MICAPRG10
//                 layout differs, so it takes its own magic)
//   version u32   ARTIFACT_VERSION; a mismatch fails before any section
//   header        entry i64, then the four dispatch relation ids u32
//   code          count u32, then op u8, flags u8, a/b/c i32 per instruction
//   constants     count u32, then u32 length + shared-codec bytes per value
//   functions     count u32, then name symbol, code_offset/code_len/
//                 register_count/param_count u32, required_count u16,
//                 has_rest u8, defaults count u32 + i32 each
//   patterns      count u32, then relation u32, column name symbols,
//                 cells (kind u8, operand i32)
//   shapes        count u32, then heading symbols per shape
//   specs         count u32, then selector symbol, roles (symbol, i32)
//   builtins      count u32, then one symbol each
//
// Symbols encode as their names and are re-interned on decode. Decoding
// checks framing only (magic, version, counts against remaining bytes,
// exact value framing, no trailing bytes); all reference semantics are left
// to `program_validate`.
//
// On encode error `out` may hold a prefix; the caller must discard it. On
// decode error partial allocations stay owned by `allocator`, matching the
// codec convention; corrupt-input tests should decode into an arena.
package vm

import "core:mem"
import s "../store"
import v "../var"

// Magic for the Odin program artifact, version 1.0.
ARTIFACT_MAGIC :: "MICAPO10"
// Artifact layout version. Bump when the section layout changes; old bytes
// must fail with Bad_Version, never misdecode.
ARTIFACT_VERSION :: u32(2)

Artifact_Error :: enum {
	None,
	// First eight bytes are not the artifact magic.
	Bad_Magic,
	// Version word does not match ARTIFACT_VERSION.
	Bad_Version,
	// Input ends mid-section.
	Truncated,
	// Bytes remain after the final section.
	Trailing_Bytes,
	// A count prefix exceeds the bytes remaining.
	Bad_Count,
	// An opcode byte is outside the Op range.
	Bad_Op,
	// A value, symbol, or integer field does not decode.
	Bad_Value,
	// A section is too large to frame.
	Too_Large,
	// A constant uses the shared codec's verdict for capabilities/functions.
	Not_Persistable,
}

// Content identity for an encoded artifact (FNV-1a 64). Equal bytes give
// equal ids; use it as the ProgramBytes program identity.
program_artifact_fingerprint :: proc(bytes: []u8) -> u64 {
	hash := u64(14695981039346656037)
	for b in bytes {
		hash = (hash ~ u64(b)) * 1099511628211
	}
	return hash
}

// Derives the durable program identity for encoded artifact bytes: the
// fingerprint folded into the identity range. Never zero, so it always
// forms a valid identity value.
program_artifact_id :: proc(bytes: []u8) -> (v.Value, bool) {
	id := program_artifact_fingerprint(bytes) & v.IDENTITY_MAX
	if id == 0 {
		id = 1
	}
	return v.value_identity_raw(id)
}

// Encodes `program` into `out`. Returns None on success; `out` may hold a
// discarded prefix on any other result.
program_to_bytes :: proc(program: ^Program, out: ^[dynamic]u8) -> Artifact_Error {
	append(out, ARTIFACT_MAGIC)
	ab_u32(out, ARTIFACT_VERSION)
	if program.entry < 0 {
		return .Bad_Value
	}
	ab_u64(out, u64(program.entry))
	ab_u32(out, program.dispatch_method_selector_relation)
	ab_u32(out, program.dispatch_param_relation)
	ab_u32(out, program.dispatch_delegates_relation)
	ab_u32(out, program.dispatch_method_program_relation)

	if error := ab_count(out, len(program.code)); error != .None {
		return error
	}
	for instr in program.code {
		append(out, u8(instr.op), instr.flags)
		ab_u32(out, transmute(u32)instr.a)
		ab_u32(out, transmute(u32)instr.b)
		ab_u32(out, transmute(u32)instr.c)
	}

	if error := ab_count(out, len(program.constants)); error != .None {
		return error
	}
	for constant in program.constants {
		if error := ab_value(out, constant); error != .None {
			return error
		}
	}

	if error := ab_count(out, len(program.functions)); error != .None {
		return error
	}
	for function in program.functions {
		if error := ab_symbol(out, function.name); error != .None {
			return error
		}
		fields := [4]int{function.code_offset, function.code_len, function.register_count, function.param_count}
		for field in fields {
			if field < 0 {
				return .Bad_Value
			}
			ab_u32(out, u32(field))
		}
		ab_u16(out, function.required_count)
		append(out, 1 if function.has_rest else 0)
		if error := ab_count(out, len(function.defaults)); error != .None {
			return error
		}
		for default in function.defaults {
			ab_u32(out, transmute(u32)default)
		}
	}

	if error := ab_count(out, len(program.patterns)); error != .None {
		return error
	}
	for pattern in program.patterns {
		ab_u32(out, pattern.relation)
		// Only an unresolved pattern carries a name; a resolved one already
		// has its id, and serializing the zero symbol would be ambiguous.
		if pattern.relation == 0 {
			if error := ab_symbol(out, pattern.relation_name); error != .None {
				return error
			}
		}
		if error := ab_symbols(out, pattern.column_names); error != .None {
			return error
		}
		if error := ab_count(out, len(pattern.cells)); error != .None {
			return error
		}
		for cell in pattern.cells {
			append(out, u8(cell.kind))
			ab_u32(out, transmute(u32)cell.operand)
		}
	}

	if error := ab_count(out, len(program.relation_shapes)); error != .None {
		return error
	}
	for shape in program.relation_shapes {
		if error := ab_symbols(out, shape.heading); error != .None {
			return error
		}
	}

	if error := ab_count(out, len(program.dispatch_specs)); error != .None {
		return error
	}
	for spec in program.dispatch_specs {
		if error := ab_symbol(out, spec.selector); error != .None {
			return error
		}
		if error := ab_count(out, len(spec.roles)); error != .None {
			return error
		}
		for role in spec.roles {
			if error := ab_symbol(out, role.role); error != .None {
				return error
			}
			ab_u32(out, transmute(u32)role.register)
		}
	}

	return ab_symbols(out, program.builtins)
}

// Decodes an artifact into `allocator`. Framing errors return nil plus the
// verdict; reference semantics are left to `program_validate`. Partial
// allocations on error stay owned by `allocator`.
program_from_bytes :: proc(data: []u8, allocator: mem.Allocator) -> (^Program, Artifact_Error) {
	reader := Artifact_Reader{data = data}
	if !ar_magic(&reader) {
		return nil, .Bad_Magic
	}
	version, version_ok := ar_u32(&reader)
	if !version_ok {
		return nil, .Truncated
	}
	if version != ARTIFACT_VERSION {
		return nil, .Bad_Version
	}

	builder: Builder
	builder_init(&builder, allocator)
	failed := true
	defer if failed {
		builder_destroy(&builder)
	}

	entry, entry_ok := ar_i64(&reader)
	if !entry_ok {
		return nil, .Truncated
	}
	if entry < 0 {
		return nil, .Bad_Value
	}
	header: [4]u32
	for index in 0 ..< 4 {
		id, id_ok := ar_u32(&reader)
		if !id_ok {
			return nil, .Truncated
		}
		header[index] = id
	}

	code_count, code_count_err := ar_count(&reader, 14)
	if code_count_err != .None {
		return nil, code_count_err
	}
	for _ in 0 ..< code_count {
		op_byte, op_ok := ar_u8(&reader)
		flags, flags_ok := ar_u8(&reader)
		a, a_ok := ar_i32(&reader)
		b, b_ok := ar_i32(&reader)
		c, c_ok := ar_i32(&reader)
		if !op_ok || !flags_ok || !a_ok || !b_ok || !c_ok {
			return nil, .Truncated
		}
		if int(op_byte) > int(Op.Positional_Dispatch_Splice) {
			return nil, .Bad_Op
		}
		append(&builder.code, Instruction{op = Op(op_byte), flags = flags, a = a, b = b, c = c})
	}

	constant_count, constant_count_err := ar_count(&reader, 5)
	if constant_count_err != .None {
		return nil, constant_count_err
	}
	for _ in 0 ..< constant_count {
		value, value_ok := ar_value(&reader, allocator)
		if !value_ok {
			return nil, .Bad_Value
		}
		append(&builder.constants, value)
	}

	function_count, function_count_err := ar_count(&reader, 8)
	if function_count_err != .None {
		return nil, function_count_err
	}
	for _ in 0 ..< function_count {
		name, name_ok := ar_symbol(&reader)
		if !name_ok {
			return nil, .Bad_Value
		}
		fields: [4]int
		for index in 0 ..< 4 {
			field, field_ok := ar_u32(&reader)
			if !field_ok {
				return nil, .Truncated
			}
			fields[index] = int(field)
		}
		required, required_ok := ar_u16(&reader)
		rest, rest_ok := ar_u8(&reader)
		if !required_ok || !rest_ok || rest > 1 {
			return nil, .Bad_Value
		}
		default_count, default_count_err := ar_count(&reader, 4)
		if default_count_err != .None {
			return nil, default_count_err
		}
		defaults := make([]i32, default_count, builder.allocator)
		for index in 0 ..< default_count {
			default, default_ok := ar_i32(&reader)
			if !default_ok {
				delete(defaults, builder.allocator)
				return nil, .Truncated
			}
			defaults[index] = default
		}
		append(&builder.functions, Function {
			name           = name,
			code_offset    = fields[0],
			code_len       = fields[1],
			register_count = fields[2],
			param_count    = fields[3],
			required_count = required,
			has_rest       = rest == 1,
			defaults       = defaults if default_count > 0 else nil,
		})
	}

	pattern_count, pattern_count_err := ar_count(&reader, 8)
	if pattern_count_err != .None {
		return nil, pattern_count_err
	}
	for _ in 0 ..< pattern_count {
		relation, relation_ok := ar_u32(&reader)
		if !relation_ok {
			return nil, .Bad_Value
		}
		relation_name := v.Symbol(0)
		if relation == 0 {
			name, name_ok := ar_symbol(&reader)
			if !name_ok {
				return nil, .Bad_Value
			}
			relation_name = name
		}
		names, names_ok := ar_symbol_list(&reader, allocator)
		if !names_ok {
			return nil, .Bad_Value
		}
		cell_count, cell_count_err := ar_count(&reader, 5)
		if cell_count_err != .None {
			delete(names, allocator)
			return nil, cell_count_err
		}
		cells := make([]Pattern_Cell, cell_count, allocator)
		cells_ok := true
		for index in 0 ..< cell_count {
			kind, kind_ok := ar_u8(&reader)
			operand, operand_ok := ar_i32(&reader)
			if !kind_ok || !operand_ok || int(kind) > int(Pattern_Cell_Kind.Wildcard) {
				cells_ok = false
				break
			}
			cells[index] = Pattern_Cell{kind = Pattern_Cell_Kind(kind), operand = operand}
		}
		if !cells_ok {
			delete(cells, allocator)
			delete(names, allocator)
			return nil, .Bad_Value
		}
		append(&builder.patterns, Scan_Pattern {
			relation      = relation,
			relation_name = relation_name,
			column_names  = names,
			cells         = cells,
		})
	}

	shape_count, shape_count_err := ar_count(&reader, 4)
	if shape_count_err != .None {
		return nil, shape_count_err
	}
	for _ in 0 ..< shape_count {
		heading, heading_ok := ar_symbol_list(&reader, allocator)
		if !heading_ok {
			return nil, .Bad_Value
		}
		append(&builder.relation_shapes, Relation_Shape{heading = heading})
	}

	spec_count, spec_count_err := ar_count(&reader, 8)
	if spec_count_err != .None {
		return nil, spec_count_err
	}
	for _ in 0 ..< spec_count {
		selector, selector_ok := ar_symbol(&reader)
		if !selector_ok {
			return nil, .Bad_Value
		}
		role_count, role_count_err := ar_count(&reader, 8)
		if role_count_err != .None {
			return nil, role_count_err
		}
		roles := make([]Dispatch_Role, role_count, allocator)
		roles_ok := true
		for index in 0 ..< role_count {
			role, role_ok := ar_symbol(&reader)
			register, register_ok := ar_i32(&reader)
			if !role_ok || !register_ok {
				roles_ok = false
				break
			}
			roles[index] = Dispatch_Role{role = role, register = register}
		}
		if !roles_ok {
			delete(roles, allocator)
			return nil, .Bad_Value
		}
		append(&builder.dispatch_specs, Dispatch_Spec{selector = selector, roles = roles})
	}

	builtins, builtins_ok := ar_symbol_list(&reader, allocator)
	if !builtins_ok {
		return nil, .Bad_Value
	}
	for symbol in builtins {
		append(&builder.builtins, symbol)
	}
	delete(builtins, allocator)

	if reader.cursor != len(reader.data) {
		return nil, .Trailing_Bytes
	}

	builder.entry = int(entry)
	builder.dispatch_method_selector_relation = header[0]
	builder.dispatch_param_relation = header[1]
	builder.dispatch_delegates_relation = header[2]
	builder.dispatch_method_program_relation = header[3]
	program := builder_build(&builder, allocator)
	failed = false
	return program, .None
}

// --- Writers ---------------------------------------------------------------

@(private)
ab_u16 :: proc(out: ^[dynamic]u8, value: u16) {
	append(out, u8(value), u8(value >> 8))
}

@(private)
ab_u32 :: proc(out: ^[dynamic]u8, value: u32) {
	append(out, u8(value), u8(value >> 8), u8(value >> 16), u8(value >> 24))
}

@(private)
ab_u64 :: proc(out: ^[dynamic]u8, value: u64) {
	for index in 0 ..< 8 {
		append(out, u8(value >> (8 * u32(index))))
	}
}

// Frames a section length. Guards the u32 range so a corrupt in-memory
// length cannot wrap the prefix.
@(private)
ab_count :: proc(out: ^[dynamic]u8, count: int) -> Artifact_Error {
	if count < 0 || i64(count) > i64(max(u32)) {
		return .Too_Large
	}
	ab_u32(out, u32(count))
	return .None
}

@(private)
ab_string :: proc(out: ^[dynamic]u8, text: string) -> Artifact_Error {
	if len(text) > int(max(u32)) {
		return .Too_Large
	}
	ab_u32(out, u32(len(text)))
	append(out, text)
	return .None
}

@(private)
ab_symbol :: proc(out: ^[dynamic]u8, symbol: v.Symbol) -> Artifact_Error {
	name, has_name := v.symbol_name(symbol)
	if !has_name {
		return .Bad_Value
	}
	return ab_string(out, name)
}

@(private)
ab_symbols :: proc(out: ^[dynamic]u8, symbols: []v.Symbol) -> Artifact_Error {
	if error := ab_count(out, len(symbols)); error != .None {
		return error
	}
	for symbol in symbols {
		if error := ab_symbol(out, symbol); error != .None {
			return error
		}
	}
	return .None
}

// Frames one constant with the shared value codec.
@(private)
ab_value :: proc(out: ^[dynamic]u8, value: v.Value) -> Artifact_Error {
	framed: [dynamic]u8
	defer delete(framed)
	if s.codec_encode_value(&framed, value) == .Not_Persistable {
		return .Not_Persistable
	} else if len(framed) == 0 {
		return .Bad_Value
	}
	if error := ab_count(out, len(framed)); error != .None {
		return error
	}
	append(out, ..framed[:])
	return .None
}

// --- Reader ----------------------------------------------------------------

@(private)
Artifact_Reader :: struct {
	data:   []u8,
	cursor: int,
}

@(private)
ar_remaining :: proc(reader: ^Artifact_Reader) -> int {
	return len(reader.data) - reader.cursor
}

@(private)
ar_magic :: proc(reader: ^Artifact_Reader) -> bool {
	if ar_remaining(reader) < len(ARTIFACT_MAGIC) {
		return false
	}
	magic := string(reader.data[reader.cursor:reader.cursor + len(ARTIFACT_MAGIC)])
	if magic != ARTIFACT_MAGIC {
		return false
	}
	reader.cursor += len(ARTIFACT_MAGIC)
	return true
}

@(private)
ar_u8 :: proc(reader: ^Artifact_Reader) -> (u8, bool) {
	if ar_remaining(reader) < 1 {
		return 0, false
	}
	value := reader.data[reader.cursor]
	reader.cursor += 1
	return value, true
}

@(private)
ar_u16 :: proc(reader: ^Artifact_Reader) -> (u16, bool) {
	if ar_remaining(reader) < 2 {
		return 0, false
	}
	value := u16(reader.data[reader.cursor]) | u16(reader.data[reader.cursor + 1]) << 8
	reader.cursor += 2
	return value, true
}

@(private)
ar_u32 :: proc(reader: ^Artifact_Reader) -> (u32, bool) {
	if ar_remaining(reader) < 4 {
		return 0, false
	}
	value := u32(reader.data[reader.cursor]) |
		u32(reader.data[reader.cursor + 1]) << 8 |
		u32(reader.data[reader.cursor + 2]) << 16 |
		u32(reader.data[reader.cursor + 3]) << 24
	reader.cursor += 4
	return value, true
}

@(private)
ar_u64 :: proc(reader: ^Artifact_Reader) -> (u64, bool) {
	if ar_remaining(reader) < 8 {
		return 0, false
	}
	value := u64(0)
	for index in 0 ..< 8 {
		value |= u64(reader.data[reader.cursor + index]) << (8 * u32(index))
	}
	reader.cursor += 8
	return value, true
}

@(private)
ar_i32 :: proc(reader: ^Artifact_Reader) -> (i32, bool) {
	raw, ok := ar_u32(reader)
	return transmute(i32)raw, ok
}

@(private)
ar_i64 :: proc(reader: ^Artifact_Reader) -> (i64, bool) {
	raw, ok := ar_u64(reader)
	return transmute(i64)raw, ok
}

// Reads a count prefix guarded against the bytes remaining: each element
// needs at least `min_bytes`, so a corrupt count fails before any
// allocation, mirroring the codec's count bound. A prefix cut short by the
// end of input reports Truncated; a present prefix that exceeds the
// remainder reports Bad_Count.
@(private)
ar_count :: proc(reader: ^Artifact_Reader, min_bytes: int) -> (int, Artifact_Error) {
	count, ok := ar_u32(reader)
	if !ok {
		return 0, .Truncated
	}
	step := max(min_bytes, 1)
	if i64(count) * i64(step) > i64(ar_remaining(reader)) {
		return 0, .Bad_Count
	}
	return int(count), .None
}

@(private)
ar_string :: proc(reader: ^Artifact_Reader, allocator: mem.Allocator) -> (string, bool) {
	length, length_err := ar_count(reader, 1)
	if length_err != .None {
		return "", false
	}
	// ar_count guarantees length <= remaining, but length 0 is allowed.
	text := make([]u8, length, allocator)
	copy(text, reader.data[reader.cursor:reader.cursor + length])
	reader.cursor += length
	return transmute(string)text, true
}

@(private)
ar_symbol :: proc(reader: ^Artifact_Reader) -> (v.Symbol, bool) {
	name, ok := ar_string(reader, context.temp_allocator)
	if !ok {
		return v.Symbol(0), false
	}
	defer delete(name, context.temp_allocator)
	return v.symbol_intern(name), true
}

@(private)
ar_symbol_list :: proc(
	reader: ^Artifact_Reader,
	allocator: mem.Allocator,
) -> (
	[]v.Symbol,
	bool,
) {
	count, count_err := ar_count(reader, 4)
	if count_err != .None {
		return nil, false
	}
	symbols := make([]v.Symbol, count, allocator)
	for index in 0 ..< count {
		symbol, symbol_ok := ar_symbol(reader)
		if !symbol_ok {
			delete(symbols, allocator)
			return nil, false
		}
		symbols[index] = symbol
	}
	return symbols, true
}

// Reads one framed constant. The codec must consume exactly the framed
// bytes; anything else is a corrupt value.
@(private)
ar_value :: proc(
	reader: ^Artifact_Reader,
	allocator: mem.Allocator,
) -> (
	v.Value,
	bool,
) {
	length, length_err := ar_count(reader, 1)
	if length_err != .None {
		return v.Value(0), false
	}
	slice := reader.data[reader.cursor:reader.cursor + length]
	cursor := 0
	value, error := s.codec_decode_value(slice, &cursor, allocator)
	if error != .None || cursor != length {
		return v.Value(0), false
	}
	reader.cursor += length
	return value, true
}
