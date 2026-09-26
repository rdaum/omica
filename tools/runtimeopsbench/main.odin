// Fixed-count measurements for operations unavailable in the pre-fix runtime.
package main

import k "../../mica/kernel"
import r "../../mica/runtime"
import v "../../mica/var"
import "core:fmt"
import "core:os"
import "core:time"

main :: proc() {
	if len(os.args) !=
	   2 {fmt.eprintln("usage: runtimeopsbench identities|installation|replacement|cross_program"); os.exit(2)}
	selected := os.args[1]
	expected := i64(0)
	switch selected {
	case "identities":
		expected = 100
	case "installation", "replacement":
		expected = 20
	case "cross_program":
		expected = 2000
	case:
		os.exit(2)
	}
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, loaded := r.world_start(
		&kernel,
		[]string{"benchmarks/mica/runtime_new_operations.mica"},
		context.allocator,
		r.World_Config{workers = 1},
	)
	if !loaded.ok {fmt.eprintln(loaded.message); os.exit(1)}
	defer r.world_destroy(world)
	if r.world_wait(world, world.entry).kind != .Complete {os.exit(1)}
	if selected == "cross_program" {
		installed := r.world_eval(world, `install_source("verb foreign(x)\n return x + 1\nend")`)
		if installed.kind != .Complete {fmt.eprintln(installed.message); os.exit(1)}
	}
	start := time.tick_now()
	outcome := r.world_call(world, selected, nil)
	elapsed := time.tick_diff(start, time.tick_now())
	result, integer := v.value_as_int(outcome.value)
	if outcome.kind != .Complete || !integer || result != expected {
		fmt.eprintln("invalid benchmark result", outcome.message, v.value_to_string(outcome.error))
		os.exit(1)
	}
	fmt.printf("%s\t%d\t%d\t%d\n", selected, i64(elapsed), expected, len(world.programs.serials))
}
