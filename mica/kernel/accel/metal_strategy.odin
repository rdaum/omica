// Darwin Metal strategy: the operator set backed by Metal compute.
// Ryan's Vulkan/CUDA backends will add sibling constructors against the same
// `Strategy` shape.
#+build darwin
package accel

// The Metal operator set. Gated to Apple hardware at runtime via
// CreateSystemDefaultDevice; without a device `available` is false and every
// operator declines.
metal_strategy :: proc() -> Strategy {
	return Strategy {
		name = "metal",
		available = metal_available_impl,
		membership_select = metal_membership_select,
		cosine_query = metal_cosine_query,
	}
}

metal_membership_select :: proc(
	left: []u64,
	right_sorted_unique: []u64,
	keep_matches: bool,
) -> (
	selected: []bool,
	ok: bool,
) {
	return membership_select_impl(left, right_sorted_unique, keep_matches)
}

metal_cosine_query :: proc(
	query: []f32,
	docs: []f32,
	n_docs: int,
	dim: int,
) -> (
	scores: []f32,
	ok: bool,
) {
	return cosine_query_impl(query, docs, n_docs, dim)
}

// Opts production dispatch into Metal, declining to CPU per operator.
use_metal :: proc() {
	select_strategy(metal_strategy())
}
