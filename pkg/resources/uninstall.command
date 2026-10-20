#!/bin/zsh
# Nestcast 제거 (Uninstall). 더블클릭하면 터미널이 열리고, 관리자 암호를 한 번 묻습니다.
# Removes Nestcast, its LaunchAgent, the "Nest Hub (Cast)" audio device and its
# settings, and restores the Mac's built-in speakers.
echo "Nestcast를 제거합니다. 관리자 암호를 입력해 주세요."
launchctl bootout "gui/$(id -u)/local.nestcast.ui" 2>/dev/null
launchctl bootout "gui/$(id -u)/local.nestcast.menu" 2>/dev/null
launchctl bootout "gui/$(id -u)/local.nestcast" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/local.nestcast.plist" "$HOME/Library/LaunchAgents/local.nestcast.menu.plist" \
  "$HOME/Library/LaunchAgents/local.nestcast.ui.plist"
sudo rm -rf "/Applications/Nestcast.app" "/Applications/Nestcast Menu.app" \
  "/Applications/Nestcast 스피커 선택.app" \
  "/Library/Audio/Plug-Ins/HAL/NestHubCast.driver"
sudo pkgutil --forget local.nestcast.pkg >/dev/null 2>&1
sudo killall -9 coreaudiod 2>/dev/null
rm -rf "$HOME/Library/Application Support/nestcast"
echo "제거가 끝났습니다. 소리는 Mac 스피커로 돌아갑니다."
echo "(시스템 설정 > 개인정보 보호 및 보안의 Nestcast 권한 항목은 그대로 두어도 됩니다.)"
