#!/usr/bin/env bash
# Bycycle: load and query the OpenCyc OWL dump in a Mica store.
#
#   scripts/bycycle-load.sh init   STORE [--force]  # ontology + rules, fresh store
#   scripts/bycycle-load.sh load   STORE OWL_GZ     # stream facts (resumable)
#   scripts/bycycle-load.sh query  STORE 'EXPR'     # eval against the store
#   scripts/bycycle-load.sh repl   STORE            # interactive REPL
#
# The OWL dump is opencyc-latest.owl.gz from asanchez75/opencyc (Git LFS —
# fetch via the media.githubusercontent.com URL, not the raw one).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

ODIN_BIN="${ODIN_BIN:-$(command -v odin || true)}"
if [[ -z "${ODIN_BIN}" || ! -x "${ODIN_BIN}" ]]; then
  echo "cannot find the Odin compiler; set ODIN_BIN" >&2
  exit 1
fi
ONTOLOGY=(
  apps/bycycle/00_schema.mica
  apps/bycycle/10_taxonomy.mica
  apps/bycycle/20_constraints.mica
  apps/bycycle/30_graph.mica
  apps/shared/retrieval.mica
)

cmd="${1:-}"
shift || true

case "${cmd}" in
  init)
    store="${1:?usage: bycycle-load.sh init STORE [--force]}"
    # init starts from an empty store; refuse to discard a (possibly partly
    # loaded, resumable) one unless asked.
    if [[ -e "${store}" ]]; then
      if [[ "${2:-}" != "--force" ]]; then
        echo "${store} exists; pass --force to delete it and start over" >&2
        exit 1
      fi
      rm -rf "${store}"
    fi
    "${ODIN_BIN}" run tools/filein -- \
      --store "${store}" --unit bycycle "${ONTOLOGY[@]}" --checkpoint
    ;;
  load)
    store="${1:?usage: bycycle-load.sh load STORE OWL_GZ}"
    owl="${2:?usage: bycycle-load.sh load STORE OWL_GZ}"
    # Resume position lives in LoaderState inside the store; safe to re-run
    # after a kill. Remove a stale LOCK if a previous run was killed.
    rm -f "${store}/LOCK"
    "${ODIN_BIN}" run tools/owlstream -- \
      --owl "${owl}" --store "${store}" --commit-batch 20000 --checkpoint \
      --retrieval-actor bycycle_reader
    ;;
  query)
    store="${1:?usage: bycycle-load.sh query STORE 'EXPR'}"
    expr="${2:?usage: bycycle-load.sh query STORE 'EXPR'}"
    rm -f "${store}/LOCK"
    "${ODIN_BIN}" run tools/filein -- --store "${store}" --eval "${expr}"
    ;;
  repl)
    store="${1:?usage: bycycle-load.sh repl STORE}"
    rm -f "${store}/LOCK"
    "${ODIN_BIN}" run tools/repl -- --store "${store}"
    ;;
  *)
    echo "usage: bycycle-load.sh {init|load|query|repl} ..." >&2
    exit 1
    ;;
esac
