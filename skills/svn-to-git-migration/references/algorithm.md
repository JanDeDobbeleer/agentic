# SVN → Git Migration — Shared Algorithm Spec

This document is the **parity contract** for `scripts/migrate.sh` (bash, macOS/Linux) and
the PowerShell implementation via inline phases (`lib/core.pslib`, executed through `phases/run-phase.md`
and `scripts/run-phase.pslib`; Windows only). Both implementations must follow every rule
here. When the two diverge, this spec is authoritative.

The PowerShell implementation additionally supports resume from the persisted SHA index,
periodic checkpoints during long-running phases, and a configurable `$maxMinutes` time budget —
features not yet available in the bash path.

---

## Prerequisites

| Tool | Min version | Notes |
|------|-------------|-------|
| `svn` | any modern | TortoiseSVN, SlikSVN, Homebrew svn, distro pkg |
| `git` | 2.x | git plumbing: `hash-object`, `write-tree`, `commit-tree`, `update-ref`, `update-index` |
| `bash` | **4.0** | macOS ships 3.2 — no associative arrays. Script MUST check `${BASH_VERSINFO[0]} -lt 4` at startup and abort with: `"bash 4.0+ required. On macOS: brew install bash"` |
| `python3` | 3.x | Used for XML parsing in bash (avoids xmllint/xpath portability issues) |
| `powershell` (or `pwsh`) | **5.1** | Windows; executed via `powershell -Command` with `[scriptblock]::Create` dot-sourcing (Group Policy blocks `-File` execution) |

---

## Subcommands

**bash (macOS/Linux):**
```
scripts/migrate.sh detect <svn-url> [options]   # preflight: info, layout, authors, size
scripts/migrate.sh run    <svn-url> [options]   # perform migration
```

**Windows (inline phases):**
The Windows path uses phase runbooks via `phases/run-phase.md` and `scripts/run-phase.pslib`.
See the skill's interview step for guided execution.

---

## Phase 0 — Preflight (`detect`)

### 0.1 Reachability
Run `svn info --xml <svn-url>`. On failure: print the svn error and abort.

Parse from the XML:
- `repository/root` → `$REPO_ROOT`   (e.g. `https://svn.example.com/repos/myrepo`)
- `repository/uuid` → `$REPO_UUID`
- `entry/@revision` (HEAD revision) → `$HEAD_REV`
- `url` (canonicalised URL of the requested path) → `$START_URL`

### 0.2 Encoding detection
From the XML declaration: `<?xml version="1.0" encoding="..."?>`. If encoding is
**not** `UTF-8` (case-insensitive) and `--encoding` is not supplied, abort with:

```
ERROR: SVN server reports encoding '<enc>'. Re-run with --encoding <enc> to transcode
commit messages and author names before processing.
```

If `--encoding <enc>` is supplied, the script must transcode all strings pulled from
`svn log --xml` output using `iconv -f <enc> -t UTF-8//TRANSLIT` (bash) or
`[System.Text.Encoding]::GetEncoding("<enc>").GetString(...)` → UTF-8 bytes (PS).

### 0.3 Layout auto-detection
- If `svn ls <url>/trunk` succeeds → suggest `--stdlayout`
- Otherwise → suggest single-path (no branch/tag enumeration)
- Always defer to explicit user flags (`-T`, `-b`, `-t`, `--stdlayout`).

### 0.4 Author enumeration
Run `svn log -q --xml <svn-url>`. Collect unique `<author>` values. If any author
appears in the log but is absent from the authors file, **and** `--no-authors-file`
is not set, abort with instructions to fill in `authors.txt`.

### 0.5 Size estimation
Report: number of unique paths (from `svn info` subtree count or `svn log` count),
HEAD revision, and a rough "estimated commits to process" number. Warn if > 5000.

---

## Phase 1 — Initialise Git repo

```
git init --initial-branch=<default-branch> <target-dir>
cd <target-dir>
git config core.autocrlf false       # always; SVN controls EOL
```

`<default-branch>` = flag value, default `main`.

---

## Phase 2 — Author map loading

Authors file format (identical to git-svn):
```
svn-username = Full Name <email@example.com>
(no author) = Unknown Author <unknown@example.com>
```

Rules:
- Lines matching `^(.+?|\(no author\))\s*=\s*(.+?)\s*<(.*)>\s*$` are loaded.
- If an svn author has no entry, use: name = `<svn-username>`, email = `<svn-username>@<REPO_UUID>`
  This exactly mirrors the git-svn default.
- `(no author)` catches commits with no svn author property.

---

## Phase 3 — Layout resolution

Resolve the set of **refs** to process. Each ref is a tuple:
```
(ref_name, svn_url, is_tag, copyfrom_url, copyfrom_rev)
```

### Stdlayout (`--stdlayout` / `-s`)
- trunk ref: `refs/heads/main` (or `--default-branch` value), url = `<url>/trunk`
- branches: enumerate `svn ls <url>/branches/` → one ref per entry,
  `refs/heads/<branch-name>`, url = `<url>/branches/<name>`
- tags: enumerate `svn ls <url>/tags/` → tentative, url = `<url>/tags/<name>`

### Custom (`-T/-b/-t`)
Same as stdlayout but with user-supplied paths.

### Single-path
One ref only: `refs/heads/main`, url = the supplied URL. No branches, no tags.

### Copyfrom metadata
For each branch and tag url, run:
```
svn log --xml --limit 1 -r 1:HEAD <url>
```
to find the first log entry. Then from `svn info --xml -r <first-rev-minus-1> <url>`
(if it exists at that rev) — actually simpler:
```
svn log --xml --stop-on-copy --limit 1 -r 1:HEAD <url>
```
The `<logentry>` at the copy revision includes `<path copyfrom-path="..." copyfrom-rev="...">`.
Parse this to populate `copyfrom_url` and `copyfrom_rev` for the ref tuple.

---

## Phase 4 — Per-ref conversion loop

Process refs in order: **trunk first**, then branches, then tags. This ensures the
SHA index is populated for trunk before branches look up their copyfrom parent.

### 4.1 Revision list
```
svn log --xml --stop-on-copy -v -r 1:HEAD <ref_url>
```

**`--stop-on-copy` is mandatory.** Without it, SVN follows copy ancestry backward
through the source path, returning revisions that predate this ref's URL — those
revisions cannot be exported from the ref's URL and will produce errors.

Parse each `<logentry>`:
- `@revision` → rev number
- `<author>` → svn username (may be absent → `(no author)`)
- `<date>` → ISO 8601 UTC timestamp, e.g. `2023-04-15T10:30:00.123456Z`
- `<msg>` → commit message text

Filter by `--revision` range if supplied: only process revisions in `[start, end]`.

### 4.2 Export to staging
```
svn export --force -r <rev> <ref_url> <staging_dir>
```

`<staging_dir>` is a temp directory per revision, cleaned up after each commit.

### 4.3 Path filtering
Apply `--ignore-paths` and `--include-paths` regexes against **ref-root-relative
paths** (e.g. `src/generated/foo.c`, not `/trunk/src/generated/foo.c`).

⚠️ This differs from git-svn, which matches repo-root-relative paths. Document this
in the skill's interview step so users migrating from git-svn config know to adjust
their patterns.

Remove matching files from the staging directory before git operations.

### 4.4 SVN property handling

#### svn:special (symlinks)
SVN represents symlinks as a regular file containing `link <target>`. On Linux/macOS,
`svn export` creates a real symlink. On Windows, it produces a text file with that
content.

**Windows/PowerShell only:**
1. Walk the staging directory for files.
2. For any file whose entire content is `link <target>` (the file is small and starts
   with `link `), query: `svn propget svn:special <ref_url>/<rel-path> -r <rev>`
3. If the property is set:
   - Delete the text file from staging.
   - Stage a symlink object: `git hash-object --stdin <<< "<target>"` to get the blob
     SHA, then `git update-index --add --cacheinfo 120000,<sha>,<rel-path>`
   
**bash:** `svn export` on POSIX creates real symlinks already; `git add -A` picks them
up as mode `120000` automatically.

#### svn:executable
**Windows/PowerShell only:**
After export, run:
```
svn proplist --xml -r <rev> <ref_url>
```
For every file with `svn:executable` in the listing, run:
```
git update-index --chmod=+x -- <rel-path>
```
after `git add` but before `git write-tree`.

**bash:** `svn export` on POSIX sets the execute bit; `git add` picks up mode `100755`.

### 4.5 Mirror into git working tree
- Remove all tracked files (except `.git/`) to handle deletes.
- Copy exported staging into the working tree.
- Stage: `git add -A`

### 4.6 Empty commit detection
After `git write-tree`, compare the resulting tree SHA against the current HEAD tree:
```bash
current_tree=$(git rev-parse HEAD^{tree} 2>/dev/null || echo "")
new_tree=$(git write-tree)
if [ "$new_tree" = "$current_tree" ]; then
  # skip unless --no-skip-empty-commits
fi
```
Default: **skip empty commits**. With `--no-skip-empty-commits`: create commit anyway
(useful to preserve SVN revision numbers in the `git-svn-id` trailer).

### 4.7 Commit author + date
Resolve the svn author through the author map. Set env vars:

```
GIT_AUTHOR_NAME="Full Name"
GIT_AUTHOR_EMAIL="email@example.com"
GIT_AUTHOR_DATE="2023-04-15T10:30:00 +0000"       # ISO 8601 with space before offset
GIT_COMMITTER_NAME=<same as AUTHOR>
GIT_COMMITTER_EMAIL=<same as AUTHOR>
GIT_COMMITTER_DATE=<same as AUTHOR>
```

SVN date format from `<date>` element: `2023-04-15T10:30:00.123456Z`
Convert to git format: strip microseconds and replace `Z` with ` +0000`.
Bash: `sed 's/\.[0-9]*Z/ +0000/'`
PS: `[datetime]::ParseExact($d.Split('.')[0],'yyyy-MM-ddTHH:mm:ss',$null).ToString('yyyy-MM-ddTHH:mm:ss +0000')`

### 4.8 Commit message
Append the `git-svn-id` trailer unless `--no-metadata`:

```
<original svn message>

git-svn-id: <ref_svn_url>@<rev> <REPO_UUID>
```

Where `<ref_svn_url>` is the **full absolute SVN URL of this ref's path** (not relative).
Example: `git-svn-id: https://svn.example.com/repos/myrepo/trunk@42 a1b2c3d4-e5f6-...`

This matches exactly what the Perl git-svn produces.

### 4.9 Create commit object
```
echo "<message>" | git commit-tree <new_tree> [-p <parent_sha>]
```

Returns the new commit SHA.

### 4.10 SHA index update
```
sha_index[<ref_url>][<rev>] = <commit_sha>
```

Also track the **latest SHA for each path up to each revision** for copyfrom lookup
(see Phase 5).

---

## Phase 5 — Copyfrom / branch ancestry

When starting a new ref (branch or tag) that has `copyfrom` metadata:

1. Compute the canonical SVN URL of the copyfrom path:
   `$REPO_ROOT + copyfrom_path` (copyfrom_path is repo-root-relative, starts with `/`)

2. Look up the parent SHA: find the highest revision `r` in `sha_index[copyfrom_url]`
   where `r ≤ copyfrom_rev`.

   **Bash implementation:**
   ```bash
   # sha_index stored as sorted file: "<rev> <sha>" lines per path
   # Use awk to find max rev <= copyfrom_rev
   parent=$(awk -v target="$copyfrom_rev" '$1 <= target {last=$2} END {print last}' \
     "$index_dir/${url_to_filename(copyfrom_url)}")
   ```

   **PowerShell implementation:**
   ```powershell
   # $shaIndex[$copyfromUrl] is a [SortedDictionary[int,string]]
   $keys = $shaIndex[$copyfromUrl].Keys | Where-Object { $_ -le $copyfromRev }
   $parent = if ($keys) { $shaIndex[$copyfromUrl][($keys | Measure-Object -Maximum).Maximum] } else { $null }
   ```

3. If `$parent` is found: use `-p $parent` in `git commit-tree` for the **first
   commit** of this ref.
4. If not found (copyfrom URL was never processed, e.g. copied from an excluded path):
   create the branch as a root commit and log a warning.

---

## Phase 6 — Tag handling

### Determining "dirty" tags
Before processing a tag ref, check for post-copy modifications:
```
svn log --stop-on-copy --xml -r <first-rev-of-tag + 1>:HEAD <tag_url>
```
If this returns any `<logentry>` elements, the tag is **dirty**.

### Dirty tag policy
Default (no flag):
- Create a git **branch** (`refs/heads/tags/<tagname>`) and process it like a branch.
- Print: `WARNING: tags/<tagname> has commits after the copy point — created as branch`

With `--tags-as-branches`: all tags become branches regardless.

### Clean tag creation
For a clean tag (no post-copy changes):
1. Run the normal per-ref loop to get the final commit SHA.
2. The tagger name/email/date come from the **copy revision** (the first revision in
   the tag's log).
3. Create annotated tag:
   ```
   git tag -a -m "SVN tag <tagname>" --cleanup=verbatim \
     -u "<Tagger Name>" --date="<copy date>" <tagname> <commit_sha>
   ```
   Or via plumbing: write a tag object with `git mktag`.

---

## Phase 7 — Post-processing

### 7.1 svn:ignore → .gitignore (`--create-ignore`, default on)
After all refs are processed:
1. For each directory that was committed to `refs/heads/main` (trunk), run:
   ```
   svn propget svn:ignore -r HEAD <ref_url>/<reldir>
   ```
2. Write the patterns (one per line) to `<reldir>/.gitignore` in the git working tree.
3. Merge with any existing `.gitignore` (append, deduplicate).
4. Create a final commit on each ref: `"Add .gitignore from svn:ignore"`.

### 7.2 Default branch
```
git symbolic-ref HEAD refs/heads/<default-branch>
```

### 7.3 Cleanup
```
git gc --aggressive --prune=now
```

---

## Phase 8 — Verification output

Print a summary:
```
Migration complete.
  Refs:         <N branches>, <M tags>
  Commits:      <total git commits>
  SVN revisions processed: <count>
  Skipped (empty after filter): <count>
  Dirty tags promoted to branches: <list>
  Unmapped SVN authors (used default): <list>

Next steps:
  git remote add origin <remote-url>
  git push --all origin
  git push --tags origin

To strip git-svn-id trailers from all commits (irreversible):
  git filter-repo --message-callback 'return re.sub(rb"\ngit-svn-id:.*", b"", message)'
```

---

## Data structures

### SHA index (bash)
One text file per URL (filename = URL with `/` replaced by `_`), in `$TMPDIR/sha_index/`:
```
42 a1b2c3d4e5f6...
57 f6e5d4c3b2a1...
```
Lines in ascending revision order.

### SHA index (PowerShell)
```powershell
$shaIndex = [System.Collections.Generic.Dictionary[string, 
  System.Collections.Generic.SortedDictionary[int,string]]]::new()
```
Outer key: canonical SVN URL string. Inner: `SortedDictionary[int, string]` of
`revision → sha`.

---

## Error handling

| Condition | Action |
|-----------|--------|
| `svn export` returns non-zero | Abort migration, print full svn error, print the failing URL+rev |
| `git commit-tree` fails | Abort, print error |
| Author not in map | Use `user@uuid` default, accumulate in "unmapped authors" list for summary |
| Copyfrom ref not yet indexed | Create root commit, add to "orphaned branches" list in summary |
| Non-UTF8 encoding detected without `--encoding` flag | Abort with clear instructions |
| Tag with post-copy modifications | Create branch, warn — do NOT abort |

---

## CLI flags reference

| Flag | Short | Default | Notes |
|------|-------|---------|-------|
| `--stdlayout` | `-s` | off | trunk/branches/tags preset |
| `--trunk` | `-T` | — | custom trunk path |
| `--branches` | `-b` | — | custom branches path (repeatable) |
| `--tags` | `-t` | — | custom tags path (repeatable) |
| `--authors-file` | `-A` | — | path to authors map file |
| `--no-metadata` | | off | omit `git-svn-id` trailer |
| `--ignore-paths` | | — | regex; ref-root-relative |
| `--include-paths` | | — | regex; ref-root-relative |
| `--revision` | `-r` | `1:HEAD` | `N` or `N:M` |
| `--no-skip-empty-commits` | | off | keep commits with no file changes |
| `--default-branch` | | `main` | git default branch name |
| `--tags-as-branches` | | off | all SVN tags become branches |
| `--create-ignore` | | on | convert svn:ignore to .gitignore |
| `--encoding` | | — | source encoding for commit messages |
| `--target` | | `./repo-name` | output git directory |
