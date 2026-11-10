# Shared shell infrastructure

`etc/common.sh` initializes strict Bash options, repository-relative/overridden
PREF paths, target constants, GNU tool PATH on macOS, pkg-config and readonly
NCRS. `comp_fail` remains shared by both drivers. Source common once per shell;
its readonly declarations intentionally do not support repeated sourcing.

`make_pkgs.sh` sources the definitions-only `etc/pkgs-support.sh` after common.
That file owns `empty_trash_bin`, `put_into_trash_bin`, `lock_acquire`,
`lock_release` and `lock_run`. Sourcing it changes no variables, options, traps,
PATH or files. It relies on common's GNU PATH setup (NUL sort, GNU utilities),
and its trash helper needs Bash >=4.4. The package driver requires >=5.1 for
`wait -n -p`; the compiler and test baseline remains >=4.4.

The compiler and diagnostics do not source package support. Diagnostics retains
its three-argument `check_pc_vs_files` internally; common's obsolete,
undocumented one-argument sourced API was removed without a compatibility copy.
Recipes, worker orchestration and nested generator callbacks retain their owners.

## Job counts

Explicit NCRS is checked before Homebrew/pkg-config setup or any filesystem
mutation. Only ASCII decimal digits are accepted, leading zeros are stripped,
and the canonical value must be 1..4096. Empty, signed, whitespace-containing,
hexadecimal, fractional, Unicode-digit and arbitrarily large inputs are rejected.
When NCRS is unset, GNU `nproc --all` is run after platform PATH setup. Failed,
empty or otherwise invalid output is rejected; a valid positive default above
4096 is clamped to 4096 with a stderr note. Readonly NCRS stores the canonical
number, so package scheduling never interprets a leading zero as octal.

## Lock contract

`lock_run DIR CMD [ARGS...]` acquires DIR through atomic mkdir and runs protected
work in a nested child subshell. Variables, cwd, functions, options and callback
traps do not escape to the holder or caller. `exit N` exits the callback only;
the caller receives N. Use filesystem outputs or status to communicate results.

A private holder EXIT trap embeds the acquired path with shell quoting at trap
installation time. Callback variables cannot redirect release; callback EXIT
traps cannot replace the holder's trap. Release uses only non-recursive rmdir.
Never put entries inside DIR, delete/replace it, or acquire the same lock again
from the callback. External lock-directory replacement is outside this contract.
No automatic stale-lock deletion or writer ownership recovery is attempted.

Callback status is preserved. If release fails and the lock still exists, an
error is printed; successful work becomes status 1, while a failing callback's
original status wins. If the lock has already vanished, status is unchanged.
SIGKILL or power loss may leave a lock. Acquisition behavior is unchanged:
uncreatable paths can wait indefinitely, as can legitimate/stale-directory
contention. Race-free error classification is deferred to Phase 2.

INT/TERM/HUP handlers exit with 130/143/129 after Bash finishes waiting for the
protected foreground child. They must not release while that work still runs.
Signals ignored at shell startup remain ignored, including SIGINT in relevant
async-worker contexts. Detached/background callback work is not covered: the
callback must wait for every protected child before it returns.

Bash conditional callers (`if`, `!`, `||`, `&&`) disable errexit throughout a
callback even when it uses subshells. Callbacks must explicitly handle every
failure that must stop subsequent work. ICU checks native configure/make/touch
before publishing `.built` and stops target work after host failure. Meson/CMake
generators explicitly remove partial output on a failed write. Successful writes
are serialized, not atomically renamed; SIGKILL/power-loss partial output and
ICU `.built` input identity remain limitations.

## Temporary lists and interruption

Parent, per-configuration and worker mktemp allocations check status and empty
output before proceeding. Worker source/build cleanup retains its existing
DELETE flags and applies even on failure. After workers have all been reaped,
a successful configuration drains its shared-artifact list and unsets its name.
On failure the parent EXIT trap removes only the current list by variable,
preserving shared ICU host tools for inspection/reuse. No stale list pathname is
registered permanently in the parent's trash bin. This preserves existing
success cleanup output and failed-worker reporting/scheduling.

Coordinated cancellation remains deferred. If a parent exits while workers
continue, parent cleanup can remove generated configurations or the current
list before workers stop; a later registration can fail. Do not interpret this
ordinary-failure fix as a full process-tree cancellation guarantee.

## Compiler completion policy

The full bytes of `make_cross-compiler.sh` and `etc/common.sh` still determine
the policy, with unchanged schema-2 compatibility, record, metadata and staging
checks. Extraction/removal/NCRS edits therefore legitimately invalidate old
completion records. Compatible recovery can replay installs and ZIP publication;
no real toolchain build should be run against an intermediate revision just to
observe that effect. Deliver all contiguous common-file commits together before
the next production invocation. Package-support-only edits later leave a valid
compiler completion reusable, because the compiler never executes that file.
Moving a compiler dependency into an unhashed file would require explicitly
extending the policy; a source statement alone cannot fingerprint its target.
