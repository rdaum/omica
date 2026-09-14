// Reference CPU strategy: same operator shapes as the Metal backend, always
// available, no size thresholds. Benchmarks and tests run this side by side
// with the Metal strategy over identical inputs.
package accel

@(private)
cpu_available :: proc() -> bool {
	return true
}

// Binary search of each probe in the sorted-unique right column. The Metal
// membership shader implements this same algorithm per thread.
@(private)
cpu_membership_select :: proc(
	left: []u64,
	right_sorted_unique: []u64,
	keep_matches: bool,
) -> (
	selected: []bool,
	ok: bool,
) {
	if len(right_sorted_unique) == 0 {
		out := make([]bool, len(left), context.allocator)
		for i in 0 ..< len(left) {
			out[i] = !keep_matches
		}
		return out, true
	}
	if !is_sorted_unique(right_sorted_unique) {
		return nil, false
	}
	out := make([]bool, len(left), context.allocator)
	for probe, i in left {
		hit := cpu_sorted_contains(right_sorted_unique, probe)
		out[i] = (hit == keep_matches)
	}
	return out, true
}

@(private)
cpu_sorted_contains :: proc(sorted_unique: []u64, probe: u64) -> bool {
	lo, hi := 0, len(sorted_unique)
	for lo < hi {
		mid := lo + ((hi - lo) >> 1)
		if sorted_unique[mid] < probe {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo < len(sorted_unique) && sorted_unique[lo] == probe
}

// One thread of the Metal cosine shader, run sequentially: one (query, doc)
// pair at a time with the same arithmetic.
@(private)
cpu_cosine_query :: proc(
	query: []f32,
	docs: []f32,
	n_docs: int,
	dim: int,
) -> (
	scores: []f32,
	ok: bool,
) {
	if n_docs < 1 || dim < 1 {
		return nil, false
	}
	if len(query) < dim || len(docs) < n_docs * dim {
		return nil, false
	}
	out := make([]f32, n_docs, context.allocator)
	for i in 0 ..< n_docs {
		d2, qn, dn := f32(0), f32(0), f32(0)
		for d in 0 ..< dim {
			qv := query[d]
			dv := docs[i * dim + d]
			d2 += qv * dv
			qn += qv * qv
			dn += dv * dv
		}
		out[i] = d2 / (cpu_sqrt(qn) * cpu_sqrt(dn) + 1e-9)
	}
	return out, true
}

@(private)
cpu_sqrt :: proc(x: f32) -> f32 {
	return x * cpu_inv_sqrt(x)
}

@(private)
cpu_inv_sqrt :: proc(x: f32) -> f32 {
	// Two Newton refinements of the bit-level approximation; matches the
	// Metal sqrt to the test tolerance (1e-3 on squared scores).
	i := transmute(u32)x
	i = 0x5f3759df - (i >> 1)
	y := transmute(f32)i
	y = y * (1.5 - 0.5 * x * y * y)
	y = y * (1.5 - 0.5 * x * y * y)
	return y
}
