#!/usr/bin/env bash
# Runs the Mica specification's evidence against omica.
#
# Usage: tools/spec-conformance/run.sh <mica-spec checkout>
#
# The specification lives in timbran-project/mica-spec; this directory is
# omica's side of it: the adapters that run `mica` and `mica-session`
# evidence through bookcheck, the profile that selects omica's `when=`
# variants, and known-failures.txt, the evidence blocks omica does not pass
# yet. The run fails on a block that fails but is not listed, and on a
# listed block that now passes (remove it from the list: the list only
# shrinks).
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
[ $# -eq 1 ] || { echo "usage: $0 <mica-spec checkout>" >&2; exit 2; }
spec="$(cd "$1" && pwd)"
profile="$(grep -v '^#' "${here}/profile" | tr '\n' ' ')"
log="$(mktemp)"
trap 'rm -f "${log}"' EXIT
RFC_PROFILE="${RFC_PROFILE:-${profile}}" \
  make -s -C "${spec}" evidence ADAPTERS="${here}/adapters" > "${log}" 2>&1
known="$(grep -v '^#' "${here}/known-failures.txt" | sed '/^$/d' | sort -u)"
# rfc-run prints one summary line per block ("FAIL <name>"); detail lines
# carry the block's temporary path instead of its name.
failed="$(awk '($1 == "FAIL" || $1 == "ERROR") && $2 !~ /^\// { print $2 }' "${log}" | sort -u)"
passed="$(awk '$1 == "PASS" { print $2 }' "${log}" | sort -u)"
unexpected="$(comm -23 <(printf '%s\n' "${failed}" | sed '/^$/d') <(printf '%s\n' "${known}"))"
stale="$(comm -12 <(printf '%s\n' "${passed}" | sed '/^$/d') <(printf '%s\n' "${known}"))"
status=0
if [ -n "${unexpected}" ]; then
  echo "unexpected failures:"; printf '  %s\n' ${unexpected}
  grep -E "^(FAIL|ERROR) /" "${log}" | grep -F -f <(printf '%s\n' ${unexpected}) | sed 's|/.*/||; s/^/    /'
  status=1
fi
if [ -n "${stale}" ]; then
  echo "now passing, remove from known-failures.txt:"; printf '  %s\n' ${stale}
  status=1
fi
echo "spec evidence: $(printf '%s\n' "${passed}" | sed '/^$/d' | wc -l | tr -d ' ') pass," \
  "$(printf '%s\n' "${failed}" | sed '/^$/d' | wc -l | tr -d ' ') fail" \
  "($(printf '%s\n' "${known}" | sed '/^$/d' | wc -l | tr -d ' ') known)"
exit "${status}"
