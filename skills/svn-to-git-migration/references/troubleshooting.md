# Troubleshooting

Common problems and fixes for `migrate.sh` / `migrate.ps1`.

---

## 1. Authentication — SVN password prompts mid-migration

**Symptom:** Migration pauses waiting for a password, or fails with
`svn: E170001: Authentication required`.

**Causes and fixes:**

- **Interactive prompt mid-run:** SVN credential caching is off or expired. Run
  `svn info <svn-url>` manually once to trigger the credential prompt and cache the
  result, then re-run the migration.

- **Force no caching (CI/headless environments):** Pass credentials explicitly and
  disable caching:
  ```bash
  # Set env vars before running the script
  export SVN_USERNAME=myuser
  export SVN_PASSWORD=mypassword
  # The scripts forward these to svn via --username / --password --no-auth-cache
  ```

- **Cached credentials location:** `~/.subversion/auth/` (Linux/macOS) or
  `%APPDATA%\Subversion\auth\` (Windows). Delete and re-authenticate if the cache
  is corrupt.

- **svn+ssh:** Ensure your SSH key is loaded (`ssh-add -l`) and that `ssh -T
  svn+ssh://host` succeeds before running the migration. The script passes the URL
  through unchanged; SSH tunnelling is handled by SVN natively.

- **HTTPS with self-signed certificates:** Accept the certificate once by running
  `svn info <svn-url>` and answering `p` (permanently) at the prompt. Or add the
  certificate to `~/.subversion/servers` manually. To bypass certificate checks
  entirely (not recommended): `svn info --trust-server-cert-failures=unknown-ca
  --non-interactive <svn-url>`.

---

## 2. bash version error on macOS

**Symptom:**
```
bash: declare: -A: invalid option
```
or
```
ERROR: bash 4.0+ required. On macOS: brew install bash
```

**Cause:** macOS ships bash 3.2 (GPLv2) and the script requires associative arrays
(`declare -A`), available only in bash 4.0+.

**Fix:**
```bash
brew install bash
# Verify:
/opt/homebrew/bin/bash --version   # should show 5.x
```

Then invoke the script with the full path to the newer bash:
```bash
/opt/homebrew/bin/bash scripts/migrate.sh detect <svn-url>
```

Or add Homebrew bash first in your PATH:
```bash
export PATH="/opt/homebrew/bin:$PATH"
bash scripts/migrate.sh detect <svn-url>
```

---

## 3. Encoding errors — garbled commit messages

**Symptom:** Commit messages contain `?` characters, mojibake, or the `detect`
subcommand aborts with:
```
ERROR: SVN server reports encoding 'ISO-8859-1'. Re-run with --encoding ISO-8859-1 ...
```

**Cause:** The SVN server is using a non-UTF-8 encoding for commit messages and author
names. This is common on older European or Japanese repositories.

**Fix:** Pass the `--encoding` flag with the source encoding:

```bash
# Western European repositories (Windows-1252 is a superset of ISO-8859-1)
bash scripts/migrate.sh run <svn-url> --encoding Windows-1252 ...

# Japanese repositories
bash scripts/migrate.sh run <svn-url> --encoding Shift-JIS ...
```

**Common encodings:**

| Region | Likely encoding |
|--------|----------------|
| Western Europe | `ISO-8859-1` or `Windows-1252` |
| Eastern Europe | `ISO-8859-2` or `Windows-1250` |
| Japan | `Shift-JIS` or `EUC-JP` |
| China (Simplified) | `GB2312` or `GBK` |
| Russia / Cyrillic | `KOI8-R` or `Windows-1251` |

**Manual transcoding check:**
```bash
svn log -q --xml <svn-url> | iconv -f Windows-1252 -t UTF-8 | head -40
```

---

## 4. Large repositories — slow migration or timeouts

**Symptom:** Migration runs for many hours, or `svn export` times out on a large
revision.

**Context:** The script uses `svn export -r <rev>` for each revision in sequence.
For repositories with tens of thousands of revisions, this is inherently slow — each
export is a full checkout at that revision. A 50 000-revision repo can take several
hours or overnight.

**Guidance:**

1. **Run overnight or in a `screen`/`tmux` session** so it won't be interrupted:
   ```bash
   tmux new -s migration
   bash scripts/migrate.sh run <svn-url> --stdlayout --target ./repo-git
   # Detach with Ctrl-B D
   ```

2. **Migrate in revision chunks** and resume. The `--revision N:M` flag lets you
   process a range, then continue from where you left off:
   ```bash
   # First chunk
   bash scripts/migrate.sh run <svn-url> --revision 1:5000 --target ./repo-git
   # Second chunk (appends to the same target)
   bash scripts/migrate.sh run <svn-url> --revision 5001:10000 --target ./repo-git
   ```
   The script detects the existing git repository in `--target` and continues from the
   last processed revision.

3. **Exclude large binary assets** with `--ignore-paths` to speed up exports:
   ```bash
   --ignore-paths "\.(psd|ai|mov|zip|jar)$"
   ```

---

## 5. Empty directories missing after migration

**Symptom:** Directories that existed in SVN (but contained no files) are absent from
the git repository.

**Cause:** SVN tracks empty directories; Git does not. `svn export` creates empty
directories, but `git add -A` ignores them — Git only tracks files.

**Workaround:**

- Add a `.gitkeep` file manually in each intentionally-empty directory, then commit.
- To find which directories were empty in SVN:
  ```bash
  svn propget svn:ignore -R <svn-url> | grep "^\..*:"  # often empty dirs have svn:ignore set
  svn ls -R <svn-url> | grep "/$"                        # list all directories
  ```
- Cross-reference with the git tree to identify which ones are now absent:
  ```bash
  git ls-tree -r --name-only HEAD | sed 's|/[^/]*$||' | sort -u > git-dirs.txt
  ```

---

## 6. svn:mergeinfo not converted

**Symptom:** After migration, `git log --merges` shows fewer merge commits than
expected, or the merge graph doesn't reflect SVN merges.

**Cause:** SVN records merge history in the `svn:mergeinfo` property on directories.
This property is not converted — it's SVN-specific metadata with no direct Git
equivalent.

**What IS preserved:** Branch ancestry via copyfrom metadata. When a branch was
created with `svn copy` (a server-side copy), that relationship becomes a proper git
parent in the converted history. The branch point appears correctly in `git log
--graph`.

**What is NOT preserved:** Cherry-picks and partial merges recorded in
`svn:mergeinfo`. These are not needed for read-only history browsing or for most
downstream Git workflows.

If precise merge topology is critical, consider a commercial tool such as
SubGit or SVN2Git that implements `svn:mergeinfo` conversion at the cost of
significantly greater complexity and runtime.

---

## 7. Branches with no copyfrom metadata — disconnected history

**Symptom:** Migration summary warns:
```
WARNING: refs/heads/feature-x has no copyfrom metadata — created as root commit
```

After migration, `git log --graph` shows `feature-x` as a disconnected history with
no common ancestor with `main`.

**Cause:** The SVN branch was created by manually adding a directory and committing
files into it, rather than using `svn copy` (which records `copyfrom` metadata).
Without `copyfrom`, the script cannot determine where the branch originated.

**Result:** The branch becomes a **root commit** (a commit with no parent) in git.
The full history within the branch is preserved; only the connection to trunk is
missing.

**Workaround (if the branch point is known):**
```bash
# After migration, manually graft the branch onto its true parent
git replace --graft <root-commit-of-branch> <intended-parent-on-main>
git filter-repo --force    # make the graft permanent
```

---

## 8. Windows path length error (`filename too long`)

**Symptom:**
```
error: could not create leading directories of '...very/long/path...'
fatal: unable to checkout working tree
```

**Cause:** Windows has a default MAX_PATH limit of 260 characters. Deep directory
structures from SVN can exceed this.

**Fix:** Enable long paths in git (run once, requires administrator):
```powershell
git config --system core.longpaths true
```

Also enable long paths at the OS level (Windows 10 1607+ / Windows 11):
1. Open Group Policy Editor (`gpedit.msc`)
2. Navigate to: Computer Configuration → Administrative Templates → System →
   Filesystem
3. Enable: **Enable Win32 long paths**

Or via registry:
```powershell
Set-ItemProperty `
  -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" `
  -Name "LongPathsEnabled" -Value 1
```

---

## 9. svn:special symlinks appear as text files on Windows

**Symptom:** After migration on Windows, files that should be symlinks appear as
text files containing `link <target>`.

**Cause:** Windows does not create real symlinks during `svn export` unless the
process has the `SeCreateSymbolicLinkPrivilege` privilege (typically requires Developer
Mode or administrator rights). The script detects these files by checking for the
`svn:special` property and stages them as git symlink objects (mode `120000`) — but
this detection can fail in rare edge cases.

**The script handles this automatically for most cases.** If you see text files with
`link <something>` content that should be symlinks:

1. Check whether the file has `svn:special`:
   ```powershell
   svn propget svn:special <svn-url>/path/to/file -r HEAD
   ```
2. If the property is set, this is a script bug — please file an issue with the SVN
   URL, relative path, and SVN revision.
3. If the property is not set, the file genuinely contains the text `link <target>` in
   SVN (unusual but valid) and was converted correctly.

---

## 10. "Repository moved" / URL redirect errors

**Symptom:**
```
svn: E301002: In ra_serf, the OPTIONS request returned invalid XML
svn: E200009: Repository moved permanently to 'https://new.example.com/...'; please relocate
```

**Cause:** The URL you provided is an alias, redirect, or old address. SVN is strict
about canonical URLs.

**Fix:** Find the canonical URL using `svn info`:
```bash
svn info <your-url>
# Look for the line: Repository Root: https://...
```

Use the value from `Repository Root:` as your `<svn-url>` argument. This is the URL
the SVN server considers authoritative, and all `copyfrom` paths in the repository
are relative to it.

---

## 11. ExecutionPolicy blocks script execution

**Symptom:**
```
File migrate.ps1 cannot be loaded because running scripts is disabled on this system.
```
or
```
migrate.ps1 is not digitally signed.
```

**Root cause:** Windows Group Policy can set `MachinePolicy` or `UserPolicy` to
`Restricted` or `AllSigned`. These policy-enforced settings **cannot be overridden**
with `-ExecutionPolicy Bypass` on the command line — that flag only overrides
user-level (`CurrentUser`) and machine-level (`LocalMachine`) preferences, not
GPO-enforced policies.

**Resolution — use Snippet Mode (recommended):**

See the **"Snippet Mode (Execution Policy Blocked)"** section in `SKILL.md` for the
full guided flow. In short: paste each phase as a code block into an interactive
`powershell.exe` or `pwsh.exe` window. Interactive input is evaluated by the REPL,
not as a script file, and is therefore **never** subject to ExecutionPolicy — even
under the strictest GPO.

**Workaround — paste into interactive PowerShell:**

```powershell
# Open powershell.exe or pwsh.exe interactively, then paste:
$SkillDir = 'C:\path\to\skill\svn-to-git-migration'
. "$SkillDir\scripts\_migrate.core.ps1"
# ... then call functions directly or use the phase subcommand
```

**Check your current policy levels:**
```powershell
Get-ExecutionPolicy -List
# MachinePolicy / UserPolicy set by GPO → cannot be bypassed
# Process / CurrentUser / LocalMachine set by admin/user → can be bypassed
```

**Why -ExecutionPolicy Bypass sometimes still works:** If only `LocalMachine` is set
to `Restricted` (not a GPO-enforced policy), `-ExecutionPolicy Bypass` overrides it
successfully. The block only applies when the *Policy* columns show a restrictive value.
