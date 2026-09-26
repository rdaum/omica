// Runs Mica fileins against an in-memory or stored world.
//
// Usage:
//
//	odin run tools/filein -- apps/shared/capabilities.mica
//	odin run tools/filein -- --unit equipment apps/examples/equipment-service.mica
//	odin run tools/filein -- --store /tmp/world --eval 'return ReadyForUse(#sensor_17)'
package main

import "core:fmt"
import "core:os"

import sourcelib "../../host/source"
import ext "../../mica/external"
import k "../../mica/kernel"
import r "../../mica/runtime"
import s "../../mica/store"
import v "../../mica/var"

@(private)
USAGE :: "usage: filein [--unit NAME] [--store DIR] [--durability none|group|strict] " +
	"[--accel " + r.ACCEL_MODE_NAMES + "] " +
	"[--actor NAME] [--checkpoint] [--eval SOURCE]... <path>...\n" +
	"       filein --store DIR --unlock [--force]\n" +
	"  --unlock: remove DIR's lock when its recorded owner is no longer running;\n" +
	"            --force also removes a lock with no owner or one from another host\n"

// Removes a store's stale lock and reports what happened; the exit status is 0
// when the store is no longer locked.
@(private)
unlock_store :: proc(path: string, force: bool) -> int {
	owner, known := s.lock_read_owner(path)
	switch s.store_unlock(path, force) {
	case .Not_Locked:
		fmt.printf("%s is not locked\n", path)
		return 0
	case .Removed:
		if known {
			fmt.printf("removed %s's lock (pid %d on %s)\n", path, owner.pid, owner.host)
		} else {
			fmt.printf("removed %s's lock\n", path)
		}
		return 0
	case .Owner_Running:
		fmt.eprintf("%s is locked by pid %d, which is still running; not removing its lock\n", path, owner.pid)
	case .Owner_Elsewhere:
		fmt.eprintf("%s is locked by pid %d on host %s, which cannot be checked from here; use --force if it is gone\n", path, owner.pid, owner.host)
	case .Owner_Unknown:
		fmt.eprintf("%s's lock records no owner (an older version wrote it); use --force if nothing is using the store\n", path)
	}
	return 1
}

@(private)
parse_durability :: proc(text: string) -> s.Durability {
	switch text {
	case "none":
		return .None
	case "strict":
		return .Strict
	}
	return .Group
}

@(private)
print_outcome :: proc(world: ^r.World, outcome: r.Task_Outcome) -> bool {
	switch outcome.kind {
	case .Complete:
		text := r.world_value_literal(world, outcome.value)
		defer delete(text, context.allocator)
		fmt.printf("%s\n", text)
		return true
	case .Aborted:
		detail := outcome.message
		if header, is_error := v.value_as_error(outcome.error); is_error {
			code, _ := v.symbol_name(header.code)
			if header.has_message && header.message != "" {
				detail = fmt.aprintf(
					"%s: %s",
					code,
					header.message,
					allocator = context.temp_allocator,
				)
			} else if code != "" {
				detail = code
			}
		}
		fmt.eprintf("aborted: %s\n", detail)
		return false
	case .Pending:
		fmt.eprintf("aborted: task did not finish (%s)\n", outcome.message)
		return false
	}
	return false
}

main :: proc() {
	unit := ""
	store_path := ""
	actor := ""
	checkpoint := false
	unlock, force := false, false
	durability := s.Durability.Group
	accel_mode := r.Accel_Mode.Unchanged
	evals: [dynamic]string
	defer delete(evals)
	paths: [dynamic]string
	defer delete(paths)

	arguments := os.args[1:]
	for index := 0; index < len(arguments); index += 1 {
		switch arguments[index] {
		case "--unit":
			if index + 1 >= len(arguments) {
				fmt.eprintf(USAGE)
				os.exit(1)
			}
			index += 1
			unit = arguments[index]
		case "--store":
			if index + 1 >= len(arguments) {
				fmt.eprintf(USAGE)
				os.exit(1)
			}
			index += 1
			store_path = arguments[index]
		case "--durability":
			if index + 1 >= len(arguments) {
				fmt.eprintf(USAGE)
				os.exit(1)
			}
			index += 1
			durability = parse_durability(arguments[index])
		case "--actor":
			if index + 1 >= len(arguments) {
				fmt.eprintf(USAGE)
				os.exit(1)
			}
			index += 1
			actor = arguments[index]
		case "--eval":
			if index + 1 >= len(arguments) {
				fmt.eprintf(USAGE)
				os.exit(1)
			}
			index += 1
			append(&evals, arguments[index])
		case "--accel":
			if index + 1 >= len(arguments) {
				fmt.eprintf(USAGE)
				os.exit(1)
			}
			index += 1
			mode, ok := r.accel_mode_parse(arguments[index])
			if !ok {
				fmt.eprintf("--accel: expected %s, got %q\n%s", r.ACCEL_MODE_NAMES, arguments[index], USAGE)
				os.exit(1)
			}
			accel_mode = mode
		case "--checkpoint":
			checkpoint = true
		case "--unlock":
			unlock = true
		case "--force":
			force = true
		case "--help", "-h":
			fmt.printf(USAGE)
			return
		case:
			append(&paths, arguments[index])
		}
	}
	if unlock {
		if store_path == "" {
			fmt.eprintf(USAGE)
			os.exit(1)
		}
		os.exit(unlock_store(store_path, force))
	}
	if len(paths) == 0 && store_path == "" && len(evals) == 0 {
		fmt.eprintf(USAGE)
		os.exit(1)
	}

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	world, start := r.world_start(
		&kernel,
		paths[:],
		context.allocator,
		r.World_Config {
			actor            = actor,
			unit             = unit,
			store_path       = store_path,
			durability       = durability,
			external_handler = ext.handle_request,
			external_workers = 2,
			accel            = accel_mode,
		},
	)
	if !start.ok {
		fmt.eprintf("failed: %s\n", start.message)
		os.exit(1)
	}
	// A store that already holds a world boots from it and ignores the given
	// files. Say so and fail, rather than report a file as loaded that never ran.
	if world.booted && len(paths) > 0 {
		for path in paths {
			fmt.eprintf(
				"failed: %s was not loaded: the store at %s already holds a world, which boots from the store and ignores new fileins\n",
				path,
				store_path,
			)
		}
		r.world_destroy(world)
		os.exit(1)
	}
	ok := true
	if world.entry != 0 {
		outcome := r.world_wait(world, world.entry)
		if outcome.kind != .Complete {
			ok = print_outcome(world, outcome)
		}
	}
	if indexed, attempted := sourcelib.index_from_env(world); attempted {
		if indexed.ok {
			fmt.printf(
				"indexed %d files (%d directories, %d skipped)\n",
				indexed.files,
				indexed.directories,
				indexed.skipped,
			)
		} else {
			fmt.eprintf("source index skipped: %s\n", indexed.message)
		}
	}
	for source in evals {
		if !print_outcome(world, r.world_eval(world, source)) {
			ok = false
		}
	}
	if checkpoint && !r.world_checkpoint(world) {
		fmt.eprintf("failed: checkpoint failed\n")
		ok = false
	}
	r.world_destroy(world)
	if ok {
		for path in paths {
			fmt.printf("loaded %s\n", path)
		}
	} else {
		os.exit(1)
	}
}
