package bookcheck

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import k "../../mica/kernel"
import r "../../mica/runtime"
import v "../../mica/var"

// One step of a `mica-session` block (draft-ndn-mica-snippets-00,
// "Sessions"): a directive line, optionally with an argument, and the
// two-space-indented body lines under it.
Step_Kind :: enum {
	Filein,
	Replace,
	Restart,
	Eval,
	Expect,
	Expect_Error,
}

Step :: struct {
	line: int,
	kind: Step_Kind,
	arg:  string, // unit for filein/replace, code for expect-error
	body: string,
}

// Splits a session into steps. Reports the first malformed line.
parse_session :: proc(text: string, allocator := context.allocator) -> ([dynamic]Step, string) {
	steps := make([dynamic]Step, allocator)
	body := strings.builder_make(allocator)
	rest := text
	line := 0
	for raw in strings.split_lines_iterator(&rest) {
		line += 1
		if raw == "" {
			continue
		}
		if strings.has_prefix(raw, "  ") {
			if len(steps) == 0 {
				return steps, fmt.aprintf("line %d: body before any step", line, allocator = allocator)
			}
			strings.write_string(&body, raw[2:])
			strings.write_byte(&body, '\n')
			continue
		}
		if len(steps) > 0 {
			steps[len(steps) - 1].body = strings.clone(strings.to_string(body), allocator)
			strings.builder_reset(&body)
		}
		directive, _, arg := strings.partition(strings.trim_space(raw), " ")
		step := Step{line = line, arg = strings.trim_space(arg)}
		switch directive {
		case "filein":
			step.kind = .Filein
		case "replace":
			step.kind = .Replace
		case "restart":
			step.kind = .Restart
		case "eval":
			step.kind = .Eval
		case "expect":
			step.kind = .Expect
		case "expect-error":
			step.kind = .Expect_Error
		case:
			return steps, fmt.aprintf("line %d: unknown step %q", line, directive, allocator = allocator)
		}
		if (step.kind == .Filein || step.kind == .Replace || step.kind == .Expect_Error) && step.arg == "" {
			return steps, fmt.aprintf("line %d: %s needs an argument", line, directive, allocator = allocator)
		}
		append(&steps, step)
	}
	if len(steps) > 0 {
		steps[len(steps) - 1].body = strings.clone(strings.to_string(body), allocator)
	}
	return steps, ""
}

// Runs a session against one world backed by a new store in `scratch_dir`.
// Returns "" on success, or why the first failing step failed.
run_session :: proc(steps: []Step, scratch_dir: string) -> string {
	store := fmt.tprintf("%s/store", scratch_dir)
	kernel := new(k.Kernel)
	k.kernel_init(kernel)
	world, start := r.world_start(kernel, nil, runtime.heap_allocator(), r.World_Config{store_path = store})
	if !start.ok {
		k.kernel_destroy(kernel)
		free(kernel)
		return fmt.tprintf("start: %s", start.message)
	}
	defer {
		r.world_destroy(world)
		k.kernel_destroy(kernel)
		free(kernel)
	}
	last: r.Task_Outcome
	has_last := false
	for step, index in steps {
		next_is_error := index + 1 < len(steps) && steps[index + 1].kind == .Expect_Error
		switch step.kind {
		case .Filein, .Replace:
			path := fmt.tprintf("%s/step-%d.mica", scratch_dir, step.line)
			if err := os.write_entire_file(path, transmute([]u8)step.body); err != nil {
				return fmt.tprintf("line %d: cannot write the unit source", step.line)
			}
			mode := r.Filein_Mode.Add if step.kind == .Filein else r.Filein_Mode.Replace
			last = r.world_filein(world, []string{path}, strings.trim_prefix(step.arg, ":"), mode)
			has_last = true
		case .Eval:
			last = r.world_eval(world, step.body)
			has_last = true
		case .Restart:
			if !r.world_checkpoint(world) {
				return fmt.tprintf("line %d: checkpoint before restart failed", step.line)
			}
			r.world_destroy(world)
			k.kernel_destroy(kernel)
			k.kernel_init(kernel)
			world, start = r.world_start(kernel, nil, runtime.heap_allocator(), r.World_Config{store_path = store})
			if !start.ok {
				world = nil
				return fmt.tprintf("line %d: restart: %s", step.line, start.message)
			}
			has_last = false
			continue
		case .Expect:
			if !has_last {
				return fmt.tprintf("line %d: expect follows no eval", step.line)
			}
			expression := strings.trim_space(step.body)
			wanted := r.world_eval(world, fmt.tprintf("return %s", expression))
			if wanted.kind != .Complete {
				return fmt.tprintf("line %d: expect expression %q did not evaluate: %s", step.line, expression, outcome_detail(wanted))
			}
			if !v.value_eq(last.value, wanted.value) {
				return fmt.tprintf(
					"line %d: expected %s (%v), got %s (%v)",
					step.line,
					r.world_value_literal(world, wanted.value, context.temp_allocator),
					v.value_kind(wanted.value),
					r.world_value_literal(world, last.value, context.temp_allocator),
					v.value_kind(last.value),
				)
			}
			continue
		case .Expect_Error:
			if !has_last {
				return fmt.tprintf("line %d: expect-error follows no step", step.line)
			}
			if last.kind != .Aborted {
				return fmt.tprintf("line %d: expected error %s, but the step %v", step.line, step.arg, last.kind)
			}
			if got := error_code(last); got != step.arg {
				return fmt.tprintf("line %d: expected error %s, got %s", step.line, step.arg, outcome_detail(last))
			}
			continue
		}
		if !next_is_error && last.kind != .Complete {
			return fmt.tprintf("line %d: %v: %s", step.line, last.kind, outcome_detail(last))
		}
	}
	return ""
}

// Checks one tangled `mica-session` file.
run_session_file :: proc(path: string) -> int {
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		fmt.eprintf("cannot read %s\n", path)
		return 2
	}
	steps, problem := parse_session(string(data))
	if problem != "" {
		fmt.printf("FAIL %s: %s\n", path, problem)
		return 1
	}
	base, dir_err := os.temp_dir(context.allocator)
	if dir_err != nil {
		fmt.eprintf("cannot resolve a temporary directory\n")
		return 2
	}
	scratch_dir := fmt.aprintf("%s/bookcheck-session-%d", base, os.get_pid())
	os.remove_all(scratch_dir)
	if err := os.make_directory_all(scratch_dir); err != nil {
		fmt.eprintf("cannot create %s\n", scratch_dir)
		return 2
	}
	defer os.remove_all(scratch_dir)
	if failure := run_session(steps[:], scratch_dir); failure != "" {
		fmt.printf("FAIL %s: %s\n", path, failure)
		return 1
	}
	return 0
}
