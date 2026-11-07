# CRS_BLD — Development guidance

## Project
CRS_BLD builds MinGW-w64 cross-compilers and supporting
libraries. The project supports Linux and macOS.

The main scripts are:
- `make_cross-compiler.sh`: cross-compiler construction.
- `make_pkgs.sh`: dependency package construction.
- `etc/common.sh`: shared functions.
- `etc/diagnostics.sh`: diagnostics.

## Current requirements
Read `docs/cross-compiler-resume-spec.md` before working
on cross-compiler recovery.

## Development rules
- Preserve existing Linux and macOS behavior.
- Make focused changes; avoid unrelated refactoring.
- Preserve valuable build artifacts when possible.
- Never execute a real compiler build during automated tests.
- Never delete or overwrite existing build trees as part
  of testing.
- Use temporary directories and mocked external commands.
- Write regression tests before fixing confirmed defects.
- Run `bash -n` and relevant tests after changes.
- Review the Git diff before finishing.
- Do not modify `make_pkgs.sh` during this recovery task.
- Do not create Git commits unless explicitly requested.
- Report changes, test results, and remaining limitations.
