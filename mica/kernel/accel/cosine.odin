// Cosine-similarity search over embedding lists through a strategy.
//
// `NearestEmbedding(index, query, limit, ?subject, ?score, ?version)` in
// `apps/shared/retrieval.mica` is currently an exact CPU cosine scan over
// `EmbeddingOf`/`EmbeddingVector`/`VectorIndexContains` facts. This helper
// keeps the same contract — same facts in, same candidate ranking out — and
// moves only the arithmetic to the strategy: pack the candidate vectors once,
// score one query against all of them in a single dispatch, take the top-k on
// CPU. Small inputs and any decline fall back to the existing CPU scan.
package accel

import "core:slice"
import v "../../var"

// One candidate: subject identity plus its embedding vector.
Cosine_Candidate :: struct {
	subject: v.Value,
	vector:  []f32,
}

// One ranked hit: candidate subject plus cosine score.
Cosine_Hit :: struct {
	subject: v.Value,
	score:   f32,
}

// Packs one query against candidates and returns (subject, score) pairs for
// the top `limit` distinct subjects, highest score first. Ties break by
// subject value order, matching the CPU scan contract. Scores are cosine
// similarities in [-1, 1]. Returns ok=false to decline to CPU. Pass an
// explicit strategy; `cosine_top_k_active` dispatches through the active one.
cosine_top_k :: proc(
	query: []f32,
	candidates: []Cosine_Candidate,
	limit: int,
	allocator := context.allocator,
	s: Strategy,
) -> (
	hits: []Cosine_Hit,
	ok: bool,
) {
	if limit <= 0 || len(candidates) == 0 || len(query) == 0 {
		return nil, false
	}
	dim := len(query)
	for cand in candidates {
		if len(cand.vector) != dim {
			return nil, false
		}
	}
	flat := make([]f32, len(candidates) * dim, context.temp_allocator)
	for cand, i in candidates {
		copy(flat[i * dim:(i + 1) * dim], cand.vector)
	}
	scores, scores_ok := s.cosine_query(query, flat, len(candidates), dim)
	if !scores_ok {
		return nil, false
	}
	defer delete(scores)
	ranked, ranked_ok := rank_cosine_hits(candidates, scores, limit, allocator)
	return ranked, ranked_ok
}

// Convenience wrapper dispatching through the active strategy.
cosine_top_k_active :: proc(
	query: []f32,
	candidates: []Cosine_Candidate,
	limit: int,
	allocator := context.allocator,
) -> (
	hits: []Cosine_Hit,
	ok: bool,
) {
	return cosine_top_k(query, candidates, limit, allocator, active_strategy())
}

// Ranks precomputed per-candidate scores: best score per distinct subject,
// highest first, subject value order breaking ties. Sorts Cosine_Hit values
// directly; no separate pair type.
rank_cosine_hits :: proc(
	candidates: []Cosine_Candidate,
	scores: []f32,
	limit: int,
	allocator := context.allocator,
) -> (
	hits: []Cosine_Hit,
	ok: bool,
) {
	best: map[v.Value]f32
	defer delete(best)
	for cand, i in candidates {
		if prev, found := best[cand.subject]; !found || scores[i] > prev {
			best[cand.subject] = scores[i]
		}
	}
	ranked := make([dynamic]Cosine_Hit, 0, len(best), context.temp_allocator)
	for subject, score in best {
		append(&ranked, Cosine_Hit{subject = subject, score = score})
	}
	slice.sort_by(ranked[:], proc(a, b: Cosine_Hit) -> bool {
		if a.score != b.score {
			return a.score > b.score
		}
		return u64(a.subject) < u64(b.subject)
	})
	n := min(limit, len(ranked))
	out := make([]Cosine_Hit, n, allocator)
	copy(out, ranked[:n])
	return out, true
}
