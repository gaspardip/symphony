# Publication preflight (PB13)

The delivery engine validates the publication policy, GitHub `pr_write` scope
and detected PR body contract before staging files, creating a commit or
pushing a branch. A failed preflight stops the run with `publish_failed` and
the original policy, credential or contract error in its persisted reason.

`PullRequestManager.validate_publication/4` exposes the same checks used by
`ensure_pull_request/4`. The latter repeats them at the PR operation boundary;
standalone PR callers continue to receive the existing checks. Repositories
without a detected PR-body contract retain the explicit `skipped` result.

`publish_preflight_test.exs` exercises the real delivery engine with a memory
tracker, local fixture and command recorder. Forbidden policy, missing
credential scope and failing PR-body contract must all leave the Git mutation
counter at zero. This is local E2 evidence; it does not publish a remote PR.
