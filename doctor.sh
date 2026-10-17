#!/bin/bash
# Checks that Backtalk can paste from this Mac into a remote Mac.
# Usage: ./doctor.sh <ssh-host>    (the same host you put in your config)

host="$1"
if [ -z "$host" ]; then
  echo "Usage: $0 <ssh-host>" >&2
  exit 2
fi

failed=0
pass() { echo "✅ $1"; }
fail() { echo "❌ $1"; echo "   → $2"; failed=1; }

if [ -d /Applications/Hammerspoon.app ]; then
  pass "Hammerspoon is installed"
else
  fail "Hammerspoon is not installed" "Install it from https://www.hammerspoon.org"
fi

if [ -d ~/.hammerspoon/Spoons/Backtalk.spoon ]; then
  pass "Backtalk.spoon is installed"
else
  fail "Backtalk.spoon is not installed" "Copy Backtalk.spoon into ~/.hammerspoon/Spoons/"
fi

if ssh -o BatchMode=yes -o ConnectTimeout=5 "$host" true 2>/dev/null; then
  pass "SSH to $host works without a password"
else
  fail "Can't SSH to $host without a password" \
    "On the remote Mac, turn on System Settings → General → Sharing → Remote Login. Then run: ssh-copy-id $host"
  exit 1
fi

# Pressing Shift is harmless, but needs the same Accessibility permission as ⌘V.
if ssh -o BatchMode=yes "$host" \
  "osascript -e 'tell application \"System Events\" to key code 56'" >/dev/null 2>&1; then
  pass "$host allows keystrokes over SSH"
else
  fail "$host doesn't allow keystrokes over SSH" \
    "On the remote Mac, add /usr/libexec/sshd-keygen-wrapper under System Settings → Privacy & Security → Accessibility (press ⌘⇧G in the file picker to type the path)"
fi

if [ "$failed" = 0 ]; then
  echo
  echo "All good. Remember to grant Hammerspoon Accessibility on this Mac too."
fi
exit "$failed"
