// Tests for the local-worktree indexer: a small tree indexes into the source
// relations the agent tools query.
package source

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

import k "../../mica/kernel"
import r "../../mica/runtime"
import v "../../mica/var"

@(private)
SCHEMA_SOURCE :: `make_identity(:source/repo_default)
make_identity(:source/rev_worktree)
make_relation(:source/RepositoryEntry, 7)
make_relation(:source/FileText, 7)
make_relation(:source/FileLineCount, 6)
make_relation(:source/IndexedFile, 6)
`

@(private)
relation_rows :: proc(world: ^r.World, name: string) -> (rows: [dynamic]v.Tuple, ok: bool) {
	relation, has_relation := world.ctx.relations[name]
	if !has_relation {
		return rows, false
	}
	metadata, has_metadata := k.snapshot_relation_metadata(
		world.kernel.current,
		k.Relation_ID(relation),
	)
	if !has_metadata {
		return rows, false
	}
	bindings := make([]v.Binding, metadata.arity, context.temp_allocator)
	k.kernel_scan_into(world.kernel, k.Relation_ID(relation), bindings, &rows)
	return rows, true
}

@(test)
test_index_workspace_tree :: proc(t: ^testing.T) {
	test_index_workspace_tree_with_root(t, "plain")
}

@(test)
test_index_workspace_normalized_root :: proc(t: ^testing.T) {
	test_index_workspace_tree_with_root(t, "normalized")
}

@(test)
test_index_workspace_symlink_root :: proc(t: ^testing.T) {
	test_index_workspace_tree_with_root(t, "symlink")
}

@(test)
test_index_workspace_relative_root :: proc(t: ^testing.T) {
	test_index_workspace_tree_with_root(t, "relative")
}

@(test)
test_index_workspace_relative_symlink_root :: proc(t: ^testing.T) {
	test_index_workspace_tree_with_root(t, "relative_symlink")
}

@(test)
test_index_rejects_file_root :: proc(t: ^testing.T) {
	test_index_workspace_tree_with_root(t, "file")
}

@(test)
test_index_rejects_missing_root :: proc(t: ^testing.T) {
	test_index_workspace_tree_with_root(t, "missing")
}

@(test)
test_index_reports_unreadable_child :: proc(t: ^testing.T) {
	// Root bypasses Unix directory permissions.
	if os.get_euid() == 0 {return}
	test_index_workspace_tree_with_root(t, "unreadable_child")
}

@(test)
test_relative_path_requires_root_boundary :: proc(t: ^testing.T) {
	cases := []struct{root, path, want: string, ok: bool}{
		{"/workspace", "/workspace/src/main.mica", "src/main.mica", true},
		{"/workspace", "/workspace", "", true},
		{"/", "/src/main.mica", "src/main.mica", true},
		{"/", "//src/main.mica", "src/main.mica", true},
		{"/workspace", "/workspace-other/file", "", false},
		{"/workspace", "/other/file", "", false},
		{"/workspace", "", "", false},
	}
	for c in cases {
		relative, ok := relative_to(c.root, c.path)
		testing.expect_value(t, ok, c.ok)
		testing.expect_value(t, relative, c.want)
	}
}

@(private)
test_index_workspace_tree_with_root :: proc(t: ^testing.T, root_kind: string) {
	defer free_all(context.temp_allocator)
	directory, directory_err := os.temp_dir(context.temp_allocator)
	if directory_err != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	root := fmt.aprintf(
		"%s/omica-source-test-%d",
		directory,
		time.tick_now()._nsec,
		allocator = context.temp_allocator,
	)
	defer os.remove_all(root)
	if err := os.make_directory_all(
		fmt.aprintf("%s/src", root, allocator = context.temp_allocator),
	); err != nil {
		testing.expectf(t, false, "cannot create test tree: %v", err)
		return
	}
	if err := os.write_entire_file(
		fmt.aprintf("%s/README.md", root, allocator = context.temp_allocator),
		"Hello\nworld\n",
	); err != nil {
		testing.expectf(t, false, "cannot write README: %v", err)
		return
	}
	if err := os.write_entire_file(
		fmt.aprintf("%s/src/main.mica", root, allocator = context.temp_allocator),
		"verb main()\nend\n",
	); err != nil {
		testing.expectf(t, false, "cannot write main.mica: %v", err)
		return
	}

	// The schema file lives outside the indexed root so it is not indexed.
	schema_path := fmt.aprintf(
		"%s/omica-source-schema-%d.mica",
		directory,
		time.tick_now()._nsec,
		allocator = context.temp_allocator,
	)
	defer os.remove(schema_path)
	if err := os.write_entire_file(schema_path, SCHEMA_SOURCE); err != nil {
		testing.expectf(t, false, "cannot write schema: %v", err)
		return
	}

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := r.world_start(
		&kernel,
		[]string{schema_path},
		context.temp_allocator,
		r.World_Config{workers = 1},
	)
	if !start.ok {
		testing.expectf(t, false, "world start failed: %s", start.message)
		return
	}
	defer r.world_destroy(world)
	r.world_wait(world, world.entry)

	indexed_root := root
	switch root_kind {
	case "normalized":
		indexed_root = fmt.aprintf("%s//.", root, allocator = context.temp_allocator)
	case "symlink", "relative_symlink":
		indexed_root = fmt.aprintf("%s-link", root, allocator = context.temp_allocator)
		err := os.symlink(root, indexed_root)
		testing.expectf(t, err == nil, "cannot create root alias: %v", err)
		if err != nil {return}
	case "file":
		indexed_root = fmt.aprintf("%s/README.md", root, allocator = context.temp_allocator)
	case "missing":
		indexed_root = fmt.aprintf("%s/missing", root, allocator = context.temp_allocator)
	}
	child := fmt.aprintf("%s/src", root, allocator = context.temp_allocator)
	// The indexer names paths under the root as the opened root directory
	// reports them (on macOS /var resolves to /private/var), so the expected
	// child path is built the same way, before the child becomes unreadable.
	resolved_child := child
	if root_file, open_err := os.open(root); open_err == nil {
		if info, stat_err := os.fstat(root_file, context.temp_allocator); stat_err == nil {
			resolved_child = fmt.aprintf("%s/src", info.fullpath, allocator = context.temp_allocator)
		}
		os.close(root_file)
	}
	if root_kind == "unreadable_child" {
		if !testing.expect(t, os.chmod(child, {}) == nil) {return}
	}
	defer if root_kind == "unreadable_child" {os.chmod(child, os.Permissions_Default_Directory)}
	alias := indexed_root
	defer if root_kind == "symlink" || root_kind == "relative_symlink" {os.remove(alias)}
	if root_kind == "relative" || root_kind == "relative_symlink" {
		cwd, cwd_err := os.getwd(context.temp_allocator)
		testing.expect(t, cwd_err == nil)
		if cwd_err != nil {return}
		relative, rel_err := filepath.rel(cwd, indexed_root, context.temp_allocator)
		testing.expect(t, rel_err == .None)
		if rel_err != .None {return}
		indexed_root = relative
	}
	result := index_world(world, Options{root = indexed_root})
	if root_kind == "unreadable_child" {
		testing.expect(t, !result.ok, "failed traversal reported a successful index")
		testing.expectf(t, strings.contains(result.message, "cannot walk") && strings.contains(result.message, resolved_child), "missing traversal error: %s", result.message)
		entries, entries_ok := relation_rows(world, "source/RepositoryEntry")
		defer delete(entries)
		testing.expect(t, entries_ok)
		testing.expect_value(t, len(entries), 0) // Do not publish the unfinished batch.
		return
	}
	if root_kind == "file" || root_kind == "missing" {
		testing.expect(t, !result.ok, "invalid root reported a successful index")
		testing.expectf(t, strings.contains(result.message, indexed_root), "error omitted root %q: %s", indexed_root, result.message)
		return
	}
	if !testing.expectf(t, result.ok, "index failed for %q (%s): %s", indexed_root, root_kind, result.message) {
		return
	}
	testing.expectf(t, result.files == 2 && result.directories == 1, "root %q (%s): %v", indexed_root, root_kind, result)
	testing.expect_value(t, result.files, 2)
	testing.expect_value(t, result.directories, 1)

	entries, entries_ok := relation_rows(world, "source/RepositoryEntry")
	testing.expect(t, entries_ok)
	testing.expect_value(t, len(entries), 3)

	texts, texts_ok := relation_rows(world, "source/FileText")
	testing.expect(t, texts_ok)
	testing.expect_value(t, len(texts), 2)
	if len(texts) == 2 {
		// Rows are canonically ordered by path: README.md then src/main.mica.
		first := v.tuple_values(texts[0])
		path, _ := v.value_as_string(first[2])
		text, _ := v.value_as_string(first[4])
		testing.expect_value(t, path, "README.md")
		testing.expect_value(t, text, "Hello\nworld\n")
	}

	line_counts, line_ok := relation_rows(world, "source/FileLineCount")
	testing.expect(t, line_ok)
	testing.expect_value(t, len(line_counts), 2)
	if len(line_counts) == 2 {
		first := v.tuple_values(line_counts[0])
		count, _ := v.value_as_int(first[3])
		testing.expect_value(t, count, i64(2))
	}

	indexed, indexed_ok := relation_rows(world, "source/IndexedFile")
	testing.expect(t, indexed_ok)
	testing.expect_value(t, len(indexed), 2)
	if len(indexed) == 2 {
		first := v.tuple_values(indexed[0])
		language, _ := v.value_as_string(first[4])
		testing.expect_value(t, language, "markdown")
	}

	delete(entries)
	delete(texts)
	delete(line_counts)
	delete(indexed)
}

// A world without the source schema is reported, not an error.
@(test)
test_index_skips_world_without_schema :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	directory, directory_err := os.temp_dir(context.temp_allocator)
	if directory_err != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	path := fmt.aprintf(
		"%s/omica-source-empty-%d.mica",
		directory,
		time.tick_now(),
		allocator = context.temp_allocator,
	)
	defer os.remove(path)
	if err := os.write_entire_file(path, "make_relation(:Marker, 1)\n"); err != nil {
		testing.expectf(t, false, "cannot write source: %v", err)
		return
	}
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := r.world_start(
		&kernel,
		[]string{path},
		context.temp_allocator,
		r.World_Config{workers = 1},
	)
	if !start.ok {
		testing.expectf(t, false, "world start failed: %s", start.message)
		return
	}
	defer r.world_destroy(world)
	r.world_wait(world, world.entry)

	result := index_world(world, Options{root = directory})
	testing.expect(t, !result.ok)
	testing.expectf(t, result.message != "", "expected a message")
}
