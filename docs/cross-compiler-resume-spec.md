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
- Permit one validated completion record per target to skip the entire completed
  target pipeline. A record confirms that the build, installation, DLL relocation
  and ZIP publication succeeded; it does not prove freshness of every internal
  `make` dependency.
- Validate source/configuration compatibility before trusting a completion record.
  Validate the saved metadata of the target's cross/native build and installation
  trees and ZIP before skipping any stage. A ZIP alone never proves completion.
- On missing, invalid, incompatible or stale completion metadata, continue using
  the existing `make` dependency tracking and revisit build and installation stages
  to repair incomplete outputs, preserving valuable artifacts.
- Invalidate the previous target record before the first target mutation; abort if
  invalidation fails. Publish a new record atomically only after the entire target
  pipeline and metadata scan succeed. Failed/interrupted work must not publish one.
- Do not introduce an unnecessary per-stage checkpoint system.
- Do not require an explicit `--resume` argument for ordinary recovery.

#### Completion record and validation (schema 1)

`$BUILD_DIRECTORY/.cross-complete-$TRG` is a regular, readable, non-symlink file
with exactly four newline-terminated lines:

```text
cross-completion-schema=1
target=<target triple>
policy=<SHA-256 of driver followed by common.sh>  -
metadata-sha256=<SHA-256 of serialized metadata>
```

The policy hashes the full contents of `make_cross-compiler.sh` followed by
`etc/common.sh`, covering configuration, build order, installation, DLL selection
and packaging conservatively. Comment changes can cause a harmless miss. Runtime
`NCRS` is excluded. Existing global input and prepared-source checks remain
mandatory; existing component configure-argument rejection remains in force.

Metadata roots, in order, are `build/cross/$TRG`, `build/native/$TRG`,
`install/cross/$TRG`, `install/native/$TRG`, and `install/native/$TRG.zip`, relative
to `PREF`. Each starts with a NUL-terminated `root=<relative path>` tag. The first
four roots must be real directories; the fifth must be a real regular file.
Symlink roots cannot authorize a hit. Each directory includes its own entry `.`.
Entries are ordered by raw relative path bytes in the C locale without following
symlinks. Each entry has eleven NUL-terminated GNU `stat` fields:

1. Hexadecimal mode including file type (`%f`).
2. Device number (`%d`).
3. Inode (`%i`).
4. Size (`%s`).
5. Octal permissions, including special mode bits (`%a`).
6. Numeric UID (`%u`).
7. Numeric GID (`%g`).
8. Hard-link count (`%h`).
9. Nanosecond mtime (`%y`).
10. Nanosecond ctime (`%z`).
11. Quoted relative path and, for links, destination (`%N`).

Serialization fixes `LC_ALL=C`, `TZ=UTC`, and GNU
`QUOTING_STYLE=shell-escape-always`. NUL framing, fixed field counts, root tags,
and GNU quoting make names and link destinations containing whitespace, newlines
or quotes unambiguous. Directory metadata uses the same fields. Atime is excluded
because scanning can change it. SHA-256 covers this stream; artifact contents are
not hashed. Exact record comparison rejects extra lines, trailing bytes, unknown
schemas, foreign targets, and altered identities. Records are never evaluated as
shell code. Scan, sorting, stat, reading and digest failures cannot authorize a
hit. Publication uses a temporary directory on the build filesystem and `mv` only
after safe ZIP publication and successful scanning.

#### Limitations and portability

- One writer must own a `PREF` during scanning, building and cache reuse. There is
  no writer lock or atomic filesystem snapshot. Concurrent mutation can race
  validation or record publication, including mutation immediately after a scan.
- Metadata-based validation cannot detect corruption that preserves all saved
  metadata (for example, low-level storage corruption). Timestamp precision is
  limited by the underlying filesystem even when GNU stat prints nine digits.
  Inode reuse and coarse timestamps can reduce detection. This is not a content
  integrity or authenticity guarantee; users able to forge records are trusted.
- ACLs, extended attributes and filesystem-specific flags are not independently
  serialized; changes usually affect ctime, but metadata-preserving changes need
  not be detected. External symlink referents are not traversed. Source validation
  retains its existing separate content checks.
- Cache validation requires GNU find, sort, xargs, stat and sha256sum. The driver
  checks GNU identities, exercises the required NUL/stat options, verifies the
  timestamp and quoting formats, and tests SHA-256 against the empty-input digest. Unsupported
  capabilities disable caching and use ordinary recovery; they never imply a hit.
  macOS uses Homebrew's GNU tools selected by `common.sh`. Native BSD tools alone
  do not enable this cache. GNU formatting/version changes can cause safe misses.
- Atomic rename prevents partially written records from being accepted, but there
  is no fsync-based power-loss durability guarantee. Completion also does not prove
  reproducibility, compiler correctness, or every internal dependency's freshness.

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
