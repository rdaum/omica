<!-- Structure and boilerplate derived from IETF practice (RFC 7322 style,
     BCP 14/RFC 8174); Specification body shape derived from NLSpec. -->

# draft-ndn-source-git-00: Source Host Git Relations

**Status:** DRAFT

**Corpus:** red (spec-first — evidence is the acceptance criteria)

**Category:** Standards-Track

**Authors:** Norman Nunley, Jr. <nnunley@gmail.com>


## Abstract

This RFC specifies three computed relations for omica's source host: `source/CommitLog`, `source/ChangedFiles`, `source/FileHistory`. These relations expose git history as queryable facts, bounded and computed on demand, enabling defect-density analysis and other version-control queries without shell-outs.


## Motivation

Mica is a database, a programming language and a runtime; the source host is where the database face meets the files a world was filed in from. omica exposes repository state as relations but not git history. The quality-tool RFC (rdaum/omica#109) requires fix-commit counts per file and file change deltas for defect density. Today this requires shelling out to `git` and parsing output; history belongs in the world as relations, queried like any other. Three relations provide this: commit log, diff between commits, and commits affecting a specific file.


## Terminology

- **repository** — Directory containing `.git`; the root of a git working tree.
- **commit** — Git object identified by its SHA-1 hash (40 hex characters).
- **parent** — Commit preceding another in the DAG; merge commits have multiple parents.
- **file_path** — Path relative to the repository root.


## Specification

This RFC defines three computed relations: `source/CommitLog`, `source/ChangedFiles`, and `source/FileHistory`. It excludes per-line operations (`source/FileBlame`, `source/FileDiff`) and git review receive flow (`refs/for/`); future RFCs will address these.

**Design principle: computed on demand, never persisted.** Relations derive from git object store at query time and are read-only; no `.git` writes.

### Data model

```
RELATION source/CommitLog:
    repository      : String              -- root path, must contain .git
    commit_id       : String              -- 40 hex characters, SHA-1
    parent_ids      : List<String>        -- parent SHAs; empty for root commits
    author_name     : String              -- author name from git config/commit object
    author_email    : String              -- author email
    author_time     : Integer             -- unix timestamp, author's time
    message         : String              -- full commit message

RELATION source/ChangedFiles:
    repository      : String              -- root path, must contain .git
    from_commit     : String              -- 40 hex characters, SHA-1
    to_commit       : String              -- 40 hex characters, SHA-1
    file_path       : String              -- relative to repo root
    change_kind     : String              -- one of: "added", "modified", "removed"

RELATION source/FileHistory:
    repository      : String              -- root path, must contain .git
    file_path       : String              -- relative to repo root
    commit_id       : String              -- 40 hex characters, SHA-1
    parent_ids      : List<String>        -- parent SHAs
    author_name     : String
    author_email    : String
    author_time     : Integer             -- unix timestamp
    message         : String              -- full commit message
```

### Behavior

**Commit log walk.** [R-log-walk-bound] `source/CommitLog` enumerates commits from HEAD with MUST visit limit of 512 per repository (matching Rust mica's MAX_COMMIT_WALK). Traversal is depth-first (newest first) following `git rev-list` semantics; merge commits visit first parent before others. Unknown repositories or unresolvable HEAD return errors; relation yields no rows.

<!-- evidence: @R-log-walk-bound -->

| Case | Input | Expected Result |
|------|-------|-----------------|
| Valid repo, HEAD at commit C1 (5 commits reachable) | repository="/path/to/repo" | 5 tuples, commit_id from C1 backwards to root |
| Unknown repository | repository="/nonexistent" | error: "repository not found" |
| `.git` missing | repository="/normal/dir" (no .git) | error: ".git not found" |
| Repository with > 512 commits | repository="/large-repo" | 512 tuples (truncated) |

**File change detection.** [R-diff-require-bounds] `source/ChangedFiles` diffs two commits and lists files added, modified, or removed. Positions 0, 1, 2 (repository, from_commit, to_commit) MUST be bound. Relation yields one row per changed file sorted by file_path. Unknown commits return errors.

<!-- evidence: @R-diff-require-bounds -->

| Case | Inputs | Expected Rows |
|------|--------|---------------|
| Commit A (empty) → B (adds foo.rs, modifies bar.rs) | from=A, to=B | (foo.rs, "added"), (bar.rs, "modified") |
| Same commit | from=C, to=C | (empty result set) |
| Nonexistent from_commit | from="0000...0000", to=valid | error: "commit not found" |

**File history walk.** [R-file-history-missing] `source/FileHistory` enumerates commits where a file changed. Positions 0, 1 (repository, file_path) MUST be bound. Walk MUST visit at most 512 commits depth-first from HEAD. Unknown repository is an error; non-existent files yield empty result. file_path MUST NOT escape repository root (`../../../etc/passwd` errors).

<!-- evidence: @R-file-history-missing -->

| Case | Inputs | Expected Rows |
|------|--------|---------------|
| File src/main.rs changed in C1, C2, C3 (not C4) | file_path="src/main.rs" | 3 tuples for C1, C2, C3 |
| File never existed | file_path="missing.rs" | (empty result set, no error) |
| Path escapes repo | file_path="../../etc/shadow" | error: "path outside repository root" |
| Unknown repository | repository="/nonexistent", file_path="any.rs" | error: "repository not found" |

### Errors

| Error                    | Trigger | Recovery |
|--------------------------|---------|----------|
| E_REPO_NOT_FOUND         | `.git` missing or path invalid | Reject query; caller MUST fix path |
| E_HEAD_UNRESOLVABLE      | HEAD unreadable or detached with no commits | Reject query; suggest checking repository state |
| E_COMMIT_NOT_FOUND       | from_commit or to_commit not in DAG | Reject query; include commit SHA in error |
| E_PATH_ESCAPE            | file_path escapes repo root | Reject query; paths MUST be relative |
| E_WALK_TRUNCATED         | Walk limit (512) exceeded | Return rows found; caller MAY re-query with a shallower bound |


## Out of Scope

**File-level diffstat and blame.** `source/FileDiff` (unified diff text per file between two commits) and `source/FileBlame` (line-by-line attribution) are deferred to Phase 2; they require per-line processing and larger result sets. A future RFC will define these as separate relations following the same computed-on-demand and bounded-walk pattern, with line numbers as additional columns.

**Review receive flow.** Git refs/for/ review updates (`refs/for/branch/topic`) are excluded here. A future RFC will define `source/GitReceivedRefUpdate` to expose code-review metadata as queryable facts, following this RFC's pattern. Review-flow specification owns that work.


## Alternatives Considered

**Why object store, not `git` shell-out?** The object store (via jj or direct binding) is built-in, avoids process overhead and parsing fragility, and gives direct DAG access.

**Why depth-first, not breadth-first?** Depth-first matches `git rev-list` semantics, is cache-friendly at walk limits, and returns recent history first, as Rust mica does ([crates/source-provider/src/vcs.rs:403-427](https://github.com/timbran-project/mica/blob/2bbceb0113b0/crates/source-provider/src/vcs.rs#L403-L427)).

**Why author, not committer?** Author is who wrote the change; committer applied it (e.g., rebase). Defect density needs the author; committer is deferred. Rust mica's `source/CommitLog` also exposes the author only ([crates/source-provider/src/relations.rs:2354-2400](https://github.com/timbran-project/mica/blob/2bbceb0113b0/crates/source-provider/src/relations.rs#L2354-L2400)).

**Why per-file, not per-line?** Per-file results suffice for defect density; per-line results are larger and require line tracking. `FileBlame` (Phase 2) will report per-line.


## Security Considerations

Relations read from `.git`, exposing public data (hashes, author names, emails, timestamps, messages, file paths, change types). [R-path-validate] file_path validation prevents directory traversal; walk limit (512) prevents denial-of-service. Relations are read-only.

<!-- evidence: @R-path-validate -->
Example test: file_path="../../secrets.env" must error with E_PATH_ESCAPE.


## Compatibility

This RFC adds new computed relations; existing eager relations (`source/FileText`, etc.) are unchanged. Results cache per session to avoid re-walking identical queries; cache drops at snapshot or session end.


## References

- RFC 2119, 8174 — BCP 14 requirement keywords
- Rust mica source-provider: [crates/source-provider/src/vcs.rs](https://github.com/timbran-project/mica/blob/2bbceb0113b0/crates/source-provider/src/vcs.rs) (L16, L403-L427, L337-L371, L474-L517)
- rdaum/omica#109 — quality-tool RFC
- [host/source/index.odin](https://github.com/rdaum/omica/blob/5a22a77cc245/host/source/index.odin) — omica eager relations


## Appendix: Relation to Rust mica

| Behavior | Rust | omica today | This RFC | Class |
|----------|------|-------------|----------|-------|
| CommitLog relation | L403-L427 | Not implemented | Computed on demand, 512-commit bound | Gap → Parity |
| ChangedFiles relation | L337-L371 | Not implemented | Computed on demand, 3 bindings required | Gap → Parity |
| FileHistory relation | L474-L517 | Not implemented | Computed on demand, 512-commit bound | Gap → Parity |
| Bounded walk | L16 | Not applicable | 512-commit limit per relation | Gap → Parity |
| Read-only access | No .git write | N/A | Read-only computed views | Parity |
| Path confinement | No validation | Not applicable | Escapes rejected; E_PATH_ESCAPE error | Improvement |
