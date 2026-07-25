# claude-workflows

Claude Code 플러그인 마켓플레이스. 지금은 플러그인 하나가 들어 있다.

- **[`wt`](plugins/wt/)** — git worktree 병렬 작업. 워크트리를 repo 밖에 만드는 훅,
  CoW 프로비저닝, 경합 없는 TODO 점유 커맨드(`/wt:todo`), PR 커맨드
  (`/wt:remote-push`).

## 설치

```bash
/plugin marketplace add Knorway/claude-workflows
/plugin install wt@claude-workflows
```

레포마다 켜려면 그 레포의 `.claude/settings.json`에:

```json
{ "enabledPlugins": { "wt@claude-workflows": true } }
```

레포별 동작은 `.claude/wt.json`으로 조정한다 — 없어도 동작한다. 자세한 건
[플러그인 README](plugins/wt/README.md).

## 개발

```bash
claude --plugin-dir ~/Desktop/claude-workflows/plugins/wt   # 설치 없이 로드
claude plugin validate ~/Desktop/claude-workflows/plugins/wt --strict
/reload-plugins                                             # 세션 중 반영
```
