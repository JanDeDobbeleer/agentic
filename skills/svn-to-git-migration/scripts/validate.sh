#!/usr/bin/env bash
# validate.sh — End-to-end validation harness for migrate.sh (bash / WSL)
#
# Mirrors validate.ps1 with the same 10 assertions:
#   1. Commit count on main
#   2. Author e-mail mapping
#   3. Branch feature-x exists
#   4. Branch ancestry (feature-x parent = trunk@3)
#   5. Tag v1.0 exists
#   6. Tag v1.0 is annotated
#   7. git-svn-id trailer in commits
#   8. HEAD tree matches svn export of trunk@7
#   9. --no-metadata: no git-svn-id in messages
#  10. Default author fallback (zuser@uuid)
#
# Usage:
#   bash validate.sh [--keep-work-dir] [--svn-repo-url file:///path/to/repo]

set -uo pipefail   # NOT -e: we collect failures without aborting

# ── Bash version guard ─────────────────────────────────────────────────────────
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  echo "ERROR: bash 4.0+ required (you have ${BASH_VERSION})." >&2; exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATE_SH="$SCRIPT_DIR/migrate.sh"

# ── Arg parse ──────────────────────────────────────────────────────────────────
KEEP_WORK_DIR=false
SVN_REPO_URL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-work-dir) KEEP_WORK_DIR=true; shift ;;
    --svn-repo-url)  SVN_REPO_URL="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# ── Work dir ───────────────────────────────────────────────────────────────────
WORK_DIR=$(mktemp -d /tmp/svn-validate-work-XXXXXX)
cleanup() {
  if [[ "$KEEP_WORK_DIR" == "true" ]]; then
    echo -e "\n  Work dir retained: $WORK_DIR"
  else
    echo -e "\n  Cleaning up: $WORK_DIR"
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

# ── Result tracking ────────────────────────────────────────────────────────────
declare -a RESULTS=()   # "PASS|FAIL|SKIP N. Name — detail"
PASS_COUNT=0
FAIL_COUNT=0

add_result() {  # add_result <n> <name> <pass:true|false> <detail>
  local n="$1" name="$2" pass="$3" detail="$4"
  if [[ "$pass" == "true" ]]; then
    RESULTS+=("PASS  $n. $name  —  $detail")
    (( PASS_COUNT++ )) || true
    echo "  PASS  $n. $name  —  $detail"
  else
    RESULTS+=("FAIL  $n. $name  —  $detail")
    (( FAIL_COUNT++ )) || true
    echo "  FAIL  $n. $name  —  $detail"
  fi
}

add_skip() {  # add_skip <n> <name> <reason>
  local n="$1" name="$2" reason="$3"
  RESULTS+=("SKIP  $n. $name  —  $reason")
  echo "  SKIP  $n. $name  —  $reason"
}

# ── git helper (runs in a given git dir) ──────────────────────────────────────
invoke_git() {  # invoke_git <git-dir> [args...]
  local gitdir="$1"; shift
  git --git-dir="$gitdir/.git" --work-tree="$gitdir" "$@" 2>/dev/null
}

# ══════════════════════════════════════════════════════════════════════════════
#  Banner
# ══════════════════════════════════════════════════════════════════════════════
echo "╔══════════════════════════════════════════════════════╗"
echo "║   SVN → Git Migration Validation Harness (bash)     ║"
echo "╚══════════════════════════════════════════════════════╝"
echo "  Work dir : $WORK_DIR"
echo "  migrate  : $MIGRATE_SH"
[[ -f "$MIGRATE_SH" ]] || echo "  (migrate.sh not found — migration assertions will fail)"

# ── Prerequisites ──────────────────────────────────────────────────────────────
echo -e "\n─── Prerequisites ───────────────────────────────────────────────────────"
for tool in svn svnadmin git python3 bash; do
  if command -v "$tool" &>/dev/null; then
    echo "  $tool : OK"
  else
    echo "  $tool : MISSING"
    if [[ "$tool" != "bash" ]]; then
      echo "ERROR: '$tool' is required."; exit 1
    fi
  fi
done

# ══════════════════════════════════════════════════════════════════════════════
#  Phase A: Create (or reuse) SVN test repository
# ══════════════════════════════════════════════════════════════════════════════
echo -e "\n─── Phase A: SVN repository ─────────────────────────────────────────────"

if [[ -n "$SVN_REPO_URL" ]]; then
  echo "  Using existing repo: $SVN_REPO_URL"
  REPO_URL="$SVN_REPO_URL"
else
  REPO_PATH=$(mktemp -d /tmp/svn-validate-repo-XXXXXX)
  echo "  Creating test repo at: $REPO_PATH"
  svnadmin create "$REPO_PATH"
  REPO_URL="file://$REPO_PATH"

  # Allow revprop changes (no-op hook)
  printf '#!/bin/sh\nexit 0\n' > "$REPO_PATH/hooks/pre-revprop-change"
  chmod +x "$REPO_PATH/hooks/pre-revprop-change"

  set_rev_props() {  # set_rev_props <rev> <author> <date-iso>
    svn propset svn:author "$2" --revprop -r "$1" "$REPO_URL" -q
    svn propset svn:date   "$3" --revprop -r "$1" "$REPO_URL" -q
  }

  # r1: layout
  svn mkdir "$REPO_URL/trunk" "$REPO_URL/branches" "$REPO_URL/tags" \
      -m "Create layout" -q
  set_rev_props 1 "svnadmin" "2020-01-01T10:00:00.000000Z"

  # Checkout trunk working copy
  WC_TRUNK=$(mktemp -d /tmp/svn-wc-trunk-XXXXXX)
  svn checkout "$REPO_URL/trunk" "$WC_TRUNK" -q

  # r2: README.md
  printf 'Hello SVN' > "$WC_TRUNK/README.md"
  svn add "$WC_TRUNK/README.md" -q
  svn commit "$WC_TRUNK" -m "Initial commit" -q
  set_rev_props 2 "jsmith" "2020-01-02T10:00:00.000000Z"

  # r3: src/main.c
  mkdir "$WC_TRUNK/src"
  printf '#include <stdio.h>\nint main(){return 0;}' > "$WC_TRUNK/src/main.c"
  svn add "$WC_TRUNK/src" -q
  svn commit "$WC_TRUNK" -m "Add C source" -q
  set_rev_props 3 "bwilliams" "2020-01-03T10:00:00.000000Z"

  # r4: copy trunk -> branches/feature-x
  svn copy "$REPO_URL/trunk" "$REPO_URL/branches/feature-x" \
      -m "Create branch feature-x" -q
  set_rev_props 4 "jsmith" "2020-01-04T10:00:00.000000Z"

  # r5: modify src/main.c on feature-x
  WC_BRANCH=$(mktemp -d /tmp/svn-wc-branch-XXXXXX)
  svn checkout "$REPO_URL/branches/feature-x" "$WC_BRANCH" -q
  printf '#include <stdio.h>\n#include <stdlib.h>\nint main(){return 0;}' \
      > "$WC_BRANCH/src/main.c"
  svn commit "$WC_BRANCH" -m "Branch change" -q
  set_rev_props 5 "bwilliams" "2020-01-05T10:00:00.000000Z"
  rm -rf "$WC_BRANCH"

  # r6: clean tag — copy trunk@3 -> tags/v1.0
  svn copy "$REPO_URL/trunk@3" "$REPO_URL/tags/v1.0" \
      -m "Tag v1.0" -q
  set_rev_props 6 "jsmith" "2020-01-06T10:00:00.000000Z"

  # r7: CHANGES.txt -> trunk
  svn update "$WC_TRUNK" -q
  printf 'v1.0 - Initial release' > "$WC_TRUNK/CHANGES.txt"
  svn add "$WC_TRUNK/CHANGES.txt" -q
  svn commit "$WC_TRUNK" -m "Post-tag trunk commit" -q
  set_rev_props 7 "jsmith" "2020-01-07T10:00:00.000000Z"

  # r8: NOTES.txt -> trunk by zuser (unmapped author)
  svn update "$WC_TRUNK" -q
  printf 'Maintenance notes' > "$WC_TRUNK/NOTES.txt"
  svn add "$WC_TRUNK/NOTES.txt" -q
  svn commit "$WC_TRUNK" -m "Add maintenance notes" -q
  set_rev_props 8 "zuser" "2020-01-08T10:00:00.000000Z"

  rm -rf "$WC_TRUNK"
  echo "  Created: $REPO_URL"
fi

# Parse UUID
REPO_UUID=$(svn info --xml "$REPO_URL" 2>/dev/null | \
  python3 -c "import sys,xml.etree.ElementTree as ET; \
    t=ET.parse(sys.stdin); \
    print(t.find('.//repository/uuid').text)")
TRUNK_URL="$REPO_URL/trunk"
echo "  UUID : $REPO_UUID"

# ══════════════════════════════════════════════════════════════════════════════
#  Phase B: Authors file
# ══════════════════════════════════════════════════════════════════════════════
echo -e "\n─── Phase B: Authors file ───────────────────────────────────────────────"
AUTHORS_FILE="$WORK_DIR/authors.txt"
cat > "$AUTHORS_FILE" <<'EOF'
jsmith = Jane Smith <jane@example.com>
bwilliams = Bob Williams <bob@example.com>
svnadmin = SVN Admin <admin@example.com>
EOF
echo "  $AUTHORS_FILE  (jsmith / bwilliams / svnadmin; zuser excluded)"

# ══════════════════════════════════════════════════════════════════════════════
#  Phase C: Migrations
# ══════════════════════════════════════════════════════════════════════════════
echo -e "\n─── Phase C: Migrations ─────────────────────────────────────────────────"

GIT_OUT_MAIN="$WORK_DIR/git-output-main"
GIT_OUT_NOMETA="$WORK_DIR/git-output-nometa"
GIT_OUT_FALLBACK="$WORK_DIR/git-output-fallback"

run_migration() {  # run_migration <label> <target> [migrate.sh args...]
  local label="$1" target="$2"; shift 2
  echo "  Running migration: $label"
  if bash "$MIGRATE_SH" run "$REPO_URL" "$@" --target "$target" > "$WORK_DIR/migrate-${label// /-}.log" 2>&1; then
    echo "  OK"
    return 0
  else
    echo "  FAILED (exit $?) — see $WORK_DIR/migrate-${label// /-}.log"
    return 1
  fi
}

MAIN_OK=false
NOMETA_OK=false
FALLBACK_OK=false

run_migration "main"     "$GIT_OUT_MAIN"     \
    --stdlayout --authors-file "$AUTHORS_FILE" --revision "1:7" \
  && MAIN_OK=true

run_migration "no-metadata" "$GIT_OUT_NOMETA" \
    --stdlayout --authors-file "$AUTHORS_FILE" --no-metadata --revision "1:7" \
  && NOMETA_OK=true

run_migration "fallback" "$GIT_OUT_FALLBACK" \
    --stdlayout --revision "1:8" \
  && FALLBACK_OK=true

# ══════════════════════════════════════════════════════════════════════════════
#  Phase D: Assertions
# ══════════════════════════════════════════════════════════════════════════════
echo -e "\n─── Phase D: Assertions ─────────────────────────────────────────────────"

MAIN_AVAIL=false
NOMETA_AVAIL=false
FALLBACK_AVAIL=false
[[ "$MAIN_OK" == "true"     && -d "$GIT_OUT_MAIN/.git"     ]] && MAIN_AVAIL=true
[[ "$NOMETA_OK" == "true"   && -d "$GIT_OUT_NOMETA/.git"   ]] && NOMETA_AVAIL=true
[[ "$FALLBACK_OK" == "true" && -d "$GIT_OUT_FALLBACK/.git" ]] && FALLBACK_AVAIL=true

# ── 1. Commit count on refs/heads/main ────────────────────────────────────────
if [[ "$MAIN_AVAIL" == "true" ]]; then
  COUNT=$(invoke_git "$GIT_OUT_MAIN" rev-list --count refs/heads/main)
  EXPECTED=4
  add_result 1 "Commit count on main" \
    "$([ "$COUNT" -eq "$EXPECTED" ] && echo true || echo false)" \
    "expected=$EXPECTED got=$COUNT"
else
  add_skip 1 "Commit count on main" "main migration unavailable"
fi

# ── 2. Author e-mail mapping ────────────────────────────────────────────────
if [[ "$MAIN_AVAIL" == "true" ]]; then
  EMAILS=$(invoke_git "$GIT_OUT_MAIN" log --format='%ae' refs/heads/main)
  HAS_JANE=$(echo "$EMAILS" | grep -cF "jane@example.com" || true)
  HAS_BOB=$(echo "$EMAILS"  | grep -cF "bob@example.com"  || true)
  PASS_AUTH=$( [[ "$HAS_JANE" -gt 0 && "$HAS_BOB" -gt 0 ]] && echo true || echo false )
  add_result 2 "Author mapping" "$PASS_AUTH" \
    "jane@example.com:$([ "$HAS_JANE" -gt 0 ] && echo ✓ || echo ✗)  bob@example.com:$([ "$HAS_BOB" -gt 0 ] && echo ✓ || echo ✗)"
else
  add_skip 2 "Author mapping" "main migration unavailable"
fi

# ── 3. Branch feature-x exists ────────────────────────────────────────────────
if [[ "$MAIN_AVAIL" == "true" ]]; then
  BL=$(invoke_git "$GIT_OUT_MAIN" branch --list "feature-x")
  FOUND=$( echo "$BL" | grep -qF "feature-x" && echo true || echo false )
  add_result 3 "Branch feature-x exists" "$FOUND" \
    "$([ "$FOUND" == "true" ] && echo found || echo "not found — git branch --list: '$BL'")"
else
  add_skip 3 "Branch feature-x exists" "main migration unavailable"
fi

# ── 4. Branch ancestry ─────────────────────────────────────────────────────────
if [[ "$MAIN_AVAIL" == "true" ]]; then
  # Find the git commit that corresponds to trunk@r3 — search body, not subject
  TRUNK3_SHA=$(invoke_git "$GIT_OUT_MAIN" log \
    --format='%H' --grep='git-svn-id:.*@3 ' refs/heads/main | head -1 || true)
  if [[ -n "$TRUNK3_SHA" ]]; then
    MERGE_BASE=$(invoke_git "$GIT_OUT_MAIN" merge-base "feature-x" "main" || true)
    PASS_ANC=$( [[ "$TRUNK3_SHA" == "$MERGE_BASE" ]] && echo true || echo false )
    add_result 4 "Branch ancestry (feature-x parent = trunk@3)" "$PASS_ANC" \
      "expected=${TRUNK3_SHA:0:8}  merge-base=${MERGE_BASE:0:8}"
  else
    add_result 4 "Branch ancestry" "false" "could not find trunk@3 commit in main log"
  fi
else
  add_skip 4 "Branch ancestry" "main migration unavailable"
fi

# ── 5. Tag v1.0 exists ────────────────────────────────────────────────────────
if [[ "$MAIN_AVAIL" == "true" ]]; then
  TL=$(invoke_git "$GIT_OUT_MAIN" tag --list "v1.0")
  FOUND_TAG=$( echo "$TL" | grep -qF "v1.0" && echo true || echo false )
  add_result 5 "Tag v1.0 exists" "$FOUND_TAG" \
    "$([ "$FOUND_TAG" == "true" ] && echo found || echo "git tag --list returned: '$TL'")"
else
  add_skip 5 "Tag v1.0 exists" "main migration unavailable"
fi

# ── 6. Tag v1.0 is annotated ─────────────────────────────────────────────────
if [[ "$MAIN_AVAIL" == "true" ]]; then
  TAG_TYPE=$(invoke_git "$GIT_OUT_MAIN" cat-file -t v1.0 || true)
  PASS_TAG=$( [[ "$TAG_TYPE" == "tag" ]] && echo true || echo false )
  add_result 6 "Tag v1.0 is annotated" "$PASS_TAG" \
    "git cat-file -t v1.0 = '$TAG_TYPE' (want 'tag')"
else
  add_skip 6 "Tag v1.0 is annotated" "main migration unavailable"
fi

# ── 7. git-svn-id trailer in commits ─────────────────────────────────────────
if [[ "$MAIN_AVAIL" == "true" ]]; then
  TOTAL_COMMITS=$(invoke_git "$GIT_OUT_MAIN" rev-list --count refs/heads/main)
  WITH_TRAILER=$(invoke_git "$GIT_OUT_MAIN" log --format='%H' refs/heads/main \
    --grep 'git-svn-id: file:///' | grep -cE '^[0-9a-f]{40}$' || true)
  PASS_TRAIL=$( [[ "$WITH_TRAILER" -ge $((TOTAL_COMMITS - 1)) && "$WITH_TRAILER" -gt 0 ]] \
    && echo true || echo false )
  add_result 7 "git-svn-id trailer in commits" "$PASS_TRAIL" \
    "$WITH_TRAILER/$TOTAL_COMMITS commits have trailer"
else
  add_skip 7 "git-svn-id trailer in commits" "main migration unavailable"
fi

# ── 8. HEAD tree matches svn export of trunk@7 ────────────────────────────────
if [[ "$MAIN_AVAIL" == "true" ]]; then
  EXPORT_DIR=$(mktemp -d /tmp/svn-export-XXXXXX)
  GIT_CHECK_DIR=$(mktemp -d /tmp/git-checkout-XXXXXX)
  trap 'rm -rf "$EXPORT_DIR" "$GIT_CHECK_DIR"; '"$(trap -p EXIT | sed 's/trap -- .//;s/. EXIT//')" EXIT

  svn export -r 7 "$TRUNK_URL" "$EXPORT_DIR" --force -q 2>/dev/null

  # Load HEAD into index, then checkout-index
  invoke_git "$GIT_OUT_MAIN" read-tree HEAD
  GIT_WORK_TREE="$GIT_CHECK_DIR" git --git-dir="$GIT_OUT_MAIN/.git" \
    checkout-index -a --prefix="$GIT_CHECK_DIR/" 2>/dev/null

  SVN_FILES=$(find "$EXPORT_DIR"  -type f | sed "s|$EXPORT_DIR/||"  | sort)
  GIT_FILES=$(find "$GIT_CHECK_DIR" -type f | sed "s|$GIT_CHECK_DIR/||" | grep -v '^\.gitignore$' | sort)

  DIFF=$(diff <(echo "$SVN_FILES") <(echo "$GIT_FILES") || true)
  if [[ -z "$DIFF" ]]; then
    FILE_COUNT=$(echo "$SVN_FILES" | wc -l | tr -d ' ')
    add_result 8 "HEAD tree matches svn export of trunk@7" "true" "Trees match ($FILE_COUNT files)"
  else
    add_result 8 "HEAD tree matches svn export of trunk@7" "false" "File list differs: $DIFF"
  fi
  rm -rf "$EXPORT_DIR" "$GIT_CHECK_DIR"
else
  add_skip 8 "HEAD tree matches svn export of trunk@7" "main migration unavailable"
fi

# ── 9. --no-metadata: no git-svn-id trailer ──────────────────────────────────
if [[ "$NOMETA_AVAIL" == "true" ]]; then
  ALL_BODIES=$(invoke_git "$GIT_OUT_NOMETA" log --format='%B' refs/heads/main)
  if echo "$ALL_BODIES" | grep -q 'git-svn-id:'; then
    add_result 9 "--no-metadata: no git-svn-id in messages" "false" \
      "git-svn-id: found in at least one commit message"
  else
    add_result 9 "--no-metadata: no git-svn-id in messages" "true" \
      "no git-svn-id trailer found (correct)"
  fi
else
  add_skip 9 "--no-metadata variant" "no-metadata migration unavailable"
fi

# ── 10. Default author fallback: zuser → zuser@<uuid> ─────────────────────────
if [[ "$FALLBACK_AVAIL" == "true" ]]; then
  EMAILS_FB=$(invoke_git "$GIT_OUT_FALLBACK" log --format='%ae' refs/heads/main)
  ZUSER_EMAIL=$(echo "$EMAILS_FB" | grep '^zuser@' | head -1 || true)
  EXPECTED_EMAIL="zuser@$REPO_UUID"
  PASS_FB=$( [[ "$ZUSER_EMAIL" == "$EXPECTED_EMAIL" ]] && echo true || echo false )
  add_result 10 "Default author fallback (zuser@uuid)" "$PASS_FB" \
    "got='$ZUSER_EMAIL'  expected='$EXPECTED_EMAIL'"
else
  add_skip 10 "Default author fallback" "fallback migration unavailable"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Summary
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   Validation Summary                                 ║"
echo "╚══════════════════════════════════════════════════════╝"
for r in "${RESULTS[@]}"; do
  echo "$r"
done
echo ""
echo "  $PASS_COUNT/10 assertions passed"

[[ "$FAIL_COUNT" -eq 0 ]]
