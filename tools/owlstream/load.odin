// OWL fact loading: stream triples into kernel asserts.
//
// The loader opens (or boots) a world, declares the bycycle relations as a
// filein unit, then streams owl:Class blocks: one kernel transaction per
// --commit-batch triples, each triple becoming one assertion. GUID subjects
// and GUID objects become named identities (#guid_<sanitized>); literals
// become strings. A GuidOf functional relation maps identity -> GUID string
// for audit; labels/comments live in Label/Comment/Alias functional
// relations. The inferencing rules live in ontology/*.mica fileins loaded
// separately (same store, same unit or another).
package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

import "core:mem/virtual"
import k "../../mica/kernel"
import r "../../mica/runtime"
import s "../../mica/store"
import v "../../mica/var"

// Relation names the loader asserts into. Declared by the bycycle ontology
// filein; the loader resolves ids against the live world after filein load.
Loader_Relations :: struct {
	isa:        k.Relation_ID,
	genls:      k.Relation_ID,
	disjoint:   k.Relation_ID,
	quoted_isa: k.Relation_ID,
	type_genls: k.Relation_ID,
	arg1_pred:  k.Relation_ID,
	rewrite_of: k.Relation_ID,
	broader:    k.Relation_ID,
	label:      k.Relation_ID,
	cycl:       k.Relation_ID,
	comment:    k.Relation_ID,
	alias:      k.Relation_ID,
	see_also:   k.Relation_ID,
	wiki_name:  k.Relation_ID,
	wiki_url:   k.Relation_ID,
	same_as:    k.Relation_ID,
	guid_of:    k.Relation_ID,
	// Durable resume checkpoint: functional key :resume -> "owl\npos\nsubjects".
	// Optional (old stores lack it); when present lets a rerun skip the scan
	// of every already-committed subject.
	loader_state: k.Relation_ID,
}

Loader_Stats :: struct {
	subjects:   int,
	triples:    int,
	asserted:   int,
	skipped:    int,
	commits:    int,
	identities: int,
	// Timing: wall seconds per phase, accumulated across batches.
	scan_seconds:    f64,
	assert_seconds:  f64,
	commit_seconds:  f64,
	checkpoint_seconds: f64,
	// Error counters (omica has no telemetry package; loader-local).
	err_assert:    int,
	err_commit:    int,
	err_identity:  int,
	err_checkpoint: int,
}

// sanitize_guid maps an OpenCyc GUID fragment to a Mica identity name.
// Dots and dashes are not ident chars (lexer.odin:485); map . and - to _.
// Prefix avoids collisions with ontology names and keeps the mapping
// invertible via GuidOf.
sanitize_guid :: proc(guid: string, allocator := context.allocator) -> string {
	prefix := "guid_"
	buf := make([dynamic]u8, 0, len(guid) + 5, allocator)
	for i in 0 ..< len(prefix) {
		append(&buf, prefix[i])
	}
	for i in 0 ..< len(guid) {
		ch := guid[i]
		if ch == '.' || ch == '-' {
			append(&buf, u8('_'))
		} else {
			append(&buf, ch)
		}
	}
	return string(buf[:])
}

// frag_of takes the fragment after the last # or / of a URI.
frag_of :: proc(uri: string) -> string {
	rest := uri
	if at := strings.last_index_byte(rest, '#'); at >= 0 {
		rest = rest[at + 1:]
	} else if at := strings.last_index_byte(rest, '/'); at >= 0 {
		rest = rest[at + 1:]
	}
	return rest
}

// is_guid reports whether a fragment looks like an OpenCyc GUID (long,
// mostly alnum with _ and -). Short fragments are predicates/labels.
is_guid :: proc(frag: string) -> bool {
	if len(frag) < 20 {
		return false
	}
	for ch in frag {
		if (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '_' || ch == '-' {
			continue
		}
		return false
	}
	return true
}

// Maps a child predicate tag to a loader relation field. Returns "" for
// tags we drop (owl:Restriction structure, versionInfo, datatypes).
predicate_relation :: proc(child_tag: string) -> string {
	switch child_tag {
	case RDF_TYPE:
		return "isa"
	case RDFS_SUBCLASS:
		return "genls"
	case OWL_DISJOINT:
		return "disjoint"
	case OWL_SAMEAS:
		return "same_as"
	case RDFS_LABEL:
		return "label"
	case CYCL_LABEL:
		return "cycl"
	case RDFS_COMMENT:
		return "comment"
	case GUID_PRETTY_STRING:
		return "alias"
	case GUID_QUOTED_ISA:
		return "quoted_isa"
	case GUID_TYPE_GENLS:
		return "type_genls"
	case GUID_REQUIRED_ARG1:
		return "arg1_pred"
	case GUID_REWRITE_OF:
		return "rewrite_of"
	case GUID_BROADER_TERM:
		return "broader"
	case GUID_SEE_ALSO:
		return "see_also"
	case GUID_WIKI_NAME:
		return "wiki_name"
	case GUID_WIKI_URL:
		return "wiki_url"
	}
	return ""
}

// Loads OWL facts into the world at store_path. The ontology fileins must
// already be loaded (or passed as extra filein paths via filein tool);
// this loader only asserts facts.
//
// Single pass: the world stays open for the whole run. The XML is scanned
// once, front to back; every commit_batch triples the pending queue is
// flushed in one kernel transaction and checkpointed, bounding memory to
// one batch. No rescan: the old per-batch world reopen (which re-walked
// all prior subjects to reach its offset, O(batches) rescans) is gone.
// A killed run still resumes: GuidOf row count gives the committed-subject
// offset, and one byte-scan lands there; set semantics dedupe overlap.
run_load :: proc(
	xml_text: string,
	store_path: string,
	owl_path: string,
	unit: string,
	limit: int,
	commit_batch: int,
	durability: s.Durability,
) {
	_ = unit
	stats: Loader_Stats

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	world, start := r.world_start(
		&kernel,
		nil,
		context.allocator,
		r.World_Config{store_path = store_path, durability = durability},
	)
	if !start.ok {
		fmt.eprintf("failed to open store: %s\n", start.message)
		os.exit(1)
	}
	defer r.world_destroy(world)

	rels, rels_ok := resolve_loader_relations(world)
	if !rels_ok {
		fmt.eprintf(
			"loader relations missing: load ontology/*.mica into the store first " +
			"(filein --store DIR --unit bycycle ontology/*.mica)\n",
		)
		os.exit(1)
	}

	identities := make(map[string]v.Value)
	defer delete(identities)
	next_identity := next_identity_seed(world)
	fmt.eprintf("  ... seeding done\n")

	// Batch arena: all pending tuples/strings allocate here and are freed
	// wholesale after each flush. transaction_assert deep-copies into the
	// tx arena synchronously, so nothing in pending outlives the flush.
	// (The old code used context.allocator per tuple: unbounded growth
	// across a 20k batch, then a crash on resume when the map held
	// kernel-borrowed strings. Both fixed here.)
	batch_arena: virtual.Arena
	if err := virtual.arena_init_growing(&batch_arena); err != nil {
		fmt.eprintf("arena init failed\n")
		os.exit(1)
	}
	defer virtual.arena_destroy(&batch_arena)
	batch_alloc := virtual.arena_allocator(&batch_arena)
	preseed_identities(world, &rels, &identities)

	pending: [dynamic]Pending_Assert
	defer delete(pending)

	flush := proc(
		kernel: ^k.Kernel,
		rels: ^Loader_Relations,
		pending: ^[dynamic]Pending_Assert,
		stats: ^Loader_Stats,
	) -> bool {
		if len(pending) == 0 {
			return true
		}
		t0 := time.tick_now()
		tx := k.kernel_begin(kernel)
		for p in pending {
			if err := k.transaction_assert(&tx, p.relation, p.tuple); err != .None {
				fmt.eprintf("assert failed: %v\n", err)
				stats.err_assert += 1
				k.transaction_destroy(&tx)
				return false
			}
			stats.asserted += 1
		}
		stats.assert_seconds += time.duration_seconds(time.tick_since(t0))
		t0 = time.tick_now()
		committed, commit_err := k.transaction_commit(&tx)
		k.transaction_destroy(&tx)
		stats.commit_seconds += time.duration_seconds(time.tick_since(t0))
		if commit_err != .None {
			fmt.eprintf("commit failed: %v\n", commit_err)
			stats.err_commit += 1
			return false
		}
		k.snapshot_release(committed)
		stats.commits += 1
		clear(pending)
		return true
	}

	// Frees everything the batch allocated (tuples, strings, names).
	// Called right after flush; transaction_assert already deep-copied
	// into the tx arena, so pending memory is dead here.
	reset_batch := proc(arena: ^virtual.Arena, pending: ^[dynamic]Pending_Assert, alloc: mem.Allocator) -> mem.Allocator {
		clear(pending)
		virtual.arena_free_all(arena)
		return virtual.arena_allocator(arena)
	}
	_ = reset_batch

	checkpoint_here := proc(world: ^r.World, stats: ^Loader_Stats) {
		t0 := time.tick_now()
		if !r.world_checkpoint(world) {
			stats.err_checkpoint += 1
			fmt.eprintf("checkpoint failed\n")
		}
		stats.checkpoint_seconds += time.duration_seconds(time.tick_since(t0))
	}

	// Resume position: durable in LoaderState (Mica store), not derived
	// from GuidOf row counting and not a re-scan over already-loaded
	// subjects. GuidOf rows still pre-seed the identity map (forward refs
	// from new subjects may point at old ones).
	scan_t0 := time.tick_now()
	pos := 0
	subjects_done := 0
	resume_pos, resume_subjects, has_resume := load_resume_state(world, &rels, owl_path)
	if has_resume {
		if resume_pos < len(xml_text) {
			pos = resume_pos
			subjects_done = resume_subjects
			stats.subjects = resume_subjects
			fmt.eprintf(
				"  resuming at byte %d/%d (%d subjects done)\n",
				pos,
				len(xml_text),
				subjects_done,
			)
		} else {
			fmt.eprintf("  resume pos out of range, starting fresh\n")
		}
	}
	triples_at_flush := 0
	for {
		if limit > 0 && subjects_done >= limit {
			break
		}
		open, is_subject, _ := scan_next_open(xml_text, pos)
		if open < 0 {
			break
		}
		pos = open
		if !is_subject {
			continue
		}
		// re-derive the head span to read rdf:about
		head_start := open
		for head_start > 0 && xml_text[head_start - 1] != '<' {
			head_start -= 1
		}
		head := xml_text[head_start:open]
		about, about_ok := attr_value(head, "rdf:about")
		if !about_ok || about == "" {
			stats.skipped += 1
			skip_subject(xml_text, &pos)
			continue
		}
		frag := frag_of(about)
		if frag == "" || !is_guid(frag) {
			// skips owl:Ontology, AnnotationProperty declarations, etc.
			stats.skipped += 1
			skip_subject(xml_text, &pos)
			continue
		}
		subj := intern_guid(
			world,
			&rels,
			&identities,
			&next_identity,
			&pending,
			&stats,
			frag,
			batch_alloc,
		)
		stats.subjects += 1
		subjects_done += 1
		scan_subject_children(
			xml_text,
			&pos,
			world,
			&rels,
			&identities,
			&next_identity,
			&pending,
			&stats,
			subj,
			frag,
			batch_alloc,
		)
		if stats.triples - triples_at_flush >= commit_batch {
			if !flush(&kernel, &rels, &pending, &stats) {
				os.exit(1)
			}
			triples_at_flush = stats.triples
			checkpoint_here(world, &stats)
			save_resume_state(world, &rels, owl_path, pos, subjects_done)
			batch_alloc = reset_batch(&batch_arena, &pending, batch_alloc)
			fmt.eprintf(
				"  ... %d subjects, %d triples asserted\n",
				stats.subjects,
				stats.asserted,
			)
		}
		if subjects_done % 20000 == 0 {
			fmt.eprintf(
				"  ... %d subjects, %d triples seen\n",
				stats.subjects,
				stats.triples,
			)
		}
	}
	flush(&kernel, &rels, &pending, &stats)
	batch_alloc = reset_batch(&batch_arena, &pending, batch_alloc)
	stats.scan_seconds += time.duration_seconds(time.tick_since(scan_t0))
	checkpoint_here(world, &stats)
	save_resume_state(world, &rels, owl_path, pos, subjects_done)

	print_timing_summary(&stats)

	fmt.printf(
		"done: %d subjects, %d triples, %d asserted, %d skipped, %d commits, %d identities\n",
		stats.subjects,
		stats.triples,
		stats.asserted,
		stats.skipped,
		stats.commits,
		stats.identities,
	)
}

// Prints the load timing curve: wall per phase plus derived rates. Called
// once at the end of run_load so a single pass reports the whole curve.
print_timing_summary :: proc(stats: ^Loader_Stats) {
	total := stats.scan_seconds + stats.assert_seconds + stats.commit_seconds + stats.checkpoint_seconds
	fmt.eprintf(
		"timing: scan %.1fs assert %.1fs commit %.1fs checkpoint %.1fs total %.1fs\n",
		stats.scan_seconds,
		stats.assert_seconds,
		stats.commit_seconds,
		stats.checkpoint_seconds,
		total,
	)
	if stats.subjects > 0 && total > 0 {
		fmt.eprintf(
			"curve: %d subjects %.1f subj/s, %d triples %.1f trip/s\n",
			stats.subjects,
			f64(stats.subjects) / total,
			stats.triples,
			f64(stats.triples) / total,
		)
	}
	fmt.eprintf(
		"errors: assert %d commit %d identity %d checkpoint %d\n",
		stats.err_assert,
		stats.err_commit,
		stats.err_identity,
		stats.err_checkpoint,
	)
}

Pending_Assert :: struct {
	relation: k.Relation_ID,
	tuple:    v.Tuple,
}

// Pre-seeds the identities map from GuidOf rows already committed: guid
// string -> identity value. A resumed run then reuses identities for
// re-encountered subjects instead of minting duplicates, and set semantics
// dedupe the re-asserted facts. Runs once at startup; the scan itself is
// still exactly one forward pass.
preseed_identities :: proc(
	world: ^r.World,
	rels: ^Loader_Relations,
	identities: ^map[string]v.Value,
) {
	rows: [dynamic]v.Tuple
	defer delete(rows)
	source := k.Relation_Source{snapshot = world.kernel.current}
	unbound := make([]v.Binding, 2, context.temp_allocator)
	k.relation_source_scan_into(&source, rels.guid_of, unbound, &rows)
	for row in rows {
		cells := v.tuple_values(row)
		if len(cells) < 2 {
			continue
		}
		id, id_ok := v.value_as_identity(cells[0])
		if !id_ok {
			continue
		}
		guid, guid_ok := v.value_as_string(cells[1])
		if !guid_ok {
			continue
		}
		// Clone into the map with a heap-stable key. NOTE: sanitize_guid
		// returns string(buf[:]) aliasing the dynamic buf — a second
		// sanitize call may reuse that backing. Clone the NAME too.
		key := strings.clone(guid, context.allocator)
		identities[key] = v.value_identity(id)
		// Register the sanitized name so #guid_X resolves in later evals
		// within this process too.
		name := strings.clone(sanitize_guid(key, context.allocator), context.allocator)
		world.ctx.identities[name] = v.value_identity(id)
	}
	if len(rows) > 0 {
		fmt.eprintf("  ... pre-seeded %d committed identities\n", len(identities))
	}
}

// Counts already-committed subjects by scanning GuidOf rows in the store.
// Opens the world read-only through the same boot path and closes it,
// releasing LOCK before the first batch.
committed_subject_count :: proc(store_path: string) -> int {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	world, start := r.world_start(
		&kernel,
		nil,
		context.allocator,
		r.World_Config{store_path = store_path},
	)
	if !start.ok {
		return 0
	}
	defer r.world_destroy(world)

	guid_id, found := world.ctx.relations["GuidOf"]
	if !found {
		return 0
	}
	rows: [dynamic]v.Tuple
	defer delete(rows)
	source := k.Relation_Source{snapshot = world.kernel.current}
	unbound := make([]v.Binding, 2, context.temp_allocator)
	k.relation_source_scan_into(&source, k.Relation_ID(guid_id), unbound, &rows)
	seen := make(map[v.Value]bool, len(rows), context.temp_allocator)
	for row in rows {
		cells := v.tuple_values(row)
		if len(cells) > 0 {
			seen[cells[0]] = true
		}
	}
	return len(seen)
}

// Skips from the current pos (just past a subject open tag) to just past its
// matching close tag.
skip_subject :: proc(xml_text: string, pos: ^int) {
	depth := 1
	for depth > 0 {
		copen, _, _ := scan_next_open(xml_text, pos^)
		cclose := scan_next_close(xml_text, pos^)
		if copen >= 0 && (cclose < 0 || copen < cclose) {
			pos^ = copen
			if is_self_closing(xml_text, copen) {
			} else {
				depth += 1
			}
		} else if cclose >= 0 {
			pos^ = cclose
			depth -= 1
		} else {
			return
		}
	}
}

// Interns a GUID fragment to a named identity, queueing the GuidOf audit
// fact. Reuses the map when seen before. Also records a NamedIdentity fact
// so the name resolves (#guid_X) after reboot and shows in fileout.
intern_guid :: proc(
	world: ^r.World,
	rels: ^Loader_Relations,
	identities: ^map[string]v.Value,
	next_identity: ^u64,
	pending: ^[dynamic]Pending_Assert,
	stats: ^Loader_Stats,
	guid: string,
	alloc: mem.Allocator,
) -> v.Value {
	if existing, found := identities[guid]; found {
		return existing
	}
	raw := next_identity^
	next_identity^ += 1
	identity, ok := v.value_identity_raw(raw)
	if !ok {
		fmt.eprintf("identity space exhausted at %d\n", raw)
		stats.err_identity += 1
		os.exit(1)
	}
	// sanitize_guid returns string(buf[:]) aliasing its dynamic buffer, so
	// clone the name: it lives in world.ctx.identities for the whole run
	// and must survive batch arena resets (and must not alias a buffer
	// that a later sanitize call reuses).
	name := strings.clone(sanitize_guid(guid, context.allocator), context.allocator)
	// Register the name so #guid_X resolves in later evals.
	world.ctx.identities[name] = identity
	// Clone: frag borrows xml_text (lives for the run, fine), but the map
	// key must be heap-stable across arena resets regardless.
	key := strings.clone(guid, context.allocator)
	identities[key] = identity
	stats.identities += 1
	append(pending, Pending_Assert {
		relation = rels.guid_of,
		tuple = v.tuple_new(alloc, []v.Value {
			identity,
			v.value_string(alloc, guid),
		}),
	})
	stats.triples += 1
	// NamedIdentity(identity, :guid_X) so world_boot resolves the name.
	named_identity_assert(world, pending, stats, identity, name)
	return identity
}

// Queues a NamedIdentity fact for a loader identity. The boot path resolves
// #name from these facts; without one the name dies with the process.
named_identity_assert :: proc(
	world: ^r.World,
	pending: ^[dynamic]Pending_Assert,
	stats: ^Loader_Stats,
	identity: v.Value,
	name: string,
) {
	tx := k.kernel_begin(world.kernel)
	err := k.transaction_assert(
		&tx,
		k.SYSTEM_NAMED_IDENTITY_ID,
		v.tuple_new(context.temp_allocator, []v.Value {
			identity,
			v.value_symbol(v.symbol_intern(name)),
		}),
	)
	if err != .None {
		k.transaction_destroy(&tx)
		return
	}
	committed, commit_err := k.transaction_commit(&tx)
	k.transaction_destroy(&tx)
	if commit_err != .None {
		return
	}
	k.snapshot_release(committed)
	stats.triples += 1
}

// Reads the world for the highest stored identity so fresh loader ids do not
// collide. Falls back to the filein start 0x1000. Uses full-width bindings:
// relation_source_visit requires arity-matched bindings.
next_identity_seed :: proc(world: ^r.World) -> u64 {
	highest := u64(0x1000)
	rows: [dynamic]v.Tuple
	defer delete(rows)
	source := k.Relation_Source{snapshot = world.kernel.current}
	unbound := make([]v.Binding, 2, context.temp_allocator)
	k.relation_source_scan_into(&source, k.SYSTEM_NAMED_IDENTITY_ID, unbound, &rows)
	for row in rows {
		cells := v.tuple_values(row)
		if len(cells) < 1 {
			continue
		}
		if id, ok := v.value_as_identity(cells[0]); ok {
			if u64(id) >= highest {
				highest = u64(id) + 1
			}
		}
	}
	return highest
}

// Resolves the loader's relation names against the live world. All must
// exist (ontology fileins load first).
resolve_loader_relations :: proc(world: ^r.World) -> (Loader_Relations, bool) {
	rels: Loader_Relations
	look :: proc(world: ^r.World, name: string) -> (k.Relation_ID, bool) {
		id, found := world.ctx.relations[name]
		if !found {
			return 0, false
		}
		return k.Relation_ID(id), true
	}
	ok := true
	rels.isa, ok = look(world, "Isa"); if !ok { return rels, false }
	rels.genls, ok = look(world, "Genls"); if !ok { return rels, false }
	rels.disjoint, ok = look(world, "DisjointWith"); if !ok { return rels, false }
	rels.quoted_isa, ok = look(world, "QuotedIsa"); if !ok { return rels, false }
	rels.type_genls, ok = look(world, "TypeGenls"); if !ok { return rels, false }
	rels.arg1_pred, ok = look(world, "Arg1Pred"); if !ok { return rels, false }
	rels.rewrite_of, ok = look(world, "RewriteOf"); if !ok { return rels, false }
	rels.broader, ok = look(world, "BroaderTerm"); if !ok { return rels, false }
	rels.label, ok = look(world, "Label"); if !ok { return rels, false }
	rels.cycl, ok = look(world, "CycLabel"); if !ok { return rels, false }
	rels.comment, ok = look(world, "Comment"); if !ok { return rels, false }
	rels.alias, ok = look(world, "Alias"); if !ok { return rels, false }
	rels.see_also, ok = look(world, "SeeAlso"); if !ok { return rels, false }
	rels.wiki_name, ok = look(world, "WikiName"); if !ok { return rels, false }
	rels.wiki_url, ok = look(world, "WikiURL"); if !ok { return rels, false }
	rels.same_as, ok = look(world, "SameAs"); if !ok { return rels, false }
	rels.guid_of, ok = look(world, "GuidOf"); if !ok { return rels, false }
	// Optional: old stores predate this relation. Without it the loader
	// degrades to the full-from-scratch scan (no durable resume point).
	if id, found := look(world, "LoaderState"); found {
		rels.loader_state = id
	}
	return rels, true
}

// Reads the durable resume point from LoaderState(:resume) if present.
// Returns the byte offset to continue from and the subject count already
// committed, plus whether a valid point exists AND the stored owl path
// matches the file this run is loading.
load_resume_state :: proc(
	world: ^r.World,
	rels: ^Loader_Relations,
	owl_path: string,
) -> (
	resume_pos: int,
	resume_subjects: int,
	ok: bool,
) {
	if rels.loader_state == 0 {
		return 0, 0, false
	}
	rows: [dynamic]v.Tuple
	defer delete(rows)
	source := k.Relation_Source{snapshot = world.kernel.current}
	unbound := make([]v.Binding, 2, context.temp_allocator)
	k.relation_source_scan_into(&source, rels.loader_state, unbound, &rows)
	for row in rows {
		cells := v.tuple_values(row)
		if len(cells) < 2 {
			continue
		}
		key, key_ok := v.value_as_symbol(cells[0])
		if !key_ok {
			continue
		}
		kname, has_name := v.symbol_name(key)
		if !has_name || kname != "resume" {
			continue
		}
		val, val_ok := v.value_as_string(cells[1])
		if !val_ok {
			return 0, 0, false
		}
		// Format: "owl_path\npos\nsubjects"
		parts := strings.split(val, "\n", context.temp_allocator)
		if len(parts) != 3 {
			return 0, 0, false
		}
		if parts[0] != owl_path {
			return 0, 0, false
		}
		pos := 0
		subj := 0
		pos_ok := false
		subj_ok := false
		pos, pos_ok = strconv.parse_int(parts[1])
		subj, subj_ok = strconv.parse_int(parts[2])
		if !pos_ok || !subj_ok || pos < 0 {
			return 0, 0, false
		}
		return pos, subj, true
	}
	return 0, 0, false
}

// Writes (or replaces) the durable resume point. Called after each
// checkpoint so a crash before the next checkpoint still resumes from
// this position; the retried batch is idempotent under set semantics.
save_resume_state :: proc(
	world: ^r.World,
	rels: ^Loader_Relations,
	owl_path: string,
	pos: int,
	subjects: int,
) {
	if rels.loader_state == 0 {
		return
	}
	val := fmt.aprintf("%s\n%d\n%d", owl_path, pos, subjects, allocator = context.allocator)
	defer delete(val, context.allocator)
	key := v.value_symbol(v.symbol_intern("resume"))

	tx := k.kernel_begin(world.kernel)
	// Retract any existing :resume tuple, then assert the new one.
	existing: [dynamic]v.Tuple
	defer delete(existing)
	unbound := make([]v.Binding, 2, context.temp_allocator)
	unbound[0] = v.binding_of(key)
	source := k.Relation_Source{transaction = &tx}
	k.relation_source_scan_into(&source, rels.loader_state, unbound, &existing)
	for row in existing {
		k.transaction_retract(&tx, rels.loader_state, row)
	}
	if err := k.transaction_assert(
		&tx,
		rels.loader_state,
		v.tuple_new(context.temp_allocator, []v.Value {
			key,
			v.value_string(context.temp_allocator, val),
		}),
	); err != .None {
		k.transaction_destroy(&tx)
		return
	}
	committed, commit_err := k.transaction_commit(&tx)
	k.transaction_destroy(&tx)
	if commit_err == .None {
		k.snapshot_release(committed)
	}
}

// Scans one subject's children, queueing one assertion per triple. Advances
// *pos past the subject's close tag.
scan_subject_children :: proc(
	xml_text: string,
	pos: ^int,
	world: ^r.World,
	rels: ^Loader_Relations,
	identities: ^map[string]v.Value,
	next_identity: ^u64,
	pending: ^[dynamic]Pending_Assert,
	stats: ^Loader_Stats,
	subj: v.Value,
	subj_guid: string,
	alloc: mem.Allocator,
) {
	depth := 1
	guard := 0
	for depth > 0 {
		guard += 1
		if guard > 1000000 {
			fmt.eprintf("scan_subject_children: runaway depth, bailing at pos %d\n", pos^)
			return
		}
		copen, _, ctag := scan_next_open(xml_text, pos^)
		cclose := scan_next_close(xml_text, pos^)
		if copen >= 0 && (cclose < 0 || copen < cclose) {
			// child element: parse its head, literal or resource, then skip
			head_start := copen
			for head_start > 0 && xml_text[head_start - 1] != '<' {
				head_start -= 1
			}
			head := xml_text[head_start:copen]
			self_close := is_self_closing(xml_text, copen)
			resource, has_resource := attr_value(head, "rdf:resource")
			field := predicate_relation(ctag)
			if field != "" {
				literal := ""
				if !has_resource && !self_close {
					// literal text runs to the matching close
					inner_start := copen
					inner_end := scan_next_close(xml_text, copen)
					if inner_end >= 0 {
						// back up to '<' of the close
						lt := inner_end
						for lt > inner_start && xml_text[lt - 1] != '<' {
							lt -= 1
						}
						literal = strings.trim_space(xml_text[inner_start:lt - 1])
					}
				}
				queue_triple(
					world,
					rels,
					identities,
					next_identity,
					pending,
					stats,
					subj,
					field,
					literal,
					resource,
					has_resource,
					alloc,
				)
			}
			pos^ = copen
			if self_close {
				// no depth change; skip nothing further
				// advance past children scan of empty element
				skip_shallow(xml_text, pos)
			} else {
				depth += 1
			}
		} else if cclose >= 0 {
			pos^ = cclose
			depth -= 1
		} else {
			return
		}
	}
}

// Advances pos past any nested content at the current level without
// interpreting it (used after handling a child element's own triple).
skip_shallow :: proc(_: string, _: ^int) {
}

// Queues one assertion for a triple. Resource objects that are GUIDs become
// identities (interned); absolute URIs only survive on same_as (kept as
// strings); literals are entity-decoded strings.
queue_triple :: proc(
	world: ^r.World,
	rels: ^Loader_Relations,
	identities: ^map[string]v.Value,
	next_identity: ^u64,
	pending: ^[dynamic]Pending_Assert,
	stats: ^Loader_Stats,
	subj: v.Value,
	field: string,
	literal: string,
	resource: string,
	has_resource: bool,
	alloc: mem.Allocator,
) {
	rel: k.Relation_ID
	switch field {
	case "isa":
		rel = rels.isa
	case "genls":
		rel = rels.genls
	case "disjoint":
		rel = rels.disjoint
	case "quoted_isa":
		rel = rels.quoted_isa
	case "type_genls":
		rel = rels.type_genls
	case "arg1_pred":
		rel = rels.arg1_pred
	case "rewrite_of":
		rel = rels.rewrite_of
	case "broader":
		rel = rels.broader
	case "label":
		rel = rels.label
	case "cycl":
		rel = rels.cycl
	case "comment":
		rel = rels.comment
	case "alias":
		rel = rels.alias
	case "see_also":
		rel = rels.see_also
	case "wiki_name":
		rel = rels.wiki_name
	case "wiki_url":
		rel = rels.wiki_url
	case "same_as":
		rel = rels.same_as
	case:
		return
	}
	if has_resource {
		frag := frag_of(resource)
		if is_guid(frag) {
			obj := intern_guid(world, rels, identities, next_identity, pending, stats, frag, alloc)
			append(pending, Pending_Assert {
				relation = rel,
				tuple = v.tuple_new(alloc, []v.Value{subj, obj}),
			})
			stats.triples += 1
		} else if field == "same_as" && resource != "" {
			append(pending, Pending_Assert {
				relation = rel,
				tuple = v.tuple_new(alloc, []v.Value {
					subj,
					v.value_string(alloc, resource),
				}),
			})
			stats.triples += 1
		} else {
			stats.skipped += 1
		}
		return
	}
	text := decode_entities(strings.trim_space(literal), alloc)
	defer delete(text, alloc)
	if text == "" {
		stats.skipped += 1
		return
	}
	// Functional single-valued relations (Label/CycLabel/Comment) keep the
	// first value; the kernel enforces the key, so later duplicates fail.
	// Route repeats to Alias instead of erroring the batch.
	if (field == "label" || field == "cycl" || field == "comment") {
		if seen_label(world, rels, field, subj) {
			append(pending, Pending_Assert {
				relation = rels.alias,
				tuple = v.tuple_new(alloc, []v.Value {
					subj,
					v.value_string(alloc, text),
				}),
			})
			stats.triples += 1
			return
		}
		mark_label(world, field, subj)
	}
	append(pending, Pending_Assert {
		relation = rel,
		tuple = v.tuple_new(alloc, []v.Value{subj, v.value_string(alloc, text)}),
	})
	stats.triples += 1
}

// First-label-wins bookkeeping for functional Label/CycLabel/Comment.
// Keyed by identity raw word (stable across reboots), NOT v.Value: Value
// is a 64-bit word so it works as a key today, but the map must survive
// preseed-vs-fresh identity reuse without hashing heap payloads. On a
// resumed run the kernel already holds first labels; the loader-local map
// starts empty, so first-seen-this-run duplicates route to Alias while
// kernel set semantics dedupe exact repeats.
@(private)
label_seen: map[u64]map[string]bool

seen_label :: proc(_: ^r.World, _: ^Loader_Relations, field: string, subj: v.Value) -> bool {
	if label_seen == nil {
		return false
	}
	id, ok := v.value_as_identity(subj)
	if !ok {
		return false
	}
	fields, found := label_seen[u64(id)]
	if !found {
		return false
	}
	return fields[field]
}

mark_label :: proc(_: ^r.World, field: string, subj: v.Value) {
	id, ok := v.value_as_identity(subj)
	if !ok {
		return
	}
	if label_seen == nil {
		label_seen = make(map[u64]map[string]bool)
	}
	fields, found := label_seen[u64(id)]
	if !found {
		fields = make(map[string]bool)
		label_seen[u64(id)] = fields
	}
	fields[field] = true
}
