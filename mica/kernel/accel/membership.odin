// Metal-accelerated membership filter for rule evaluation.
//
// A rule body frequently probes "does this value occur in relation R" —
// existence checks for negated atoms, duplicate suppression in
// `rules_derived_add`, and closure fixpoint convergence. When R is a large
// single-column identity relation, those probes are one sorted membership
// test each. This helper encodes a column of identity values once and answers
// batch probes through the given strategy, falling back to the CPU reference
// for anything else.
//
// The encoding is the raw u64 identity word: Mica `Value` is a 64-bit word
// with the tag in the top byte (`mica/var/value.odin`), so identity values
// sort and compare as plain u64s with no marshalling loss.
package accel

import v "../../var"

// Reports whether every value in `col` is an identity (encodable).
column_is_identities :: proc(col: []v.Value) -> bool {
	for value in col {
		if v.value_tag(value) != .Identity {
			return false
		}
	}
	return true
}

// Encodes identity values as raw u64 words. Caller owns the result.
encode_identities :: proc(
	col: []v.Value,
	allocator := context.allocator,
) -> []u64 {
	out := make([]u64, len(col), allocator)
	for value, i in col {
		out[i] = u64(value)
	}
	return out
}

// Batch membership through `s`: for each value in `probes`, report membership
// in `column`, which must be sorted-unique encoded words (see
// `is_sorted_unique`). Returns (results, ok); on decline the caller runs its
// own CPU path. Pass an explicit strategy; `membership_probe_active`
// dispatches through the active one.
membership_probe_identities :: proc(
	probes: []v.Value,
	column_sorted_unique: []u64,
	keep_matches := true,
	allocator := context.allocator,
	s: Strategy,
) -> (
	results: []bool,
	ok: bool,
) {
	if !column_is_identities(probes) {
		return nil, false
	}
	encoded := encode_identities(probes, context.temp_allocator)
	selected, selected_ok := s.membership_select(encoded, column_sorted_unique, keep_matches)
	if !selected_ok {
		return nil, false
	}
	out := make([]bool, len(selected), allocator)
	copy(out, selected)
	delete(selected)
	return out, true
}

// Convenience wrapper dispatching through the active strategy.
membership_probe_active :: proc(
	probes: []v.Value,
	column_sorted_unique: []u64,
	keep_matches := true,
	allocator := context.allocator,
) -> (
	results: []bool,
	ok: bool,
) {
	return membership_probe_identities(
		probes,
		column_sorted_unique,
		keep_matches,
		allocator,
		active_strategy(),
	)
}
