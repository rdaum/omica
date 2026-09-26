package mica_runtime

import c "../compiler"
import k "../kernel"
import s "../store"
import v "../var"
import vm "../vm"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

@(private)
corpus_candidate :: proc(name: string) -> string {
	candidates := []string {
		"apps/shared/capabilities.mica",
		"../apps/shared/capabilities.mica",
		"../../apps/shared/capabilities.mica",
	}
	for candidate in candidates {
		if os.is_file(candidate) {
			return candidate
		}
	}
	return ""
}

@(private)
expect_relation_rows :: proc(t: ^testing.T, kernel: ^k.Kernel, name: string, expected: int) {
	metadata, found := k.snapshot_relation_metadata_named(kernel.current, v.symbol_intern(name))
	testing.expect(t, found)
	if !found {
		return
	}
	bindings := make([]v.Binding, metadata.arity, context.temp_allocator)
	rows: [dynamic]v.Tuple
	k.kernel_scan_into(kernel, metadata.id, bindings, &rows)
	testing.expectf(
		t,
		len(rows) == expected,
		"%s has %d rows, expected %d",
		name,
		len(rows),
		expected,
	)
	delete(rows)
}

@(test)
test_run_capabilities_filein :: proc(t: ^testing.T) {
	path := corpus_candidate("apps/shared/capabilities.mica")
	if path == "" {
		testing.expect(t, false, "capabilities.mica not found")
		return
	}

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_filein(&kernel, path, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)

	expect_relation_rows(t, &kernel, "Delegates", 3)
	expect_relation_rows(t, &kernel, "Name", 1)
	expect_relation_rows(t, &kernel, "HasRole", 2)
	expect_relation_rows(t, &kernel, "RelationInSurface", 2)
}

@(private)
compile_and_run :: proc(t: ^testing.T, source: string, ctx: ^c.Compile_Context) -> vm.VM {
	ast, parse_errors := c.parse_program(source, context.temp_allocator)
	testing.expectf(t, len(parse_errors) == 0, "parse errors for %q: %v", source, parse_errors)
	compiled := c.compile_program(ast, ctx, context.temp_allocator)
	testing.expectf(
		t,
		len(compiled.errors) == 0,
		"compile errors for %q: %v",
		source,
		compiled.errors,
	)

	state: vm.VM
	vm.vm_init(&state, compiled.program, context.temp_allocator)
	register_runtime_builtins(&state)
	testing.expectf(t, vm.vm_run(&state) == .Halted, "vm did not halt for %q", source)
	return state
}

@(test)
test_builtin_string_surface :: proc(t: ^testing.T) {
	ctx := c.Compile_Context {
		builtins   = make(map[string]bool),
		relations  = make(map[string]u32),
		identities = make(map[string]v.Value),
	}
	defer delete(ctx.builtins)
	defer delete(ctx.relations)
	defer delete(ctx.identities)
	install_builtin_names(&ctx)

	state := compile_and_run(
		t,
		"string_concat(\"a\", string_from_chars(string_chars(\"bc\")))",
		&ctx,
	)
	defer vm.vm_destroy(&state)
	text, ok := v.value_as_string(state.result)
	testing.expect(t, ok)
	testing.expect_value(t, text, "abc")
}

// A string is a sequence of Unicode scalar values for indexing, length, and
// iteration, not of bytes. The value at a position is the scalar as an
// integer, which is what a scanner classifies.
@(test)
test_run_string_scalar_scanning :: proc(t: ^testing.T) {
	ctx := c.Compile_Context {
		builtins   = make(map[string]bool),
		relations  = make(map[string]u32),
		identities = make(map[string]v.Value),
	}
	defer delete(ctx.builtins)
	defer delete(ctx.relations)
	defer delete(ctx.identities)
	install_builtin_names(&ctx)

	// Scalar position, not byte offset: "héllo"[1] is 'é', the scalar 0xe9.
	expect_int_builtin(t, &ctx, `"héllo"[1]`, 0xe9)
	expect_int_builtin(t, &ctx, `"abc"[0]`, 'a')
	expect_int_builtin(t, &ctx, `len("héllo")`, 5)
	expect_int_builtin(t, &ctx, `string_len("héllo")`, 5)

	// Slicing still works by scalar positions and cannot split a scalar.
	expect_string_builtin(t, &ctx, `string_slice("héllo", 1, 2)`, "é")
	expect_string_builtin(t, &ctx, `string_slice("héllo", 1, 3)`, "él")

	// Iteration yields scalars in order.
	expect_int_builtin(
		t,
		&ctx,
		`begin
  let text = "hé"
  let total = 0
  for scalar in text
    total = total + scalar
  end
  total
end`,
		0x68 + 0xe9,
	)

	// The two-binding form pairs each scalar with its position.
	expect_int_builtin(
		t,
		&ctx,
		`begin
  let text = "hé"
  let total = 0
  for position, scalar in text
    if position == 1
      total = total + scalar
    end
  end
  total
end`,
		0xe9,
	)

	// Bounds are enforced like list indexing.
	expect_builtin_error(t, &ctx, `"abc"[3]`, "E_INDEX")
	expect_builtin_error(t, &ctx, `"abc"[-1]`, "E_INDEX")
	expect_builtin_error(t, &ctx, `string_slice("abc", 0, 4)`, "E_INDEX")
}

@(private)
expect_int_builtin :: proc(t: ^testing.T, ctx: ^c.Compile_Context, source: string, expected: i64) {
	state := compile_and_run(t, source, ctx)
	defer vm.vm_destroy(&state)
	value, ok := v.value_as_int(state.result)
	testing.expectf(t, ok, "%s: result is not an int", source)
	if ok {
		testing.expectf(t, value == expected, "%s = %d, expected %d", source, value, expected)
	}
}

@(private)
expect_string_builtin :: proc(
	t: ^testing.T,
	ctx: ^c.Compile_Context,
	source: string,
	expected: string,
) {
	state := compile_and_run(t, source, ctx)
	defer vm.vm_destroy(&state)
	value, ok := v.value_as_string(state.result)
	testing.expectf(t, ok, "%s: result is not a string", source)
	if ok {
		testing.expectf(t, value == expected, "%s = %q, expected %q", source, value, expected)
	}
}

@(private)
expect_bool_builtin :: proc(
	t: ^testing.T,
	ctx: ^c.Compile_Context,
	source: string,
	expected: bool,
) {
	state := compile_and_run(t, source, ctx)
	defer vm.vm_destroy(&state)
	value, ok := v.value_as_bool(state.result)
	testing.expectf(t, ok, "%s: result is not a bool", source)
	if ok {
		testing.expectf(t, value == expected, "%s = %v, expected %v", source, value, expected)
	}
}

@(private)
expect_builtin_error :: proc(
	t: ^testing.T,
	ctx: ^c.Compile_Context,
	source: string,
	expected_code: string,
) {
	ast, parse_errors := c.parse_program(source, context.temp_allocator)
	testing.expectf(t, len(parse_errors) == 0, "parse errors for %q: %v", source, parse_errors)
	compiled := c.compile_program(ast, ctx, context.temp_allocator)
	testing.expectf(
		t,
		len(compiled.errors) == 0,
		"compile errors for %q: %v",
		source,
		compiled.errors,
	)

	state: vm.VM
	vm.vm_init(&state, compiled.program, context.temp_allocator)
	defer vm.vm_destroy(&state)
	register_runtime_builtins(&state)
	testing.expectf(t, vm.vm_run(&state) == .Failed, "%s should fail", source)
	error, error_ok := v.value_as_error(state.error)
	testing.expectf(t, error_ok, "%s: no error value", source)
	if error_ok {
		code, _ := v.symbol_name(error.code)
		testing.expectf(
			t,
			code == expected_code,
			"%s raised %s, expected %s",
			source,
			code,
			expected_code,
		)
	}
}

@(test)
test_sort_i64 :: proc(t: ^testing.T) {
	// The int sort is hand-rolled, so exercise the partitioning path (above the
	// insertion threshold), the degenerate orders, and duplicates directly.
	SIZES :: []int{0, 1, 2, 3, 12, 13, 100, 511, 512, 1000, 8192}
	for size in SIZES {
		values := make([]i64, size)
		seed: i64 = 12345
		for &value in values {
			// Keep the generator inside the 56-bit Mica integer range.
			seed = (seed * 97 + 7919) % 100003
			value = (seed % 2001) - 1000
		}
		sort_i64(values)
		for index in 1 ..< len(values) {
			testing.expectf(
				t,
				values[index - 1] <= values[index],
				"size %d: values[%d]=%d > values[%d]=%d",
				size,
				index - 1,
				values[index - 1],
				index,
				values[index],
			)
		}
		delete(values)
	}

	ascending := make([]i64, 300)
	descending := make([]i64, 300)
	equal := make([]i64, 200)
	for _, index in ascending {
		ascending[index] = i64(index)
		descending[index] = i64(300 - index)
	}
	for &value in equal {
		value = 7
	}
	sort_i64(ascending)
	sort_i64(descending)
	sort_i64(equal)
	for index in 1 ..< len(ascending) {
		testing.expect(t, ascending[index - 1] <= ascending[index])
		testing.expect(t, descending[index - 1] <= descending[index])
	}
	testing.expect(t, equal[0] == 7 && equal[len(equal) - 1] == 7)
	delete(ascending)
	delete(descending)
	delete(equal)
}

@(test)
test_scalar_builtins :: proc(t: ^testing.T) {
	ctx := c.Compile_Context {
		builtins   = make(map[string]bool),
		relations  = make(map[string]u32),
		identities = make(map[string]v.Value),
	}
	defer delete(ctx.builtins)
	defer delete(ctx.relations)
	defer delete(ctx.identities)
	install_builtin_names(&ctx)

	expect_int_builtin(t, &ctx, `string_len("héllo")`, 5)
	expect_string_builtin(t, &ctx, `string_slice("héllo", 1, 4)`, "éll")
	expect_string_builtin(t, &ctx, `string_join(["a", "b", "c"], "-")`, "a-b-c")
	expect_bool_builtin(t, &ctx, `string_starts_with("hello", "he")`, true)
	expect_bool_builtin(t, &ctx, `string_starts_with("hello", "lo")`, false)
	expect_bool_builtin(t, &ctx, `string_contains("hello", "ell")`, true)
	expect_bool_builtin(t, &ctx, `string_contains("hello", "xyz")`, false)
	expect_bool_builtin(t, &ctx, `string_equal_fold("HeLLo", "hello")`, true)
	expect_string_builtin(t, &ctx, `lower("HeLLo")`, "hello")
	expect_int_builtin(t, &ctx, `edit_distance("kitten", "sitting")`, 3)
	expect_string_builtin(t, &ctx, `url_decode_component(url_encode_component("a b&c"))`, "a b&c")
	expect_int_builtin(t, &ctx, `len(sort([3, 1, 2]))`, 3)

	expect_builtin_error(t, &ctx, `string_len(1)`, "E_TYPE")
	expect_builtin_error(t, &ctx, `string_slice("abc", 2, 1)`, "E_INDEX")
	expect_builtin_error(t, &ctx, `string_slice("abc", 0, 9)`, "E_INDEX")
	expect_builtin_error(t, &ctx, `string_slice("abc", "a", 1)`, "E_TYPE")
	expect_builtin_error(t, &ctx, `string_join([1], "-")`, "E_TYPE")
	expect_builtin_error(t, &ctx, `lower(3)`, "E_TYPE")
	expect_builtin_error(t, &ctx, `words(3)`, "E_TYPE")
	expect_builtin_error(t, &ctx, `sort(1)`, "E_TYPE")
	expect_builtin_error(t, &ctx, `edit_distance(1, "a")`, "E_TYPE")
	expect_builtin_error(t, &ctx, `map_pairs([1])`, "E_TYPE")
	expect_builtin_error(t, &ctx, `url_decode_component("%zz")`, "E_URL")
}

@(test)
test_builtin_splice_and_set_index :: proc(t: ^testing.T) {ctx := c.Compile_Context {
		builtins   = make(map[string]bool),
		relations  = make(map[string]u32),
		identities = make(map[string]v.Value),
	}
	defer delete(ctx.builtins)
	defer delete(ctx.relations)
	defer delete(ctx.identities)
	install_builtin_names(&ctx)

	state := compile_and_run(t, "let xs = [1, 2]\n[@xs, 3]", &ctx)
	defer vm.vm_destroy(&state)
	values, ok := v.value_as_list(state.result)
	testing.expect(t, ok)
	testing.expect_value(t, len(values), 3)

	indexed := compile_and_run(t, "let m = {:a -> 1}\nm[:b] = 2\nm", &ctx)
	defer vm.vm_destroy(&indexed)
	entries, map_ok := v.value_as_map(indexed.result)
	testing.expect(t, map_ok)
	testing.expect_value(t, len(entries), 2)
}

@(test)
test_primitive_identity_prototypes :: proc(t: ^testing.T) {
	ctx := c.Compile_Context {
		builtins   = make(map[string]bool),
		relations  = make(map[string]u32),
		identities = make(map[string]v.Value),
	}
	defer delete(ctx.builtins)
	defer delete(ctx.relations)
	defer delete(ctx.identities)
	install_builtin_names(&ctx)
	install_primitive_identities(&ctx)

	state := compile_and_run(t, "#string", &ctx)
	defer vm.vm_destroy(&state)
	identity, ok := v.value_as_identity(state.result)
	testing.expect(t, ok)
	testing.expect_value(t, v.identity_raw(identity), u64(v.STRING_PROTOTYPE))
}

@(test)
test_run_dispatch_role_call :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:player)
make_identity(:thing)
make_identity(:alice)
make_identity(:coin)
make_relation(:Taken, 2)
assert Delegates(#alice, #player, 0)
assert Delegates(#coin, #thing, 0)
verb take(actor @ #player, item @ #thing)
  assert Taken(actor, item)
end
:take(actor: #alice, item: #coin)
`
	directory, directory_err := os.temp_dir(context.temp_allocator)
	if directory_err != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	path := fmt.aprintf(
		"%s/mica_dispatch_test.mica",
		directory,
		allocator = context.temp_allocator,
	)
	if write_err := os.write_entire_file(path, source); write_err != nil {
		testing.expect(t, false, "cannot write the dispatch test file")
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)

	expect_relation_rows(t, &kernel, "Taken", 1)
}

@(test)
test_run_dispatch_without_method_fails :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := "make_identity(:alice)\n:missing(actor: #alice)\n"
	directory, directory_err := os.temp_dir(context.temp_allocator)
	if directory_err != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	path := fmt.aprintf(
		"%s/mica_dispatch_missing_test.mica",
		directory,
		allocator = context.temp_allocator,
	)
	if write_err := os.write_entire_file(path, source); write_err != nil {
		testing.expect(t, false, "cannot write the dispatch test file")
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expect(t, !result.ok)
}

@(test)
test_run_multiple_files_share_verbs :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	directory, directory_err := os.temp_dir(context.temp_allocator)
	if directory_err != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	library := `make_relation(:Shared, 1)
verb shared/add(value)
  assert Shared(value)
end
`
	caller := `shared/add(7)
`
	library_path := fmt.aprintf(
		"%s/mica_library_test.mica",
		directory,
		allocator = context.temp_allocator,
	)
	caller_path := fmt.aprintf(
		"%s/mica_caller_test.mica",
		directory,
		allocator = context.temp_allocator,
	)
	if os.write_entire_file(library_path, library) != nil ||
	   os.write_entire_file(caller_path, caller) != nil {
		testing.expect(t, false, "cannot write the multi-file test files")
		return
	}
	defer os.remove(library_path)
	defer os.remove(caller_path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{library_path, caller_path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Shared", 1)
}

@(test)
test_run_spawn_task :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Done, 1)
verb child()
  assert Done(1)
end
spawn :child()
suspend()
`
	directory, directory_err := os.temp_dir(context.temp_allocator)
	if directory_err != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	path := fmt.aprintf("%s/mica_spawn_test.mica", directory, allocator = context.temp_allocator)
	if write_err := os.write_entire_file(path, source); write_err != nil {
		testing.expect(t, false, "cannot write the spawn test file")
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)

	expect_relation_rows(t, &kernel, "Done", 1)
}

@(test)
test_run_raise_reports_error :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `raise E_RANGE, "out of range"
`
	directory, directory_err := os.temp_dir(context.temp_allocator)
	if directory_err != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	path := fmt.aprintf("%s/mica_raise_test.mica", directory, allocator = context.temp_allocator)
	if write_err := os.write_entire_file(path, source); write_err != nil {
		testing.expect(t, false, "cannot write the raise test file")
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expect(t, !result.ok)
	testing.expectf(
		t,
		len(result.message) > 0,
		"raise should report a message, got %q",
		result.message,
	)
}

@(test)
test_run_invoke_dynamic_dispatch :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:player)
make_identity(:alice)
make_relation(:Taken, 1)
assert Delegates(#alice, #player, 0)
verb take(actor @ #player)
  assert Taken(actor)
end
invoke(:take, {:actor -> #alice})
`
	directory, directory_err := os.temp_dir(context.temp_allocator)
	if directory_err != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	path := fmt.aprintf("%s/mica_invoke_test.mica", directory, allocator = context.temp_allocator)
	if write_err := os.write_entire_file(path, source); write_err != nil {
		testing.expect(t, false, "cannot write the invoke test file")
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)

	expect_relation_rows(t, &kernel, "Taken", 1)
}

@(test)
test_run_match_expression :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Score, 1)
make_relation(:Failed, 1)
verb classify(text)
  return match parse_ordinal(text)
  case ok(value) if value >= 0
    value
  case ok(ignored)
    -1
  case err(problem)
    -2
  end
end
assert Score(classify("7"))
assert Failed(classify("banana"))
`
	directory, directory_err := os.temp_dir(context.temp_allocator)
	if directory_err != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	path := fmt.aprintf("%s/mica_match_test.mica", directory, allocator = context.temp_allocator)
	if write_err := os.write_entire_file(path, source); write_err != nil {
		testing.expect(t, false, "cannot write the match test file")
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)

	expect_relation_rows(t, &kernel, "Score", 1)
	expect_relation_rows(t, &kernel, "Failed", 1)
}

@(test)
test_run_from_literal_and_to_xml :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:alice)
make_relation(:Entity, 1)
make_relation(:Markup, 1)
verb entity_from_literal(text)
  return match from_literal(text)
  case ok(value)
    value
  case err(problem)
    none
  end
end
assert Entity(entity_from_literal("#alice"))
assert Markup(to_xml(dom <p class="note">hi</p>))
`
	directory, directory_err := os.temp_dir(context.temp_allocator)
	if directory_err != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	path := fmt.aprintf(
		"%s/mica_literal_xml_test.mica",
		directory,
		allocator = context.temp_allocator,
	)
	if write_err := os.write_entire_file(path, source); write_err != nil {
		testing.expect(t, false, "cannot write the literal/XML test file")
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)

	expect_relation_rows(t, &kernel, "Entity", 1)
	expect_relation_rows(t, &kernel, "Markup", 1)
}

@(test)
test_run_mud_app_world :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	core := corpus_candidate("apps/mud/core.mica")
	if core == "" {
		testing.expect(t, false, "mud corpus not found")
		return
	}
	apps := filepath.dir(filepath.dir(core))
	names := []string {
		"shared/string.mica",
		"shared/events.mica",
		"shared/retrieval.mica",
		"shared/sync-host.mica",
		"shared/sync-dom.mica",
		"mud/core.mica",
		"mud/auth.mica",
		"mud/command-parser.mica",
		"mud/event-substitutions.mica",
		"mud/ui-session.mica",
		"mud/ui-actions.mica",
		"mud/ui-compose.mica",
		"mud/ui-narrative.mica",
		"mud/ui-mica-inspect.mica",
		"mud/ui-retrieval.mica",
		"mud/http.mica",
	}
	paths := make([]string, len(names), context.temp_allocator)
	for name, index in names {
		joined, join_err := filepath.join([]string{apps, name}, context.temp_allocator)
		if join_err != nil {
			testing.expect(t, false, "cannot join a corpus path")
			return
		}
		paths[index] = joined
	}

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, paths, context.temp_allocator)
	testing.expectf(t, result.ok, "mud world failed: %s", result.message)
}

@(test)
test_run_records_catalog_facts :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Widget, 2)
make_relation(:Parent, 2)
Parent(child, parent) :-
  Widget(child, parent)
`
	directory, directory_err := os.temp_dir(context.temp_allocator)
	if directory_err != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	path := fmt.aprintf("%s/mica_catalog_test.mica", directory, allocator = context.temp_allocator)
	if write_err := os.write_entire_file(path, source); write_err != nil {
		testing.expect(t, false, "cannot write the catalog test file")
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)

	widget, widget_found := k.snapshot_relation_metadata_named(
		k.kernel_snapshot(&kernel),
		v.symbol_intern("Widget"),
	)
	testing.expect(t, widget_found)

	names: [dynamic]v.Tuple
	defer delete(names)
	k.kernel_scan_into(&kernel, k.SYSTEM_RELATION_NAME_ID, []v.Binding{{}, {}}, &names)
	found_name := false
	for row in names {
		values := v.tuple_values(row)
		if len(values) == 2 && v.value_eq(values[1], v.value_symbol(v.symbol_intern("Widget"))) {
			found_name = true
		}
	}
	testing.expect(t, found_name)

	arity_rows: [dynamic]v.Tuple
	defer delete(arity_rows)
	k.kernel_scan_into(&kernel, k.SYSTEM_ARITY_ID, []v.Binding{{}, {}}, &arity_rows)
	found_arity := false
	for row in arity_rows {
		values := v.tuple_values(row)
		if len(values) != 2 {
			continue
		}
		raw, raw_ok := v.value_as_identity(values[0])
		arity, arity_ok := v.value_as_int(values[1])
		if raw_ok && arity_ok && u64(v.identity_raw(raw)) == u64(widget.id) && arity == 2 {
			found_arity = true
		}
	}
	testing.expect(t, found_arity)

	rule_rows: [dynamic]v.Tuple
	defer delete(rule_rows)
	k.kernel_scan_into(&kernel, k.SYSTEM_RULE_ID, []v.Binding{{}}, &rule_rows)
	testing.expect(t, len(rule_rows) >= 1)

	source_rows: [dynamic]v.Tuple
	defer delete(source_rows)
	k.kernel_scan_into(&kernel, k.SYSTEM_RULE_SOURCE_ID, []v.Binding{{}, {}}, &source_rows)
	testing.expect(t, len(source_rows) >= 1)
}

@(test)
test_run_try_catch_codes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Matched, 2)
verb probe(mode)
  try
    if mode == 1
      raise E_RANGE, "bad"
    elseif mode == 2
      raise E_TYPE, "wrong"
    end
    return 7
  catch E_RANGE
    return 1
  catch E_TYPE as err
    return 2
  end
end
assert Matched(probe(1), 1)
assert Matched(probe(2), 2)
assert Matched(probe(0), 7)
`
	directory, directory_err := os.temp_dir(context.temp_allocator)
	if directory_err != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	path := fmt.aprintf(
		"%s/mica_try_codes_test.mica",
		directory,
		allocator = context.temp_allocator,
	)
	if write_err := os.write_entire_file(path, source); write_err != nil {
		testing.expect(t, false, "cannot write the try test file")
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Matched", 3)
}

@(test)
test_run_try_catches_builtin_error :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Caught, 1)
verb indexed()
  try
    let items = [10]
    return items[4]
  catch err
    assert Caught(1)
    return 0
  end
end
assert Caught(indexed())
`
	directory, directory_err := os.temp_dir(context.temp_allocator)
	if directory_err != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	path := fmt.aprintf(
		"%s/mica_try_builtin_test.mica",
		directory,
		allocator = context.temp_allocator,
	)
	if write_err := os.write_entire_file(path, source); write_err != nil {
		testing.expect(t, false, "cannot write the try builtin test file")
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Caught", 2)
}

@(test)
test_run_arithmetic_error_codes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `verb classify(which)
  try
    if which == 1
      return 1 / 0
    elseif which == 2
      return 1.0 / 0.0
    elseif which == 3
      let big = 36028797018963967
      return big + 1
    elseif which == 4
      return 4 / 2.0
    elseif which == 5
      return 5 / 2
    elseif which == 6
      return 1 % 0
    elseif which == 7
      let most_negative = -36028797018963967 - 1
      return -most_negative
    elseif which == 8
      return 3.4028235e38 * 3.4028235e38
    end
    return 0
  catch E_DIV
    return 10
  catch E_TYPE
    return 20
  catch E_ARITH
    return 30
  end
end
require classify(1) == 10
require classify(2) == 10
require classify(3) == 30
require classify(4) == 20
require classify(5) == 30
require classify(6) == 10
require classify(7) == 30
require classify(8) == 30
require classify(0) == 0
`
	directory, directory_err := os.temp_dir(context.temp_allocator)
	if directory_err != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	path := fmt.aprintf(
		"%s/mica_arithmetic_codes_test.mica",
		directory,
		allocator = context.temp_allocator,
	)
	if write_err := os.write_entire_file(path, source); write_err != nil {
		testing.expect(t, false, "cannot write the arithmetic codes test file")
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	// No E_ARITHMETIC arm exists, so a stray E_ARITHMETIC aborts the filein.
	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
}

@(test)
test_run_explicit_numeric_conversions :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `verb convert(which)
  try
    if which == 1
      return to_float(5) / to_float(2)
    elseif which == 2
      return to_int(4.0 / 2.0)
    elseif which == 3
      return to_int(7.5)
    end
    return 0
  catch E_TYPE
    return -1
  end
end
require convert(1) == 2.5
require convert(2) == 2
require convert(3) == -1
`
	directory, directory_err := os.temp_dir(context.temp_allocator)
	if directory_err != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	path := fmt.aprintf(
		"%s/mica_numeric_conversion_test.mica",
		directory,
		allocator = context.temp_allocator,
	)
	if write_err := os.write_entire_file(path, source); write_err != nil {
		testing.expect(t, false, "cannot write the numeric conversion test file")
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
}

@(test)
test_run_require_rejects_empty_list :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `verb probe(which)
  try
    if which == 1
      require []
    elseif which == 2
      require [1]
      return 2
    elseif which == 3
      require []
      return 3
    elseif which == 4
      require none
    elseif which == 5
      require [] {}
    end
    return 0
  catch E_REQUIRE
    return 42
  end
end
require probe(1) == 42
require probe(2) == 2
require probe(3) == 42
require probe(4) == 42
require probe(5) == 42
require probe(0) == 0
`
	directory, directory_err := os.temp_dir(context.temp_allocator)
	if directory_err != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	path := fmt.aprintf(
		"%s/mica_require_truthiness_test.mica",
		directory,
		allocator = context.temp_allocator,
	)
	if write_err := os.write_entire_file(path, source); write_err != nil {
		testing.expect(t, false, "cannot write the require truthiness test file")
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
}

@(test)
test_run_try_finally_paths :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Cleanup, 1)
verb clean_normal()
  let value = 0
  try
    value = 3
  finally
    assert Cleanup(1)
  end
  return value
end
assert Cleanup(clean_normal())

verb clean_error()
  try
    raise E_RANGE, "bad"
  finally
    assert Cleanup(2)
  end
end
try
  clean_error()
catch err
  assert Cleanup(3)
end
`
	directory, directory_err := os.temp_dir(context.temp_allocator)
	if directory_err != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	path := fmt.aprintf(
		"%s/mica_try_finally_test.mica",
		directory,
		allocator = context.temp_allocator,
	)
	if write_err := os.write_entire_file(path, source); write_err != nil {
		testing.expect(t, false, "cannot write the try finally test file")
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Cleanup", 3)
}

@(test)
test_run_uncaught_inner_raise_propagates :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `verb probe()
  try
    raise E_RANGE, "bad"
  catch E_TYPE
    return 1
  end
  return 0
end
probe()
`
	directory, directory_err := os.temp_dir(context.temp_allocator)
	if directory_err != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	path := fmt.aprintf(
		"%s/mica_try_unmatched_test.mica",
		directory,
		allocator = context.temp_allocator,
	)
	if write_err := os.write_entire_file(path, source); write_err != nil {
		testing.expect(t, false, "cannot write the try unmatched test file")
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expect(t, !result.ok)
}

@(private)
write_temp_source :: proc(t: ^testing.T, name: string, source: string) -> (string, bool) {
	directory, directory_err := os.temp_dir(context.temp_allocator)
	if directory_err != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return "", false
	}
	path := fmt.aprintf("%s/%s", directory, name, allocator = context.temp_allocator)
	if write_err := os.write_entire_file(path, source); write_err != nil {
		testing.expect(t, false, "cannot write the test file")
		return "", false
	}
	return path, true
}

@(test)
test_run_mailbox_roundtrip :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Got, 1)
let [receiver, sender] = mailbox()
mailbox_send(sender, 42)
let ready = mailbox_recv([receiver])
let first = ready[0][1][0]
assert Got(first)
mailbox_close(receiver)
`
	path, path_ok := write_temp_source(t, "mica_mailbox_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Got", 1)
}

@(test)
test_run_mailbox_wakes_waiter :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Got, 1)
verb deliver(receiver, sender_cap)
  mailbox_send(sender_cap, 7)
end
let [receiver, sender] = mailbox()
spawn :deliver(receiver: receiver, sender_cap: sender)
let ready = mailbox_recv([receiver])
let first = ready[0][1][0]
assert Got(first)
`
	path, path_ok := write_temp_source(t, "mica_mailbox_wake_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Got", 1)
}

@(test)
test_run_mailbox_timeout :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:TimedOut, 1)
let [receiver, sender] = mailbox()
let ready = mailbox_recv([receiver], 1)
require(ready == [])
assert TimedOut(1)
`
	path, path_ok := write_temp_source(t, "mica_mailbox_timeout_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "TimedOut", 1)
}

@(test)
test_run_fn_literals :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Result, 2)
verb apply(f, x)
  return f(x)
end
let double = fn(x) => x * 2
let inc = fn(x)
  return x + 1
end
let choosers = [fn(x) => x + 1]
assert Result(1, apply(double, 21))
assert Result(2, inc(41))
assert Result(3, choosers[0](41))
let nested = fn(x) => (fn(y) => y * 3)(x)
assert Result(4, nested(14))
`
	path, path_ok := write_temp_source(t, "mica_fn_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Result", 4)
}

@(test)
test_run_fn_captures :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Result, 2)
let base = 10
let add = fn(x) => x + base
assert Result(1, add(5))
base = 100
assert Result(2, add(5))
verb apply(f, x)
  return f(x)
end
assert Result(3, apply(add, 5))
let outer = fn(x)
  let scale = 3
  return fn(y) => (x + y) * scale
end
assert Result(4, outer(2)(4))
let makers = []
for i in [1, 2]
  makers = [@makers, fn() => i]
end
assert Result(5, makers[0]())
assert Result(6, makers[1]())
assert Result(7, [{:f -> add}][0][:f](5))
`
	path, path_ok := write_temp_source(t, "mica_fn_capture_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Result", 7)
}

@(test)
test_run_byte_literals :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Payload, 1)
require(b"3q2-7w==" == b"3q2-7w==")
require(b"" == b"")
assert Payload(b"3q2-7w==")
`
	path, path_ok := write_temp_source(t, "mica_bytes_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Payload", 1)
}

@(test)
test_run_argument_splices :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Result, 1)
verb sum3(a, b, c)
  return a + b + c
end
let xs = [1, 2, 3]
require(sum3(@xs) == 6)
require(sum3(1, @[2, 3]) == 6)
let f = fn(a, b) => a * b
let pair = [6, 7]
require(f(@pair) == 42)
require(string_concat(@["a", "b", "c"]) == "abc")
let pick = [f]
require(pick[0](@pair) == 42)
assert Result(sum3(@xs))
`
	path, path_ok := write_temp_source(t, "mica_splice_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Result", 1)
}

@(test)
test_run_match_collection_patterns :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Out, 1)
verb classify(value)
  return match value
  case [a, b]
    a + b
  case [first, @rest]
    first + len(rest)
  case {:kind -> :pair, :left -> l, :right -> r}
    l * r
  case _
    -1
  end
end
require(classify([1, 2]) == 3)
require(classify([5, 6, 7]) == 7)
require(classify({:kind -> :pair, :left -> 3, :right -> 4}) == 12)
require(classify(:nope) == -1)
assert Out(classify([1, 2]))
`
	path, path_ok := write_temp_source(t, "mica_match_patterns_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Out", 1)
}

@(test)
test_run_scatter_bindings :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Out, 1)
let [a, b] = [1, 2]
let [first, @rest] = [10, 20, 30]
let [x, ?y = 9, @tail] = [4]
let [p, ?q, @remaining] = [4, 5, 6, 7]
require(a + b == 3)
require(first + len(rest) == 12)
require(x + y + len(tail) == 13)
require(p + q + len(remaining) == 11)
assert Out(a)
`
	path, path_ok := write_temp_source(t, "mica_scatter_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Out", 1)
}

@(test)
test_run_finally_on_return :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Cleanup, 1)
verb compute(mode)
  try
    if mode == 1
      raise E_RANGE, "bad"
    end
    return 42
  finally
    assert Cleanup(1)
  end
end
require(compute(0) == 42)
verb nested()
  try
    try
      return 7
    finally
      assert Cleanup(2)
    end
  finally
    assert Cleanup(3)
  end
end
require(nested() == 7)
verb error_return(mode)
  try
    return 5
  finally
    if mode == 1
      raise E_TYPE, "cleanup failed"
    end
  end
end
require(error_return(0) == 5)
try
  error_return(1)
catch err
  assert Cleanup(4)
end
verb loop_return()
  for i in [1, 2, 3]
    try
      if i == 2
        return i
      end
    finally
      assert Cleanup(5)
    end
  end
  return 0
end
require(loop_return() == 2)
`
	path, path_ok := write_temp_source(t, "mica_finally_return_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Cleanup", 5)
}

@(test)
test_run_finally_on_catch_return :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Cleanup, 1)
verb caught(mode)
  try
    if mode == 1
      raise E_RANGE, "bad"
    end
    return 1
  catch err
    if mode == 1
      return 2
    end
    return 3
  finally
    assert Cleanup(1)
  end
end
require(caught(1) == 2)
require(caught(0) == 1)
assert Cleanup(1)
`
	path, path_ok := write_temp_source(t, "mica_catch_return_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Cleanup", 1)
}

@(test)
test_run_recursion :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Out, 1)
let fact = fn(n)
  if n <= 1
    return 1
  end
  return n * fact(n - 1)
end
fn fib(n)
  if n < 2
    return n
  end
  return fib(n - 1) + fib(n - 2)
end
fn tripled(x) => x * 3
require(fact(5) == 120)
require(fib(10) == 55)
require(tripled(7) == 21)
let other = fn(n)
  if n <= 0
    return 0
  end
  return 1 + other(n - 1)
end
require(other(4) == 4)
require(fact(4) == 24)
assert Out(fact(5))
`
	path, path_ok := write_temp_source(t, "mica_recursion_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Out", 1)
}

@(test)
test_run_optional_rest_params :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Out, 1)
verb greet(name, ?greeting = "hello", @extras)
  return [name, greeting, extras]
end
require(greet("x") == ["x", "hello", []])
require(greet("x", "yo") == ["x", "yo", []])
require(greet("x", "yo", 1, 2) == ["x", "yo", [1, 2]])
verb optional_none(a, ?b)
  return b
end
require(optional_none(1) == none)
verb collect(a, @rest)
  return [a, rest]
end
require(collect(1) == [1, []])
require(collect(1, 2, 3) == [1, [2, 3]])
fn opt(x, ?y = 2) => x + y
require(opt(1) == 3)
let f = fn(a, ?b = 5, @rest) => [a, b, rest]
let g = f
require(g(1) == [1, 5, []])
require(g(1, 2, 3, 4) == [1, 2, [3, 4]])
assert Out(greet("z", "bonjour"))
`
	path, path_ok := write_temp_source(t, "mica_optional_params_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Out", 1)
}

@(test)
test_run_receiver_dispatch :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:player)
make_identity(:alice)
make_identity(:coin)
make_identity(:gem)
make_relation(:Taken, 2)
assert Delegates(#alice, #player, 0)
assert Delegates(#coin, #player, 0)
assert Delegates(#gem, #player, 0)
verb take(actor @ #player, item @ #player)
  assert Taken(actor, item)
  return :generic
end
verb take(actor @ #player, item @ #coin)
  assert Taken(actor, item)
  return :specific
end
require(#alice:take(#coin) == :specific)
require(#alice:take(#gem) == :generic)
let carried = #alice
require(carried:take(#gem) == :generic)
assert Taken(#alice, #coin)
`
	path, path_ok := write_temp_source(t, "mica_receiver_dispatch_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Taken", 2)
}

@(test)
test_run_positional_dispatch_restrictions :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:template/name)
make_identity(:template/conjugation)
make_identity(:alice)

verb render_part(part @ #string, bindings, viewer)
  return :text
end

verb render_part(part @ #template/name<_>, bindings, viewer)
  return :name
end

verb render_part(part @ #template/conjugation<_>, bindings, viewer)
  return :conjugation
end

verb pick(part, x)
  return :any
end

verb pick(part @ #template/name<_>, x)
  return :name
end

require(render_part(frob(#template/name, {:binding -> #alice}), {}, #alice) == :name)
require(render_part(frob(#template/conjugation, {:binding -> #alice}), {}, #alice) == :conjugation)
require(render_part("plain", {}, #alice) == :text)
require(pick(frob(#template/name, {:binding -> #alice}), #alice) == :name)
require(pick("plain", #alice) == :any)
`
	path, path_ok := write_temp_source(t, "mica_positional_dispatch_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
}

@(test)
test_run_return_in_finally :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Ran, 1)
verb override()
  try
    return 1
  finally
    return 2
  end
end
verb override_error()
  try
    raise E_RANGE, "bad"
  finally
    return 3
  end
end
verb nested()
  try
    try
      return 4
    finally
      assert Ran(1)
      return 5
    end
  finally
    assert Ran(2)
  end
end
require(override() == 2)
require(override_error() == 3)
require(nested() == 5)
`
	path, path_ok := write_temp_source(t, "mica_finally_return2_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Ran", 2)
}

@(test)
test_run_constant_defaults :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Out, 1)
verb conf(a, ?tags = [], ?opts = {:mode -> :fast}, ?pair = some(1), ?flag = -2, ?raw = b"AAEC", ?missing = none)
  return [a, tags, opts, pair, flag, raw, missing]
end
require(conf(1) == [1, [], {:mode -> :fast}, some(1), -2, b"AAEC", none])
require(conf(1, [2], {:mode -> :slow}, some(9), 5, b"", none) == [1, [2], {:mode -> :slow}, some(9), 5, b"", none])
fn f(?x = [1, 2], ?list = {:a -> [3]}) => [x, list]
require(f() == [[1, 2], {:a -> [3]}])
assert Out(conf(1))
`
	path, path_ok := write_temp_source(t, "mica_const_defaults_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Out", 1)
}

@(test)
test_run_cross_task_closure :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Out, 2)
verb run_it(f, tag)
  let value = f()
  assert Out(tag, value)
end
let base = 10
let closure = fn(?step = 1) => base + step
spawn :run_it(f: closure, tag: 1)
suspend()
`
	path, path_ok := write_temp_source(t, "mica_cross_task_closure_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Out", 1)
}

@(test)
test_run_dispatch_optional_rest_params :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:alice)
make_identity(:bob)
make_relation(:Out, 1)
assert Delegates(#bob, #alice, 0)
verb act(receiver @ #alice, ?extra = 7, @rest)
  return [receiver, extra, rest]
end
require(#bob:act() == [#bob, 7, []])
require(#bob:act(9) == [#bob, 9, []])
require(#bob:act(9, 1, 2) == [#bob, 9, [1, 2]])
assert Out(#bob:act())
`
	path, path_ok := write_temp_source(t, "mica_dispatch_modes_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Out", 1)
}

@(test)
test_run_authority_grants :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:alice)
make_identity(:reader)
make_relation(:RoleCanRead, 2)
make_relation(:RoleCanWrite, 2)
make_relation(:Secret, 1)
make_relation(:Leak, 1)
assert Delegates(#alice, #reader, 0)
assert Secret(1)
grant role #reader
  read:
    :Secret
  write:
    :Leak
end
commit()
verb peek()
  if Secret(1)
    assert Leak(1)
  end
end
spawn :peek()
suspend()
`
	path, path_ok := write_temp_source(t, "mica_authority_grant_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(
		&kernel,
		[]string{path},
		context.temp_allocator,
		Run_Options{actor = "alice"},
	)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Leak", 1)
}

@(test)
test_run_authority_denies_unlisted :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:alice)
make_relation(:CanRead, 2)
make_relation(:CanWrite, 2)
make_relation(:CanInvoke, 2)
make_relation(:CanEffect, 1)
make_relation(:Secret, 1)
make_relation(:DeniedRead, 1)
make_relation(:DeniedInvoke, 1)
make_relation(:DeniedEffect, 1)
make_relation(:AllowedRead, 1)
make_relation(:AllowedInvoke, 1)
make_relation(:AllowedEffect, 1)
assert Secret(1)
grant #alice
  write:
    :DeniedRead
    :DeniedInvoke
    :DeniedEffect
    :AllowedRead
    :AllowedInvoke
    :AllowedEffect
end
commit()
verb peek()
  try
    let rows = Secret(1)
    assert AllowedRead(1)
  catch err
    assert DeniedRead(1)
  end
  try
    let text = string_concat("a", "b")
    assert AllowedInvoke(1)
  catch err
    assert DeniedInvoke(1)
  end
  try
    external_request(:svc, 1)
    assert AllowedEffect(1)
  catch err
    assert DeniedEffect(1)
  end
end
spawn :peek()
suspend()
`
	path, path_ok := write_temp_source(t, "mica_authority_denied_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(
		&kernel,
		[]string{path},
		context.temp_allocator,
		Run_Options{actor = "alice"},
	)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "DeniedRead", 1)
	expect_relation_rows(t, &kernel, "DeniedInvoke", 1)
	expect_relation_rows(t, &kernel, "DeniedEffect", 1)
	expect_relation_rows(t, &kernel, "AllowedRead", 0)
	expect_relation_rows(t, &kernel, "AllowedInvoke", 0)
	expect_relation_rows(t, &kernel, "AllowedEffect", 0)
}

@(test)
test_run_capability_passing :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:alice)
make_relation(:Secret, 1)
make_relation(:Leak, 1)
assert Secret(1)
let read_cap = mint_capability(:read, :Secret)
let write_cap = mint_capability(:write, :Leak)
verb peek(read_cap, write_cap)
  use_capability(read_cap)
  use_capability(write_cap)
  if Secret(1)
    assert Leak(1)
  end
end
spawn :peek(read_cap: read_cap, write_cap: write_cap)
suspend()
`
	path, path_ok := write_temp_source(t, "mica_capability_passing_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(
		&kernel,
		[]string{path},
		context.temp_allocator,
		Run_Options{actor = "alice"},
	)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Leak", 1)
}

@(test)
test_run_capability_denied_without_adoption :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:alice)
make_relation(:Secret, 1)
make_relation(:DeniedRead, 1)
make_relation(:DeniedMint, 1)
make_relation(:AllowedRead, 1)
make_relation(:AllowedMint, 1)
assert Secret(1)
let read_cap = mint_capability(:read, :Secret)
let observe_cap = mint_capability(:write, :DeniedRead)
let observe_cap_two = mint_capability(:write, :DeniedMint)
let observe_cap_three = mint_capability(:write, :AllowedRead)
let observe_cap_four = mint_capability(:write, :AllowedMint)
verb peek(read_cap, observe_cap, observe_cap_two, observe_cap_three, observe_cap_four)
  use_capability(observe_cap)
  use_capability(observe_cap_two)
  use_capability(observe_cap_three)
  use_capability(observe_cap_four)
  try
    let rows = Secret(1)
    assert AllowedRead(1)
  catch err
    assert DeniedRead(1)
  end
  try
    let minted = mint_capability(:read, :Secret)
    assert AllowedMint(1)
  catch err
    assert DeniedMint(1)
  end
end
spawn :peek(read_cap: read_cap, observe_cap: observe_cap, observe_cap_two: observe_cap_two, observe_cap_three: observe_cap_three, observe_cap_four: observe_cap_four)
suspend()
`
	path, path_ok := write_temp_source(t, "mica_capability_denied_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(
		&kernel,
		[]string{path},
		context.temp_allocator,
		Run_Options{actor = "alice"},
	)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "DeniedRead", 1)
	expect_relation_rows(t, &kernel, "DeniedMint", 1)
	expect_relation_rows(t, &kernel, "AllowedRead", 0)
	expect_relation_rows(t, &kernel, "AllowedMint", 0)
}

// Field read/write must enforce the same relation authority as direct scans
// and writes. Regression (SEC1): the __get_field/__set_field builtins called
// the kernel transaction path directly, so a task with no relation grants
// could read and modify a functional relation through ordinary field syntax.
@(test)
test_run_field_access_requires_relation_authority :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:alice)
make_identity(:item)
make_relation(:AllowedRead, 1)
make_relation(:DeniedRead, 1)
make_relation(:AllowedWrite, 1)
make_relation(:DeniedWrite, 1)
make_functional_relation(:Name, 2, [0])
assert Name(#item, "secret")
let allowed_read_cap = mint_capability(:write, :AllowedRead)
let denied_read_cap = mint_capability(:write, :DeniedRead)
let allowed_write_cap = mint_capability(:write, :AllowedWrite)
let denied_write_cap = mint_capability(:write, :DeniedWrite)

verb probe(allowed_read_cap, denied_read_cap, allowed_write_cap, denied_write_cap)
  use_capability(allowed_read_cap)
  use_capability(denied_read_cap)
  use_capability(allowed_write_cap)
  use_capability(denied_write_cap)
  try
    let value = #item.name
    assert AllowedRead(1)
  catch err
    assert DeniedRead(1)
  end
  try
    #item.name = "changed"
    assert AllowedWrite(1)
  catch err
    assert DeniedWrite(1)
  end
end

spawn :probe(allowed_read_cap: allowed_read_cap, denied_read_cap: denied_read_cap, allowed_write_cap: allowed_write_cap, denied_write_cap: denied_write_cap)
suspend()
`
	path, path_ok := write_temp_source(t, "mica_field_authority_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(
		&kernel,
		[]string{path},
		context.temp_allocator,
		Run_Options{actor = "alice"},
	)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)

	// Both field operations were denied.
	expect_relation_rows(t, &kernel, "DeniedRead", 1)
	expect_relation_rows(t, &kernel, "DeniedWrite", 1)
	expect_relation_rows(t, &kernel, "AllowedRead", 0)
	expect_relation_rows(t, &kernel, "AllowedWrite", 0)

	// The denied write left the stored value unchanged.
	metadata, metadata_found := k.snapshot_relation_metadata_named(
		kernel.current,
		v.symbol_intern("Name"),
	)
	testing.expect(t, metadata_found)
	if metadata_found {
		rows: [dynamic]v.Tuple
		k.kernel_scan_into(&kernel, metadata.id, []v.Binding{{}, {}}, &rows)
		testing.expect_value(t, len(rows), 1)
		if len(rows) == 1 {
			values := v.tuple_values(rows[0])
			text, is_text := v.value_as_string(values[1])
			testing.expect(t, is_text)
			testing.expect_value(t, text, "secret")
		}
		delete(rows)
	}
}

@(test)
test_run_capability_multi_revoke_and_expiry :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:alice)
make_relation(:A, 1)
make_relation(:B, 1)
make_relation(:Rw, 2)
make_relation(:Vault, 1)
make_relation(:Ephemeral, 1)
make_relation(:Denied, 1)
make_relation(:Expired, 1)
make_relation(:Allowed, 1)
make_relation(:ChildBoom, 1)
assert A(1)
assert B(2)
assert Ephemeral(3)
let read_two = mint_capability(:read, [:A, :B])
let rw = mint_capability([:read, :write], :Rw)
let vault = mint_capability([:read, :write], :Vault)
let short = mint_capability(:read, :Ephemeral, {:ttl_millis -> 100})
let write_denied = mint_capability(:write, :Denied)
let write_expired = mint_capability(:write, :Expired)
let write_allowed = mint_capability(:write, :Allowed)
let write_boom = mint_capability(:write, :ChildBoom)
let call_cap = mint_capability(:invoke, [:mailbox_send])
verb work(read_two, rw, vault, short, write_denied, write_expired, write_allowed, write_boom, call_cap, sender_cap)
  use_capability(call_cap)
  use_capability(write_boom)
  mailbox_send(sender_cap, :start)
  try
    use_capability(read_two)
    use_capability(rw)
    use_capability(vault)
    use_capability(short)
    use_capability(write_denied)
    use_capability(write_expired)
    use_capability(write_allowed)
    let a_rows = A(1)
    let b_rows = B(2)
    assert Rw(1, 2)
    let rw_rows = Rw(1, 2)
    assert Vault(read_two)
    let vault_rows = Vault(read_two)
    let restricted = restrict_capability(read_two, [:read])
    use_capability(restricted)
    revoke_capability(read_two)
    try
      let rows = B(2)
      assert Allowed(1)
    catch err
      assert Denied(1)
    end
    try
      use_capability(read_two)
    catch err
      assert Denied(2)
    end
    suspend(150)
    try
      let rows = Ephemeral(3)
      assert Allowed(2)
    catch err
      assert Expired(1)
    end
  catch err
    assert ChildBoom(err.code)
  end
  mailbox_send(sender_cap, :done)
end
let [receiver, sender] = mailbox()
let child_id = spawn :work(read_two: read_two, rw: rw, vault: vault, short: short, write_denied: write_denied, write_expired: write_expired, write_allowed: write_allowed, write_boom: write_boom, call_cap: call_cap, sender_cap: sender)
require(child_id != 0)
let started = mailbox_recv([receiver], 2000)
require(len(started) == 1)
require(len(mailbox_recv([receiver], 2000)) == 1)
`
	path, path_ok := write_temp_source(t, "mica_capability_full_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(
		&kernel,
		[]string{path},
		context.temp_allocator,
		Run_Options{actor = "alice"},
	)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "ChildBoom", 0)
	expect_relation_rows(t, &kernel, "Denied", 2)
	expect_relation_rows(t, &kernel, "Expired", 1)
	expect_relation_rows(t, &kernel, "Allowed", 0)
	expect_relation_rows(t, &kernel, "Vault", 1)
	expect_relation_rows(t, &kernel, "Rw", 1)
}

@(test)
test_run_mailbox_handle_revocation :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Out, 1)
let [receiver, sender] = mailbox()
revoke_capability(receiver)
try
  mailbox_send(sender, 1)
  assert Out(0)
catch err
  assert Out(1)
end
try
  mailbox_recv([receiver])
  assert Out(2)
catch err
  assert Out(3)
end
let [receiver_two, sender_two] = mailbox()
mailbox_close(receiver_two)
try
  mailbox_send(sender_two, 1)
  assert Out(4)
catch err
  assert Out(5)
end
`
	path, path_ok := write_temp_source(t, "mica_mailbox_revoke_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Out", 3)
}

@(test)
test_run_subscription_changes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Note, 2)
let [receiver, sender] = mailbox()
let sub = subscribe_changes(sender, :facts, some(:Note), [some(1), none], :changes)
assert Note(1, 10)
assert Note(1, 11)
assert Note(2, 12)
commit()
let ready = mailbox_recv([receiver])
let message = ready[0][1][0]
require(index_or(message, :kind, none) == :changes)
let assertions = index_or(message, :assertions, [])
require(len(assertions) == 2)
require(len(index_or(message, :retractions, [])) == 0)
cancel_subscription(sub)
assert Note(1, 13)
commit()
let remaining = mailbox_recv([receiver], 0)
require(len(remaining) == 0)
`
	path, path_ok := write_temp_source(t, "mica_subscription_changes_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Note", 4)
}

@(test)
test_run_subscription_snapshot_and_close :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Note, 2)
make_relation(:CloseFailed, 1)
let [receiver, sender] = mailbox()
assert Note(5, 50)
commit()
let sub = subscribe_changes(sender, :facts, some(:Note), [none, none], :snapshot)
let ready = mailbox_recv([receiver])
let message = ready[0][1][0]
require(index_or(message, :kind, none) == :snapshot)
require(len(index_or(message, :assertions, [])) == 1)

let [receiver_two, sender_two] = mailbox()
let sub_two = subscribe_changes(sender_two, :facts, some(:Note), [none, none], :changes)
mailbox_close(receiver_two)
assert Note(5, 51)
commit()
try
  mailbox_recv([receiver_two])
  assert CloseFailed(0)
catch err
  assert CloseFailed(1)
end
`
	path, path_ok := write_temp_source(t, "mica_subscription_snapshot_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "CloseFailed", 1)
}

@(test)
test_run_buffer_subscription_changes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Seen, 1)
make_buffer(:notes, :durable)
buffer_insert(:notes, 0, "hello")
commit()
let [receiver, sender] = mailbox()
let sub = subscribe_changes(sender, :buffer, some(:notes), [], :changes)
buffer_insert(:notes, 5, " world")
commit()
let ready = mailbox_recv([receiver])
let message = ready[0][1][0]
require(index_or(message, :kind, none) == :changes)
require(index_or(message, :subject, none) == :buffer)
let changes = index_or(message, :changes, [])
require(len(changes) == 1)
let change = changes[0]
require(change[:base_revision] == 1)
require(change[:new_revision] == 2)
let edits = change[:edits]
require(len(edits) == 1)
require(edits[0][:at] == 5)
require(edits[0][:remove] == 0)
require(edits[0][:text] == " world")
cancel_subscription(sub)
assert Seen(1)
`
	path, path_ok := write_temp_source(t, "mica_buffer_subscription_changes_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Seen", 1)
}

@(test)
test_run_buffer_subscription_snapshot :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Seen, 1)
make_buffer(:notes, :durable)
buffer_insert(:notes, 0, "current text")
commit()
let [receiver, sender] = mailbox()
let sub = subscribe_changes(sender, :buffer, some(:notes), [], :snapshot)
let ready = mailbox_recv([receiver])
let message = ready[0][1][0]
require(index_or(message, :kind, none) == :snapshot)
require(index_or(message, :subject, none) == :buffer)
require(index_or(message, :revision, none) == 1)
require(index_or(message, :text, none) == "current text")
cancel_subscription(sub)
assert Seen(1)
`
	path, path_ok := write_temp_source(t, "mica_buffer_subscription_snapshot_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Seen", 1)
}

// A completion token is not a capability. The reader must also have read
// authority for the buffer whose apply produced the result.
@(test)
test_run_buffer_completion_requires_read_authority :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:alice)
make_relation(:CanRead, 2)
make_relation(:CanWrite, 2)
make_relation(:CanInvoke, 2)
make_relation(:Denied, 1)
make_buffer(:secret_notes, :durable)
require buffer_apply(:secret_notes, 0, [{:at -> 0, :remove -> 0, :text -> "secret"}], 9876) == :staged
grant #alice
  write:
    :Denied
  invoke:
    :buffer_apply_result
end
commit()
verb probe_completion()
  try
    buffer_apply_result(9876)
  catch E_PERMISSION
    assert Denied(1)
  end
end
spawn :probe_completion()
suspend()
`
	path, path_ok := write_temp_source(t, "mica_buffer_completion_authority_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	result := run_files(
		&kernel,
		[]string{path},
		context.temp_allocator,
		Run_Options{actor = "alice"},
	)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Denied", 1)
}

// Access to a computed projection does not grant access to its backing
// buffer. The projection must apply the caller's authority to both layers.
@(test)
test_run_buffer_computed_relation_requires_buffer_authority :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:alice)
make_relation(:CanRead, 2)
make_relation(:CanWrite, 2)
make_relation(:BufferLine, 7)
make_relation(:NearestEmbedding, 6)
make_relation(:VectorIndexContains, 2)
make_functional_relation(:EmbeddingOf, 2, [0])
make_functional_relation(:EmbeddingVector, 2, [0])
make_relation(:Denied, 1)
make_buffer(:secret_notes, :durable)
buffer_insert(:secret_notes, 0, "secret")
assert VectorIndexContains(:secret_index, :secret_vector)
assert EmbeddingOf(:secret_vector, :secret_subject)
assert EmbeddingVector(:secret_vector, [1.0, 0.0])
grant #alice
  read:
    :BufferLine
    :NearestEmbedding
  write:
    :Denied
end
commit()
verb probe_projection()
  try
    BufferLine(:secret_notes, 0, 1, ?line, _, _, ?text)
  catch E_PERMISSION
    assert Denied(:buffer)
  end
  try
    NearestEmbedding(:secret_index, [1.0, 0.0], 1, ?subject, _, _)
  catch E_PERMISSION
    assert Denied(:retrieval)
  end
end
spawn :probe_projection()
suspend()
`
	path, path_ok := write_temp_source(t, "mica_buffer_computed_authority_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	result := run_files(
		&kernel,
		[]string{path},
		context.temp_allocator,
		Run_Options{actor = "alice"},
	)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Denied", 2)
}

@(test)
test_run_json_roundtrip :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Out, 1)
let decoded = json_decode("{\"a\":[1,2.5,true,null,1e3],\"b\":\"x\"}")
let items = index_or(decoded, :a, [])
require(items[0] == 1)
require(items[1] == 2.5)
require(items[2] == true)
require(json_is_null(items[3]))
require(items[4] == 1000.0)
require(index_or(decoded, :b, "") == "x")
let encoded = json_encode({:a -> [1, 2.5, true, json_null()], :b -> "x"})
require(encoded == "{\"a\":[1,2.5,true,null],\"b\":\"x\"}")
require(json_decode("\"A\u0041\u00e9\ud83d\ude00\"") == "AAé😀")
try
  json_decode("{} junk")
  assert Out(0)
catch err
  assert Out(1)
end
try
  json_decode("36028797018963968")
  assert Out(2)
catch err
  assert Out(3)
end
assert Out(decoded)
`
	path, path_ok := write_temp_source(t, "mica_json_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Out", 3)
}

@(test)
test_run_rule_enable_disable :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Base, 1)
make_relation(:Derived, 1)
make_relation(:Out, 1)
Derived(x) :- Base(x)
assert Base(1)
commit()
require(Derived(1))
let rules = Rule(?rule)
let rule_count = 0
for found in rules
  disable_rule(found[:rule])
  rule_count = rule_count + 1
end
require(rule_count == 1)
commit()
require(!Derived(1))
for found in rules
  enable_rule(found[:rule])
end
commit()
require(Derived(1))
assert Out(1)
`
	path, path_ok := write_temp_source(t, "mica_rule_toggle_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Out", 1)
}

@(test)
test_run_relation_reflection_facts :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:witness)
make_relation(:Plain, 2)
make_functional_relation(:Keyed, 2, [0], :volatile)
make_relation(:Out, 1)

verb greet(name)
  assert Out(1)
end

let plain_names = RelationName(?rel, :Plain)
for found in plain_names
  let plain = found[:rel]
  require(ConflictPolicy(plain, :set))
  require(RelationDurability(plain, :durable))
end
let keyed_names = RelationName(?rel, :Keyed)
for found in keyed_names
  let keyed = found[:rel]
  require(ConflictPolicy(keyed, :functional))
  require(FunctionalKey(keyed, 0, 0))
  require(RelationDurability(keyed, :volatile))
  let indexes = Index(keyed, ?idx)
  require(len(indexes) == 1)
  let idx = indexes[0][:idx]
  require(IndexPosition(idx, 0, 0))
  require(IndexPosition(idx, 1, 1))
  require(IndexStorageKind(idx, :btree))
end
let endpoints = RelationName(?rel, :Endpoint)
require(len(endpoints) == 1)
for found in endpoints
  let endpoint_rel = found[:rel]
  require(RelationDurability(endpoint_rel, :volatile))
end
let witness = NamedIdentity(?identity, :witness)
require(len(witness) == 1)
let units = UnitSource(0, ?unit, ?text)
require(len(units) == 1)
require(units[0][:unit] == :mica_reflection_facts_test)
let methods = MethodSelector(?mm, :greet)
require(len(methods) == 1)
let m = methods[0][:mm]
let sources = MethodSource(m, ?src)
require(len(sources) == 1)
let text = sources[0][:src]
require(text == "verb greet(name)\n  assert Out(1)\nend")
assert Out(2)
`
	path, path_ok := write_temp_source(t, "mica_reflection_facts_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Out", 1)
}

@(test)
test_run_subscription_relation_derived :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Base, 1)
make_relation(:Derived, 1)
make_relation(:Out, 1)
Derived(x) :- Base(x)
let [receiver, sender] = mailbox()
let sub = subscribe_changes(sender, :relation, some(:Derived), [none], :changes)
assert Base(1)
commit()
let first = mailbox_recv([receiver])
let first_message = first[0][1][0]
require(index_or(first_message, :kind, none) == :changes)
require(index_or(first_message, :subject, none) == :relation)
require(len(index_or(first_message, :assertions, [])) == 1)
assert Base(2)
commit()
let second = mailbox_recv([receiver])
let second_message = second[0][1][0]
require(len(index_or(second_message, :assertions, [])) == 1)
require(len(index_or(second_message, :retractions, [])) == 0)
retract Base(1)
commit()
let third = mailbox_recv([receiver])
let third_message = third[0][1][0]
require(len(index_or(third_message, :assertions, [])) == 0)
require(len(index_or(third_message, :retractions, [])) == 1)
cancel_subscription(sub)
assert Out(1)
`
	path, path_ok := write_temp_source(t, "mica_subscription_relation_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Out", 1)
}

@(test)
test_run_subscription_catalogue :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Base, 1)
make_relation(:Derived, 1)
make_relation(:Out, 1)
Derived(x) :- Base(x)
let [receiver, sender] = mailbox()
let sub = subscribe_changes(sender, :catalogue, none, [], :snapshot)
let ready = mailbox_recv([receiver])
let message = ready[0][1][0]
require(index_or(message, :kind, none) == :snapshot)
require(index_or(message, :subject, none) == :catalogue)
require(len(index_or(message, :entries, [])) > 0)
let rules = Rule(?rule)
for found in rules
  disable_rule(found[:rule])
end
commit()
let changed = mailbox_recv([receiver])
let changes = changed[0][1][0]
require(index_or(changes, :kind, none) == :changes)
require(index_or(changes, :subject, none) == :catalogue)
let entries = index_or(changes, :entries, [])
require(len(entries) == 1)
require(index_or(entries[0], :kind, none) == :rule_disabled)
cancel_subscription(sub)
assert Out(1)
`
	path, path_ok := write_temp_source(t, "mica_subscription_catalogue_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Out", 1)
}

@(test)
test_run_subscription_queue_budget :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Note, 1)
make_relation(:Out, 1)
let [receiver, sender] = mailbox()
let sub = subscribe_changes(sender, :facts, some(:Note), [none], :changes, none, 1)
assert Note(1)
commit()
assert Note(2)
commit()
let ready = mailbox_recv([receiver])
let queued = ready[0][1]
require(len(queued) == 1)
require(index_or(queued[0], :kind, none) == :snapshot)
require(len(index_or(queued[0], :assertions, [])) == 2)
assert Note(3)
assert Note(4)
commit()
let resynced = mailbox_recv([receiver])
let snapshot = resynced[0][1][0]
require(index_or(snapshot, :kind, none) == :snapshot)
require(len(index_or(snapshot, :assertions, [])) == 4)
cancel_subscription(sub)
assert Out(1)
`
	path, path_ok := write_temp_source(t, "mica_subscription_budget_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Out", 1)
}

@(test)
test_run_subscription_revoked_marker :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Note, 1)
make_relation(:Out, 1)
let [receiver, sender] = mailbox()
let sub = subscribe_changes(sender, :facts, some(:Note), [none], :changes)
assert Note(1)
commit()
revoke_capability(sub)
assert Note(2)
commit()
let ready = mailbox_recv([receiver])
let queued = ready[0][1]
require(len(queued) == 1)
require(index_or(queued[0], :kind, none) == :revoked)
assert Out(1)
`
	path, path_ok := write_temp_source(t, "mica_subscription_revoked_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Out", 1)
}

@(test)
test_run_subscription_catalogue_needs_root :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:alice)
make_relation(:Out, 1)
let [receiver, sender] = mailbox()
try
  let sub = subscribe_changes(sender, :catalogue, none, [], :snapshot)
  assert Out(0)
catch err
  assert Out(1)
end
`
	path, path_ok := write_temp_source(t, "mica_subscription_catalogue_denied_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(
		&kernel,
		[]string{path},
		context.temp_allocator,
		Run_Options{actor = "alice"},
	)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Out", 1)
}

@(test)
test_run_assume_actor :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:alice)
make_identity(:bob)
make_identity(:carol)
make_relation(:CanRead, 2)
make_relation(:CanWrite, 2)
make_relation(:session/CanAssumeActor, 2)
make_relation(:Secret, 1)
make_relation(:Out, 1)
make_relation(:Denied, 1)
make_relation(:Phase, 1)
assert CanRead(#bob, :Secret)
assert session/CanAssumeActor(#alice, #bob)
assert Secret(1)
let call_cap = mint_capability(:invoke, [:assume_actor, :actor])
let out_cap = mint_capability(:write, :Out)
let denied_cap = mint_capability(:write, :Denied)
let phase_cap = mint_capability(:write, :Phase)
commit()
verb work(call_cap, out_cap, denied_cap, phase_cap)
  use_capability(call_cap)
  use_capability(out_cap)
  use_capability(denied_cap)
  use_capability(phase_cap)
  if let some(current) = actor()
    if current == #alice
      assert Phase(1)
    else
      assert Phase(2)
    end
  end
  assume_actor(#bob)
  if let some(adopted) = actor()
    if adopted == #bob
      assert Phase(3)
    else
      assert Phase(4)
    end
  end
  if Secret(1)
    assert Out(1)
  end
  try
    assume_actor(#carol)
    assert Denied(0)
  catch err
    assert Denied(1)
  end
end
spawn :work(call_cap: call_cap, out_cap: out_cap, denied_cap: denied_cap, phase_cap: phase_cap)
suspend()
`
	path, path_ok := write_temp_source(t, "mica_assume_actor_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(
		&kernel,
		[]string{path},
		context.temp_allocator,
		Run_Options{actor = "alice"},
	)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Out", 1)
	expect_relation_rows(t, &kernel, "Denied", 1)
	expect_relation_rows(t, &kernel, "Phase", 2)
}

@(test)
test_run_truthiness_and_options :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Flag, 1)
make_relation(:Out, 1)

verb probe()
  let empty = Flag(2)
  if Flag(1)
    assert Out(1)
  end
  if not Flag(2)
    assert Out(2)
  end
  if not empty
    assert Out(3)
  end
  if actor()
    assert Out(4)
  end
  if let some(current) = actor()
    assert Out(5)
  end
  if let some(p) = principal()
    assert Out(6)
  end
  if sync_signature(1, "payload") > 0
    assert Out(7)
  end
  return none
end

assert Flag(1)
probe()
`
	path, path_ok := write_temp_source(t, "mica_truthiness_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Out", 7)
}

@(test)
test_run_relation_algebra :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Person, 2)
make_relation(:Active, 1)
make_relation(:TeamOnce, 1)
make_relation(:PersonActive, 2)
make_relation(:AnyPerson, 1)
make_relation(:Remaining, 1)
make_relation(:Color, 1)

assert Person(:alice, :ops)
assert Person(:bob, :ops)
assert Person(:chandra, :research)
assert Active(:alice)
assert Active(:bob)
assert TeamOnce(:ops)
assert TeamOnce(:research)
assert PersonActive(:alice, :ops)
assert PersonActive(:bob, :ops)
assert AnyPerson(:alice)
assert AnyPerson(:bob)
assert AnyPerson(:chandra)
assert Remaining(:chandra)
assert Color(:red)
assert Color(:blue)

let people = Person(?person, ?team)
let active = Active(?person)
let remaining = Remaining(?person)
let any_person = AnyPerson(?person)

require project(people, :team) == TeamOnce(?team)
require len(project(people)) == 1
require natural_join(people, active) == PersonActive(?person, ?team)
require union(active, remaining) == any_person
require difference(any_person, active) == remaining
require len(natural_join(people, Color(?color))) == 6
`
	path, path_ok := write_temp_source(t, "mica_relation_algebra_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
}

@(test)
test_run_relation_algebra_errors :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Person, 2)
make_relation(:Active, 1)
make_relation(:Caught, 1)

assert Person(:alice, :ops)
assert Active(:alice)

verb probe()
  try
    return union(Person(?person, ?team), Active(?person))
  catch E_INVARG
    return :heading_mismatch
  end
end
assert Caught(probe())
`
	path, path_ok := write_temp_source(t, "mica_relation_algebra_error_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Caught", 1)
}

@(test)
test_run_dom_diff_builtin :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `let patches = dom_diff(dom_text("old"), dom_text("new"))
require len(patches) == 1
require patches[0][:op] == "set_text"
require patches[0][:text] == "new"
require len(patches[0][:path]) == 0

let element_patches = dom_diff(
  dom_element("ul", {}, []),
  dom_element("ul", {:id -> "messages"}, [dom_text("hi")])
)
require len(element_patches) == 2
require element_patches[0][:op] == "set_attr"
require element_patches[0][:name] == "id"
require element_patches[0][:value] == "messages"
require element_patches[1][:op] == "append_child"
require element_patches[1][:node][:text] == "hi"

let sibling_patches = dom_diff(
  dom_element("div", {}, [dom_text("same"), dom_text("old")]),
  dom_element("div", {}, [dom_text("same"), dom_text("new")])
)
require len(sibling_patches) == 1
require sibling_patches[0][:op] == "set_text"
require sibling_patches[0][:text] == "new"
let sibling_path = sibling_patches[0][:path]
require len(sibling_path) == 1
require sibling_path[0] == 1

let deep_patches = dom_diff(
  dom_element("div", {}, [dom_text("same"), dom_element("ul", {}, [dom_text("a"), dom_text("old")])]),
  dom_element("div", {}, [dom_text("same"), dom_element("ul", {}, [dom_text("a"), dom_text("new")])])
)
require len(deep_patches) == 1
require deep_patches[0][:op] == "set_text"
let deep_path = deep_patches[0][:path]
require len(deep_path) == 2
require deep_path[0] == 1
require deep_path[1] == 1
`
	path, path_ok := write_temp_source(t, "mica_dom_diff_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
}

@(test)
test_run_log_builtin :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Caught, 1)

verb probe()
  try
    log(:nope, "bad level")
    return :no_error
  catch E_INVARG
    return :caught
  end
end

log("hello")
log(:debug, "lower level")
assert Caught(probe())
`
	path, path_ok := write_temp_source(t, "mica_log_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Caught", 1)
}

@(test)
test_run_rule_introspection :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:DirectDependency, 2)
make_relation(:DependsOn, 2)

DependsOn(component, dependency) :-
  DirectDependency(component, dependency)

assert DirectDependency(:service_a, :service_b)

let active = rules(:DependsOn)
require len(active) == 1
let source = describe_rule(active[0])
require string_contains(source, "DirectDependency")

disable_rule(active[0])
require len(rules(:DependsOn)) == 0
enable_rule(active[0])
require len(rules(:DependsOn)) == 1
`
	path, path_ok := write_temp_source(t, "mica_rule_introspection_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
}

@(test)
test_run_dom_html_builtin :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Caught, 1)

require dom_html(dom_element("button", {:id -> "send", :type -> "submit"}, [dom_text("Send & go")])) == "<button id=\"send\" type=\"submit\">Send &amp; go</button>"
require dom_html(dom_element("h4", {}, [dom_text("References")])) == "<h4>References</h4>"

let label = "Send & go"
let extra = [dom <span class="note">!</span>]
let composed = dom_html(dom <button id="send" type="submit">{label}{@extra}</button>)
require string_contains(composed, "Send &amp; go")
require string_contains(composed, "<span class=\"note\">!</span>")

let expanded = dom_html(dom_element("img", {:alt -> "Logo", "aria-describedby" -> "caption", "data-route" -> "home", :loading -> "lazy", :src -> "/logo.png"}, []))
require string_starts_with(expanded, "<img ")
require string_contains(expanded, "alt=\"Logo\"")
require string_contains(expanded, "aria-describedby=\"caption\"")
require string_contains(expanded, "data-route=\"home\"")
require string_contains(expanded, "loading=\"lazy\"")
require string_contains(expanded, "src=\"/logo.png\"")

verb probe()
  try
    return dom_html(dom_element("widget", {}, []))
  catch E_TYPE
    return :caught
  end
end
assert Caught(probe())
`
	path, path_ok := write_temp_source(t, "mica_dom_html_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Caught", 1)
}

@(test)
test_run_from_xml_builtin :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Caught, 1)

require to_xml(from_xml("<p>a &amp; b</p>")) == "<p>a &amp; b</p>"
require to_xml(from_xml("<a></a><b></b>")) == "<a></a><b></b>"
require to_xml(from_xml("<ul><!-- note --><li>one</li><li>two</li></ul>")) == "<ul><li>one</li><li>two</li></ul>"
require to_xml(from_xml("<input id='actor'/>")) == "<input id=\"actor\"></input>"

let composer = from_xml("<form id='chat-composer' data-sync-event='submit' data-sync-action='chat_post'><input id='actor' name='actor' autocomplete='name' value='browser' aria-label='Actor'/><input id='message' name='text' autocomplete='off' placeholder='Message' aria-label='Message'/><button id='send' type='submit'>Send</button></form>")
require composer[:tag] == "form"
let rendered = to_xml(composer)
require string_contains(rendered, "<form ")
require string_contains(rendered, "id=\"chat-composer\"")
require string_contains(rendered, "data-sync-event=\"submit\"")
require string_contains(rendered, "data-sync-action=\"chat_post\"")
require string_contains(rendered, "<input ")
require string_contains(rendered, "aria-label=\"Actor\"")
require string_contains(rendered, "<button ")
require string_contains(rendered, ">Send</button>")

verb probe()
  try
    return from_xml("<a><b></a>")
  catch E_INVARG
    return :caught
  end
end
assert Caught(probe())
`
	path, path_ok := write_temp_source(t, "mica_from_xml_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Caught", 1)
}

@(test)
test_run_tasks_builtin :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Slept, 1)
make_relation(:ObservedRunning, 1)
make_relation(:ObservedSuspended, 1)

verb sleeper()
  assert Slept(1)
  suspend(10000)
end

verb observer()
  let snapshot = tasks()
  for entry in snapshot
    if entry[:state] == :running
      assert ObservedRunning(1)
    end
    if entry[:state] == :suspended
      assert ObservedSuspended(1)
    end
  end
end
`
	path, path_ok := write_temp_source(t, "mica_tasks_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	world, start := world_start(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, start.ok, "world start failed: %s", start.message)
	if !start.ok {
		return
	}
	defer world_destroy(world)
	entry := world_wait(world, world.entry)
	testing.expect_value(t, entry.kind, Task_Outcome_Kind.Complete)

	sleeper_id := world_submit_call(world, "sleeper", nil)
	testing.expect(t, sleeper_id != 0)

	// Wait until the sleeper has asserted its fact and parked.
	slept := false
	deadline := time.tick_now()
	for time.tick_since(deadline) < 2 * time.Second {
		snapshot := k.kernel_snapshot(&kernel)
		metadata, found := k.snapshot_relation_metadata_named(snapshot, v.symbol_intern("Slept"))
		k.snapshot_release(snapshot)
		if found {
			one, _ := v.value_int(1)
			if k.kernel_contains(
				&kernel,
				metadata.id,
				v.tuple_new(context.temp_allocator, []v.Value{one}),
			) {
				slept = true
				break
			}
		}
		time.sleep(1 * time.Millisecond)
	}
	testing.expect(t, slept, "sleeper did not park")

	observer := world_call(world, "observer", nil)
	testing.expectf(t, observer.kind == .Complete, "observer failed: %s", observer.message)
	expect_relation_rows(t, &kernel, "ObservedRunning", 1)
	expect_relation_rows(t, &kernel, "ObservedSuspended", 1)
}

@(test)
test_run_destroy_identity :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:thing)
make_identity(:room)
make_relation(:Object, 1)
make_relation(:LocatedIn, 2)
make_relation(:Destroyed, 1)

assert Object(#thing)
assert Object(#room)
assert LocatedIn(#thing, #room)
assert LocatedIn(#room, #thing)
assert Destroyed(destroy_identity(#thing))

require Object(#room)
require LocatedIn(#room, #thing)
require !Object(#thing)
require !LocatedIn(#thing, #room)
`
	path, path_ok := write_temp_source(t, "mica_destroy_identity_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Destroyed", 1)
	expect_relation_rows(t, &kernel, "Object", 1)
	expect_relation_rows(t, &kernel, "LocatedIn", 1)

	// Two subject facts and the NamedIdentity name binding were retracted.
	metadata, found := k.snapshot_relation_metadata_named(
		k.kernel_snapshot(&kernel),
		v.symbol_intern("Destroyed"),
	)
	testing.expect(t, found)
	if found {
		rows: [dynamic]v.Tuple
		k.kernel_scan_into(&kernel, metadata.id, []v.Binding{{}}, &rows)
		if len(rows) == 1 {
			count, is_int := v.value_as_int(v.tuple_values(rows[0])[0])
			testing.expectf(t, is_int && count == 3, "destroyed count %d", count)
		}
		delete(rows)
	}
}

@(test)
test_run_fileout_rules :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:DirectDependency, 2)
make_relation(:DependsOn, 2)

DependsOn(component, dependency) :-
  DirectDependency(component, dependency)

require fileout_rules(:DependsOn) == "DependsOn(component, dependency) :-\n  DirectDependency(component, dependency)"
require fileout_rules(:DirectDependency) == ""
require string_contains(fileout_rules(), "DirectDependency")

let rule = rules(:DependsOn)
disable_rule(rule[0])
require fileout_rules(:DependsOn) == ""
`
	path, path_ok := write_temp_source(t, "mica_fileout_rules_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
}

@(test)
test_run_fileout_unit :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Source, 1)
make_relation(:Caught, 1)

assert Source(fileout(:example))

verb probe()
  try
    return fileout(:missing)
  catch E_INVARG
    return :caught
  end
end
assert Caught(probe())
`
	path, path_ok := write_temp_source(t, "mica_fileout_unit_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(
		&kernel,
		[]string{path},
		context.temp_allocator,
		Run_Options{unit = "example"},
	)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Caught", 1)

	snapshot := k.kernel_snapshot(&kernel)
	metadata, found := k.snapshot_relation_metadata_named(snapshot, v.symbol_intern("Source"))
	k.snapshot_release(snapshot)
	testing.expect(t, found)
	if !found {
		return
	}
	rows: [dynamic]v.Tuple
	defer delete(rows)
	k.kernel_scan_into(&kernel, metadata.id, []v.Binding{{}}, &rows)
	if len(rows) != 1 {
		testing.expectf(t, false, "Source has %d rows", len(rows))
		return
	}
	text, is_string := v.value_as_string(v.tuple_values(rows[0])[0])
	testing.expect(t, is_string)
	testing.expectf(t, text == source, "fileout text: %q", text)
}

@(test)
test_run_read_waits_for_input :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `verb ask()
  return read()
end

verb answer()
  return read(:line)
end
`
	path, path_ok := write_temp_source(t, "mica_read_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	world, start := world_start(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, start.ok, "world start failed: %s", start.message)
	if !start.ok {
		return
	}
	defer world_destroy(world)
	entry := world_wait(world, world.entry)
	testing.expect_value(t, entry.kind, Task_Outcome_Kind.Complete)

	answer_id := world_submit_call(world, "answer", nil)
	testing.expect(t, answer_id != 0)
	metadata := v.Value(0)
	has_request := false
	deadline := time.tick_now()
	for time.tick_since(deadline) < 2 * time.Second {
		metadata, has_request = world_task_request(world, answer_id)
		if has_request {
			break
		}
		time.sleep(1 * time.Millisecond)
	}
	testing.expect(t, has_request)
	symbol, is_symbol := v.value_as_symbol(metadata)
	testing.expect(t, is_symbol)
	name, has_name := v.symbol_name(symbol)
	testing.expect(t, has_name)
	testing.expect_value(t, name, "line")

	input := v.value_string(context.temp_allocator, "look")
	testing.expect(t, world_resume(world, answer_id, input))
	answer := world_wait(world, answer_id)
	testing.expect_value(t, answer.kind, Task_Outcome_Kind.Complete)
	text, is_text := v.value_as_string(answer.value)
	testing.expect(t, is_text)
	testing.expect_value(t, text, "look")
	world_release(world, answer_id)

	// A read with no metadata waits without a request value.
	ask_id := world_submit_call(world, "ask", nil)
	testing.expect(t, ask_id != 0)
	ask_parked := false
	deadline = time.tick_now()
	for time.tick_since(deadline) < 2 * time.Second {
		_, ask_parked = world_task_request(world, ask_id)
		if ask_parked {
			break
		}
		time.sleep(1 * time.Millisecond)
	}
	testing.expect(t, ask_parked)
	done := v.value_symbol(v.symbol_intern("done"))
	testing.expect(t, world_resume(world, ask_id, done))
	ask_answer := world_wait(world, ask_id)
	testing.expect_value(t, ask_answer.kind, Task_Outcome_Kind.Complete)
	testing.expect(t, v.value_eq(ask_answer.value, done))
	world_release(world, ask_id)
}

@(test)
test_run_store_boot :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:alice)
make_relation(:Marker, 2)
make_relation(:BufferStat, 4)
make_buffer(:notes, :durable)
buffer_insert(:notes, 0, "persistent text")

verb mark(who)
  assert Marker(who, :marked)
end
verb buffer_size()
  let exactly {:length -> length} = BufferStat(:notes, ?length, _, _)
  return length
end
assert Marker(#alice, :seed)
`
	path, path_ok := write_temp_source(t, "mica_store_boot_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	directory, directory_error := os.temp_dir(context.temp_allocator)
	if directory_error != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	store_path, join_error := filepath.join(
		[]string{directory, "mica_store_boot"},
		context.temp_allocator,
	)
	if join_error != nil {
		return
	}
	os.remove_all(store_path)
	defer os.remove_all(store_path)

	// First world: load from source and persist.
	{
		kernel: k.Kernel
		k.kernel_init(&kernel)
		world, start := world_start(
			&kernel,
			[]string{path},
			context.temp_allocator,
			World_Config{store_path = store_path},
		)
		testing.expectf(t, start.ok, "load failed: %s", start.message)
		if start.ok {
			entry := world_wait(world, world.entry)
			testing.expect_value(t, entry.kind, Task_Outcome_Kind.Complete)
			who := v.value_symbol(v.symbol_intern("alice"))
			outcome := world_call(
				world,
				"mark",
				[]k.Role_Pair{{role = v.value_symbol(v.symbol_intern("who")), value = who}},
			)
			testing.expect_value(t, outcome.kind, Task_Outcome_Kind.Complete)
			testing.expect(t, world_checkpoint(world))
			world_destroy(world)
		}
		k.kernel_destroy(&kernel)
	}

	// Second world: boot from the store with no source paths.
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := world_start(
		&kernel,
		nil,
		context.temp_allocator,
		World_Config{store_path = store_path},
	)
	testing.expectf(t, start.ok, "boot failed: %s", start.message)
	if !start.ok {
		return
	}
	defer world_destroy(world)
	testing.expect_value(t, world.entry, Task_ID(0))
	testing.expect(t, len(world.env.unit_sources) >= 1)
	expect_relation_rows(t, &kernel, "Marker", 2)

	// Code and identity names are restored; the verb runs against them.
	alice, has_alice := world.ctx.identities["alice"]
	testing.expect(t, has_alice)
	outcome := world_call(
		world,
		"mark",
		[]k.Role_Pair{{role = v.value_symbol(v.symbol_intern("who")), value = alice}},
	)
	testing.expectf(t, outcome.kind == .Complete, "call failed: %s", outcome.message)
	expect_relation_rows(t, &kernel, "Marker", 3)
	stat := world_call(world, "buffer_size", nil)
	testing.expectf(
		t,
		stat.kind == .Complete,
		"computed relation after boot failed: %s",
		stat.message,
	)
	length, length_ok := v.value_as_int(stat.value)
	testing.expect(t, length_ok)
	testing.expect_value(t, length, i64(15))
}

@(test)
test_run_records_program_bytes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:alice)
make_relation(:Marker, 2)

verb mark(who)
  assert Marker(who, :marked)
end
assert Marker(#alice, :seed)
`
	path, path_ok := write_temp_source(t, "mica_program_bytes_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	directory, directory_error := os.temp_dir(context.temp_allocator)
	if directory_error != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	store_path, join_error := filepath.join(
		[]string{directory, "mica_program_bytes"},
		context.temp_allocator,
	)
	if join_error != nil {
		return
	}
	os.remove_all(store_path)
	defer os.remove_all(store_path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := world_start(
		&kernel,
		[]string{path},
		context.temp_allocator,
		World_Config{store_path = store_path},
	)
	testing.expectf(t, start.ok, "load failed: %s", start.message)
	if !start.ok {
		return
	}
	defer world_destroy(world)
	entry := world_wait(world, world.entry)
	testing.expect_value(t, entry.kind, Task_Outcome_Kind.Complete)
	testing.expect(t, world_checkpoint(world))

	// Exactly one ProgramBytes row, keyed by content identity.
	rows: [dynamic]v.Tuple
	defer delete(rows)
	k.kernel_scan_into(&kernel, k.SYSTEM_PROGRAM_BYTES_ID, []v.Binding{{}, {}}, &rows)
	testing.expect_value(t, len(rows), 1)
	if len(rows) != 1 {
		return
	}
	values := v.tuple_values(rows[0])
	program_id, id_ok := v.value_as_identity(values[0])
	testing.expect(t, id_ok)
	artifact, artifact_ok := v.value_as_bytes(values[1])
	testing.expect(t, artifact_ok)
	if !id_ok || !artifact_ok {
		return
	}
	testing.expect(t, len(artifact) > 0)

	// The row decodes to a valid program whose fingerprint is the row id.
	// Decoded into the temporary allocator; the deferred free_all reclaims
	// it, so no program_destroy (which frees individual slices).
	program, decode_error := vm.program_from_bytes(artifact, context.temp_allocator)
	testing.expect_value(t, decode_error, vm.Artifact_Error.None)
	if program == nil {
		return
	}
	testing.expect_value(t, vm.program_validate(program), vm.Program_Error.None)
	testing.expect_value(
		t,
		v.identity_raw(program_id),
		vm.program_artifact_fingerprint(artifact) & v.IDENTITY_MAX,
	)
	testing.expect_value(t, len(program.functions), len(world.program.functions))
	testing.expect_value(t, program.entry, world.program.entry)
}

@(test)
test_run_boot_resolves_program_bytes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:alice)
make_relation(:Marker, 2)

verb mark(who)
  assert Marker(who, :marked)
end
assert Marker(#alice, :seed)
`
	path, path_ok := write_temp_source(t, "mica_boot_artifact_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	directory, directory_error := os.temp_dir(context.temp_allocator)
	if directory_error != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	store_path, join_error := filepath.join(
		[]string{directory, "mica_boot_artifact"},
		context.temp_allocator,
	)
	if join_error != nil {
		return
	}
	os.remove_all(store_path)
	defer os.remove_all(store_path)

	// First world: load from source, then retract every UnitSource row so a
	// boot cannot recompile; only the program artifact can supply the code.
	{
		kernel: k.Kernel
		k.kernel_init(&kernel)
		world, start := world_start(
			&kernel,
			[]string{path},
			context.temp_allocator,
			World_Config{store_path = store_path},
		)
		testing.expectf(t, start.ok, "load failed: %s", start.message)
		if start.ok {
			entry := world_wait(world, world.entry)
			testing.expect_value(t, entry.kind, Task_Outcome_Kind.Complete)

			unit_rows: [dynamic]v.Tuple
			k.kernel_scan_into(
				&kernel,
				k.SYSTEM_UNIT_SOURCE_ID,
				[]v.Binding{{}, {}, {}},
				&unit_rows,
			)
			testing.expect(t, len(unit_rows) >= 1)
			tx := k.kernel_begin(&kernel)
			for row in unit_rows {
				testing.expect_value(
					t,
					k.transaction_retract(&tx, k.SYSTEM_UNIT_SOURCE_ID, row),
					k.Kernel_Error.None,
				)
			}
			delete(unit_rows)
			committed, commit_err := k.transaction_commit(&tx)
			testing.expect_value(t, commit_err, k.Kernel_Error.None)
			k.snapshot_release(committed)
			k.transaction_destroy(&tx)

			testing.expect(t, world_checkpoint(world))
			world_destroy(world)
		}
		k.kernel_destroy(&kernel)
	}

	// Second world: boot from the store with no source paths and no stored
	// sources. Dispatch must resolve through the artifact.
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := world_start(
		&kernel,
		nil,
		context.temp_allocator,
		World_Config{store_path = store_path},
	)
	testing.expectf(t, start.ok, "boot failed: %s", start.message)
	if !start.ok {
		return
	}
	defer world_destroy(world)
	testing.expect(t, len(world.sources) == 0)

	alice, has_alice := world.ctx.identities["alice"]
	testing.expect(t, has_alice)
	outcome := world_call(
		world,
		"mark",
		[]k.Role_Pair{{role = v.value_symbol(v.symbol_intern("who")), value = alice}},
	)
	testing.expectf(t, outcome.kind == .Complete, "call failed: %s", outcome.message)

	// Boot resolves; it never backfills a second row.
	rows: [dynamic]v.Tuple
	defer delete(rows)
	k.kernel_scan_into(&kernel, k.SYSTEM_PROGRAM_BYTES_ID, []v.Binding{{}, {}}, &rows)
	testing.expect_value(t, len(rows), 1)
}

@(test)
test_run_artifact_boot_matches_recompile_boot :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:alice)
make_relation(:Log, 2)

verb ping(who)
  assert Log(who, :pinged)
  return 1
end

verb ping(who, marker)
  assert Log(who, marker)
  return 2
end

verb echo(who)
  return who
end

assert Log(#alice, :seed)
`
	path, path_ok := write_temp_source(t, "mica_boot_equivalence_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	directory, directory_error := os.temp_dir(context.temp_allocator)
	if directory_error != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	artifact_store, join_error := filepath.join(
		[]string{directory, "mica_boot_equiv_artifact"},
		context.temp_allocator,
	)
	recompile_store, rejoin_error := filepath.join(
		[]string{directory, "mica_boot_equiv_recompile"},
		context.temp_allocator,
	)
	if join_error != nil || rejoin_error != nil {
		return
	}
	os.remove_all(artifact_store)
	defer os.remove_all(artifact_store)
	os.remove_all(recompile_store)
	defer os.remove_all(recompile_store)

	testing.expect(t, boot_equivalence_load(t, path, artifact_store, false))
	testing.expect(t, boot_equivalence_load(t, path, recompile_store, true))

	artifact_values, artifact_rows, artifact_ok := boot_equivalence_boot(t, artifact_store)
	recompile_values, recompile_rows, recompile_ok := boot_equivalence_boot(t, recompile_store)
	testing.expect(t, artifact_ok && recompile_ok)
	if !artifact_ok || !recompile_ok {
		return
	}
	for index in 0 ..< 3 {
		testing.expectf(
			t,
			v.value_eq(artifact_values[index], recompile_values[index]),
			"result %d differs between boots",
			index,
		)
	}
	testing.expect_value(t, artifact_rows, recompile_rows)
	testing.expect_value(t, artifact_rows, 3)
}

// Runs the call script against a booted world, returning the three result
// values plus the Log row count for comparison.
@(private)
boot_equivalence_exercise :: proc(
	t: ^testing.T,
	world: ^World,
	kernel: ^k.Kernel,
	alice: v.Value,
) -> (
	[3]v.Value,
	int,
	bool,
) {
	who_role := v.value_symbol(v.symbol_intern("who"))
	marker_role := v.value_symbol(v.symbol_intern("marker"))
	loud := v.value_symbol(v.symbol_intern("loud"))

	first := world_call(world, "ping", []k.Role_Pair{{role = who_role, value = alice}})
	if first.kind != .Complete {
		return {}, 0, false
	}
	second := world_call(
		world,
		"ping",
		[]k.Role_Pair{{role = who_role, value = alice}, {role = marker_role, value = loud}},
	)
	if second.kind != .Complete {
		return {}, 0, false
	}
	third := world_call(world, "echo", []k.Role_Pair{{role = who_role, value = alice}})
	if third.kind != .Complete {
		return {}, 0, false
	}

	rows: [dynamic]v.Tuple
	defer delete(rows)
	metadata, found := k.snapshot_relation_metadata_named(kernel.current, v.symbol_intern("Log"))
	if !found {
		return {}, 0, false
	}
	bindings := make([]v.Binding, metadata.arity, context.temp_allocator)
	k.kernel_scan_into(kernel, metadata.id, bindings, &rows)
	return [3]v.Value{first.value, second.value, third.value}, len(rows), true
}

// Loads the fixture into store_path; when strip is set the ProgramBytes
// rows are retracted first, so the later boot takes the legacy recompile
// path instead of the artifact path.
@(private)
boot_equivalence_load :: proc(t: ^testing.T, path, store_path: string, strip: bool) -> bool {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := world_start(
		&kernel,
		[]string{path},
		context.temp_allocator,
		World_Config{store_path = store_path},
	)
	if !start.ok {
		testing.expectf(t, false, "load failed: %s", start.message)
		return false
	}
	entry := world_wait(world, world.entry)
	ok := entry.kind == .Complete
	if ok && strip {
		artifact_rows: [dynamic]v.Tuple
		k.kernel_scan_into(&kernel, k.SYSTEM_PROGRAM_BYTES_ID, []v.Binding{{}, {}}, &artifact_rows)
		tx := k.kernel_begin(&kernel)
		for row in artifact_rows {
			if k.transaction_retract(&tx, k.SYSTEM_PROGRAM_BYTES_ID, row) != k.Kernel_Error.None {
				ok = false
			}
		}
		delete(artifact_rows)
		committed, commit_err := k.transaction_commit(&tx)
		k.snapshot_release(committed)
		k.transaction_destroy(&tx)
		ok = ok && commit_err == k.Kernel_Error.None
	}
	ok = ok && world_checkpoint(world)
	world_destroy(world)
	return ok
}

// Boots store_path sourceless and exercises it.
@(private)
boot_equivalence_boot :: proc(t: ^testing.T, store_path: string) -> ([3]v.Value, int, bool) {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := world_start(
		&kernel,
		nil,
		context.temp_allocator,
		World_Config{store_path = store_path},
	)
	if !start.ok {
		testing.expectf(t, false, "boot failed: %s", start.message)
		return {}, 0, false
	}
	defer world_destroy(world)
	alice, has_alice := world.ctx.identities["alice"]
	if !has_alice {
		return {}, 0, false
	}
	return boot_equivalence_exercise(t, world, &kernel, alice)
}

@(test)
test_assemble_description_round_trip :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `verb build()
  return assemble({:entry -> 0,
    :code -> [{:op -> :Load_Const, :flags -> 0, :a -> 0, :b -> 0, :c -> 0},
              {:op -> :Return, :flags -> 0, :a -> 0, :b -> 0, :c -> 0}],
    :constants -> [41, "seven", true],
    :functions -> [{:name -> "main", :code_offset -> 0, :code_len -> 2, :registers -> 1,
                    :params -> 0, :required -> 0, :rest -> false, :defaults -> []}],
    :patterns -> [{:relation -> 99, :columns -> [:x, :y],
                   :cells -> [{:kind -> :Const, :operand -> 0}, {:kind -> :Bind, :operand -> 0},
                              {:kind -> :Output, :operand -> 1}, {:kind -> :Wildcard, :operand -> -1}]}],
    :shapes -> [[:a, :b]],
    :specs -> [{:selector -> :go, :roles -> [{:role -> :x, :register -> 0}]}],
    :builtins -> [:len]})
end

verb build_no_entry()
  return assemble({:code -> []})
end

verb build_bad_op()
  return assemble({:entry -> 0,
    :code -> [{:op -> :Nope, :flags -> 0, :a -> 0, :b -> 0, :c -> 0}]})
end

verb build_bad_entry()
  return assemble({:entry -> 5})
end
`
	path, path_ok := write_temp_source(t, "mica_assemble_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := world_start(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, start.ok, "load failed: %s", start.message)
	if !start.ok {
		return
	}
	defer world_destroy(world)
	entry := world_wait(world, world.entry)
	testing.expect_value(t, entry.kind, Task_Outcome_Kind.Complete)

	outcome := world_call(world, "build", nil)
	testing.expectf(t, outcome.kind == .Complete, "assemble failed: %s", outcome.message)
	if outcome.kind != .Complete {
		return
	}
	artifact, artifact_ok := v.value_as_bytes(outcome.value)
	testing.expect(t, artifact_ok)
	if !artifact_ok {
		return
	}
	program, decode_error := vm.program_from_bytes(artifact, context.temp_allocator)
	testing.expect_value(t, decode_error, vm.Artifact_Error.None)
	if program == nil {
		return
	}
	testing.expect_value(t, vm.program_validate(program), vm.Program_Error.None)
	testing.expect_value(t, program.entry, 0)
	testing.expect_value(t, len(program.code), 2)
	testing.expect_value(t, len(program.constants), 3)
	testing.expect_value(t, len(program.functions), 1)
	testing.expect_value(t, len(program.patterns), 1)
	testing.expect_value(t, len(program.relation_shapes), 1)
	testing.expect_value(t, len(program.dispatch_specs), 1)
	testing.expect_value(t, len(program.builtins), 1)
	testing.expect(t, program.dispatch_method_selector_relation != 0)
	if first, ok := v.value_as_int(program.constants[0]); ok {
		testing.expect_value(t, first, i64(41))
	} else {
		testing.expect(t, false, "first constant did not decode as an int")
	}

	// Malformed descriptions fail the call instead of producing bytes.
	bad_names := []string{"build_no_entry", "build_bad_op", "build_bad_entry"}
	for name in bad_names {
		failed := world_call(world, name, nil)
		testing.expectf(t, failed.kind != .Complete, "%s unexpectedly succeeded", name)
	}
}

@(test)
test_comprehension_exec :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `verb comp_map()
  let got = [x + 1 for x in [1, 2, 3]]
  return len(got) == 3 && got[0] == 2 && got[1] == 3 && got[2] == 4
end

verb comp_filter()
  let got = [n for n in [1, 2, 3, 4] if n == 2]
  return len(got) == 1 && got[0] == 2
end

verb comp_sort()
  let got = [n for n in [3, 1, 2] sort]
  return len(got) == 3 && got[0] == 1 && got[1] == 2 && got[2] == 3
end

verb comp_sort_key()
  let got = [pair[1] for pair in [[1, 2], [0, 3]] sort pair[0]]
  return len(got) == 2 && got[0] == 3 && got[1] == 2
end

verb comp_pattern()
  let got = [a + b for [a, b] in [[1, 2], [3, 4]]]
  return len(got) == 2 && got[0] == 3 && got[1] == 7
end

verb comp_map_pattern()
  let got = [v for {v} in [{:v -> 5}, {:v -> 7}]]
  return len(got) == 2 && got[0] == 5 && got[1] == 7
end
`
	path, path_ok := write_temp_source(t, "mica_comprehension_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := world_start(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, start.ok, "load failed: %s", start.message)
	if !start.ok {
		return
	}
	defer world_destroy(world)
	entry := world_wait(world, world.entry)
	testing.expect_value(t, entry.kind, Task_Outcome_Kind.Complete)

	names := []string {
		"comp_map",
		"comp_filter",
		"comp_sort",
		"comp_sort_key",
		"comp_pattern",
		"comp_map_pattern",
	}
	for name in names {
		outcome := world_call(world, name, nil)
		testing.expectf(t, outcome.kind == .Complete, "%s failed: %s", name, outcome.message)
		if outcome.kind != .Complete {
			continue
		}
		flag, flag_ok := v.value_as_bool(outcome.value)
		testing.expectf(t, flag_ok && flag, "%s returned false", name)
	}
}

// The shared list library: higher-order verbs over #list, called directly and
// through receiver dispatch, alongside a `-> map` annotation to prove the verb
// name does not shadow the type.
@(test)
test_run_list_functional_verbs :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	library := corpus_relative("apps/shared/list.mica")
	if library == "" {
		testing.expect(t, false, "apps/shared/list.mica not found")
		return
	}

	source := `make_relation(:Result, 2)
assert Result(1, map([1, 2, 3], fn(x) => x * 2) == [2, 4, 6])
assert Result(2, filter([1, 2, 3, 4], fn(x) => x == 2) == [2])
assert Result(3, fold([1, 2, 3], 0, fn(acc, x) => acc + x) == 6)
assert Result(4, find([1, 2, 3], fn(x) => x > 1) == 2)
assert Result(5, find([1, 2, 3], fn(x) => x > 9) == none)
assert Result(6, any([1, 2, 3], fn(x) => x == 3))
assert Result(7, all([1, 2, 3], fn(x) => x > 0))
assert Result(8, !all([1, 2, 3], fn(x) => x > 1))
assert Result(9, flat_map([[1, 2], [3]], fn(xs) => xs) == [1, 2, 3])
assert Result(10, zip([1, 2], ["a", "b"]) == [[1, "a"], [2, "b"]])
assert Result(11, take([1, 2, 3], 2) == [1, 2])
assert Result(12, drop([1, 2, 3], 1) == [2, 3])
assert Result(13, [1, 2, 3, 4] :filter(fn(x) => x != 2) :map(fn(x) => x * 10) == [10, 30, 40])
assert Result(14, len(each([1, 2], fn(x) => x)) == 2)

verb annotate() -> map
  return {:answer -> 42}
end

assert Result(15, annotate()[:answer] == 42)
assert Result(16, [row[:k] for row in __relation_literal([:k], [[1], [2]])] == [1, 2])
`
	path, path_ok := write_temp_source(t, "mica_list_functional_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{library, path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Result", 16)
}

@(test)
test_query_value_filter :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `verb qfilter()
  let rows = __relation_literal([:node, :role], [[1, :kind], [2, :other], [1, :other]])
  let found = []
  for {node -> 1, role -> r} in rows
    found = [@found, r]
  end
  return len(found) == 2 && found[0] == :kind && found[1] == :other
end

verb qempty()
  let rows = __relation_literal([:node, :role], [[1, :kind]])
  let found = []
  for {node -> 9, role -> r} in rows
    found = [@found, r]
  end
  return len(found) == 0
end

verb qbind()
  let rows = __relation_literal([:node, :role], [[1, :kind], [2, :other]])
  let found = []
  for {node -> n, role -> r} in rows
    found = [@found, n]
  end
  return len(found) == 2 && found[0] == 1 && found[1] == 2
end
`
	path, path_ok := write_temp_source(t, "mica_query_value_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := world_start(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, start.ok, "load failed: %s", start.message)
	if !start.ok {
		return
	}
	defer world_destroy(world)
	entry := world_wait(world, world.entry)
	testing.expect_value(t, entry.kind, Task_Outcome_Kind.Complete)

	names := []string{"qfilter", "qempty", "qbind"}
	for name in names {
		outcome := world_call(world, name, nil)
		testing.expectf(t, outcome.kind == .Complete, "%s failed: %s", name, outcome.message)
		if outcome.kind != .Complete {
			continue
		}
		flag, flag_ok := v.value_as_bool(outcome.value)
		testing.expectf(t, flag_ok && flag, "%s returned false", name)
	}
}

@(test)
test_mica_emitter_matches_odin :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		testing.expect(t, false, "cannot initialize test arena")
		return
	}
	defer virtual.arena_destroy(&arena)
	alloc := virtual.arena_allocator(&arena)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := world_start(
		&kernel,
		[]string{"apps/compiler/lex.mica", "apps/compiler/parse.mica", "apps/compiler/emit.mica"},
		context.temp_allocator,
	)
	testing.expectf(t, start.ok, "compiler load failed: %s", start.message)
	if !start.ok {
		return
	}
	defer world_destroy(world)
	entry := world_wait(world, world.entry)
	testing.expect_value(t, entry.kind, Task_Outcome_Kind.Complete)

	cases := [?]string {
		"1 + 2 * 3",
		"let x = 1 + 2 * 3\nlet y = x - 1\ny",
		"let x = 10\nx = x + 1\nx",
		"return 2 + 3",
		"1.5 + 2.5",
		"true",
		"7 % 3",
		"1 < 2",
		"1 <= 1",
		"2 > 1",
		"2 >= 2",
		"1 == 1",
		"1 != 2",
		"-5",
		"!true",
		"\"hello\"",
		"\"a\\tb\"",
		"\"say \\\"hi\\\"\"",
		"\"a\\0b\"",
		":widget",
		"#42",
		"E_FAIL",
		"[1, 2, 3]",
		"{:a -> 1, :b -> 2}",
		"[10, 20, 30][1]",
		"{:a -> 7}[:a]",
		"let xs = [4, 5]\nxs[0] + xs[1]",
		"let m = {:k -> 9}\nm[:k]",
		"if 1 < 2\n  10\nelse\n  20\nend",
		"if 2 < 1\n 10\nend",
		"if false\n 1\nelseif true\n 2\nelse\n 3\nend",
		"let n = 0\nlet i = 0\nwhile i < 5\n n = n + i\n i = i + 1\nend\nn",
		"let n = 0\nlet i = 0\nwhile i < 10\n i = i + 1\n if i == 3\n  break\n end\n n = n + 1\nend\nn",
		"let n = 0\nlet i = 0\nwhile i < 5\n i = i + 1\n if i == 2\n  continue\n end\n n = n + i\nend\nn",
		"begin\n 1\n 2\n 3\nend",
		"let x = 4\nif x > 3\n \"big\"\nelse\n \"small\"\nend",
		"let n = 0\nfor v in [10, 20, 30]\n n = n + v\nend\nn",
		"let n = 0\nfor v, i in [10, 20, 30]\n n = n + i\nend\nn",
		"let n = 0\nfor v in [1, 2, 3, 4]\n if v == 3\n  break\n end\n n = n + v\nend\nn",
		"verb double(x)\n x * 2\nend\ndouble(21)",
		"verb add(a, b)\n a + b\nend\nadd(1, 2) * add(3, 4)",
		"verb fact(n)\n if n < 2\n  1\n else\n  n * fact(n - 1)\n end\nend\nfact(5)",
		"verb classify(n)\n if n < 0\n  \"neg\"\n elseif n == 0\n  \"zero\"\n else\n  \"pos\"\n end\nend\nclassify(-3)",
		"len([1, 2, 3, 4])",
		"verb size(xs)\n len(xs)\nend\nsize([7, 8])",
		"let xs = [1, 2]\n[@xs, 3]",
		"let a = [1]\nlet b = [2]\n[@a, @b]",
		"let xs = []\nlet i = 0\nwhile i < 5\n xs = [@xs, i]\n i = i + 1\nend\nlen(xs)",
		"let total = 0\nfor [a, b] in [[1, 2], [3, 4]]\n total = total + a + b\nend\ntotal",
		"let total = 0\nfor _ in [1, 2, 3]\n total = total + 1\nend\ntotal",
		"[x + 1 for x in [1, 2, 3]]",
		"[n for n in [1, 2, 3, 4] if n == 2]",
		"[n for n in [3, 1, 2] sort]",
		"[pair[1] for pair in [[1, \"b\"], [0, \"a\"]] sort pair[0]]",
		"[a + b for [a, b] in [[1, 2], [3, 4]]]",
		"let add = fn(a, b) => a + b\nadd(3, 4)",
		"verb make_adder(base)\n fn(value) => base + value\nend\nlet add5 = make_adder(5)\nadd5(3)",
		"let x = 10\nlet f = fn() => x\nf()",
		"let f = fn(n)\n n * n\nend\nf(6)",
		"let make = fn(base) => fn(v) => base + v\nlet add10 = make(10)\nadd10(7)",
		"let fact = fn f(n) => if n < 2\n 1\nelse\n n * f(n - 1)\nend\nfact(5)",
		"b\"YWJj\"",
		"1..5",
		"[:x, :y] {[1, 2], [3, 4]}",
		"let [first, ?second = \"dflt\", @rest] = [\"a\"]\n[first, second, rest]",
		"let [first, ?second = \"dflt\", @rest] = [\"a\", \"b\", \"c\"]\n[first, second, rest]",
		"let [a, @more] = [1, 2, 3]\n[a, more]",
	}
	for source in cases {
		if !mica_emitter_matches_odin(t, world, source, alloc) {
			testing.expectf(t, false, "emitter mismatch for %q", source)
		}
	}
}

// Compiles `source` with both emitters, runs both programs, and compares
// the results.
@(private)
mica_emitter_matches_odin :: proc(
	t: ^testing.T,
	world: ^World,
	source: string,
	alloc: mem.Allocator,
) -> bool {
	// Odin baseline: parse, compile with a bare context, run.
	ast, parse_errors := c.parse_program(source, context.temp_allocator)
	if len(parse_errors) > 0 {
		testing.expectf(t, false, "odin parse failed for %q", source)
		return false
	}
	ctx := c.Compile_Context {
		builtins   = make(map[string]bool, context.temp_allocator),
		relations  = make(map[string]u32, context.temp_allocator),
		identities = make(map[string]v.Value, context.temp_allocator),
	}
	compiled := c.compile_program(ast, &ctx, context.temp_allocator)
	if len(compiled.errors) > 0 {
		testing.expectf(t, false, "odin compile failed for %q", source)
		return false
	}
	odin_state: vm.VM
	vm.vm_init(&odin_state, compiled.program, alloc)
	defer vm.vm_destroy(&odin_state)
	register_runtime_builtins(&odin_state)
	if vm.vm_run(&odin_state) != .Halted {
		testing.expectf(t, false, "odin program did not halt for %q", source)
		return false
	}

	// Mica path: emit to bytes through the world, decode, run.
	outcome := world_call(
		world,
		"emit_source",
		[]k.Role_Pair {
			{
				role = v.value_symbol(v.symbol_intern("source")),
				value = v.value_string(context.temp_allocator, source),
			},
		},
	)
	if outcome.kind != .Complete {
		testing.expectf(t, false, "emit_source failed for %q: %s", source, outcome.message)
		return false
	}
	result, result_ok := v.value_as_map(outcome.value)
	if !result_ok {
		testing.expectf(t, false, "emit_source did not return a map for %q", source)
		return false
	}
	ok_value := map_get(result, "ok")
	ok, _ := v.value_as_bool(ok_value)
	if !ok {
		testing.expectf(t, false, "emitter errors for %q", source)
		return false
	}
	artifact, artifact_ok := v.value_as_bytes(map_get(result, "bytes"))
	if !artifact_ok {
		testing.expectf(t, false, "emit_source returned no bytes for %q", source)
		return false
	}
	program, decode_error := vm.program_from_bytes(artifact, alloc)
	if decode_error != .None {
		testing.expectf(t, false, "assembled bytes do not decode for %q", source)
		return false
	}
	if vm.program_validate(program) != .None {
		testing.expectf(t, false, "assembled program is invalid for %q", source)
		return false
	}
	mica_state: vm.VM
	vm.vm_init(&mica_state, program, alloc)
	defer vm.vm_destroy(&mica_state)
	register_runtime_builtins(&mica_state)
	if vm.vm_run(&mica_state) != .Halted {
		testing.expectf(t, false, "mica program did not halt for %q", source)
		return false
	}
	return v.value_eq(odin_state.result, mica_state.result)
}

// The Mica emitter lowers `assert`/`retract` to name-resolving builtins
// rather than baked relation ids. Compile a write with it, run the decoded
// artifact against a real kernel transaction, and confirm the row lands.
@(test)
test_mica_emitter_relation_write :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		testing.expect(t, false, "cannot initialize test arena")
		return
	}
	defer virtual.arena_destroy(&arena)
	alloc := virtual.arena_allocator(&arena)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	// The declaration lives in the same world as the emitted program, so the
	// name-resolving builtin sees :Point through the world's context.
	declaration := "make_relation(:Point, 1)\n"
	declaration_path, declaration_ok := write_temp_source(
		t,
		"mica_emitter_write_decl.mica",
		declaration,
	)
	if !declaration_ok {
		return
	}
	defer os.remove(declaration_path)

	world, start := world_start(
		&kernel,
		[]string {
			"apps/compiler/lex.mica",
			"apps/compiler/parse.mica",
			"apps/compiler/emit.mica",
			declaration_path,
		},
		context.temp_allocator,
	)
	testing.expectf(t, start.ok, "compiler load failed: %s", start.message)
	if !start.ok {
		return
	}
	defer world_destroy(world)
	entry := world_wait(world, world.entry)
	testing.expect_value(t, entry.kind, Task_Outcome_Kind.Complete)

	outcome := world_call(
		world,
		"emit_source",
		[]k.Role_Pair {
			{
				role = v.value_symbol(v.symbol_intern("source")),
				value = v.value_string(context.temp_allocator, "assert Point(7)"),
			},
		},
	)
	testing.expectf(t, outcome.kind == .Complete, "emit_source failed: %s", outcome.message)
	if outcome.kind != .Complete {
		return
	}
	fields, fields_ok := v.value_as_map(outcome.value)
	testing.expect(t, fields_ok)
	if !fields_ok {
		return
	}
	ok, _ := v.value_as_bool(map_get(fields, "ok"))
	testing.expect(t, ok, "emitter reported an error for the write")
	if !ok {
		return
	}
	artifact, artifact_ok := v.value_as_bytes(map_get(fields, "bytes"))
	testing.expect(t, artifact_ok)
	if !artifact_ok {
		return
	}
	program, decode_error := vm.program_from_bytes(artifact, alloc)
	testing.expect_value(t, decode_error, vm.Artifact_Error.None)
	if program == nil {
		return
	}
	testing.expect_value(t, vm.program_validate(program), vm.Program_Error.None)

	// The Mica world's context must be reachable to the running program so
	// the name-resolving builtin can find :Point.
	tx := k.kernel_begin(&kernel)
	relation_source := k.Relation_Source {
		transaction        = &tx,
		use_stored_derived = true,
	}
	state: vm.VM
	vm.vm_init(&state, program, alloc)
	defer vm.vm_destroy(&state)
	register_runtime_builtins(&state)
	state.user = &world.env
	vm.vm_set_workspace(&state, &relation_source, &tx)
	run_status := vm.vm_run(&state)
	if run_status != .Halted {
		error_message := "?"
		if error_value, is_error := v.value_as_error(state.error); is_error {
			error_message = error_value.message
		}
		testing.expectf(t, false, "mica write program failed: %s", error_message)
		return
	}

	committed, commit_err := k.transaction_commit(&tx)
	testing.expect_value(t, commit_err, k.Kernel_Error.None)
	k.snapshot_release(committed)
	k.transaction_destroy(&tx)

	expect_relation_rows(t, &kernel, "Point", 1)
}

@(test)
test_mica_emitter_relation_query :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		testing.expect(t, false, "cannot initialize test arena")
		return
	}
	defer virtual.arena_destroy(&arena)
	alloc := virtual.arena_allocator(&arena)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	declaration := `make_relation(:Point, 2)
assert Point(1, 10)
assert Point(2, 20)
`
	declaration_path, declaration_ok := write_temp_source(
		t,
		"mica_emitter_query_decl.mica",
		declaration,
	)
	if !declaration_ok {
		return
	}
	defer os.remove(declaration_path)

	world, start := world_start(
		&kernel,
		[]string {
			"apps/compiler/lex.mica",
			"apps/compiler/parse.mica",
			"apps/compiler/emit.mica",
			declaration_path,
		},
		context.temp_allocator,
	)
	testing.expectf(t, start.ok, "compiler load failed: %s", start.message)
	if !start.ok {
		return
	}
	defer world_destroy(world)
	entry := world_wait(world, world.entry)
	testing.expect_value(t, entry.kind, Task_Outcome_Kind.Complete)

	outcome := world_call(
		world,
		"emit_source",
		[]k.Role_Pair {
			{
				role = v.value_symbol(v.symbol_intern("source")),
				value = v.value_string(context.temp_allocator, "Point(?x, ?y)"),
			},
		},
	)
	testing.expectf(t, outcome.kind == .Complete, "emit_source failed: %s", outcome.message)
	if outcome.kind != .Complete {
		return
	}
	fields, fields_ok := v.value_as_map(outcome.value)
	testing.expect(t, fields_ok)
	if !fields_ok {
		return
	}
	ok, _ := v.value_as_bool(map_get(fields, "ok"))
	testing.expect(t, ok, "emitter reported an error for the query")
	if !ok {
		return
	}
	artifact, artifact_ok := v.value_as_bytes(map_get(fields, "bytes"))
	testing.expect(t, artifact_ok)
	if !artifact_ok {
		return
	}
	program, decode_error := vm.program_from_bytes(artifact, alloc)
	testing.expect_value(t, decode_error, vm.Artifact_Error.None)
	if program == nil {
		return
	}
	testing.expect_value(t, vm.program_validate(program), vm.Program_Error.None)

	tx := k.kernel_begin(&kernel)
	relation_source := k.Relation_Source {
		transaction        = &tx,
		use_stored_derived = true,
	}
	state: vm.VM
	vm.vm_init(&state, program, alloc)
	defer vm.vm_destroy(&state)
	register_runtime_builtins(&state)
	state.user = &world.env
	vm.vm_set_workspace(&state, &relation_source, &tx)
	if vm.vm_run(&state) != .Halted {
		testing.expect(t, false, "mica query program did not halt")
		return
	}
	k.transaction_destroy(&tx)

	relation, relation_ok := v.value_as_relation(state.result)
	testing.expect(t, relation_ok)
	if !relation_ok {
		return
	}
	testing.expectf(t, len(relation.rows) == 2, "expected two rows, got %d", len(relation.rows))
}

// The strongest self-hosting check before the full bootstrap: the Mica
// emitter must accept the language the compiler is written in. Each compiler
// source compiles to a program that decodes and validates.
// The Mica emitter must reject what the Odin compiler rejects: assigning to a
// const binding is a compile error, and a program that silently allowed it
// would diverge from the Odin compiler's diagnostics.
@(test)
test_mica_emitter_rejects_const_assignment :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := world_start(
		&kernel,
		[]string{"apps/compiler/lex.mica", "apps/compiler/parse.mica", "apps/compiler/emit.mica"},
		context.temp_allocator,
	)
	testing.expectf(t, start.ok, "compiler load failed: %s", start.message)
	if !start.ok {
		return
	}
	defer world_destroy(world)
	entry := world_wait(world, world.entry)
	testing.expect_value(t, entry.kind, Task_Outcome_Kind.Complete)

	sources := []string {
		// const reassignment must be rejected.
		"verb go()\n const x = 10\n x = 20\n return x\nend",
		// A mutable binding must still be accepted.
		"verb go()\n let x = 10\n x = 20\n return x\nend",
	}
	expect_ok := []bool{false, true}
	for source, index in sources {
		outcome := world_call(
			world,
			"emit_source",
			[]k.Role_Pair {
				{
					role = v.value_symbol(v.symbol_intern("source")),
					value = v.value_string(context.temp_allocator, source),
				},
			},
		)
		if outcome.kind != .Complete {
			testing.expectf(t, false, "emit_source aborted for %q", source)
			continue
		}
		fields, fields_ok := v.value_as_map(outcome.value)
		if !fields_ok {
			testing.expectf(t, false, "emit_source did not return a map for %q", source)
			continue
		}
		ok, _ := v.value_as_bool(map_get(fields, "ok"))
		testing.expectf(
			t,
			ok == expect_ok[index],
			"%q: emitter ok=%v, expected %v",
			source,
			ok,
			expect_ok[index],
		)
	}
}

@(test)
test_mica_emitter_compiles_compiler :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		testing.expect(t, false, "cannot initialize test arena")
		return
	}
	defer virtual.arena_destroy(&arena)
	alloc := virtual.arena_allocator(&arena)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	world, start := world_start(
		&kernel,
		[]string{"apps/compiler/lex.mica", "apps/compiler/parse.mica", "apps/compiler/emit.mica"},
		context.temp_allocator,
	)
	testing.expectf(t, start.ok, "compiler load failed: %s", start.message)
	if !start.ok {
		return
	}
	defer world_destroy(world)
	entry := world_wait(world, world.entry)
	testing.expect_value(t, entry.kind, Task_Outcome_Kind.Complete)

	sources := []string {
		"apps/compiler/lex.mica",
		"apps/compiler/parse.mica",
		"apps/compiler/emit.mica",
	}
	for path in sources {
		source, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
		if read_err != nil {
			testing.expectf(t, false, "cannot read %s", path)
			continue
		}
		outcome := world_call(
			world,
			"emit_source",
			[]k.Role_Pair {
				{
					role = v.value_symbol(v.symbol_intern("source")),
					value = v.value_string(context.temp_allocator, string(source)),
				},
			},
		)
		if outcome.kind != .Complete {
			testing.expectf(t, false, "%s: emit_source failed: %s", path, outcome.message)
			continue
		}
		fields, fields_ok := v.value_as_map(outcome.value)
		if !fields_ok {
			testing.expectf(t, false, "%s: emit_source did not return a map", path)
			continue
		}
		ok, _ := v.value_as_bool(map_get(fields, "ok"))
		if !ok {
			message := "?"
			if list, list_ok := v.value_as_list(map_get(fields, "errors"));
			   list_ok && len(list) > 0 {
				if s, s_ok := v.value_as_string(list[0]); s_ok {
					message = s
				}
			}
			testing.expectf(t, false, "%s: emitter errors: %s", path, message)
			continue
		}
		artifact, artifact_ok := v.value_as_bytes(map_get(fields, "bytes"))
		if !artifact_ok {
			testing.expectf(t, false, "%s: emitted no bytes", path)
			continue
		}
		program, decode_error := vm.program_from_bytes(artifact, alloc)
		if decode_error != .None {
			testing.expectf(t, false, "%s: decode %v", path, decode_error)
			continue
		}
		testing.expectf(
			t,
			vm.program_validate(program) == vm.Program_Error.None,
			"%s: invalid program",
			path,
		)
	}
}

// Application execution conformance: the Mica emitter must produce a program
// that behaves like the Odin-compiled one for role-dispatched app verbs.
// `approve` is the important case: it calls a rule predicate with all-bound
// arguments, which the emitter must route to a relation scan rather than a
// builtin call. The app-conformance tool covers more cases.
@(test)
test_mica_emitter_app_conformance :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		testing.expect(t, false, "cannot initialize test arena")
		return
	}
	defer virtual.arena_destroy(&arena)
	alloc := virtual.arena_allocator(&arena)

	cases := [?]struct {
		name:  string,
		paths: []string,
		call:  string,
	} {
		{
			name = "equipment-service",
			paths = []string{"apps/examples/equipment-service.mica"},
			call = "record_calibration",
		},
		{
			name = "approval-workflow",
			paths = []string{"apps/examples/approval-workflow.mica"},
			call = "approve",
		},
		{
			// Exercises match, structural literals, verb overloading with
			// parameter restrictions, runtime identity resolution, and dynamic
			// invoke in one scenario suite.
			name  = "mud scenarios",
			paths = []string {
				"apps/shared/string.mica",
				"apps/shared/events.mica",
				"apps/mud/core.mica",
				"apps/mud/command-parser.mica",
				"apps/mud/event-substitutions.mica",
				"apps/mud/tests/event-scenarios.mica",
			},
			call  = "test/command_parser_records_structured_utility_events",
		},
	}

	for entry in cases {
		roles_array := app_conformance_roles(entry.paths[0], entry.call)
		roles := roles_array[:]
		baseline, baseline_ok := app_conformance_run(t, entry.paths, nil, entry.call, roles, alloc)
		artifact, artifact_ok := app_conformance_emit(t, entry.paths, alloc)
		if !artifact_ok {
			testing.expectf(t, false, "%s: Mica emitter failed", entry.name)
			continue
		}
		emitted, emitted_ok := app_conformance_run(
			t,
			entry.paths,
			artifact,
			entry.call,
			roles,
			alloc,
		)
		if !baseline_ok || !emitted_ok {
			testing.expectf(t, false, "%s: a program did not run", entry.name)
			continue
		}
		testing.expectf(
			t,
			v.value_eq(baseline, emitted),
			"%s: results differ (odin %s, mica %s)",
			entry.name,
			v.value_to_string(baseline, context.temp_allocator),
			v.value_to_string(emitted, context.temp_allocator),
		)
	}
}

// The role arguments a specific app verb needs, using identities the app
// declares. Kept minimal: enough to drive a role-dispatched verb.
@(private)
app_conformance_roles :: proc(path, call: string) -> [3]k.Role_Pair {
	if strings.has_suffix(path, "approval-workflow.mica") {
		return {
			{app_role("actor"), app_identity("sam")},
			{app_role("request"), app_identity("office_supplies_request")},
			{app_role("note"), app_identity("office_supplies_request")},
		}
	}
	return {
		{app_role("actor"), app_identity("technician")},
		{app_role("instrument"), app_identity("sensor_17")},
		{},
	}
}

@(private)
app_role :: proc(name: string) -> v.Value {
	return v.value_symbol(v.symbol_intern(name))
}

// A placeholder that app_conformance_run replaces with the identity the world
// declares under this name.
@(private)
app_identity :: proc(name: string) -> v.Value {
	return v.value_symbol(v.symbol_intern(name))
}

// Emits the concatenated `paths` with the Mica emitter, returning the
// artifact. Concatenation matches how the app-conformance tool compiles a
// multi-file app: one program from all its sources.
@(private)
app_conformance_emit :: proc(
	t: ^testing.T,
	paths: []string,
	alloc: mem.Allocator,
) -> (
	[]u8,
	bool,
) {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := world_start(
		&kernel,
		[]string{"apps/compiler/lex.mica", "apps/compiler/parse.mica", "apps/compiler/emit.mica"},
		context.temp_allocator,
	)
	if !start.ok {
		return nil, false
	}
	defer world_destroy(world)
	started := world_wait(world, world.entry)
	if started.kind != .Complete {
		return nil, false
	}
	builder: strings.Builder
	strings.builder_init(&builder, context.temp_allocator)
	defer strings.builder_destroy(&builder)
	for path in paths {
		source, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
		if read_err != nil {
			return nil, false
		}
		strings.write_string(&builder, "\n")
		strings.write_string(&builder, string(source))
	}
	outcome := world_call(
		world,
		"emit_source",
		[]k.Role_Pair {
			{
				role = v.value_symbol(v.symbol_intern("source")),
				value = v.value_string(context.temp_allocator, strings.to_string(builder)),
			},
		},
	)
	if outcome.kind != .Complete {
		return nil, false
	}
	fields, fields_ok := v.value_as_map(outcome.value)
	if !fields_ok {
		return nil, false
	}
	ok, _ := v.value_as_bool(map_get(fields, "ok"))
	if !ok {
		return nil, false
	}
	artifact, artifact_ok := v.value_as_bytes(map_get(fields, "bytes"))
	if !artifact_ok {
		return nil, false
	}
	owned := make([]u8, len(artifact), alloc)
	copy(owned, artifact)
	return owned, true
}

// Loads `paths`, optionally swaps in `artifact`, calls `call` with `roles`, and
// returns the result.
@(private)
app_conformance_run :: proc(
	t: ^testing.T,
	paths: []string,
	artifact: []u8,
	call: string,
	roles: []k.Role_Pair,
	alloc: mem.Allocator,
) -> (
	v.Value,
	bool,
) {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := world_start(&kernel, paths, context.temp_allocator, HARNESS_CONFIG)
	if !start.ok {
		return v.Value(0), false
	}
	defer world_destroy(world)
	started := world_wait(world, world.entry)
	if started.kind != .Complete {
		return v.Value(0), false
	}
	if artifact != nil {
		program, decode_error := vm.program_from_bytes(artifact, alloc)
		if decode_error != .None {
			return v.Value(0), false
		}
		if vm.program_validate(program) != .None {
			return v.Value(0), false
		}
		vm.program_destroy(world.program, world.allocator)
		world.program = program
	}
	// Resolve identity-named role values against the loaded world.
	resolved := make([]k.Role_Pair, len(roles), context.temp_allocator)
	for role, index in roles {
		resolved[index] = role
		if symbol, is_symbol := v.value_as_symbol(role.value); is_symbol {
			if name_text, has_name := v.symbol_name(symbol); has_name {
				if identity, found := world.ctx.identities[name_text]; found {
					resolved[index] = k.Role_Pair {
						role  = role.role,
						value = identity,
					}
				}
			}
		}
	}
	outcome := world_call(world, call, resolved)
	if outcome.kind != .Complete {
		if error_value, is_error := v.value_as_error(outcome.value); is_error {
			return v.value_error_code(error_value.code), true
		}
		return v.Value(0), false
	}
	return outcome.value, true
}

// Execution conformance: a Mica-emitted program must agree with the
// Odin-compiled one. This covers a representative subset (queries,
// comprehension/for patterns, concurrency with commit and mailboxes); the
// full 19-file run lives in tools/conformance.
@(test)
test_mica_emitter_execution_conformance :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		testing.expect(t, false, "cannot initialize test arena")
		return
	}
	defer virtual.arena_destroy(&arena)
	alloc := virtual.arena_allocator(&arena)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	world, start := world_start(
		&kernel,
		[]string{"apps/compiler/lex.mica", "apps/compiler/parse.mica", "apps/compiler/emit.mica"},
		context.temp_allocator,
	)
	testing.expectf(t, start.ok, "compiler load failed: %s", start.message)
	if !start.ok {
		return
	}
	defer world_destroy(world)
	entry := world_wait(world, world.entry)
	testing.expect_value(t, entry.kind, Task_Outcome_Kind.Complete)

	files := []string {
		"benchmarks/mica/relation_join_scan.mica",
		"benchmarks/mica/language_for_pattern.mica",
		"benchmarks/mica/relation_commit.mica",
	}
	for path in files {
		source, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
		if read_err != nil {
			testing.expectf(t, false, "cannot read %s", path)
			continue
		}
		outcome := world_call(
			world,
			"emit_source",
			[]k.Role_Pair {
				{
					role = v.value_symbol(v.symbol_intern("source")),
					value = v.value_string(context.temp_allocator, string(source)),
				},
			},
		)
		if outcome.kind != .Complete {
			testing.expectf(t, false, "%s: emit_source failed: %s", path, outcome.message)
			continue
		}
		fields, fields_ok := v.value_as_map(outcome.value)
		if !fields_ok {
			testing.expectf(t, false, "%s: emit_source did not return a map", path)
			continue
		}
		ok, _ := v.value_as_bool(map_get(fields, "ok"))
		if !ok {
			testing.expectf(t, false, "%s: emitter errors", path)
			continue
		}
		artifact, artifact_ok := v.value_as_bytes(map_get(fields, "bytes"))
		if !artifact_ok {
			testing.expectf(t, false, "%s: emitted no bytes", path)
			continue
		}

		baseline, baseline_ok := conformance_run(t, path, nil, alloc)
		emitted, emitted_ok := conformance_run(t, path, artifact, alloc)
		if !baseline_ok || !emitted_ok {
			testing.expectf(t, false, "%s: could not run both programs", path)
			continue
		}
		testing.expectf(
			t,
			v.value_eq(baseline, emitted),
			"%s: results differ (odin %v, mica %v)",
			path,
			baseline,
			emitted,
		)
	}
}

// A world configured with the harness limits must fail a non-terminating
// program promptly instead of hanging. This is the regression guard for #92:
// a mis-emitted loop previously spun forever, blocking the whole runtime
// suite with no failure location. Both shapes are covered: a pure compute
// loop (bounded by the instruction budget) and a commit-heavy loop (bounded
// by the wall-clock deadline, since its kernel cost makes the budget trip too
// slowly to matter).
@(test)
test_harness_limits_bound_runaway_programs :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	compute_loop := `verb bench()
  let i = 0
  while i < 1000
    i = i - 1
  end
  return i
end
`
	commit_loop := `make_relation(:Point, 2)
verb bench()
  let i = 0
  while i < 1000
    assert Point(i, i * 2)
    i = i - 1
  end
  return i
end
`
	for source, index in ([]string{compute_loop, commit_loop}) {
		path, path_ok := write_temp_source(
			t,
			fmt.aprintf("mica_harness_limit_%d.mica", index, allocator = context.temp_allocator),
			source,
		)
		if !path_ok {
			return
		}
		defer os.remove(path)

		kernel: k.Kernel
		k.kernel_init(&kernel)
		defer k.kernel_destroy(&kernel)

		// A short limit keeps the test fast; the harness passes
		// HARNESS_TIME_LIMIT, and only the value differs here.
		limit := 500 * time.Millisecond
		started := time.tick_now()
		world, start := world_start(
			&kernel,
			[]string{path},
			context.temp_allocator,
			World_Config{instruction_budget = HARNESS_INSTRUCTION_BUDGET, time_limit = limit},
		)
		testing.expectf(t, start.ok, "world start failed: %s", start.message)
		if !start.ok {
			return
		}
		entry := world_wait(world, world.entry)
		testing.expect_value(t, entry.kind, Task_Outcome_Kind.Complete)
		bench := world_call(world, "bench", nil)
		world_destroy(world)

		testing.expectf(
			t,
			bench.kind == .Aborted,
			"runaway program %d should abort, got %v",
			index,
			bench.kind,
		)
		elapsed := time.tick_since(started)
		testing.expectf(
			t,
			elapsed < limit + 5 * time.Second,
			"runaway program %d took %v, expected the limits to bound it",
			index,
			elapsed,
		)
	}
}

// Loads `path` in a fresh kernel, runs setup then bench, and returns the bench
// result. A non-nil `artifact` replaces the world's program, so the calls run
// the Mica-emitted program instead of the Odin-compiled one.
@(private)
conformance_run :: proc(
	t: ^testing.T,
	path: string,
	artifact: []u8,
	alloc: mem.Allocator,
) -> (
	v.Value,
	bool,
) {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	// Budget the file under test so a mis-emitted loop fails here instead of
	// hanging the suite. The compiler world in the caller is left unlimited.
	world, start := world_start(&kernel, []string{path}, context.temp_allocator, HARNESS_CONFIG)
	if !start.ok {
		return v.Value(0), false
	}
	defer world_destroy(world)
	entry := world_wait(world, world.entry)
	if entry.kind != .Complete {
		return v.Value(0), false
	}
	if artifact != nil {
		program, decode_error := vm.program_from_bytes(artifact, alloc)
		if decode_error != .None {
			return v.Value(0), false
		}
		if vm.program_validate(program) != .None {
			return v.Value(0), false
		}
		vm.program_destroy(world.program, world.allocator)
		world.program = program
	}
	if setup := world_call(world, "setup", nil); setup.kind != .Complete {
		if setup.message != "no applicable method" {
			testing.expectf(t, false, "%s: setup: %s", path, setup.message)
			return v.Value(0), false
		}
	}
	bench := world_call(world, "bench", nil)
	if bench.kind != .Complete {
		testing.expectf(t, false, "%s: bench: %s", path, bench.message)
		return v.Value(0), false
	}
	return bench.value, true
}

// The bootstrap: the Mica-emitted compiler must compile a target whose
// program behaves like the Odin-compiled compiler's program. This is compile
// plus execute, not just decode: the emitted compiler is installed as the
// world's program and used to emit a second program, which then runs.
@(test)
test_mica_emitted_compiler_bootstraps :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		testing.expect(t, false, "cannot initialize test arena")
		return
	}
	defer virtual.arena_destroy(&arena)
	alloc := virtual.arena_allocator(&arena)

	target := `make_relation(:Point, 1)
verb bench()
  assert Point(3)
  assert Point(7)
  let total = 0
  for row in Point(?x)
    total = total + row[:x]
  end
  let doubled = [n * 2 for n in [1, 2, 3] if n != 2]
  total + len(doubled)
end
`
	// Stage 1: the Odin-compiled compiler emits the target.
	odin_artifact, odin_ok := compiler_emit(t, target, nil, alloc)
	testing.expectf(t, odin_ok, "odin-compiled compiler could not emit the target")
	if !odin_ok {
		return
	}
	// Emit the compiler itself with the Mica emitter.
	compiler_source, read_ok := read_compiler_sources(
		t,
		[]string{"apps/compiler/lex.mica", "apps/compiler/parse.mica", "apps/compiler/emit.mica"},
		alloc,
	)
	if !read_ok {
		return
	}
	compiler_artifact, compiler_ok := compiler_emit(t, compiler_source, nil, alloc)
	testing.expectf(t, compiler_ok, "Mica emitter could not emit the compiler")
	if !compiler_ok {
		return
	}
	// Stage 2: the Mica-emitted compiler emits the same target.
	self_artifact, self_ok := compiler_emit(t, target, compiler_artifact, alloc)
	testing.expectf(t, self_ok, "Mica-emitted compiler could not emit the target")
	if !self_ok {
		return
	}
	// Both artifacts must run to the same result.
	odin_result, odin_ran := run_target(t, target, odin_artifact, alloc)
	self_result, self_ran := run_target(t, target, self_artifact, alloc)
	testing.expect(t, odin_ran && self_ran, "a bootstrap artifact did not run")
	if !odin_ran || !self_ran {
		return
	}
	testing.expectf(
		t,
		v.value_eq(odin_result, self_result),
		"bootstrap results differ (odin %s, mica %s)",
		v.value_to_string(odin_result, context.temp_allocator),
		v.value_to_string(self_result, context.temp_allocator),
	)
}

@(private)
read_compiler_sources :: proc(
	t: ^testing.T,
	paths: []string,
	alloc: mem.Allocator,
) -> (
	string,
	bool,
) {
	builder: strings.Builder
	strings.builder_init(&builder, alloc)
	defer strings.builder_destroy(&builder)
	for path in paths {
		data, read_err := os.read_entire_file_from_path(path, alloc)
		if read_err != nil {
			testing.expectf(t, false, "cannot read %s", path)
			return "", false
		}
		strings.write_string(&builder, "\n")
		strings.write_string(&builder, string(data))
	}
	return strings.to_string(builder), true
}

// Loads the compiler into a world and emits `source`. A non-nil `replace`
// swaps the world's program first, so the call runs the Mica-emitted compiler.
@(private)
compiler_emit :: proc(
	t: ^testing.T,
	source: string,
	replace: []u8,
	alloc: mem.Allocator,
) -> (
	[]u8,
	bool,
) {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := world_start(
		&kernel,
		[]string{"apps/compiler/lex.mica", "apps/compiler/parse.mica", "apps/compiler/emit.mica"},
		context.temp_allocator,
	)
	if !start.ok {
		testing.expectf(t, false, "compiler load failed: %s", start.message)
		return nil, false
	}
	defer world_destroy(world)
	entry := world_wait(world, world.entry)
	if entry.kind != .Complete {
		return nil, false
	}
	if replace != nil {
		program, decode_error := vm.program_from_bytes(replace, alloc)
		if decode_error != .None {
			return nil, false
		}
		if vm.program_validate(program) != .None {
			return nil, false
		}
		vm.program_destroy(world.program, world.allocator)
		world.program = program
	}
	outcome := world_call(
		world,
		"emit_source",
		[]k.Role_Pair {
			{
				role = v.value_symbol(v.symbol_intern("source")),
				value = v.value_string(context.temp_allocator, source),
			},
		},
	)
	if outcome.kind != .Complete {
		return nil, false
	}
	fields, fields_ok := v.value_as_map(outcome.value)
	if !fields_ok {
		return nil, false
	}
	ok, _ := v.value_as_bool(map_get(fields, "ok"))
	if !ok {
		return nil, false
	}
	artifact, artifact_ok := v.value_as_bytes(map_get(fields, "bytes"))
	if !artifact_ok {
		return nil, false
	}
	owned := make([]u8, len(artifact), alloc)
	copy(owned, artifact)
	return owned, true
}

// Loads `target` (for its relations and methods), swaps in `artifact`, and
// runs bench.
@(private)
run_target :: proc(
	t: ^testing.T,
	target: string,
	artifact: []u8,
	alloc: mem.Allocator,
) -> (
	v.Value,
	bool,
) {
	path, path_ok := write_temp_source(t, "mica_bootstrap_target.mica", target)
	if !path_ok {
		return v.Value(0), false
	}
	defer os.remove(path)
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := world_start(&kernel, []string{path}, context.temp_allocator, HARNESS_CONFIG)
	if !start.ok {
		testing.expectf(t, false, "target load failed: %s", start.message)
		return v.Value(0), false
	}
	defer world_destroy(world)
	entry := world_wait(world, world.entry)
	if entry.kind != .Complete {
		return v.Value(0), false
	}
	program, decode_error := vm.program_from_bytes(artifact, alloc)
	if decode_error != .None {
		return v.Value(0), false
	}
	if vm.program_validate(program) != .None {
		return v.Value(0), false
	}
	vm.program_destroy(world.program, world.allocator)
	world.program = program
	bench := world_call(world, "bench", nil)
	if bench.kind != .Complete {
		testing.expectf(t, false, "target bench: %s", bench.message)
		return v.Value(0), false
	}
	return bench.value, true
}

@(test)
test_run_shutdown_checkpoint :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Kept, 1)
assert Kept(1)
`
	path, path_ok := write_temp_source(t, "mica_shutdown_checkpoint_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	directory, directory_error := os.temp_dir(context.temp_allocator)
	if directory_error != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	store_path, join_error := filepath.join(
		[]string{directory, "mica_shutdown_checkpoint"},
		context.temp_allocator,
	)
	if join_error != nil {
		return
	}
	os.remove_all(store_path)
	defer os.remove_all(store_path)

	// The first world checkpoints only at clean shutdown.
	{
		kernel: k.Kernel
		k.kernel_init(&kernel)
		world, start := world_start(
			&kernel,
			[]string{path},
			context.temp_allocator,
			World_Config{store_path = store_path},
		)
		testing.expectf(t, start.ok, "load failed: %s", start.message)
		if start.ok {
			entry := world_wait(world, world.entry)
			testing.expect_value(t, entry.kind, Task_Outcome_Kind.Complete)
			world_destroy(world)
		}
		k.kernel_destroy(&kernel)
	}

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := world_start(
		&kernel,
		nil,
		context.temp_allocator,
		World_Config{store_path = store_path},
	)
	testing.expectf(t, start.ok, "boot failed: %s", start.message)
	if !start.ok {
		return
	}
	defer world_destroy(world)
	testing.expect_value(t, world.entry, Task_ID(0))
	expect_relation_rows(t, &kernel, "Kept", 1)
}

@(test)
test_run_guard_and_projection :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:seven)
make_relation(:Flag, 1)
make_relation(:Pair, 2)
make_relation(:Out, 2)

assert Flag(1)
assert Pair(7, #seven)

verb guarded()
  Flag(1) || return :missed
  return :guarded
end

verb projected()
  let exactly {value} = Pair(7, ?value)
  return value
end

assert Out(guarded(), projected())
`
	path, path_ok := write_temp_source(t, "mica_guard_projection_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Out", 1)
}

@(test)
test_run_relation_literals :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `require len([:a] {[1], [2]}) == 2
require to_literal([:person, :team] {[:alice, :operations]}) == "[:person, :team] {[:alice, :operations]}"

require project([:person, :team] {
  [:alice, :operations],
  [:bob, :operations],
  [:chandra, :research]
}, :team) == [:team] {[:operations], [:research]}

require natural_join(
  [:person, :team] {[:alice, :operations], [:bob, :research]},
  [:team, :room] {[:operations, :north], [:research, :south]}
) == [:person, :team, :room] {
  [:alice, :operations, :north],
  [:bob, :research, :south]
}

require project([:person, :team] {}) == [] {}
`
	path, path_ok := write_temp_source(t, "mica_relation_literals_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
}

@(test)
test_run_late_bound_verb_call :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Loaded, 1)

verb probe()
  return missing_verb(1, 2)
end

assert Loaded(1)
`
	path, path_ok := write_temp_source(t, "mica_late_bound_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	world, start := world_start(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, start.ok, "load failed: %s", start.message)
	if !start.ok {
		return
	}
	defer world_destroy(world)
	entry := world_wait(world, world.entry)
	testing.expect_value(t, entry.kind, Task_Outcome_Kind.Complete)

	// The call resolves at runtime and reports no applicable method.
	outcome := world_call(world, "probe", nil)
	testing.expect_value(t, outcome.kind, Task_Outcome_Kind.Aborted)
}

@(test)
test_run_eval_submit_suspend_resume :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `verb probe()
  return read(:line)
end
`
	path, path_ok := write_temp_source(t, "mica_eval_submit_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	world, start := world_start(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, start.ok, "world start failed: %s", start.message)
	if !start.ok {
		return
	}
	defer world_destroy(world)
	entry := world_wait(world, world.entry)
	testing.expect_value(t, entry.kind, Task_Outcome_Kind.Complete)

	id, failure, submitted := world_eval_submit(world, "return read(:line)")
	testing.expectf(t, submitted, "eval failed: %s", failure.message)
	if !submitted {
		return
	}

	parked := false
	deadline := time.tick_now()
	for time.tick_since(deadline) < 2 * time.Second {
		if _, has_request := world_task_request(world, id); has_request {
			parked = true
			break
		}
		time.sleep(1 * time.Millisecond)
	}
	testing.expect(t, parked)

	suspended, observed := world_task_outcome(world, id)
	testing.expect(t, observed)
	testing.expect_value(t, suspended.kind, Task_Outcome_Kind.Pending)
	testing.expect_value(t, suspended.suspend, Task_Suspend.Host_Request)

	testing.expect(t, world_resume(world, id, v.value_string(context.temp_allocator, "look")))

	finished := Task_Outcome{}
	deadline = time.tick_now()
	for time.tick_since(deadline) < 2 * time.Second {
		outcome, has_outcome := world_task_outcome(world, id)
		if has_outcome && outcome.kind != .Pending {
			finished = outcome
			break
		}
		time.sleep(1 * time.Millisecond)
	}
	testing.expect_value(t, finished.kind, Task_Outcome_Kind.Complete)
	text, is_text := v.value_as_string(finished.value)
	testing.expect(t, is_text)
	testing.expect_value(t, text, "look")
	world_release(world, id)
}

// Decoding a JSON string allocates a copy; the decode must not also leak the
// temporary builder buffer used to unescape it.
@(test)
test_json_decode_string_no_leak :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)

	value, message, ok := json_decode_text(alloc, `{"greeting":"hello \"world\""}`)
	testing.expectf(t, ok, "decode failed: %s", message)
	if ok {
		v.value_deep_free(alloc, value)
	}
	testing.expectf(
		t,
		len(track.allocation_map) == 0,
		"json_decode_text leaked %d allocation(s)",
		len(track.allocation_map),
	)
}

// A read-only boot must not append to the WAL. Rule reconstruction is derived
// from persisted facts, so the shutdown checkpoint is skipped and the store
// does not grow.
@(test)
test_read_only_store_boot_has_no_pending_writes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := ""
	for candidate in ([]string{"apps/examples/equipment-service.mica", "../apps/examples/equipment-service.mica", "../../apps/examples/equipment-service.mica"}) {
		if os.is_file(candidate) {
			path = candidate
			break
		}
	}
	if path == "" {
		testing.expect(t, false, "equipment example not found")
		return
	}

	directory, directory_error := os.temp_dir(context.temp_allocator)
	if directory_error != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	store_path, join_error := filepath.join(
		[]string{directory, "mica_read_only_boot"},
		context.temp_allocator,
	)
	if join_error != nil {
		testing.expect(t, false, "cannot join the store path")
		return
	}
	os.remove_all(store_path)
	defer os.remove_all(store_path)

	// First world: load a rule-bearing source and persist it.
	{
		kernel: k.Kernel
		k.kernel_init(&kernel)
		world, start := world_start(
			&kernel,
			[]string{path},
			context.temp_allocator,
			World_Config{store_path = store_path},
		)
		testing.expectf(t, start.ok, "load failed: %s", start.message)
		if start.ok {
			entry := world_wait(world, world.entry)
			testing.expect_value(t, entry.kind, Task_Outcome_Kind.Complete)
			testing.expect(t, world_checkpoint(world))
			world_destroy(world)
		}
		k.kernel_destroy(&kernel)
	}

	// Second world: read-only boot, no user work.
	{
		kernel: k.Kernel
		k.kernel_init(&kernel)
		world, start := world_start(
			&kernel,
			nil,
			context.temp_allocator,
			World_Config{store_path = store_path},
		)
		testing.expectf(t, start.ok, "boot failed: %s", start.message)
		if start.ok {
			testing.expectf(
				t,
				!s.store_has_pending_writes(world.store),
				"read-only boot appended to the WAL",
			)
			// Rule reconstruction advanced the version without writing the
			// log; a checkpoint must still complete rather than wait forever.
			testing.expectf(t, world_checkpoint(world), "checkpoint after boot failed")
			world_destroy(world)
		}
		k.kernel_destroy(&kernel)
	}
}

// Returning from inside a protected region must retire that frame's handlers,
// so a later raise at the same depth does not unwind into the completed frame.
@(test)
test_return_inside_try_retires_handlers :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	ctx := c.Compile_Context {
		builtins   = make(map[string]bool),
		relations  = make(map[string]u32),
		identities = make(map[string]v.Value),
	}
	defer delete(ctx.builtins)
	defer delete(ctx.relations)
	defer delete(ctx.identities)
	install_builtin_names(&ctx)

	source := `let f = fn()
  try
    return 1
  catch
    return 2
  end
end
f()
let g = fn()
  raise E_X
end
return g()`
	expect_builtin_error(t, &ctx, source, "E_X")
}

// A lexically visible local function value takes precedence over a
// compiler-recognized form or builtin of the same name.
@(test)
test_local_shadows_builtin :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	ctx := c.Compile_Context {
		builtins   = make(map[string]bool),
		relations  = make(map[string]u32),
		identities = make(map[string]v.Value),
	}
	defer delete(ctx.builtins)
	defer delete(ctx.relations)
	defer delete(ctx.identities)
	install_builtin_names(&ctx)

	expect_int_builtin(t, &ctx, `let len = fn(x) => 99
return len([1, 2])`, 99)
}

// `continue` in a for loop must advance the index, not repeat the element.
@(test)
test_for_loop_continue_advances_index :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	ctx := c.Compile_Context {
		builtins   = make(map[string]bool),
		relations  = make(map[string]u32),
		identities = make(map[string]v.Value),
	}
	defer delete(ctx.builtins)
	defer delete(ctx.relations)
	defer delete(ctx.identities)
	install_builtin_names(&ctx)

	expect_int_builtin(
		t,
		&ctx,
		`let n = 0
for x in [1, 2]
  n = n + 1
  if n < 3
    continue
  end
end
return n`,
		2,
	)
}

// A wildcard retract must require write authority, like a concrete retract.
@(test)
test_run_wildcard_retract_requires_write :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:alice)
make_relation(:CanRead, 2)
make_relation(:CanWrite, 2)
make_relation(:Secret, 1)
make_relation(:Cleared, 1)
make_relation(:Denied, 1)
assert Secret(1)
assert Secret(2)
assert Secret(3)
grant #alice
  read:
    :Secret
  write:
    :Cleared
    :Denied
end
commit()
verb clear()
  try
    retract Secret(_)
    assert Cleared(1)
  catch err
    assert Denied(1)
  end
end
spawn :clear()
suspend()
`
	path, path_ok := write_temp_source(t, "mica_wildcard_retract_authority.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(
		&kernel,
		[]string{path},
		context.temp_allocator,
		Run_Options{actor = "alice"},
	)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Denied", 1)
	expect_relation_rows(t, &kernel, "Cleared", 0)
	expect_relation_rows(t, &kernel, "Secret", 3)
}

// A per-call actor override must be checked with that actor's authority, not
// the world default's.
@(test)
test_run_per_call_actor_authority :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:alice)
make_identity(:bob)
make_relation(:CanRead, 2)
make_relation(:CanWrite, 2)
make_relation(:SecretA, 1)
make_relation(:SecretB, 1)
make_relation(:Allowed, 1)
make_relation(:Denied, 1)
assert SecretA(1)
assert SecretB(1)
grant #alice
  read:
    :SecretA
  write:
    :Denied
end
grant #bob
  read:
    :SecretB
  write:
    :Allowed
    :Denied
end
commit()
verb peek_b()
  try
    let rows = SecretB(1)
    assert Allowed(1)
  catch err
    assert Denied(1)
  end
end
`
	path, path_ok := write_temp_source(t, "mica_per_call_actor.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := world_start(
		&kernel,
		[]string{path},
		context.temp_allocator,
		World_Config{actor = "alice"},
	)
	testing.expectf(t, start.ok, "world start failed: %s", start.message)
	if !start.ok {
		return
	}
	defer world_destroy(world)
	entry := world_wait(world, world.entry)
	testing.expect_value(t, entry.kind, Task_Outcome_Kind.Complete)

	bob, bob_found := world.ctx.identities["bob"]
	testing.expect(t, bob_found)

	result := world_submit_call_with_options(
		world,
		"peek_b",
		nil,
		nil,
		0,
		World_Call_Options{actor = bob},
	)
	testing.expect(t, result.id != 0)
	if result.id != 0 {
		outcome := world_wait(world, result.id)
		testing.expect_value(t, outcome.kind, Task_Outcome_Kind.Complete)
		world_release(world, result.id)
	}
	expect_relation_rows(t, &kernel, "Allowed", 1)
	expect_relation_rows(t, &kernel, "Denied", 0)
}

// Resuming a relation subscription from an older cursor cannot reconstruct the
// baseline at that cursor, so it must resynchronize rather than silently skip
// the changes made while disconnected.
@(test)
test_run_subscription_relation_resume_resyncs :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Base, 1)
make_relation(:Derived, 1)
make_relation(:Out, 1)
Derived(x) :- Base(x)
let [receiver, sender] = mailbox()
assert Base(1)
commit()
let sub_one = subscribe_changes(sender, :relation, some(:Derived), [none], :changes)
assert Base(2)
commit()
let ready_one = mailbox_recv([receiver])
let cursor = index_or(ready_one[0][1][0], :cursor, 0)
cancel_subscription(sub_one)
assert Base(3)
commit()
let sub_two = subscribe_changes(sender, :relation, some(:Derived), [none], :changes, some(cursor))
assert Out(1)
commit()
let ready_two = mailbox_recv([receiver], 500)
require(len(ready_two) > 0)
`
	path, path_ok := write_temp_source(t, "mica_subscription_resume_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Out", 1)
}

// A finally body must run when the guarded catch body raises, before the
// exception propagates to an outer catch.
@(test)
test_run_finally_runs_on_catch_raise :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	ctx := c.Compile_Context {
		builtins   = make(map[string]bool),
		relations  = make(map[string]u32),
		identities = make(map[string]v.Value),
	}
	defer delete(ctx.builtins)
	defer delete(ctx.relations)
	defer delete(ctx.identities)
	install_builtin_names(&ctx)

	expect_int_builtin(
		t,
		&ctx,
		`let n = 0
try
  try
    raise E_X
  catch
    raise E_Y
  finally
    n = n + 1
  end
catch
end
return n`,
		1,
	)
}

// `break` and `continue` must run the finalizers of the protected regions they
// exit.
@(test)
test_run_break_and_continue_run_finally :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	ctx := c.Compile_Context {
		builtins   = make(map[string]bool),
		relations  = make(map[string]u32),
		identities = make(map[string]v.Value),
	}
	defer delete(ctx.builtins)
	defer delete(ctx.relations)
	defer delete(ctx.identities)
	install_builtin_names(&ctx)

	expect_int_builtin(
		t,
		&ctx,
		`let n = 0
while true
  try
    break
  finally
    n = n + 1
  end
end
return n`,
		1,
	)

	expect_int_builtin(
		t,
		&ctx,
		`let n = 0
for x in [1, 2]
  try
    continue
  finally
    n = n + 1
  end
end
return n`,
		2,
	)
}

// An aborted task must not publish staged mailbox sends or subscriptions.
@(test)
test_run_aborted_task_publishes_nothing :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Note, 1)
make_relation(:Out, 1)
let [receiver, sender] = mailbox()
verb work(sender)
  mailbox_send(sender, 1)
  let sub = subscribe_changes(sender, :facts, some(:Note), [none], :changes)
  raise E_X
end
let id = spawn :work(sender: sender)
suspend()
assert Note(1)
commit()
let messages = mailbox_recv([receiver], 200)
require(len(messages) == 0)
assert Out(1)
`
	path, path_ok := write_temp_source(t, "mica_aborted_publication_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Out", 1)
}

// Differential test for the Mica lexer (#80).
//
// Lexes each corpus file with the Odin lexer and with `apps/compiler/lex.mica`
// and compares kind, text, scalar offset, line, and column token for token.
// This is the conformance gate for the port: any divergence is either a lexer
// bug or a deliberate difference that must be recorded.
@(test)
test_mica_lexer_matches_odin :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	lexer_path := corpus_relative("apps/compiler/lex.mica")
	if lexer_path == "" {
		testing.expect(t, false, "compiler lexer not found")
		return
	}

	corpus := make([dynamic]string, 0, 64, context.temp_allocator)
	// Every `.mica` file under the app and benchmark trees, so the gate covers
	// the whole source surface rather than a hand-picked sample.
	for root in ([]string{"apps", "benchmarks"}) {
		corpus_root := corpus_relative_dir(root)
		if corpus_root == "" {
			continue
		}
		walker := os.walker_create_path(corpus_root)
		for info in os.walker_walk(&walker) {
			if _, walk_err := os.walker_error(&walker); walk_err != nil {
				break
			}
			if info.type == .Regular && strings.has_suffix(info.name, ".mica") {
				append(&corpus, strings.clone(info.fullpath, context.temp_allocator))
			}
		}
		os.walker_destroy(&walker)
	}

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	world, start := world_start(&kernel, []string{lexer_path}, context.temp_allocator)
	testing.expectf(t, start.ok, "lexer load failed: %s", start.message)
	if !start.ok {
		return
	}
	defer world_destroy(world)
	_ = world_wait(world, world.entry)

	compared := 0
	for relative in corpus {
		path := relative
		if !os.is_file(path) {
			path = corpus_relative(relative)
		}
		if path == "" {
			continue
		}
		data, read_err := os.read_entire_file(path, context.temp_allocator)
		if read_err != nil {
			testing.expectf(t, false, "cannot read %s", path)
			continue
		}
		if mica_lexer_matches_odin(t, world, relative, string(data)) {
			compared += 1
		}
	}
	testing.expectf(t, compared >= 50, "only %d corpus files compared", compared)
}

// The differential gate over hand-written edge cases: malformed input, every
// line-break form, empty input, invalid UTF-8, and the token-boundary corners a
// clean corpus never exercises. Kept separate from the corpus test so a failure
// names the case.
@(test)
test_mica_lexer_matches_odin_edge_cases :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	lexer_path := corpus_relative("apps/compiler/lex.mica")
	if lexer_path == "" {
		testing.expect(t, false, "compiler lexer not found")
		return
	}

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	world, start := world_start(&kernel, []string{lexer_path}, context.temp_allocator)
	testing.expectf(t, start.ok, "lexer load failed: %s", start.message)
	if !start.ok {
		return
	}
	defer world_destroy(world)
	_ = world_wait(world, world.entry)

	cases := [?]struct {
		name: string,
		text: string,
	} {
		{"empty", ""},
		{"lf", "a\nb\n"},
		{"crlf", "a\r\nb\r\n"},
		{"lone_cr", "a\rb"},
		{"crlf_run", "a\r\n\r\nb"},
		{"mixed_breaks", "a\n\n\r\n\rb"},
		{"cr_at_eof", "a\r"},
		{"crlf_at_eof", "a\r\n"},
		{"unterminated_string", "let x = \"abc"},
		{"escaped_quote", "\"a\\\"b\"\n"},
		{"escape_at_eof", "\"abc\\"},
		{"backslash_eof", "\\"},
		{"cr_in_string", "\"a\rb\"\n"},
		{"crlf_in_string", "\"a\r\nb\"\n"},
		{"bytes_unterminated", "b\"abc"},
		{"cr_bytes", "b\"a\rb\"\n"},
		{"stray_amp", "a & b"},
		{"error_code", "E_FOO"},
		{"bare_error_prefix", "E_"},
		{"dot_vs_dotdot", "a.b .. c"},
		{"colon_dash", "a :- b"},
		{"membership", "a \xe2\x88\x88 b"},
		{"emoji", "\"\xf0\x9f\x98\x80\"\n"},
		{"invalid_utf8", "a \xff b"},
		{"nonascii_word", "caf\xc3\xa9 x"},
		{"underscore", "_ _x _1"},
		{"number_edges", "1 1.5 1..2 1e3 1e 1.2e-3"},
		{"number_letter", "12abc"},
		{"dot_number", "1.5.6"},
		{"comment_eof", "a // comment"},
		{"comment_no_nl", "// only comment"},
		{"nested_comment", "// a // b"},
		{"bang", "a != b !c"},
		{"spaces", "  \t  x\t"},
		{"hash_ident", "#foo"},
		{"at_ident", "@bar"},
		{"question", "?x"},
		{"semi", "a; b"},
	}

	for entry in cases {
		_ = mica_lexer_matches_odin(t, world, entry.name, entry.text)
	}
}

// Lexes `source` with both lexers and asserts token-for-token agreement.
// Returns true when every token matched. `label` names the case in failures.
@(private)
mica_lexer_matches_odin :: proc(
	t: ^testing.T,
	world: ^World,
	label: string,
	source: string,
) -> bool {
	odin_result := c.lex(source, context.temp_allocator)
	defer c.lex_destroy(&odin_result, context.temp_allocator)

	source_value := v.value_string(context.temp_allocator, source)
	outcome := world_call(
		world,
		"lex",
		[]k.Role_Pair{{role = v.value_symbol(v.symbol_intern("source")), value = source_value}},
	)
	if outcome.kind != .Complete {
		testing.expectf(t, false, "%s: Mica lex failed: %s", label, outcome.message)
		return false
	}
	mica_result, result_ok := v.value_as_list(outcome.value)
	if !result_ok || len(mica_result) != 2 {
		testing.expectf(t, false, "%s: Mica lex did not return [tokens, errors]", label)
		return false
	}
	mica_tokens, tokens_ok := v.value_as_list(mica_result[0])
	mica_errors, errors_ok := v.value_as_list(mica_result[1])
	if !tokens_ok || !errors_ok {
		testing.expectf(t, false, "%s: Mica lex result is not [list, list]", label)
		return false
	}
	if len(mica_tokens) != len(odin_result.tokens) {
		testing.expectf(
			t,
			false,
			"%s: token count %d (Mica) != %d (Odin)",
			label,
			len(mica_tokens),
			len(odin_result.tokens),
		)
		return false
	}
	// The diagnostics must agree too: message, line, and column, in order.
	if len(mica_errors) != len(odin_result.errors) {
		testing.expectf(
			t,
			false,
			"%s: error count %d (Mica) != %d (Odin)",
			label,
			len(mica_errors),
			len(odin_result.errors),
		)
		return false
	}
	for mica_error, index in mica_errors {
		entries, entries_ok := v.value_as_map(mica_error)
		if !entries_ok {
			testing.expectf(t, false, "%s: error %d is not a map", label, index)
			return false
		}
		message, _ := v.value_as_string(map_get(entries, "message"))
		line, _ := v.value_as_int(map_get(entries, "line"))
		column, _ := v.value_as_int(map_get(entries, "column"))
		odin_error := odin_result.errors[index]
		if message != odin_error.message ||
		   line != i64(odin_error.line) ||
		   column != i64(odin_error.column) {
			testing.expectf(
				t,
				false,
				"%s error %d: Mica (%q %d:%d) != Odin (%q %d:%d)",
				label,
				index,
				message,
				line,
				column,
				odin_error.message,
				odin_error.line,
				odin_error.column,
			)
			return false
		}
	}

	mismatched := 0
	ascii_source := true
	for byte in transmute([]u8)source {
		if byte >= 0x80 {
			ascii_source = false
			break
		}
	}
	previous_offset := i64(-1)
	for mica_token, index in mica_tokens {
		entries, entries_ok := v.value_as_map(mica_token)
		if !entries_ok {
			testing.expectf(t, false, "%s: token %d is not a map", label, index)
			return false
		}
		kind_value := map_get(entries, "kind")
		text_value := map_get(entries, "text")
		offset_value := map_get(entries, "offset")
		line_value := map_get(entries, "line")
		column_value := map_get(entries, "column")

		odin_token := odin_result.tokens[index]
		mica_kind, _ := v.value_as_symbol(kind_value)
		odin_kind_name, _ := odin_token_kind_name(odin_token.kind)
		mica_kind_name, _ := v.symbol_name(mica_kind)
		mica_text, _ := v.value_as_string(text_value)
		mica_offset, _ := v.value_as_int(offset_value)
		mica_line, _ := v.value_as_int(line_value)
		mica_column, _ := v.value_as_int(column_value)

		// The Mica offset is a scalar position; the Odin offset is a byte
		// offset. They are equal for ASCII sources and diverge by the extra
		// bytes of each multi-byte scalar otherwise, so compare the offset
		// exactly only for ASCII and validate the scalar offset through the
		// source range below.
		offset_matches := !ascii_source || mica_offset == i64(odin_token.offset)
		if mica_kind_name != odin_kind_name ||
		   mica_text != odin_token.text ||
		   !offset_matches ||
		   mica_line != i64(odin_token.line) ||
		   mica_column != i64(odin_token.column) {
			if mismatched < 5 {
				testing.expectf(
					t,
					false,
					"%s token %d: Mica (%s %q %d:%d:%d) != Odin (%s %q %d:%d:%d)",
					label,
					index,
					mica_kind_name,
					mica_text,
					mica_offset,
					mica_line,
					mica_column,
					odin_kind_name,
					odin_token.text,
					odin_token.offset,
					odin_token.line,
					odin_token.column,
				)
			}
			mismatched += 1
		}

		// Independent invariant: the token's text is exactly the source scalar
		// range at its offset, and offsets advance. This holds on non-ASCII
		// input too, where byte and scalar positions diverge.
		text_length, _ := v.string_scalar_count(text_value)
		byte_start, byte_end, range_ok := v.string_byte_range(
			source_value,
			int(mica_offset),
			int(mica_offset) + text_length,
		)
		if !range_ok || source[byte_start:byte_end] != mica_text {
			if mismatched < 5 {
				testing.expectf(
					t,
					false,
					"%s token %d: text %q at scalar offset %d is not %q",
					label,
					index,
					mica_text,
					mica_offset,
					range_ok ? source[byte_start:byte_end] : "<invalid range>",
				)
			}
			mismatched += 1
		}
		if mica_offset < previous_offset {
			if mismatched < 5 {
				testing.expectf(
					t,
					false,
					"%s token %d: scalar offset %d moved backwards",
					label,
					index,
					mica_offset,
				)
			}
			mismatched += 1
		}
		previous_offset = mica_offset
	}
	return mismatched == 0
}

@(private)
corpus_relative :: proc(relative: string) -> string {
	candidates := []string {
		relative,
		fmt.aprintf("../%s", relative, allocator = context.temp_allocator),
		fmt.aprintf("../../%s", relative, allocator = context.temp_allocator),
	}
	for candidate in candidates {
		if os.is_file(candidate) {
			return candidate
		}
	}
	return ""
}

@(private)
corpus_relative_dir :: proc(relative: string) -> string {
	candidates := []string {
		relative,
		fmt.aprintf("../%s", relative, allocator = context.temp_allocator),
		fmt.aprintf("../../%s", relative, allocator = context.temp_allocator),
	}
	for candidate in candidates {
		if os.is_dir(candidate) {
			return candidate
		}
	}
	return ""
}

@(private)
map_get :: proc(entries: []v.Map_Entry, name: string) -> v.Value {
	key := v.value_symbol(v.symbol_intern(name))
	for entry in entries {
		if entry.key == key {
			return entry.value
		}
	}
	return v.Value(0)
}

@(private)
odin_token_kind_name :: proc(kind: c.Token_Kind) -> (string, bool) {
	return fmt.aprintf("%v", kind, allocator = context.temp_allocator), true
}

// Differential test for the Mica parser (#79).
//
// Parses each corpus file with the Odin parser and with `apps/compiler/parse.mica`
// and compares a canonical S-expression rendering of the two ASTs. The Odin AST
// is rendered by `ast_sexpr`; the Mica relational AST by `relation_ast_sexpr`.
// Both renderers live in Odin, so a match means the Mica parser produced the
// same tree.
@(test)
test_mica_parser_matches_odin :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	lexer_path := corpus_relative("apps/compiler/lex.mica")
	parser_path := corpus_relative("apps/compiler/parse.mica")
	if lexer_path == "" || parser_path == "" {
		testing.expect(t, false, "compiler parser files not found")
		return
	}

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := world_start(&kernel, []string{lexer_path, parser_path}, context.temp_allocator)
	testing.expectf(t, start.ok, "parser load failed: %s", start.message)
	if !start.ok {
		return
	}
	defer world_destroy(world)
	_ = world_wait(world, world.entry)

	cases := [?]struct {
		name: string,
		text: string,
	} {
		{"empty", ""},
		{"int", "1"},
		{"add", "1 + 2"},
		{"precedence", "1 + 2 * 3"},
		{"binding", "let x = 1"},
		{"const", "const y = 2"},
		{"call", "f(1, 2)"},
		{"name", "foo/bar"},
		{"symbol", ":name"},
		{"identity", "#x"},
		{"string", "\"abc\""},
		{"list", "[1, 2, 3]"},
		{"map", "{:a -> 1}"},
		{"compare", "a < b"},
		{"index", "xs[0]"},
		{"field", "x.name"},
		{"unary", "-x"},
		{"not", "not x"},
		{"if", "if x\n  y\nend"},
		{"ifelse", "if x\n  y\nelse\n  z\nend"},
		{"while", "while x\n  y\nend"},
		{"for", "for i in xs\n  y\nend"},
		{"begin", "begin\n  x\nend"},
		{"return", "return 1"},
		{"assignment", "x = 1"},
		{"verb", "verb f(a, b)\n  return a\nend"},
		{"query", "Point(?x, ?y)"},
	}

	for entry in cases {
		mica_parser_matches_odin(t, world, entry.name, entry.text)
	}

	// The corpus gate: every .mica file under apps and benchmarks.
	corpus := make([dynamic]string, 0, 64, context.temp_allocator)
	for root in ([]string{"apps", "benchmarks"}) {
		corpus_root := corpus_relative_dir(root)
		if corpus_root == "" {
			continue
		}
		walker := os.walker_create_path(corpus_root)
		for info in os.walker_walk(&walker) {
			if _, walk_err := os.walker_error(&walker); walk_err != nil {
				break
			}
			if info.type == .Regular && strings.has_suffix(info.name, ".mica") {
				append(&corpus, strings.clone(info.fullpath, context.temp_allocator))
			}
		}
		os.walker_destroy(&walker)
	}
	compared := 0
	for path in corpus {
		data, read_err := os.read_entire_file(path, context.temp_allocator)
		if read_err != nil {
			continue
		}
		if mica_parser_matches_odin(t, world, path, string(data)) {
			compared += 1
		}
	}
	testing.expectf(t, compared >= 40, "only %d corpus files parsed identically", compared)
}

// Parses `source` with both parsers and compares the canonical renderings.
@(private)
mica_parser_matches_odin :: proc(
	t: ^testing.T,
	world: ^World,
	label: string,
	source: string,
) -> bool {
	odin_ast, odin_errors := c.parse_program(source, context.temp_allocator)
	odin_rendered := c.ast_sexpr(odin_ast, context.temp_allocator)

	outcome := world_call(
		world,
		"parse",
		[]k.Role_Pair {
			{
				role = v.value_symbol(v.symbol_intern("source")),
				value = v.value_string(context.temp_allocator, source),
			},
		},
	)
	if outcome.kind != .Complete {
		testing.expectf(t, false, "%s: Mica parse failed: %s", label, outcome.message)
		return false
	}
	result, result_ok := v.value_as_map(outcome.value)
	if !result_ok {
		testing.expectf(t, false, "%s: parse did not return a map", label)
		return false
	}
	root_value, _ := v.value_as_int(map_get(result, "root"))
	nodes := map_get(result, "nodes")
	mica_rendered := c.relation_ast_sexpr(int(root_value), nodes, context.temp_allocator)

	mica_errors, _ := v.value_as_list(map_get(result, "errors"))
	if len(mica_errors) != len(odin_errors) {
		testing.expectf(
			t,
			false,
			"%s: error count %d (Mica) != %d (Odin)",
			label,
			len(mica_errors),
			len(odin_errors),
		)
		return false
	}
	if mica_rendered != odin_rendered {
		testing.expectf(
			t,
			false,
			"%s:\n  mica: %s\n  odin: %s",
			label,
			mica_rendered,
			odin_rendered,
		)
		return false
	}
	return true
}

// Locates the in-Mica buffer scenarios from whichever directory the test runs
// in.
@(private)
buffer_scenario_path :: proc() -> string {
	candidates := []string {
		"apps/buffers/tests/buffer-scenarios.mica",
		"../apps/buffers/tests/buffer-scenarios.mica",
		"../../apps/buffers/tests/buffer-scenarios.mica",
	}
	for candidate in candidates {
		if os.is_file(candidate) {
			return candidate
		}
	}
	return ""
}

// The buffer surface is a runtime feature, so its acceptance tests are written
// in Mica and driven here. Each scenario verb runs as its own task, and
// therefore its own transaction.
@(test)
test_buffer_builtins_mica_scenarios :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := buffer_scenario_path()
	if path == "" {
		testing.expect(t, false, "buffer scenario filein not found")
		return
	}

	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		testing.expect(t, false, "cannot initialize test arena")
		return
	}
	defer virtual.arena_destroy(&arena)
	alloc := virtual.arena_allocator(&arena)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	world, start := world_start(&kernel, []string{path}, alloc)
	if !start.ok {
		testing.expectf(t, false, "buffer scenarios failed to load: %s", start.message)
		return
	}
	defer world_destroy(world)
	started := world_wait(world, world.entry)
	if started.kind != .Complete {
		testing.expectf(
			t,
			false,
			"buffer scenario load task did not complete: %s",
			started.message,
		)
		return
	}

	verbs := []string {
		"test/buffer_insert_read_and_measure",
		"test/buffer_offsets_are_view_relative",
		"test/buffer_replace_and_delete",
		"test/buffer_line_accounting",
		"test/buffer_scalars_not_bytes",
		"test/buffers_are_independent",
		"test/make_buffer_is_idempotent",
		"test/buffer_unknown_name_is_rejected",
		"test/buffer_revision_starts_at_zero_before_commit",
		"test/buffer_compaction_is_accepted",
		"test/buffer_apply_checks_revision_and_order",
		"test/buffer_conflict_policy_is_selectable",
		"test/kill_buffer_retires_the_name",
		// Order matters: the first stages with a token, the second reads it.
		"test/buffer_apply_records_completion",
		"test/buffer_apply_completion_is_readable",
		// Reversion needs committed history, so these publish three revisions
		// before reverting to the first.
		"test/buffer_revert_seed",
		"test/buffer_revert_second_version",
		"test/buffer_revert_third_version",
		"test/buffer_revert_restores_an_earlier_revision",
		"test/buffer_revert_reports_status",
		// Compaction describes committed content, so these reach a committed
		// buffer before exercising it.
		"test/buffer_compaction_seed",
		"test/buffer_compaction_refuses_a_moved_view",
		"test/buffer_compaction_seals_the_view",
		"test/buffer_find_locates_and_windows",
		"test/buffer_lines_projects_spans",
		"test/buffer_line_spans_address_lines",
		"test/buffer_positions_convert_to_lines_and_columns",
		"test/buffer_line_columns_convert_to_offsets",
		"test/buffer_viewport_is_bounded",
	}
	for verb in verbs {
		outcome := world_call(world, verb, nil)
		detail := outcome.message
		if error_value, is_error := v.value_as_error(outcome.error); is_error {
			detail = error_value.message
		}
		testing.expectf(
			t,
			outcome.kind == .Complete,
			"%s: kind=%v message=%s",
			verb,
			outcome.kind,
			detail,
		)
	}
}

// The editor core is a Mica application, so its acceptance tests are written
// in Mica and driven here. Session state is volatile but in-memory, so the
// verbs run in order against one world: later scenarios build on committed
// history from earlier ones.
@(test)
test_editor_mica_scenarios :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	relative := []string {
		"apps/shared/buffers.mica",
		"apps/editor/schema.mica",
		"apps/editor/windows.mica",
		"apps/editor/buffers.mica",
		"apps/editor/keymaps.mica",
		"apps/editor/undo.mica",
		"apps/editor/commands.mica",
		"apps/editor/session.mica",
		"apps/editor/picker.mica",
		"apps/editor/minibuffer.mica",
		"apps/editor/files.mica",
		"apps/editor/ui.mica",
		"apps/editor/defaults.mica",
		"apps/editor/tests/editor-scenarios.mica",
	}
	files := make([]string, len(relative), context.temp_allocator)
	for path, index in relative {
		files[index] = scenario_source_path(path)
		if files[index] == "" {
			testing.expectf(t, false, "editor filein not found: %s", path)
			return
		}
	}

	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		testing.expect(t, false, "cannot initialize test arena")
		return
	}
	defer virtual.arena_destroy(&arena)
	alloc := virtual.arena_allocator(&arena)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	world, start := world_start(&kernel, files, alloc)
	if !start.ok {
		testing.expectf(t, false, "editor scenarios failed to load: %s", start.message)
		return
	}
	defer world_destroy(world)
	started := world_wait(world, world.entry)
	if started.kind != .Complete {
		testing.expectf(
			t,
			false,
			"editor scenario load task did not complete: %s",
			started.message,
		)
		return
	}

	// Order matters: sessions, undo history, and buffer revisions accumulate.
	verbs := []string {
		"test/editor_session_seeds_a_frame",
		"test/editor_session_create_is_idempotent",
		"test/editor_session_rejects_a_different_actor",
		"test/editor_word_and_keymap_invariants",
		"test/editor_display_names_are_disambiguated",
		"test/editor_retirement_keeps_internal_names_distinct",
		"test/editor_typing_inserts_at_point",
		"test/editor_consecutive_returns_seed",
		"test/editor_consecutive_returns_first",
		"test/editor_consecutive_returns_second",
		"test/editor_prefix_and_undefined_keys",
		"test/editor_text_clears_a_stale_prefix",
		"test/editor_movement_keeps_a_goal_column",
		"test/editor_numeric_arguments",
		"test/editor_undo_seed",
		"test/editor_undo_types_b",
		"test/editor_undo_types_c",
		"test/editor_undo_reverts_one_group",
		"test/editor_undo_reports_nothing_left",
		"test/editor_redo_reapplies_the_group",
		"test/editor_redo_tail_undo",
		"test/editor_redo_tail_type",
		"test/editor_redo_tail_is_gone",
		"test/editor_read_only_rejects_edits",
		"test/editor_windows_seed",
		"test/editor_windows_split_and_points",
		"test/editor_windows_edit_rebases_both",
		"test/editor_window_tree_commands",
		"test/editor_marks_seed",
		"test/editor_marks_and_region",
		"test/editor_max_runs_a_registered_command",
		"test/editor_max_rejects_unknown_names",
		"test/editor_picker_navigation_and_buffer_switch",
		"test/editor_minibuffer_editing",
		"test/editor_minibuffer_survives_a_broken_prompt",
		"test/editor_staged_result_has_a_token",
		"test/editor_result_finalizes",
		"test/editor_snapshot_seed",
		"test/editor_snapshot_reports_the_viewport",
		"test/editor_json_bridge_seed",
		"test/editor_json_bridge_runs_items",
		"test/editor_json_bridge_commits_tagged_items_in_one_call",
		"test/editor_json_bridge_rejects_bad_json",
		"test/editor_pointer_items_move_point",
		"test/editor_session_cleanup_removes_state",
	}
	for verb in verbs {
		outcome := world_call(world, verb, nil)
		detail := outcome.message
		if error_value, is_error := v.value_as_error(outcome.error); is_error {
			detail = error_value.message
		}
		testing.expectf(
			t,
			outcome.kind == .Complete,
			"%s: kind=%v message=%s",
			verb,
			outcome.kind,
			detail,
		)
	}
}

// Locates a file under `apps/` from whichever directory the test runs in.
@(private)
scenario_source_path :: proc(relative: string) -> string {
	candidates := []string {
		relative,
		fmt.aprintf("../%s", relative, allocator = context.temp_allocator),
		fmt.aprintf("../../%s", relative, allocator = context.temp_allocator),
	}
	for candidate in candidates {
		if os.is_file(candidate) {
			return candidate
		}
	}
	return ""
}

// The marker and annotation layer is a library over world relations, so its
// acceptance tests load the library and drive it the way an application would.
// Each verb is its own task and therefore its own transaction; the sequence runs
// from seeding through a token-tagged apply to rebasing by the committed delta.
@(test)
test_marker_builtins_mica_scenarios :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	library := scenario_source_path("apps/shared/buffers.mica")
	scenarios := scenario_source_path("apps/buffers/tests/marker-scenarios.mica")
	if library == "" || scenarios == "" {
		testing.expect(t, false, "marker scenario sources not found")
		return
	}

	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		testing.expect(t, false, "cannot initialize test arena")
		return
	}
	defer virtual.arena_destroy(&arena)
	alloc := virtual.arena_allocator(&arena)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	world, start := world_start(&kernel, []string{library, scenarios}, alloc)
	if !start.ok {
		testing.expectf(t, false, "marker scenarios failed to load: %s", start.message)
		return
	}
	defer world_destroy(world)
	started := world_wait(world, world.entry)
	if started.kind != .Complete {
		testing.expectf(
			t,
			false,
			"marker scenario load task did not complete: %s",
			started.message,
		)
		return
	}

	verbs := []string {
		"test/marker_rebase_insertion_types",
		"test/marker_rebase_shifts_and_collapses",
		// Order matters: seed publishes revision 1, the token apply publishes
		// revision 2, and the rebase reads that change back.
		"test/marker_seed",
		"test/buffer_computed_stat_and_lines",
		"test/buffer_computed_lines_are_bounded",
		"test/marker_create_at_committed_revision",
		"test/marker_apply_with_token",
		"test/marker_rebases_from_the_recorded_delta",
		"test/annotation_follows_its_markers",
		"test/annotation_drop_collapsed",
	}
	for verb in verbs {
		outcome := world_call(world, verb, nil)
		detail := outcome.message
		if error_value, is_error := v.value_as_error(outcome.error); is_error {
			detail = error_value.message
		}
		testing.expectf(
			t,
			outcome.kind == .Complete,
			"%s: kind=%v message=%s",
			verb,
			outcome.kind,
			detail,
		)
	}
}

@(test)
test_retrieval_computed_relation_scenarios :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	library := scenario_source_path("apps/shared/retrieval.mica")
	scenarios := scenario_source_path("apps/retrieval/tests/computed-scenarios.mica")
	if library == "" || scenarios == "" {
		testing.expect(t, false, "retrieval scenario sources not found")
		return
	}

	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		testing.expect(t, false, "cannot initialize test arena")
		return
	}
	defer virtual.arena_destroy(&arena)
	alloc := virtual.arena_allocator(&arena)
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := world_start(&kernel, []string{library, scenarios}, alloc)
	if !start.ok {
		testing.expectf(t, false, "retrieval scenarios failed to load: %s", start.message)
		return
	}
	defer world_destroy(world)
	if started := world_wait(world, world.entry); started.kind != .Complete {
		testing.expectf(t, false, "retrieval scenario load failed: %s", started.message)
		return
	}
	verbs := []string{"test/retrieval_seed", "test/retrieval_exact_computed_relation"}
	for verb in verbs {
		outcome := world_call(world, verb, nil)
		testing.expectf(
			t,
			outcome.kind == .Complete,
			"%s: kind=%v message=%s",
			verb,
			outcome.kind,
			outcome.message,
		)
	}
}

// Booting from a store restores every stored rule; the fixpoint over the
// stored facts runs once for the whole rule set, not once per rule.
@(test)
test_run_store_boot_derives_once :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	RULES :: 6
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	strings.write_string(&b, "make_relation(:Edge, 2)\n")
	for i in 0 ..< RULES {
		fmt.sbprintf(&b, "make_relation(:Reach%d, 2)\n", i)
	}
	for i in 0 ..< RULES {
		fmt.sbprintf(&b, "\nReach%d(a, b) :-\n  Edge(a, b)\n", i)
	}
	strings.write_string(&b, "\nassert Edge(1, 2)\nassert Edge(2, 3)\n")
	path, path_ok := write_temp_source(t, "mica_store_boot_derive_test.mica", strings.to_string(b))
	if !path_ok {
		return
	}
	defer os.remove(path)

	directory, directory_error := os.temp_dir(context.temp_allocator)
	if directory_error != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	store_path, join_error := filepath.join(
		[]string{directory, "mica_store_boot_derive"},
		context.temp_allocator,
	)
	if join_error != nil {
		return
	}
	os.remove_all(store_path)
	defer os.remove_all(store_path)

	{
		kernel: k.Kernel
		k.kernel_init(&kernel)
		world, start := world_start(
			&kernel,
			[]string{path},
			context.temp_allocator,
			World_Config{store_path = store_path},
		)
		testing.expectf(t, start.ok, "load failed: %s", start.message)
		if start.ok {
			entry := world_wait(world, world.entry)
			testing.expect_value(t, entry.kind, Task_Outcome_Kind.Complete)
			testing.expect(t, world_checkpoint(world))
			world_destroy(world)
		}
		k.kernel_destroy(&kernel)
	}

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := world_start(
		&kernel,
		nil,
		context.temp_allocator,
		World_Config{store_path = store_path},
	)
	testing.expectf(t, start.ok, "boot failed: %s", start.message)
	if !start.ok {
		return
	}
	defer world_destroy(world)
	derivations := k.kernel_derivation_count(&kernel)
	testing.expectf(t, derivations <= 2, "boot ran %d derivations for %d rules", derivations, RULES)
	for i in 0 ..< RULES {
		expect_relation_rows(t, &kernel, fmt.tprintf("Reach%d", i), 2)
	}
}

// Values a task reads from a relation outlive the transaction that read them
// (a task keeps them across commits and suspensions, when the rows' chunks can
// be freed), so every read path hands the VM its own copy, not a pointer into
// the stored row.
@(test)
test_run_relation_reads_are_owned_by_the_task :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:a)
make_functional_relation(:Label, 2, [0])
assert Label(#a, "alpha-label")

verb read_one()
  let exactly {:l -> l} = Label(#a, ?l)
  return l
end
verb read_first()
  let {:l -> l} = Label(#a, ?l)
  return l
end
verb read_field()
  return #a.label
end
`
	path, path_ok := write_temp_source(t, "mica_owned_reads_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := world_start(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, start.ok, "load failed: %s", start.message)
	if !start.ok {
		return
	}
	defer world_destroy(world)
	entry := world_wait(world, world.entry)
	testing.expect_value(t, entry.kind, Task_Outcome_Kind.Complete)

	snapshot := k.kernel_snapshot(&kernel)
	defer k.snapshot_release(snapshot)
	label, _ := k.snapshot_relation_metadata_named(snapshot, v.symbol_intern("Label"))
	block, has_block := k.snapshot_relation_block(snapshot, label.id)
	testing.expect(t, has_block)
	if !has_block {
		return
	}
	stored_row := v.tuple_values(k.relation_block_row(block, 0))
	stored, _ := v.value_as_string(stored_row[1])

	verbs := []string{"read_one", "read_first", "read_field"}
	for verb in verbs {
		outcome := world_call(world, verb, nil)
		testing.expectf(t, outcome.kind == .Complete, "%s failed: %s", verb, outcome.message)
		got, is_string := v.value_as_string(outcome.value)
		testing.expectf(t, is_string && got == "alpha-label", "%s returned %v", verb, outcome.value)
		testing.expectf(t, raw_data(got) != raw_data(stored), "%s returned the stored row's bytes, not a copy", verb)
	}
}

// Subscription messages sit in a mailbox until the receiver runs, after the
// snapshot their rows came from may be gone (and its chunks freed): scanned
// rows are copies taken while the snapshot is held, and message values own
// their strings.
@(test)
test_run_subscription_rows_are_owned :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Note, 2)
assert Note(5, "note-text")
`
	path, path_ok := write_temp_source(t, "mica_subscription_owned_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := world_start(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, start.ok, "load failed: %s", start.message)
	if !start.ok {
		return
	}
	defer world_destroy(world)
	_ = world_wait(world, world.entry)

	snapshot := k.kernel_snapshot(&kernel)
	defer k.snapshot_release(snapshot)
	note, _ := k.snapshot_relation_metadata_named(snapshot, v.symbol_intern("Note"))
	block, has_block := k.snapshot_relation_block(snapshot, note.id)
	testing.expect(t, has_block)
	if !has_block {
		return
	}
	stored_row := v.tuple_values(k.relation_block_row(block, 0))
	stored, _ := v.value_as_string(stored_row[1])

	rows := subscription_scan_rows(&world.env, .Facts, note.id, []v.Binding{{}, {}})
	defer delete(rows)
	testing.expect_value(t, len(rows), 1)
	if len(rows) != 1 {
		return
	}
	scanned, _ := v.value_as_string(v.tuple_values(rows[0])[1])
	testing.expect(t, scanned == "note-text")
	testing.expect(t, raw_data(scanned) != raw_data(stored))

	message := subscription_row_value(&world.env, rows[0])
	items, _ := v.value_as_list(message)
	text, _ := v.value_as_string(items[1])
	testing.expect(t, text == "note-text")
	testing.expect(t, raw_data(text) != raw_data(scanned))
}
