#!/bin/sh
# Damagochi ↔ Claude Code 연동 훅.
#
# Claude Code 가 statusline 명령에 넘겨주는 JSON(여기에 주간 한도 rate_limits 가 들어 있다)을
# 파일로 저장해서 Damagochi 앱이 읽을 수 있게 한다. 외부로 전송하는 것은 없다.
#
# 사용법 (~/.claude/settings.json):
#   statusline 을 안 쓰는 경우
#     "statusLine": { "type": "command",
#       "command": "sh /Applications/Damagochi.app/Contents/Resources/claude-statusline-hook.sh" }
#   이미 쓰는 statusline 명령이 있는 경우: 그 명령을 뒤에 그대로 붙인다
#     "command": "sh /Applications/Damagochi.app/Contents/Resources/claude-statusline-hook.sh bash ~/.claude/statusline-command.sh"

input=$(cat)

dir="$HOME/Library/Application Support/Damagochi"
tmp="$dir/claude-usage.tmp.$$"
if mkdir -p "$dir" 2>/dev/null && printf '%s' "$input" > "$tmp" 2>/dev/null; then
  mv -f "$tmp" "$dir/claude-usage.json" 2>/dev/null || rm -f "$tmp"
fi

if [ "$#" -gt 0 ]; then
  # 기존 statusline 명령에 입력을 그대로 넘겨서 원래 표시를 유지한다
  printf '%s' "$input" | "$@"
else
  printf 'Damagochi 연동 중'
fi
