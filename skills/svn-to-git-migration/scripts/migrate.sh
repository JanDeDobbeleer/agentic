#!/usr/bin/env bash
# migrate.sh — Migrate SVN repository to Git without git-svn
# Algorithm parity contract: see references/algorithm.md
# Usage: migrate.sh detect|run <svn-url> [options]

# ── Bash version guard (BLOCKER) ──────────────────────────────────────────────
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  echo "ERROR: bash 4.0+ required (you have ${BASH_VERSION})." >&2
  echo "  macOS: brew install bash  (then use /usr/local/bin/bash or /opt/homebrew/bin/bash)" >&2
  exit 1
fi

set -euo pipefail

# ── Script identity ────────────────────────────────────────────────────────────
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="1.0.0"

# ── Global counters ────────────────────────────────────────────────────────────
TOTAL_COMMITS=0
TOTAL_SKIPPED=0
SVN_REVS_PROCESSED=0

# ── Repository metadata (populated in Phase 0) ────────────────────────────────
REPO_ROOT=""
REPO_UUID=""
HEAD_REV=0
START_URL=""

# ── Ref arrays — parallel indexed lists (populated in Phase 3) ────────────────
declare -a REF_NAMES=()
declare -a REF_URLS=()
declare -a REF_IS_TAG=()
declare -a REF_COPYFROM_URL=()
declare -a REF_COPYFROM_REV=()

# ── Author / summary tracking ──────────────────────────────────────────────────
declare -A AUTHOR_MAP=()
declare -a UNMAPPED_AUTHORS=()
declare -a DIRTY_TAGS=()
declare -a ORPHANED_BRANCHES=()

# ── Runtime directories (set up before cmd_run) ────────────────────────────────
WORK_DIR=""     # output git repository
INDEX_DIR=""    # SHA index files (one per SVN URL)
WORK_TEMP=""    # all ephemeral scratch space

# ── CLI options — defaults ─────────────────────────────────────────────────────
SUBCOMMAND=""
SVN_URL=""
OPT_STDLAYOUT=false
OPT_TRUNK=""
declare -a OPT_BRANCHES=()
declare -a OPT_TAGS=()
OPT_AUTHORS_FILE=""
OPT_NO_AUTHORS_FILE=false
OPT_NO_METADATA=false
OPT_IGNORE_PATHS=""
OPT_INCLUDE_PATHS=""
OPT_REVISION_START=1
OPT_REVISION_END="HEAD"
OPT_NO_SKIP_EMPTY=false
OPT_DEFAULT_BRANCH="main"
OPT_TAGS_AS_BRANCHES=false
OPT_CREATE_IGNORE=true
OPT_ENCODING=""
OPT_TARGET=""

# ── Cleanup ────────────────────────────────────────────────────────────────────
cleanup() {
  local rc=${?:-0}
  if [[ -n "${WORK_TEMP:-}" && -d "${WORK_TEMP:-}" ]]; then
    rm -rf "$WORK_TEMP" 2>/dev/null || true
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

# ── Logging ────────────────────────────────────────────────────────────────────
log_info()     { printf '[SVN→Git] %s\n'         "$*"; }
log_warn()     { printf '[SVN→Git] WARNING: %s\n' "$*" >&2; }
log_error()    { printf '[SVN→Git] ERROR: %s\n'   "$*" >&2; }
log_progress() { printf '[SVN→Git] %s\n'           "$*"; }
die()          { log_error "$*"; exit 1; }

# ── Usage ──────────────────────────────────────────────────────────────────────
usage() {
  cat <<USAGE
${SCRIPT_NAME} ${SCRIPT_VERSION} — Migrate SVN repository to Git (no git-svn required)

USAGE:
  ${SCRIPT_NAME} detect <svn-url> [options]   Preflight checks only (safe, read-only)
  ${SCRIPT_NAME} run    <svn-url> [options]   Perform full migration

LAYOUT FLAGS:
  -s, --stdlayout              Standard trunk/branches/tags layout
  -T, --trunk <path>           Custom trunk path (relative to svn-url)
  -b, --branches <path>        Custom branches container path (repeatable)
  -t, --tags <path>            Custom tags container path (repeatable)

AUTHOR FLAGS:
  -A, --authors-file <file>    Authors map file (git-svn format)
                                 jdoe = John Doe <jdoe@example.com>
                                 (no author) = Unknown <unknown@example.com>
      --no-authors-file        Accept unmapped authors (use default format)

CONTENT FLAGS:
      --ignore-paths <regex>   Exclude paths matching regex (ref-root-relative)
      --include-paths <regex>  Only include paths matching regex (ref-root-relative)
  -r, --revision <N[:M]>       Limit to SVN revision range (default: 1:HEAD)
      --encoding <enc>         Source encoding for messages (e.g. CP1252, ISO-8859-1)

COMMIT FLAGS:
      --no-metadata            Omit git-svn-id trailers from commit messages
      --no-skip-empty-commits  Preserve commits with no file changes
      --default-branch <name>  Git default branch name (default: main)
      --tags-as-branches       Treat all SVN tags as git branches
      --create-ignore          Convert svn:ignore to .gitignore (default: ON)
      --no-create-ignore       Skip svn:ignore conversion

OUTPUT FLAGS:
      --target <dir>           Output git repo directory (default: ./repo-name)

NOTES:
  • --ignore-paths and --include-paths match ref-root-relative paths
    (e.g. "src/foo.c" not "/trunk/src/foo.c"). Adjust patterns from git-svn accordingly.
  • Dirty tags (post-copy commits) become refs/heads/tags/<name>, not refs/tags/<name>.
  • Default author (no map entry): "user = user <user@REPO_UUID>" — mirrors git-svn.
  • Requires: bash 4+, svn, git 2.x, python3

EXAMPLES:
  ${SCRIPT_NAME} detect https://svn.example.com/repos/proj -s
  ${SCRIPT_NAME} run    https://svn.example.com/repos/proj -s -A authors.txt
  ${SCRIPT_NAME} run    https://svn.example.com/repos/proj \\
      -T trunk -b branches -t tags \\
      --authors-file authors.txt --default-branch main \\
      --target ./proj-git
USAGE
  exit 0
}

# ── Argument parsing ───────────────────────────────────────────────────────────
parse_args() {
  [[ $# -lt 1 ]] && usage
  case "$1" in
    --help|-h) usage ;;
    detect|run) SUBCOMMAND="$1"; shift ;;
    *) die "Unknown subcommand '${1}'. Use 'detect' or 'run'." ;;
  esac
  [[ $# -lt 1 ]] && die "Missing <svn-url> argument."
  SVN_URL="$1"; shift

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -s|--stdlayout)
        OPT_STDLAYOUT=true ;;
      -T|--trunk)
        [[ $# -lt 2 ]] && die "$1 requires a value"
        OPT_TRUNK="$2"; shift ;;
      -b|--branches)
        [[ $# -lt 2 ]] && die "$1 requires a value"
        OPT_BRANCHES+=("$2"); shift ;;
      -t|--tags)
        [[ $# -lt 2 ]] && die "$1 requires a value"
        OPT_TAGS+=("$2"); shift ;;
      -A|--authors-file)
        [[ $# -lt 2 ]] && die "$1 requires a value"
        OPT_AUTHORS_FILE="$2"; shift ;;
      --no-authors-file)
        OPT_NO_AUTHORS_FILE=true ;;
      --no-metadata)
        OPT_NO_METADATA=true ;;
      --ignore-paths)
        [[ $# -lt 2 ]] && die "$1 requires a value"
        OPT_IGNORE_PATHS="$2"; shift ;;
      --include-paths)
        [[ $# -lt 2 ]] && die "$1 requires a value"
        OPT_INCLUDE_PATHS="$2"; shift ;;
      -r|--revision)
        [[ $# -lt 2 ]] && die "$1 requires a value"
        if [[ "$2" == *:* ]]; then
          OPT_REVISION_START="${2%%:*}"
          OPT_REVISION_END="${2##*:}"
        else
          OPT_REVISION_START="$2"
          OPT_REVISION_END="$2"
        fi
        shift ;;
      --no-skip-empty-commits)
        OPT_NO_SKIP_EMPTY=true ;;
      --default-branch)
        [[ $# -lt 2 ]] && die "$1 requires a value"
        OPT_DEFAULT_BRANCH="$2"; shift ;;
      --tags-as-branches)
        OPT_TAGS_AS_BRANCHES=true ;;
      --create-ignore)
        OPT_CREATE_IGNORE=true ;;
      --no-create-ignore)
        OPT_CREATE_IGNORE=false ;;
      --encoding)
        [[ $# -lt 2 ]] && die "$1 requires a value"
        OPT_ENCODING="$2"; shift ;;
      --target)
        [[ $# -lt 2 ]] && die "$1 requires a value"
        OPT_TARGET="$2"; shift ;;
      --help|-h) usage ;;
      *) die "Unknown option: $1" ;;
    esac
    shift
  done
}

# ── Prerequisite check ─────────────────────────────────────────────────────────
check_prereqs() {
  local missing=()
  command -v svn     &>/dev/null || missing+=("svn")
  command -v git     &>/dev/null || missing+=("git")
  command -v python3 &>/dev/null || missing+=("python3")
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing required tools: ${missing[*]}"
  fi
}

# ── URL → safe filename (SHA-256, portable via python3) ───────────────────────
url_to_hash() {
  python3 -c "
import hashlib, sys
print(hashlib.sha256(sys.argv[1].encode('utf-8')).hexdigest())
" "$1"
}

# ── SHA index operations ───────────────────────────────────────────────────────
# Append rev→sha to the sorted file for a URL (call in ascending rev order).
index_append() {
  local url="$1" rev="$2" sha="$3"
  printf '%s %s\n' "$rev" "$sha" >> "${INDEX_DIR}/$(url_to_hash "$url")"
}

# Return the commit SHA for the highest rev ≤ target_rev, or empty string.
# Uses "at-or-before" lookup (BLOCKER requirement): copyfrom-rev often points
# to a revision where the source path wasn't modified; exact match returns nothing.
index_lookup() {
  local url="$1" target_rev="$2"
  local hash_file="${INDEX_DIR}/$(url_to_hash "$url")"
  [[ -f "$hash_file" ]] || { printf ''; return; }
  awk -v target="$target_rev" \
    '$1+0 <= target+0 { last=$2 } END { print (last ? last : "") }' \
    "$hash_file"
}

# ── Transcode SVN XML output if --encoding set ────────────────────────────────
maybe_transcode() {
  if [[ -n "$OPT_ENCODING" ]]; then
    iconv -f "$OPT_ENCODING" -t UTF-8//TRANSLIT 2>/dev/null || cat
  else
    cat
  fi
}

# ── Author resolution ──────────────────────────────────────────────────────────
resolve_author() {
  local svn_user="$1"
  if [[ -n "${AUTHOR_MAP[$svn_user]+_}" ]]; then
    printf '%s' "${AUTHOR_MAP[$svn_user]}"
    return
  fi
  # Track unmapped authors (deduplicated)
  local u already=false
  for u in "${UNMAPPED_AUTHORS[@]+"${UNMAPPED_AUTHORS[@]}"}"; do
    [[ "$u" == "$svn_user" ]] && already=true && break
  done
  [[ "$already" == false ]] && UNMAPPED_AUTHORS+=("$svn_user")
  # Default: mirrors git-svn — name = svn_user, email = svn_user@REPO_UUID
  printf '%s <%s@%s>' "$svn_user" "$svn_user" "$REPO_UUID"
}

# Split "Full Name <email@x>" into AUTHOR_NAME / AUTHOR_EMAIL globals
split_author() {
  AUTHOR_NAME="${1% <*}"
  AUTHOR_EMAIL="${1##*<}"
  AUTHOR_EMAIL="${AUTHOR_EMAIL%>}"
}

# ── Phase 0 — Preflight ────────────────────────────────────────────────────────
phase0_preflight() {
  local mode="${1:-detect}"   # "detect" or "run"
  log_info "Phase 0: Preflight — ${SVN_URL}"

  # 0.1 Reachability
  log_info "  0.1 Checking reachability..."
  local info_xml info_err
  if ! info_xml=$(svn info --xml "$SVN_URL" 2>&1); then
    die "SVN unreachable at '${SVN_URL}': ${info_xml}"
  fi

  # 0.2 Encoding detection
  # Extract encoding from the XML declaration line
  local xml_enc
  xml_enc=$(printf '%s' "$info_xml" | \
    python3 -c "
import sys, re
line = sys.stdin.readline()
m = re.search(r'encoding=[\"\\x27]([^\"\\x27]+)[\"\\x27]', line)
print(m.group(1) if m else 'UTF-8')
" 2>/dev/null) || xml_enc="UTF-8"
  [[ -z "$xml_enc" ]] && xml_enc="UTF-8"

  if [[ "${xml_enc^^}" != "UTF-8" ]] && [[ -z "$OPT_ENCODING" ]]; then
    die "SVN server reports encoding '${xml_enc}'. Re-run with --encoding ${xml_enc} to transcode commit messages and author names before processing."
  fi
  if [[ -n "$OPT_ENCODING" ]]; then
    info_xml=$(printf '%s' "$info_xml" | iconv -f "$OPT_ENCODING" -t UTF-8//TRANSLIT 2>/dev/null || printf '%s' "$info_xml")
  fi

  # Parse core metadata from svn info XML
  local parsed
  parsed=$(printf '%s' "$info_xml" | python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.stdin).getroot()
def g(path):
    el = root.find(path)
    return (el.text or '').strip() if el is not None else ''
entry = root.find('entry')
rev = entry.get('revision', '0') if entry is not None else '0'
print('REPO_ROOT=' + g('entry/repository/root'))
print('REPO_UUID=' + g('entry/repository/uuid'))
print('HEAD_REV='  + rev)
print('START_URL=' + g('entry/url'))
" 2>/dev/null) || die "Failed to parse svn info XML"

  while IFS='=' read -r key val; do
    case "$key" in
      REPO_ROOT) REPO_ROOT="$val" ;;
      REPO_UUID) REPO_UUID="$val" ;;
      HEAD_REV)  HEAD_REV="$val"  ;;
      START_URL) START_URL="$val" ;;
    esac
  done <<< "$parsed"

  [[ -z "$REPO_ROOT" ]] && die "Could not determine repository root from svn info"
  [[ -z "$REPO_UUID" ]] && die "Could not determine repository UUID from svn info"

  log_info "  Repository root : ${REPO_ROOT}"
  log_info "  Repository UUID : ${REPO_UUID}"
  log_info "  HEAD revision   : ${HEAD_REV}"
  log_info "  Start URL       : ${START_URL}"

  # 0.3 Layout auto-detection
  log_info "  0.3 Layout detection..."
  if [[ "$OPT_STDLAYOUT" == true ]] || [[ -n "$OPT_TRUNK" ]] || \
     [[ ${#OPT_BRANCHES[@]} -gt 0 ]] || [[ ${#OPT_TAGS[@]} -gt 0 ]]; then
    log_info "      User-specified layout flags detected — using as-is."
  else
    if svn ls "${SVN_URL}/trunk" &>/dev/null; then
      log_info "      Detected standard layout. Suggestion: add --stdlayout (-s)"
    else
      log_info "      No trunk/ detected. Suggestion: use as single-path (omit --stdlayout)"
    fi
  fi

  # 0.4 Author enumeration
  log_info "  0.4 Enumerating authors (may be slow for large repos)..."
  local log_xml
  log_xml=$(svn log -q --xml "$SVN_URL" 2>/dev/null | maybe_transcode) || log_xml="<log/>"

  local all_authors
  all_authors=$(printf '%s' "$log_xml" | python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.stdin).getroot()
authors = set()
for e in root.findall('logentry'):
    a = e.find('author')
    authors.add(a.text.strip() if a is not None and a.text else '(no author)')
for a in sorted(authors):
    print(a)
" 2>/dev/null) || all_authors=""

  local total_authors=0 missing_authors=()
  if [[ -n "$all_authors" ]]; then
    while IFS= read -r author; do
      [[ -z "$author" ]] && continue
      ((total_authors++)) || true
      local marker="  "
      if [[ -n "$OPT_AUTHORS_FILE" && -f "$OPT_AUTHORS_FILE" ]]; then
        if grep -qF "$author" "$OPT_AUTHORS_FILE" 2>/dev/null; then
          marker="✓ "
        else
          marker="✗ "
          missing_authors+=("$author")
        fi
      fi
      log_info "      ${marker}${author}"
    done <<< "$all_authors"

    if [[ ${#missing_authors[@]} -gt 0 ]]; then
      log_warn "Authors not in map file (will use default 'user <user@UUID>'):"
      for m in "${missing_authors[@]}"; do log_warn "    ${m}"; done
      if [[ "$mode" == "run" && "$OPT_NO_AUTHORS_FILE" == false && -n "$OPT_AUTHORS_FILE" ]]; then
        log_warn "Add missing authors to '${OPT_AUTHORS_FILE}' or use --no-authors-file to suppress."
      fi
    fi
    if [[ -z "$OPT_AUTHORS_FILE" && "$OPT_NO_AUTHORS_FILE" == false && "$mode" == "run" ]]; then
      log_warn "No --authors-file supplied. All ${total_authors} author(s) will use default mapping."
      log_warn "  To create an authors file: svn log -q ${SVN_URL} | grep '^r' | awk '{print \$3}' | sort -u"
    fi
  else
    log_info "      (No authors found — repo may be empty)"
  fi

  # 0.5 Size estimation
  log_info "  0.5 Size estimate:"
  log_info "      HEAD revision (upper bound for commits): ${HEAD_REV}"
  if [[ "$HEAD_REV" -gt 5000 ]] 2>/dev/null; then
    log_warn "Large repository (${HEAD_REV} revisions). Migration may take a long time."
    log_warn "Consider using --revision N:M to migrate in batches."
  fi
}

# ── Phase 1 — Initialise Git repo ─────────────────────────────────────────────
phase1_init_git() {
  log_info "Phase 1: Initialising Git repository at '${WORK_DIR}'..."
  mkdir -p "$WORK_DIR"
  # git init --initial-branch requires git 2.28+; fall back gracefully
  if ! git init --initial-branch="$OPT_DEFAULT_BRANCH" "$WORK_DIR" &>/dev/null; then
    git init "$WORK_DIR" &>/dev/null
    git -C "$WORK_DIR" symbolic-ref HEAD "refs/heads/${OPT_DEFAULT_BRANCH}"
  fi
  git -C "$WORK_DIR" config core.autocrlf false
  log_info "  Initialised (branch: ${OPT_DEFAULT_BRANCH})."
}

# ── Phase 2 — Author map loading ──────────────────────────────────────────────
phase2_load_authors() {
  log_info "Phase 2: Loading author map..."
  if [[ -z "$OPT_AUTHORS_FILE" ]]; then
    log_info "  No --authors-file supplied. Default mapping will be used for all authors."
    return
  fi
  [[ -f "$OPT_AUTHORS_FILE" ]] || die "Authors file not found: ${OPT_AUTHORS_FILE}"
  local line count=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    # Pattern: svn-user = Full Name <email>   (also handles "(no author)")
    if [[ "$line" =~ ^([^=]+[^[:space:]=])[[:space:]]*=[[:space:]]*(.+[^[:space:]])[[:space:]]*\<([^>]*)\>[[:space:]]*$ ]]; then
      local key="${BASH_REMATCH[1]}"
      local val="${BASH_REMATCH[2]} <${BASH_REMATCH[3]}>"
      AUTHOR_MAP["$key"]="$val"
      ((count++)) || true
    fi
  done < "$OPT_AUTHORS_FILE"
  log_info "  Loaded ${count} author entries."
}

# ── Copyfrom metadata helper (used in Phase 3) ────────────────────────────────
# Populates nameref variables $2 (url) and $3 (rev) from the first SVN log entry.
get_copyfrom() {
  local url="$1"
  local -n _out_url="$2"
  local -n _out_rev="$3"
  _out_url=""
  _out_rev=""

  local log_xml
  log_xml=$(svn log --xml --stop-on-copy -v --limit 1 -r "1:HEAD" "$url" 2>/dev/null \
    | maybe_transcode) || return 0

  local result
  result=$(printf '%s' "$log_xml" | python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.stdin).getroot()
entries = root.findall('logentry')
if not entries:
    print('')
    print('')
    sys.exit(0)
for path in entries[0].findall('paths/path'):
    cf  = path.get('copyfrom-path', '')
    cr  = path.get('copyfrom-rev',  '')
    if cf:
        print(cf)
        print(cr)
        sys.exit(0)
print('')
print('')
" 2>/dev/null) || return 0

  # Use underscore-prefixed locals to avoid nameref collision:
  # "local cf_rev" would shadow _out_rev's nameref to the caller's "cf_rev".
  local _cf_path _cf_rev
  _cf_path=$(printf '%s' "$result" | sed -n '1p')
  _cf_rev=$(printf '%s' "$result"  | sed -n '2p')

  if [[ -n "$_cf_path" && -n "$_cf_rev" ]]; then
    # copyfrom-path is repo-root-relative (starts with /); prepend REPO_ROOT
    _out_url="${REPO_ROOT}${_cf_path}"
    _out_rev="$_cf_rev"
  fi
}

# ── Phase 3 — Layout resolution ───────────────────────────────────────────────
phase3_resolve_layout() {
  log_info "Phase 3: Resolving layout..."

  # Apply --stdlayout defaults (only if not already set by explicit flags)
  if [[ "$OPT_STDLAYOUT" == true ]]; then
    [[ -z "$OPT_TRUNK" ]]          && OPT_TRUNK="trunk"
    [[ ${#OPT_BRANCHES[@]} -eq 0 ]] && OPT_BRANCHES=("branches")
    [[ ${#OPT_TAGS[@]}    -eq 0 ]] && OPT_TAGS=("tags")
  fi

  # ── Trunk ──
  if [[ -n "$OPT_TRUNK" ]]; then
    local trunk_url="${SVN_URL}/${OPT_TRUNK}"
    REF_NAMES+=("refs/heads/${OPT_DEFAULT_BRANCH}")
    REF_URLS+=("$trunk_url")
    REF_IS_TAG+=("false")
    REF_COPYFROM_URL+=("")
    REF_COPYFROM_REV+=("")
    log_info "  trunk  → refs/heads/${OPT_DEFAULT_BRANCH}  (${trunk_url})"
  else
    # Single-path mode: the SVN_URL itself is the only ref
    REF_NAMES+=("refs/heads/${OPT_DEFAULT_BRANCH}")
    REF_URLS+=("$SVN_URL")
    REF_IS_TAG+=("false")
    REF_COPYFROM_URL+=("")
    REF_COPYFROM_REV+=("")
    log_info "  single-path → refs/heads/${OPT_DEFAULT_BRANCH}  (${SVN_URL})"
  fi

  # ── Branches ──
  local bp
  for bp in "${OPT_BRANCHES[@]+"${OPT_BRANCHES[@]}"}"; do
    local branches_url="${SVN_URL}/${bp}"
    log_info "  Enumerating branches at ${branches_url} ..."
    local branch_list
    branch_list=$(svn ls "$branches_url" 2>/dev/null) || {
      log_warn "Cannot list ${branches_url} — skipping"
      continue
    }
    while IFS= read -r bname; do
      [[ -z "$bname" ]] && continue
      bname="${bname%/}"
      local burl="${branches_url}/${bname}"
      local cf_url="" cf_rev=""
      get_copyfrom "$burl" cf_url cf_rev
      REF_NAMES+=("refs/heads/${bname}")
      REF_URLS+=("$burl")
      REF_IS_TAG+=("false")
      REF_COPYFROM_URL+=("$cf_url")
      REF_COPYFROM_REV+=("$cf_rev")
      log_info "    branch: ${bname}  copyfrom: ${cf_url:-none}@${cf_rev:-}"
    done <<< "$branch_list"
  done

  # ── Tags ──
  local tp
  for tp in "${OPT_TAGS[@]+"${OPT_TAGS[@]}"}"; do
    local tags_url="${SVN_URL}/${tp}"
    log_info "  Enumerating tags at ${tags_url} ..."
    local tag_list
    tag_list=$(svn ls "$tags_url" 2>/dev/null) || {
      log_warn "Cannot list ${tags_url} — skipping"
      continue
    }
    while IFS= read -r tname; do
      [[ -z "$tname" ]] && continue
      tname="${tname%/}"
      local turl="${tags_url}/${tname}"
      local cf_url="" cf_rev=""
      get_copyfrom "$turl" cf_url cf_rev
      REF_NAMES+=("refs/tags/${tname}")
      REF_URLS+=("$turl")
      REF_IS_TAG+=("true")
      REF_COPYFROM_URL+=("$cf_url")
      REF_COPYFROM_REV+=("$cf_rev")
      log_info "    tag:    ${tname}  copyfrom: ${cf_url:-none}@${cf_rev:-}"
    done <<< "$tag_list"
  done

  log_info "  Total refs resolved: ${#REF_NAMES[@]}"
}

# ── Path filtering ─────────────────────────────────────────────────────────────
# Removes files from WORK_DIR that match --ignore-paths or don't match --include-paths.
# Matches against ref-root-relative paths (e.g. "src/foo.c", not "/trunk/src/foo.c").
apply_path_filter() {
  [[ -z "$OPT_IGNORE_PATHS" && -z "$OPT_INCLUDE_PATHS" ]] && return 0

  local work="$WORK_DIR"
  local f rel

  if [[ -n "$OPT_IGNORE_PATHS" ]]; then
    while IFS= read -r -d '' f; do
      rel="${f#"${work}"/}"
      if printf '%s' "$rel" | grep -qEe "$OPT_IGNORE_PATHS" 2>/dev/null; then
        rm -rf "$f"
      fi
    done < <(find "$work" -mindepth 1 -not -path "${work}/.git*" \
               \( -type f -o -type l \) -print0 2>/dev/null)
  fi

  if [[ -n "$OPT_INCLUDE_PATHS" ]]; then
    while IFS= read -r -d '' f; do
      rel="${f#"${work}"/}"
      if ! printf '%s' "$rel" | grep -qEe "$OPT_INCLUDE_PATHS" 2>/dev/null; then
        rm -f "$f"
      fi
    done < <(find "$work" -mindepth 1 -not -path "${work}/.git*" \
               -type f -print0 2>/dev/null)
  fi

  # Remove empty directories left by filtering
  find "$work" -mindepth 1 -not -path "${work}/.git*" \
    -type d -empty -delete 2>/dev/null || true
}

# ── Phase 4/5/6 — Process one ref ─────────────────────────────────────────────
process_ref() {
  local ref_idx="$1"
  local ref_name="${REF_NAMES[$ref_idx]}"
  local ref_url="${REF_URLS[$ref_idx]}"
  local is_tag="${REF_IS_TAG[$ref_idx]}"
  local copyfrom_url="${REF_COPYFROM_URL[$ref_idx]}"
  local copyfrom_rev="${REF_COPYFROM_REV[$ref_idx]}"

  log_info ""
  log_info "Processing ref [$(( ref_idx + 1 ))/${#REF_NAMES[@]}]: ${ref_name}"
  log_info "  SVN URL: ${ref_url}"

  cd "$WORK_DIR"

  # ── Phase 5: Resolve initial parent from copyfrom metadata ────────────────
  local initial_parent=""
  if [[ -n "$copyfrom_url" && -n "$copyfrom_rev" ]]; then
    initial_parent=$(index_lookup "$copyfrom_url" "$copyfrom_rev")
    if [[ -z "$initial_parent" ]]; then
      log_warn "Copyfrom not in SHA index for ${ref_name}"
      log_warn "  (copyfrom_url=${copyfrom_url} rev=${copyfrom_rev})"
      log_warn "  Creating root commit. Branch history will appear disconnected."
      ORPHANED_BRANCHES+=("$ref_name")
    else
      log_info "  Copyfrom parent: ${initial_parent} (${copyfrom_url}@${copyfrom_rev})"
    fi
  fi

  # ── Phase 4.1: Fetch revision list ────────────────────────────────────────
  # --stop-on-copy is MANDATORY: without it SVN returns trunk revisions that
  # predate this branch URL, which cannot be exported from the branch URL.
  local log_xml log_err
  if ! log_xml=$(svn log --xml --stop-on-copy -v \
                   -r "${OPT_REVISION_START}:${OPT_REVISION_END}" \
                   "$ref_url" 2>&1); then
    log_warn "svn log failed for ${ref_url}: ${log_xml}"
    return 0
  fi
  log_xml=$(printf '%s' "$log_xml" | maybe_transcode)

  # Parse log entries into TSV: rev TAB author TAB date TAB base64(msg)
  local revisions_tsv
  revisions_tsv=$(printf '%s' "$log_xml" | python3 -c "
import sys, xml.etree.ElementTree as ET, base64 as b64
root = ET.parse(sys.stdin).getroot()
for e in root.findall('logentry'):
    rev    = e.get('revision', '')
    a      = e.find('author')
    author = a.text.strip() if a is not None and a.text else '(no author)'
    d      = e.find('date')
    date   = d.text.strip() if d is not None and d.text else ''
    m      = e.find('msg')
    msg    = m.text if m is not None and m.text else ''
    b      = b64.b64encode(msg.encode('utf-8', 'replace')).decode('ascii')
    print(rev + '\t' + author + '\t' + date + '\t' + b)
" 2>/dev/null) || true

  if [[ -z "$revisions_tsv" ]]; then
    log_info "  No revisions to process for ${ref_name}"
    return 0
  fi

  local total_revs
  total_revs=$(printf '%s\n' "$revisions_tsv" | wc -l | tr -d '[:space:]')
  log_info "  ${total_revs} revision(s) to process"

  # Get first revision number (needed for dirty-tag check)
  local first_rev
  first_rev=$(printf '%s\n' "$revisions_tsv" | head -1 | cut -f1)

  # ── Phase 6: Dirty tag check ──────────────────────────────────────────────
  local actual_ref_name="$ref_name"
  local make_annotated_tag=false

  if [[ "$is_tag" == true ]]; then
    local tag_short="${ref_name##refs/tags/}"

    if [[ "$OPT_TAGS_AS_BRANCHES" == true ]]; then
      actual_ref_name="refs/heads/tags/${tag_short}"
      DIRTY_TAGS+=("${tag_short} (--tags-as-branches)")
      log_info "  Tag '${tag_short}' → branch (--tags-as-branches)"
    else
      # Check for post-copy modifications
      local first_rev_plus_one=$(( first_rev + 1 ))
      local post_xml post_count
      post_xml=$(svn log --stop-on-copy --xml \
                   -r "${first_rev_plus_one}:HEAD" "$ref_url" 2>/dev/null) || post_xml="<log/>"
      post_count=$(printf '%s' "$post_xml" | python3 -c "
import sys, xml.etree.ElementTree as ET
print(len(ET.parse(sys.stdin).getroot().findall('logentry')))
" 2>/dev/null) || post_count=0

      if [[ "$post_count" -gt 0 ]]; then
        actual_ref_name="refs/heads/tags/${tag_short}"
        DIRTY_TAGS+=("$tag_short")
        log_warn "tags/${tag_short} has commits after the copy point — created as branch ${actual_ref_name}"
      else
        make_annotated_tag=true
        # Process revisions into a temporary branch ref, promote to annotated tag at end
        actual_ref_name="refs/heads/_svn_tag_tmp_${tag_short}"
        log_info "  Tag '${tag_short}' is clean — will create annotated tag"
      fi
    fi
  fi

  # ── Per-revision loop ──────────────────────────────────────────────────────
  local current_parent="$initial_parent"
  local last_commit_sha=""
  local tagger_author="" tagger_date=""
  local rev_idx=0

  while IFS=$'\t' read -r rev author svn_date msg_b64; do
    ((rev_idx++)) || true

    # Progress line: "Fetching rev 42/1500: trunk — "Fix build" (jdoe)"
    local msg_preview short_name
    msg_preview=$(printf '%s' "$msg_b64" | base64 -d 2>/dev/null | \
                  head -1 | cut -c1-60) || msg_preview="?"
    short_name="${actual_ref_name##refs/heads/}"
    short_name="${short_name##refs/tags/}"
    short_name="${short_name##_svn_tag_tmp_}"
    log_progress "  Fetching rev ${rev}/${HEAD_REV} [${rev_idx}/${total_revs}]: ${short_name} — \"${msg_preview}\" (${author})"

    # ── Phase 4.2: Export to staging ────────────────────────────────────────
    local stage_parent="${WORK_TEMP}/stage_${$}_${rev}"
    local stage_export="${stage_parent}/export"
    mkdir -p "$stage_parent"

    local svn_export_err
    if ! svn_export_err=$(svn export --force -q -r "$rev" "$ref_url" "$stage_export" 2>&1); then
      rm -rf "$stage_parent"
      die "svn export failed for ${ref_url}@${rev}: ${svn_export_err}"
    fi

    # ── Phase 4.5: Mirror into git working tree ──────────────────────────────
    # Remove all tracked/untracked content (handles deletes), preserve .git/
    find "$WORK_DIR" -mindepth 1 -maxdepth 1 ! -name '.git' \
      -exec rm -rf {} + 2>/dev/null || true

    # Copy exported snapshot into working tree (preserves symlinks with -P)
    if [[ -d "$stage_export" ]]; then
      find "$stage_export" -mindepth 1 -maxdepth 1 -print0 \
        | xargs -0 -I{} cp -rP {} "$WORK_DIR/" 2>/dev/null || true
    fi
    rm -rf "$stage_parent"

    # ── Phase 4.3: Path filtering ────────────────────────────────────────────
    apply_path_filter

    # Stage everything (new, modified, deleted; symlinks captured as mode 120000)
    git add -A

    # ── Phase 4.6: Empty commit detection ───────────────────────────────────
    local new_tree
    new_tree=$(git write-tree)

    local compare_parent="${current_parent:-${last_commit_sha}}"
    local current_tree=""
    if [[ -n "$compare_parent" ]]; then
      current_tree=$(git rev-parse "${compare_parent}^{tree}" 2>/dev/null || true)
    fi

    if [[ "$new_tree" == "$current_tree" ]] && [[ "$OPT_NO_SKIP_EMPTY" == false ]]; then
      log_info "    (skipped — tree unchanged)"
      ((TOTAL_SKIPPED++)) || true
      # Still update index so subsequent copyfrom lookups for this URL work
      if [[ -n "$compare_parent" ]]; then
        index_append "$ref_url" "$rev" "$compare_parent"
      fi
      # Do NOT clear current_parent here: it holds the copyfrom initial parent and must
      # persist until an actual (non-empty) commit consumes it at line 856 below.
      continue
    fi

    # ── Phase 4.7: Commit author + date ────────────────────────────────────
    local author_full author_name author_email git_date
    author_full=$(resolve_author "$author")
    split_author "$author_full"
    author_name="$AUTHOR_NAME"
    author_email="$AUTHOR_EMAIL"
    # Convert "2023-04-15T10:30:00.123456Z" → "2023-04-15T10:30:00 +0000"
    git_date=$(printf '%s' "$svn_date" | sed 's/\.[0-9]*Z/ +0000/')

    # ── Phase 4.8: Commit message ────────────────────────────────────────────
    local raw_msg commit_msg
    raw_msg=$(printf '%s' "$msg_b64" | base64 -d 2>/dev/null || true)
    if [[ "$OPT_NO_METADATA" == false ]]; then
      # Append git-svn-id trailer (blank line separator, full absolute URL)
      # Matches exactly what Perl git-svn produces.
      commit_msg="${raw_msg}

git-svn-id: ${ref_url}@${rev} ${REPO_UUID}"
    else
      commit_msg="$raw_msg"
    fi

    # ── Phase 4.9: Create commit object ─────────────────────────────────────
    local effective_parent="${current_parent:-${last_commit_sha}}"
    local commit_sha
    # Use if/else to pass -p correctly — array expansion inside nested quotes
    # collapses to a single word ("-p sha") instead of two args ("-p" "sha").
    if [[ -n "$effective_parent" ]]; then

      if ! commit_sha=$(
        GIT_AUTHOR_NAME="$author_name"     \
        GIT_AUTHOR_EMAIL="$author_email"   \
        GIT_AUTHOR_DATE="$git_date"        \
        GIT_COMMITTER_NAME="$author_name"  \
        GIT_COMMITTER_EMAIL="$author_email"\
        GIT_COMMITTER_DATE="$git_date"     \
        git commit-tree "$new_tree" -p "$effective_parent" \
          <<< "$commit_msg"
      ); then
        die "git commit-tree failed for ${ref_url}@${rev}"
      fi
    else
      if ! commit_sha=$(
        GIT_AUTHOR_NAME="$author_name"     \
        GIT_AUTHOR_EMAIL="$author_email"   \
        GIT_AUTHOR_DATE="$git_date"        \
        GIT_COMMITTER_NAME="$author_name"  \
        GIT_COMMITTER_EMAIL="$author_email"\
        GIT_COMMITTER_DATE="$git_date"     \
        git commit-tree "$new_tree" \
          <<< "$commit_msg"
      ); then
        die "git commit-tree failed for ${ref_url}@${rev}"
      fi
    fi

    # Advance the ref pointer
    git update-ref "$actual_ref_name" "$commit_sha"

    # ── Phase 4.10: SHA index update ─────────────────────────────────────────
    index_append "$ref_url" "$rev" "$commit_sha"

    last_commit_sha="$commit_sha"
    current_parent=""   # only used for the very first commit of a ref

    ((TOTAL_COMMITS++)) || true
    ((SVN_REVS_PROCESSED++)) || true

    # Record tagger info from the first (copy) revision
    if [[ "$rev_idx" -eq 1 ]]; then
      tagger_author="$author"
      tagger_date="$svn_date"
    fi

  done <<< "$revisions_tsv"

  # ── Phase 6: Create annotated tag for clean tags ──────────────────────────
  if [[ "$make_annotated_tag" == true ]]; then
    local tag_short="${ref_name##refs/tags/}"
    # Use last commit produced by the loop, or fall back to copyfrom parent
    local final_sha="${last_commit_sha:-${initial_parent}}"

    if [[ -n "$final_sha" ]]; then
      local t_full t_name t_email t_git_date
      t_full=$(resolve_author "${tagger_author:-(no author)}")
      split_author "$t_full"
      t_name="$AUTHOR_NAME"
      t_email="$AUTHOR_EMAIL"
      t_git_date=$(printf '%s' "${tagger_date:-}" | sed 's/\.[0-9]*Z/ +0000/')

      if GIT_COMMITTER_NAME="$t_name"   \
         GIT_COMMITTER_EMAIL="$t_email" \
         GIT_COMMITTER_DATE="$t_git_date" \
         git tag -a -m "SVN tag ${tag_short}" "${tag_short}" "$final_sha" 2>/dev/null; then
        log_info "  Created annotated tag: ${tag_short} → ${final_sha}"
      else
        log_warn "Failed to create annotated tag ${tag_short}; falling back to lightweight tag"
        git tag "${tag_short}" "$final_sha" 2>/dev/null || \
          log_warn "Failed to create lightweight tag ${tag_short}"
      fi
    else
      log_warn "No final SHA for tag ${tag_short}; skipping tag creation"
    fi

    # Clean up the temporary branch ref used during processing
    git update-ref -d "${actual_ref_name}" 2>/dev/null || true
  fi
}

# ── Phase 7 — Post-processing ──────────────────────────────────────────────────
phase7_post_process() {
  log_info ""
  log_info "Phase 7: Post-processing..."
  cd "$WORK_DIR"

  # 7.1 svn:ignore → .gitignore
  if [[ "$OPT_CREATE_IGNORE" == true ]]; then
    log_info "  7.1 Converting svn:ignore → .gitignore ..."

    local trunk_url
    if [[ -n "$OPT_TRUNK" ]]; then
      trunk_url="${SVN_URL}/${OPT_TRUNK}"
    else
      trunk_url="$SVN_URL"
    fi
    local trunk_ref="refs/heads/${OPT_DEFAULT_BRANCH}"
    local trunk_sha
    trunk_sha=$(git rev-parse "$trunk_ref" 2>/dev/null) || {
      log_warn "Cannot resolve ${trunk_ref}; skipping .gitignore generation"
      return 0
    }

    # Restore working tree to current trunk HEAD using git plumbing
    find "$WORK_DIR" -mindepth 1 -maxdepth 1 ! -name '.git' \
      -exec rm -rf {} + 2>/dev/null || true
    git read-tree "$trunk_sha"
    git checkout-index -a --force 2>/dev/null || true

    # Enumerate all directories in trunk (SVN side)
    local dirs_xml
    dirs_xml=$(svn list --xml -r HEAD -R "$trunk_url" 2>/dev/null) || dirs_xml="<lists/>"

    local dir_list
    dir_list=$(printf '%s' "$dirs_xml" | python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.stdin).getroot()
print('')  # always check root dir
for e in root.findall('.//entry[@kind=\"dir\"]'):
    n = e.find('name')
    if n is not None and n.text and n.text.strip() not in ('', '.'):
        print(n.text.strip())
" 2>/dev/null) || dir_list=""

    local changed=false
    while IFS= read -r reldir; do
      local prop_url="$trunk_url"
      [[ -n "$reldir" ]] && prop_url="${trunk_url}/${reldir}"

      local svn_ignore
      svn_ignore=$(svn propget svn:ignore -r HEAD "$prop_url" 2>/dev/null) || svn_ignore=""
      [[ -z "$svn_ignore" ]] && continue

      local gitignore_dir="${WORK_DIR}"
      [[ -n "$reldir" ]] && gitignore_dir="${WORK_DIR}/${reldir}"
      mkdir -p "$gitignore_dir"

      local gitignore_file="${gitignore_dir}/.gitignore"

      # Append patterns not already present (deduplicate)
      local new_patterns=""
      while IFS= read -r pattern; do
        [[ -z "$pattern" ]] && continue
        if ! grep -qxF "$pattern" "$gitignore_file" 2>/dev/null; then
          new_patterns+="${pattern}"$'\n'
        fi
      done <<< "$svn_ignore"

      if [[ -n "$new_patterns" ]]; then
        printf '%s' "$new_patterns" >> "$gitignore_file"
        changed=true
        log_info "    Wrote .gitignore: ${gitignore_file#"${WORK_DIR}/"}"
      fi
    done <<< "$dir_list"

    if [[ "$changed" == true ]]; then
      git add -A
      local new_tree
      new_tree=$(git write-tree)
      local now_date
      now_date=$(date -u '+%Y-%m-%dT%H:%M:%S +0000')
      local ignore_sha
      ignore_sha=$(
        GIT_AUTHOR_NAME="svn-migrate"            \
        GIT_AUTHOR_EMAIL="svn-migrate@${REPO_UUID}" \
        GIT_AUTHOR_DATE="$now_date"              \
        GIT_COMMITTER_NAME="svn-migrate"         \
        GIT_COMMITTER_EMAIL="svn-migrate@${REPO_UUID}" \
        GIT_COMMITTER_DATE="$now_date"           \
        git commit-tree "$new_tree" -p "$trunk_sha" <<< "Add .gitignore from svn:ignore"
      ) || { log_warn "Failed to create .gitignore commit"; return 0; }
      git update-ref "$trunk_ref" "$ignore_sha"
      log_info "    .gitignore commit created: ${ignore_sha}"
    else
      log_info "    No svn:ignore properties found — .gitignore step skipped."
    fi
  fi

  # 7.2 Set default branch HEAD
  log_info "  7.2 Setting HEAD → refs/heads/${OPT_DEFAULT_BRANCH}"
  git symbolic-ref HEAD "refs/heads/${OPT_DEFAULT_BRANCH}"

  # 7.3 Pack objects
  log_info "  7.3 Running git gc (aggressive) ..."
  git gc --aggressive --prune=now --quiet 2>/dev/null || \
    git gc --prune=now --quiet 2>/dev/null || true
}

# ── Phase 8 — Verification summary ────────────────────────────────────────────
phase8_summary() {
  local branch_count=0 tag_count=0
  local r
  for r in "${REF_NAMES[@]+"${REF_NAMES[@]}"}"; do
    case "$r" in
      refs/heads/*) ((branch_count++)) || true ;;
      refs/tags/*)  ((tag_count++))   || true ;;
    esac
  done

  log_info ""
  log_info "══════════════════════════════════════════════════════════════"
  log_info " Migration complete."
  log_info "══════════════════════════════════════════════════════════════"
  log_info "  Refs:                          ${branch_count} branch(es), ${tag_count} tag(s)"
  log_info "  Git commits created:           ${TOTAL_COMMITS}"
  log_info "  SVN revisions processed:       ${SVN_REVS_PROCESSED}"
  log_info "  Skipped (empty/no change):     ${TOTAL_SKIPPED}"

  if [[ ${#DIRTY_TAGS[@]} -gt 0 ]]; then
    log_info "  Dirty tags promoted to branches:"
    local dt; for dt in "${DIRTY_TAGS[@]}"; do log_info "    • ${dt}"; done
  fi

  if [[ ${#ORPHANED_BRANCHES[@]} -gt 0 ]]; then
    log_info "  Branches with unresolved copyfrom (created as root commits):"
    local ob; for ob in "${ORPHANED_BRANCHES[@]}"; do log_info "    • ${ob}"; done
  fi

  if [[ ${#UNMAPPED_AUTHORS[@]} -gt 0 ]]; then
    log_info "  Unmapped SVN authors (used default 'user <user@UUID>'):"
    local ua
    for ua in "${UNMAPPED_AUTHORS[@]}"; do
      log_info "    • ${ua}  →  ${ua} <${ua}@${REPO_UUID}>"
    done
  fi

  log_info ""
  log_info "Next steps:"
  log_info "  git -C '${WORK_DIR}' remote add origin <remote-url>"
  log_info "  git -C '${WORK_DIR}' push --all origin"
  log_info "  git -C '${WORK_DIR}' push --tags origin"
  log_info ""
  log_info "To strip git-svn-id trailers from all commits (irreversible):"
  log_info "  git -C '${WORK_DIR}' filter-repo --message-callback \\"
  log_info "    'return re.sub(rb\"\ngit-svn-id:.*\", b\"\", message)'"
  log_info "══════════════════════════════════════════════════════════════"
}

# ── cmd_detect ────────────────────────────────────────────────────────────────
cmd_detect() {
  log_info "════════════════════════════════════════════════════════════════"
  log_info " SVN → Git Migration — Preflight Report"
  log_info " ${SCRIPT_NAME} ${SCRIPT_VERSION}"
  log_info "════════════════════════════════════════════════════════════════"
  log_info " SVN URL: ${SVN_URL}"
  log_info ""
  phase0_preflight "detect"
  log_info ""
  log_info "════════════════════════════════════════════════════════════════"
  log_info " Preflight complete. To migrate, re-run with the 'run' subcommand."
  log_info "════════════════════════════════════════════════════════════════"
}

# ── cmd_run ───────────────────────────────────────────────────────────────────
cmd_run() {
  log_info "════════════════════════════════════════════════════════════════"
  log_info " SVN → Git Migration — ${SCRIPT_NAME} ${SCRIPT_VERSION}"
  log_info "════════════════════════════════════════════════════════════════"
  log_info " SVN URL : ${SVN_URL}"
  log_info " Target  : ${WORK_DIR}"
  log_info ""

  # Phase 0: Preflight (sets REPO_ROOT, REPO_UUID, HEAD_REV, START_URL)
  phase0_preflight "run"

  # Phase 1: Init git repo
  phase1_init_git

  # Phase 2: Load author map
  phase2_load_authors

  # Phase 3: Resolve refs
  phase3_resolve_layout

  # Set up SHA index directory now that WORK_TEMP is known
  INDEX_DIR="${WORK_TEMP}/sha_index"
  mkdir -p "$INDEX_DIR"

  log_info ""
  log_info "════ Phases 4-6: Ref conversion ════"

  # Process order per spec: trunk (and any other root branches) first, then
  # branches-with-copyfrom, then tags.  This guarantees the trunk SHA index
  # is fully populated before branches look up their copyfrom parent.
  # Root branches (no copyfrom_url) include trunk AND branches created from
  # scratch — we process all of them in Pass 1.
  local i

  # Pass 1: all non-tag refs with no copyfrom (trunk + scratch-created branches)
  for (( i=0; i<${#REF_NAMES[@]}; i++ )); do
    [[ "${REF_IS_TAG[$i]}" == true ]] && continue
    [[ -n "${REF_COPYFROM_URL[$i]}" ]] && continue   # has copyfrom — skip to pass 2
    process_ref "$i"
  done

  # Pass 2: non-tag refs with copyfrom (branches copied from trunk/other branches)
  for (( i=0; i<${#REF_NAMES[@]}; i++ )); do
    [[ "${REF_IS_TAG[$i]}" == true ]] && continue
    [[ -z "${REF_COPYFROM_URL[$i]}" ]] && continue   # already done in pass 1
    process_ref "$i"
  done

  # Pass 3: tags — all branch indices are now populated
  for (( i=0; i<${#REF_NAMES[@]}; i++ )); do
    [[ "${REF_IS_TAG[$i]}" == true ]] || continue
    process_ref "$i"
  done

  # Phase 7: Post-processing (.gitignore, default branch, gc)
  phase7_post_process

  # Phase 8: Summary
  phase8_summary
}

# ── main ──────────────────────────────────────────────────────────────────────
main() {
  parse_args "$@"
  check_prereqs

  # Resolve target directory (needed by both detect and run for display)
  if [[ -z "$OPT_TARGET" ]]; then
    local url_basename
    url_basename=$(basename "${SVN_URL%/}")
    OPT_TARGET="./${url_basename}"
  fi
  WORK_DIR="$(realpath -m "$OPT_TARGET" 2>/dev/null || echo "$OPT_TARGET")"

  # Create working temp space (cleaned up by EXIT trap)
  WORK_TEMP="$(mktemp -d)"

  case "$SUBCOMMAND" in
    detect) cmd_detect ;;
    run)    cmd_run    ;;
  esac
}

main "$@"

