package web

import "core:mem/virtual"
import "core:testing"

@(private = "file")
Scratch_Probe :: struct {
	steps: int,
	arena: [3]bool, // the step's temp allocator was an arena
	empty: [3]bool, // and nothing was allocated in it yet
}

@(private = "file")
scratch_probe_step :: proc(data: rawptr) -> bool {
	probe := (^Scratch_Probe)(data)
	is_arena := context.temp_allocator.procedure == virtual.arena_allocator_proc
	probe.arena[probe.steps] = is_arena
	probe.empty[probe.steps] = is_arena && (^virtual.Arena)(context.temp_allocator.data).total_used == 0
	// Scratch the next step must not see.
	_ = make([]u8, 1024, context.temp_allocator)
	probe.steps += 1
	return probe.steps < len(probe.arena)
}

// A long-lived loop runs every step in an arena emptied after the step before.
@(test)
test_scratch_loop_resets_arena_between_steps :: proc(t: ^testing.T) {
	probe: Scratch_Probe
	scratch_loop(scratch_probe_step, &probe)
	testing.expect_value(t, probe.steps, 3)
	for i in 0 ..< 3 {
		testing.expectf(t, probe.arena[i], "step %d: temp allocator is not an arena", i)
		testing.expectf(t, probe.empty[i], "step %d: temp arena already held data", i)
	}
}
