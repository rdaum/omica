package bookcheck

import "core:mem"
import "core:strings"

// How a fenced Mica example is checked, following the Rust book harness
// (crates/runtime/tests/book_examples.rs): Parse blocks must parse, Eval
// blocks run as one task that must complete, and Filein blocks load as a file.
Mode :: enum {
	Parse,
	Eval,
	Filein,
}

// A Mica block and what the fences after it say it produces. Info strings
// follow draft-ndn-snippet-attributes-00: `mica` with an optional legacy
// flag (`mica,eval`) or `mode=`, an optional `@R-slug`, and `key=value`
// attributes. `condition` is the `when=` value.
Block :: struct {
	line:             int, // line of the opening fence, 1-based
	mode:             Mode,
	source:           string,
	condition:        string,
	expect:           string,
	has_expect:       bool,
	expect_error:     string,
	has_expect_error: bool,
	has_expect_reject: bool, // refused before any task runs
}

// Returns the Mica blocks in `markdown`, with any `expect` or `expect-error`
// block that follows one (blank lines between) attached to it. Reports false
// when a fence is never closed.
extract_blocks :: proc(markdown: string, allocator: mem.Allocator) -> ([dynamic]Block, bool) {
	blocks := make([dynamic]Block, allocator)
	lines := strings.split_lines(markdown, allocator)
	// Index of the Mica block an expect fence may attach to; -1 when prose or
	// another fence intervened.
	owner := -1
	i := 0
	for i < len(lines) {
		text := lines[i]
		if !strings.has_prefix(text, "```") {
			if strings.trim_space(text) != "" {
				owner = -1
			}
			i += 1
			continue
		}
		info := text[3:]
		start := i + 1
		j := start
		for j < len(lines) && lines[j] != "```" {
			j += 1
		}
		if j >= len(lines) {
			return blocks, false
		}
		body := strings.join(lines[start:j], "\n", allocator)
		if j > start {
			body = strings.concatenate({body, "\n"}, allocator)
		}
		type, mode, condition, is_mica := parse_info(info)
		switch {
		case is_mica:
			append(&blocks, Block{line = i + 1, mode = mode, source = body, condition = condition})
			owner = len(blocks) - 1
		case owner >= 0 && type == "expect":
			blocks[owner].expect = body
			blocks[owner].has_expect = true
		case owner >= 0 && type == "expect-error":
			blocks[owner].expect_error = body
			blocks[owner].has_expect_error = true
		case owner >= 0 && type == "expect-reject":
			blocks[owner].has_expect_reject = true
		case:
			owner = -1
		}
		i = j + 1
	}
	return blocks, true
}

// Reads an info string. `is_mica` is false for other types and for info
// strings that do not follow the grammar.
@(private)
parse_info :: proc(info: string) -> (type: string, mode: Mode, condition: string, is_mica: bool) {
	items := strings.fields(info, context.temp_allocator)
	if len(items) == 0 {
		return
	}
	head := strings.split(items[0], ",", context.temp_allocator)
	type = head[0]
	mode = .Parse
	for flag in head[1:] {
		if flag_mode, known := mode_named(flag); known {
			mode = flag_mode
		}
	}
	for item in items[1:] {
		if strings.has_prefix(item, "@R-") {
			continue
		}
		key, _, value := strings.partition(item, "=")
		switch key {
		case "mode":
			named, known := mode_named(value)
			if !known {
				return type, mode, condition, false
			}
			mode = named
		case "when":
			condition = value
		}
	}
	return type, mode, condition, type == "mica"
}

@(private)
mode_named :: proc(name: string) -> (Mode, bool) {
	switch name {
	case "parse":
		return .Parse, true
	case "eval":
		return .Eval, true
	case "filein":
		return .Filein, true
	}
	return .Parse, false
}

// Reports whether every `key:value` in a `when=` condition matches the
// profile. An empty condition always holds.
when_holds :: proc(condition: string, profile: map[string]string) -> bool {
	if condition == "" {
		return true
	}
	rest := condition
	for part in strings.split_iterator(&rest, ",") {
		key, _, value := strings.partition(part, ":")
		if profile[key] != value {
			return false
		}
	}
	return true
}
