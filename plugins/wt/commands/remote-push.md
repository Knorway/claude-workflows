---
description: Scan for secrets, commit, push, and open a PR with a Korean body
argument-hint: [base | hint for the message]
---

Commit everything in the working tree, push it to `origin`, and open a pull
request against the base branch.

`$ARGUMENTS` is a free-form hint. If it names the base branch (`main`, `master`,
`main으로`, `여기에`), run in **direct mode**: no pull request, push straight to
the remote base branch. Otherwise treat it as a steer for the message. Empty is
the normal case.

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

## 1. Gather and scan — one call

```bash
git remote get-url origin && git branch --show-current && git add -A && git diff --cached --stat
git diff --cached --name-only | git check-ignore --stdin
git diff --cached --name-only | grep -Ei '(^|/)\.env($|\.)|\.(pem|key|p12|pfx|jks|keystore|mobileprovision)$|(^|/)id_(rsa|ed25519)|google-services\.json|GoogleService-Info\.plist'
git diff --cached -U0 | grep -E '^\+' | grep -Ein -e '-----BEGIN[A-Z ]*PRIVATE KEY|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{30,}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|sk-[A-Za-z0-9]{20,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.|(secret|passwd|password|api[_-]?key|access[_-]?token|client[_-]?secret|private[_-]?key)["'"'"' ]*[:=]["'"'"' ]*[^"'"'"'[:space:],;)}]{12,}'
git diff --cached -U0 -- ':(exclude)*.env.example' ':(exclude)*.env.sample' | grep -E '^\+(EXPO_PUBLIC|NEXT_PUBLIC|VITE|REACT_APP|PUBLIC)_[A-Z0-9_]+=.+'
gh auth status
```

The four greps are, in order: a force-added ignored file; a filename that should
never be committed; a secret in an added line; a real value for a
build-time-inlined public env var outside the template file. Those `*_PUBLIC_*`
prefixes are inlined into the client bundle, so a real value landing in git is
how keys leak in JS projects. The `-e` on the third one is required — the pattern
starts with `-` and grep would otherwise read it as an option.

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

## 3. Message

Read `git diff --cached -U0 -- ':(exclude)yarn.lock' ':(exclude)package-lock.json'
':(exclude)pnpm-lock.yaml' ':(exclude)Cargo.lock' ':(exclude)go.sum'` **once** — it
feeds both the commit subject here and the PR body in step 5. Then write:

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
**ends here**: report the short SHA, the branch and the file count, and do not
go to step 5.

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
- **`## 확인`** — checks this session actually ran; drop the block if none.

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
	printf '\n## 확인\n\n'; cat <<'CHECKS'
<실제로 돌린 검증만 — 없으면 이 블록 통째로 뺀다>
CHECKS
} | gh pr create --base <base> --title '<english subject>' --body-file -
```

The `cat "$PLAN"` carries the whole plan into the PR at ~zero token cost; only the
short `## 결과` (and `## 확인`) are your prose.

Report the PR URL. If `gh pr create` fails, report it as-is and stop — the commit
and the push already landed, so nothing gets undone.

**Local verification artifacts (screenshots, recordings) are never attached** —
`gh` cannot embed a local image, so `## 확인` names the check that ran, not a
file path.
