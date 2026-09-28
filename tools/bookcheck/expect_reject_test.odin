package bookcheck

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_expect_reject :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	base, _ := os.temp_dir(context.temp_allocator)
	scratch := fmt.tprintf("%s/bookcheck-reject-test.mica", base)
	defer os.remove(scratch)
	profile := make(map[string]string, context.temp_allocator)
	refused := Block{mode = .Eval, source = "return (1 +\n", has_expect_reject = true}
	_, verdict := check_block(refused, profile, scratch)
	testing.expect_value(t, verdict, Verdict.Pass)
	runs := Block{mode = .Eval, source = "return 1\n", has_expect_reject = true}
	message, ran := check_block(runs, profile, scratch)
	testing.expect_value(t, ran, Verdict.Fail)
	testing.expect(t, strings.contains(message, "loaded"), message)
	parses := Block{mode = .Parse, source = "return 1\n", has_expect_reject = true}
	_, parsed := check_block(parses, profile, scratch)
	testing.expect_value(t, parsed, Verdict.Fail)
}
