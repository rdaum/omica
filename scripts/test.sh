#!/usr/bin/env bash
# Builds and runs the Mica test suites.
#
#   scripts/test.sh              # unit tests (default)
#   scripts/test.sh unit         # package unit tests
#   scripts/test.sh integration  # end-to-end CLI and web smoke tests
#   scripts/test.sh tsan         # unit tests under ThreadSanitizer
#   scripts/test.sh all          # unit + integration
#
# Every external command runs under a wall-clock limit (GNU `timeout`/`gtimeout`
# when present, otherwise a portable background-watchdog fallback) and its
# output is captured to a file, so a hang is reported as a failure instead of
# blocking the run. The watchdog kills the whole process tree, not just the
# direct child, so a test binary cannot outlive its compiler and hold the run
# open. A run fails on a test failure, a crash, a tracking allocator "bad free",
# a timeout, or a ThreadSanitizer report. Leaks are reported in the log summary;
# set STRICT_LEAKS=1 to fail on them too (there is a known backlog of
# parser/lexer/builder leaks).
#
# Portable across Linux and macOS: no GNU-only utilities.
#
# Environment:
#   ODIN_BIN       Odin compiler (default: `odin` on PATH, else ../odin-setup/odin)
#   STRICT_LEAKS   set to 1 to fail on any tracking-allocator leak
#   TEST_TIMEOUT   per-command timeout in seconds (default 300; the runtime
#                  suite compiles and runs near the old 120s budget on the
#                  4-core CI runners)
#   TSAN_TIMEOUT   per-package ThreadSanitizer timeout in seconds (default 1200)
#   PORTABLE_TIMEOUT  set to 1 to force the portable timeout fallback
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

odin_bin="${ODIN_BIN:-$(command -v odin || true)}"
if [[ -z "${odin_bin}" && -x "${repo_root}/../odin-setup/odin" ]]; then
  odin_bin="${repo_root}/../odin-setup/odin"
fi
if [[ -z "${odin_bin}" || ! -x "${odin_bin}" ]]; then
  echo "cannot find the Odin compiler; set ODIN_BIN" >&2
  exit 1
fi

if [[ ! -f "${repo_root}/vendor/micromeasure/micromeasure-odin/micromeasure.odin" ]]; then
  echo "missing micromeasure submodule; run git submodule update --init --recursive" >&2
  exit 1
fi

packages=(vendor/micromeasure/micromeasure-odin mica/var mica/buffer mica/kernel mica/vm mica/compiler mica/runtime mica/external mica/dom mica/store host/source host/web)
bin_dir="${repo_root}/.cache/test-bin"
log_dir="${repo_root}/.cache/test-logs"
strict_leaks="${STRICT_LEAKS:-0}"
test_timeout="${TEST_TIMEOUT:-300}"
tsan_timeout="${TSAN_TIMEOUT:-1200}"
fail=0
cleanup_pids=()
cleanup_paths=()

# Sends `sig` to a process and every descendant, grandchildren first.
kill_tree() {
  local sig="$1" pid="$2" child
  [[ -n "${pid}" ]] || return 0
  for child in $(pgrep -P "${pid}" 2>/dev/null || true); do
    kill_tree "${sig}" "${child}"
  done
  kill -s "${sig}" "${pid}" 2>/dev/null || true
}

# Terminates a process tree, escalating to SIGKILL.
stop_process() {
  local pid="$1"
  [[ -n "${pid}" ]] || return 0
  kill_tree TERM "${pid}"
  local i
  for ((i = 0; i < 50; i++)); do
    kill -0 "${pid}" 2>/dev/null || return 0
    sleep 0.1
  done
  kill_tree KILL "${pid}"
}

# Kills leftover servers and removes temp dirs, including on interrupt.
cleanup() {
  local rc=$? i
  if [[ ${#cleanup_pids[@]} -gt 0 ]]; then
    for ((i = ${#cleanup_pids[@]} - 1; i >= 0; i--)); do
      stop_process "${cleanup_pids[i]}"
    done
  fi
  if [[ ${#cleanup_paths[@]} -gt 0 ]]; then
    for ((i = 0; i < ${#cleanup_paths[@]}; i++)); do
      rm -rf "${cleanup_paths[i]}"
    done
  fi
  return "${rc}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "${bin_dir}" "${log_dir}"

# The fileins that make up the browser MUD (mirror of scripts/mud.sh).
mud_fileins=(
  apps/shared/string.mica
  apps/shared/list.mica
  apps/shared/events.mica
  apps/shared/retrieval.mica
  apps/shared/sync-host.mica
  apps/shared/sync-dom.mica
  apps/mud/core.mica
  apps/mud/auth.mica
  apps/mud/command-parser.mica
  apps/mud/event-substitutions.mica
  apps/mud/ui-session.mica
  apps/mud/ui-actions.mica
  apps/mud/ui-compose.mica
  apps/mud/ui-narrative.mica
  apps/mud/ui-mica-inspect.mica
  apps/mud/ui-retrieval.mica
  apps/mud/http.mica
)

# Runs "$@" with a wall-clock limit. GNU timeout/gtimeout knows to kill the
# child's process group; the portable fallback runs the command in the
# background and a watchdog kills the whole tree on expiry. The caller is
# expected to redirect output to a file, never capture it with $(...), so a
# lingering process cannot hold the run open. Set PORTABLE_TIMEOUT=1 to force
# the fallback (used to exercise it on Linux).
run_timeout() {
  local secs="$1"
  shift
  if [[ "${PORTABLE_TIMEOUT:-0}" != "1" ]] && command -v timeout >/dev/null 2>&1; then
    timeout "${secs}" "$@"
    return $?
  fi
  if [[ "${PORTABLE_TIMEOUT:-0}" != "1" ]] && command -v gtimeout >/dev/null 2>&1; then
    gtimeout "${secs}" "$@"
    return $?
  fi
  # A background job gets stdin from /dev/null, so save stdin on a high fd and
  # restore it for the command: the REPL and other stdin consumers must still
  # see their input.
  local have_stdin=0
  # Scope stderr suppression to the duplication attempt. Redirection on a
  # bare `exec` otherwise persists and hides the command's test diagnostics.
  if { exec 9<&0; } 2>/dev/null; then
    have_stdin=1
  fi
  if [[ "${have_stdin}" == "1" ]]; then
    "$@" <&9 &
  else
    "$@" &
  fi
  local pid=$!
  if [[ "${have_stdin}" == "1" ]]; then
    { exec 9<&-; } 2>/dev/null || true
  fi
  (
    sleep "${secs}"
    stop_process "${pid}"
  ) &
  local watchdog=$!
  local rc=0
  wait "${pid}" || rc=$?
  # Kill the watchdog *and its sleep child*: killing only the subshell would
  # orphan the `sleep`, leaving one reparented sleep per command.
  kill_tree TERM "${watchdog}"
  wait "${watchdog}" 2>/dev/null || true
  return "${rc}"
}

# Runs a command under the timeout, sending combined output to `${log}` and
# returning the command's exit status.
capture() {
  local log="$1" secs="$2"
  shift 2
  local rc=0
  run_timeout "${secs}" "$@" >"${log}" 2>&1 || rc=$?
  return "${rc}"
}

# A stable digest of every file in a directory (POSIX cksum).
store_digest() {
  find "$1" -type f -exec cksum {} + 2>/dev/null | sort
}

slugify() {
  printf '%s' "$1" | tr '/: ' '---'
}

note() { printf '\n== %s\n' "$*"; }
pass() { echo "ok   $*"; }
problem() { echo "FAIL $*"; fail=1; }

# Classifies one already-captured test log.
inspect() {
  local label="$1" log="$2" rc="$3"
  local bad leaks
  bad="$(grep -ac '+++ bad free' "${log}" || true)"
  leaks="$(grep -ac '+++ leak' "${log}" || true)"
  if [[ "${rc}" -eq 124 || "${rc}" -eq 137 || "${rc}" -eq 143 ]]; then
    problem "${label}: timed out or killed (rc=${rc}) (${log})"
  elif [[ "${rc}" -ne 0 ]]; then
    problem "${label}: test failure (rc=${rc}) (${log})"
    grep -aE "test failed|\[ERROR\]|^ - " "${log}" | head -20 || true
  elif grep -qaE "test failed|Signal caught|\[FATAL\]" "${log}"; then
    problem "${label}: test failure (${log})"
    grep -aE "^ - |\[ERROR\]" "${log}" | head -20 || true
  elif [[ "${bad}" -gt 0 ]]; then
    problem "${label}: ${bad} bad free(s) (${log})"
  elif [[ "${strict_leaks}" == "1" && "${leaks}" -gt 0 ]]; then
    problem "${label}: ${leaks} leak(s) (${log})"
  else
    pass "${label} (leaks=${leaks})"
  fi
}

run_unit() {
  note "unit tests"
  local pkg log rc
  for pkg in "${packages[@]}"; do
    log="${log_dir}/$(slugify "unit:${pkg}").log"
    rc=0
    capture "${log}" "${test_timeout}" "${odin_bin}" test "${pkg}" || rc=$?
    inspect "unit:${pkg}" "${log}" "${rc}"
  done
  if command -v node >/dev/null 2>&1 && [[ -f "${repo_root}/host/web/sync-client.test.mjs" ]]; then
    log="${log_dir}/unit-sync-client.log"
    rc=0
    client_tests=("${repo_root}/host/web/sync-client.test.mjs")
    if [[ -f "${repo_root}/host/web/editor-client.test.mjs" ]]; then
      client_tests+=("${repo_root}/host/web/editor-client.test.mjs")
    fi
    capture "${log}" "${test_timeout}" node --test "${client_tests[@]}" || rc=$?
    inspect "unit:client-js" "${log}" "${rc}"
  fi
}

run_tsan() {
  local supp="${repo_root}/scripts/tsan.supp"
  if [[ ! -f "${supp}" ]]; then
    echo "missing ${supp}" >&2
    exit 1
  fi
  export TSAN_OPTIONS="suppressions=${supp}"
  note "ThreadSanitizer unit tests"
  local pkg log rc races
  for pkg in "${packages[@]}"; do
    # One test thread avoids cross-test address-reuse false positives; the
    # kernel/runtime internal concurrency tests still run.
    log="${log_dir}/$(slugify "tsan:${pkg}").log"
    rc=0
    capture "${log}" "${tsan_timeout}" "${odin_bin}" test "${pkg}" \
      -sanitize:thread -define:ODIN_TEST_THREADS=1 || rc=$?
    races="$(grep -ac 'SUMMARY: ThreadSanitizer' "${log}" || true)"
    if [[ "${rc}" -ne 0 ]]; then
      problem "tsan:${pkg}: test failure (rc=${rc}) (${log})"
    elif [[ "${races}" -gt 0 ]]; then
      problem "tsan:${pkg}: ${races} race report(s) (${log})"
      grep -a 'SUMMARY: ThreadSanitizer' "${log}" | sed -E 's/.* in //' \
        | sort | uniq -c | sort -rn | head -5
    else
      pass "tsan:${pkg}"
    fi
  done
  unset TSAN_OPTIONS
}

build_tools() {
  note "build tools"
  local tool
  for tool in filein repl webhost parse_corpus owlstream; do
    if run_timeout "${test_timeout}" "${odin_bin}" build "tools/${tool}" \
      -out:"${bin_dir}/${tool}"; then
      pass "build:${tool}"
    else
      problem "build:${tool}"
    fi
  done
}

run_web_smoke() {
  local webhost="$1"
  local tmp
  tmp="$(mktemp -d)"
  cleanup_paths+=("${tmp}")
  local log="${tmp}/server.log"
  local args=()
  for file in "${mud_fileins[@]}"; do
    args+=(--filein "${file}")
  done
  # Background the server directly (not through run_timeout) so the PID we
  # track is the server itself and stopping it cannot orphan anything.
  "${webhost}" "${args[@]}" --store "${tmp}/db" \
    --bind 127.0.0.1:0 --sync-client host/web/sync-client.js >"${log}" 2>&1 &
  local pid=$!
  cleanup_pids+=("${pid}")
  local base="" rc=0 i
  for ((i = 0; i < 150; i++)); do
    base="$(grep -oE 'http://127.0.0.1:[0-9]+' "${log}" | head -1 || true)"
    [[ -n "${base}" ]] && break
    kill -0 "${pid}" 2>/dev/null || break
    sleep 0.1
  done
  if [[ -z "${base}" ]]; then
    echo "webhost did not start:" >&2
    cat "${log}" >&2 || true
    rc=1
  else
    check_code() {
      local what="$1" expected="$2"
      shift 2
      local code
      code="$(curl -s --max-time "${test_timeout}" -o /dev/null \
        -w '%{http_code}' "$@" || true)"
      if [[ "${code}" == "${expected}" ]]; then
        pass "web-smoke:${what}"
      else
        echo "web-smoke:${what}: expected ${expected}, got ${code}" >&2
        rc=1
      fi
    }
    check_code healthz 200 "${base}/healthz"
    check_code mud 200 "${base}/mud"
    check_code login 303 -X POST -d 'login=alice&password=alice-pass' "${base}/auth/login"
    check_code bad-login 401 -X POST -d 'login=alice&password=wrong' "${base}/auth/login"
    check_code traversal 404 --path-as-is "${base}/mud/../../etc/passwd"
  fi
  stop_process "${pid}"
  wait "${pid}" 2>/dev/null || true
  rm -rf "${tmp}"
  return "${rc}"
}

# The bycycle ontology (mirror of ONTOLOGY in scripts/bycycle-load.sh).
bycycle_fileins=(
  apps/bycycle/00_schema.mica
  apps/bycycle/10_taxonomy.mica
  apps/bycycle/20_constraints.mica
  apps/bycycle/30_graph.mica
  apps/shared/retrieval.mica
)
owl_fixture=tools/owlstream/testdata/fixture.owl

# Everything the owlstream fixture should load, one query per line.
owl_fingerprint_queries=(
  'return Label(#guid_Mx4rTestAnimalGuid000001, ?l)'
  'return Alias(#guid_Mx4rTestAnimalGuid000001, ?l)'
  'return WikiName(#guid_Mx4rTestAnimalGuid000001, ?l)'
  'return WikiURL(#guid_Mx4rTestAnimalGuid000001, ?l)'
  'return Comment(#guid_Mx4rTestAnimalGuid000001, ?l)'
  'return Label(#guid_Mx4rTestDogGuid000000002, ?l)'
  'return Comment(#guid_Mx4rTestDogGuid000000002, ?l)'
  'return len(Subsumes(?a, ?d))'
  'return len(InstanceOf(?i, ?c))'
  'return len(InconsistentWith(?x, ?a, ?b))'
  'return len(GuidOf(?i, ?g))'
  'return len(CanRetrieveSubject(#bycycle_reader, ?s))'
)
owl_fingerprint_expected='[:l] {["Animal"]}
[:l] {["Beast"]}
[:l] {["Animal"]}
[:l] {["http://en.wikipedia.org/wiki/Animal"]}
[:l] {["A <b>living</b> thing &amp; more"]}
[:l] {["Dog & kin"]}
[:l] {["Canines"]}
1
3
2
4
4'

# Prints the fixture queries' answers against a store, one per line.
owl_fingerprint() {
  local filein="$1" store="$2" query
  for query in "${owl_fingerprint_queries[@]}"; do
    run_timeout "${test_timeout}" "${filein}" --store "${store}" --eval "${query}" 2>&1 || true
  done
}

# owlstream: load the fixture in one pass, and again in --limit slices that
# resume; both must match the expected facts, a rerun must change nothing, and
# a failed load must not leave the store locked.
run_owlstream_checks() {
  local filein="$1" owlstream="$2" tmp="$3" store out
  for store in "${tmp}/owl-once" "${tmp}/owl-resumed"; do
    run_timeout "${test_timeout}" "${filein}" --store "${store}" --unit bycycle \
      "${bycycle_fileins[@]}" --checkpoint >/dev/null
  done

  if run_timeout "${test_timeout}" "${owlstream}" --owl "${owl_fixture}" \
    --store "${tmp}/owl-once" --commit-batch 3 --checkpoint \
    --retrieval-actor bycycle_reader >"${tmp}/owl-once.log" 2>&1; then
    out="$(owl_fingerprint "${filein}" "${tmp}/owl-once")"
    if [[ "${out}" == "${owl_fingerprint_expected}" ]]; then
      pass "integration:owlstream-load"
    else
      problem "integration:owlstream-load: unexpected facts"
      diff <(echo "${owl_fingerprint_expected}") <(echo "${out}") || true
    fi
  else
    problem "integration:owlstream-load (${tmp}/owl-once.log)"
  fi

  # --limit counts subjects scanned this run: 2 + 1 + the rest.
  local limit ok=1
  for limit in 2 1 0; do
    run_timeout "${test_timeout}" "${owlstream}" --owl "${owl_fixture}" \
      --store "${tmp}/owl-resumed" --commit-batch 3 --checkpoint --limit "${limit}" \
      --retrieval-actor bycycle_reader >"${tmp}/owl-resumed.log" 2>&1 || ok=0
  done
  out="$(owl_fingerprint "${filein}" "${tmp}/owl-resumed")"
  if [[ "${ok}" -eq 1 && "${out}" == "${owl_fingerprint_expected}" ]] \
    && grep -q "resuming at byte" "${tmp}/owl-resumed.log"; then
    pass "integration:owlstream-resume"
  else
    problem "integration:owlstream-resume (${tmp}/owl-resumed.log)"
    diff <(echo "${owl_fingerprint_expected}") <(echo "${out}") || true
  fi

  # A rerun over a fully loaded store resumes at the end and adds nothing.
  run_timeout "${test_timeout}" "${owlstream}" --owl "${owl_fixture}" \
    --store "${tmp}/owl-once" --commit-batch 3 --retrieval-actor bycycle_reader \
    >"${tmp}/owl-rerun.log" 2>&1 || true
  out="$(owl_fingerprint "${filein}" "${tmp}/owl-once")"
  if [[ "${out}" == "${owl_fingerprint_expected}" ]] \
    && grep -q "^done: 4 subjects, 0 triples" "${tmp}/owl-rerun.log"; then
    pass "integration:owlstream-rerun"
  else
    problem "integration:owlstream-rerun (${tmp}/owl-rerun.log)"
  fi

  # A store without the ontology fails the load; the store must stay usable.
  printf 'make_relation(:Color, 1)\n' > "${tmp}/owl-color.mica"
  run_timeout "${test_timeout}" "${filein}" --store "${tmp}/owl-bare" \
    --checkpoint "${tmp}/owl-color.mica" >/dev/null
  if run_timeout "${test_timeout}" "${owlstream}" --owl "${owl_fixture}" \
    --store "${tmp}/owl-bare" >"${tmp}/owl-bare.log" 2>&1; then
    problem "integration:owlstream-failure: load without the ontology succeeded"
  elif [[ -e "${tmp}/owl-bare/LOCK" ]]; then
    problem "integration:owlstream-failure: failed load left the store locked"
  else
    pass "integration:owlstream-failure"
  fi
}

run_integration() {
  build_tools
  note "integration"
  local filein="${bin_dir}/filein" repl="${bin_dir}/repl" webhost="${bin_dir}/webhost"
  local tmp
  tmp="$(mktemp -d)"
  cleanup_paths+=("${tmp}")

  # filein: load and query a checkpointed store.
  if run_timeout "${test_timeout}" "${filein}" --store "${tmp}/db" --unit equipment \
    --checkpoint apps/examples/equipment-service.mica >/dev/null; then
    pass "integration:filein-load"
  else
    problem "integration:filein-load"
  fi
  capture "${tmp}/eval.log" "${test_timeout}" "${filein}" --store "${tmp}/db" \
    --eval 'return ReadyForUse(#sensor_17)' || true
  local out
  out="$(cat "${tmp}/eval.log")"
  if [[ "${out}" == "true" || "${out}" == "false" ]]; then
    pass "integration:filein-eval"
  else
    problem "integration:filein-eval: expected a boolean, got '${out}'"
  fi

  # A checkpoint after a store boot must complete (regression: reconstruction
  # advanced the version without writing the log, so the checkpoint waited for
  # records that never arrived).
  if run_timeout 30 "${filein}" --store "${tmp}/db" \
    --checkpoint apps/examples/equipment-service.mica >/dev/null 2>&1; then
    pass "integration:checkpoint-after-boot"
  else
    problem "integration:checkpoint-after-boot (timeout or error)"
  fi

  # Read-only evals must not grow the store.
  local before after
  before="$(store_digest "${tmp}/db")"
  run_timeout "${test_timeout}" "${filein}" --store "${tmp}/db" --eval 'return 1' >/dev/null
  run_timeout "${test_timeout}" "${filein}" --store "${tmp}/db" --eval 'return 2' >/dev/null
  after="$(store_digest "${tmp}/db")"
  if [[ "${before}" == "${after}" ]]; then
    pass "integration:read-only-eval"
  else
    problem "integration:read-only-eval: store changed across read-only evals"
  fi

  # A mutation survives a restart (fresh store; booting an existing store
  # ignores new fileins).
  printf 'make_relation(:Color, 1)\n' > "${tmp}/color.mica"
  run_timeout "${test_timeout}" "${filein}" --store "${tmp}/db2" \
    --checkpoint "${tmp}/color.mica" >/dev/null
  run_timeout "${test_timeout}" "${filein}" --store "${tmp}/db2" \
    --eval 'assert Color(:red)' >/dev/null
  capture "${tmp}/mutation.log" "${test_timeout}" "${filein}" --store "${tmp}/db2" \
    --eval 'return Color(:red)' || true
  out="$(cat "${tmp}/mutation.log")"
  if [[ "${out}" == "true" ]]; then
    pass "integration:store-mutation"
  else
    problem "integration:store-mutation: expected true, got '${out}'"
  fi

  run_owlstream_checks "${filein}" "${bin_dir}/owlstream" "${tmp}"

  # REPL evaluates a line.
  printf '1 + 1\n' > "${tmp}/repl.in"
  capture "${tmp}/repl.log" 30 "${repl}" < "${tmp}/repl.in" || true
  if grep -q "mica> 2" "${tmp}/repl.log"; then
    pass "integration:repl"
  else
    problem "integration:repl"
    tail -5 "${tmp}/repl.log" || true
  fi

  if ! command -v curl >/dev/null 2>&1; then
    echo "skip integration:web-smoke (curl not found)"
  elif run_web_smoke "${webhost}"; then
    pass "integration:web-smoke"
  else
    problem "integration:web-smoke"
  fi

  rm -rf "${tmp}"
}

mode="${1:-unit}"
case "${mode}" in
  unit)        run_unit ;;
  integration) run_integration ;;
  tsan)        run_tsan ;;
  all)         run_unit; run_integration ;;
  *)
    echo "usage: scripts/test.sh [unit|integration|tsan|all]" >&2
    exit 2
    ;;
esac

if [[ "${fail}" -ne 0 ]]; then
  echo "test suite: FAILED"
  exit 1
fi
echo "test suite: OK (${mode})"
