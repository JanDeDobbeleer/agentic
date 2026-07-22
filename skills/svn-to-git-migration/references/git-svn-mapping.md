# git-svn → This Skill: Flag Mapping

This document maps every `git svn` CLI switch to the equivalent option in the
skill (bash: `scripts/migrate.sh`, Windows: inline phases). Use it when you're
migrating an existing `git svn` workflow or adapting a `git svn clone` command you
found in documentation.

---

## Command equivalents

| git-svn command / flag | This skill's equivalent | Notes |
|------------------------|-------------------------|-------|
| `git svn clone <url>` | bash: `scripts/migrate.sh run <url>` / Windows: phase runbooks (see `phases/run-phase.md`) | One-time migration; clones and converts in a single pass |
| `--stdlayout` / `-s` | `--stdlayout` | Identical — assumes `trunk/`, `branches/`, `tags/` layout |
| `--trunk <path>` / `-T <path>` | `--trunk <path>` / `-T <path>` | Identical |
| `--branches <path>` / `-b <path>` | `--branches <path>` / `-b <path>` | Identical; repeatable for multiple branch paths |
| `--tags <path>` / `-t <path>` | `--tags <path>` / `-t <path>` | Identical; repeatable for multiple tag paths |
| `--authors-file <file>` / `-A <file>` | `--authors-file <file>` / `-A <file>` | Identical file format: `svn-user = Full Name <email>` |
| `--no-metadata` | `--no-metadata` | Omits the `git-svn-id` trailer from commit messages |
| `--ignore-paths <regex>` | `--ignore-paths <regex>` | ⚠️ **Pattern base differs** — see note below |
| `--include-paths <regex>` | `--include-paths <regex>` | ⚠️ **Pattern base differs** — see note below |
| `-r N:M` / `--revision N:M` | `--revision N:M` | Identical semantics; also accepts a single revision `N` |
| `--prefix <prefix>` | N/A — removed | `git svn` stored branches under `refs/remotes/<prefix>/`; this skill creates clean `refs/heads/` and `refs/tags/` directly |
| `--no-minimize-url` | N/A — not needed | This skill always operates on the exact URL provided |
| `--repack` / `--repack-flags` | N/A | `git gc --aggressive --prune=now` is always run at the end |
| `git svn dcommit` | **Not supported** | One-time migration scope only; no ongoing SVN↔Git sync |
| `git svn rebase` | **Not supported** | One-time migration scope only |
| `git svn blame` | **Not supported** | Use `git log -S` or `git log -p` as alternatives |
| `git svn log` | **Not supported** | Use `git log` after migration |
| `git svn info` | **Not supported** | Use `git log` / `git show` after migration |
| `git svn show-ignore` | Replaced by `--create-ignore` | `--create-ignore` (default on) writes `.gitignore` files directly and commits them |
| `git svn create-ignore` | Replaced by `--create-ignore` | Same as above |
| `git svn mkdirs` | **Not supported** | SVN empty directories are not tracked by Git; see troubleshooting guide |
| `git svn find-rev` | **Not supported** | Use `git log --grep="git-svn-id:.*@<rev>"` to find by SVN revision |
| `git svn reset` | **Not supported** | One-time migration; no incremental sync state to reset |

---

## ⚠️ `--ignore-paths` and `--include-paths`: important base path difference

This is the most likely source of confusion when adapting an existing `git svn` config.

| Implementation | Pattern matched against |
|----------------|------------------------|
| `git svn` | **Repo-root-relative** path, e.g. `/trunk/src/generated/foo.c` |
| This skill | **Ref-root-relative** path, e.g. `src/generated/foo.c` |

**Example:** to exclude the `generated/` directory under trunk:

```bash
# git svn (old)
git svn clone ... --ignore-paths "^/trunk/generated/"

# This skill (new) — drop the leading /trunk/
bash scripts/migrate.sh run ... --ignore-paths "^generated/"
```

The same adjustment applies to branch and tag refs: patterns are always relative to
the ref's own root, not to the SVN repository root.

---

## What is NOT supported (and why)

This skill is scoped to **one-time migration**. It is not a bidirectional bridge or an
ongoing sync tool. The following `git svn` subcommands are intentionally out of scope:

| Unsupported command | Reason |
|---------------------|--------|
| `dcommit` | Pushes git commits back to SVN. Requires ongoing state and a live SVN connection post-migration. Out of scope. |
| `rebase` | Pulls new SVN commits into an existing git-svn clone. Only relevant for active mirroring. |
| `blame` | Annotates lines with SVN revision info. Use `git blame` after migration. |
| `log` | Displays SVN log with git-svn metadata. Use `git log` after migration. |
| `info` | Shows SVN working-copy info. Not applicable after migration. |
| `show-ignore` | Prints `svn:ignore` patterns. Replaced by `--create-ignore` which writes `.gitignore` files directly. |
| `mkdirs` | Recreates empty SVN directories. Not tracked by Git; see troubleshooting guide for workarounds. |
| `find-rev` | Finds git commit SHA for a given SVN revision. Use `git log --grep` on the `git-svn-id` trailer. |
| `reset` | Resets git-svn tracking state. Not applicable to a completed one-time migration. |
