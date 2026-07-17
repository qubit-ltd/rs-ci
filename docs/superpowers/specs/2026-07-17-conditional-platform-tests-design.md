# Conditional Platform Tests Design

## Goal

Make both Windows and macOS tests opt-in in the reusable `rs-ci` workflow,
then enable both platform jobs for `rs-command` and `rs-local-files`.

## Reusable workflow

Add a boolean `run_windows_tests` workflow-call input next to the existing
`run_macos_tests` input. It defaults to `false`, matching the opt-in macOS
behavior. The Windows job runs only when `run_windows_tests` is true and the
event is not a scheduled run. The existing macOS condition remains unchanged.

Document both inputs together in the English and Chinese READMEs. The example
shows consumers enabling only the platform jobs that exercise platform-specific
code.

## Consumer workflows

Set both `run_windows_tests: true` and `run_macos_tests: true` in the reusable
workflow call in `rs-command` and `rs-local-files`. No other workflow behavior
changes.

After publishing `rs-ci`, run each consumer repository's existing
`update-submodule.sh` script so its `.rs-ci` gitlink advances to the published
`rs-ci/main` revision.

## Git delivery

Use English Angular-style commit messages in all three repositories. Publish
the `rs-ci` change by merging it through `dev-starfish`, `dev`, and `main`, then
push those three branches. Commit the consumer workflow and submodule updates
separately in `rs-command` and `rs-local-files`; do not push those repositories.

## Verification

Add or update workflow structure tests in `rs-ci` to verify the new input,
default, and Windows job condition while retaining the macOS checks. Run the
relevant `rs-ci` test suite and validate the YAML syntax. In each consumer,
inspect the workflow diff, confirm both inputs are enabled, confirm `.rs-ci`
points at the published `rs-ci/main` commit, and run the repository's applicable
CI checks before committing.
