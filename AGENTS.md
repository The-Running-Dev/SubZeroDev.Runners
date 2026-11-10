# Agent contract

## Shared contract

**Read `AGENTS.shared.md` completely before this file.** It holds the rules every repository using the kit shares, resolved from the `AGENTKIT_HOME` environment variable if set, else `.agent-kit` in the home directory.

**Plan execution.** When the user assigns completion or resumption of an agreed plan, read AGENTS.shared.md and follow the kit's skills/next/SKILL.md. That assignment includes adopting an existing repository, checks, commits, pushes, non-draft pull requests, review fixes, merging only through tools/merge-pull-request.ts, cleanup and the next eligible slice, without routine permission or continuation questions. Never commit on the default branch. Keep going within the agreed scope; a merged slice is progress, not the end of the assignment. Interpret "next", "continue" and "resume" in the active assignment, not as unconditional triggers. A request to continue an explanation or review grants no delivery authority. Honor explicit slice limits, pauses and later restrictions; a plan file or saved checkpoint never overrides them. Stop for completion or an evidenced genuine blocker after authorized recovery. Missing project files are preparation work, not a handoff to the user. Restore the assignment and existing branch/PR after compaction; do not claim a terminated host will restart itself.
