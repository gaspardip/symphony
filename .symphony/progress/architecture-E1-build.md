# E1-build: explicit build provenance and startup diagnosis

## Goal

Identify the source build and loaded code without turning a startup diagnostic into
dispatch authorization or E1 task acceptance. Initial base 09e6c8a, composed on
3e82c2a with metadata and P3b.2 before validation; approved design
E1-build-design-20260925-02.

## Acceptance

Source-built manifest and receipt bind stable readable inputs, actual Mix-packed
module code MD5 and archive SHA-256 separately. Startup is immutable; controls use a
small summary without new IO or scans. Explicit fresh inspections expose uncertain,
missing, changed and old code. Promotion checks the clean receipt before/after copy.
E1-B01..B15 are this unit; B16 belongs to the later acceptance consumer.

## Plan

Implement the approved seventeen files, obtain independent static review, then run
format, focused tests and complete gates under an exclusive VM slot. Keep loaded
provenance separate from checker authority, local result receipts and publication.

## Work Log

The source driver uses pinned Elixir/Mix/OTP helpers only, forces compile once, and
compares source/compiled inputs with real Mix probe/final archives. Runtime publishes
capture and precomputed summary atomically before children. No Symphony compiled
helper is invoked by the builder. No commit, live promotion, service or task acceptance.

Static candidate 01 preserved. Root review found R1/R2 implemented and requested R3:
source exclusions now derive from the evaluated Mix project and declare exact paths.
Outputs outside bounded project directories and output ancestor symlinks are rejected.
Foreign `_build`, deps, bin and manifest-like files remain inputs. The existing A/B
builds carry foreign `elixir/` sentinels; the existing dirty build now uses a nested
Mix project and carries Git-root sentinels. No added build/process budget. Missing
files still listed by Git are explicitly source_unavailable; no missing-file tombstones
are synthesized.

After composition on 3e82c2a, formatting and the first lint identified two empty-list
checks; both now use an empty-list comparison while preserving upper limits. The
first real-build focus exposed order-sensitive configuration hashing: Mix moves the
escript keyword to the end when setting temporary paths. The driver now stably sorts
only external keys after excluding that path; nested values and final comparison stay
intact. The next focus exposed loss of the absolute root in Path.join("", "/"). The
resolver now preserves the first component and still checks every segment, symlink
and depth limit. These were product fixes; the five test suites were unchanged.

The final repository build then exposed a separate source/decode limit conflation:
the tracked demo video is 30,446,771 bytes, larger than the 16 MiB archive entry cap.
Source hashing now streams 64 KiB chunks under a 64 MiB aggregate capture budget;
path/open-handle metadata and actual byte counts are checked. Runtime source schema
validation uses that same aggregate budget. ZIP/BEAM limits and source exclusions
stay unchanged. Existing real builds gain a 16 MiB+1 source input and an empty input;
negative manifest cases cover individual/aggregate size, and one new rejected builder
checks aggregate overflow before compile while preserving the published pair.

Streaming then passed format/lint and focused 59/0 on manifest 17e8205e, but the real
build rejected StaticAssets' dependency JavaScript outside the Git inventory. The
new correction declares those three inputs in Mix configuration, validates their
materialized dependency paths and exact priv symlinks before compilation, and
compares their shared-budget hashes after compile and final packaging. Git entries
and external resources remain distinct under one fingerprint/build_id. Unknown
external_resource attributes still block. Preparation of dependencies is explicit;
copied priv trees and arbitrary aliases are not supported in this initial layout.

The local integration fixture now builds a real path dependency inside each existing
builder VM before loading the driver, without loading Symphony or fabricating aliases.
Two additional rejected builds separately mutate only a declared resource and retarget
its alias to a different file with identical bytes. Both preserve archive and receipt;
the historical note.txt mutation stays intact. Runtime schema negatives recompute
fingerprint and build_id so size/path rejection cannot pass on an unrelated digest
mismatch. The promotion validator and its explicitly synthetic fixture adopt the same
fingerprint; this necessary delta expanded the approved correction from seven to nine
files, still inside the original seventeen.

## Evidence

Prepared regressions cover real A/B builds, dirty/missing source, preloaded helpers,
mutation during compile, consolidated/package inventories, malformed manifests,
missing/duplicate/corrupt receipts and archives, A in memory/B on disk, changed links,
misleading filenames, old code, delayed loading, getter purity, runtime-owned dispatch
metadata and damaged release copies. Synthetic promotion ZIPs prove shell ordering
and binding only; they are never counted as build or loaded-code identity proof.

Budget approved by root after R3 closure for each authorized focus: one child
VM at a time; three complete builds (A, B, nested dirty), six rejected builder
invocations (preloaded runtime, no Git, compile-time source mutation, aggregate source
budget, compile-time external resource mutation, same-byte alias retarget), each with a
120-second process-group watchdog. At most sixteen runtime escripts, 30 seconds each.
The promotion suite's three promotions can launch six short version-probe VMs; each
shell action and descendants have a 45-second watchdog. Maximum 31 child VM launches,
serial in addition to the ExUnit parent. Identity cases allow 300 seconds to outlast
child cleanup. No network/downloaded dependencies/services; the fixture has one local Mix dependency, compiled within the existing child. Child VMs are not cover-instrumented.

Format04 and lint04 passed. Focal03 forced compilation of 111 files, then passed all
five changed suites: 58 tests, zero failures or invalid cases. This includes the real
build/runtime identity scenarios and the explicitly limited synthetic promotion tests.
The three checks used identical manifest f8af44bac3957dbf9e82013831229b6de38f10fc40c90bb9019e1e05cef601cc
and left source unchanged. All five test files match the first focus byte for byte.

Preserved failures: lint01 exited 16 with two ListLength warnings; focal01 exited 2
with one setup failure and 12 invalid cases (configuration order); focal02 exited 2
with 10 failures sharing the root-resolution error. Diagnoses and before/after hashes
remain under external validation/e1build. No assertion was weakened. Focal03 ended
with no BEAM/runner/fixture processes remaining, and its exclusive VM slot was released.

The early harness check passed before the two product corrections. Root then selected
E1-first integration order. On the frozen e08e3df2 candidate, independent validation
passed full 1597/0, coverage and Dialyzer; final-build01 failed on the tracked video.
That failure is preserved. The streaming correction then passed format/lint and focused
59/0, with the subsequent external-resource build failure preserved separately. Those
gates do not apply to this resource correction, which has not run yet. No callable
LSP exists. No integration, release deployment, E1-B16 acceptance or thesis acceptance
is claimed. Historical assertions remain; new schema negatives and two independent
real compile-time resource failures still need execution.

## Next Step

Freeze the resource correction for static review, then use a newly assigned exclusive
VM slot for format/lint, focus, real build and required final gates. Preserve failures
and stop for diagnosis before repeating checks. E1-acceptance authority/receipts remain
separate; do not claim full coverage of this updated tree from earlier results.

Review correction on 2026-09-29: the previous real-project build used already compiled
dependencies, while the minimal fixture had a special preparation alias. The production
build alias now explicitly compiles dependencies before loading the unchanged driver;
setup remains responsible for fetching them. The fixture reads that production alias
and starts without its own _build, so it exercises the same preparation. The duplicate
module negative recomputes build_id to isolate schema uniqueness. Existing assertions,
watchdogs and the child-VM budget are preserved. Format/lint/focus/build 61/0 on resource
manifest 0d9bc011 remain historical; validation of this correction is pending.
