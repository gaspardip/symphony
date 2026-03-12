# Testing And Ops

Primary repo validation:
- `scripts/symphony-preflight.sh`
- `scripts/symphony-validate.sh`
- `scripts/symphony-smoke.sh`
- `scripts/symphony-post-merge.sh`
- `scripts/symphony-artifacts.sh`
- `mix harness.check`

Symphony should prefer deterministic repo-owned checks, strong issue-level observability, and explicit stop reasons over silent retries or guesswork.

