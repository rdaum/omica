// Error hierarchy: ErrorParent(code, parent) facts relate error codes, and a
// code's ancestors are itself plus the ancestors of its parents. Catch clauses
// and the ErrorIsA relation both use the walk below
// (draft-ndn-error-hierarchy-00).
package kernel

import v "../var"

SYSTEM_ERROR_PARENT_ID :: Relation_ID(0x7fff_fe1e)
SYSTEM_ERROR_IS_A_ID :: Relation_ID(0x7fff_fe1f)

// The links a new world starts with, as [code, parent] names.
ERROR_HIERARCHY_BUILTIN_LINKS :: [?][2]string {
	{"E_INDEX", "E_LOOKUP"},
	{"E_KEY", "E_LOOKUP"},
	{"E_NOT_FOUND", "E_LOOKUP"},
	{"E_INVARG", "E_TYPE"},
	{"E_DIV", "E_ARITH"},
	{"E_CONFLICT", "E_TRANSACTION"},
	{"E_RETRY", "E_TRANSACTION"},
	{"E_PERMISSION", "E_AUTHORITY"},
	{"E_CAPABILITY", "E_AUTHORITY"},
}

// Visits `code` and each of its ancestors once, breadth first, reading
// ErrorParent through `source`. Stops early when `visit` returns false.
error_ancestors_visit :: proc(
	source: ^Relation_Source,
	code: v.Value,
	visit: proc(user: rawptr, ancestor: v.Value) -> bool,
	user: rawptr,
) {
	seen := make([dynamic]v.Value, context.temp_allocator)
	append(&seen, code)
	rows := make([dynamic]v.Tuple, context.temp_allocator)
	for next := 0; next < len(seen); next += 1 {
		current := seen[next]
		if !visit(user, current) {
			return
		}
		clear(&rows)
		bindings := []v.Binding{v.binding_of(current), {}}
		relation_source_scan_into(source, SYSTEM_ERROR_PARENT_ID, bindings, &rows)
		for row in rows {
			parent := v.tuple_values(row)[1]
			known := false
			for existing in seen {
				if v.value_eq(existing, parent) {
					known = true
					break
				}
			}
			if !known {
				append(&seen, parent)
			}
		}
	}
}

// Whether `ancestor` is `code` or one of its ancestors.
error_is_a :: proc(source: ^Relation_Source, code, ancestor: v.Value) -> bool {
	if v.value_eq(code, ancestor) {
		return true
	}
	Search :: struct {
		target: v.Value,
		found:  bool,
	}
	search := Search{target = ancestor}
	error_ancestors_visit(source, code, proc(user: rawptr, candidate: v.Value) -> bool {
		search := (^Search)(user)
		if v.value_eq(candidate, search.target) {
			search.found = true
			return false
		}
		return true
	}, &search)
	return search.found
}
