#!/usr/bin/env bash
# PsiTransfer deterministic seed definitions + seed/verify helpers.
# Sourced by ./tester-env (cmd_seed / cmd_verify). Not run directly.
# Fixed sids (12 hex chars, like the frontend randomSid), fixed passwords,
# fixed contents, fixed retentions. File keys are server-generated UUIDs,
# so assertions use names/sizes/retentions, never keys.

# Bucket 1: open, 2 files, 1-week retention (default).
SEED_OPEN_SID="a1b2c3d4e5f6"
SEED_OPEN_RETENTION="604800"
# Bucket 2: password-protected, 1 file, 1-day retention.
SEED_LOCKED_SID="9f8e7d6c5b4a"
SEED_LOCKED_PASSWORD="share-secret-7"
SEED_LOCKED_RETENTION="86400"
# Bucket 3: open, 1 file, 1-hour retention (exercises short retention/expiry metadata).
SEED_SHORT_SID="012345abcdef"
SEED_SHORT_RETENTION="3600"

SEED_SIDS="${SEED_OPEN_SID} ${SEED_LOCKED_SID} ${SEED_SHORT_SID}"

seed_b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

# Stage fixed fixture files into $1 (a directory). Prints nothing.
seed_stage_fixtures() {
  local dir="$1"
  printf '%s\n' \
    'Launch v2.4.4 - release notes' \
    '- Fixed tus resume on Node 24' \
    '- Admin bucket list masks passwords' \
    '- Zip/tar.gz archive downloads verified' \
    'Full checklist in launch-checklist.txt' \
    > "${dir}/release-notes.txt"
  printf '%s\n' \
    'Launch checklist' \
    '[done] Build docker image' \
    '[done] Smoke-test upload page' \
    '[todo] Share links with reviewers' \
    'Owner: release team' \
    > "${dir}/launch-checklist.txt"
  printf '%s\n' \
    'item,owner,amount' \
    'hosting,ops,120' \
    'licenses,eng,340' \
    'travel,sales,860' \
    > "${dir}/budget-review.csv"
  printf '%s\n' \
    'Quick memo - expires in one hour.' \
    'Reviewer link for the launch assets.' \
    > "${dir}/one-hour-memo.txt"
}

# Upload one file via the tus protocol. Args: base sid name path retention [password]
seed_tus_upload() {
  local base="$1" sid="$2" name="$3" path="$4" retention="$5" password="${6:-}"
  local meta="name $(seed_b64 "${name}"),sid $(seed_b64 "${sid}"),retention $(seed_b64 "${retention}")"
  if [[ -n "${password}" ]]; then
    meta="${meta},password $(seed_b64 "${password}")"
  fi
  local len loc code
  len="$(wc -c < "${path}" | tr -d ' ')"
  loc="$(curl -sS -D - -o /dev/null -X POST "${base}/files" \
    -H "Tus-Resumable: 1.0.0" \
    -H "Upload-Length: ${len}" \
    -H "Upload-Metadata: ${meta}" | grep -i '^location:' | tr -d '\r' | awk '{print $2}')"
  [[ -n "${loc}" ]] || { echo "SEED FAILED: tus POST for ${sid}/${name} returned no Location"; return 1; }
  code="$(curl -sS -o /dev/null -w "%{http_code}" -X PATCH "${base}${loc}" \
    -H "Tus-Resumable: 1.0.0" \
    -H "Content-Type: application/offset+octet-stream" \
    -H "Upload-Offset: 0" --data-binary "@${path}")"
  [[ "${code}" == "204" ]] || { echo "SEED FAILED: tus PATCH for ${sid}/${name} returned ${code}, expected 204"; return 1; }
  echo "seeded ${sid}/${name} (${len} bytes, retention ${retention})"
}

# Names already present in a bucket (via share metadata endpoint). Empty when missing.
seed_bucket_names() {
  local base="$1" sid="$2" password="${3:-}"
  local args=(-sS -o /dev/null -w "%{http_code}")
  if [[ -n "${password}" ]]; then args+=(-H "x-download-pass: ${password}"); fi
  local code
  code="$(curl "${args[@]}" "${base}/${sid}.json")"
  [[ "${code}" == "200" ]] || return 0
  if [[ -n "${password}" ]]; then
    curl -sS -H "x-download-pass: ${password}" "${base}/${sid}.json" | jq -r '.items[].metadata.name'
  else
    curl -sS "${base}/${sid}.json" | jq -r '.items[].metadata.name'
  fi
}

# Idempotent: upload only files whose names are not already in the bucket.
seed_all() {
  local base="$1"
  local workdir names
  workdir="$(mktemp -d)"
  seed_stage_fixtures "${workdir}"
  # Bucket 1: open, 2 files.
  names="$(seed_bucket_names "${base}" "${SEED_OPEN_SID}")"
  [[ "${names}" == *"release-notes.txt"* ]] || seed_tus_upload "${base}" "${SEED_OPEN_SID}" "release-notes.txt" "${workdir}/release-notes.txt" "${SEED_OPEN_RETENTION}"
  [[ "${names}" == *"launch-checklist.txt"* ]] || seed_tus_upload "${base}" "${SEED_OPEN_SID}" "launch-checklist.txt" "${workdir}/launch-checklist.txt" "${SEED_OPEN_RETENTION}"
  # Bucket 2: password-protected, 1 file.
  names="$(seed_bucket_names "${base}" "${SEED_LOCKED_SID}" "${SEED_LOCKED_PASSWORD}")"
  [[ "${names}" == *"budget-review.csv"* ]] || seed_tus_upload "${base}" "${SEED_LOCKED_SID}" "budget-review.csv" "${workdir}/budget-review.csv" "${SEED_LOCKED_RETENTION}" "${SEED_LOCKED_PASSWORD}"
  # Bucket 3: open, short retention, 1 file.
  names="$(seed_bucket_names "${base}" "${SEED_SHORT_SID}")"
  [[ "${names}" == *"one-hour-memo.txt"* ]] || seed_tus_upload "${base}" "${SEED_SHORT_SID}" "one-hour-memo.txt" "${workdir}/one-hour-memo.txt" "${SEED_SHORT_RETENTION}"
  rm -rf "${workdir}"
  echo "==> Seed complete: 3 buckets, 4 files."
}

# Assert seeded state. Args: base admin_pass. Returns 0 on success.
verify_all() {
  local base="$1" admin_pass="$2"
  local workdir fail=0
  workdir="$(mktemp -d)"
  seed_stage_fixtures "${workdir}"
  check() {  # check <desc> <command...>
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "  ok: ${desc}"; else echo "  MISSING/WRONG: ${desc}"; fail=1; fi
  }
  echo "==> Verifying upload page..."
  check "upload page served" bash -c "curl -fsS '${base}/' | grep -qi 'psitransfer'"
  echo "==> Verifying admin bucket list (exactly 3 seeded buckets)..."
  local admin
  admin="$(curl -sS -H "x-passwd: ${admin_pass}" "${base}/admin/data.json")"
  [[ "$(printf '%s' "${admin}" | jq -r 'keys | sort | join(",")')" == "012345abcdef,9f8e7d6c5b4a,a1b2c3d4e5f6" ]] \
    && echo "  ok: bucket sids match seed" \
    || { echo "  MISSING/WRONG: bucket sids: $(printf '%s' "${admin}" | jq -c 'keys')"; fail=1; }
  echo "==> Verifying bucket contents (names, sizes, retentions)..."
  local spec sid retention name size
  while IFS='|' read -r sid retention name; do
    size="$(wc -c < "${workdir}/${name}" | tr -d ' ')"
    if [[ "${sid}" == "${SEED_LOCKED_SID}" ]]; then
      check "${sid}/${name} size ${size}" bash -c "curl -sS -H 'x-download-pass: ${SEED_LOCKED_PASSWORD}' '${base}/${sid}.json' | jq -e --arg n '${name}' --argjson s ${size} '[.items[] | select(.metadata.name==\$n and .size==\$s)] | length==1'"
      check "${sid}/${name} retention ${retention}" bash -c "curl -sS -H 'x-download-pass: ${SEED_LOCKED_PASSWORD}' '${base}/${sid}.json' | jq -e --arg n '${name}' --arg r '${retention}' '[.items[] | select(.metadata.name==\$n and .metadata.retention==\$r)] | length==1'"
    else
      check "${sid}/${name} size ${size}" bash -c "curl -sS '${base}/${sid}.json' | jq -e --arg n '${name}' --argjson s ${size} '[.items[] | select(.metadata.name==\$n and .size==\$s)] | length==1'"
      check "${sid}/${name} retention ${retention}" bash -c "curl -sS '${base}/${sid}.json' | jq -e --arg n '${name}' --arg r '${retention}' '[.items[] | select(.metadata.name==\$n and .metadata.retention==\$r)] | length==1'"
    fi
    check "${sid}/${name} upload complete" bash -c "curl -sS -H 'x-passwd: ${admin_pass}' '${base}/admin/data.json' | jq -e --arg sid '${sid}' --arg n '${name}' '[.[\$sid][] | select(.metadata.name==\$n and (has(\"isPartial\")|not))] | length==1'"
  done <<SPEC
${SEED_OPEN_SID}|${SEED_OPEN_RETENTION}|release-notes.txt
${SEED_OPEN_SID}|${SEED_OPEN_RETENTION}|launch-checklist.txt
${SEED_LOCKED_SID}|${SEED_LOCKED_RETENTION}|budget-review.csv
${SEED_SHORT_SID}|${SEED_SHORT_RETENTION}|one-hour-memo.txt
SPEC
  echo "==> Verifying password gate on locked bucket..."
  check "locked bucket rejects anonymous metadata" bash -c "test \"\$(curl -sS -o /dev/null -w '%{http_code}' '${base}/${SEED_LOCKED_SID}.json')\" = 401"
  check "locked bucket rejects wrong password" bash -c "test \"\$(curl -sS -o /dev/null -w '%{http_code}' -H 'x-download-pass: wrong-pass' '${base}/${SEED_LOCKED_SID}.json')\" = 401"
  check "locked bucket masks password hash in admin view" bash -c "curl -sS -H 'x-passwd: ${admin_pass}' '${base}/admin/data.json' | jq -e '.[\"${SEED_LOCKED_SID}\"] | all(.metadata._password==true)'"
  echo "==> Verifying share pages + one file download..."
  check "open share page served" bash -c "curl -fsS '${base}/${SEED_OPEN_SID}' | grep -qi 'psitransfer'"
  check "locked share page served" bash -c "curl -fsS '${base}/${SEED_LOCKED_SID}' | grep -qi 'psitransfer'"
  local key code body
  key="$(curl -sS "${base}/${SEED_SHORT_SID}.json" | jq -r '.items[0].key')"
  code="$(curl -sS -o "${workdir}/dl.txt" -w "%{http_code}" "${base}/files/${SEED_SHORT_SID}++${key}")"
  [[ "${code}" == "200" ]] && cmp -s "${workdir}/dl.txt" "${workdir}/one-hour-memo.txt" \
    && echo "  ok: single-file download byte-identical" \
    || { echo "  MISSING/WRONG: single-file download (http ${code})"; fail=1; }
  rm -rf "${workdir}"
  if [[ "${fail}" == "0" ]]; then echo "==> Verify OK: seeded state matches."; else echo "==> Verify FAILED"; fi
  return "${fail}"
}
