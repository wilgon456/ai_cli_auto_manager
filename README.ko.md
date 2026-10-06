<div align="center">

# AI CLI Auto Manager

[English](README.md) · **한국어**

**이 컴퓨터에 깔린 AI 코딩 CLI를 매주 찾아 목록으로 정리하고, 매일 새벽 안전하게 최신으로 올리고,<br>
그 도구들이 쌓아 두는 오래된 세션·임시 파일·캐시를 매주 치웁니다.**

[![ci](https://github.com/wilgon456/ai_cli_auto_manager/actions/workflows/ci.yml/badge.svg)](https://github.com/wilgon456/ai_cli_auto_manager/actions/workflows/ci.yml)
[![macOS](https://img.shields.io/badge/macOS-launchd-000000?logo=apple&logoColor=white)](#예약-실행)
[![Windows](https://img.shields.io/badge/Windows-Task_Scheduler-0078D4?logo=windows11&logoColor=white)](#예약-실행)
[![Linux](https://img.shields.io/badge/Linux-cron-FCC624?logo=linux&logoColor=black)](#예약-실행)
[![License: MIT](https://img.shields.io/badge/License-MIT-22c55e.svg)](LICENSE)

</div>

---

AI 코딩 CLI를 몇 달 쓰면 세 가지가 헷갈리기 시작합니다. 무엇을 깔아 두었는지, 그게 최신인지, 디스크를 얼마나 먹는지입니다.
같은 CLI가 앱용·npm용으로 두 벌 깔려 있어서 업데이트는 한쪽만 되고 실제로는 옛 버전을 쓰고 있는 일도 흔합니다.
이 도구는 세 가지 일을 예약해 두고 대신 챙깁니다. 설치 없이 저장소를 받아 명령 하나로 예약하면 됩니다.

| 작업 | 주기 (기본 시각) | 하는 일 |
| --- | --- | --- |
| 목록 | 매주 (월 12:00) | 깔린 AI CLI를 찾아 버전, 최신 버전, 설치 방식, 매일 업데이트가 실제로 닿는지를 표로 남깁니다. 새로 생기거나 사라진 CLI는 알림으로 알려 줍니다 |
| 업데이트 | 매일 (05:00) | 깔린 CLI를 모두 올립니다. npm으로 깐 CLI는 나온 지 3일 지난 버전만, 이상 징후와 서명을 확인한 뒤 깝니다. 하나가 실패해도 나머지는 계속합니다 |
| 정리 | 매주 (월 12:30) | 30일 동안 쓰지 않은 대화 기록과 날짜가 지난 임시 파일·캐시를 지웁니다. 링크는 따라가지 않고, 메모리·인증·설정 파일은 지우지 않습니다 |

세 작업은 실행될 때마다 나머지 둘이 아직 등록돼 있는지 확인합니다. 예약이 사라졌거나 실행이 실패하면 바탕화면 알림을 띄웁니다.

## 빠른 시작

### Windows

```powershell
git clone https://github.com/wilgon456/ai_cli_auto_manager.git
cd ai_cli_auto_manager
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

.\bin\aicm.ps1 inventory           # 깔린 AI CLI 목록 (아무것도 바꾸지 않음)
.\bin\aicm.ps1 status              # 예약 상태, 마지막 실행, 폴더별 용량과 지울 수 있는 양
.\bin\aicm.ps1 clean -DryRun       # 지울 대상만 미리 보기
.\bin\aicm.ps1 schedule install    # 매일 05:00 업데이트, 매주 월요일 12:00 목록·12:30 정리
```

### macOS · Linux

```bash
git clone https://github.com/wilgon456/ai_cli_auto_manager.git
cd ai_cli_auto_manager

./bin/aicm inventory
./bin/aicm status
./bin/aicm clean --dry-run
./bin/aicm schedule install
```

## 명령

| 명령 | 하는 일 |
| --- | --- |
| `aicm inventory` | 깔린 AI CLI 목록을 만듭니다. `--offline`(`-Offline`)이면 최신 버전 조회를 건너뜁니다 |
| `aicm update` | 깔린 AI CLI를 올립니다. `--dry-run`, `--targets codex,claude`, `--install-missing`, `--min-release-age-days N` |
| `aicm clean` | 오래된 찌꺼기를 지웁니다. `--dry-run`, `--rules codex-sessions,os-temp` |
| `aicm status` | 예약 상태, 마지막 실행 결과, 마지막 목록, 규칙별 용량과 지울 수 있는 양을 보여 줍니다 |
| `aicm doctor` | 예약이 사라졌거나 실행이 밀렸거나 실패했으면 문제를 적고 종료 코드 1을 냅니다 |
| `aicm schedule install` | 업데이트·목록·정리 예약을 등록합니다. 다시 실행하면 같은 작업을 덮어씁니다 |
| `aicm schedule remove` | 등록한 예약을 지웁니다 |
| `aicm version` | 버전을 출력합니다 |

Windows에서는 `.\bin\aicm.ps1 <명령>`을 쓰고, 옵션은 `-DryRun`, `-Targets`, `-Rules`처럼 PowerShell 방식으로 줍니다.

## 목록

어떤 CLI를 찾을지는 [`rules/ai-clis.conf`](rules/ai-clis.conf) 카탈로그에 있습니다. Claude Code, Codex, OpenCode, Grok Build, Kimi Code, Antigravity, Gemini CLI, Qwen Code, GitHub Copilot CLI, Amp, Augment Auggie, Crush, Continue, Cursor Agent, Goose, Factory Droid, Aider, OpenCode Desktop(Windows)이 들어 있습니다.

```text
CLI                  via         version        latest         state     daily update
Claude Code          npm         2.1.288        2.1.291        held      yes
OpenAI Codex         standalone  0.157.1        0.160.1        behind    no: the update refreshes the npm copy, not the one on PATH
                     npm copy 0.160.1 is also installed, but PATH runs C:\...\OpenAI\Codex\bin\codex.exe
Grok Build           standalone  1.0.46         1.0.46         current   yes
Cursor Agent         standalone  2026.09.18                    installed yes
```

`state`가 `held`이면 더 새 버전이 나왔지만 아직 3일 대기 중이라는 뜻입니다. `daily update` 칸이 `no`이면 매일 업데이트가 그 CLI에 닿지 않는다는 뜻이고, 이유를 함께 적습니다. 위 Codex처럼 터미널이 실행하는 사본과 업데이트가 올리는 사본이 다르면 여기서 드러나고, 처음 발견될 때 해결 방법과 함께 알림이 뜹니다.
결과는 `~/.ai-cli-auto-manager/inventory.md`(사람이 읽는 표)와 `state/inventory.json`에 남습니다. 카탈로그에 없는 전역 npm 패키지는 표 아래에 따로 적습니다.

카탈로그에 CLI를 더하려면 `~/.ai-cli-auto-manager/ai-clis.local.conf`에 같은 형식으로 적습니다. `id`가 같으면 기본 줄을 대신합니다.

```text
# id      | command | name      | npm            | brew | winget | self_update | note
my-agent  | myagent | My Agent  | @me/my-agent   |      |        |             |
```

## 업데이트

기본 대상은 `all`, 곧 카탈로그에 있으면서 이 컴퓨터에 깔린 CLI 전부입니다. 깔리지 않은 CLI는 건너뜁니다.

| 대상 | 업데이트 방법 |
| --- | --- |
| Claude Code, Codex, OpenCode, Grok Build, Kimi Code, Antigravity | 도구마다 따로 만든 경로(Homebrew·npm·자체 업데이트 명령·xAI 설치 스크립트). 터미널이 실행하는 사본을 기준으로 고릅니다 |
| 나머지 카탈로그 CLI | 터미널이 실행하는 사본을 깐 방식 그대로: npm이면 npm, Homebrew면 Homebrew, winget이면 winget, 단독 설치면 카탈로그의 자체 업데이트 명령 |

`--targets codex,claude`(`-Targets`)로 고를 수 있고, `gpt`는 `codex`와 같은 대상입니다.
새 CLI는 `--install-missing`(`-InstallMissing`)과 함께 그 id를 직접 적었을 때만 설치합니다. `all`로는 아무것도 새로 깔지 않습니다.

### 안전하게 올리기 (npm으로 깐 CLI)

공식 CLI도 악성 버전이 올라온 적이 있습니다. Amazon Q 확장 1.84.0(2025-07)은 파일을 지우라는 명령이 심긴 채 정식 배포됐고, Cline CLI 2.3.0(2026-02)은 도난당한 배포 열쇠로 올라와 설치 때 다른 프로그램을 몰래 깔았습니다. 둘 다 몇 시간에서 이틀 사이에 내려갔습니다. 그래서 npm으로 깐 CLI는 네 단계를 거쳐 올립니다.

1. **3일 묵히기**: 나온 지 3일이 지난 버전 중 가장 새것만 깝니다.
2. **이상 징후 비교**: 지금 깔린 버전과 비교해, 빌드 출처 증명(provenance)이 사라졌거나 설치 때 실행되는 스크립트(`preinstall`·`install`·`postinstall`)가 새로 생기거나 바뀌었으면 설치하지 않고 알립니다. Cline 2.3.0은 두 가지에 다 걸립니다.
3. **임시 폴더에서 서명 검사**: 스크립트를 실행하지 않고(`--ignore-scripts`) 임시 폴더에 먼저 받아 `npm audit signatures`로 레지스트리 서명을 확인합니다(이 검사는 전역 설치에는 쓸 수 없어서 이렇게 합니다).
4. 셋을 다 통과하면 그 버전을 전역으로 설치합니다. 이미 그 버전이면 다시 설치하지 않습니다.

| 환경 변수 | 뜻 |
| --- | --- |
| `AICM_MIN_RELEASE_AGE_DAYS` | 묵힐 날 수(기본 3, `0`이면 바로 최신). Windows는 `-MinReleaseAgeDays`, macOS·Linux는 `--min-release-age-days`도 됩니다 |
| `AICM_VERIFY_SIGNATURES` | `0`이면 3단계 서명 검사를 건너뜁니다 |
| `AICM_ALLOW` | 직접 확인한 뒤 통과시킬 버전 목록. 예: `AICM_ALLOW=cline@3.1.0` |

보안 수정도 업데이트로 오기 때문에 너무 길게 묵히면 손해입니다. 3일은 지금까지의 사고를 피하면서 수정은 빨리 받는 정도입니다.

### 업데이트 뒤에 할 일 (훅)

CLI를 새로 깔아도 이미 떠 있는 데몬이 옛 실행 파일을 붙잡고 있는 경우가 있습니다. 그럴 때는 훅 파일을 두면 업데이트가 끝날 때마다 실행됩니다. 훅이 실패해도 업데이트는 성공으로 남습니다.

| OS | 훅 파일 |
| --- | --- |
| Windows | `%USERPROFILE%\.ai-cli-auto-manager\hooks\post-update.ps1` |
| macOS · Linux | `~/.ai-cli-auto-manager/hooks/post-update.sh` (실행 권한 필요) |

```powershell
# 예: Paseo 데몬이 새 CLI를 다시 읽게 하기
paseo reload
```

## 정리

기본 규칙은 [`rules/clean-rules.conf`](rules/clean-rules.conf) 한 파일에 있고, Windows와 macOS·Linux가 같은 파일을 읽습니다. 기준은 처음 만든 날이 아니라 마지막으로 쓴 날이라서, 지금 이어서 쓰는 긴 대화는 지워지지 않습니다.

| 규칙 | 대상 | 기준 | 기본 |
| --- | --- | --- | --- |
| `codex-sessions` | Codex 대화 기록. 파일을 직접 지우지 않고 Codex 공식 명령 `codex delete`로 지움 | 30일 | 켬 |
| `gemini-tmp`, `qwen-tmp`, `grok-sessions`, `copilot-sessions` | 각 CLI의 대화·체크포인트 | 30일 | 켬 |
| `claude-transcripts` | Claude Code 대화 기록. Claude가 스스로 지우므로(`cleanupPeriodDays`, 기본 30일) 꺼 둠. 켜면 지우기 전에 아카이브 | 아카이브 22일, 삭제 +60일 | 끔 |
| `codex-images` | Codex가 만든 그림(켜면 아카이브 후 삭제) | 아카이브 30일, 삭제 +60일 | 끔 |
| `codex-tmp` | Codex 임시 파일 | 7일 | 켬 |
| `codex-trace-db` | Codex 추적 로그 DB(`logs_*.sqlite`, 끄는 설정이 없어 계속 커짐) | 30일 또는 200MB 초과 | 켬 |
| `claude-file-history`, `claude-debug` | Claude Code 되돌리기 백업, 디버그 로그 | 30일, 14일 | 켬 |
| `claude-temp` | Claude Code 세션 임시 파일(Windows `%TEMP%\claude`). Claude가 대부분 하루 안에 스스로 비움 | 1일 | 켬 |
| `grok-downloads`, `kimi-logs` | 설치 파일 내려받기, 로그 | 14일, 30일 | 켬 |
| `npm-cache`, `pip-cache` | 패키지 내려받기 캐시(필요하면 다시 받음) | 60일, 30일 | 켬 |
| `uv-cache` | `uv cache prune`으로 uv가 직접 정리 | - | 켬 |
| `os-temp` | Windows 사용자 임시 폴더 | 7일 | 켬 |
| `playwright-browsers` | Playwright 브라우저 옛 빌드(이름별 최신 2개만 남김) | - | 끔 |

**Codex는 파일을 직접 지우면 안 됩니다.** Codex는 대화를 파일과 자체 DB에 함께 저장해서, 파일만 지우면 DB에 열리지 않는 대화가 남습니다(1.x와 2.0~2.1이 그랬습니다). 그래서 Codex 기록은 공식 명령만 씁니다. 이미 파일이 사라진 대화도 같은 기준으로 `codex delete`해서 DB에서 지웁니다. 이 확인에는 Codex DB를 읽기 전용으로 여는 Python(Windows) 또는 sqlite3(macOS)가 필요하고, 없으면 그 단계만 건너뜁니다.

### 지우기 전에 아카이브하기 (선택)

`archive` 규칙은 날짜가 지난 파일을 바로 지우지 않고 `~/.ai-cli-auto-manager/archive/<규칙>/<날짜>/` 아래로 원래 폴더 구조 그대로 옮기고, `limit`일이 지나면 그 아카이브를 지웁니다. 규칙을 다시 꺼도 오래된 아카이브는 계속 지워지므로 잔재가 남지 않습니다. 되살리려면 파일을 원래 자리로 옮기면 됩니다. Codex도 `limit`을 0보다 크게 주면 `codex archive` 후 `limit`일 뒤 `codex delete`로 바뀌고, `codex unarchive <id>`로 되살립니다.

아카이브는 파일을 옮길 뿐이라 그 단계에서는 용량이 줄지 않습니다. 실제로 비워지는 건 아카이브를 지울 때입니다. 자체 정리 기능이 있는 CLI(Claude Code `cleanupPeriodDays`, Gemini CLI `sessionRetention`, Qwen Code `cleanupPeriodDays`)는 그 설정값을 읽어, CLI가 먼저 지워 버리지 않도록 일주일 앞서 아카이브합니다.

### 지우지 않는 것

- 정해 둔 날짜보다 새로운 파일, 그리고 지금 다른 프로그램이 열고 있는 파일(건너뛰고 로그에 "in use"로 남깁니다).
- 심볼릭 링크와 정션 안쪽. 링크를 만나면 따라 들어가지 않으므로 링크가 가리키는 원본은 안전합니다.
- `MEMORY.md`, `CLAUDE.md`, `AGENTS.md`, `GEMINI.md`, `auth.json`, `.credentials.json`, `settings.json`, `config.toml` 같은 메모리·인증·설정 파일, `*.env`, 그리고 `memory`라는 이름의 폴더 안 모든 파일.
- 홈 폴더와 임시 폴더 바깥. 규칙에 바깥 경로를 적으면 그 규칙은 거부되고 알림이 뜹니다. 홈 폴더 자체를 통째로 지정해도 거부합니다.

### 규칙 바꾸기

`~/.ai-cli-auto-manager/clean-rules.local.conf`(Windows는 `%USERPROFILE%\.ai-cli-auto-manager\clean-rules.local.conf`)에 같은 형식으로 적습니다. 기본 규칙과 `id`가 같은 줄은 그 규칙을 대신하고, 새 `id`는 규칙을 하나 더합니다.

```text
# id                | os      | kind        | path                          | pattern   | days | limit | default | note
playwright-browsers | windows | keep-latest | {localappdata}/ms-playwright  | *         |      | 2     | on      | 옛 빌드 정리 켜기
codex-sessions      | all     | codex       | ~/.codex                      | rollout-* | 30   | 60    | on      | 30일 뒤 아카이브, 90일 뒤 삭제
claude-transcripts  | all     | archive     | ~/.claude/projects            | *.jsonl   | 30   | 60    | on      | Claude 대화도 지우기 전에 아카이브
os-temp             | windows | age         | {temp}                        | *         | 7    |       | off     | 끄기
my-notebook-cache   | all     | age         | ~/.cache/my-tool              | *.tmp     | 14   |       | on      | 내 규칙 추가
```

`kind`는 여섯 가지입니다. `age`는 날짜보다 오래된 파일을 지우고 빈 폴더를 정리합니다. `codex`는 Codex 공식 명령으로 지우거나(`limit` 0) 아카이브 후 지웁니다. `archive`는 아카이브로 옮겼다가 `limit`일 뒤 지웁니다. `cap`은 바로 아래 파일 중 날짜가 지났거나 크기(MB)를 넘은 것을 지웁니다. `keep-latest`는 `이름-숫자` 꼴 폴더에서 이름별로 최신 몇 개만 남깁니다. `command`는 도구가 제공하는 정리 명령을 실행합니다.

## 예약 실행

`aicm schedule install`이 운영체제에 맞게 등록합니다. 시각은 바꿀 수 있습니다.

| OS | 등록 위치 | 시각 바꾸기 |
| --- | --- | --- |
| Windows | 작업 스케줄러 `\AI CLI Auto Manager\` 폴더의 `Update`, `Inventory`, `Clean` | `-UpdateAt 05:00 -InventoryDay Monday -InventoryAt 12:00 -CleanDay Monday -CleanAt 12:30` |
| macOS | `~/Library/LaunchAgents/io.github.wilgon456.ai-cli-auto-manager.{update,inventory,clean}.plist` | `--update-at 05:00 --inventory-day mon --inventory-at 12:00 --clean-day mon --clean-at 12:30` |
| Linux | 사용자 crontab(`# aicm:update`, `# aicm:inventory`, `# aicm:clean` 표시가 붙은 줄만 건드림) | 위와 같음 |

Windows는 PC가 꺼져 있어 시각을 놓치면 다음에 켜질 때 실행합니다. macOS는 잠자기 중이었다면 깨어날 때 실행합니다.
필요 없는 작업은 `--no-update`, `--no-inventory`, `--no-clean`(`-NoUpdate`, `-NoInventory`, `-NoClean`)으로 뺍니다.

예약 작업은 조용히 사라질 수 있습니다. 그래서 등록할 때 어떤 작업을 등록했는지 기록해 두고, 매번 실행할 때 다른 작업이 아직 있는지 확인합니다. 없으면 바탕화면 알림을 띄웁니다. 알림을 끄려면 환경 변수 `AICM_NOTIFY=0`을 둡니다.

## 로그와 상태 파일

| 파일 | 내용 |
| --- | --- |
| `~/.ai-cli-auto-manager/logs/update-*.log`, `latest.log` | 업데이트 실행 기록 |
| `~/.ai-cli-auto-manager/logs/inventory-*.log` | 목록 실행 기록 |
| `~/.ai-cli-auto-manager/logs/clean-*.log` | 정리 실행 기록(규칙별로 지운 개수와 용량) |
| `~/.ai-cli-auto-manager/inventory.md` | 마지막 목록(사람이 읽는 표) |
| `~/.ai-cli-auto-manager/state/last-update.json`, `inventory.json`, `last-clean.json` | 마지막 실행 결과(`status`, `doctor`가 읽음) |
| `~/.ai-cli-auto-manager/state/schedule.json` | 등록한 예약 목록 |
| `~/.ai-cli-auto-manager/archive/` | 아카이브 규칙을 켰을 때 옮긴 파일(규칙별·날짜별 폴더) |

로그는 30일 지나면 지웁니다. 기간은 `LOG_RETENTION_DAYS` 환경 변수(Windows는 `-LogRetentionDays`도 됨)로 바꿉니다. 위치는 `AICM_HOME` 환경 변수로 바꿀 수 있습니다.

## 1.x(ai_cli_auto_update)에서 옮기기

- 저장소 이름이 `ai_cli_auto_update_public`에서 `ai_cli_auto_manager`로 바뀌었습니다. 옛 주소는 GitHub가 새 주소로 넘겨 줍니다.
- `bin/update_ai_clis.sh`, `bin/update_ai_clis.ps1`는 그대로 있어서 기존 자동화가 깨지지 않습니다.
- Windows에서 `aicm.ps1 schedule install`을 실행하면 옛 작업 `AI CLI Auto Update`를 새 작업으로 바꿉니다(`-KeepLegacyTask`로 남길 수 있습니다). `windows\install_scheduled_task.ps1`도 계속 동작하며, 예전처럼 업데이트 작업만 등록합니다.
- 로그 위치가 `~/.ai-cli-auto-update`에서 `~/.ai-cli-auto-manager`로 바뀌었습니다. 옛 폴더는 건드리지 않으니 필요 없으면 직접 지우면 됩니다.
- macOS에서 예전 템플릿(`com.example.ai-cli-auto-update`)을 등록해 두었다면 `aicm schedule install`이 지우는 명령을 알려 줍니다.

## 개발과 테스트

모든 테스트는 임시로 만든 가짜 홈 폴더에서 돌고, 실제 홈 폴더와 실제 예약 작업은 건드리지 않습니다. 목록·업데이트·정리 테스트는 가짜 CLI, 가짜 npm, 가짜 codex를 써서 실제 CLI를 실행하거나 올리지 않습니다.

```bash
shellcheck -x bin/aicm bin/*.sh lib/*.sh tests/*.sh
bash tests/clean_test.sh
bash tests/aicm_test.sh
bash tests/inventory_test.sh
```

```powershell
.\tests\clean_test.ps1
.\tests\aicm_test.ps1
.\tests\inventory_test.ps1
```

CI는 Ubuntu, macOS(기본 내장된 bash 3.2), Windows PowerShell 5.1과 PowerShell 7에서 같은 테스트를 돌립니다.

## 한계

- 개인 장비와 작은 팀을 위한 도구입니다. 조직 전체에 배포하려면 변경 관리 절차를 따로 두는 편이 좋습니다.
- 문제가 생긴 버전으로 자동으로 되돌리는 기능은 없습니다.
- 3일 묵히기와 서명·이상 징후 검사는 npm으로 깐 CLI에만 적용됩니다. Homebrew·winget·자체 업데이트 명령(`claude update` 등)·xAI 설치 스크립트로 올리는 CLI는 그 경로를 그대로 믿습니다.
- Grok Build는 베타이고, 계정·구독 조건이 있을 수 있습니다.

## 공식 문서

- [Kimi Code CLI](https://www.kimi.com/code/docs/en/kimi-code-cli/guides/getting-started.html)
- [OpenAI Codex CLI](https://help.openai.com/en/articles/11096431)
- [OpenCode](https://github.com/anomalyco/opencode#installation)
- [Claude Code](https://code.claude.com/docs/en/installation)
- [Grok Build](https://docs.x.ai/build/overview)

## License

MIT License. 자세한 내용은 [LICENSE](LICENSE)를 보세요.
