# Completion-cache regression tests

Tests for the planned "verified per-target completion cache" in
`make_cross-compiler.sh`.  They are test-only: no production file was changed, and
they are expected to **fail against the current implementation** (master
`86d55ac`) until the feature exists.  Nothing compiles anything; all tools are
simulated (see `lib.sh`), and the real-make fixture runs GNU make on generated
Makefiles with a fake compiler.

## Running

```sh
tests/run-cross-compiler-tests.sh                            # whole shell suite (old + new)
tests/run-cross-compiler-tests.sh -k '_cc_|_hdr_|^d_'        # only the completion-cache tests
tests/run-cross-compiler-tests.sh tests/cross-compiler/test_headers.sh
python3 -m unittest discover -s tests -p 'test_*.py'         # Python suite (old + new)
CRS_ROOT=/path/to/other/checkout tests/run-cross-compiler-tests.sh
CRS_ROOT=/path/to/other/checkout python3 -m unittest discover -s tests -p 'test_*.py'
```

`CRS_ROOT` points both suites at another checkout (it was already supported by
the shell runner; the Python suite now honours it as well), so the same tests
can be run against another implementation.

Runner additions: an exit status of 77 is reported as `SKIP` (e.g. no GNU make,
or running as root for permission tests); tests named `d_*` are
*demonstrations* of behaviour of the implementation under test and never affect
the exit status (`DEMO-REPRODUCED` / `DEMO-NOT-REPRODUCED`).

## Observable contract the tests assume

The design is only specified by behaviour, so the tests assume exactly this:

1. After a target was built, installed, its DLL relocated and its ZIP
   published, **one completion record per target** exists.  Where it lives and
   how it is formatted is free, except that **the record's path must name its
   target triple** (so that "the record of `x86_64-w64-mingw32`" is identifiable
   black-box) and that it is **not a symlink**.  The tests find the records by
   elimination: any file under `PREF` (outside `src/`) or `HOME` that the original
   implementation and the simulated tools never create (`CC_KNOWN_RE` in
   `lib_completion.sh`).
2. A target whose record and metadata snapshot validate is **skipped entirely**:
   no `make`, `configure`, `zip` or source-preparation tool runs for it, and no
   artifact is touched (no mtime/ctime change below `build/` or `install/`, except
   the record files and their directories).
3. Otherwise the **existing recovery procedure runs unchanged**: every stage of the
   target in the original order, then packaging exactly once
   (`assert_target_replayed`).  Re-configuration is allowed when `Makefile`s are
   gone.
4. The record is invalidated (deleted or rewritten) **before the first tool that
   can modify the target runs** (checked by a spy in the simulated `make`, `zip`
   and `configure`, `MOCK_SPY=1`).
5. The record is published **by a rename** (`mv`); a failed rename never yields a
   hit later (`MOCK_MV_FAIL_UNKNOWN=1`).
6. Source/configuration compatibility checks and `NCRS` validation come first and
   are unchanged: a changed environment, source or tool is still refused with an
   explanation and without touching anything, even if a complete cache exists.
   Changing only `NCRS` never invalidates a record.
7. Nothing valuable is ever removed (`assert_no_artifact_lost`, sentinels).

## Test inventory

### Shell: `test_completion.sh` (mock make; 188 `t_cc_*`, 4 `a_cc_*`, 4 `t_000_cc_*`)

| Group | Tests | Purpose |
|---|---|---|
| Hits | `completed_build_leaves_one_record_per_target`, `unchanged_repeat_does_no_work`, `two_unchanged_repeats_do_no_work`, `hit_does_not_prepare_sources_again` | A repeat of a completed build runs no tool and touches nothing; records are stable across repeats; packages stay byte-identical. |
| NCRS | `changing_only_ncrs_keeps_the_cache`, `invalid_ncrs_is_rejected_with_a_complete_cache` | Only the job count differs: still a hit.  Invalid values are still rejected first. |
| Two targets | `first_target_complete_second_interrupted_resumes_second_only`, `interrupted_second_target_does_not_disturb_first_record`, `first_target_interrupted_then_both_complete`, `change_in_one_target_does_not_invalidate_the_other`, `both_targets_modified_both_recovered`, `unrelated_file_next_to_the_packages_does_not_invalidate` | Records are per target and independent. |
| Interrupted compilation / installation (34, generated: `interrupted__<arch>_<kind>_<component>__<make-target>`) | one per stage of each target | `make` fails in that stage; no record is left; the same command completes the target (finished first target skipped), records both, then everything idles. |
| Interrupted DLL relocation, ZIP and record publication | `interrupted_dll_relocation_*`, `interrupted_zip_*`, `interrupted_zip_publication_*`, `interrupted_record_publication_never_yields_a_hit`, `failed_packaging_of_a_changed_target_is_not_completion` | Success is only declared after relocation, packaging, publication (and validation). |
| Pipeline success vs make freshness | `fresh_make_without_record_is_not_completion`, `packaging_failure_after_fresh_make_is_not_completion`, `run_that_compiled_things_records_completion` | `make` finding everything up to date is neither necessary nor sufficient for completion. |
| Mutation matrix (64, generated: `mutation__<arch>__<tree>__<kind>`) | trees: build/cross, build/native, install/cross, install/native, ZIP; kinds: delete, add file, add directory, grow, same-size edit with restored mtime, inode swap with restored mtime, chmod, chmod and restore, mtime only, hard link outside the tree (ctime only), directory chmod | A genuine hit first; then the change is detected, the target (only) is replayed, the record is invalidated before modification, nothing is lost, deleted artifacts are recovered, and the target is recorded again.  Full matrix for `x86_64`, a representative part for `i686`. |
| High resolution | `modifications_within_the_same_second_are_detected` | Same-size edits repeated immediately: timestamps are not compared at one second resolution. |
| Roots, links | `missing_*_root_is_recovered` (4), `root_replaced_by_a_file/symlink_*`, `symlink_retargeted_in_{build,install}_tree_invalidates` | Missing/changed roots; added, retargeted (same length, link mtime restored) and replaced symbolic links. |
| Records | `damaged_record__{empty,garbage,truncate,append,flip,symlink_to_copy,symlink_dangling}__<arch>` (14), `unreadable_record__*` (2), `missing_record_*` (2), `all_records_missing_*`, `record_of_the_other_target_is_rejected`, `stale_record_restored_over_a_newer_one_is_rejected` | Missing, malformed, truncated, appended, bit-flipped, symlinked (never written through), unreadable, foreign and stale records. |
| Scans | `unreadable_directory_is_never_accepted_as_complete`, `scan_failure__<tool>` (15), `metadata_scan_uses_an_external_tool_that_can_fail` | A failing scan, whichever tool of the pipeline fails and whether it dies with truncated output or after complete output, is never accepted; also a deterministic failure (unreadable directory) is never accepted. |
| Compatibility first | `changed_cflags_*`, `changed_environment_cc_*`, `other_gcc_version_*`, `newer_binutils_archive_*`, `changed_gcc_archive_*`, `edited_source_*`, `replaced_host_tool_*`, `changed_gcc_source_link_*` (all "refused despite a complete cache"), `changed_configure_options/gcc_languages_are_never_a_silent_hit`, `script_comment_change_never_breaks_the_build` | Changed source/configuration/build logic is never taken for a completed build. |
| Git source | `git_repeat_is_a_hit_and_leaves_sources_alone`, `git_two_unchanged_repeats_are_hits`, `git_second_target_interruption_resumes_second_only`, `git_changed_checkout_*`, `git_local_source_edit_*`, `git_modified_target_is_recovered_without_fetching` | Compatibility with the existing Git-source behaviour (pinned checkout, no fetch, source timestamps untouched). |
| Preservation | `strict_mv_replay_after_invalidation`, `invalidation_preserves_all_build_artifacts` | The DLL-already-in-bin/ replay still works after invalidation; no artifact or source file is lost. |
| Advisory (`a_cc_*`) | `record_names_target_and_schema`, `record_with_unknown_schema_version_is_rejected`, `changed_runtime_dll_policy_is_not_a_hit`, `changed_packaging_command_is_not_a_hit` | Depend on decisions not in the design (record format, what "build-policy identity" covers). |
| Harness self-checks (`t_000_cc_*`) | `mutations_do_what_they_claim`, `mv_failure_injection_*`, `scan_shims_are_transparent`, `spy_records_files_*` | Hold on any implementation, including the current one. |

### Shell: `test_headers.sh` (real GNU make, fake compilation; 7 `t_hdr_*`, 4 `t_000_header_*`, 1 `d_*`)

Models the MinGW-w64 14.0.0 problem: stage 2 installs placeholder
`pthread_{signal,time,unistd}.h` (84/82/84 bytes) with `install -C`, stage 6
(winpthreads) and stage 9 (native mingw-w64) install the full ones
(1304/4768/5012 bytes) into the same sysroot; objects of the CRT, gcc, winpthreads
and the native components depend on those headers, so `make`'s own dependency
evaluation rebuilds them on every replay.  Needs GNU make (`SKIP` otherwise).

| Test | Purpose |
|---|---|
| `t_000_header_fixture_*` (4) | The fixture itself: completed sysroots hold full headers; `install -C` leaves identical content alone but the placeholder→full round trip gives the full header a new mtime (so content-aware install alone cannot help); flipped headers invalidate dependent objects; compile-failure injection. |
| `d_unchanged_completed_repeat_rewrites_objects` | Demonstration: reports how many objects an unchanged completed repeat rewrites. |
| `t_hdr_unchanged_repeat_rewrites_no_objects`, `t_hdr_two_unchanged_repeats_rewrite_no_objects` | Zero objects compiled, header mtimes unchanged, sentinels intact. |
| `t_hdr_repeat_never_leaves_placeholder_headers` | After any repeat the sysroots hold the full headers (holds today and must keep holding). |
| `t_hdr_second_target_interruption_keeps_first_target_objects` | Retry after an interrupted second target rewrites none of the finished first target's objects. |
| `t_hdr_interrupted_compilation_is_not_recorded_as_complete` | Compile failure; the retry completes; only then a hit. |
| `t_hdr_modified_target_recovers_and_other_target_untouched` | A changed target is replayed (headers end full), the other target compiles nothing; recorded again afterwards. |
| `t_hdr_missing_record_replays_even_though_artifacts_are_complete` | Complete artifacts without a record are not trusted. |

### Python: `tests/test_cross_completion.py` (reuses `test_cross_recovery.Recovery` fixtures; 29 tests)

Nanosecond precision cases via `os.utime(ns=…)`, `os.link`, `os.chown` (root only,
else skipped): same-size edit of a build file and of the ZIP with restored mtime,
inode swap with preserved mtime, ctime-only change through an out-of-tree hard
link, permission flip-and-restore, directory permissions, added file/empty
directory, retargeted symlink with restored link times, missing install root,
record damage (missing, empty, malformed, truncated, appended, symlinked,
swapped between targets), first-target-complete/second-interrupted, interrupted
compilation/installation/packaging/DLL relocation/ZIP publication, failing
`find`, changed inputs and changed build logic, Git source.

## Existing assertions that need deliberate modification

Established by running the **unmodified** existing suites against a throw-away
prototype of the design (not committed; see "How the tests were validated").
Nothing existing was weakened; the following are listed for the reviewer.

### Assume a successful repeat re-runs make and packaging (fail with a cache)

| Test | Assumption | Suggested change |
|---|---|---|
| `test_cross_recovery.py::test_interrupted_packaging_does_not_publish_partial_archive` | the third run (`FAIL_ZIP=yes`, `ok=False`) re-packages a completed build | change the install tree (e.g. add a file) before the failing run, so the target is invalid and packaging is attempted |
| `test_cross_recovery.py::test_packaging_term_preserves_archive_and_cleans_staging` | the repeat after `build()` runs `zip` | same |
| `test_cross_recovery.py::test_compilation_installation_and_second_target_recovery` | the second loop iteration injects a `make` failure into a completed target and expects it to be hit | invalidate the target before each iteration (or build into a fresh tree) |
| `test_cross_recovery.py::test_repeat_completion_jobs_and_packaging` | `assertGreaterEqual(events.count("zip "), 5)` — **passes only by accident**: `"zip "` occurs twice in every simulated `zip` log line, so 3 `zip` runs count as 6 | replace by the real intent: after a completed build, a repeat with another `NCRS` runs no `zip` and no `configure` (cache hit) |

### Pass, but silently stop exercising what they were written for (by inspection)

`t_r6_repeated_invocation_after_complete_build_succeeds`,
`t_r6_retry_after_second_target_failure_revisits_first_target`,
`t_r4_third_invocation_still_succeeds`, `t_r6_repeated_packaging_is_stable`: the
repeat becomes a cache hit, so the replay path (strict `mv` with the DLL already
in `bin/`, revisiting a finished target, repeated packaging) is no longer
reached.  To keep their guarantees, invalidate the target between the runs (add a
file to its install tree).  `t_cc_strict_mv_replay_after_invalidation` covers the
strict-mv case in the new suite.

### Snapshot `build/` around a run that now legitimately changes records

`t_r4_rerun_after_success_preserves_everything`,
`t_r5_changing_only_job_count_keeps_build`,
`t_git_continuation_after_success_does_not_fetch_or_touch`: they call
`plant_sentinels` after the build (which changes the tree, so the cache is invalid
and the repeat republishes the record) and then require `snapshot_dir build/` to be
identical.  Suggested: run `build_ok` once more after `plant_sentinels` (re-record)
before taking the "before" snapshot.

`t_r5_changed_binutils_options_not_silently_reused`,
`t_r5_changed_gcc_languages_not_silently_reused`
(`assert_safe_input_change`): a rejected run must leave `build/` untouched, but
"invalidate before modifying" removes the record.  This only matters **if the
record lives under `build/`** (it did in the prototype).  Decide: keep records
outside `build/` (no test change), or make the snapshot ignore records.

## Results (this machine, Linux, GNU make 4.4.1, non-root)

| Run | Shell suite | Python suite |
|---|---|---|
| master `86d55ac` | existing 148 pass, 0 fail; new: 7 `t_hdr` + ~187 `t_cc` fail (feature missing), 4 advisory fail, 1 demo reproduced (36 of 46 objects rewritten by an unchanged repeat) | existing 45 pass; new 28 fail, 1 skipped (root-only) |
| throw-away prototype | new tests all pass, 12 SKIP (scan tools the prototype does not use); the only failures are the 5 existing tests listed above | new 28 pass, 1 skipped; existing: the 3 listed above fail |

## How the tests were validated

* Against `86d55ac`: every new feature test fails, for the intended reason (no
  record exists / the finished target was re-run).  Existing tests still pass
  unmodified.
* Against a throw-away prototype of the design (a copy of `86d55ac` plus ~40 lines;
  find/sha256 snapshot with `-printf`, record at `build/.cross-complete-<target>`;
  kept outside the repository): the new tests pass, with the SKIPs listed below.
* Against deliberately broken variants of that prototype, each of these was caught:
  ctime not in the snapshot (the 9 ctime-only mutations), ZIP not in the snapshot
  (7 tests), record not invalidated before modification (23 tests), symlinked
  record accepted, scan failure ignored (also when the tool fails *after*
  writing all output), `NCRS` part of the policy, one-second timestamps.

## Not covered / limitations

* **Individual snapshot fields** (mtime, inode, size, mode, symlink target)
  cannot be distinguished black-box: every possible mutation also changes ctime,
  so variants that drop any one of them (but keep ctime) pass.  Only ctime,
  the ZIP, the roots, and "something is compared at full resolution" are
  pinned.  A unit-level test of the snapshot function would be needed.
* **Numeric ownership** can only be tested as root (`test_numeric_ownership_change_invalidates`,
  skipped otherwise) and **device numbers** not at all (single filesystem).
* **Failed scan while creating the record** (rather than validating it) is only
  covered by the unreadable-directory test; the tool-failure shims fire only in the
  window between the start of a run and the first modifying tool.
* The scan-failure tests need to know which external tools the scan uses; the shim
  list is `find stat sort xargs awk perl python3 sha256sum shasum sha512sum openssl ls readlink od uniq`
  (`cksum` is excluded because the original script uses it while configuring).
  Tools not in the list, or a scan written in pure bash, are not injected;
  `metadata_scan_uses_an_external_tool_that_can_fail` fails if none of them takes part.
* Unsupported **schema version** and **target identity** inside an otherwise valid
  record cannot be forged without knowing the record format (advisory tests
  `a_cc_record_*` check for a recognisable schema/version/target marker).
* No test asserts the *message* printed on a hit, the record file name, or
  atomicity beyond "published by `mv`".
* No test of crash-safety against `SIGKILL` between publishing the ZIP and the
  record (only failures of `mv`, `zip` and `make` are injectable).
* Timestamp tests assume nanosecond mtime/ctime (Linux, APFS); they still pass on
  coarser file systems but then detect less.  `find -newer/-cnewer`, `touch -h -r`,
  `install -C` and a GNU-compatible `make` are used (all available on macOS with
  the Homebrew tools the project already requires); not run on macOS here.
* Resuming an *interrupted* target still replays stages 2→6 and so rewrites
  header-dependent objects built before the interruption; the design only
  addresses completed targets.  `t_hdr_*` deliberately do not require otherwise.

## Decisions needed

1. **Record location and name.**  Tests require the path to name the target and
   not to be a symlink.  Under `build/` it disturbs existing `build/` snapshots
   (above); under `install/` it would sit next to the ZIPs (and inside
   `install/{cross,native}/<target>` it would be part of the tree it describes).
2. **Is the record part of "the artifacts" a hit must not touch?**  The tests allow
   the record files (and their directories) to change on a hit, and nothing else.
3. **What a "build-policy identity" covers.**  Configure options (hard test);
   DLL names and packaging flags (advisory); a comment-only edit of the script is
   *not* required to be a hit nor a miss.
4. **Run outcome when the post-build scan fails** (record cannot be written):
   fail the build, or warn and continue without a record?  The tests accept both.
5. **Unreadable directories** inside a tree: tests require only "never a hit".
6. **Whether a hit prints something** (nothing is asserted).
7. **Per-target `PREF`-relative vs absolute paths** in the snapshot: a moved
   `PREF` is refused by the existing input record already; no cache-specific test.
