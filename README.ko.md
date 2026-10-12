<div align="center">

[![🇬🇧 English](https://img.shields.io/badge/🇬🇧-English-134538?style=flat-square)](README.md)
[![🇰🇷 한국어](https://img.shields.io/badge/🇰🇷-한국어-E985A2?style=flat-square)](README.ko.md)

<img src="Resources/appicon-1024.png" width="120" alt="CmdMD 아이콘" />

# CmdMD

**macOS용 리뷰 우선(review‑first) 마크다운 에디터이자 Obsidian 볼트 라우터.**

노트를 열고, 아름답게 읽고, 알맞은 볼트 폴더로 보낸다 — 각각 단축키 하나.
네이티브 Swift / SwiftUI · macOS 14+ · CMDS 브랜딩, 라이트 & 다크.

**[cmdmd.cmdspace.work](https://cmdmd.cmdspace.work)** · [다운로드](https://github.com/johnfkoo951/CmdMD/releases/latest) · [웹사이트 소스](https://github.com/johnfkoo951/CmdMD-web)

<br/>

<img src="docs/images/hero.png" width="900" alt="CMDS 라이트·다크 테마의 CmdMD" />

<br/>
<br/>

![CmdMD 데모](docs/images/demo.gif)

</div>

---

## 왜 CmdMD인가

대부분의 마크다운 앱은 에디터로 열립니다. CmdMD는 **렌더된 프리뷰**로 열립니다 — 읽기가
먼저고, 편집은 단축키 하나 거리입니다 (글을 쓰는 게 아니라, PR을 리뷰하듯이).
**Obsidian 방식 마크다운**을 그대로 이해하고 **라우터**로도 동작합니다: 노트를 포착하거나 열어,
템플릿과 규칙으로 알맞은 볼트 폴더에 보냅니다.

## 스크린샷

| 프리뷰 — 라이트 | 프리뷰 — 다크 |
|---|---|
| <img src="docs/images/cmds-light-preview.png" alt="라이트 프리뷰" /> | <img src="docs/images/cmds-dark-preview.png" alt="다크 프리뷰" /> |

| 분할(소스 + 프리뷰) — 라이트 | 분할 — 다크 |
|---|---|
| <img src="docs/images/cmds-light-split.png" alt="라이트 분할" /> | <img src="docs/images/cmds-dark-split.png" alt="다크 분할" /> |

> 액센트는 시스템 외형을 따라갑니다 — 라이트는 **CMDS 그린**, 다크는 **CMDS 핑크**.

## 기능

- **리뷰 우선** — 렌더된 프리뷰로 시작하고, `⌘1`/`⌘2`/`⌘3` 로 소스 / 분할 / 프리뷰를 전환.
- **완전한 마크다운** — GitHub‑Flavored(테이블, 태스크 리스트, 취소선)에 더해 Obsidian
  확장 문법: `[[wiki‑links]]`, `#tags`, `> [!callouts]`, `==highlights==`.
- **Mermaid 11 + KaTeX** — 다이어그램과 수식(`$…$`, `$$…$$`, `\[…\]`, `\(…\)`), `\ce{}` 화학식까지.
- **7가지 프리뷰 테마** — CMDS, GitHub, Obsidian, Minimal, Sepia, Newsprint, Dark Pro — 그리고
  라이트 / 다크를 따라가는 구문 강조 소스 테마.
- **Obsidian 볼트 라우터** — 설치된 볼트를 자동 감지해 어떤 폴더로든 노트를 보냅니다.
  **템플릿**, **라우팅 규칙**(태그 / 파일명 / 내용으로 자동 라우팅), 볼트별 인박스 지원.
- **옴니서치** (`⇧⌘O`) — 퍼지 파일명 + 디바운스 내용 검색.
- **커맨드 팔레트** (`⌘P`)와 **전부 재지정 가능한 단축키** (Settings → Shortcuts).
- **탭**, 분할 **스크롤 동기화**, **드래프트**, **퀵 캡처**(메뉴바 + 전역 단축키),
  frontmatter **인스펙터**, 슬러그가 정확한 **목차(TOC)**, **HTML / PDF 내보내기**.
- **통합 줌** — `⌘=` / `⌘−` / `⌘0` 또는 트랙패드 핀치로 에디터와 프리뷰를 함께 확대·축소.
- **선택 즉시 복사** — 마우스 선택을 마치면 곧바로 클립보드에 들어가고, 연달아 선택해도
  각각 클립보드 히스토리 관리자에 남습니다 (끌 수 있음).
- **진단 로그** — 주요 동작을 Console.app과 일별 파일에 기록 (7일 보관).

## 설치

### 다운로드 (권장)

[**Releases**](../../releases) 페이지에서 최신 빌드를 받으세요:

- **`CmdMD-<version>.dmg`** — 열어서 `CmdMD.app`을 **Applications** 단축아이콘에 드래그.
- **`CmdMD-macos.zip`** — 압축을 풀고 `CmdMD.app`을 `/Applications`로 이동 (마운트 없이 같은 결과).

앱은 **ad‑hoc 서명**(공증 없음)이라 첫 실행을 Gatekeeper가 막습니다. macOS 15 이상에서는
한 번 열어 본 뒤 **시스템 설정 → 개인정보 보호 및 보안 → 그래도 열기**를 누르세요
(macOS 14에서는 우클릭 → **열기**도 됩니다). 또는 격리 플래그를 해제합니다:

```bash
xattr -dr com.apple.quarantine /Applications/CmdMD.app
```

### 소스에서 빌드

macOS 14+ 에서 Xcode 15+ (Swift 5.9+) 가 필요합니다.

```bash
git clone https://github.com/johnfkoo951/CmdMD.git
cd CmdMD

swift build                         # 디버그 빌드
swift run                           # 실행
swift test                          # 테스트 실행

# 설치된 CmdMD와 함께 띄운다면? 개발 빌드의 설정·세션·로그를 분리:
CMDMD_DATA_DIR="$HOME/Library/Application Support/CmdMD-dev" swift run

swift build -c release              # 릴리스 바이너리
bash scripts/package_app.sh         # → dist/CmdMD.app + dist/CmdMD-macos.zip
```

## 키보드 단축키

기본값은 익숙한 Obsidian 바인딩을 따르고, 모든 동작은 **Settings → Shortcuts**에서 재지정할 수 있습니다.

| 동작 | 단축키 | | 동작 | 단축키 |
|---|---|---|---|---|
| 커맨드 팔레트 | `⌘P` | | 볼트로 보내기 | `⇧⌘T` |
| 옴니서치 | `⇧⌘O` | | 자동 라우팅 전송 | `⌃⌘T` |
| 소스 / 분할 / 프리뷰 | `⌘1` `⌘2` `⌘3` | | 퀵 캡처 | `⇧⌘M` |
| 왼쪽 사이드바 토글 | `⌃⌘←` | | 새 드래프트 | `⌘N` |
| 오른쪽 사이드바 토글 | `⌃⌘→` | | 저장 / 다른 이름으로 저장 | `⌘S` `⇧⌘S` |
| 파일 경로 복사 | `⌥⌘C` | | 문서에서 찾기 | `⌘F` |
| 확대 / 축소 | `⌘=` `⌘−` (또는 핀치) | | 실제 크기 | `⌘0` |
| Obsidian에서 열기 | `⌥⌘J` | | | |

## 볼트로 보내기

CmdMD는 Obsidian 볼트에 연결됩니다 (Obsidian 자체 레지스트리를 읽어 원클릭 연결을 제안합니다).
**보내기**(`⇧⌘T`)를 하면 노트가 목적지 폴더로 복사되거나 이동됩니다:

- **전역 기본 전송 폴더**(Settings → Vaults)가 모든 곳에 적용되지만…
- …볼트에 자체 **인박스**가 지정되어 있으면 그쪽이 우선합니다.
- **라우팅 규칙**은 태그, 파일명, frontmatter, 내용으로 자동 라우팅합니다 (`⌃⌘T`).
- **템플릿**은 파일명을 바꾸고 본문을 감쌉니다 (`{{title}}`, `{{date}}`, `{{content}}`, …).

## 기술 스택

Swift / SwiftUI · [swift‑markdown](https://github.com/apple/swift-markdown) ·
[Highlightr](https://github.com/raspu/Highlightr) · [Yams](https://github.com/jpsim/Yams) ·
Mermaid & KaTeX는 CDN으로 로드. 앱 데이터는 `~/Library/Application Support/CmdMD/`에 저장됩니다.
`cmdmd://open?note=<name>` URL 스킴은 열린 폴더와 볼트에서 노트를 찾아 엽니다.

## 라이선스

[MIT](LICENSE) © 2026 CMDSPACE · 구요한

제작: **Yohan Koo (CMDSPACE)** · [cmdspace.work](https://cmdspace.work)
