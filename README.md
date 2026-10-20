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
7. [보안](#보안) · [제거](#제거)
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
- 네트워크에 Nest Hub가 **한 대뿐**이면 자동으로 그 Hub를 사용합니다.
- **여러 대**이거나 Nest Hub가 아닌 스피커(Google Home, Nest Mini 등)를 쓰려면 **메뉴 막대의 Nestcast 아이콘 → 스피커** 에서 고르세요. 고르기 전까지는 재생하지 않습니다(회사·기숙사 같은 공용 네트워크에서 남의 스피커로 소리가 나가지 않도록).
- 선택한 스피커는 이름이 아니라 **고유 기기 ID** 로 기억하므로, 같은 이름의 다른 기기로 잘못 연결되지 않습니다.

## 사용 방법

### 메뉴 막대 앱
메뉴 막대의 스피커 아이콘(Nestcast)을 누르면 다음을 할 수 있습니다.

| 항목 | 설명 |
|---|---|
| **Mac 오디오 전송** 스위치 | 켜면 소리 출력이 "Nest Hub (Cast)" 로 바뀌고 스피커로 재생합니다. 끄면 전송을 멈추고 Hub 음량을 되돌리며, 소리는 원래 출력(Mac 스피커 등)으로 돌아갑니다. |
| 보라색 표시 안내 | 전송이 켜져 있는 동안 메뉴 막대 오른쪽에 보라색 점과 **"개인정보 보호 · Nestcast · 시스템 오디오 녹음"** 이 표시됩니다. Mac 소리를 스피커로 보내고 있다는 뜻이며, 소리를 저장하지 않습니다. 전송을 끄면 사라집니다. |
| **스피커** 목록 | 같은 네트워크의 Google Cast 스피커(Nest Hub, Google Home, Nest Mini 등)가 모두 표시됩니다. 누르면 바로 그 스피커로 바뀝니다. |
| 상태 | "‘거실’에서 재생 중", "다른 앱이 사용 중", "전송 꺼짐" 등 |
| 메뉴 막대에서 닫기 | 아이콘만 닫힙니다. **전송은 계속됩니다**(재생은 백그라운드 엔진이 담당). 다시 열려면 응용 프로그램 → Nestcast Menu. |

### 그 밖의 동작

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
| 스피커를 못 찾음 | Mac과 스피커가 같은 네트워크인지, **로컬 네트워크** 권한, 메뉴 막대 → 스피커에서 다시 선택 |
| 다른 스피커로 재생됨 | 메뉴 막대 → 스피커에서 원하는 스피커 선택 |
| 메뉴에 "엔진이 실행 중이 아닙니다" | 로그아웃 후 다시 로그인하거나 pkg를 다시 설치하세요. |
| 메뉴에 "스피커를 선택해 주세요" | Nest Hub가 여러 대입니다. 메뉴 → 스피커에서 하나를 고르세요. |
| 그 밖의 문제 | 로그 파일: `~/Library/Logs/nestcast.log` (Finder → 이동 → 폴더로 이동). 설치 로그: `/tmp/nestcast-install.log` |

설정 파일: `~/Library/Application Support/nestcast/`
- `hub` — 사용할 스피커의 고유 ID(1행)와 이름(2행)
- `enabled` — 전송 스위치(1/0)
- `status.json` — 엔진 상태와 스피커 목록(메뉴 막대 앱이 읽음)
- `hub_volume` — 되돌릴 Hub 원래 음량(재생 중에만 존재)

## 보안

Mac의 모든 소리를 보내는 앱이므로 다음과 같이 설계했습니다.

- **진짜 Google Cast 기기에만 전송**: 연결할 때마다 스피커가 Google이 서명한 기기 인증서를 증명해야 합니다(Cast 기기 인증 + 인증서 폐기 목록 확인). 네트워크에서 같은 이름을 흉내 낸 가짜 기기는 소리를 받을 수 없습니다.
- **암호화**: 제어 채널은 TLS, 오디오·영상 스트림은 세션마다 새로 만든 키로 AES-128 암호화됩니다.
- **열린 포트 없음**: Hub로 나가는 연결만 있고, 외부에서 접속할 수 있는 서버를 열지 않습니다. 소리는 디스크나 로그에 저장하지 않습니다.
- **권한 보호**: "시스템 오디오 녹음" 권한을 가진 실행 파일은 `/Applications` 에 root 소유로 설치되며, 런처는 root 소유가 아닌 실행 파일은 실행하지 않고 `DYLD_*` 환경 변수를 제거합니다. 두 실행 파일 모두 hardened runtime 으로 서명됩니다.
- **가상 장치는 출력 전용**: "Nest Hub (Cast)" 에는 입력이 없어서 다른 앱이 이 장치로 가는 소리를 읽을 수 없습니다.
- **공용 네트워크 보호**: 스피커를 고르지 않았고 Nest Hub가 여러 대 보이면 재생하지 않습니다.
- **메뉴 막대 앱은 권한이 없습니다**: 설정 파일만 쓰고 읽으며, 오디오 녹음·네트워크 접근은 엔진만 합니다.
- **설치 파일 확인**: Release 노트의 SHA-256 값과 `shasum -a 256 Nestcast-<버전>.pkg` 결과가 같은지 확인할 수 있습니다.
- 로그(`~/Library/Logs/nestcast.log`)에는 스피커 이름과 내부 IP가 기록됩니다(소리는 기록하지 않음).

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
| `menu/` | 메뉴 막대 앱 (Swift/AppKit) — 엔진의 리모컨 |
| `pkg/` | 설치 패키지 빌드 스크립트, 설치/제거 스크립트 |
| `tools/` | 지연 측정 도구(예약 비프음 `refbeep.swift`, 녹음 분석 `onsets.py`, 테스트 스크립트) |

## 동작 원리

```
앱들 ──▶ "Nest Hub (Cast)" 출력 장치 (무음, 지연 360 ms 보고 → 영상이 립싱크 맞춤)
  │
  └─▶ Core Audio 프로세스 탭 (시스템 오디오 캡처, 48 kHz)
         └─▶ Opus 인코딩 (10 ms 프레임) ──▶ Cast Streaming (RTP/UDP, AES)
                                              └─▶ Google Nest Hub (미러링 수신 앱)
```

- **보안**: 위 [보안](#보안) 참고.
- **안정성**: 연결 끊김·Hub 재부팅·네트워크 변경 시 자동 재연결(1→10초 백오프), mDNS로 매번 스피커를 이름으로 다시 찾음(IP가 바뀌어도 동작), 잠자기/깨어나기·coreaudiod 재시작 처리, 오디오 캡처 정지 감지 후 재구성, Hub 응답 감시(4초).
- **양보**: 접속 전에 Hub 상태를 확인해 다른 앱이 재생 중이면 시작하지 않고, 재생 중 다른 앱이 Hub를 쓰면 원래 음량으로 되돌린 뒤 물러납니다.
- **지연 최적화**: 오디오 프레임을 정시에 보내도록 타임스탬프를 맞춰 Hub가 목표 지연(300 ms)을 정확히 지키게 했습니다.

## 라이선스

- 이 저장소: **GNU GPL v3.0** (`LICENSE`).
- `driver/` 는 [BlackHole](https://github.com/ExistentialAudio/BlackHole) (GPL-3.0, © Existential Audio Inc.)을 수정한 것입니다. BlackHole 상표·이름은 사용하지 않으며 원본 고지는 `driver/LICENSE.BlackHole` 에 있습니다.
- Open Screen / Chromium 코드는 BSD 라이선스이며, 이 저장소에는 **패치만** 포함됩니다. 빌드 시 원본을 내려받습니다.
- Opus(BSD), libvpx(BSD)는 빌드 시 정적으로 링크됩니다.
