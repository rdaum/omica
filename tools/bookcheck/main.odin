// Runs Mica examples from a book or from tangled RFC evidence.
//
//	odin run tools/bookcheck -- [--known FILE] [--profile KEY=VALUE]... <book-src-dir>
//	odin run tools/bookcheck -- [--profile KEY=VALUE]... --block FILE
//
// Every Mica block must parse. Eval and filein blocks load into a fresh world
// and their top-level code must complete, or, when an `expect-error` block
// follows, abort with that error code. An `expect` block holds a Mica
// expression the result must equal canonically. A block whose `when=` does not
// hold under the profile reports N/A. Info strings and expected results follow
// draft-ndn-snippet-attributes-00 and draft-ndn-mica-snippets-00.
//
// Book mode: the known-failures file lists `path:line` of examples omica does
// not pass yet, relative to the book directory. The run fails on a failure that
// is not listed, and on a listed example that now passes, so the list only
// shrinks.
//
// Block mode runs one tangled file (rfc-tangle) with its sidecars: FILE.attrs
// (mode=, flags=, when=), FILE.expect and FILE.expect-error. It exits 0 on a
// pass or N/A, 1 on a failure, and 2 when it cannot run.
//
// The profile starts from RFC_PROFILE (space-separated KEY=VALUE), then
// --profile options; `impl` defaults to `omica`.
package bookcheck

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import c "../../mica/compiler"
import k "../../mica/kernel"
import r "../../mica/runtime"
import v "../../mica/var"

USAGE :: "usage: bookcheck [--known FILE] [--profile KEY=VALUE]... <book-src-dir>\n" +
	"       bookcheck [--profile KEY=VALUE]... --block FILE\n" +
	"       bookcheck --session FILE\n"

Verdict :: enum {
	Pass,
	Fail,
	Not_Applicable,
}

main :: proc() {
	known_path, book, block_path, session_path := "", "", "", ""
	profile := make(map[string]string)
	if env, found := os.lookup_env("RFC_PROFILE", context.allocator); found {
		add_facts(&profile, env)
	}
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch {
		case args[i] == "--known" && i + 1 < len(args):
			i += 1
			known_path = args[i]
		case args[i] == "--profile" && i + 1 < len(args):
			i += 1
			add_facts(&profile, args[i])
		case args[i] == "--block" && i + 1 < len(args):
			i += 1
			block_path = args[i]
		case args[i] == "--session" && i + 1 < len(args):
			i += 1
			session_path = args[i]
		case book == "" && !strings.has_prefix(args[i], "--"):
			book = args[i]
		case:
			fmt.eprintf(USAGE)
			os.exit(2)
		}
	}
	if "impl" not_in profile {
		profile["impl"] = "omica"
	}

	scratch, dir_err := os.temp_dir(context.allocator)
	if dir_err != nil {
		fmt.eprintf("cannot resolve a temporary directory\n")
		os.exit(2)
	}
	scratch_file := fmt.aprintf("%s/bookcheck-%d.mica", scratch, os.get_pid())

	status := 2
	switch {
	case session_path != "" && block_path == "" && book == "" && known_path == "":
		status = run_session_file(session_path)
	case block_path != "" && book == "" && known_path == "":
		status = run_one(block_path, profile, scratch_file)
	case block_path == "" && book != "":
		status = run_book(book, known_path, profile, scratch_file)
	case:
		fmt.eprintf(USAGE)
	}
	os.remove(scratch_file)
	os.exit(status)
}

@(private)
add_facts :: proc(profile: ^map[string]string, text: string) {
	for item in strings.fields(text, context.allocator) {
		key, _, value := strings.partition(item, "=")
		profile[key] = value
	}
}

@(private)
run_book :: proc(book, known_path: string, profile: map[string]string, scratch_file: string) -> int {
	known := make(map[string]bool)
	if known_path != "" {
		data, read_err := os.read_entire_file(known_path, context.allocator)
		if read_err != nil {
			fmt.eprintf("cannot read %s\n", known_path)
			return 2
		}
		text := string(data)
		for line in strings.split_lines_iterator(&text) {
			entry := strings.trim_space(line)
			if entry != "" && !strings.has_prefix(entry, "#") {
				known[entry] = true
			}
		}
	}

	// Directory entries come back as absolute paths, so the book root must be
	// absolute too for locations to be relative to it.
	root, abs_err := filepath.abs(book, context.allocator)
	if abs_err != nil {
		fmt.eprintf("cannot resolve %s\n", book)
		return 2
	}
	files := make([dynamic]string)
	collect_markdown(root, &files)
	slice.sort(files[:])

	checked, passed, known_failed, skipped := 0, 0, 0, 0
	unexpected, stale := 0, 0
	for path in files {
		relative, rel_err := filepath.rel(root, path, context.allocator)
		if rel_err != .None {
			fmt.eprintf("cannot relate %s to %s\n", path, root)
			return 2
		}
		data, read_err := os.read_entire_file(path, context.allocator)
		if read_err != nil {
			fmt.eprintf("cannot read %s\n", path)
			return 2
		}
		blocks, closed := extract_blocks(string(data), context.allocator)
		if !closed {
			fmt.printf("FAIL %s: unclosed code fence\n", relative)
			unexpected += 1
		}
		for block in blocks {
			location := fmt.aprintf("%s:%d", relative, block.line)
			checked += 1
			message, verdict := check_block(block, profile, scratch_file)
			is_known := known[location]
			switch {
			case verdict == .Not_Applicable:
				skipped += 1
			case verdict == .Pass && is_known:
				fmt.printf("STALE %s: passes now; remove it from the known failures\n", location)
				stale += 1
			case verdict == .Pass:
				passed += 1
			case is_known:
				fmt.printf("known %s: %s\n", location, message)
				known_failed += 1
			case:
				fmt.printf("FAIL %s: %s\n", location, message)
				unexpected += 1
			}
			free_all(context.temp_allocator)
		}
	}
	fmt.printf(
		"bookcheck: %d examples, %d pass, %d n/a, %d known failures, %d unexpected failures, %d stale\n",
		checked,
		passed,
		skipped,
		known_failed,
		unexpected,
		stale,
	)
	return 1 if unexpected > 0 || stale > 0 else 0
}

// Runs one tangled block with its sidecars.
@(private)
run_one :: proc(path: string, profile: map[string]string, scratch_file: string) -> int {
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		fmt.eprintf("cannot read %s\n", path)
		return 2
	}
	block := Block{line = 1, mode = .Parse, source = string(data)}
	if attrs, found := read_sidecar(path, ".attrs"); found {
		for line in strings.split_lines(attrs, context.allocator) {
			key, _, value := strings.partition(line, "=")
			switch key {
			case "mode", "flags":
				for name in strings.split(value, ",", context.allocator) {
					if named, known := mode_named(name); known {
						block.mode = named
					}
				}
			case "when":
				block.condition = value
			}
		}
	}
	block.expect, block.has_expect = read_sidecar(path, ".expect")
	block.expect_error, block.has_expect_error = read_sidecar(path, ".expect-error")
	message, verdict := check_block(block, profile, scratch_file)
	switch verdict {
	case .Pass:
		return 0
	case .Not_Applicable:
		fmt.printf("n/a: %s\n", block.condition)
		return 0
	case .Fail:
		fmt.printf("FAIL %s: %s\n", path, message)
	}
	return 1
}

@(private)
read_sidecar :: proc(path, suffix: string) -> (string, bool) {
	data, err := os.read_entire_file(strings.concatenate({path, suffix}, context.allocator), context.allocator)
	if err != nil {
		return "", false
	}
	return string(data), true
}

@(private)
collect_markdown :: proc(directory: string, files: ^[dynamic]string) {
	handle, open_err := os.open(directory)
	if open_err != nil {
		fmt.eprintf("cannot open %s\n", directory)
		os.exit(2)
	}
	defer os.close(handle)
	entries, read_err := os.read_dir(handle, -1, context.allocator)
	if read_err != nil {
		fmt.eprintf("cannot read %s\n", directory)
		os.exit(2)
	}
	for entry in entries {
		if entry.type == .Directory {
			collect_markdown(entry.fullpath, files)
		} else if strings.has_suffix(entry.name, ".md") {
			append(files, entry.fullpath)
		}
	}
}

// Parses the block, and for eval and filein blocks runs it in a fresh world
// and checks what it produced.
@(private)
check_block :: proc(block: Block, profile: map[string]string, scratch_file: string) -> (string, Verdict) {
	if !when_holds(block.condition, profile) {
		return "", .Not_Applicable
	}
	_, errors := c.parse_program(block.source, context.temp_allocator)
	if len(errors) > 0 {
		return fmt.tprintf("parse: %s", errors[0].message), .Fail
	}
	if block.mode == .Parse {
		return "", .Pass
	}
	if write_err := os.write_entire_file(scratch_file, transmute([]u8)block.source); write_err != nil {
		return "cannot write the example to a temporary file", .Fail
	}
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	// World threads share this allocator, so it must be thread-safe.
	world, start := r.world_start(&kernel, []string{scratch_file}, runtime.heap_allocator())
	if !start.ok {
		return fmt.tprintf("load: %s", start.message), .Fail
	}
	defer r.world_destroy(world)
	if world.entry == 0 {
		if block.has_expect || block.has_expect_error {
			return "the example has no top-level code to produce a result", .Fail
		}
		return "", .Pass
	}
	outcome := r.world_wait(world, world.entry)
	if block.has_expect_error {
		want := strings.trim_space(block.expect_error)
		if outcome.kind != .Aborted {
			return fmt.tprintf("expected error %s, but the task %v", want, outcome.kind), .Fail
		}
		if got := error_code(outcome); got != want {
			return fmt.tprintf("expected error %s, got %s", want, outcome_detail(outcome)), .Fail
		}
		return "", .Pass
	}
	if outcome.kind != .Complete {
		return fmt.tprintf("%v: %s", outcome.kind, outcome_detail(outcome)), .Fail
	}
	if block.has_expect {
		expression := strings.trim_space(block.expect)
		wanted := r.world_eval(world, fmt.tprintf("return %s", expression))
		if wanted.kind != .Complete {
			return fmt.tprintf("expect expression %q did not evaluate: %s", expression, outcome_detail(wanted)), .Fail
		}
		if !v.value_eq(outcome.value, wanted.value) {
			// Kinds are shown because some values of different kinds print
			// alike (the float 1.0 prints as 1).
			return fmt.tprintf(
				"expected %s (%v), got %s (%v)",
				r.world_value_literal(world, wanted.value, context.temp_allocator),
				v.value_kind(wanted.value),
				r.world_value_literal(world, outcome.value, context.temp_allocator),
				v.value_kind(outcome.value),
			), .Fail
		}
	}
	return "", .Pass
}

@(private)
error_code :: proc(outcome: r.Task_Outcome) -> string {
	if header, is_error := v.value_as_error(outcome.error); is_error {
		code, _ := v.symbol_name(header.code)
		return code
	}
	return ""
}

@(private)
outcome_detail :: proc(outcome: r.Task_Outcome) -> string {
	if header, is_error := v.value_as_error(outcome.error); is_error {
		code, _ := v.symbol_name(header.code)
		if header.has_message && header.message != "" {
			return fmt.tprintf("%s: %s", code, header.message)
		}
		return code
	}
	return outcome.message
}
