# Regression tests

From the repository root, run:

```sh
tests/run-tests.sh
```

The Bash entry point runs the existing cross-compiler shell suite, the existing
Python unittest suite, focused Bash checks of the aggregate runner, and the
infrastructure characterization suite (see below). Once the
shared Bash prerequisite is accepted, all four are attempted in that order even
when an earlier suite fails. If Bash is missing or too old, all four dependent
phases are explicitly reported as `not run`, without numeric exit statuses;
the Python fixtures also require that Bash. The overall status is zero only
when all four succeed. The infrastructure runner and each of its five
components (`t_common_*`, `t_diag_*`, `t_harness_*`, `t_pkgs_*`, `t_pkgs_support_*`) must exist and
contribute at least one hard test, otherwise the phase fails. Missing mandatory runners or interpreters, failed
discovery and empty suites are errors, not skips. Shell discovery must include
at least one hard (`t_*`) test. The dispatcher takes no filtering arguments.

Each suite prints its own results. The shell runner prints pass, failure,
advisory-failure, skip and demonstration information; Python runs with verbosity
2 to show skipped test IDs and reasons. The final dispatcher summary reports
observed phase exit statuses or `not run`, without inferring test counts. A suite
that fails before producing a count has no reliable count to report. Existing
shell advisory failures and demonstrations remain non-gating, as before.

The script locates tests relative to itself, so it can also be invoked by
absolute path from another working directory. It passes through `CRS_ROOT`
(alternate implementation checkout), `TMPDIR` and `KEEP_SANDBOX` to the existing
suites. Python runs with `-B` to avoid writing bytecode into the checkout. Test
discovery stays in this checkout; `CRS_ROOT` selects the implementation under test.

## Separate commands

The existing entry points and their options remain supported:

```sh
tests/run-cross-compiler-tests.sh
tests/run-cross-compiler-tests.sh -l
tests/run-cross-compiler-tests.sh -k '_cc_|_hdr_'
tests/run-cross-compiler-tests.sh tests/cross-compiler/test_headers.sh
python3 -B -m unittest discover -s tests -p 'test_*.py' -v
```

The Python phase uses the same unittest discovery through its standard-library
API with the CLI's default warning filter, so it can reject zero discovered tests
before running them. Its stdin is the consumed discovery heredoc; current tests
do not read stdin. It does not
replace any test or fixture. The aggregate runner's lightweight checks can run
separately without running the compiler regression suites:

```sh
bash tests/runner/test_run_tests.sh
```

Those checks copy the dispatcher to temporary directories, install fake suite
runners and tiny unittest fixtures, and test continuation, statuses, skip output,
missing interpreters/runners, the Bash version gate, discovery errors and
absent/empty suites. The fake shell runner rejects unexpected arguments so a
filtered aggregate invocation cannot pass. The bytecode check clears inherited
`PYTHONDONTWRITEBYTECODE` and `PYTHONPYCACHEPREFIX` rather than masking a missing
`-B`. Their fake self-check runner records execution without recursive aggregate
execution. Standalone checks require Python and diagnose its absence explicitly.

Syntax checks remain a separate validation step, for example:

```sh
bash -n tests/run-tests.sh
bash -n tests/runner/test_run_tests.sh
bash -n make_cross-compiler.sh
git diff --check
```

## Infrastructure characterization tests

`tests/infrastructure/` characterizes the *current* behavior of `etc/common.sh`
(`test_common.sh`), package-only helpers (`test_pkgs_support.sh`), `etc/diagnostics.sh` (`test_diagnostics.sh`) and
`make_pkgs.sh` (`test_make_pkgs.sh`); `test_harness.sh` tests the runner and
`lib.sh` themselves. The characterization tests assert what the scripts do
today, including quirks, not what a corrected version should do; a deliberate
behavior change must update the matching test.

```sh
tests/infrastructure/run-infrastructure-tests.sh        # all test_*.sh files
tests/infrastructure/run-infrastructure-tests.sh -l     # list (fails on load errors)
tests/infrastructure/run-infrastructure-tests.sh -k '_lock_|_ncrs_'
tests/infrastructure/run-infrastructure-tests.sh tests/infrastructure/test_common.sh
```

Discovery is automatic: without file arguments every `test_*.sh` in the
directory is loaded, and the five files named above are mandatory. With file
arguments only those files are loaded. A file fails discovery (and the run) if
it is missing or empty, fails `bash -n`, returns nonzero or writes any byte to
stdout or stderr (even a lone newline) while being sourced, if listing or
sorting its test names fails or loses a name, if the whole step (syntax check,
sourcing, listing and sorting run in one supervised process) exceeds
`INFRA_DISCOVERY_TIMEOUT` (default 30 s), if it defines no `t_*` test, or if
it redefines another file's test.

Outcomes: `t_*` tests gate (`PASS`, `FAIL`, or `SKIP` on exit 77). The remaining
`k_pkgs_support_lock_acquire_spins_forever_when_parent_missing` demonstrates the
known uncreatable-lock-path wait, deferred to R3 Phase 2. Lock-run failure cleanup
and per-configuration-list leakage now have mandatory `t_*` regressions.
`KNOWN-DEFECT-REPRODUCED` (exit 0), `-NOT-REPRODUCED` (exit 1) and `-SKIPPED`
(exit 77) are non-gating; `-ERROR` (timeout, signal, load or other failure) gates.
Package-driver tests skip on Bash older than 5.1. An optional real-old-Bash test
uses `CRS_OLD_BASH` (or an available named old binary), otherwise explicitly skips;
static gate-order coverage is reported separately.

Moved helper tests are named `t_pkgs_support_*` and source common once followed by
support. Mandatory discovery includes `test_pkgs_support.sh`; spawned-worker
and unusual-TMPDIR harness selections use the migrated exact names. Ownership
tests enforce definitions-only support and absence from compiler/diagnostics.
The compiler shell suite tests a support-file edit remaining a true no-work hit;
Python's compiler fixtures still work without that file.

`test_lock_signals.py` uses only synthetic paths, bounded process groups and an
allowlist of ordinary utilities. It explicitly establishes default SIGINT for
foreground tests and startup-ignored SIGINT for the async-worker case. TERM/HUP
to the holder must retain the lock until the protected foreground child finishes.
ICU tests invoke only its custom function with fabricated configure/make spies;
recipe hooks and real compilers are never executed. NCRS tests cover ASCII,
canonicalization, bounds, huge values, defaults/failure and pre-mutation rejection.

Supervision and cleanup: each test and each discovery step runs in a fresh
`bash --noprofile --norc` with nounset, in its own process group, under a
watchdog (`INFRA_TEST_TIMEOUT`, default 120 s; TERM, then KILL after
`INFRA_KILL_GRACE`, default 5 s). When a test ends for any reason - pass,
failure, timeout, kill - the runner signals what remains of that process group
and of the GNU `timeout` groups the test registered, waits for them to exit, and
then removes the per-test directory it created under its own run directory in
`TMPDIR`. INT, TERM and HUP to the runner do the same before it exits.
Mandatory cleanup is part of the result: if a process group cannot be reaped
or a runner-created file or directory (including the final run directory)
cannot be removed, an otherwise successful run or listing exits 3, and an
existing failure status is kept. Only
process groups created for the run are signalled; there is no name-based
killing. A process that deliberately starts its own session or process group
without registering it, or that clears its environment and re-parents itself,
is outside this guarantee.

Sandboxes: `sandbox_new` aborts the test (exit 90, `HARNESS-ERROR`) if its
directory cannot be allocated, resolved or verified as an owned, non-symlink
directory, before the body runs; `SB` stays unset until then and test processes
run with nounset. Recursive removal (`safe_rm_tree`) requires a root that is its
own physical path and a target whose parent resolves physically to exactly its
spelling (so no intermediate component is a symlink); ambiguous paths are
rejected, not normalized. The runner itself removes only direct children of its
physical run directory, and removes a symlink there without following it.

Command isolation: the scripts under test run only through `run_ctl`
(`env -i`, an explicit variable list, `HOME` inside the sandbox, no Bash startup
files) with `PATH` limited to symlinks to an allowlist of ordinary utilities
(coreutils, find, grep, sed, tar, gzip, ...) plus spies. There is no fallback to
the host `PATH`. `uname` is pinned to Linux unless a test asks for a simulated
Darwin; `pkg-config` is a stub. make, meson, ninja, cmake, the configure script
and the glib helpers are command spies that record `%q`-encoded argv with an
argument count, and `tar` is a logging wrapper around the real tar used on
synthetic archives. Compilers, linkers, assemblers, binutils, downloaders, VCS
clients, package managers, `patch`, `install` and `sudo` are either absent or
"forbidden" spies; using one fails the test. Commands named by absolute path
cannot be intercepted this way, and the scripts under test do not use any.

Paths: tests pass sandbox paths as arguments, never by interpolation into
script text. `test_harness.sh` runs representative tests under TMPDIR paths
containing spaces, apostrophes, tabs and newlines. Diagnostics tests skip under
a newline (a `.pc` variable cannot hold one). A colon in TMPDIR or in the
sandbox path is rejected before anything is created or run (runner exit 2,
`sandbox_new` exit 90), because sandbox directories are placed on `PATH` and a
colon would add an unintended search directory.

Homebrew/macOS handling is exercised with a mocked `uname`/`brew` on Linux only;
native macOS is not tested.

## Language policy and prerequisites

Bash is preferred for test orchestration and ordinary command workflows. Python
remains appropriate for binary/NUL data, precise filesystem operations,
nanosecond timestamps and independent metadata expectations. One entry point
does not require one test language. This entry-point change migrates no tests
and redesigns no shared mocks.

Use Bash 4.4 or newer on `PATH`, Python 3 with the standard-library modules used
by the existing tests (including gzip/xz archive support), and the Unix/GNU tools
required by the existing fixtures. macOS's system Bash 3.2 is insufficient; use
a modern Bash and Homebrew GNU tools on the test host's `PATH`. The driver's
macOS tool setup does not configure the parent test runner's environment.

The header fixture needs GNU make and uses a fake compiler. Real ZIP checks
require zip/unzip. Permission checks depend on root versus non-root execution.
Missing optional fixture capabilities retain the existing suites' skip policy;
the aggregate runner does not turn those skips into passes or require them to
run. Missing mandatory Bash/Python interpreters always fail the invocation.
An entirely skipped but nonempty suite retains its existing successful status;
there is no new all-skipped failure threshold (review finding L4, deferred).

## Baseline and limits

At `5efea23`, shell discovery lists 356 names: 348 hard tests, seven advisory
checks and one demonstration. On the audited non-root Linux host, 345 checks
passed (including the advisories), ten skipped, and the object-rewriting
demonstration was not reproduced. The skipped scan-failure shims were for awk,
ls, od, openssl, perl, python3, readlink, sha512sum, shasum and uniq, which the
implementation does not use in its metadata scan. Python discovers 92 tests:
91 passed and the root-only numeric-ownership test skipped. These are reference
results, not hardcoded runtime expectations; prerequisites can change skips.
The aggregate runner's own checks are additional and reported separately.

The existing suites use isolated temporary prefixes and mocked tools or tiny
GNU make fixtures. They perform no real GCC/MinGW compilation. Preserve valuable
source, build and install trees; never use a production prefix as a test fixture.

Native macOS operation and real compiler correctness are not established by
these suites. The Python macOS test is a Linux simulation. `etc/common.sh`,
`etc/diagnostics.sh` and `make_pkgs.sh` have direct characterization tests
(above), not real-build coverage; general package recipes under `src/pkg/cfg` remain untested; ICU host-tools lock behavior has a synthetic spy fixture. The aggregate runner rejects an entirely empty
suite, but does not enforce a complete baseline manifest or detect every partial
discovery loss. Existing timeout, environment-isolation and advisory policies
are unchanged. For the completion-cache contract and limits, see
[the recovery specification](../docs/cross-compiler-resume-spec.md); historical
test provenance remains in
[COMPLETION-CACHE-TESTS.md](cross-compiler/COMPLETION-CACHE-TESTS.md).

Signal forwarding (review finding L2) is deferred. SIGINT delivered to the process
group interrupts the run without a final summary. SIGTERM sent only to the
dispatcher's PID is not forwarded and can leave its current child running;
supervisors should terminate the process group. Continuation after an ordinary
suite failure does not promise continuation or a summary after a signal.
