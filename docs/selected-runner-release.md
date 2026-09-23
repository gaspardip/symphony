# Selected runner release

`RunnerRuntime.selected_release_root/0` returns the expanded target of the runner install's `current` symlink. Relative targets are resolved against the install directory. The same value is exposed as `selected_release_root` in runner information, separately from `current_checkout_root` and the existing version fields.

A missing, unreadable or non-symlink `current` entry yields `nil`, using the existing link reader. There is no fallback to `promoted_release_path` metadata. A dangling symlink still identifies a selected path; it does not establish that the release exists or is healthy. Runner health validation remains separate and unchanged.

The selected path joins the install directory and current checkout in `protected_paths/0`. The existing overlap check therefore rejects pre-run workspaces equal to the selected path, inside it or containing it, including a release selected outside the install directory. This is the existing `RunPolicy.enforce_pre_run/3` boundary. It does not add protection to Workspace create/remove operations or hooks; the current AgentRunner runs workspace creation and before-run hooks before that policy check.

Selection is not execution identity. Changing `current` does not prove that a running BEAM VM loaded another release. This change leaves `runtime_version/0`, `current_version_sha` and their existing checkout/metadata behavior unchanged; those fields do not become independent proof of loaded code. The promotion and local topology scripts retain their existing launch behavior.

The tests cover absolute and relative external targets, overlap rejection through the existing policy, absent/non-symlink/dangling entries, and different local Git fixture revisions while the selected link changes. These local checks do not start another Symphony runtime, promote a release or contact providers.
