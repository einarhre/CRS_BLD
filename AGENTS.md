# CRS_BLD — Development guidance

## Project and scope

CRS_BLD builds MinGW-w64 cross-compilers and supporting libraries on Linux and macOS.

Main entry points:
- `make_cross-compiler.sh`: compiler and toolchain construction.
- `make_pkgs.sh`: supporting-library builds.
- `etc/common.sh`: shared shell functions and platform setup.
- `etc/diagnostics.sh`: diagnostics.

For changes to cross-compiler source preparation, recovery, configuration, installation, packaging or completion caching, read `docs/cross-compiler-resume-spec.md` first. That document defines the expected behavior and known limits; existing code and tests must still be inspected before editing.

## Safety and change boundaries

- Preserve Linux and macOS behavior. Do not claim native macOS verification from Linux-only or simulated tests.
- Keep changes focused; do not refactor unrelated scripts or modify `make_pkgs.sh` for a cross-compiler-only task without a clear need and authorization.
- Treat existing `src/`, `build/` and `install/` trees, toolchain archives and packages as valuable. Do not delete, reset, overwrite or relocate them merely to simplify testing.
- Never use the production build prefix as a test fixture. Use disposable temporary directories for automated tests and a separately designated `PREF` for explicitly authorized real builds.
- Do not run full GCC/MinGW builds as part of automated regression tests. A real integration build requires explicit authorization, an isolated prefix and a preservation plan.
- Do not assume a `make`-up-to-date result proves the full target pipeline completed. A completion-cache hit must satisfy the compatibility, record and metadata rules in the specification.
- A changed or missing completion record may trigger an expensive replay. Never remove one casually, especially in a populated prefix.
- A `PREF` has a single writer; do not run concurrent builds or modify its artifacts during a completion scan.
- Respect the current task's read-only, worktree, commit, merge and push boundaries. Do not commit, merge, push or modify another worktree without explicit authorization.

## Verification and reporting

- Prefer regression tests that reproduce a confirmed failure before implementing its correction.
- Use temporary directories and mocked tool invocations for automated tests; include actual GNU `make` fixtures when useful, without compiling a real toolchain.
- After cross-compiler logic changes, run the relevant shell and Python tests, and validate modified shell files with `bash -n`:

  ```sh
  tests/run-tests.sh
  bash -n make_cross-compiler.sh
  ```

  The separate suite commands remain supported; see `tests/README.md` for prerequisites, filtering and skip reporting.

- Inspect `git diff --check` and the complete diff. Do not weaken existing recovery or artifact-preservation assertions just to obtain passing tests.
- For completion-cache changes, test both a valid no-work hit and a cache miss followed by recovery. Cover incompatibility, interruption, record invalidation before mutation, ZIP publication and preservation of unrelated target artifacts.
- Report precisely which tests ran, passes/skips/failures, what was not tested (especially native macOS and real compiler builds), and any remaining limitations.
