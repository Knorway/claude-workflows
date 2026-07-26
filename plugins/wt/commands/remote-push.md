---
description: Scan for secrets, commit, push, and open a PR with a Korean body
argument-hint: "[base | hint] [--no-review]"
---

Commit everything in the working tree, push it to `origin`, and open a pull
request against the base branch.

`$ARGUMENTS` is a free-form hint. Pull out `--no-review` first if present (it
turns off the gate in step 0) and parse what remains. If that names the base
branch (`main`, `master`, `main으로`, `여기에`), run in **direct mode**: no pull
request, push straight to the remote base branch. Otherwise treat it as a steer
for the message. Empty is the normal case.

Direct mode gets the review gate too — pushing straight to the base branch is the
riskier path, not the safer one.

The base branch is `main` unless the repo says otherwise — check
`.claude/wt.json`'s `baseBranch`, then `git symbolic-ref --short
refs/remotes/origin/HEAD`. Everywhere below, `<base>` means that branch.

## Token budget

This runs often. Keep it cheap:

- Never run a bare `git diff` — always `-U0`, and exclude lockfiles.
- Do not open files to build the message. The staged diff feeds the commit; the
  PR body's `## 플랜` is the plan file **`cat`-piped straight to `gh`** (step 5) so
  its bytes never enter your token stream — never read it into context and retype it.
- Batch the git calls: step 1 is one Bash invocation, step 4 is another.
- If the branch carries earlier commits, skim those with `git log origin/<base>..HEAD
  --format='%s'` and `git diff origin/<base>...HEAD --stat` — never re-read their diffs.

## 0. Review gate — before anything else

Unreviewed work should not become a pull request by accident. If this branch has
not been reviewed yet, run **`/wt:review --quick`** first, then come back here.

```bash
wt-verify checks 2>/dev/null | grep -E '^- review — ok|사람 확인 필요.*· review —' | grep -v 미실행
```

That pattern matches only the two statuses that mean *someone actually looked* —
`review=ok` and `review=human`. It deliberately does **not** match
`- review — 건너뜀`, `- review — **실패**` or `- review — 미실행`: a review that was
skipped for budget, or invalidated by a previous push (step 7), must not satisfy
the gate. Matching the id alone would let `review=skip:토큰부족` wave a PR through.

**The `grep -v 미실행` is not decoration.** A repo is free to declare `review` as a
step in its own ladder — `{ "id": "review", "human": true }` is the natural way to
write it — and an unrecorded human step renders as
`- [ ] **사람 확인 필요** · review — 미실행`, which matches the second alternative on
the strength of the words alone. Without the filter, adding that one line to
`wt.json` disables this gate permanently, in a way nobody would ever notice.

The ledger is per-branch, so this only ever reflects work on *this* branch. Treat
the branch as **reviewed** only if that line is there *or* you can see a
`/wt:review` run for the current state in this conversation. **When in doubt,
review** — a redundant `--quick` costs a few dollars; an unreviewed PR costs more.

Skip the gate entirely when:

- `$ARGUMENTS` contains **`--no-review`** (strip it before parsing the rest), or
- there is nothing to push (step 1 finds no changes and no unpushed commits), or
- the review would have nothing to read (`git diff origin/<base>...HEAD --stat` and
  the working tree are both empty).

After the review returns:

- **0 findings** → say so in one line and continue to step 1.
- **findings** → show the report and **ask whether to push anyway.** Do not push
  in the same turn. `--quick` never edits files, so nothing was fixed for you;
  this is the moment the user decides. If they want the findings fixed, run
  `/wt:review` (no `--quick`) instead of pushing.

The gate is about *having looked*, not about being clean — it never silently
blocks, and `--no-review` is always there for a one-line typo fix.

## 1. Gather and scan — one call

```bash
git remote get-url origin && git branch --show-current && git add -A && git diff --cached --stat
git diff --cached --name-only | git check-ignore --stdin
git diff --cached --name-only | grep -Ei '(^|/)\.env($|\.)|\.(pem|key|p12|pfx|jks|keystore|mobileprovision|tfstate)$|(^|/)id_(rsa|ed25519)|(^|/)\.(npmrc|netrc|pypirc)$|google-services\.json|GoogleService-Info\.plist'
git diff --cached -U0 | grep -E '^\+' | grep -Ein -e '-----BEGIN[A-Z ]*PRIVATE KEY|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{30,}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|sk-[A-Za-z0-9]{20,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.|(secret|passwd|password|api[_-]?key|access[_-]?token|client[_-]?secret|private[_-]?key)["'"'"' ]*[:=]["'"'"' ]*[^"'"'"'[:space:],;)}]{12,}'
git diff --cached -U0 -- ':(exclude)*.env.example' ':(exclude)*.env.sample' | grep -E '^\+(NEXT_PUBLIC|PUBLIC|REACT_APP|VITE|EXPO_PUBLIC|GATSBY|NUXT_PUBLIC)_[A-Z0-9_]+=.+'
gh auth status
```

The four greps are, in order: a force-added ignored file; a filename that should
never be committed; a secret in an added line; a real value for a
build-time-inlined public env var outside the template file. Those `*_PUBLIC_*`
prefixes are inlined into the client bundle, so a real value landing in git is
how keys leak in JS projects. The `-e` on the third one is required — the pattern
starts with `-` and grep would otherwise read it as an option.

The framework-specific names (mobile provisioning profiles, `EXPO_PUBLIC_`,
`google-services.json`) cost nothing in a repo that has none of them — they
simply never match. Ordering carries no meaning; do not read it as a target
stack.

**Any grep hit stops the command.** Report exactly what matched and in which
file. Do not commit, and do not unstage — leave the tree as the user left it and
let them decide.

Also stop if `git remote get-url origin` fails; there is nowhere to push.

**Stop before committing if `gh auth status` says not logged in** — except in
direct mode, which never touches `gh`. `gh auth login` is interactive, so you
cannot run it; tell the user to type `! gh auth login` in the prompt.

If nothing was staged, check `git log @{u}..HEAD --oneline`. If commits are
already sitting there, skip to step 4 and just push. If that is empty too, go to
step 5 — an unpushed branch may still be missing its PR. If there is nothing on
either side, say there is nothing to do.

## 2. Branch

If the current branch is `<base>` and this is not direct mode, create one from
the change: `git switch -c <type>/<kebab-summary>`, where type is `feat`, `fix`,
`docs` or `chore`. Otherwise stay where you are.

**If you switched, carry the verify ledger over with you:**

```bash
wt-verify adopt <the branch you were on> 2>&1 || true
```

The ledger is per-branch, and everything recorded so far — the review in step 0,
whatever `/wt:todo` ran — was filed under `<base>`, because that is where you were
standing when you ran it. Skip this and the new branch starts empty: `## 확인` in
step 5 reports every check as `미실행` for work that was genuinely verified, and
step 7's invalidation writes to the new branch while the real `review=ok` stays
behind on `<base>`, ready to wave through the *next* unreviewed push from there.
`adopt` refuses to overwrite a non-empty ledger, so it is safe when in doubt.

## 3. Message

Read `git diff --cached -U0 -- ':(exclude)*.lock' ':(exclude)*.lockb'
':(exclude)*-lock.json' ':(exclude)*-lock.yaml' ':(exclude)npm-shrinkwrap.json'
':(exclude)go.sum'` **once** — it feeds both the commit subject here and the PR
body in step 5. Git's `*` crosses `/`, so those six cover every ecosystem's
lockfile at any depth. Then write:

- One `type: summary` subject, imperative, under 72 characters, English, matching
  the existing history.
- One sentence underneath saying **why** — the part `git log` cannot reconstruct
  later. Wrap at 72; two lines at most. Leave out anything the diff already makes
  obvious. The detail belongs in the PR body, not here.

## 4. Commit and push — one call

```bash
git commit -F - <<'EOF'
<subject>

<one-line why>

<the Co-Authored-By trailer your harness instructions specify>
EOF
git push -u origin HEAD
```

In direct mode the push is `git push origin HEAD:<base>` instead, and the command
skips step 5 (no pull request): report the short SHA, the branch and the file
count, then go straight to **step 6**.

If the push is rejected, say so plainly and stop — do not force, and do not
rebase without being asked.

## 5. Pull request

**Check for an open one first:**

```bash
gh pr view --json url,state
```

If a PR is already open for this branch, the push in step 4 has updated it
already. Report the URL and stop — do not rewrite the body, the user may have
edited it by hand.

Otherwise assemble the body. Prefer the **plan + result** shape — that is the
record the user actually wants, not a diff summary. Body sections (Korean):

- **`## 플랜`** — the plan this work executed. Locate it: a path in `$ARGUMENTS`
  wins; else the newest `~/.claude/plans/*.md`. `cat` it straight into the body
  via the pipe below so its (possibly thousands of) characters bypass your tokens.
- **`## 결과`** — a short prose summary of what was actually done and how it turned
  out — the same thing you'd report to the user. **This is the only part you write.**
- **`## 확인`** — the roll call from `wt-verify checks`, piped in like the plan so
  you never retype it. It prints **every** step of the repo's ladder, filling
  anything unrecorded with `미실행`, which is the point: an omission shows up as a
  line instead of a silence. Emit the block whenever `wt-verify checks` produces
  output — only drop it when the command prints nothing (no ladder, no notes).

If the work was **not** plan-driven (no plan file fits), fall back to the old
diff-derived body instead: `## 변경 내용` (3~6 bullets of what/why, from the
step-3 diff) + `## 확인`. For branch-wide context use
`git log origin/<base>..HEAD --format='%s' && git diff origin/<base>...HEAD --stat`.

Title stays English (reuse the commit subject for a one-commit branch; else write
one covering the whole branch). Assemble by **piping files, never re-emitting them**:

```bash
PLAN="${plan_path:-$(ls -t ~/.claude/plans/*.md 2>/dev/null | head -1)}"
{
	if [ -n "$PLAN" ] && [ -f "$PLAN" ]; then printf '## 플랜\n\n'; cat "$PLAN"; printf '\n'; fi
	printf '## 결과\n\n'; cat <<'RESULT'
<한국어: 무엇을 했고 결과가 어땠는지>
RESULT
	CHECKS=$(wt-verify checks 2>/dev/null || true)
	if [ -n "$CHECKS" ]; then printf '\n## 확인\n\n%s\n' "$CHECKS"; fi
} | gh pr create --base <base> --title '<english subject>' --body-file -
```

The `cat "$PLAN"` carries the whole plan into the PR at ~zero token cost, and
`wt-verify checks` does the same for the verification roll call — only the short
`## 결과` is your prose.

**Human gates.** `wt-verify checks` renders a `[사람 확인 필요]` step as a real
GitHub checkbox (`- [ ] …`), so the gate lives where the reviewer already is. If
any such line came back, **repeat it as the last line of your terminal report**
too — the user may not open the PR right away — and do not call the work done.
Never let an unticked gate block the push; reporting it is the whole mechanism.

Report the PR URL. If `gh pr create` fails, **run step 7 anyway**, then report the
failure as-is and stop — the commit and the push already landed, so nothing gets
undone. The review record is retired by the code leaving this machine, not by the
PR existing; leaving it valid because the last step errored means the next
`/wt:remote-push` sees `review=ok` and lets unreviewed commits straight through.

## 6. Mark the TODO items as "PR raised"

Once the pull request exists (or, in direct mode, once the push lands), move this
tab's claims from `[-]` to `[~]`:

```bash
wt-todo pr 2>&1 || true
```

**`2>&1`, not `2>/dev/null`** — `wt-todo pr` reports on stderr (its stdout is the
rewritten file), so discarding stderr would leave you nothing to report. It always
prints a summary line, either `PR 표시: n건` or `PR 표시할 점유 항목 없음`, so you
can tell "nothing was claimed" from "something went wrong".

No arguments: it moves every line this tab owns, which is exactly the set this
branch was for. It is a **no-op when this tab claimed nothing**, so it is safe to
run after any push — and the `|| true` keeps a repo without a gitignored `TODO.md`
from turning a successful push into a failure report.

`[~]` means *the work left this tab and is waiting on a merge*: still owned, no
longer selectable, not yet done. The human ticks it to `[x]` after merging, which
ends the claim the same way it always did. If the PR is closed or superseded
instead, `wt-todo release` puts the item back to `[]`.

Mention the moved items in your final report so the state change is visible.

## 7. Invalidate the review record

The code that just went out was reviewed; the code that goes out *next* has not
been. Retire the marker so the gate in step 0 fires again on the following push:

```bash
wt-verify note review=skip:"이 푸시 시점까지만 리뷰됨 — 이후 커밋은 다시" 2>&1 || true
```

`skip` is not one of the statuses the step-0 gate accepts, so the next
`/wt:remote-push` on this branch reviews the new commits instead of trusting this
one's record.

This runs **after** step 5, so the PR you just opened still shows `- review — ok`
in its `## 확인` — correct, because at the moment that body was written the branch
*was* reviewed in full. The retirement applies to the next push, and shows up in
the next PR body. Do not reorder it to "fix" the discrepancy: invalidating first
would stamp every fresh PR as unreviewed.

**Local verification artifacts (screenshots, recordings) are never attached** —
`gh` cannot embed a local image, so `## 확인` names the check that ran, not a
file path.
