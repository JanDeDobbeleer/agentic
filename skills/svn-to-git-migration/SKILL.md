---
name: svn-to-git-migration
description: >
  Guide users through migrating a Subversion (SVN) repository to a standalone Git
  repository, then execute the migration using platform-native scripts. Use this skill
  whenever the user mentions SVN migration, converting SVN to Git, "we're moving away
  from SVN", "git svn is missing", "git-svn not found on Windows", or wants to import
  SVN history into a Git repo — even if they don't use the word "migrate". Also use
  when someone asks how to preserve SVN history in Git, convert branches/tags from SVN,
  or set up a Git mirror of an SVN repo.
---

# SVN → Git Migration

`git-svn` is no longer bundled with Git for Windows (and macOS Homebrew dropped it
too). This skill recreates the full `git svn clone` behaviour using only the `svn` CLI
and standard git plumbing commands (`hash-object`, `write-tree`, `commit-tree`,
`update-ref`, `update-index`). No Perl, no native extensions required.

**Platform support:**
- **Windows** — PowerShell 7+ via `scripts/migrate.ps1`
- **macOS / Linux** — bash via `scripts/migrate.sh`

> ⚠️ **macOS users:** The system bash is version 3.2 and will not work. Install bash ≥ 4
> first: `brew install bash`. The script checks at startup and aborts with instructions
> if the version is too old.

---

## Prerequisites

Verify these before starting:

```sh
svn --version          # any modern version (TortoiseSVN, SlikSVN, Homebrew, distro pkg)
git --version          # 2.x or later
python3 --version      # 3.x — used for XML parsing in the bash script
```

**macOS only:**
```sh
bash --version         # must be 4.0 or later
# If not: brew install bash
```

**Script locations (relative to the skill directory):**
- macOS / Linux: `scripts/migrate.sh`
- Windows: `scripts/migrate.ps1`

---

## Step 1 — Detect (run this first)

Run the `detect` subcommand against your SVN URL. It performs a preflight check:
confirms reachability, detects repository layout, enumerates authors, and estimates
the number of revisions to process.

**macOS / Linux:**
```bash
bash scripts/migrate.sh detect <svn-url>
```

**Windows:**
```powershell
pwsh scripts/migrate.ps1 detect <svn-url>
```

Share the output here so we can review it together before deciding on options.

---

## Step 2 — Interview: migration options

Work through these decisions **in order** based on what `detect` reported.

### a. Repository layout

What layout does your SVN repository use?

| Layout | Description | Flag to use |
|--------|-------------|-------------|
| **Standard** | Has `trunk/`, `branches/`, `tags/` at the top level | `--stdlayout` |
| **Custom paths** | Different names (e.g. `main/`, `rb/`, `rel/`) | `-T <trunk> -b <branches> -t <tags>` |
| **Single path** | No branches or tags — just one linear history | _(no flag)_ |

The `detect` output will suggest the likely layout. You can always override it.

### b. Author mapping

Do you want real names and email addresses in git commits?

SVN commits store only a username (e.g. `jsmith`). Without a mapping, each commit
author defaults to `jsmith@<repo-uuid>` — fine for private repositories, but not ideal
for public ones.

To provide a mapping, create an `authors.txt` file (see `assets/authors.template.txt`):
```
jsmith = Jane Smith <jane.smith@example.com>
bwilliams = Bob Williams <bob@example.com>
(no author) = Unknown Committer <unknown@example.com>
```

The `detect` output lists every SVN author that appears in the log — use that list to
build your file. Ask me to generate a stub `authors.txt` from that list if you'd like.

Pass the file with: `--authors-file authors.txt`

### c. Metadata trailer

Keep `git-svn-id` in each commit message?

Each commit will end with a line like:
```
git-svn-id: https://svn.example.com/repos/myproject/trunk@42 a1b2c3d4-e5f6-...
```

- **Default (recommended):** keep it — preserves SVN revision traceability. You can
  always strip it later with `git filter-repo`.
- **To omit:** add `--no-metadata`

### d. Path filtering

Are there directories you want to exclude — generated code, large binaries, IDE files?

Use `--ignore-paths <regex>` with a regex matched against **ref-root-relative** paths.

Example — exclude a generated directory and all `.class` files:
```
--ignore-paths "(^generated/|\.class$)"
```

> ⚠️ **Migrating from git-svn?** `git-svn` matched `--ignore-paths` against
> **repo-root-relative** paths (e.g. `/trunk/generated/`). This skill matches against
> **ref-root-relative** paths (e.g. `generated/`). Adjust your patterns accordingly.
> See `references/git-svn-mapping.md` for the full mapping.

Use `--include-paths <regex>` to do the inverse (whitelist).

### e. Tag handling

Clean tags (directories that were never modified after the SVN copy) automatically
become annotated git tags. Dirty tags (modified after creation) automatically become
branches named `tags/<tagname>`, with a warning printed in the summary.

Override with `--tags-as-branches` to turn **all** SVN tags into branches regardless
of cleanliness.

### f. Default branch name

What should the trunk become in git?

| Choice | Flag |
|--------|------|
| `main` (default) | _(omit flag)_ |
| `master` | `--default-branch master` |
| `trunk` | `--default-branch trunk` |

### g. svn:ignore → .gitignore conversion

The `--create-ignore` option (on by default) reads `svn:ignore` properties from the
SVN repository and writes `.gitignore` files into the git repository, then creates a
final commit on each ref. Recommended: keep the default.

To disable: `--no-create-ignore` _(note: the default flag name is `--create-ignore`;
pass it explicitly or omit to accept the default)._

### h. Target directory

Where should the git repository be created?

Default: `./repo-name` (derived from the SVN URL). Override with `--target <path>`.

### i. Revision range

Migrate all revisions (default), or a specific range?

- All revisions: _(omit flag)_ — equivalent to `--revision 1:HEAD`
- Specific range: `--revision N:M`
- Single revision: `--revision N`

For very large repositories (> 5 000 revisions), consider migrating in chunks and
re-running with a later range. See `references/troubleshooting.md` for guidance.

---

## Step 3 — Generate the command

Based on your answers, here is the command to run. Example for a standard-layout
repository with an authors file:

**macOS / Linux:**
```bash
bash scripts/migrate.sh run https://svn.example.com/repos/myproject \
  --stdlayout \
  --authors-file authors.txt \
  --default-branch main \
  --target ./myproject-git
```

**Windows:**
```powershell
pwsh scripts/migrate.ps1 run https://svn.example.com/repos/myproject `
  --stdlayout `
  --authors-file authors.txt `
  --default-branch main `
  --target ./myproject-git
```

Tell me your answers to the interview questions and I'll produce the exact command for
your repository.

---

## Step 4 — Execute

Run the command. For large repositories this may take a while — the script prints
progress as it processes each SVN revision.

If you see errors or unexpected output, share it here and we'll diagnose together. The
most common issues are covered in `references/troubleshooting.md`.

---

## Step 5 — Verify

After the migration completes, check the result:

```bash
# Check recent commit messages and SVN revision traceability
git log --oneline | head -20

# Check all branches were created
git branch -a

# Check tags
git tag

# Inspect the latest commit in full
git show HEAD
```

If anything looks wrong (missing branches, garbled commit messages, missing history),
share the output here.

---

## Step 6 — Next steps

**Push to a remote:**
```bash
git remote add origin <remote-url>
git push --all origin
git push --tags origin
```

**Optional — strip git-svn-id trailers** (irreversible; requires `git filter-repo`):
```bash
git filter-repo --message-callback 'return re.sub(rb"\ngit-svn-id:.*", b"", message)'
```

---

## Reference files

- `references/algorithm.md` — technical algorithm spec (for debugging/understanding the scripts)
- `references/git-svn-mapping.md` — mapping from original git-svn CLI switches to this skill's options
- `references/troubleshooting.md` — auth issues, encoding, large repos, edge cases
