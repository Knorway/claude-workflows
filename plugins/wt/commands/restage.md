---
description: Rebuild the staging branch as the composite of every open PR, or merge the PRs it is made of
argument-hint: "[--merge]"
---

Rebuild the staging branch from scratch — the base branch plus **every currently
open pull request** — so one URL shows what all the in-flight work looks like
together.

`wt-restage` does the work. This command exists for the one thing a script must
not decide on its own: whether to merge.

**Nothing is ever merged back out of staging.** Pull requests still target the
base branch and get merged one at a time. A rebuild writes exactly one ref, so it
cannot touch a pull request, a branch, or the user's checkout — it is safe to run
at any time, and re-running it is how a stale staging gets fixed.

Read `$ARGUMENTS` for **`--merge`**. Nothing else is a flag; anything else is
noise and can be ignored.

## Without `--merge` — rebuild

```bash
wt-restage
```

Report its output as-is. It prints the composite, the staging URLs if the repo
configured any, and — on stderr — any pull request that **dropped out on a
conflict**.

**Repeat the conflicted list as the last line of your report.** Those pull
requests are not on staging, so nobody is QA-ing them, and the output scrolls.
Each one comes with the merge that would let it back in — carry that through
verbatim rather than restating it.

**Do not assume the base branch is what a casualty hit.** Folds go in ascending
pull request number, so a branch that merges the base perfectly cleanly still
drops out when it disagrees with a pull request folded ahead of it — and the
script says which one. Telling somebody to merge the base in that case sends
them into a loop: the merge succeeds, nothing is fixed, and the next rebuild
fails on the same files.

If the script stops on missing config or a `gh` login, relay the message. `gh
auth login` is interactive, so you cannot run it — tell the user to type
`! gh auth login` in the prompt.

## With `--merge` — ship what staging proved

`--merge` acts on the composite **that already exists**, not on a fresh one. Do
not rebuild first: rebuilding would fold in pull requests opened since the last
QA and then merge them as though they had been tested.

**Step 1 — show the manifest. Do not merge in this turn.**

```bash
wt-restage manifest
```

Every fold is listed with a status. Only `ok` gets merged; `stale`, `draft` and
`gone` are skipped by the script itself. `stale` is the one worth reading out
loud — it means that branch was **pushed to after the composite was built**, so
what is on staging is not what would be merged.

**Step 2 — ask, then merge.** Put three things in the question:

- how many pull requests will be merged, and that **each merge is its own deploy**
  — `--merge` on four pull requests is four production deploys, not one;
- the `stale`/`draft`/`gone` rows, so their exclusion is a decision rather than a
  surprise;
- whether anything that has to happen **before** a merge has happened. The plugin
  cannot know what that is — a database migration against production, a secret,
  a bucket — but the repo's own `CLAUDE.md` usually does. Read it if there is
  one, and name what it says.

Only after the user answers:

```bash
wt-restage merge
```

It re-derives the manifest itself — your confirmation is not what makes it safe —
merges the `ok` ones in ascending order, **stops at the first failure**, and then
rebuilds staging so the composite reflects the new base branch.

If it stopped partway, report exactly which pull requests went in and which are
still open. Nothing needs undoing: the ones that merged were each their own
change.
