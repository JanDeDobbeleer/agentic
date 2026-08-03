# git-svn → This Skill: Flag Mapping

This document maps every `git svn` CLI switch to the equivalent option in the skill (bash: `scripts/migrate.sh`,
Windows: inline phases). Use it when you're migrating an existing `git svn` workflow or adapting a `git svn clone`
command you found in documentation.

---

## Command equivalents

- **git-svn command / flag:** `git svn clone <url>`
  - **This skill's equivalent:** bash: `scripts/migrate.sh run <url>` / Windows: phase runbooks (see
    `phases/run-phase.md`)
  - **Notes:** One-time migration; clones and converts in a single pass

- **git-svn command / flag:** `--stdlayout` / `-s`
  - **This skill's equivalent:** `--stdlayout`
  - **Notes:** Identical — assumes `trunk/`, `branches/`, `tags/` layout

- **git-svn command / flag:** `--trunk <path>` / `-T <path>`
  - **This skill's equivalent:** `--trunk <path>` / `-T <path>`
  - **Notes:** Identical

- **git-svn command / flag:** `--branches <path>` / `-b <path>`
  - **This skill's equivalent:** `--branches <path>` / `-b <path>`
  - **Notes:** Identical; repeatable for multiple branch paths

- **git-svn command / flag:** `--tags <path>` / `-t <path>`
  - **This skill's equivalent:** `--tags <path>` / `-t <path>`
  - **Notes:** Identical; repeatable for multiple tag paths

- **git-svn command / flag:** `--authors-file <file>` / `-A <file>`
  - **This skill's equivalent:** `--authors-file <file>` / `-A <file>`
  - **Notes:** Identical file format: `svn-user = Full Name <email>`

- **git-svn command / flag:** `--no-metadata`
  - **This skill's equivalent:** `--no-metadata`
  - **Notes:** Omits the `git-svn-id` trailer from commit messages

- **git-svn command / flag:** `--ignore-paths <regex>`
  - **This skill's equivalent:** `--ignore-paths <regex>`
  - **Notes:** ⚠️ **Pattern base differs** — see note below

- **git-svn command / flag:** `--include-paths <regex>`
  - **This skill's equivalent:** `--include-paths <regex>`
  - **Notes:** ⚠️ **Pattern base differs** — see note below

- **git-svn command / flag:** `-r N:M` / `--revision N:M`
  - **This skill's equivalent:** `--revision N:M`
  - **Notes:** Identical semantics; also accepts a single revision `N`

- **git-svn command / flag:** `--prefix <prefix>`
  - **This skill's equivalent:** N/A — removed
  - **Notes:** `git svn` stored branches under `refs/remotes/<prefix>/`; this skill creates clean `refs/heads/` and
    `refs/tags/` directly

- **git-svn command / flag:** `--no-minimize-url`
  - **This skill's equivalent:** N/A — not needed
  - **Notes:** This skill always operates on the exact URL provided

- **git-svn command / flag:** `--repack` / `--repack-flags`
  - **This skill's equivalent:** N/A
  - **Notes:** `git gc --aggressive --prune=now` is always run at the end

- **git-svn command / flag:** `git svn dcommit`
  - **This skill's equivalent:** **Not supported**
  - **Notes:** One-time migration scope only; no ongoing SVN↔Git sync

- **git-svn command / flag:** `git svn rebase`
  - **This skill's equivalent:** **Not supported**
  - **Notes:** One-time migration scope only

- **git-svn command / flag:** `git svn blame`
  - **This skill's equivalent:** **Not supported**
  - **Notes:** Use `git log -S` or `git log -p` as alternatives

- **git-svn command / flag:** `git svn log`
  - **This skill's equivalent:** **Not supported**
  - **Notes:** Use `git log` after migration

- **git-svn command / flag:** `git svn info`
  - **This skill's equivalent:** **Not supported**
  - **Notes:** Use `git log` / `git show` after migration

- **git-svn command / flag:** `git svn show-ignore`
  - **This skill's equivalent:** Replaced by `--create-ignore`
  - **Notes:** `--create-ignore` (default on) writes `.gitignore` files directly and commits them

- **git-svn command / flag:** `git svn create-ignore`
  - **This skill's equivalent:** Replaced by `--create-ignore`
  - **Notes:** Same as above

- **git-svn command / flag:** `git svn mkdirs`
  - **This skill's equivalent:** **Not supported**
  - **Notes:** SVN empty directories are not tracked by Git; see troubleshooting guide

- **git-svn command / flag:** `git svn find-rev`
  - **This skill's equivalent:** **Not supported**
  - **Notes:** Use `git log --grep="git-svn-id:.*@<rev>"` to find by SVN revision

- **git-svn command / flag:** `git svn reset`
  - **This skill's equivalent:** **Not supported**
  - **Notes:** One-time migration; no incremental sync state to reset

---

## ⚠️ `--ignore-paths` and `--include-paths`: important base path difference

This is the most likely source of confusion when adapting an existing `git svn` config.

| Implementation | Pattern matched against                                        |
| -------------- | -------------------------------------------------------------- |
| `git svn`      | **Repo-root-relative** path, e.g. `/trunk/src/generated/foo.c` |
| This skill     | **Ref-root-relative** path, e.g. `src/generated/foo.c`         |

**Example:** to exclude the `generated/` directory under trunk:

```bash
# git svn (old)
git svn clone ... --ignore-paths "^/trunk/generated/"

# This skill (new) — drop the leading /trunk/
bash scripts/migrate.sh run ... --ignore-paths "^generated/"
```

The same adjustment applies to branch and tag refs: patterns are always relative to the ref's own root, not to the SVN
repository root.

---

## What is NOT supported (and why)

This skill is scoped to **one-time migration**. It is not a bidirectional bridge or an ongoing sync tool. The following
`git svn` subcommands are intentionally out of scope:

- **Unsupported command:** `dcommit`
  - **Reason:** Pushes git commits back to SVN. Requires ongoing state and a live SVN connection post-migration. Out of
    scope.

- **Unsupported command:** `rebase`
  - **Reason:** Pulls new SVN commits into an existing git-svn clone. Only relevant for active mirroring.

- **Unsupported command:** `blame`
  - **Reason:** Annotates lines with SVN revision info. Use `git blame` after migration.

- **Unsupported command:** `log`
  - **Reason:** Displays SVN log with git-svn metadata. Use `git log` after migration.

- **Unsupported command:** `info`
  - **Reason:** Shows SVN working-copy info. Not applicable after migration.

- **Unsupported command:** `show-ignore`
  - **Reason:** Prints `svn:ignore` patterns. Replaced by `--create-ignore` which writes `.gitignore` files directly.

- **Unsupported command:** `mkdirs`
  - **Reason:** Recreates empty SVN directories. Not tracked by Git; see troubleshooting guide for workarounds.

- **Unsupported command:** `find-rev`
  - **Reason:** Finds git commit SHA for a given SVN revision. Use `git log --grep` on the `git-svn-id` trailer.

- **Unsupported command:** `reset`
  - **Reason:** Resets git-svn tracking state. Not applicable to a completed one-time migration.
