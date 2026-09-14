// Microbenchmark driver for the mica-odin data core.
//
// Usage:
//
//	odin run benchmarks -o:speed
//	odin run benchmarks -o:speed -- -suite=var -filter=string
//	odin run benchmarks -o:speed -- -save=baseline.tsv
//	odin run benchmarks -o:speed -- -baseline=baseline.tsv
package main

import "core:fmt"
import "core:os"
import "core:strings"

import mm "../micromeasure"

Args :: struct {
	config:   mm.Config,
	filter:   string,
	suite:    string,
	save:     string,
	baseline: string,
}

main :: proc() {
	args := parse_args()
	runner: mm.Runner
	mm.runner_init(&runner, args.config)
	defer mm.runner_destroy(&runner)

	switch args.suite {
	case "var":
		register_var_benches(&runner)
	case "kernel":
		register_kernel_benches(&runner)
	case "tasks":
		register_task_benches(&runner)
	case "accel":
		register_accel_benches(&runner)
	case "all":
		register_var_benches(&runner)
		register_kernel_benches(&runner)
		register_task_benches(&runner)
		register_accel_benches(&runner)
	case:
		fmt.eprintf("unknown suite: %s (use all, var, kernel, tasks, or accel)\n", args.suite)
		os.exit(1)
	}
	runner.filter = args.filter

	if args.filter != "" {
		fmt.eprintf("running benchmarks matching filter: %q\n", args.filter)
	}

	ran := mm.runner_run(&runner)
	if ran == 0 {
		fmt.eprintln("no benchmarks matched")
		os.exit(1)
	}

	baseline: map[string]f64
	if args.baseline != "" {
		baseline = mm.load_baseline(args.baseline)
		if baseline == nil {
			fmt.eprintf("could not read baseline: %s\n", args.baseline)
		}
	}
	mm.report(&runner, baseline)

	if args.save != "" {
		if mm.save_report(args.save, &runner) {
			fmt.printf("results saved to %s\n", args.save)
		} else {
			fmt.eprintf("could not save results to %s\n", args.save)
		}
	}
}

@(private)
parse_args :: proc() -> Args {
	args := Args {
		config = mm.DEFAULT_CONFIG,
		suite  = "all",
	}
	for raw in os.args[1:] {
		arg := raw
		switch {
		case strings.has_prefix(arg, "-filter="):
			args.filter = arg[len("-filter="):]
		case strings.has_prefix(arg, "-suite="):
			args.suite = arg[len("-suite="):]
		case strings.has_prefix(arg, "-save="):
			args.save = arg[len("-save="):]
		case strings.has_prefix(arg, "-baseline="):
			args.baseline = arg[len("-baseline="):]
		case arg == "-quick":
			args.config = mm.QUICK_CONFIG
		case !strings.has_prefix(arg, "-"):
			args.filter = arg
		}
	}
	return args
}
