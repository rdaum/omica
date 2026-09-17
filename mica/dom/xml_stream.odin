// Streaming XML tag scanner for inputs too large to build as a DOM value
// (tools/owlstream reads a 250MB OWL dump through it). It finds tag
// boundaries without building a tree; the caller tracks depth. Comments,
// declarations and processing instructions never surface as tags.
package dom

import "core:mem"
import "core:strings"

Dom_Xml_Tag_Kind :: enum {
	Open,
	Close,
	Self_Close,
}

// One `<...>` in the input.
Dom_Xml_Tag :: struct {
	kind:  Dom_Xml_Tag_Kind,
	// Byte offsets of `<` and just past `>`.
	start: int,
	end:   int,
	// Raw tag name (with namespace prefix); empty for a close tag.
	name:  string,
	// text[start:end], for attribute lookup.
	head:  string,
}

@(private)
DOM_XML_CDATA_OPEN :: "<![CDATA["
@(private)
DOM_XML_CDATA_CLOSE :: "]]>"

// Finds the next tag at or after pos. Returns ok=false at end of input or on
// an unterminated tag.
dom_xml_next_tag :: proc(text: string, pos: int) -> (tag: Dom_Xml_Tag, ok: bool) {
	i := max(pos, 0)
	for i < len(text) {
		rel := strings.index_byte(text[i:], '<')
		if rel < 0 || i + rel + 1 >= len(text) {
			return {}, false
		}
		i += rel
		// Comments, CDATA and processing instructions are skipped whole:
		// a `<` inside them is not a tag.
		skip_to := ""
		switch {
		case strings.has_prefix(text[i:], "<!--"):
			skip_to = "-->"
		case strings.has_prefix(text[i:], DOM_XML_CDATA_OPEN):
			skip_to = DOM_XML_CDATA_CLOSE
		case text[i + 1] == '?':
			skip_to = "?>"
		case text[i + 1] == '!':
			skip_to = ">"
		}
		if skip_to != "" {
			stop := strings.index(text[i:], skip_to)
			if stop < 0 {
				return {}, false
			}
			i += stop + len(skip_to)
			continue
		}
		if text[i + 1] == '/' {
			tag.kind = .Close
		} else {
			tag.kind = .Open
		}
		gt := strings.index_byte(text[i:], '>')
		if gt < 0 {
			return {}, false
		}
		tag.start = i
		tag.end = i + gt + 1
		tag.head = text[tag.start:tag.end]
		if tag.kind == .Open {
			if text[tag.end - 2] == '/' {
				tag.kind = .Self_Close
			}
			j := 1
			for j < len(tag.head) && dom_xml_name_char(tag.head[j]) {
				j += 1
			}
			tag.name = tag.head[1:j]
		}
		return tag, true
	}
	return {}, false
}

// Extracts the value of a double-quoted attribute from a tag head. The value
// is returned raw (entities undecoded) as a slice of head.
dom_xml_attr_value :: proc(head: string, name: string) -> (value: string, ok: bool) {
	rest := head
	for {
		at := strings.index(rest, name)
		if at < 0 {
			return "", false
		}
		after := rest[at + len(name):]
		if at > 0 && dom_xml_is_space(rest[at - 1]) && strings.has_prefix(after, `="`) {
			after = after[2:]
			end := strings.index_byte(after, '"')
			if end < 0 {
				return "", false
			}
			return after[:end], true
		}
		rest = rest[at + len(name):]
	}
}

// Returns the text between an open tag and its matching close, and the
// offset just past that close. A CDATA section is unwrapped and taken
// verbatim, with is_cdata set: its content is not entity-encoded and any
// markup inside it is content, not structure, so it need not balance.
dom_xml_element_text :: proc(
	text: string,
	open: Dom_Xml_Tag,
) -> (
	body: string,
	is_cdata: bool,
	end: int,
	ok: bool,
) {
	rest := text[open.end:]
	if strings.has_prefix(rest, DOM_XML_CDATA_OPEN) {
		stop := strings.index(rest, DOM_XML_CDATA_CLOSE)
		if stop < 0 {
			return "", false, 0, false
		}
		close, close_ok := dom_xml_next_tag(text, open.end + stop + len(DOM_XML_CDATA_CLOSE))
		if !close_ok || close.kind != .Close {
			return "", false, 0, false
		}
		return rest[len(DOM_XML_CDATA_OPEN):stop], true, close.end, true
	}
	depth := 1
	pos := open.end
	for {
		tag, tag_ok := dom_xml_next_tag(text, pos)
		if !tag_ok {
			return "", false, 0, false
		}
		pos = tag.end
		switch tag.kind {
		case .Open:
			depth += 1
		case .Close:
			depth -= 1
			if depth == 0 {
				return text[open.end:tag.start], false, tag.end, true
			}
		case .Self_Close:
		}
	}
}

// Skips from just past an open tag to just past its matching close tag,
// returning that offset. A self-closing tag has no body.
dom_xml_skip_element :: proc(text: string, open: Dom_Xml_Tag) -> (end: int, ok: bool) {
	if open.kind == .Self_Close {
		return open.end, true
	}
	_, _, end, ok = dom_xml_element_text(text, open)
	return end, ok
}

// Decodes the predefined entities and numeric character references into
// allocator; unknown entities are kept verbatim. Text without an `&` is
// returned as is, not copied.
dom_xml_decode_entities_into :: proc(text: string, allocator: mem.Allocator) -> string {
	if !strings.contains(text, "&") {
		return text
	}
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	dom_xml_write_decoded(&builder, text)
	return strings.to_string(builder)
}
