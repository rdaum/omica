// Accelerator strategies for Mica relation operators.
//
// Selection is a strategy value, not a conditional: callers hold a `Strategy`
// (CPU reference, Metal, and later Vulkan/CUDA) and invoke its operators.
// Production code uses `active_strategy()`; benchmarks and tests pass
// strategies explicitly to run the same workload down multiple paths.
//
// The contract mirrors the Rust `RelationAccelerator` trait
// (`crates/relation-kernel/src/execution.rs`): optional, row-threshold gated,
// decline-on-anything-unexpected. The kernel must always be able to complete
// the operation on CPU.
package accel

// One operator set: availability probe plus the accelerated operators. Every
// operator returns `ok=false` to decline, in which case the caller runs its
// CPU path.
Strategy :: struct {
	name:              string,
	available:         proc() -> bool,
	membership_select: proc(left: []u64, right_sorted_unique: []u64, keep_matches: bool) -> (selected: []bool, ok: bool),
	cosine_query:      proc(query: []f32, docs: []f32, n_docs: int, dim: int) -> (scores: []f32, ok: bool),
}

// Reference CPU operator set. Always available, handles any input size.
cpu_strategy :: proc() -> Strategy {
	return Strategy {
		name = "cpu",
		available = cpu_available,
		membership_select = cpu_membership_select,
		cosine_query = cpu_cosine_query,
	}
}

@(private)
active_data: Strategy

@(private)
active_ready: bool

// The strategy production code dispatches through. Defaults to CPU;
// `select_strategy` overrides it for the process. GPU backends are strictly
// opt-in: call `use_metal()` on Darwin (later: Vulkan/CUDA constructors).
active_strategy :: proc() -> Strategy {
	if !active_ready {
		active_data = cpu_strategy()
		active_ready = true
	}
	return active_data
}

// Installs the strategy production code dispatches through.
select_strategy :: proc(s: Strategy) {
	active_data = s
	active_ready = true
}

// Production dispatches through the CPU reference only.
use_cpu :: proc() {
	select_strategy(cpu_strategy())
}

// Membership probe dispatched through the active strategy.
membership_select :: proc(
	left: []u64,
	right_sorted_unique: []u64,
	keep_matches: bool,
) -> (
	selected: []bool,
	ok: bool,
) {
	s := active_strategy()
	return s.membership_select(left, right_sorted_unique, keep_matches)
}

// Cosine similarity dispatched through the active strategy.
cosine_query :: proc(
	query: []f32,
	docs: []f32,
	n_docs: int,
	dim: int,
) -> (
	scores: []f32,
	ok: bool,
) {
	s := active_strategy()
	return s.cosine_query(query, docs, n_docs, dim)
}

// Encoded u64 column sort order expected by the membership operator: ascending.
is_sorted_unique :: proc(rows: []u64) -> bool {
	if len(rows) < 2 {
		return true
	}
	for i in 1 ..< len(rows) {
		if rows[i - 1] >= rows[i] {
			return false
		}
	}
	return true
}
