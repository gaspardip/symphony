# Symphony Local Dogfood Topology

## Goal
Run Symphony locally with:

- the self-hosted observability stack
- a `stable` local runner
- a `canary` local runner
- enough wiring to test GitHub review-follow-up behavior on real PRs

## Current Limitation
This branch does not yet have the full cross-process scheduler that lets a stable ingress process accept a GitHub webhook and forward it to a separate canary runner automatically.

That means:

- the dual-instance topology can run locally today
- metrics, traces, logs, lease state, and runner controls work locally today
- for live GitHub PR review dogfooding, point the webhook at the canary instance for now

Use the stable instance locally as the future ingress target, observability reference, and control-plane comparison. Use the canary instance to actually process Symphony self-work until the scheduler split lands.

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

For now, use the canary instance as the webhook target for live review follow-up.

1. Expose the canary runner publicly with a tunnel.
2. Set `GITHUB_WEBHOOK_SECRET` in the canary runner environment before starting it.
3. In GitHub, configure the webhook payload URL as:

```text
https://<your-tunnel-host>/api/webhooks/github
```

4. Enable:
   - `Pull request reviews`
   - `Pull request review comments`
5. Label the Symphony self-work issue or PR so it is clearly canary-targeted.
   Use `canary:symphony` on the issue or PR that should route to canary behavior.
6. Redeliver the existing PR review event from GitHub or add a fresh review comment.

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

- stable ingress accepts GitHub webhooks
- ingress persists and routes the event
- canary runner receives assigned work without GitHub pointing at it directly

That is the point where the local topology becomes the real target architecture rather than a local bootstrap with one temporary direct-webhook compromise.
