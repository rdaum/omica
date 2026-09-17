// Streaming OWL reader: opencyc-latest.owl.gz -> kernel asserts, no transform.
//
// Loads OWL facts directly into a Mica world with the custom Mica-side
// parser: pass-through, not transform. Facts become assertions in the
// world's relations; the inferencing rules load separately as fileins.
//
// Usage:
//
//	odin run tools/owlstream -- --owl ~/development/bycycle/data/opencyc-latest.owl.gz --census
//	odin run tools/owlstream -- --owl .../opencyc-latest.owl.gz --store .../store/bycycle-db --limit 1000
//	odin run tools/owlstream -- --owl .../opencyc-latest.owl.gz --store .../store/bycycle-db --checkpoint
//
// Pipeline: gzip.load (26MB gz -> ~252MB RAM) -> line scanner -> per
// owl:Class block: stream triples (subject GUID, predicate, object-literal
// or object-resource) -> kernel transaction_assert in batches -> checkpoint.
//
// Identity scheme: filein-assigned raw ids start at 0x1000 (world.odin:563);
// the loader reserves the same range by allocating through a monotonic
// counter seeded from max_stored_identity + 1. GUID strings live in a
// GuidOf functional relation; human names are sanitized labels.
package main

import "core:bytes"
import "core:compress/gzip"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

import dom "../../mica/dom"
import s "../../mica/store"

// GUID predicates in opencyc-latest.owl, mapped to bycycle relations.
// Decoded once via the labels on their own rdf:about subjects:
//   Mx4rwLSVCpwpEbGdrcN5Y29ycA -> prettyString (literal alternates)
//   Mx4rBVVEokNxEdaAAACgydogAg -> quotedIsa (resource)
//   Mx4rvhOImJwpEbGdrcN5Y29ycA -> typeGenls (resource)
//   Mx4rvdUGBpwpEbGdrcN5Y29ycA -> requiredArg1Pred (resource)
//   Mx4rwTvAxJwpEbGdrcN5Y29ycA -> rewriteOf (resource)
//   Mx4rZOAVeiYGEdqAAAACs2IMmw -> broaderTerm (resource)
//   Mx4riWVFR6HJSpaEaHrcWS3MSA -> seeAlsoURI (literal)
//   Mx4rTv-jk9SPTXa991kk5mAvHg -> wikipediaArticleName-Canonical (literal)
//   Mx4rNv0nbm4TTjOp7yhmnzOyqg -> wikipediaArticleURL (literal)
GUID_PRETTY_STRING :: "Mx4rwLSVCpwpEbGdrcN5Y29ycA"
GUID_QUOTED_ISA :: "Mx4rBVVEokNxEdaAAACgydogAg"
GUID_TYPE_GENLS :: "Mx4rvhOImJwpEbGdrcN5Y29ycA"
GUID_REQUIRED_ARG1 :: "Mx4rvdUGBpwpEbGdrcN5Y29ycA"
GUID_REWRITE_OF :: "Mx4rwTvAxJwpEbGdrcN5Y29ycA"
GUID_BROADER_TERM :: "Mx4rZOAVeiYGEdqAAAACs2IMmw"
GUID_SEE_ALSO :: "Mx4riWVFR6HJSpaEaHrcWS3MSA"
GUID_WIKI_NAME :: "Mx4rTv-jk9SPTXa991kk5mAvHg"
GUID_WIKI_URL :: "Mx4rNv0nbm4TTjOp7yhmnzOyqg"

RDF_TYPE :: "rdf:type"
RDFS_SUBCLASS :: "rdfs:subClassOf"
OWL_DISJOINT :: "owl:disjointWith"
OWL_SAMEAS :: "owl:sameAs"
RDFS_LABEL :: "rdfs:label"
CYCL_LABEL :: "cycAnnot:label"
RDFS_COMMENT :: "rdfs:comment"

@(private)
USAGE :: "usage: owlstream --owl PATH [--store DIR] [--census] [--limit N] " +
	"[--commit-batch N] [--durability none|group|strict] [--checkpoint] [--retrieval-actor NAME]\n" +
	"  --census: print top-level element + child predicate frequencies, assert nothing\n" +
	"  --limit N: stop after N subjects (default 0 = all)\n" +
	"  --commit-batch N: queued facts per transaction commit (default 20000)\n" +
	"  --checkpoint: checkpoint the store after every commit batch\n" +
	"  --retrieval-actor NAME: assert CanRetrieveSubject(#NAME, subject) for every subject\n"

main :: proc() {
	owl_path := ""
	store_path := ""
	census_only := false
	limit := 0
	commit_batch := 20000
	checkpoint := false
	retrieval_actor := ""
	durability := s.Durability.Group

	arguments := os.args[1:]
	for index := 0; index < len(arguments); index += 1 {
		switch arguments[index] {
		case "--owl":
			index += 1
			if index >= len(arguments) {
				fmt.eprintf(USAGE)
				os.exit(1)
			}
			owl_path = arguments[index]
		case "--store":
			index += 1
			if index >= len(arguments) {
				fmt.eprintf(USAGE)
				os.exit(1)
			}
			store_path = arguments[index]
		case "--census":
			census_only = true
		case "--limit":
			index += 1
			if index >= len(arguments) {
				fmt.eprintf(USAGE)
				os.exit(1)
			}
			limit = atoi("--limit", arguments[index])
		case "--commit-batch":
			index += 1
			if index >= len(arguments) {
				fmt.eprintf(USAGE)
				os.exit(1)
			}
			commit_batch = atoi("--commit-batch", arguments[index])
		case "--durability":
			index += 1
			if index >= len(arguments) {
				fmt.eprintf(USAGE)
				os.exit(1)
			}
			switch arguments[index] {
			case "none":
				durability = s.Durability.None
			case "strict":
				durability = s.Durability.Strict
			}
		case "--checkpoint":
			checkpoint = true
		case "--retrieval-actor":
			index += 1
			if index >= len(arguments) {
				fmt.eprintf(USAGE)
				os.exit(1)
			}
			retrieval_actor = arguments[index]
		case "--help", "-h":
			fmt.printf(USAGE)
			return
		case:
			fmt.eprintf("unknown flag: %s\n%s", arguments[index], USAGE)
			os.exit(1)
		}
	}
	if owl_path == "" {
		fmt.eprintf(USAGE)
		os.exit(1)
	}
	if !census_only && store_path == "" {
		fmt.eprintf("need --store DIR (or --census)\n%s", USAGE)
		os.exit(1)
	}

	raw, raw_err := os.read_entire_file(owl_path, context.allocator)
	if raw_err != nil {
		fmt.eprintf("cannot read %s\n", owl_path)
		os.exit(1)
	}
	defer delete(raw, context.allocator)

	t0 := time.tick_now()
	// NOTE: buf must live until run_load/run_census return: xml_text
	// aliases its memory. Do NOT scope buf in the if-block with a defer
	// (Odin runs block-scoped defers at block end, dangling xml_text ->
	// SIGSEGV in scan_next_open once pages are reused; ASan proved it).
	buf: bytes.Buffer
	have_buf := false
	xml_text: string
	if strings.has_suffix(owl_path, ".gz") {
		if err := gzip.load_from_bytes(raw, &buf, len(raw)); err != nil {
			fmt.eprintf("gzip decode failed: %v\n", err)
			os.exit(1)
		}
		have_buf = true
		xml_text = string(bytes.buffer_to_bytes(&buf))
	} else {
		xml_text = string(raw)
	}
	fmt.eprintf(
		"decoded %d bytes of XML in %.1fs\n",
		len(xml_text),
		time.duration_seconds(time.tick_since(t0)),
	)

	if census_only {
		run_census(xml_text)
	} else {
		run_load(
			xml_text,
			store_path,
			owl_path,
			limit,
			commit_batch,
			durability,
			checkpoint,
			retrieval_actor,
		)
	}
	if have_buf {
		bytes.buffer_destroy(&buf)
	}
}

@(private)
atoi :: proc(flag: string, text: string) -> int {
	n, ok := strconv.parse_int(text)
	if !ok || n < 0 {
		fmt.eprintf("%s: expected a non-negative integer, got %q\n%s", flag, text, USAGE)
		os.exit(1)
	}
	return n
}

// Census: frequencies of top-level rdf:about element tags and of child
// predicate tags. No kernel involved.
@(private)
run_census :: proc(xml_text: string) {
	subjects := make(map[string]int)
	preds := make(map[string]int)
	defer delete(subjects)
	defer delete(preds)

	pos := 0
	n_subjects := 0
	for {
		tag, ok := dom.dom_xml_next_tag(xml_text, pos)
		if !ok {
			break
		}
		pos = tag.end
		if !is_subject(tag) {
			continue
		}
		n_subjects += 1
		subjects[tag.name] = (subjects[tag.name] or_else 0) + 1
		// scan children until matching close
		depth := tag.kind == .Self_Close ? 0 : 1
		for depth > 0 {
			child, child_ok := dom.dom_xml_next_tag(xml_text, pos)
			if !child_ok {
				break
			}
			pos = child.end
			switch child.kind {
			case .Close:
				depth -= 1
				continue
			case .Open:
				depth += 1
			case .Self_Close:
			}
			if !is_subject(child) {
				preds[child.name] = (preds[child.name] or_else 0) + 1
			}
		}
	}

	fmt.printf("subjects: %d\n", n_subjects)
	fmt.printf("== top-level element tags ==\n")
	print_top(subjects, 20)
	fmt.printf("== child predicate tags ==\n")
	print_top(preds, 30)
}

@(private)
Print_Pair :: struct {
	key:   string,
	count: int,
}

@(private)
print_top :: proc(counts: map[string]int, n: int) {
	ordered := make([dynamic]Print_Pair, 0, len(counts), context.temp_allocator)
	for key, count in counts {
		append(&ordered, Print_Pair{key = key, count = count})
	}
	if len(ordered) == 0 {
		return
	}
	for i in 1 ..< len(ordered) {
		j := i
		for j > 0 && ordered[j].count > ordered[j - 1].count {
			ordered[j], ordered[j - 1] = ordered[j - 1], ordered[j]
			j -= 1
		}
	}
	for i in 0 ..< min(n, len(ordered)) {
		fmt.printf("%8d  %s\n", ordered[i].count, ordered[i].key)
	}
}

// The OWL is machine-generated: one element per line, children indented
// under their subject. mica/dom's streaming scanner finds the tag boundaries;
// a tag carrying rdf:about opens a subject.

ABOUT_ATTR :: "rdf:about"
RESOURCE_ATTR :: "rdf:resource"

@(private)
is_subject :: proc(tag: dom.Dom_Xml_Tag) -> bool {
	return tag.kind != .Close && strings.contains(tag.head, ABOUT_ATTR + `="`)
}
