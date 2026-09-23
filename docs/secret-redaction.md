# Redaction of secrets in evidence (PB12)

Evidence now passes through `SymphonyElixir.SecretRedactor` before it is
serialized or persisted. The redactor identifies values from sensitive keys
without reading environment variables or credential files, then replaces
occurrences of those values throughout the same evidence envelope.

The covered boundaries are:

- Debug artifacts: payload, metadata and kind are considered together.
  Iodata is joined before inspection. Redaction happens before size limits,
  hashing, gzip compression and manifest creation. The returned SHA-256 and
  manifest describe the bounded, redacted payload bytes actually stored.
- Structured JSON logs: the original and rendered message plus structured
  metadata are considered together before JSON serialization. This preserves
  sensitive-key context and catches raw tokens split across chardata chunks.
- The legacy and typed run ledger: the complete entry is redacted before
  append; typed entries returned to callers are also redacted.
- Observability metadata: redaction precedes normalization and truncation for
  telemetry, span attributes and logger metadata.

Sensitive keys are matched case-insensitively, ignoring spaces, hyphens and
underscores. The list includes API keys/tokens, access/refresh/id tokens,
passwords, client secrets, authorization headers, cookies, private keys and
credentials. Explicit provider prefixes on API keys/tokens, access/refresh
tokens, client secrets, passwords and private keys are recognized by suffix.
The exact key `token` is sensitive; `input_tokens`, `output_tokens`,
`total_tokens`, `token_count` and token-budget fields are not matched.

Maps, lists and ordinary scalar types retain their structure. Sensitive values
are replaced with `[REDACTED]`; issue identifiers, event IDs, rule IDs and trace
correlation remain intact unless they contain an identified secret value.

For raw text, identification is deliberately bounded: Bearer/Basic token
syntax and sensitive `key=value` or `key: value` assignments with a single
unquoted token or a simple quoted value. Identified values are also removed
from other fields in the same envelope. This is not a parser for all shell
quoting, escaped JSON, URLs, encodings, multiline credentials or log formats.

No arbitrary unlabeled secret detection is promised. A value supplied only as
unmarked prose, a transformed/encoded copy, a partial secret, or a secret in a
separate envelope may remain unidentified. Callers should provide structured
sensitive fields together with message/payload metadata. Short values can also
match unrelated text; redaction favors removing the identified value.

This change does not rewrite historical artifacts or cover every possible
output channel, run-state snapshot, provider-owned log, permission boundary or
external exporter. Existing filesystem permissions and ledger write-error
semantics are unchanged. Secret redaction is separate from enforcing denied
operations.

Regression coverage in `secret_redaction_test.exs` uses only invented
`SYNTHETIC_NOT_A_REAL_SECRET_PB12_...` values, following the local diagnostic
probe. It reads gzip payloads, manifests, JSON logs and both ledger forms from
disk, verifies telemetry/correlation and recalculates SHA-256 from stored bytes.

Run from `elixir/`:

```sh
mise exec -- mix test test/symphony_elixir/secret_redaction_test.exs test/symphony_elixir/observability_test.exs test/symphony_elixir/run_ledger_test.exs
```
