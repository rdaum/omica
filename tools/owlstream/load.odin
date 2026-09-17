// OWL fact loading: stream triples into kernel asserts.
//
// The loader opens (or boots) a world whose bycycle relations were declared
// by the apps/bycycle fileins, then streams owl:Class blocks: one kernel
// transaction per --commit-batch queued facts, each triple becoming one
// assertion. GUID subjects and GUID objects become named identities
// (#guid_<sanitized>); literals become strings. A GuidOf functional relation
// maps identity -> GUID string for audit; labels/comments live in
// Label/Comment/Alias functional relations. The inferencing rules live in the
// apps/bycycle fileins.
package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

import "core:mem/virtual"
import dom "../../mica/dom"
import k "../../mica/kernel"
import r "../../mica/runtime"
import s "../../mica/store"
import v "../../mica/var"

// Every relation the loader writes. The first block maps one-to-one onto OWL
// predicates (see predicate_field); the rest are loader-internal.
Field :: enum {
	None,
	Isa,
	Genls,
	Disjoint,
	Quoted_Isa,
	Type_Genls,
	Arg1_Pred,
	Rewrite_Of,
	Broader,
	Label,
	Cycl,
	Comment,
	Alias,
	See_Also,
	Wiki_Name,
	Wiki_URL,
	Same_As,
	// Audit: identity -> source GUID string.
	Guid_Of,
	// Durable resume checkpoint: functional key :resume -> "owl\npos\nsubjects".
	// Optional (old stores lack it); without it a rerun starts from scratch.
	Loader_State,
	// Retrieval gate read by apps/shared/retrieval.mica. Optional; required
	// only when --retrieval-actor is given.
	Can_Retrieve,
}

// Relation names as declared by the bycycle ontology filein.
FIELD_RELATION_NAMES :: [Field]string {
	.None         = "",
	.Isa          = "Isa",
	.Genls        = "Genls",
	.Disjoint     = "DisjointWith",
	.Quoted_Isa   = "QuotedIsa",
	.Type_Genls   = "TypeGenls",
	.Arg1_Pred    = "Arg1Pred",
	.Rewrite_Of   = "RewriteOf",
	.Broader      = "BroaderTerm",
	.Label        = "Label",
	.Cycl         = "CycLabel",
	.Comment      = "Comment",
	.Alias        = "Alias",
	.See_Also     = "SeeAlso",
	.Wiki_Name    = "WikiName",
	.Wiki_URL     = "WikiURL",
	.Same_As      = "SameAs",
	.Guid_Of      = "GuidOf",
	.Loader_State = "LoaderState",
	.Can_Retrieve = "CanRetrieveSubject",
}

OPTIONAL_FIELDS :: bit_set[Field]{.None, .Loader_State, .Can_Retrieve}

// Functional single-valued relations: the kernel enforces the key, so a
// second value for the same subject would fail the batch. Repeats route to
// Alias (see queue_triple).
FIRST_WINS_FIELDS :: bit_set[Field]{.Label, .Cycl, .Comment}

// Relation ids resolved against the live world after filein load; 0 for an
// optional relation the store lacks.
Loader_Relations :: [Field]k.Relation_ID

Loader_Stats :: struct {
	subjects:   int,
	// OWL triples queued. Loader-internal rows (GuidOf, NamedIdentity,
	// CanRetrieveSubject) count under internal instead.
	triples:    int,
	internal:   int,
	asserted:   int,
	// Input intentionally not loaded: non-GUID subjects (owl:Ontology,
	// property declarations) and empty literals.
	skipped:    int,
	// Resource objects discarded because their fragment is not a GUID (see
	// is_guid). Counted apart from skipped: this is data loss, not policy.
	dropped_resources: int,
	// Every kernel commit: batch flushes and resume-state writes.
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

Pending_Assert :: struct {
	relation: k.Relation_ID,
	tuple:    v.Tuple,
}

// Everything the per-triple path needs, so the scan procs take one pointer
// instead of nine.
Loader :: struct {
	world:         ^r.World,
	rels:          Loader_Relations,
	identities:    map[string]v.Value,
	next_identity: u64,
	pending:       [dynamic]Pending_Assert,
	stats:         Loader_Stats,
	// Batch arena: all pending tuples/strings allocate here and are freed
	// wholesale after each flush. transaction_assert deep-copies into the
	// tx arena synchronously, so nothing in pending outlives the flush.
	// pending's own backing array is on context.allocator so its capacity is
	// reused across batches.
	batch_arena: virtual.Arena,
	batch_alloc: mem.Allocator,
	// First-label-wins bookkeeping for FIRST_WINS_FIELDS, keyed by identity
	// raw word (stable across reboots). On a resumed run the kernel already
	// holds first labels while this map starts empty, so first-seen-this-run
	// duplicates route to Alias and kernel set semantics dedupe exact repeats.
	label_seen: map[u64]bit_set[Field],
}

// sanitize_guid maps an OpenCyc GUID fragment to a Mica identity name.
// Dots and dashes are not ident chars (lexer.odin:485); map . and - to _.
// Prefix avoids collisions with ontology names and keeps the mapping
// invertible via GuidOf. The result is a fresh allocation owned by the caller.
sanitize_guid :: proc(guid: string, allocator := context.allocator) -> string {
	prefix := "guid_"
	buf := make([]u8, len(prefix) + len(guid), allocator)
	copy(buf, prefix)
	for i in 0 ..< len(guid) {
		ch := guid[i]
		buf[len(prefix) + i] = (ch == '.' || ch == '-') ? '_' : ch
	}
	return string(buf)
}

// frag_of takes the fragment after the last # or / of a URI.
frag_of :: proc(uri: string) -> string {
	if at := strings.last_index_byte(uri, '#'); at >= 0 {
		return uri[at + 1:]
	}
	if at := strings.last_index_byte(uri, '/'); at >= 0 {
		return uri[at + 1:]
	}
	return uri
}

// is_guid reports whether a fragment looks like an OpenCyc GUID: at least 20
// chars of alnum, _ and -. OpenCyc GUID fragments are 26 chars ("Mx4r..."),
// so the cutoff separates them from vocabulary fragments such as "Class".
// Any other resource with a short fragment (a hand-written ".../Dog") is not
// loaded: as a subject it counts under skipped, as an object under
// dropped_resources.
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

// Maps a child predicate tag to the relation it loads into. Returns .None for
// tags we drop (owl:Restriction structure, versionInfo, datatypes).
predicate_field :: proc(child_tag: string) -> Field {
	switch child_tag {
	case RDF_TYPE:
		return .Isa
	case RDFS_SUBCLASS:
		return .Genls
	case OWL_DISJOINT:
		return .Disjoint
	case OWL_SAMEAS:
		return .Same_As
	case RDFS_LABEL:
		return .Label
	case CYCL_LABEL:
		return .Cycl
	case RDFS_COMMENT:
		return .Comment
	case GUID_PRETTY_STRING:
		return .Alias
	case GUID_QUOTED_ISA:
		return .Quoted_Isa
	case GUID_TYPE_GENLS:
		return .Type_Genls
	case GUID_REQUIRED_ARG1:
		return .Arg1_Pred
	case GUID_REWRITE_OF:
		return .Rewrite_Of
	case GUID_BROADER_TERM:
		return .Broader
	case GUID_SEE_ALSO:
		return .See_Also
	case GUID_WIKI_NAME:
		return .Wiki_Name
	case GUID_WIKI_URL:
		return .Wiki_URL
	}
	return .None
}

// Loads OWL facts into the world at store_path. The ontology fileins must
// already be loaded (scripts/bycycle-load.sh init); this loader only asserts
// facts.
//
// Single pass: the world stays open for the whole run and the XML is scanned
// once, front to back. Every fact the loader produces, including the GuidOf
// and NamedIdentity rows for new identities, is queued in pending; once
// pending holds commit_batch rows it is flushed in one kernel transaction, so
// the rule fixpoint is recomputed once per batch rather than once per
// identity. After each flush the scan position is saved to LoaderState and,
// with checkpoint set, the store is checkpointed. A killed run resumes from
// LoaderState; set semantics dedupe the replayed tail. When retrieval_actor
// is non-empty every subject also gets CanRetrieveSubject(actor, subject).
run_load :: proc(
	xml_text: string,
	store_path: string,
	owl_path: string,
	limit: int,
	commit_batch: int,
	durability: s.Durability,
	checkpoint: bool,
	retrieval_actor: string,
) {
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

	ld: Loader
	ld.world = world
	rels_ok: bool
	ld.rels, rels_ok = resolve_loader_relations(world)
	if !rels_ok {
		fmt.eprintf(
			"loader relations missing: load the bycycle ontology into the store first " +
			"(scripts/bycycle-load.sh init DIR)\n",
		)
		os.exit(1)
	}
	if retrieval_actor != "" && ld.rels[.Can_Retrieve] == 0 {
		fmt.eprintf("--retrieval-actor given but CanRetrieveSubject is not declared in the store\n")
		os.exit(1)
	}

	ld.identities = make(map[string]v.Value)
	defer delete(ld.identities)
	defer delete(ld.label_seen)
	defer delete(ld.pending)
	ld.next_identity = next_identity_seed(world)
	fmt.eprintf("  ... seeding done\n")

	if err := virtual.arena_init_growing(&ld.batch_arena); err != nil {
		fmt.eprintf("arena init failed\n")
		os.exit(1)
	}
	defer virtual.arena_destroy(&ld.batch_arena)
	ld.batch_alloc = virtual.arena_allocator(&ld.batch_arena)
	preseed_identities(&ld)

	actor: v.Value
	has_actor := retrieval_actor != ""
	if has_actor {
		actor = resolve_actor(&ld, retrieval_actor)
	}

	// Resume position: durable in LoaderState (Mica store), not derived
	// from GuidOf row counting and not a re-scan over already-loaded
	// subjects. GuidOf rows still pre-seed the identity map (forward refs
	// from new subjects may point at old ones).
	scan_t0 := time.tick_now()
	pos := 0
	subjects_done := 0
	resume_pos, resume_subjects, has_resume := load_resume_state(&ld, owl_path)
	if has_resume {
		if resume_pos < len(xml_text) {
			pos = resume_pos
			subjects_done = resume_subjects
			ld.stats.subjects = resume_subjects
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
	for limit <= 0 || subjects_done < limit {
		tag, ok := dom.dom_xml_next_tag(xml_text, pos)
		if !ok {
			break
		}
		pos = tag.end
		if !is_subject(tag) {
			continue
		}
		about, about_ok := dom.dom_xml_attr_value(tag.head, ABOUT_ATTR)
		frag := frag_of(about)
		if !about_ok || frag == "" || !is_guid(frag) {
			// owl:Ontology, AnnotationProperty declarations, etc.
			ld.stats.skipped += 1
			if end, skip_ok := dom.dom_xml_skip_element(xml_text, tag); skip_ok {
				pos = end
			}
			continue
		}
		subj := intern_guid(&ld, frag)
		ld.stats.subjects += 1
		subjects_done += 1
		if has_actor {
			queue(&ld, .Can_Retrieve, actor, subj)
			ld.stats.internal += 1
		}
		scan_subject_children(&ld, xml_text, &pos, tag, subj)
		if len(ld.pending) >= commit_batch {
			if !flush(&ld) {
				os.exit(1)
			}
			if checkpoint {
				checkpoint_here(&ld)
			}
			save_resume_state(&ld, owl_path, pos, subjects_done)
			reset_batch(&ld)
			fmt.eprintf(
				"  ... %d subjects, %d triples asserted\n",
				ld.stats.subjects,
				ld.stats.asserted,
			)
		}
		if subjects_done % 20000 == 0 {
			fmt.eprintf(
				"  ... %d subjects, %d triples seen\n",
				ld.stats.subjects,
				ld.stats.triples,
			)
		}
	}
	if !flush(&ld) {
		os.exit(1)
	}
	reset_batch(&ld)
	ld.stats.scan_seconds += time.duration_seconds(time.tick_since(scan_t0))
	if checkpoint {
		checkpoint_here(&ld)
	}
	save_resume_state(&ld, owl_path, pos, subjects_done)

	print_timing_summary(&ld.stats)

	fmt.printf(
		"done: %d subjects, %d triples, %d internal, %d asserted, %d skipped, " +
		"%d dropped resources, %d commits, %d identities\n",
		ld.stats.subjects,
		ld.stats.triples,
		ld.stats.internal,
		ld.stats.asserted,
		ld.stats.skipped,
		ld.stats.dropped_resources,
		ld.stats.commits,
		ld.stats.identities,
	)
}

// Commits everything in pending as one transaction.
flush :: proc(ld: ^Loader) -> bool {
	if len(ld.pending) == 0 {
		return true
	}
	t0 := time.tick_now()
	tx := k.kernel_begin(ld.world.kernel)
	for p in ld.pending {
		if err := k.transaction_assert(&tx, p.relation, p.tuple); err != .None {
			fmt.eprintf("assert failed: %v\n", err)
			ld.stats.err_assert += 1
			k.transaction_destroy(&tx)
			return false
		}
		ld.stats.asserted += 1
	}
	ld.stats.assert_seconds += time.duration_seconds(time.tick_since(t0))
	t0 = time.tick_now()
	committed, commit_err := k.transaction_commit(&tx)
	k.transaction_destroy(&tx)
	ld.stats.commit_seconds += time.duration_seconds(time.tick_since(t0))
	if commit_err != .None {
		fmt.eprintf("commit failed: %v\n", commit_err)
		ld.stats.err_commit += 1
		return false
	}
	k.snapshot_release(committed)
	ld.stats.commits += 1
	clear(&ld.pending)
	return true
}

// Frees everything the batch allocated (tuples, strings). Called right after
// flush; transaction_assert already deep-copied into the tx arena, so pending
// memory is dead here.
reset_batch :: proc(ld: ^Loader) {
	clear(&ld.pending)
	virtual.arena_free_all(&ld.batch_arena)
}

checkpoint_here :: proc(ld: ^Loader) {
	t0 := time.tick_now()
	if !r.world_checkpoint(ld.world) {
		ld.stats.err_checkpoint += 1
		fmt.eprintf("checkpoint failed\n")
	}
	ld.stats.checkpoint_seconds += time.duration_seconds(time.tick_since(t0))
}

// Queues one binary fact on the batch arena. Callers count it under triples
// or internal as appropriate.
queue :: proc(ld: ^Loader, field: Field, a, b: v.Value) {
	append(&ld.pending, Pending_Assert {
		relation = ld.rels[field],
		tuple = v.tuple_new(ld.batch_alloc, []v.Value{a, b}),
	})
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

// Pre-seeds the identities map from GuidOf rows already committed: guid
// string -> identity value. A resumed run then reuses identities for
// re-encountered subjects instead of minting duplicates, and set semantics
// dedupe the re-asserted facts. Runs once at startup; the scan itself is
// still exactly one forward pass.
preseed_identities :: proc(ld: ^Loader) {
	rows: [dynamic]v.Tuple
	defer delete(rows)
	source := k.Relation_Source{snapshot = ld.world.kernel.current}
	unbound := make([]v.Binding, 2, context.temp_allocator)
	k.relation_source_scan_into(&source, ld.rels[.Guid_Of], unbound, &rows)
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
		// Clone into the map with a heap-stable key.
		key := strings.clone(guid, context.allocator)
		ld.identities[key] = v.value_identity(id)
		// Register the sanitized name so #guid_X resolves in later evals
		// within this process too. The map owns sanitize_guid's result.
		ld.world.ctx.identities[sanitize_guid(key, context.allocator)] = v.value_identity(id)
	}
	if len(rows) > 0 {
		fmt.eprintf("  ... pre-seeded %d committed identities\n", len(ld.identities))
	}
}

// Mints a fresh loader identity, registered under name in the world (so
// #name resolves in later evals this process) and queued as a NamedIdentity
// fact (so it resolves after reboot). The fact rides the batch like any
// other: a commit of its own would rerun the rule fixpoint once per identity.
mint_identity :: proc(ld: ^Loader, name: string) -> v.Value {
	raw := ld.next_identity
	ld.next_identity += 1
	identity, ok := v.value_identity_raw(raw)
	if !ok {
		fmt.eprintf("identity space exhausted at %d\n", raw)
		ld.stats.err_identity += 1
		os.exit(1)
	}
	ld.world.ctx.identities[name] = identity
	ld.stats.identities += 1
	append(&ld.pending, Pending_Assert {
		relation = k.SYSTEM_NAMED_IDENTITY_ID,
		tuple = v.tuple_new(ld.batch_alloc, []v.Value {
			identity,
			v.value_symbol(v.symbol_intern(name)),
		}),
	})
	ld.stats.internal += 1
	return identity
}

// Interns a GUID fragment to a named identity, queueing the GuidOf audit
// fact. Reuses the map when seen before.
intern_guid :: proc(ld: ^Loader, guid: string) -> v.Value {
	if existing, found := ld.identities[guid]; found {
		return existing
	}
	// Both the name and the map key outlive every batch, so they live on
	// context.allocator: the name in world.ctx.identities, the key here
	// (guid borrows xml_text, which also lives for the run, but a heap-stable
	// key keeps the map independent of the input buffer).
	identity := mint_identity(ld, sanitize_guid(guid, context.allocator))
	ld.identities[strings.clone(guid, context.allocator)] = identity
	append(&ld.pending, Pending_Assert {
		relation = ld.rels[.Guid_Of],
		tuple = v.tuple_new(ld.batch_alloc, []v.Value {
			identity,
			v.value_string(ld.batch_alloc, guid),
		}),
	})
	ld.stats.internal += 1
	return identity
}

// Resolves the retrieval actor by name, minting it when the store has none
// yet. A rerun finds the name through NamedIdentity at boot and reuses it.
resolve_actor :: proc(ld: ^Loader, name: string) -> v.Value {
	if existing, found := ld.world.ctx.identities[name]; found {
		return existing
	}
	return mint_identity(ld, strings.clone(name, context.allocator))
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

// Resolves the loader's relation names against the live world. Every
// non-optional relation must exist (ontology fileins load first).
resolve_loader_relations :: proc(world: ^r.World) -> (rels: Loader_Relations, ok: bool) {
	names := FIELD_RELATION_NAMES
	for field in Field {
		id, found := world.ctx.relations[names[field]]
		if found {
			rels[field] = k.Relation_ID(id)
		} else if field not_in OPTIONAL_FIELDS {
			return rels, false
		}
	}
	return rels, true
}

// Reads the durable resume point from LoaderState(:resume) if present.
// Returns the byte offset to continue from and the subject count already
// committed, plus whether a valid point exists AND the stored owl path
// matches the file this run is loading.
load_resume_state :: proc(ld: ^Loader, owl_path: string) -> (resume_pos: int, resume_subjects: int, ok: bool) {
	if ld.rels[.Loader_State] == 0 {
		return 0, 0, false
	}
	rows: [dynamic]v.Tuple
	defer delete(rows)
	source := k.Relation_Source{snapshot = ld.world.kernel.current}
	unbound := make([]v.Binding, 2, context.temp_allocator)
	k.relation_source_scan_into(&source, ld.rels[.Loader_State], unbound, &rows)
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
		if len(parts) != 3 || parts[0] != owl_path {
			return 0, 0, false
		}
		pos, pos_ok := strconv.parse_int(parts[1])
		subj, subj_ok := strconv.parse_int(parts[2])
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
save_resume_state :: proc(ld: ^Loader, owl_path: string, pos: int, subjects: int) {
	rel := ld.rels[.Loader_State]
	if rel == 0 {
		return
	}
	val := fmt.tprintf("%s\n%d\n%d", owl_path, pos, subjects)
	key := v.value_symbol(v.symbol_intern("resume"))

	tx := k.kernel_begin(ld.world.kernel)
	// Retract any existing :resume tuple, then assert the new one.
	existing: [dynamic]v.Tuple
	defer delete(existing)
	unbound := make([]v.Binding, 2, context.temp_allocator)
	unbound[0] = v.binding_of(key)
	source := k.Relation_Source{transaction = &tx}
	k.relation_source_scan_into(&source, rel, unbound, &existing)
	for row in existing {
		k.transaction_retract(&tx, rel, row)
	}
	if err := k.transaction_assert(
		&tx,
		rel,
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
		ld.stats.commits += 1
	}
}

// Scans one subject's children, queueing one assertion per triple. Advances
// *pos past the subject's close tag. A self-closing subject has no children.
scan_subject_children :: proc(ld: ^Loader, xml_text: string, pos: ^int, subject: dom.Dom_Xml_Tag, subj: v.Value) {
	depth := subject.kind == .Self_Close ? 0 : 1
	for depth > 0 {
		tag, ok := dom.dom_xml_next_tag(xml_text, pos^)
		if !ok {
			return
		}
		pos^ = tag.end
		switch tag.kind {
		case .Close:
			depth -= 1
			continue
		case .Open:
			depth += 1
		case .Self_Close:
		}
		field := predicate_field(tag.name)
		if field == .None {
			continue
		}
		resource, has_resource := dom.dom_xml_attr_value(tag.head, RESOURCE_ATTR)
		if has_resource || tag.kind != .Open {
			queue_triple(ld, subj, field, "", false, resource, has_resource)
			continue
		}
		literal, is_cdata, end, text_ok := dom.dom_xml_element_text(xml_text, tag)
		if !text_ok {
			return
		}
		// The element's body and close tag are consumed here, so the depth
		// walk never sees the markup inside a comment.
		pos^ = end
		depth -= 1
		queue_triple(ld, subj, field, literal, is_cdata, "", false)
	}
}

// Queues one assertion for a triple. Resource objects that are GUIDs become
// identities (interned); absolute URIs only survive on same_as (kept as
// strings); literals are entity-decoded strings, except CDATA text, which
// the source already wrote verbatim.
queue_triple :: proc(
	ld: ^Loader,
	subj: v.Value,
	field: Field,
	literal: string,
	is_cdata: bool,
	resource: string,
	has_resource: bool,
) {
	if has_resource {
		frag := frag_of(resource)
		if is_guid(frag) {
			queue(ld, field, subj, intern_guid(ld, frag))
			ld.stats.triples += 1
		} else if field == .Same_As && resource != "" {
			queue(ld, field, subj, v.value_string(ld.batch_alloc, resource))
			ld.stats.triples += 1
		} else {
			ld.stats.dropped_resources += 1
		}
		return
	}
	// CDATA is written verbatim by the source (OpenCyc comments hold HTML),
	// so only plain text is entity-decoded.
	text := strings.trim_space(literal)
	if !is_cdata {
		text = dom.dom_xml_decode_entities_into(text, ld.batch_alloc)
	}
	if text == "" {
		ld.stats.skipped += 1
		return
	}
	target := field
	if field in FIRST_WINS_FIELDS {
		if id, ok := v.value_as_identity(subj); ok {
			seen := ld.label_seen[u64(id)]
			if field in seen {
				target = .Alias
			} else {
				ld.label_seen[u64(id)] = seen + {field}
			}
		}
	}
	queue(ld, target, subj, v.value_string(ld.batch_alloc, text))
	ld.stats.triples += 1
}
