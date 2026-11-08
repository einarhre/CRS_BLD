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
  Bind each record to cryptographic identities of both validated global records,
  `.cross-inputs` and `.cross-prepared`. Before legitimately republishing either
  global record on the no-artifacts path, invalidate every existing target
  completion record, before any source preparation or other relevant mutation.
  Abort on invalidation failure without changing the global compatibility identity.
  Validate the saved metadata of the target's cross/native build and installation
  trees and ZIP before skipping any stage. A ZIP alone never proves completion.
- On missing, invalid, incompatible or stale completion metadata, continue using
  the existing `make` dependency tracking and revisit build and installation stages
  to repair incomplete outputs, preserving valuable artifacts.
- Invalidate the previous target record before the first target mutation; abort if
  invalidation fails. Publish a new record atomically only after the entire target
  pipeline and metadata scan succeed. Failed/interrupted work must not publish one.
- If the post-build completion scan fails, preserve the completed artifacts and
  published ZIP, publish no completion record, and fail the invocation. A subsequent
  run uses recovery until the scan can succeed; this conservative failure is deliberate.
- Do not introduce an unnecessary per-stage checkpoint system.
- Do not require an explicit `--resume` argument for ordinary recovery.

#### Completion record and validation (schema 2)

`$BUILD_DIRECTORY/.cross-complete-$TRG` is a regular, readable, non-symlink file
with exactly six newline-terminated lines:

```text
cross-completion-schema=2
target=<target triple>
policy=<SHA-256 of driver>:<SHA-256 of common.sh>
inputs-sha256=<SHA-256 of validated .cross-inputs bytes>
sources-sha256=<SHA-256 of validated .cross-prepared bytes>
metadata-sha256=<SHA-256 of serialized metadata>
```

The policy independently hashes the full contents of `make_cross-compiler.sh` and
`etc/common.sh`, covering configuration, build order, installation, DLL selection
and packaging conservatively. Two fixed-length hexadecimal digests with an explicit
separator avoid ambiguity at the file boundary. Comment changes and unrelated
`common.sh` helper edits can cause harmless misses. Runtime `NCRS` is excluded.
Existing global input and prepared-source checks remain mandatory; existing
component configure-argument rejection remains in force. The two compatibility
digests bind exact validated file bytes, including final newlines. Schema 1 records
are rejected and replaced through recovery. Record rejection prints a diagnostic.

Global invalidation includes all `.cross-complete-*` paths, even malformed records
or unexpected target names. Regular files and symlinks are unlinked without
following links. A directory-valued path is preserved and aborts the invocation;
it is never recursively removed. Per-target invalidation uses the same safeguards.

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
- Conversely, device/inode changes after copies, restores, remounts, device
  renumbering, overlay copy-up or on some network/FUSE filesystems cause safe
  misses, even if the contents are unchanged. The metadata fields are retained
  conservatively; cache availability across filesystems is not guaranteed.
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
- The policy covers driver/shared-script contents and the existing compatibility
  checks cover their selected host tools. It does not fingerprint every helper
  binary, including `zip` and utilities used for DLL selection. Upgrading those
  helpers alone can keep an existing completed package valid; this cache confirms
  pipeline completion under the saved inputs rather than freshness of every tool.
- The capability probe checks GNU identity, simple quoting and timestamps, but
  does not round-trip hostile names at runtime. Hostile-name serialization is
  regression-tested on modern GNU tools. Legacy GNU releases that silently ignore
  `QUOTING_STYLE` are not validated; use current GNU coreutils (Homebrew on macOS).
- SIGKILL or power loss can leave invocation-owned `.cross-completion.*` and
  `.cross-package.*` staging directories. They cannot authorize a hit and are not
  automatically swept. Ordinary failure/termination cleans invocation-owned staging.

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
