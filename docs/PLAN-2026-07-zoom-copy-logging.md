# CmdMD 개선 기획 — 줌 · 선택 복사 · 로깅 (2026-07)

> 상태: 승인 후 구현 진행 · 대상 버전: 1.5.0
> 범위: 기능 검토 결과를 바탕으로 한 3개 신규 기능 + 단축키 정비

## 1. 현재 앱 상태 점검 (2026-07-02, v1.4.8 기준)

### 잘 되어 있는 것
- **단축키 체계**: `AppShortcut` enum + `KeyBinding` 모델로 17개 액션이 리맵 가능. Settings → Keyboard 패널에서 편집 가능. Obsidian 메인 볼트 핫키와 미러링됨.
- **설정 복원력**: `decodeIfPresent` 기반 resilient 디코딩 — 필드 추가/삭제에도 기존 설정 유지.
- **에디터**: 실 NSRulerView 거터, undo-safe 인플레이스 하이라이팅, 스마트 리스트 연속, `[[`/`#` 자동완성, 스크롤 싱크.
- **프리뷰**: WKWebView + 태스크 토글 JS 브리지, 디바운스 렌더 + 스크롤 보존.

### 부족한 것 (이번 범위)
| 항목 | 현황 | 문제 |
|---|---|---|
| 줌 | 없음. 글꼴 크기는 Settings 슬라이더(10–24)뿐 | 리뷰 중 즉석 확대/축소 불가. 핀치 제스처 무반응 |
| 선택 복사 | 수동 ⌘C만 | 빠르게 여러 구절을 클립보드 히스토리에 쌓는 워크플로 미지원 |
| 로깅 | print/os.log 호출 0건 | 문제 재현·진단 불가. 1.4.6 크래시 같은 사고 때 근거 부재 |
| 단축키 갭 | ⌘=/⌘-/⌘0 미배정 | macOS 표준 줌 키가 죽어 있음 |

## 2. 기능 설계

### 2.1 통합 줌 (Unified Zoom)
- **모델**: `AppSettings.zoomLevel: Double = 1.0` (0.5–3.0 클램프). 폰트 크기 설정과 **별도의 배율** — 슬라이더 범위(10–24)를 오염시키지 않음. resilient 디코딩 준수.
- **적용**:
  - 에디터: `editorFont()`가 `fontSize × zoomLevel`로 계산. 기존 `themeChange` 경로(pointSize 비교)가 하이라이터 재적용을 자동 처리.
  - 프리뷰: `WKWebView.pageZoom = zoomLevel`. 재렌더 불필요, `loadHTMLString` 후에도 유지됨.
- **입력**:
  - 메뉴: View → Zoom In(⌘=) / Zoom Out(⌘−) / Actual Size(⌘0). `AppShortcut` 케이스로 추가 → 자동으로 Keyboard 설정 패널에 노출, 리맵 가능.
  - 핀치: 에디터는 `CmdMDTextView.magnify(with:)` 오버라이드, 프리뷰는 `NSMagnificationGestureRecognizer`(WKWebView 자체 magnification은 사용 안 함 — 줌 상태가 앱 배율과 분리되는 것을 방지).
- **지속성**: 줌 변경은 0.5s 디바운스로 settings.json 저장 (핀치 틱마다 7개 JSON 재기록 방지).
- **표시**: 상태바에 100% 아님일 때만 배율 배지(클릭 시 리셋).

### 2.2 드래그 선택 → 즉시 클립보드 복사
- **동작**: 마우스로 텍스트를 드래그(또는 더블/트리플 클릭)해 선택이 **끝나는 순간(mouse-up)** 선택 텍스트를 NSPasteboard에 즉시 기록. 디바운스/딜레이 없음 — 연속 선택 시 각 선택이 개별 pasteboard change로 기록되어 클립보드 히스토리 매니저(Raycast/Paste 등)가 각각 캡처 가능.
- **구현**: `CmdMDTextView.mouseDown(with:)` 오버라이드. NSTextView의 mouseDown은 드래그 추적 루프를 내장하므로 `super.mouseDown()` 리턴 = mouse-up 시점. 리턴 후 선택이 (a) 비어 있지 않고 (b) 클릭 전과 달라졌을 때만 복사.
  - 드래그 중(mid-drag)에는 절대 복사하지 않음 — pasteboard 오염 방지.
  - 키보드 선택(⇧+화살표)은 대상 아님 (의도적).
  - 기존 선택 영역을 드래그해 DnD를 시작하는 경우 선택 불변 → 복사 안 함.
- **설정**: `copySelectionOnDrag: Bool = true` (Settings → Editor → Editing 토글).
- **피드백**: 토스트 없음(연속 선택 시 스팸). 로그로만 기록.

### 2.3 로깅 (LogService)
- **이중 싱크**: `os.Logger`(Console.app, subsystem `work.cmdspace.CmdMD`) + 파일 로그.
- **파일**: `~/Library/Application Support/CmdMD/logs/cmdmd-YYYY-MM-DD.log`, 시작 시 7일 초과분 삭제. 직렬 큐로 append.
- **카테고리**: app / file / send / editor / preview / zoom / clipboard / error.
- **계측 지점**: 앱 시작·종료, 문서 열기/저장/리로드, Send·자동 라우팅(규칙 매칭 결과 포함), 세션 저장/복원, 내보내기, 줌 변경, 선택 복사, `showError` 전체.
- **설정**: `fileLoggingEnabled: Bool = true` 토글 + "Open Logs Folder" 버튼 (Settings → General).

### 2.4 단축키 정비
- 신규: ⌘= Zoom In · ⌘− Zoom Out · ⌘0 Actual Size (리맵 가능).
- 충돌 검사 결과: 기존 표에서 ⌘=/⌘−/⌘0 미사용 확인. ⌘P(팔레트)가 시스템 Print를 가리는 것은 인쇄 기능이 없으므로 유지.
- Command Palette에 Zoom 3종 커맨드 등록.

## 3. 수용 기준 (Acceptance)
1. ⌘= 연타 → 에디터 글자와 프리뷰가 같은 배율로 커지고, 앱 재시작 후에도 유지.
2. 트랙패드 핀치 → 에디터/프리뷰 각각 부드럽게 확대·축소, ⌘0으로 즉시 100%.
3. 드래그 선택 3회 연속(1초 안에) → pasteboard changeCount 3회 증가, 마지막 선택 텍스트가 ⌘V로 붙음.
4. `logs/cmdmd-<오늘>.log`에 열기/저장/Send/줌/복사 이벤트가 타임스탬프와 함께 기록.
5. `swift test` 전체 통과 (기존 52 + 신규: 줌 클램프, 설정 디코딩, 로그 포맷/보존).
6. 기존 설정 파일(settings.json)을 가진 사용자가 업데이트해도 설정 초기화 없음.

## 4. 비범위 (이번에 안 함)
- 프리뷰 `allowsMagnification` 네이티브 핀치(앱 배율과 이원화되므로 배제).
- 키보드 선택 자동 복사, 복사 시 서식 유지(RTF) — 플레인 텍스트만.
- 로그 뷰어 UI — 파일/Console.app으로 충분.

---

## 5. Apple-Native 폴리시 패스 (2026-07-26 추가, 같은 1.5.0 범위)

8차원 HIG 리뷰(93건) 후 high/medium 중심으로 구현. 원칙: **계산을 지우지 말고 시점을 옮긴다** (디바운스/저장 플래그/스킵) — 타이핑 핫패스 무회귀.

### 성능 (타이핑 핫패스)
- 키스트로크당 O(n) 전문서 작업 제거: 단어/글자 수·Inspector TOC는 250–300ms 디바운스(`.task(id:)`), dirty는 `currentDocument` setter에서 저장 플래그 1회 갱신 → 탭바/상태바는 플래그만 읽음.
- 캐럿 이동마다 전체 NSTextView 재그리기 제거(현재 줄 강조 조건부만), LineIndex 버퍼 재사용, 300k+ 문서는 타이핑 하이라이트 패스 전체 스킵.
- Settings 슬라이더 틱당 JSON 7종 동기 저장 → `saveUserDataDebounced()`(0.5s). 핀치 줌 중 전체 재하이라이트 → 120ms 디바운스.
- 수학 없는 노트에 KaTeX 4종 리소스+전신 DOM 스캔 로드 제거(`$` 게이팅).

### 프리뷰 (review-first 핵심 면)
- WKWebView 투명화(`drawsBackground=false`) + 페인 배경을 테마 색으로 → 다크모드 리로드 흰 플래시 제거. `color-scheme: light dark` 선언.
- 탭 전환 시 문서별 스크롤 위치 기억/복원, 복원은 DOMContentLoaded 주입(페인트 전).
- 코드가 Courier로 나오던 테마 수정(전 테마 `ui-monospace` 스택), 체크박스 `accent-color` 네이티브 틴트.

### 크롬/메뉴
- 타이틀바: 문서 제목 + `.navigationDocument` 프록시 아이콘(드래그·⌘클릭 경로). 닫기 버튼 edited 도트(`isDocumentEdited`).
- 탭바 Safari식 재작업: leading 16pt 슬롯(dirty 도트↔호버 ✕ 스왑), 언더라인 제거→시스템 선택 필, 비활성 창 디밍(`controlActiveState`), 활성 탭 자동 스크롤, 최대폭 180, 끝으로 드래그 드롭존, 핀 프리픽스 클램프.
- 메뉴 정비: ⌘W가 dirty 확인 경유(무확인 폐기 버그), 탭 없으면 Close Window, View 모드 체크마크(Toggle), Actual Size 우선 줌 순서, Show/Hide 동사, `…` 통일, 종료 얼럿 HIG 배치(Save All / Cancel / Discard Changes-destructive), 시스템 윈도우 탭 비활성, Dock 최근 문서(`noteNewRecentDocumentURL`), Help에 실 도움말 링크.
- ⌘P/⇧⌘O를 시트→**탑 앵커 플로팅 오버레이**(Spotlight 식, 스크림+snappy, Reduce Motion 존중)로 교체.

### 사이드바/에디터/시트
- 파일트리: URL 기반 안정 identity + `List(selection:)` 네이티브 선택/키보드 탐색, 선택=현재 탭 교체(핀·dirty 탭은 보호되어 새 탭). 컨텍스트 메뉴에 Rename/Duplicate/Copy Path, Trash는 열린 탭 정리+토스트.
- 에디터: 인셋 20×16, typingAttributes(빈/oversized 문서 타이핑 색 플래시 제거), 리치 페이스트 차단(`pasteAsPlainText`), **볼드가 에디터 폰트 유지**, 거터 폰트 줌 연동+현재 줄 번호 강조, 점프 시 뷰포트 중앙 정렬, 자동완성 팝업 8행 캡+실측 높이+스크롤 추적, 문서 로드 시 Ln/Col 오보고 수정(인덱스 선빌드).
- 시트: Send 시트 HIG 푸터(Cancel ⎋+Send ↩, 진행 표시), Quick Capture prominent 기본 버튼, 볼트 해제 2곳 `confirmationDialog`, Inspector 세그먼트 탭+머티리얼 복원.

### 개발 격리
- `CMDMD_DATA_DIR` env로 데이터·로그 전체 격리(AppState + LogService) — 설치본과 dev 빌드 동시 실행 안전.

검증: `swift test` 67/67, 격리 인스턴스 스크린샷으로 스플릿/팔레트/ESC 해제 실사 확인.
