# CRS_BLD — Claude Code

Follow `AGENTS.md` for repository-wide safety, testing and change-management rules.

For any work involving cross-compiler recovery or completion caching, read `docs/cross-compiler-resume-spec.md` before changing code or tests.

Respect the role and boundaries of the current task, including read-only reviews and separate Git worktrees. Do not infer permission to edit, commit, merge, push or run a real compiler build merely because such actions were authorized in an earlier task.

When reviewing work by another agent, distinguish verified findings from assumptions and report reproducible defects, test coverage gaps and remaining risks. Keep detailed implementation requirements in the specification rather than duplicating them here.
