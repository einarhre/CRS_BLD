# Regression tests

From the repository root, run:

```sh
tests/run-tests.sh
```

The Bash entry point runs the existing cross-compiler shell suite, the existing
Python unittest suite, and focused Bash checks of the aggregate runner. Once the
shared Bash prerequisite is accepted, all three are attempted in that order even
when an earlier suite fails. If Bash is missing or too old, all three dependent
phases are explicitly reported as `not run`, without numeric exit statuses;
the Python fixtures also require that Bash. The overall status is zero only
when all three succeed. Missing mandatory runners or interpreters, failed
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
these suites. The Python macOS test is a Linux simulation. There are currently
no direct suites for `make_pkgs.sh` or `etc/diagnostics.sh`, and `etc/common.sh`
is largely covered indirectly. The aggregate runner rejects an entirely empty
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
