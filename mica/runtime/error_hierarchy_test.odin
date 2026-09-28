// Error hierarchy: ErrorParent links error codes, ErrorIsA is their
// reflexive, transitive closure, and a catch clause accepts any code
// descended from its own (draft-ndn-error-hierarchy-00).
package mica_runtime

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:testing"
import k "../kernel"

@(private = "file")
run_error_source :: proc(t: ^testing.T, name: string, source: string, options := Run_Options{}) -> (^k.Kernel, bool) {
	path, path_ok := write_temp_source(t, name, source)
	if !path_ok {
		return nil, false
	}
	defer os.remove(path)
	kernel := new(k.Kernel)
	k.kernel_init(kernel)
	result := run_files(kernel, []string{path}, runtime.heap_allocator(), options)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	return kernel, result.ok
}

@(private = "file")
drop_kernel :: proc(kernel: ^k.Kernel) {
	if kernel != nil {
		k.kernel_destroy(kernel)
		free(kernel)
	}
}

@(test)
test_error_hierarchy_builtin_links :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Done, 1)
require ErrorParent(E_KEY, ?parent) == [:parent] {[E_LOOKUP]}
require ErrorParent(E_INDEX, ?parent) == [:parent] {[E_LOOKUP]}
require ErrorParent(E_DIV, ?parent) == [:parent] {[E_ARITH]}
require ErrorParent(E_CONFLICT, ?parent) == [:parent] {[E_TRANSACTION]}
require ErrorParent(E_PERMISSION, ?parent) == [:parent] {[E_AUTHORITY]}
require !ErrorParent(E_CARDINALITY, _)
require ErrorIsA(E_KEY, E_LOOKUP)
require ErrorIsA(E_KEY, E_KEY)
require ErrorIsA(E_CARDINALITY, E_CARDINALITY)
require !ErrorIsA(E_LOOKUP, E_KEY)
require ErrorIsA(E_KEY, ?ancestor) == [:ancestor] {[E_KEY], [E_LOOKUP]}
assert Done(1)
`
	kernel, ok := run_error_source(t, "mica_error_builtin_links_test.mica", source)
	defer drop_kernel(kernel)
	if ok {
		expect_relation_rows(t, kernel, "Done", 1)
	}
}

@(test)
test_error_catch_by_ancestry :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Caught, 2)
try
  raise E_KEY, "missing"
catch E_LOOKUP as problem
  assert Caught(problem.code, problem.code == E_LOOKUP)
end
try
  raise E_KEY
catch E_KEY
  assert Caught(:exact, true)
end
try
  try
    raise E_LOOKUP
  catch E_KEY
    assert Caught(:wrong, true)
  end
catch E_LOOKUP
  assert Caught(:parent_not_caught_by_child, true)
end
`
	kernel, ok := run_error_source(t, "mica_error_catch_ancestry_test.mica", source)
	defer drop_kernel(kernel)
	if ok {
		expect_relation_rows(t, kernel, "Caught", 3)
	}
}

@(test)
test_error_lookup_codes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Code, 1)
let settings = {:colour -> "amber"}
try
  settings[:size]
catch E_LOOKUP as problem
  assert Code(problem.code)
end
try
  [1, 2][5]
catch E_LOOKUP as problem
  assert Code(problem.code)
end
require Code(?code) == [:code] {[E_KEY], [E_INDEX]}
`
	kernel, ok := run_error_source(t, "mica_error_lookup_codes_test.mica", source)
	defer drop_kernel(kernel)
	if ok {
		expect_relation_rows(t, kernel, "Code", 2)
	}
}

@(test)
test_error_hierarchy_extends_in_task :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Handled, 1)
assert ErrorParent(E_UPSTREAM_TIMEOUT, E_UPSTREAM)
assert ErrorParent(E_UPSTREAM_TIMEOUT, E_TIMEOUT)
try
  raise E_UPSTREAM_TIMEOUT
catch E_UPSTREAM
  assert Handled(:upstream)
end
try
  raise E_UPSTREAM_TIMEOUT
catch E_TIMEOUT
  assert Handled(:timeout)
end
`
	kernel, ok := run_error_source(t, "mica_error_extend_test.mica", source)
	defer drop_kernel(kernel)
	if ok {
		expect_relation_rows(t, kernel, "Handled", 2)
	}
}

@(test)
test_error_hierarchy_rejects_cycles :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Rejected, 1)
try
  assert ErrorParent(E_LOOKUP, E_KEY)
catch E_INVARG
  assert Rejected(:cycle)
end
try
  assert ErrorParent(E_KEY, E_KEY)
catch E_INVARG
  assert Rejected(:self)
end
`
	kernel, ok := run_error_source(t, "mica_error_cycle_test.mica", source)
	defer drop_kernel(kernel)
	if ok {
		expect_relation_rows(t, kernel, "Rejected", 2)
		expect_relation_rows(t, kernel, "ErrorParent", 9)
	}
}

@(test)
test_error_catch_needs_no_read_authority :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:alice)
make_identity(:reader)
make_relation(:RoleCanRead, 2)
make_relation(:RoleCanWrite, 2)
make_relation(:Seen, 1)
assert Delegates(#alice, #reader, 0)
grant role #reader
  write:
    :Seen
end
commit()
verb probe()
  try
    raise E_KEY
  catch E_LOOKUP
    assert Seen(1)
  end
end
spawn :probe()
suspend()
`
	kernel, ok := run_error_source(
		t,
		"mica_error_catch_authority_test.mica",
		source,
		Run_Options{actor = "alice"},
	)
	defer drop_kernel(kernel)
	if ok {
		expect_relation_rows(t, kernel, "Seen", 1)
	}
}

// Built-in links are seeded when ErrorParent is created, not on every start,
// so a world that retracts one keeps it retracted after reopening.
@(test)
test_error_hierarchy_seeds_once :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	directory, directory_error := os.temp_dir(context.temp_allocator)
	if directory_error != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	store_path, join_error := filepath.join(
		[]string{directory, "mica_error_hierarchy_store"},
		context.temp_allocator,
	)
	if join_error != nil {
		return
	}
	os.remove_all(store_path)
	defer os.remove_all(store_path)
	config := World_Config{store_path = store_path}

	// First world: retract one built-in link and add a new one.
	{
		kernel: k.Kernel
		k.kernel_init(&kernel)
		defer k.kernel_destroy(&kernel)
		world, start := world_start(&kernel, nil, runtime.heap_allocator(), config)
		testing.expectf(t, start.ok, "first start failed: %s", start.message)
		if !start.ok {
			return
		}
		outcome := world_eval(
			world,
			"retract ErrorParent(E_KEY, E_LOOKUP)\nassert ErrorParent(E_GATEWAY, E_LOOKUP)\nreturn true",
		)
		testing.expectf(t, outcome.kind == .Complete, "first eval: %v %s", outcome.kind, outcome.message)
		testing.expect(t, world_checkpoint(world))
		world_destroy(world)
	}

	// Second world: the retraction and the new link survive; the rest remain.
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := world_start(&kernel, nil, runtime.heap_allocator(), config)
	testing.expectf(t, start.ok, "second start failed: %s", start.message)
	if !start.ok {
		return
	}
	defer world_destroy(world)
	outcome := world_eval(
		world,
		`require !ErrorParent(E_KEY, _)
require ErrorParent(E_GATEWAY, E_LOOKUP)
require ErrorParent(E_INDEX, E_LOOKUP)
return true`,
	)
	testing.expectf(t, outcome.kind == .Complete, "second eval: %v %s", outcome.kind, outcome.message)
}
