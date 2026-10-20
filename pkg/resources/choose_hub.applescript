-- "Nestcast 스피커 선택": pick which Cast speaker Nestcast plays to.
-- Lists the Cast devices on the network, saves the choice, and restarts
-- Nestcast so it takes effect.
set core to "/Applications/Nestcast.app/Contents/MacOS/nestcast-core"
set listing to do shell script quoted form of core & " --list"
if listing is "" then
	display dialog "네트워크에서 Google Cast 스피커를 찾지 못했습니다." & return & ¬
		"Mac과 스피커가 같은 네트워크에 있는지, '로컬 네트워크' 권한이 허용되었는지 확인해 주세요." ¬
		buttons {"확인"} default button 1 with icon caution
	return
end if
set AppleScript's text item delimiters to tab
set namesList to {}
set idList to {}
set labelList to {}
repeat with ln in paragraphs of listing
	set parts to text items of ln
	set end of namesList to item 1 of parts
	set end of idList to item 3 of parts
	set end of labelList to (item 1 of parts) & "  (" & (item 2 of parts) & ")"
end repeat
set AppleScript's text item delimiters to ""
set picked to choose from list labelList with prompt "Mac 소리를 재생할 스피커를 선택하세요:" ¬
	with title "Nestcast 스피커 선택" OK button name "선택" cancel button name "취소"
if picked is false then return
set pickedLabel to item 1 of picked
repeat with i from 1 to count of labelList
	if item i of labelList is pickedLabel then
		set chosen to item i of namesList
		set chosenId to item i of idList
	end if
end repeat
set cfgDir to (POSIX path of (path to home folder)) & "Library/Application Support/nestcast"
-- Saved by unique device ID (names are not unique); the name is for display.
do shell script "mkdir -p " & quoted form of cfgDir & " && printf '%s\\n%s\\n' " & quoted form of chosenId & " " & quoted form of chosen & " > " & quoted form of (cfgDir & "/hub")
do shell script "launchctl kickstart -k gui/$(id -u)/local.nestcast || true"
display dialog "'" & chosen & "' 스피커로 재생합니다." buttons {"확인"} default button 1
