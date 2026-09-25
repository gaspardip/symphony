# Architecture P3b.2: strict local turn errors

## Goal

Stop local CLI delivery on command or executor failure and return the exact cause
before plan or implement can advance. Initial base 6381def with B1; validation
composition c4799f2 includes C4a and lazy snapshot metadata.

## Acceptance

Every failed preparation step omits subsequent effects and normal final delivery.
Plan and implement propagate turn_effect_failed without internal retry or stage
advance. Partial provider, formatter, index, hook and executor effects remain.
Verifier and other provider contracts stay unchanged. No I2 claim is made.

## Plan

Apply checked returns to TurnEffects and the existing Claude wrappers, guard the
two engine consumers, migrate deliberate error contracts and add real temporary
Git/CLI engine regressions. Freeze for independent static review before VM gates.

## Work Log

- Added narrow command and executor invocation boundaries preserving step, status,
  observed output or exception kind/reason. No environment/transport options are
  captured and no recovery commands are added.
- Required a report consumer before Git and string-keyed boolean success after
  one synchronous invocation. Error notification stays outside classification.
- Plan stops before old-report fetch/implement transition; implement returns the
  tag before after_snapshot/replies/transition or its existing retry classifier.
- Migrated only wrappers and tests whose checked return/error contract changes;
  kept profile parsing, defaults, callbacks, direct transport and verifier policy.
- Added regressions for partial writes, missing refs, executor response forms,
  command/executor exceptions and public plan/implement command/rejection paths.

## Evidence

The initial candidate was inspected without a callable LSP or VM. After C4a
composition, explicit formatting, format check, lint and the early harness passed.
The first effects focus ran 108 tests with one failure: its new fixture assumed
Git exit 128 both for missing HEAD and a non-repository. Direct local Git confirmed
128 and 129 respectively. The authorized fixture correction preserves exact codes
and strengthens output, executable, argv and cwd checks; product code is unchanged.
The corrected effects focus passed 108/0 and delivery compatibility passed 95/0.
Constant-comparison warnings in the parameterized fixture remain recorded.
The first frozen full ran 1,568 cases with two timeouts: the concurrent budget
stream and a snapshot during a held retry lookup. Gates stopped and both original
tests retained their assertions and deadlines. A covered diagnostic focus passed
43 cases but exposed repeated discarded Git lookups inside snapshot operations.
The independent metadata unit was reviewed and integrated as c4799f2 after its
own full 1,556/0 and configured gates. B2 is now composed on that commit, with its
product and test bytes unchanged. This does not retrospectively establish the
cause of the earlier failures. The composed full and remaining gates are pending;
all attempts remain externally under validation/p3b2.

Public engine tests use actual local CLI
scripts and the standard report interceptor. Executor throw/raise is tested at
TurnEffects, while public plan tests cover command failure and actual report
rejection. The engine's public bootstrap cannot inject a custom provider, so these
tests do not claim that its internal standard executor throws through public plan.
Root approved this explicit limit without adding a production test hook.

## Next Step

Independent review, composition and focused checks are complete. Freeze this
source, execute full and the remaining gates, and preserve the initial failure
and final manifests externally.
