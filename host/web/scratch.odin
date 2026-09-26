package web

import "core:mem/virtual"

// Calls `step(data)` until it returns false. Each call runs with a scratch
// arena as `context.temp_allocator`, emptied after the call, so a long-lived
// thread's temporaries never outlive one step. The arena is installed here, at
// the scope of the loop: a `context` assignment or `defer` inside an inner
// block would end with that block.
scratch_loop :: proc(step: proc(data: rawptr) -> bool, data: rawptr) {
	arena: virtual.Arena
	ok := virtual.arena_init_growing(&arena) == nil
	defer if ok {
		virtual.arena_destroy(&arena)
	}
	context.temp_allocator = virtual.arena_allocator(&arena) if ok else context.temp_allocator
	for step(data) {
		free_all(context.temp_allocator)
	}
}
