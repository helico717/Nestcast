# Nestcast

Mac의 모든 소리를 **Google Nest Hub**(Google Cast 스피커)로 실시간 재생하는 macOS 앱입니다.
Bluetooth처럼 끊기지 않고, AirCast·Music Assistant보다 훨씬 짧은 **약 0.36초** 지연으로 동작합니다.

- Chromium의 **Cast Streaming(미러링) 프로토콜**을 [Open Screen](https://chromium.googlesource.com/openscreen/) 라이브러리로 직접 구현했습니다.
- 가상 출력 장치 **"Nest Hub (Cast)"** 가 지연 시간(360 ms)을 macOS에 알려 주기 때문에, 대부분의 동영상 플레이어가 영상을 그만큼 늦춰 **입모양(립싱크)이 맞습니다**.
- 로그인하면 자동으로 시작되고, 끊기면 스스로 다시 연결합니다.

> 개인 프로젝트이며 Google, Apple, Existential Audio(BlackHole)와 관계가 없습니다.

---

## 목차
1. [요구 사항](#요구-사항)
2. [설치](#설치)
3. [처음 설정](#처음-설정)
4. [사용 방법](#사용-방법)
5. [지연 시간과 립싱크](#지연-시간과-립싱크)
6. [문제 해결](#문제-해결)
7. [제거](#제거)
8. [소스에서 빌드하기](#소스에서-빌드하기)
9. [동작 원리](#동작-원리)
10. [라이선스](#라이선스)

---

## 요구 사항

| 항목 | 조건 |
|---|---|
| Mac | Apple Silicon (M1 이상) |
| macOS | **26 (Tahoe) 이상** |
| 스피커 | Google Nest Hub (Google Home / Nest Mini 등 다른 Cast 기기도 대부분 동작) |
| 네트워크 | Mac과 스피커가 **같은 공유기(같은 네트워크)** 에 연결. Mac은 유선 연결을 권장 |

## 설치

1. [Releases](../../releases) 에서 `Nestcast-<버전>.pkg` 를 내려받습니다.
2. **pkg 파일을 더블클릭**합니다.
   - "확인되지 않은 개발자" 경고가 나오면: **시스템 설정 → 개인정보 보호 및 보안** 맨 아래의 **"그래도 열기"** 를 누르거나, Finder에서 pkg를 **우클릭 → 열기** 하세요. (Apple 개발자 인증서로 서명하지 않은 개인 프로젝트라서 나오는 경고입니다.)
3. 설치 마법사에서 **계속 → 설치** 를 누르고 Mac 암호를 입력합니다.
   - 설치 중 오디오가 약 2초 동안 끊깁니다(오디오 시스템 재시작).
4. 설치가 끝나면 Nestcast가 자동으로 시작되며, **권한 요청 창이 두 번** 뜹니다. 모두 **허용**을 눌러 주세요.
   - **"Nestcast"이(가) 이 컴퓨터의 오디오를 녹음하려고 합니다** → 허용 (Mac 소리를 가져오기 위해 필요)
   - **"Nestcast"이(가) 로컬 네트워크의 기기를 찾고 연결하려고 합니다** → 허용 (스피커에 연결하기 위해 필요)

터미널 명령어는 필요 없습니다.

## 처음 설정

### 1) 소리 출력을 "Nest Hub (Cast)" 로 선택
**시스템 설정 → 사운드 → 출력** 에서 **Nest Hub (Cast)** 를 선택합니다.
(메뉴 막대의 음량 아이콘을 눌러 선택해도 됩니다.)

- 이 장치를 선택하면 Mac 스피커는 조용해지고, 소리는 Nest Hub에서 나옵니다.
- 다시 **Mac 스피커**를 선택하면 Nestcast는 스피커 재생을 멈추고 소리는 Mac에서 나옵니다.

### 2) 재생할 스피커 고르기
기본값으로 **네트워크에서 처음 찾은 Nest Hub** 를 사용합니다.
스피커가 여러 대라면 **응용 프로그램 → "Nestcast 스피커 선택"** 을 실행해 목록에서 고르세요.
(처음 실행할 때 로컬 네트워크 권한을 한 번 더 묻습니다 → 허용)

## 사용 방법

| 하고 싶은 것 | 방법 |
|---|---|
| 음량 조절 | Mac **음량 키**(또는 메뉴 막대 음량)로 조절하면 **Nest Hub 음량**이 함께 바뀝니다. 시작할 때는 Hub의 원래 음량을 유지하고, 키를 누르는 만큼 올리고 내립니다. |
| 음소거 | Mac 음소거 키 → Nest Hub도 음소거 |
| 휴대폰에서 YouTube 등을 캐스트 | Nestcast가 **자동으로 양보**합니다(Hub를 빼앗지 않음). 캐스트가 끝나면 몇 초 안에 다시 Mac 소리를 재생합니다. |
| Mac 잠자기 / 종료 | 재생을 깔끔하게 멈추고 **Hub 음량을 원래대로 되돌립니다**. 깨어나거나 다시 로그인하면 자동으로 재개합니다. |

### Nest Hub 화면
재생하는 동안 Hub 화면에는 어두운 배경에 **날짜, 시계(오전/오후), "Mac 오디오 재생 중"** 이 작게 표시됩니다.

## 지연 시간과 립싱크

- 측정된 지연: **Mac → Nest Hub 약 0.36초** (Nest Hub가 허용하는 최소 버퍼 약 0.3초 + 캡처·전송).
- **"Nest Hub (Cast)"** 출력 장치는 이 지연(360 ms)을 macOS에 보고합니다. 다음 앱들은 영상을 그만큼 늦춰 **립싱크가 맞습니다**:
  - Safari(YouTube·Netflix 등 웹 동영상), QuickTime Player, Apple TV 앱 등 AVFoundation 기반 앱
  - Chrome / Edge, IINA, VLC (실측: IINA·Chrome 모두 남은 차이 0.1초 이내)
- 맞출 수 없는 경우(소리가 약 0.36초 늦게 들림): 게임, 화상 통화, 일부 웹 앱의 효과음 등 **실시간 소리**.

## 문제 해결

| 증상 | 확인할 것 |
|---|---|
| Hub에서 소리가 안 남 | ① 출력이 **Nest Hub (Cast)** 인지 ② **시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 녹음** 에서 Nestcast가 **켜져** 있는지 ③ **로컬 네트워크** 에서 Nestcast가 켜져 있는지 |
| 스피커를 못 찾음 | Mac과 스피커가 같은 네트워크인지, **로컬 네트워크** 권한, 스피커 이름("Nestcast 스피커 선택" 으로 다시 선택) |
| 다른 스피커로 재생됨 | "Nestcast 스피커 선택" 으로 원하는 스피커 선택 |
| 마이크 입력이 "Nest Hub (Cast)" 로 바뀜 | 마이크가 없는 Mac(예: Mac mini)에서는 macOS가 자동으로 고를 수 있습니다. 마이크를 연결했다면 **사운드 → 입력** 에서 마이크를 선택하세요. |
| 그 밖의 문제 | 로그 파일: `~/Library/Logs/nestcast.log` (Finder → 이동 → 폴더로 이동). 설치 로그: `/tmp/nestcast-install.log` |

설정 파일: `~/Library/Application Support/nestcast/`
- `hub` — 사용할 스피커 이름
- `hub_volume` — 되돌릴 Hub 원래 음량(재생 중에만 존재)

## 제거

`Nestcast-Uninstall.command` (Release의 "Nestcast 제거", 설치 후에는 `/Applications/Nestcast.app/Contents/Resources/uninstall.command`) 를 **더블클릭**하고 Mac 암호를 입력합니다.
Nestcast 앱, 자동 시작 항목, "Nest Hub (Cast)" 장치, 설정이 모두 지워지고 소리는 Mac 스피커로 돌아갑니다.

## 소스에서 빌드하기

필요: Xcode Command Line Tools, Homebrew `opus`, `libvpx`

```bash
brew install opus libvpx
scripts/build.sh          # depot_tools + Open Screen(고정 리비전) 받기, 패치, 빌드
pkg/build_pkg.sh          # dist/Nestcast-<버전>.pkg 생성
```

| 경로 | 내용 |
|---|---|
| `src/` | nestcast 본체 (C++/Objective-C++, Open Screen 트리 안에서 `//nestcast` 로 빌드) |
| `app/` | Nestcast.app 런처(권한을 소유하는 고정 실행 파일)와 Info.plist |
| `driver/` | "Nest Hub (Cast)" 가상 오디오 장치 (BlackHole 기반 HAL 플러그인) |
| `patches/` | Open Screen 패치, Chromium `//build` 패치(Xcode 없이 Command Line Tools만으로 빌드) |
| `pkg/` | 설치 패키지 빌드 스크립트, 설치/제거 스크립트, 스피커 선택 앱 |
| `tools/` | 지연 측정 도구(예약 비프음 `refbeep.swift`, 녹음 분석 `onsets.py`, 테스트 스크립트) |

## 동작 원리

```
앱들 ──▶ "Nest Hub (Cast)" 출력 장치 (무음, 지연 360 ms 보고 → 영상이 립싱크 맞춤)
  │
  └─▶ Core Audio 프로세스 탭 (시스템 오디오 캡처, 48 kHz)
         └─▶ Opus 인코딩 (10 ms 프레임) ──▶ Cast Streaming (RTP/UDP, AES)
                                              └─▶ Google Nest Hub (미러링 수신 앱)
```

- **안정성**: 연결 끊김·Hub 재부팅·네트워크 변경 시 자동 재연결(1→10초 백오프), mDNS로 매번 스피커를 이름으로 다시 찾음(IP가 바뀌어도 동작), 잠자기/깨어나기·coreaudiod 재시작 처리, 오디오 캡처 정지 감지 후 재구성, Hub 응답 감시(4초).
- **양보**: 접속 전에 Hub 상태를 확인해 다른 앱이 재생 중이면 시작하지 않고, 재생 중 다른 앱이 Hub를 쓰면 원래 음량으로 되돌린 뒤 물러납니다.
- **지연 최적화**: 오디오 프레임을 정시에 보내도록 타임스탬프를 맞춰 Hub가 목표 지연(300 ms)을 정확히 지키게 했습니다.

## 라이선스

- 이 저장소: **GNU GPL v3.0** (`LICENSE`).
- `driver/` 는 [BlackHole](https://github.com/ExistentialAudio/BlackHole) (GPL-3.0, © Existential Audio Inc.)을 수정한 것입니다. BlackHole 상표·이름은 사용하지 않으며 원본 고지는 `driver/LICENSE.BlackHole` 에 있습니다.
- Open Screen / Chromium 코드는 BSD 라이선스이며, 이 저장소에는 **패치만** 포함됩니다. 빌드 시 원본을 내려받습니다.
- Opus(BSD), libvpx(BSD)는 빌드 시 정적으로 링크됩니다.
