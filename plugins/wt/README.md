# wt — 워크트리 병렬 작업 플러그인

여러 작업을 동시에 진행할 때 세션마다 독립된 폴더+브랜치를 준다. 같은 폴더를 탭
여러 개로 공유하면 `git add -A`가 남의 작업을 쓸어담고 `git switch -c`가 다른 탭까지
브랜치를 끌고 가므로, worktree로 물리적으로 분리한다.

## 구성

| 구성요소 | 이벤트/명령 | 하는 일 |
| --- | --- | --- |
| `wt-create.sh` | WorktreeCreate | 워크트리를 **repo 밖** 형제 디렉터리에 만든다 |
| `wt-remove.sh` | WorktreeRemove | 그 형제 디렉터리를 정리한다(비강제) |
| `wt-provision.sh` | SessionStart | node_modules 등 gitignore된 것들을 CoW로 채운다 |
| `sync-main.sh` | SessionStart | primary 체크아웃의 base 브랜치를 ff-only로 당긴다 |
| `plan-nudge.sh` | UserPromptSubmit | plan 모드가 아니면 제안하라고 모델에게만 귀띔 |
| `/wt:todo` | 커맨드 | 메인의 `TODO.md` 한 파일에서 경합 없이 항목을 점유 |
| `/wt:remote-push` | 커맨드 | 비밀키 스캔 → 커밋 → 푸시 → PR |
| `/wt:review` | 커맨드 | 문맥 없는 리뷰어 여럿 병렬 → 반증 검증 → CONFIRMED만 수정 |
| `wt:reviewer`, `wt:refuter` | 서브에이전트 | `/wt:review`가 띄우는 읽기 전용 리뷰어/회의론자 |
| `wt-todo`, `wt-new` | PATH 실행파일 | todo/워크트리의 셸 진입점 |

## 쓰는 법

```bash
claude --worktree          # 워크트리 + 브랜치 생성 후 그 안에서 세션 시작
```

프로비저닝은 SessionStart 훅이 최초 1회 자동으로 한다("worktree 프로비저닝 중…").
이후 세션 시작은 즉시. 끝나면 세션 종료 시 WorktreeRemove 훅이 정리하고, 커밋 안 된
작업이 남아 있으면 **지우지 않고 남겨 둔다.**

세션을 새로 열지 않고 워크트리만 만들려면(예: 두 번째 개발 서버) `wt-new <name>`.
`wt-new`·`wt-todo`는 플러그인이 **Claude Code 세션의 PATH 끝에 붙여주는** 실행파일이라
세션 안에서만 이름으로 잡힌다. 평범한 터미널에서도 쓰려면 셸 설정에 직접 넣는다:

```bash
export PATH="$PATH:<플러그인 경로>/bin"   # 설치본은 ~/.claude/plugins/cache/<마켓>/wt/<버전>/bin
```

버전이 올라가면 캐시 경로가 바뀌므로, 소스 체크아웃 쪽 `plugins/wt/bin`을 가리키는
편이 덜 깨진다.

## 이 플러그인을 고치고 배포하기

### 알아야 할 사실 하나

**설치된 플러그인은 소스 폴더를 읽지 않는다.**
`~/.claude/plugins/cache/<마켓플레이스>/<플러그인>/<버전>/` 에 **복사본**으로 들어간다.
그래서 소스만 고치고 `plugin update`를 하면 이렇게 끝난다:

```
✔ wt is already at the latest version (0.2.0).
```

**`plugin.json`의 `version`을 올리는 것이 업데이트의 트리거다.**

### 1. 개발 루프 — 설치본을 무시하고 소스를 직접 읽기

```bash
claude --plugin-dir <경로>/claude-workflows/plugins/wt
```

버전을 올릴 필요도 커밋할 필요도 없다. 세션 도중 고쳤으면 `/reload-plugins`.
만드는 동안은 이것만 쓰면 된다.

### 2. 배포 — 확정할 때

```bash
#   1) 고친다
#   2) plugins/wt/.claude-plugin/plugin.json 의 version 을 올린다   ← 필수
claude plugin validate ./plugins/wt --strict
git commit && git push
```

### 3. 적용

**최초 1회.** 소비자 레포가 `.claude/settings.json`에 마켓플레이스를 선언해 두면
(아래 "레포에 붙이기") 폴더를 신뢰할 때 설치 안내가 뜬다. 손으로 하려면:

```bash
claude plugin marketplace add Knorway/claude-workflows
claude plugin install wt@claude-workflows --scope project
```

**이후.** 카탈로그를 당기고, 플러그인을 올리고, 재시작한다:

```bash
claude plugin marketplace update claude-workflows
claude plugin update wt@claude-workflows --scope project
# → "Restart to apply changes"
```

`--scope project`를 빼면 사용자 스코프를 보고
`✘ Plugin "wt" is not installed at scope user` 로 실패한다. 설치할 때 쓴 스코프를
업데이트에도 그대로 써야 한다.

### 마켓플레이스를 로컬 디렉터리로 등록한 경우

`claude plugin marketplace add <경로>` 로 등록하면 소스가 GitHub가 아니라 그 폴더가
된다. 그러면 **푸시하지 않아도** `marketplace update`가 로컬 작업본을 읽는다 — 공개
전에 실물로 돌려볼 수 있다. 뒤집으면 **푸시를 잊으면 그 머신만 최신**이다.

소비자 레포가 `extraKnownMarketplaces`로 GitHub 소스를 선언해도 **이미 등록된 쪽이
이긴다.** GitHub로 통일하려면 지우고 다시 넣는다:

```bash
claude plugin marketplace remove claude-workflows
claude plugin marketplace add Knorway/claude-workflows
```

## 레포에 붙이기

소비자 레포의 `.claude/settings.json`에 **두 가지**를 쓴다. `enabledPlugins`만 쓰면
마켓플레이스 이름이 그 머신의 사용자 설정으로만 풀리고, 새로 클론한 사람에게는
이름이 안 풀린다. **플러그인 부재는 에러가 아니라 무동작**이라 훅이 조용히 사라지고
`claude --worktree`가 기본값대로 repo 안에 워크트리를 만든다.

```json
{
  "extraKnownMarketplaces": {
    "claude-workflows": {
      "source": { "source": "github", "repo": "Knorway/claude-workflows" }
    }
  },
  "enabledPlugins": { "wt@claude-workflows": true }
}
```

## 레포별 설정 — `.claude/wt.json` (전부 선택)

```jsonc
{
  "worktreeRoot": "~/somewhere/else",   // 생략 시 <repo>-wt 형제 디렉터리
  "baseBranch": "main",                 // 생략 시 main → master → origin/HEAD
  "provision": {
    "clone": ["node_modules"],          // CoW 복제할 디렉터리(레포 상대경로)
    "copy":  ["apps/mobile/.env.local"],// 그대로 복사할 gitignore 파일
    "mkdir": ["src/__generated__"],     // 생성기가 스스로 못 만드는 디렉터리
    "run":   ["yarn relay"]             // 최초 프로비저닝 때 한 번 실행
  }
}
```

설정 파일이 **없으면** `node_modules`가 있을 때만 복제하고 끝난다. 설정 0으로도
동작한다.

> 플러그인의 `pluginConfigs`/`user_config`를 쓰지 않는 이유: Claude Code는 프로젝트
> `.claude/settings.json`의 `pluginConfigs`를 **무시한다**(클론한 레포가 훅 커맨드에
> 값을 주입할 수 있어서). 그래서 레포별 설정은 스크립트가 직접 읽는 레포 안 파일이다.

## 워크트리는 repo 밖에 둔다

`claude --worktree`의 기본 위치는 repo **안**의 `.claude/worktrees/<name>`이다. JS
레포에서 이건 치명적이다 — 메인 체크아웃의 파일 감시자(Metro/webpack/watchman)가
워크트리의 `node_modules`(= 같은 모듈의 두 번째 사본)까지 크롤해 중복 모듈·haste
충돌을 내고, 워크트리가 자기 개발 서버를 띄우면 watch root가 메인 것 안에 중첩된다.

그래서 `wt-create.sh`가 `<repo>-wt/<name>` 형제 디렉터리로 옮긴다. 각 체크아웃이
독립된 watch root가 되고, 번들러 설정은 하나도 안 건드린다.

## node_modules는 심볼릭 링크가 아니라 CoW 클론이다 (검증 결과)

`symlinkDirectories`처럼 **`node_modules`를 디렉터리째 심볼릭 링크하면 조용히
틀린다.** 워크스페이스 레포의 `node_modules`에는 **상대 심볼릭 링크**가 들어 있다:

```
node_modules/@scope/schema  ->  ../../packages/schema
node_modules/mobile         ->  ../apps/mobile
```

`node_modules`를 통째로 심볼릭 링크하면 안쪽 이 상대 링크들이 링크를 타고 넘어가
**원본 체크아웃**을 가리킨다. 즉 워크트리에서 스키마를 고쳐도 서버·컴파일러가
원본의 옛 파일을 읽는다 — **에러 없이 조용히.**

두 방식을 실제로 만들어 `realpath`로 확인한 값(APFS):

| 방식 | `node_modules/@scope/schema` 최종 경로 | 디스크 |
| --- | --- | --- |
| 디렉터리 심볼릭 링크 | `.../<repo>/packages/schema` (원본) ❌ | 0 |
| `cp -c -R` CoW 클론 | `.../<repo>-wt/<name>/packages/schema` (워크트리) ✅ | ~0 (df 불변) |

APFS `cp -c`는 copy-on-write라 수 GB짜리 `node_modules`를 복제해도 실제 디스크는 거의
안 먹고(수정된 블록만 분리), 네트워크도 재설치도 필요 없다. CoW를 지원하지 않는
파일시스템에서는 자동으로 일반 복사로 떨어진다.

**`yarn install`은 언제?** 락파일이 바뀔 때만. 평상시엔 CoW 클론으로 충분하고 빠르다.

## 워크트리에서 주의할 것

- **의존성은 스냅샷이다.** 최초 프로비저닝 이후 원본에서 `yarn add`를 해도 워크트리엔
  반영 안 된다. 의존성 변경은 원본에서 하고 워크트리를 다시 판다.
- **복사한 `.env` 류도 스냅샷이다.** 훅은 "없을 때만" 복사하므로, 워크트리를 만든
  **뒤** 원본에서 값을 바꿔도 전파되지 않는다.
- **단일 포트를 점유하는 개발 서버는 하나뿐**이고 보통 원본이 소유한다. 워크트리는
  포트를 분리하거나 원본 것을 쓴다.
- **네이티브 빌드 산출물이 절대경로를 굽는 툴체인(CocoaPods 등)은 워크트리에서
  금지.** 그런 검증은 원본 체크아웃에서 한다.
- **`yarn add`는 작업 중엔 격리되지만 머지 때 부딪힌다.** 두 워크트리가 각각 설치하고
  둘 다 머지하면 락파일이 충돌한다(일반 git 현상). 한쪽을 택하고 재생성하면 된다.

## `/wt:todo` — 경합 없는 점유

`TODO.md` **한 파일**이 목록이자 점유 기록이다. 빈 항목은 `- []`, 어느 탭이 잡은
항목은 `- [-] 본문  #<slug>`, 끝난 항목은 `- [x]`. 별도 원장이 없으니 어긋날 것이
없고, 사람이 `[-]`를 `[x]`로 바꾸면 점유도 함께 끝난다.

- 파일은 **primary 체크아웃에만** 있고, 모든 워크트리가 `--git-common-dir`로 그 한
  파일을 찾아간다. 워크트리마다 자기 사본을 만들지 않는 게 핵심이다.
- 쓰기는 전부 락(`TODO.md.lock`, `mkdir` 원자성) 아래에서 파일 전체를 다시 쓰고
  rename하므로 두 탭이 같은 줄에서 동시에 이길 수 없다.
- 슬러그는 체크아웃 디렉터리 이름이다 — 브랜치 이름 규약을 아무도 알 필요가 없다.
- **`TODO.md`와 `TODO.md.lock`은 `.gitignore`에 넣어야 한다.** 머신 로컬
  스크래치패드라야 브랜치 전환이 내용을 흔들지 않는다.

셸에서 직접: `wt-todo list | add "<메모>" | claim <줄번호…> | release | mine`.

## `/wt:review` — 편향 없는 리뷰

구현한 세션이 자기 코드를 다시 읽으면 자기 합리화까지 물려받는다. 이 커맨드는
**문맥이 전혀 없는 서브에이전트**를 렌즈별로 병렬로 띄우고, 나온 지적마다 **반증
담당**을 붙여 거른 뒤, 살아남은 것(CONFIRMED)만 고친다.

```bash
/wt:review              # 현재 브랜치 vs base — 렌즈 3, 반증 1표
/wt:review 28           # PR #28
/wt:review --quick      # 렌즈 2, 반증·수정 없음 (훑어보기)
/wt:review --deep       # 렌즈 5, 반증 3표 과반
```

- **diff 원문은 오케스트레이터 문맥에 올라가지 않는다.** `--stat`만 보고, 원문은 각
  서브에이전트가 자기 문맥에서 직접 읽는다 — 이 커맨드의 비용을 결정하는 규칙이다.
- 리뷰어에게는 **Edit/Write가 없다.** 리뷰어는 절대 고치지 않는다.
- **머지·닫힌 PR은 읽기 전용으로 강등된다.** 옛 diff를 보고 지금의 워킹 트리를 고치면
  이미 해결된 것을 되돌리기 때문이다. 지난 PR을 교보재로 돌려볼 때 안전하다.
- PLAUSIBLE은 사람이 고르고, REFUTED도 화면에 남긴다 — 무엇이 걸러졌는지 보여야
  걸러낸다는 사실을 신뢰할 수 있다.
- 커밋하지 않는다. 커밋·푸시는 `/wt:remote-push`의 일이다.

왜 이 모양인지(독립성 등급, 비용 모델, 완전 자동 루프의 함정, CI로 올리는 법)는
[`docs/review-loop.md`](../../docs/review-loop.md).

## plan-nudge

plan 모드가 아닐 때 UserPromptSubmit에 **모델에게만 보이는** 안내를 주입한다
(`hookSpecificOutput.additionalContext`) — "실질 작업이면 착수 전에 plan 모드를 한 번
제안하라". 사용자에겐 보이지 않는다.

- SessionStart 훅에는 `permission_mode`가 **없어서** 세션 시작 시점엔 판단할 수 없다.
  그래서 UserPromptSubmit이다.
- 상태를 저장하지 않는다. "한 번만 제안" 판단은 모델이 자기 대화 기록을 보고 한다.
- 애초에 **모든 세션을 plan으로 시작**하고 싶으면 nudge 대신 레포
  `.claude/settings.json`에 `{"permissions": {"defaultMode": "plan"}}`을 넣으면 된다.
  그러면 이 훅은 조용히 아무것도 하지 않는다.
