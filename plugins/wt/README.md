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
| `wt-verify` | 커맨드가 호출 | 검증 사다리 출력 + 무엇이 돌았는지 점호 |
| `wt-todo`, `wt-new` | PATH 실행파일 | todo/워크트리의 셸 진입점 |

## 요구사항

- **`jq`** — 하드 의존성이다(`brew install jq`). 훅이 stdin의 JSON 페이로드와
  `.claude/wt.json`을 읽는 데 쓴다. 없으면 설정을 못 읽어 조용히 절반만 프로비저닝될 수
  있으므로, 그 경우 스크립트가 경고를 낸다. `plan-nudge`는 jq가 없으면 그냥 침묵한다.
- `git` 2.x, `bash`. macOS 기준이지만 `flock` 같은 GNU 전용 도구는 쓰지 않는다.
- `gh` — `/wt:remote-push`의 PR 단계에만 필요하다.

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

## 새 프로젝트에 붙일 때 — 체크리스트

가장 마찰이 적은 길은 **사용자 스코프로 한 번 설치**하는 것이다. 그러면 프로젝트마다
`.claude/settings.json`을 손보지 않아도 모든 레포에서 켜진다.

```bash
claude plugin marketplace add Knorway/claude-workflows
claude plugin install wt@claude-workflows --scope user     # ← 한 번만
```

그다음 새 레포에서:

1. **`.gitignore`에 `/TODO.md`와 `/TODO.md.lock`.** 안 넣으면 `wt-todo`가 **파일을 만들지
   않고 거부한다** — 넣지 않은 채로 두면 `/wt:remote-push`의 `git add -A`가 머신 로컬
   스크래치패드를 PR로 내보내기 때문이다.
2. **`wt-verify plan`을 한 번 돌려본다.** 추정 사다리와 붙여넣을 `verify` 블록을 준다.
   맞으면 `.claude/wt.json`에 넣고, 아니면 고쳐서 넣는다.
3. **워크트리를 하나 만들어 본다**(`wt-new tmp`). 프로비저닝이 "메인에 있는 설정 파일이
   이 워크트리엔 없다"고 알려주면 그 경로를 `provision.copy`에 넣는다.
4. `provision.run`을 쓴다면 이 머신에서 한 번 허용한다(아래 참고).

레포를 공유하거나 CI에서도 켜지길 원할 때만 아래의 프로젝트 스코프 설정을 쓴다.

## 레포에 붙이기 (프로젝트 스코프)

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
    "copy":  [".env.local"],            // 그대로 복사할 gitignore 파일
    "mkdir": ["src/generated"],         // 생성기가 스스로 못 만드는 디렉터리
    "run":   ["make codegen"]           // 최초 프로비저닝 때 한 번 실행
  },
  "verify": [ /* 아래 "검증 사다리" 절 */ ]
}
```

**이 파일은 플러그인이 배포하지도 생성하지도 않는다.** 새 레포에 설치해도 아무 파일이
안 생기고, 없으면 모든 조회가 기본값으로 떨어진다 — `node_modules`가 있을 때만 복제하고
끝이다. **설정 0으로 동작한다.**

값은 전부 그 레포의 것이다. 위 예시가 JS로 보이는 건 예시라서지 플러그인이 JS를 알기
때문이 아니다. Rust 레포라면 `clone: ["target"]`, `run: ["cargo build"]`가 된다.

### `run`은 머신 주인이 레포마다 한 번 허용해야 한다

다른 키는 **복사할 경로**를 적지만 `run`은 **명령**을 적고, 이 파일은 레포에 커밋된다.
그대로 두면 남의 레포를 클론해 워크트리 세션을 한 번 여는 것만으로 그 명령이 조용히
실행된다 — Claude Code가 프로젝트 훅에 신뢰 승인을 요구하는 바로 그 위험이고, 우리
훅이 레포 파일을 읽는 것이 그 승인을 우회하는 통로가 되어선 안 된다.

그래서 레포는 명령을 **제안**만 하고, 실행 여부는 머신 주인이 한 번 정한다:

```bash
echo /path/to/repo >> ~/.claude/wt-run-allow      # 빈 줄과 # 주석 무시
```

허용되지 않은 레포에서는 `run`을 건너뛰고, **무엇을 건너뛰었고 어떻게 허용하는지**를
세션 시작 메시지로 알려준다. 복사·복제·디렉터리 생성은 아무것도 실행할 수 없으므로
게이트가 없다. 경로 대신 `WT_RUN_ALLOW_FILE`로 다른 허용 목록을 지정할 수도 있다.

> 플러그인의 `pluginConfigs`/`user_config`를 쓰지 않는 이유: Claude Code는 프로젝트
> `.claude/settings.json`의 `pluginConfigs`를 **무시한다**(클론한 레포가 훅 커맨드에
> 값을 주입할 수 있어서). 그래서 레포별 설정은 스크립트가 직접 읽는 레포 안 파일이다.

## 검증 사다리 — `verify` 와 사람 게이트

무엇을 돌려야 변경이 "끝난" 것인지를 기계가 읽을 수 있게 적는다. 싼 것부터 순서대로.

```jsonc
"verify": [
  { "id": "typecheck", "run": "yarn typecheck" },
  { "id": "codegen",   "run": "yarn relay", "when": "스키마가 바뀌었을 때" },
  { "id": "e2e",       "human": true,  "when": "UI가 바뀌었을 때", "note": "CLAUDE.md '검증' 절" },
  { "id": "release",   "worktree": false, "note": "절대경로를 굽는 툴체인 — 메인에서만" }
]
```

| 필드 | 기본 | 의미 |
| --- | --- | --- |
| `id` | (필수) | 점호에 쓰이는 안정된 키 |
| `run` | — | **원문 그대로 출력되는** 명령. 여러 단계면 생략하고 `note`로 문서를 가리킨다 |
| `when` | — | 언제 돌리는지. 산문 — 모델이 판단한다 |
| `worktree` | `true` | `false` = 워크트리에서 물리적으로 불가 |
| `human` | `false` | 기계가 판정 못 함 → 사람 게이트 |
| `note` | — | 한 줄 주의, 또는 문서 포인터 |

```bash
wt-verify plan                          # 사다리를 출력한다 (실행은 하지 않는다)
wt-verify note typecheck=ok api=skip:서버미기동
wt-verify note e2e=human:"시트가 60% 높이로 올라오는지"
wt-verify checks                        # PR 본문 `## 확인`에 들어갈 점호
```

- **`wt-verify`는 명령을 출력만 한다. 절대 실행하지 않는다.** 실행은 모델이 평범한
  Bash로 한다. `wt-verify run <id>` 같은 건 없다 — 불투명한 id 뒤에서 레포 문자열이
  도는 건 프롬프트 세탁이다.
- **다만 그것만으로 안전해지지 않는다.** `wt.json`은 커밋되는 파일이고, allow 규칙이
  넓으면(`Bash(curl *)` 등) permission 프롬프트가 아예 안 뜬다. 그래서 사다리는
  **primary 체크아웃의 계약을 먼저** 쓰고(다른 데서 왔으면 `plan`이 알린다), 검증 단계가
  할 일이 아닌 모양은 `⚠ 위험 패턴`으로 **표시**한다 — 셸로 파이프, 비-로컬 네트워크,
  셸 치환, 홈·비밀 경로, 파괴적 명령, 인코딩 해독. 로컬 `curl` 같은 정상 계약엔 침묵한다.
  **이상한 계약을 알아채는 장치이지 안전장치가 아니다.**
- **`checks`는 계약의 모든 id를 찍고, 기록 없는 건 `미실행`으로 채운다.** 빠뜨린 검증이
  침묵이 아니라 줄로 보이는 게 요점이다. `worktree: false` 단계는 워크트리에서 자동으로
  `건너뜀(메인 체크아웃 전용)`이 된다.
- **`human` 단계는 PR 본문에 진짜 체크박스(`- [ ]`)로 나온다.** 푸시를 막지는 않는다 —
  막으면 안 쓰게 되므로, 보고가 전부다.
- **`verify`가 없어도 된다.** 없으면 `package.json` scripts·`Cargo.toml`·`go.mod`·
  `pyproject.toml`·`Makefile`을 보고 **추정**해서 출력하고, 그대로 굳힐 수 있게
  **붙여넣을 `verify` 블록까지 찍어준다.** 추정할 것도 없으면 직접 찾아 돌리고 못 돌린 건
  이름을 대라고 안내한다.

`wt.json`의 `verify`는 **색인**이고 `CLAUDE.md`는 **매뉴얼**이다. 왜 그 포트여야 하는지,
어떤 식으로 실패하는지 같은 산문은 `CLAUDE.md`에 두고 `note`로 가리킨다 — 두 군데 적으면
갈라진다. 자세한 근거는 [`docs/wt-design.md`](../../docs/wt-design.md).

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

`TODO.md` **한 파일**이 목록이자 점유 기록이다.

```
- [] 본문                 자유, 선택 가능
- [-] 본문  #<slug>       점유, 그 탭이 작업 중
- [~] 본문  #<slug>       PR 올라감, 머지 대기      ← /wt:remote-push 가 찍는다
- [x] 본문                완료 (점유도 함께 끝남)
```

별도 점유 원장이 없으니 어긋날 것이 없고, 사람이 `[-]`나 `[~]`를 `[x]`로 바꾸면 점유도
함께 끝난다. PR이 닫히거나 갈아엎였으면 `wt-todo release`가 `[]`로 되돌린다.
(`wt-verify`의 원장은 별개 파일이다 — `.git/worktrees/<name>/wt/verify-<branch>.tsv`.)

- 파일은 **primary 체크아웃에만** 있고, 모든 워크트리가 `--git-common-dir`로 그 한
  파일을 찾아간다. 워크트리마다 자기 사본을 만들지 않는 게 핵심이다.
- 쓰기는 전부 락(`TODO.md.lock`, `mkdir` 원자성) 아래에서 파일 전체를 다시 쓰고
  rename하므로 두 탭이 같은 줄에서 동시에 이길 수 없다.
- 슬러그는 체크아웃 디렉터리 이름이다 — 브랜치 이름 규약을 아무도 알 필요가 없다.
- **`TODO.md`와 `TODO.md.lock`은 `.gitignore`에 넣어야 한다.** 머신 로컬
  스크래치패드라야 브랜치 전환이 내용을 흔들지 않는다. 안 넣으면 `wt-todo`가 **파일을
  만들지 않고 거부한다** — 점유 마커와 메모가 `/wt:remote-push`의 `git add -A`를 타고
  PR로 나가는 걸 막는 게 부탁이 아니라 가드여야 하기 때문이다.

셸에서 직접: `wt-todo list | add "<메모>" | claim <줄번호…> | pr | release | mine`.

**새 상태를 만들려면 `list`/`claim`/`pr`/`release`/`mine`을 한꺼번에 가르쳐야 한다.**
`list`가 모르는 마커는 항목의 상태를 바꾸는 게 아니라 목록에서 **사라지게** 만든다.

## `/wt:review` — 편향 없는 리뷰

구현한 세션이 자기 코드를 다시 읽으면 자기 합리화까지 물려받는다. 이 커맨드는
**문맥이 전혀 없는 서브에이전트**를 렌즈별로 병렬로 띄우고, 나온 지적마다 **반증
담당**을 붙여 거른 뒤, 살아남은 것(CONFIRMED)만 고친다.

```bash
/wt:review              # 현재 브랜치 vs base (워킹 트리·untracked 포함)
/wt:review 28           # PR #28
```

**모드는 하나다.** 렌즈 수도 반증 표 수도 플래그가 아니라 diff에서 유도한다 — 렌즈
1·2·3은 항상, 인터페이스 렌즈는 공개 계약(`export`/타입/스키마/마이그레이션)을 건드릴 때,
**테스트 작성자는 테스트 러너가 감지될 때.** 반증은 항상 1표다(같은 기반 모델을 여러 표
쌓아도 오차가 상관되어 표 수만큼 정확해지지 않는다).

- **diff 원문은 오케스트레이터 문맥에 올라가지 않는다.** `--stat`만 보고, 원문은 각
  서브에이전트가 자기 문맥에서 직접 읽는다 — 이 커맨드의 비용을 결정하는 규칙이다.
- **리뷰 범위 = 푸시 범위.** 커밋된 것만이 아니라 워킹 트리와 untracked까지 본다.
  이 커맨드의 수정은 커밋되지 않은 채 남으므로, 좁게 잡으면 자기 출력에 눈이 먼다.
- 리뷰어와 반증 담당에게는 **Edit/Write가 없다.** 유일한 예외가 **테스트 작성자**인데,
  쓰기 경로가 **테스트 파일로 제한**된다 — 프로덕션 코드는 5단계 자동 수정만 건드린다.
- **테스트 작성자**는 원래 세션이 쓴 테스트를 회의적으로 보고 엣지케이스를 **직접 써서
  레포에 남긴다.** 빨간 것은 결함 보고가 되고(그 테스트가 곧 재현 명령이다), 초록은
  커버리지로 남는다. 기대값을 코드를 돌려서 얻는 것은 금지 — 현재 동작을 골든으로 박는
  것은 버그를 정전화하는 방법이다.
- **규약 문서(`CLAUDE.md`/`AGENTS.md`/`DESIGN.md`)는 자동 수정하지 않는다.** 다음 라운드
  규약 렌즈의 유일한 증거 기반이라, 여기 착지한 틀린 문장이 두 라운드 만에 사실이 된다.
  제안 diff로 보고에만 싣는다.
- **머지·닫힌 PR은 읽기 전용으로 강등된다.** 옛 diff를 보고 지금의 워킹 트리를 고치면
  이미 해결된 것을 되돌리기 때문이다. 지난 PR을 교보재로 돌려볼 때 안전하다.
- PLAUSIBLE은 사람이 고르고, REFUTED도 화면에 남긴다 — 무엇이 걸러졌는지 보여야
  걸러낸다는 사실을 신뢰할 수 있다.
- 커밋하지 않는다. 커밋·푸시는 `/wt:remote-push`의 일이다.
- 끝나면 원장에 `review=…`를 남긴다. 그래서 **`/wt:remote-push`가 리뷰 안 한 브랜치를
  잡아낸다** — 기록이 없으면 푸시 전에 한 번 강제로 돌리고, 사람이 판단할 것이 남으면
  보고한 뒤 계속할지 묻는다. 급할 땐 `/wt:remote-push --no-review`.
  PLAUSIBLE이 남았거나 **CONFIRMED가 미수정으로 남았으면** `review=human:…`으로 남겨
  PR에 체크박스로 띄운다.
- **전체 테스트 스위트는 리뷰 안에서 반복 실행하지 않는다.** 테스트 작성자는 자기가 쓴
  파일만 돌리고, 전체는 수정 후 `wt-verify` 사다리에서 **한 번** 돈다.

왜 이 모양인지(독립성 등급, 비용 모델, 완전 자동 루프의 함정, CI로 올리는 법)는
[`docs/review-loop.md`](../../docs/review-loop.md).

## plan-nudge

plan 모드가 아닐 때 UserPromptSubmit에 **모델에게만 보이는** 안내를 주입한다
(`hookSpecificOutput.additionalContext`) — "실질 작업이면 착수 전에 plan 모드를 한 번
제안하라". 사용자에겐 보이지 않는다.

- SessionStart 훅에는 `permission_mode`가 **없어서** 세션 시작 시점엔 판단할 수 없다.
  그래서 UserPromptSubmit이다.
- 상태를 저장하지 않는다. "한 번만 제안" 판단은 모델이 자기 대화 기록을 보고 한다.
- 예외 하나: 프롬프트가 `/wt:todo` 목록에 대한 번호 답장이면 **claim이 먼저**고, 사소한
  항목이 아니면 그 직후 모델이 `EnterPlanMode`로 직접 진입한다 — 그 경우엔 "제안"이
  아니다.
- **`defaultMode`는 네가 정한다.** `plan`으로 두면 모든 세션이 plan으로 시작하고 이 훅은
  조용히 아무것도 하지 않는다 — 대신 plan 모드가 모든 쓰기를 막으므로 `/wt:todo`의
  claim이 걸려 매 선택마다 shift+tab이 필요하다. 반대로 non-plan 디폴트 + 이 훅 +
  `EnterPlanMode` 조합은 그 마찰이 없지만 사전 승인 게이트를 잃는다. 트레이드오프와
  어느 파일에 넣을지는 [`commands/todo.md`](commands/todo.md)의 "세션 권한 설정" 참고.
