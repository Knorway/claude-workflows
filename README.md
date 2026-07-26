# claude-workflows

Claude Code 플러그인 마켓플레이스. 지금은 플러그인 하나가 들어 있다.

- **[`wt`](plugins/wt/)** — git worktree 병렬 작업. 워크트리를 repo 밖에 만드는 훅,
  CoW 프로비저닝, 경합 없는 TODO 점유 커맨드(`/wt:todo`), 검증 사다리와 사람 게이트
  (`wt-verify`), PR 커맨드(`/wt:remote-push`), 병렬 리뷰 + 반증 커맨드(`/wt:review`).

무엇을 지향하고 무엇을 일부러 안 하는지는 [`docs/wt-design.md`](docs/wt-design.md).
리뷰 자동화를 어디까지 밀지 고민 중이라면 [`docs/review-loop.md`](docs/review-loop.md).

## 설치

`jq`가 필요하다(`brew install jq`).

```bash
/plugin marketplace add Knorway/claude-workflows
/plugin install wt@claude-workflows --scope user      # 모든 레포에서 켜짐
```

특정 레포에서만 켜려면 `--scope project`로 설치하고, 그 레포의
`.claude/settings.json`에 마켓플레이스 선언까지 함께 넣는다(그래야 클론한 사람에게도
이름이 풀린다 — [플러그인 README](plugins/wt/README.md#레포에-붙이기-프로젝트-스코프)).

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
