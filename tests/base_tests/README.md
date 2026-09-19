# base_tests -- pristine content of every file the graded suite loads

One file per repo-relative path. `helpers/restore_tests.py` copies each of them
over the repo before the tests run, so whatever the agent did to its own copy is
irrelevant to the score.

The path list is this directory's listing. There is no manifest to keep in sync:
if a graded test's file is here it is protected, and if it is not here it is not.

What goes in:

* every file holding a `pass_to_pass` test -- these are ordinary repo test files
  the agent can see and edit, and they are the ones that used to be exposed;
* every file holding a `fail_to_pass` test, with its FINISHED content (the tests
  as they must run), since these files are not in the image at all.

Nothing else. Do not put source files here -- restoring one would delete the
agent's fix and make the task unsolvable.

Delete this file before submitting. The verifier restores everything under
`base_tests/` over the repository, so leaving it here overwrites the repo's own
`README.md` -- `cyberswe/base-tests-has-no-scaffold-readme` fails the task for it.
