// A/B benchmarks: identical workloads through the CPU reference strategy
// and GPU strategies (Metal on Darwin; Vulkan/CUDA later). Each pair shares
// inputs; the delta column (via -baseline) shows the speedup. GPU entries
// decline gracefully when no device is present, in which case only the CPU
// side is meaningful.
package main

import "core:mem"
import "core:mem/virtual"

import mm "../micromeasure"
import accl "../mica/kernel/accel"
import v "../mica/var"

Accel_State :: struct {
	arena: virtual.Arena,
	alloc: mem.Allocator,

	cpu:   accl.Strategy,
	// Populated only on Darwin; the bench bodies that read it are
	// `when ODIN_OS == .Darwin` gated, so Linux never touches it.
	metal: accl.Strategy,

	mem_left:  []u64,
	mem_right: []u64,

	cos_query: []f32,
	cos_docs:  []f32,
	cos_dim:   int,
	cos_docs_n: int,
	cos_cands: []accl.Cosine_Candidate,

	sink: u64,
}

@(private)
accel_state_init :: proc() -> ^Accel_State {
	state := new(Accel_State)
	if err := virtual.arena_init_growing(&state.arena); err != nil {
		panic("failed to initialize accel benchmark arena")
	}
	state.alloc = virtual.arena_allocator(&state.arena)
	state.cpu = accl.cpu_strategy()
	when ODIN_OS == .Darwin {
		state.metal = accl.metal_strategy()
	}

	n := 8192
	state.mem_left = make([]u64, n, state.alloc)
	state.mem_right = make([]u64, n / 2, state.alloc)
	for i in 0 ..< n {
		state.mem_left[i] = u64(i)
	}
	for i in 0 ..< n / 2 {
		state.mem_right[i] = u64(i * 2)
	}

	state.cos_dim = 64
	state.cos_docs_n = 2048
	state.cos_query = make([]f32, state.cos_dim, state.alloc)
	for i in 0 ..< state.cos_dim {
		state.cos_query[i] = f32(i + 1) / f32(state.cos_dim)
	}
	state.cos_docs = make([]f32, state.cos_docs_n * state.cos_dim, state.alloc)
	for i in 0 ..< len(state.cos_docs) {
		state.cos_docs[i] = f32((i % 37) + 1) / 37.0
	}
	state.cos_cands = make([]accl.Cosine_Candidate, state.cos_docs_n, state.alloc)
	for i in 0 ..< state.cos_docs_n {
		id, _ := v.identity_new(u64(1000 + i))
		state.cos_cands[i] = accl.Cosine_Candidate {
			subject = v.value_identity(id),
			vector  = state.cos_docs[i * state.cos_dim:(i + 1) * state.cos_dim],
		}
	}
	return state
}

@(private)
bench_cpu_membership :: proc(user: rawptr, chunk: int, _: int) {
	state := (^Accel_State)(user)
	total := u64(0)
	for _ in 0 ..< chunk {
		selected, ok := state.cpu.membership_select(state.mem_left, state.mem_right, true)
		if ok {
			total += u64(len(selected))
			delete(selected)
		}
	}
	state.sink = mm.black_box(total)
}

when ODIN_OS == .Darwin {

	@(private)
	bench_metal_membership :: proc(user: rawptr, chunk: int, _: int) {
		state := (^Accel_State)(user)
		total := u64(0)
		for _ in 0 ..< chunk {
			selected, ok := state.metal.membership_select(
				state.mem_left,
				state.mem_right,
				true,
			)
			if ok {
				total += u64(len(selected))
				delete(selected)
			}
		}
		state.sink = mm.black_box(total)
	}

	@(private)
	bench_metal_cosine :: proc(user: rawptr, chunk: int, _: int) {
		state := (^Accel_State)(user)
		total := u64(0)
		for _ in 0 ..< chunk {
			scores, ok := state.metal.cosine_query(
				state.cos_query,
				state.cos_docs,
				state.cos_docs_n,
				state.cos_dim,
			)
			if ok {
				total += u64(len(scores))
				delete(scores)
			}
		}
		state.sink = mm.black_box(total)
	}

	@(private)
	bench_metal_top_k :: proc(user: rawptr, chunk: int, _: int) {
		state := (^Accel_State)(user)
		top_k_loop(state, chunk, state.metal)
	}
}

@(private)
bench_cpu_cosine :: proc(user: rawptr, chunk: int, _: int) {
	state := (^Accel_State)(user)
	total := u64(0)
	for _ in 0 ..< chunk {
		scores, ok := state.cpu.cosine_query(
			state.cos_query,
			state.cos_docs,
			state.cos_docs_n,
			state.cos_dim,
		)
		if ok {
			total += u64(len(scores))
			delete(scores)
		}
	}
	state.sink = mm.black_box(total)
}

@(private)
bench_cpu_top_k :: proc(user: rawptr, chunk: int, _: int) {
	state := (^Accel_State)(user)
	top_k_loop(state, chunk, state.cpu)
}

// Scratch arena per call: top_k allocates per-hit maps and sort temporaries,
// which must not accumulate across the chunk.
@(private)
top_k_loop :: proc(state: ^Accel_State, chunk: int, s: accl.Strategy) {
	scratch: virtual.Arena
	if err := virtual.arena_init_growing(&scratch); err != nil {
		return
	}
	defer virtual.arena_destroy(&scratch)
	total := u64(0)
	for _ in 0 ..< chunk {
		virtual.arena_free_all(&scratch)
		hits, ok := accl.cosine_top_k(
			state.cos_query,
			state.cos_cands,
			8,
			virtual.arena_allocator(&scratch),
			s,
		)
		if ok {
			total += u64(len(hits))
		}
	}
	state.sink = mm.black_box(total)
}

register_accel_benches :: proc(runner: ^mm.Runner) {
	state := accel_state_init()
	compare := mm.group(runner, "accel/compare")
	mm.bench(compare, "membership_cpu_8k", state, bench_cpu_membership)
	mm.bench(compare, "cosine_cpu_2k_x64", state, bench_cpu_cosine)
	mm.bench(compare, "top_k_cpu_2k_x64", state, bench_cpu_top_k)
	when ODIN_OS == .Darwin {
		mm.bench(compare, "membership_metal_8k", state, bench_metal_membership)
		mm.bench(compare, "cosine_metal_2k_x64", state, bench_metal_cosine)
		mm.bench(compare, "top_k_metal_2k_x64", state, bench_metal_top_k)
	}
}
