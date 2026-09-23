// Minimal XML parsing for the `from_xml` builtin, mirroring the quick-xml
// event loop in the Rust runtime. Handles elements, attributes, text, CDATA,
// comments, declarations, and the five predefined entities plus numeric
// character references.
package dom

import "core:mem"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import v "../var"

@(private)
Xml_Frame :: struct {
	tag:      string,
	attrs:    [dynamic]v.Map_Entry,
	children: [dynamic]v.Value,
}

// Builds the map shape `dom_element` produces.
dom_element_value :: proc(
	tag: string,
	attrs: []v.Map_Entry,
	children: []v.Value,
	allocator: mem.Allocator,
) -> v.Value {
	return v.value_map(allocator, []v.Map_Entry {
		{
			key   = v.value_symbol(v.symbol_intern("attrs")),
			value = v.value_map(allocator, attrs),
		},
		{
			key   = v.value_symbol(v.symbol_intern("children")),
			value = v.value_list(allocator, children),
		},
		{
			key   = v.value_symbol(v.symbol_intern("tag")),
			value = v.value_string(allocator, tag),
		},
	})
}

// Builds the map shape `dom_text` produces.
dom_text_value :: proc(text: string, allocator: mem.Allocator) -> v.Value {
	return v.value_map(allocator, []v.Map_Entry {
		{
			key   = v.value_symbol(v.symbol_intern("text")),
			value = v.value_string(allocator, text),
		},
	})
}

// Parses XML into a DOM value: one root node, or a list when the text holds
// several top-level nodes. Returns an error message on failure.
dom_parse_xml_value :: proc(text: string, allocator: mem.Allocator) -> (v.Value, string) {
	stack: [dynamic]Xml_Frame
	stack = make([dynamic]Xml_Frame, context.temp_allocator)
	roots: [dynamic]v.Value
	roots = make([dynamic]v.Value, context.temp_allocator)

	position := 0
	for position < len(text) {
		next := strings.index_byte(text[position:], '<')
		if next < 0 {
			dom_xml_append_text(&stack, &roots, text[position:], allocator)
			break
		}
		if next > 0 {
			dom_xml_append_text(&stack, &roots, text[position:position + next], allocator)
		}
		position += next
		rest := text[position:]
		switch {
		case strings.has_prefix(rest, "<!--"):
			end := strings.index(rest, "-->")
			if end < 0 {
				return v.Value(0), "XML parse error: unterminated comment"
			}
			position += end + 3
		case strings.has_prefix(rest, "<![CDATA["):
			end := strings.index(rest, "]]>")
			if end < 0 {
				return v.Value(0), "XML parse error: unterminated CDATA section"
			}
			dom_xml_append_text(&stack, &roots, rest[9:end], allocator)
			position += end + 3
		case strings.has_prefix(rest, "<?"):
			end := strings.index(rest, "?>")
			if end < 0 {
				return v.Value(0), "XML parse error: unterminated declaration"
			}
			position += end + 2
		case strings.has_prefix(rest, "<!"):
			end := strings.index_byte(rest, '>')
			if end < 0 {
				return v.Value(0), "XML parse error: unterminated declaration"
			}
			position += end + 1
		case strings.has_prefix(rest, "</"):
			end := strings.index_byte(rest, '>')
			if end < 0 {
				return v.Value(0), "XML parse error: unterminated end tag"
			}
			if len(stack) == 0 {
				return v.Value(0), "end tag without start tag"
			}
			name := dom_xml_local_name(strings.trim_space(rest[2:end]))
			frame := pop(&stack)
			if frame.tag != name {
				return v.Value(0), "XML parse error: mismatched end tag"
			}
			node := dom_element_value(frame.tag, frame.attrs[:], frame.children[:], allocator)
			if len(stack) > 0 {
				append(&stack[len(stack) - 1].children, node)
			} else {
				append(&roots, node)
			}
			position += end + 1
		case:
			consumed, self_closing, tag, attrs, parse_error := dom_xml_parse_start_tag(rest, allocator)
			if parse_error != "" {
				return v.Value(0), parse_error
			}
			if self_closing {
				node := dom_element_value(tag, attrs, nil, allocator)
				if len(stack) > 0 {
					append(&stack[len(stack) - 1].children, node)
				} else {
					append(&roots, node)
				}
			} else {
				frame := Xml_Frame {
					tag   = tag,
					attrs = make([dynamic]v.Map_Entry, context.temp_allocator),
				}
				frame.children = make([dynamic]v.Value, context.temp_allocator)
				append(&frame.attrs, ..attrs)
				append(&stack, frame)
			}
			position += consumed
		}
	}

	if len(stack) > 0 {
		return v.Value(0), "unclosed XML element"
	}
	switch len(roots) {
	case 0:
		return v.Value(0), "XML did not contain a node"
	case 1:
		return roots[0], ""
	}
	return v.value_list(allocator, roots[:]), ""
}

// Parses one start tag. Returns the bytes consumed, whether the tag closes
// itself, the local tag name, and its attributes.
@(private)
dom_xml_parse_start_tag :: proc(
	rest: string,
	allocator: mem.Allocator,
) -> (
	consumed: int,
	self_closing: bool,
	tag: string,
	attrs: []v.Map_Entry,
	parse_error: string,
) {
	position := 1
	name_start := position
	for position < len(rest) && dom_xml_name_char(rest[position]) {
		position += 1
	}
	if position == name_start {
		return 0, false, "", nil, "XML parse error: invalid tag name"
	}
	tag = dom_xml_local_name(rest[name_start:position])

	collected: [dynamic]v.Map_Entry
	collected = make([dynamic]v.Map_Entry, context.temp_allocator)
	for {
		for position < len(rest) && dom_xml_is_space(rest[position]) {
			position += 1
		}
		if position >= len(rest) {
			return 0, false, "", nil, "XML parse error: unterminated start tag"
		}
		if strings.has_prefix(rest[position:], "/>") {
			return position + 2, true, tag, collected[:], ""
		}
		if rest[position] == '>' {
			return position + 1, false, tag, collected[:], ""
		}
		attr_start := position
		for position < len(rest) && dom_xml_name_char(rest[position]) {
			position += 1
		}
		if position == attr_start {
			return 0, false, "", nil, "XML parse error: invalid attribute name"
		}
		attr_name := dom_xml_local_name(rest[attr_start:position])
		for position < len(rest) && dom_xml_is_space(rest[position]) {
			position += 1
		}
		if position >= len(rest) || rest[position] != '=' {
			return 0, false, "", nil, "XML parse error: attribute without a value"
		}
		position += 1
		for position < len(rest) && dom_xml_is_space(rest[position]) {
			position += 1
		}
		if position >= len(rest) || (rest[position] != '"' && rest[position] != '\'') {
			return 0, false, "", nil, "XML parse error: attribute value is not quoted"
		}
		quote := rest[position]
		position += 1
		value_start := position
		for position < len(rest) && rest[position] != quote {
			position += 1
		}
		if position >= len(rest) {
			return 0, false, "", nil, "XML parse error: unterminated attribute value"
		}
		decoded := dom_xml_decode_entities(rest[value_start:position])
		append(&collected, v.Map_Entry {
			key   = v.value_string(allocator, attr_name),
			value = v.value_string(allocator, decoded),
		})
		position += 1
	}
}

// Appends text to the innermost open element, or to the roots when no element
// is open. Whitespace-only text is skipped, matching quick-xml handling.
@(private)
dom_xml_append_text :: proc(
	stack: ^[dynamic]Xml_Frame,
	roots: ^[dynamic]v.Value,
	raw: string,
	allocator: mem.Allocator,
) {
	decoded := dom_xml_decode_entities(raw)
	if strings.trim_space(decoded) == "" {
		return
	}
	node := dom_text_value(decoded, allocator)
	if len(stack) > 0 {
		append(&stack[len(stack) - 1].children, node)
	} else {
		append(roots, node)
	}
}

// Decodes the predefined entities and numeric character references. Unknown
// entities are kept verbatim. The result lives until the temp arena resets;
// dom_xml_decode_entities_into (xml_stream.odin) takes an allocator for
// longer-lived output.
@(private)
dom_xml_decode_entities :: proc(text: string) -> string {
	return dom_xml_decode_entities_into(text, context.temp_allocator)
}

@(private)
dom_xml_write_decoded :: proc(builder: ^strings.Builder, text: string) {
	position := 0
	for position < len(text) {
		if text[position] != '&' {
			strings.write_byte(builder, text[position])
			position += 1
			continue
		}
		semicolon := strings.index_byte(text[position:], ';')
		if semicolon < 0 {
			strings.write_byte(builder, '&')
			position += 1
			continue
		}
		entity := text[position + 1:position + semicolon]
		switch entity {
		case "amp":
			strings.write_byte(builder, '&')
		case "lt":
			strings.write_byte(builder, '<')
		case "gt":
			strings.write_byte(builder, '>')
		case "quot":
			strings.write_byte(builder, '"')
		case "apos":
			strings.write_byte(builder, '\'')
		case:
			if strings.has_prefix(entity, "#") {
				digits := entity[1:]
				base := 10
				if strings.has_prefix(digits, "x") || strings.has_prefix(digits, "X") {
					digits = digits[1:]
					base = 16
				}
				codepoint, parsed := strconv.parse_int(digits, base)
				r := rune(codepoint)
				if !parsed || !utf8.valid_rune(r) {
					strings.write_byte(builder, '&')
					position += 1
					continue
				}
				strings.write_rune(builder, r)
			} else {
				strings.write_byte(builder, '&')
				position += 1
				continue
			}
		}
		position += semicolon + 1
	}
}

@(private)
dom_xml_is_space :: proc(c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

@(private)
dom_xml_name_start :: proc(c: u8) -> bool {
	return c == '_' || c == ':' || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
}

@(private)
dom_xml_name_char :: proc(c: u8) -> bool {
	return dom_xml_name_start(c) || c == '-' || c == '.' || (c >= '0' && c <= '9')
}

// Strips a namespace prefix, matching quick-xml's `local_name`.
@(private)
dom_xml_local_name :: proc(name: string) -> string {
	if colon := strings.index_byte(name, ':'); colon >= 0 {
		return name[colon + 1:]
	}
	return name
}
