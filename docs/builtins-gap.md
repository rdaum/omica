# Builtins Gap

This document tracks differences between the built-in surface described by the
book (`mdbook/src/language/builtins.md`) and the built-ins installed by the
Odin runtime (`runtime_builtins` in `mica/runtime/builtins.odin`).

Every documented built-in and compiler-recognized form is installed. The
remaining differences are behavioral and are listed under Notes.

## Relation creation

`make_relation` and `make_functional_relation` create schemas during execution, including calls
inside verbs with computed arguments. Creation and reflection facts share the task transaction.
Matching declarations return the same identity. Incompatible declarations fail. Administrative
authority is required. Literal filein declarations use the same validation before compilation.

`make_identity` creates durable name bindings from computed symbols in the task transaction.
Filein and runtime creation share the allocator. Later compilation reads committed bindings.

`compile` produces encoded program bytes. `install_source` stages verbs, rules, and literal declarations atomically.
Both use a private compile context. Source installation requires administrative authority.
Programs have separate artifact identities; frames and function handles retain their defining images.
Unreachable function handles currently remain interned until world shutdown.
Type aliases remain outside the current parser's grammar.

## Coverage

Installed and matching the book: `string_*`, `url_*`, `words`, `sort`,
`to_symbol`, `error`, `error_code`, `to_literal`, `from_literal`,
`map_pairs`, `index_or`, `json_encode`, `json_decode`, `json_null`,
`make_identity`, `make_relation`, `make_functional_relation`, `compile`, `install_source`,
`project`, `union`, `difference`, `natural_join`, `actor`, `principal`,
`endpoint`, `assume_actor`, `emit`, `log`, `mailbox`, `mailbox_send`,
`mailbox_close`, `mailbox_recv`, `subscribe_changes`,
`cancel_subscription`, `frob`, `frob_delegate`, `frob_value`, `is_frob`,
`dom_text`, `dom_raw`, `dom_element`, `dom_html`, `to_xml`, `from_xml`,
`dom_diff`, `dom_snapshot_payload`, `sync_signature`, `embed_text`, `lower`,
`edit_distance`, `parse_ordinal`, `external_request`, `destroy_identity`,
`rules`, `describe_rule`, `enable_rule`, `disable_rule`, `tasks`, `fileout`,
`fileout_rules`, `os_getenv`, and `require`.

Compiler forms: `commit()`, `suspend([seconds])`, `read([metadata])`, and
`invoke(selector, roles)`. `suspend()` without a duration compiles to a
cooperative yield; a duration parks the task on a timer.

## read

`read` is a task suspension. The VM commits the task at the boundary and
parks it with `Task_Suspend.Host_Request`. The request metadata is exposed on
`Task_Outcome.request` and through `world_task_request(world, id)`. A host
resumes the task with `world_resume(world, id, value)`; the value becomes the
`read` expression's value. Rust's `SuspendKind::WaitingForInput` maps to this
pair of accessors.

## Installed but not documented in the built-in tables

### Capabilities

- `mint_capability(...)`
- `restrict_capability(...)`
- `use_capability(...)`
- `revoke_capability(...)`
- `drop_capability(...)`

The book covers authority policy and `grant`, but not these bearer-capability
operations. No file under `mdbook/src` mentions them. `language/authority.md`
is the natural home for them.

### Rule Toggles

- `enable_rule(#rule)`

`disable_rule` is documented in the book's table, `enable_rule` is not. Both
are installed here.

### JSON

- `json_is_null(value)`

### Internal Helpers

These names are compiler detail, not part of the documented surface, and
should not be added to the book:

- `__get_field`, `__set_field`, `__set_index`, `__index_option`,
  `__len_option`, `__list_concat`, `__list_slice`

## Prototype identities

`bool`, `bytes`, `capability`, `error`, `error_code`, `float`, `frob`,
`function`, `identity`, `integer`, `list`, `map`, `range`, `relation`,
`string`, and `symbol` are installed as primitive prototype identities
(`#bool`, `#string`, ...) in `install_primitive_identities`, not as callable
builtins. They are already covered by `value-kind-annotations.md` and
`values.md`.

## Notes

- Relation values canonicalize their heading and row order internally, so
  `project` output column order is not observable from Mica; `union` and
  `difference` compare canonical headings, and `natural_join` matches on
  shared column names with canonical value equality.
- `dom_diff` returns the same patch map shape as the Rust host protocol
  (`op`, `path`, and variant keys), so `json_encode(dom_diff(...))` matches
  the documented examples.
- `dom_html` restricts tags and attributes to the DOM surface and never
  emits void elements: `<input>` renders as `<input></input>`, matching the
  Rust `to_xml` writer.
- `to_xml` accepts symbol attribute names and quote-escapes attribute string
  values, matching `dom_html` and the Rust host.
- `from_xml` supports elements, attributes, text, CDATA, comments,
  declarations, the five predefined entities, and numeric character
  references. It does not validate tags against the DOM surface, matching
  the Rust parser.
- `log` requires effect authority and writes to the host standard error.
- `tasks()` returns `[:id, :state]` maps for non-terminal tasks, sorted by
  id, with `:running` and `:suspended` states.
- `destroy_identity(#identity)` retracts stored facts whose first column is
  the identity plus the `NamedIdentity` name binding, and returns the count.
  Identity names still resolve in the current compile context; only the
  durable binding is removed. Catalogue relations are never touched.
- `fileout(:unit)` returns the source text loaded for a unit. The unit name
  comes from the explicit load unit (`--unit NAME` in `tools/filein`,
  `Run_Options.unit`, or `World_Config.unit`); otherwise it is the file's
  base name without its extension. When several files share a unit their
  sources are joined with a blank line. Loaded unit sources are recorded as
  `UnitSource(ordinal, unit, source)` facts so `fileout` and boot-time code
  recompilation work without the files. The Rust host rebuilds unit source
  from `SourceOwnsFact`, `SourceOwnsRelation`, and `SourceOwnsRule`
  ownership facts; this port does not populate those relations and units are
  load-time labels, not a replace or persistence model.
- `fileout_rules([:Relation])` returns active rule source, optionally
  filtered to a head relation, with rules separated by a blank line. Rule
  source is the rule's own span, so `describe_rule` and `RuleSource` facts
  are per-rule.
- `os_getenv` is installed and documented. It requires root authority or an
  invoke grant as the book says.
- `embed_text` is installed and documented, but the port returns a
  deterministic hash-based vector and ignores the model argument pending a
  provider. The `embedding` external service itself is implemented in
  `mica/external` for hosts that call `external_request(:embedding, ...)`.
- The LLM host requests (`llm_responses_stream`, `llm_chat_stream_to`,
  `openai_chat_completion`, `openai_chat_completion_with_options`) are
  compiler-recognized and implemented in `mica/external` over libcurl; see
  [The LLM Host Bridge](../mdbook/src/runtime/llm-bridge.md).

## String scanning

Indexing, `len`, and `for` treat a string as a sequence of Unicode scalar
values: `text[i]` yields the scalar at position `i` as an integer, `len(text)`
is the scalar count, and `for ch in text` (or `for i, ch in text`) iterates
scalars. These reuse the existing `.Index`, `.Len`, `Collection_Value_At`, and
`Collection_Key_At` opcodes, so no new builtins are installed. `string_len` and
`string_slice` are unchanged in meaning but now share the same scalar model and
run in O(1) on ASCII strings and O(32) on indexable non-ASCII strings
(`STRING_INDEX_STRIDE`). This is a deliberate extension over the Rust surface,
which is documented in the book; the Rust implementation has no string
indexing. `string_from_chars` still documents one-scalar elements but does not
validate them.
