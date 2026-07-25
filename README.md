# claude-workflows

Claude Code 플러그인 마켓플레이스. 지금은 플러그인 하나가 들어 있다.

- **[`wt`](plugins/wt/)** — git worktree 병렬 작업. 워크트리를 repo 밖에 만드는 훅,
  CoW 프로비저닝, 경합 없는 TODO 점유 커맨드(`/wt:todo`), PR 커맨드
  (`/wt:remote-push`), 병렬 리뷰 + 반증 커맨드(`/wt:review`).

리뷰 자동화를 어디까지 밀지 고민 중이라면 [`docs/review-loop.md`](docs/review-loop.md).

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
claude --plugin-dir ./plugins/wt              # 설치본 무시하고 소스를 직접 로드
claude plugin validate ./plugins/wt --strict
/reload-plugins                               # 세션 중 반영
```

**설치된 플러그인은 소스 폴더가 아니라 캐시 복사본을 읽는다** — 고친 걸 실제로
반영하려면 `plugin.json`의 `version`을 올려야 한다. 전체 절차는
[플러그인 README의 "이 플러그인을 고치고 배포하기"](plugins/wt/README.md#이-플러그인을-고치고-배포하기).
