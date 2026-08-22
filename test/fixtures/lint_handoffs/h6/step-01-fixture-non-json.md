# Fixture: non-JSON handoff-shaped file

This is a permanent test fixture for ISS-0262's H6 check
(`lib/mix/tasks/letflow.lint_handoffs.ex`), not a real handoff. It exists solely to
prove that `handoff_files/1` discovers a `step`-prefixed, non-`.json` file under a
fixture root, and that `lint_file/2` classifies it as an un-grandfathered `H6`
violation. Its content is never read by H6 (extension-only classification), so no
particular schema applies here.
