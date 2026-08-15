<!-- fastctx:begin -->
## FastCtx tool routing

For local file reads, content searches, and path searches, prefer the FastCtx MCP
tools — `mcp__fastctx__read`, `mcp__fastctx__grep`, and `mcp__fastctx__glob` —
over `cat`/`Get-Content`, `rg`/`findstr`/`Select-String`, and recursive
`dir`/`ls` traversal. Read only what the task needs. When you need several
files, pass them to one read call as `files=[{"path": ...}, ...]` instead of
making one call per file. Pass absolute paths. The last line of every result
says `Complete` or `Partial`; continue only with the exact parameters a
`Partial` note provides.

### Mechanical replacement

Use `mcp__fastctx__replace` for mechanical find-and-replace across files. It
preserves each file's encoding and line endings, supports dry-run previews,
and rejects concurrent changes before writing.

### Fallback boundary

For the same operation goal supported by FastCtx, do not fall back to native
PowerShell or Bash until three consecutive, reasonable FastCtx attempts have
failed. Every retry must correct the command, path, arguments, or strategy
based on the previous failure. Never repeat an unchanged failing call merely
to reach three attempts. When falling back after the third corrected failure,
briefly state that FastCtx failed and why.

Specialized host tools such as `apply_patch` remain exempt. Use them directly
for generated content, semantic rewrites, or small local edits; do not force
them through FastCtx.

### Shell commands

Prefer `mcp__fastctx__run` over the built-in shell for terminal work that
FastCtx can execute. It runs bash (Git Bash on Windows), so write POSIX bash,
not PowerShell syntax. Commands must be non-interactive; use flags such as
`-y` or `--no-edit`, and expect editors and pagers to be disabled. A non-zero
exit code is a normal result to diagnose, not by itself a reason to fall back.

Never pass `apply_patch` to `mcp__fastctx__run`; it is a specialized host tool,
not a shell program.

For work that may outlast `run`'s four-minute maximum, use
`mcp__fastctx__run_background`, inspect it with `mcp__fastctx__job_output`, and
stop it with `mcp__fastctx__job_kill`. Background jobs survive client restarts;
rediscover them with `mcp__fastctx__job_list` and continue by `job_id`.
<!-- fastctx:end -->