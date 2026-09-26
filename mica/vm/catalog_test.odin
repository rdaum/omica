package vm

import "core:testing"
import k "../kernel"
import v "../var"

@(test)
test_vm_named_scan_resolves_staged_relation :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	tx := k.kernel_begin(&kernel)
	defer k.transaction_destroy(&tx)
	name := v.symbol_intern("Staged")
	id, err := k.transaction_create_relation(&tx, k.relation_metadata(0, name, 1))
	testing.expect_value(t, err, k.Kernel_Error.None)
	source := k.Relation_Source{transaction = &tx}
	state := VM{source = &source, transaction = &tx, allocator = context.temp_allocator}
	resolved, ok := vm_resolve_pattern_relation(&state, Scan_Pattern{relation_name = name})
	testing.expect(t, ok)
	testing.expect_value(t, resolved, id)
	_, published := k.snapshot_relation_metadata_named(tx.base, name)
	testing.expect(t, !published)
}
