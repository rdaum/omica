package bookcheck

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_parse_session_steps :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	text := "filein :counter\n  make_relation(:Count, 1)\n  assert Count(1)\nrestart\neval\n  return 1\nexpect\n  1\nexpect-error E_INVARG\n"
	steps, problem := parse_session(text, context.temp_allocator)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, len(steps), 5)
	if len(steps) == 5 {
		testing.expect_value(t, steps[0].kind, Step_Kind.Filein)
		testing.expect_value(t, steps[0].arg, ":counter")
		testing.expect_value(t, steps[0].body, "make_relation(:Count, 1)\nassert Count(1)\n")
		testing.expect_value(t, steps[1].kind, Step_Kind.Restart)
		testing.expect_value(t, steps[3].body, "1\n")
		testing.expect_value(t, steps[4].arg, "E_INVARG")
	}
}

@(test)
test_parse_session_rejects_malformed :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	_, unknown := parse_session("run\n  x\n", context.temp_allocator)
	testing.expect(t, strings.contains(unknown, "unknown step"), unknown)
	_, orphan := parse_session("  return 1\n", context.temp_allocator)
	testing.expect(t, strings.contains(orphan, "body before any step"), orphan)
	_, bare := parse_session("filein\n  x\n", context.temp_allocator)
	testing.expect(t, strings.contains(bare, "needs an argument"), bare)
}

@(private = "file")
session_verdict :: proc(t: ^testing.T, name, text: string) -> string {
	steps, problem := parse_session(text, context.temp_allocator)
	testing.expect_value(t, problem, "")
	base, _ := os.temp_dir(context.temp_allocator)
	dir := fmt.tprintf("%s/bookcheck-session-test-%s", base, name)
	os.remove_all(dir)
	os.make_directory_all(dir)
	defer os.remove_all(dir)
	return run_session(steps[:], dir)
}

@(test)
test_session_survives_restart :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	failure := session_verdict(t, "pass", "filein :counter\n  make_relation(:Count, 1)\n  assert Count(1)\nrestart\neval\n  return Count(?n)\nexpect\n  [:n] {[1]}\neval\n  raise E_INVARG\nexpect-error E_INVARG\n")
	testing.expect_value(t, failure, "")
	// A restart boots from the store: volatile facts are gone afterwards.
	rebooted := session_verdict(t, "reboot", "filein :u\n  make_relation(:Seen, 1, :volatile)\n  assert Seen(1)\neval\n  return Seen(?x)\nexpect\n  [:x] {[1]}\nrestart\neval\n  return Seen(?x)\nexpect\n  [:x] {}\n")
	testing.expect_value(t, rebooted, "")
}

@(test)
test_session_reports_failures :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	wrong := session_verdict(t, "wrong", "eval\n  return 1\nexpect\n  2\n")
	testing.expect(t, strings.contains(wrong, "line 3: expected 2"), wrong)
	unraised := session_verdict(t, "unraised", "eval\n  return 1\nexpect-error E_INVARG\n")
	testing.expect(t, strings.contains(unraised, "expected error E_INVARG"), unraised)
	aborted := session_verdict(t, "aborted", "eval\n  raise E_INVARG\n")
	testing.expect(t, strings.contains(aborted, "line 1: Aborted"), aborted)
	lost := session_verdict(t, "lost", "filein :u\n  make_relation(:Kept, 1)\n  assert Kept(1)\nrestart\neval\n  return Kept(?x)\nexpect\n  [:x] {}\n")
	testing.expect(t, strings.contains(lost, "line 7: expected"), lost)
}
