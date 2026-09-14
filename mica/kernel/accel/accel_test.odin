package accel

import "core:testing"
import v "../../var"

@(test)
test_cpu_strategy_available :: proc(t: ^testing.T) {
	testing.expect(t, cpu_strategy().available())
}

@(test)
test_is_sorted_unique :: proc(t: ^testing.T) {
	testing.expect(t, is_sorted_unique(nil))
	testing.expect(t, is_sorted_unique([]u64{1}))
	testing.expect(t, is_sorted_unique([]u64{1, 2, 3}))
	testing.expect(t, !is_sorted_unique([]u64{1, 1, 2}))
	testing.expect(t, !is_sorted_unique([]u64{3, 2, 1}))
}

@(test)
test_cpu_strategy_handles_small :: proc(t: ^testing.T) {
	c := cpu_strategy()
	selected, ok := c.membership_select([]u64{1, 2, 3}, []u64{2, 3, 4}, true)
	testing.expect(t, ok)
	if ok {
		defer delete(selected)
		testing.expect(t, slice_eq(selected, []bool{false, true, true}))
	}
	comp, comp_ok := c.membership_select([]u64{1, 2, 3}, []u64{2, 3, 4}, false)
	testing.expect(t, comp_ok)
	if comp_ok {
		defer delete(comp)
		testing.expect(t, slice_eq(comp, []bool{true, false, false}))
	}
	scores, scores_ok := c.cosine_query([]f32{1, 0}, []f32{1, 0, 0, 1}, 2, 2)
	testing.expect(t, scores_ok)
	if scores_ok {
		defer delete(scores)
		testing.expect(t, len(scores) == 2)
	}
}

@(test)
test_probe_helper_declines_non_identities :: proc(t: ^testing.T) {
	one, _ := v.value_int(1)
	_, ok := membership_probe_identities(
		[]v.Value{one},
		[]u64{1, 2, 3},
		true,
		context.temp_allocator,
		cpu_strategy(),
	)
	testing.expect(t, !ok)
}

// Element-wise equality; []bool is not directly comparable in Odin.
slice_eq :: proc(a, b: []bool) -> bool {
	if len(a) != len(b) {
		return false
	}
	for x, i in a {
		if x != b[i] {
			return false
		}
	}
	return true
}
