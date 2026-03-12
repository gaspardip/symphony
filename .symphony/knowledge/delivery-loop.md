# Delivery Loop

The canonical runtime loop is:
1. checkout
2. initialize_harness
3. implement
4. validate
5. verify
6. publish
7. await_checks
8. merge
9. post_merge
10. done or blocked

Passive late stages should avoid unnecessary model invocations. Publish and merge are always gated by repo-owned proof and policy.

