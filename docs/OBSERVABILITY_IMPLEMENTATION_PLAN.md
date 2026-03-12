# Symphony Observability Implementation Plan

## Summary
Symphony should use a self-hosted or local-first observability stack for core runtime behavior:

- `:telemetry` as the internal event contract
- OpenTelemetry for traces
- Prometheus-compatible metrics
- structured JSON logs
- Grafana dashboards for operators
- bounded local replay artifacts for failure forensics

Linear remains the primary tracker for Symphony self-work. Manual intake stays available, but it is not the main observability path.

## Default Architecture

### Runtime instrumentation
- emit `:telemetry` events from intake, orchestration, stage execution, proof, PR/review flow, deploy flow, and operator actions
- wrap stage execution and provider-facing actions in OpenTelemetry spans
- attach stable issue, stage, policy, and rule metadata to every signal

### Storage model
- metrics: Prometheus scrape endpoint exposed by Symphony at `/metrics`
- traces: OTLP export to Tempo or another OTLP-compatible backend
- logs: structured JSON logs written locally and optionally scraped into Loki
- replay artifacts: bounded local files stored outside the normal metric/log stream and referenced by artifact ID

### Privacy defaults
- normal telemetry does not include raw prompt bodies, full shell output, or file contents
- failures and explicit debug mode may store bounded local raw artifacts
- replay storage is local-first, compressed, size-capped, and referenced by hash and artifact ID

## Event Areas

### Intake and routing
- tracker webhook accepted, ignored, rejected
- tracker backoff entered and cleared
- issue-source reads and mutations

### Stage lifecycle
- stage start, stop, duration, and outcome
- transition metadata from persisted run state

### Tokens and budget pressure
- per-turn input, output, and total token deltas
- soft token pressure and hard stop events

### Proof and verification
- behavioral proof evaluated
- UI proof evaluated
- verifier completed with verdict and smoke status

### Git and PR lifecycle
- git command start and stop
- PR publish start, stop, and published
- merge attempted and completed
- review feedback detected

### Runtime and operator actions
- runtime stop events
- runtime repair events
- operator action events

## Replay and Time-Travel

Symphony should not assume deterministic replay from telemetry alone. Provider behavior, external APIs, git state, and shell state make that unrealistic.

The useful model is forensic replay:

- store prompt envelopes, tool calls, state transitions, token usage, and summaries in normal telemetry
- store bounded raw artifacts only for failures or explicit debug mode
- let operators move from a trace or log entry to a local artifact reference when normal telemetry is insufficient

That gives Symphony a practical time machine for “why did it behave this way?” without turning the main observability backend into an unbounded private-data archive.

## Local Self-Hosted Stack

Repo-owned assets live under [ops/observability](/Users/gaspar/src/symphony-clz-22/ops/observability):

- Docker Compose
- Prometheus config
- Loki config
- Promtail config
- Tempo config
- Grafana datasources
- starter Grafana dashboard

Bring the stack up with:

```bash
cd /Users/gaspar/src/symphony-clz-22
docker compose -f ops/observability/docker-compose.yml up -d
```

Run Symphony against it with:

```bash
cd /Users/gaspar/src/symphony-clz-22/elixir
OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318 mise exec -- mix phx.server
```

Prometheus scrapes the host Symphony process at `http://host.docker.internal:4040/metrics`. If Symphony runs on a different port, update [ops/observability/prometheus/prometheus.yml](/Users/gaspar/src/symphony-clz-22/ops/observability/prometheus/prometheus.yml) before starting the stack.

## Rollout Order

1. Runtime telemetry, traces, logs, and bounded artifact plumbing
2. Local self-hosted stack with Docker Compose
3. Dashboard refinement and historical delivery views
4. Optional product analytics later, separate from core runtime observability

## Explicit Non-Goals

- Kubernetes in the initial rollout
- third-party SaaS as the primary runtime source of truth
- raw prompt and shell output in normal telemetry streams by default
