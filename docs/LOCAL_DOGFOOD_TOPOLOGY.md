# Symphony Local Dogfood Topology

## Goal
Run Symphony locally with:

- the self-hosted observability stack
- a `stable` local runner
- a `canary` local runner
- enough wiring to test GitHub review-follow-up behavior on real PRs

## Current Limitation
This branch now supports stable-ingress relay for GitHub review webhooks: stable can accept the verified webhook and relay it to the canary runner internally.

What is still missing is the fuller scheduler/control-plane split:

- stable ingress still relays review webhooks directly to configured sibling instances instead of assigning durable work items through a dedicated scheduler
- tracker event routing and issue dispatch are still per-process
- the eventual target remains a stable ingress that persists and assigns cross-runner work instead of relaying it opportunistically

## Bootstrap

Generate local workflow files and runtime paths:

```bash
cd /Users/gaspar/src/symphony-clz-22
ops/local-topology.sh prepare
```

The script writes stable and canary workflow files under your local state directory and prints the active paths and ports.
It also seeds each local runner install root with a valid `metadata.json`, `history.jsonl`, `current` symlink, and release manifest so the runner-health gate starts in a healthy state instead of `runner.metadata_invalid`.

### Tracker mode
The script chooses tracker mode automatically:

- `linear` if `LINEAR_API_KEY` and `LINEAR_PROJECT_SLUG` are set
- `memory` otherwise

You can override this with:

```bash
export SYMPHONY_LOCAL_TRACKER_KIND=memory
```

or:

```bash
export SYMPHONY_LOCAL_TRACKER_KIND=linear
```

## Start The Observability Stack

```bash
cd /Users/gaspar/src/symphony-clz-22
ops/local-topology.sh start-observability
```

Services:

- Grafana: [http://127.0.0.1:3000](http://127.0.0.1:3000)
- Prometheus: [http://127.0.0.1:9090](http://127.0.0.1:9090)
- Loki: [http://127.0.0.1:3100](http://127.0.0.1:3100)
- Tempo: [http://127.0.0.1:3200](http://127.0.0.1:3200)

Prometheus scrapes both local runner ports:

- `127.0.0.1:4040`
- `127.0.0.1:4041`

Promtail tails local runner logs under [log/local-topology](/Users/gaspar/src/symphony-clz-22/log/local-topology).

## Start Both Runners

Run these in separate terminals.

Stable:

```bash
cd /Users/gaspar/src/symphony-clz-22
ops/local-topology.sh start-stable
```

Canary:

```bash
cd /Users/gaspar/src/symphony-clz-22
ops/local-topology.sh start-canary
```

Endpoints:

- stable dashboard/API: [http://127.0.0.1:4040](http://127.0.0.1:4040)
- canary dashboard/API: [http://127.0.0.1:4041](http://127.0.0.1:4041)

Useful API checks:

```bash
curl http://127.0.0.1:4040/api/v1/state
curl http://127.0.0.1:4041/api/v1/state
curl http://127.0.0.1:4040/metrics
curl http://127.0.0.1:4041/metrics
```

## Live GitHub PR Review Dogfooding

For local review dogfooding, use the stable instance as the GitHub webhook target.

1. Expose the stable runner publicly with a tunnel.
2. Set `GITHUB_WEBHOOK_SECRET` in both stable and canary runner environments before starting them.
3. In GitHub, configure the webhook payload URL as:

```text
https://<your-stable-tunnel-host>/api/webhooks/github
```

4. Enable:
   - `Pull request reviews`
   - `Pull request review comments`
5. Label the Symphony self-work issue or PR so it is clearly canary-targeted.
   Use `canary:symphony` on the issue or PR that should route to canary behavior.
6. Redeliver the existing PR review event from GitHub or add a fresh review comment.

Stable will verify the webhook, enqueue it locally for observability, and relay the same signed request to configured sibling instances from `portfolio.instances`. The canary instance will then process the review follow-up normally.

## Observing The Run

Watch:

- `GET /api/v1/state` on stable and canary
- `GET /api/v1/<ISSUE>/details` for routing, lease, and review state
- Grafana dashboards and Loki logs
- the runner control API:

```bash
curl -X POST http://127.0.0.1:4041/api/v1/runner/actions/inspect
```

## Runner Control Actions

The canary or stable instance can execute:

- `inspect`
- `promote`
- `record_canary`
- `rollback`

Example:

```bash
curl -X POST http://127.0.0.1:4041/api/v1/runner/actions/inspect
```

## Next Architecture Step

After local dogfooding works, the next structural step is the missing seam:

- stable ingress persists and assigns cross-runner work instead of relaying it directly
- canary runner receives explicit assigned work items rather than a forwarded webhook request
- tracker ingress and review ingress converge on the same scheduler path

That is the point where the local topology becomes the full target architecture instead of a stable-ingress relay bridge.
