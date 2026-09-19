# Vendor the task repo here

This folder holds the task's source tree (`environment/repo/`). Replace this
placeholder with the actual repo — from the task root:

```sh
rm environment/repo/placeholder.md
git clone <git url> environment/repo
```

Keep the cloned `.git` history: the substance gates
(`cyberswe/repo-has-enough-files`, `cyberswe/repo-has-enough-commits`) read
it, and it ships with the submission. The Dockerfile copies `repo/` into the
image and flattens history at build time, so the agent never sees it.
