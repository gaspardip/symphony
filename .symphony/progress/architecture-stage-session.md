# Delivery stage session ownership

## Goal

Own the current main transport across delivery stages while retaining execution
authority, accumulated usage and the existing 26-case video reference.

## Acceptance

- Same-provider stages retain exact session and binding.
- Replacement closes and retires the old resource before opening the successor.
- Failed close retains its original outcome and is attempted once.
- Actual turn provider, accounting ordinal and retired usage remain correlated.
- Passive stages and verifier ownership retain their existing contracts.
- Compiler, format, harness, lint, Dialyzer and native tests must pass on final source.

## Plan

Apply the reviewed scope and Engine composition in the isolated candidate. Verify
new contracts and actual admitted execution, then selected owned close failures.
Integrate only a clean validated commit and build; revalidate all 26 final cases.

## Work Log

The original engine retained its initial transport in both public CLI directions
despite correctly resolved stage mapping. The scope and owner patch address that
resource lifetime. Existing tests and production authority owners are unchanged.

## Evidence

External static reviews found no concrete functional defect. Configuration was
separately integrated with 2798 native tests passing. At application, native verification of this session source, its clean build
and final-source case acceptance were still pending. Subsequent validation
results are recorded against each exact composed source in external receipts.

## Next Step

Run targeted lifecycle and admitted accounting tests. Complete real owned close
failure and primary/cleanup composition evidence before full validation and Main.
