# CRS_BLD — Cross-compiler build recovery

## Objective

Improve `make_cross-compiler.sh` so that an interrupted build can be restarted safely using the same command, preserving valid completed work and repeating incomplete work.

The solution must preserve existing successful build behavior on Linux and macOS.

## Functional requirements

### R1. Command-line arguments

- Preserve the existing interface: `make_cross-compiler.sh GCC_VERSION`.
- Accept exactly one valid GCC version or `git`.
- Match available GCC versions exactly, not by substring.
- Reject missing, ambiguous, or unsupported versions before destructive operations.
- Provide useful error messages.
- Validate `NCRS` as a positive integer.

### R2. Source preparation

- Do not treat the GCC symbolic link alone as evidence of completed preparation.
- Record successful preparation only after all required preparation operations have completed.
- If preparation is interrupted, the next invocation must recognize the incomplete state.
- Validate the selected GCC, Binutils, and MinGW source identities before reusing previous results.
- Avoid silently reusing incompatible build trees.

### R3. Configuration

- Do not use `config.log` as the sole indication of successful configuration.
- Retry configuration when a previous attempt failed or was interrupted.
- Preserve successfully configured build directories when the relevant inputs remain compatible.
- Preserve useful diagnostic logs when configuration fails.

### R4. Build resumption

- Reuse existing build artifacts when the sources and build configuration remain compatible.
- Continue using the existing `make` dependency tracking.
- Revisit build and installation stages as needed to repair incomplete outputs.
- Do not introduce an unnecessary per-stage checkpoint system.
- Do not require an explicit `--resume` argument for ordinary recovery.

### R5. Changed build inputs

- Detect relevant changes in source selection and build configuration.
- Do not silently reuse incompatible configured build trees.
- Reject unsafe reuse with an explanatory message.
- Do not automatically delete valuable build artifacts merely because compatibility cannot be established.
- Changing only the parallel job count must not invalidate a compatible build.

### R6. Repeatable installation and packaging

- Repeated DLL relocation must succeed when the required DLL is already at its destination.
- Interrupted installation or packaging must be recoverable.
- Preserve the existing output format and target architecture behavior.

## Verification requirements

Tests must use isolated temporary directories and simulated build tools, without compiling GCC.

Test at least:

1. Valid and invalid arguments.
2. Exact version matching and archive discovery.
3. Interrupted source preparation.
4. Failed and interrupted configuration.
5. Interrupted compilation and installation.
6. Repeated invocation after successful completion.
7. Recovery after finishing the first target but failing during the second.
8. Changed and unchanged build inputs.
9. Repeated DLL relocation and packaging.
10. Preservation of compatible build artifacts.

Regression tests for confirmed defects must fail against the original implementation before fixes are evaluated.

## Constraints

- Do not modify `make_pkgs.sh`.
- Preserve Linux and macOS compatibility.
- Avoid new runtime dependencies where possible.
- Avoid real compiler builds during automated regression testing.
- Do not weaken tests merely to make an implementation pass.
- Do not create Git commits unless explicitly requested.

## Division of responsibility

**Claude Code:** Independently develop regression and edge-case tests from this specification, using the original implementation as the baseline.

**Codex:** Independently design and implement the smallest maintainable correction, with its own focused tests.

**Human reviewer:** Compare the results, run Claude's tests against Codex's implementation, inspect changes in Vim, and approve integration.
