---
applyTo: "**/*.go"
---

# Go

Refer to `skills/golang/SKILL.md` for the full Go coding standards.

Key rules to always apply:

- **Never use `else`** — use early returns, `continue`, or `break` instead; keep the happy path left-aligned
- Names use `mixedCaps`/`MixedCaps`; avoid `_` in package names; no stuttering (`http.Server` not `http.HTTPServer`)
- Interfaces use `-er` suffix; keep them small (1–3 methods); accept interfaces, return concrete types
- Wrap errors with `fmt.Errorf("...: %w", err)`; name error vars `err`; error strings start lowercase
- Log with the codebase `log` package only; use `defer log.Trace(time.Now(), args)` for complex calls
- Line length max 180 characters
- **Pre-commit gate** (all must pass before committing):
  `modernize --fix ./...`, `fieldalignment --fix ./...`, `go mod tidy`, `gofmt -w .`, `golangci-lint run`
- Always use named fields in struct literals so `fieldalignment` rewrites don't break positional init
- When adding platform-specific files (`_unix.go`, `_windows.go`), cross-compile for the other platform
