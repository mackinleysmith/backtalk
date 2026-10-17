--- === Backtalk ===
---
--- Make dictation apps and clipboard managers paste correctly inside Apple's
--- Screen Sharing.
---
--- Apps like Wispr Flow paste by putting text on the clipboard and posting a
--- synthetic ⌘V. Screen Sharing drops the synthetic ⌘, so the remote Mac just
--- gets a "v". Backtalk intercepts that synthetic ⌘V while Screen Sharing is
--- frontmost, swallows it, and instead ships the clipboard to the remote Mac over
--- SSH, where it's copied and pasted natively.
---
--- Physical ⌘V presses are left alone, as is every other app.

local obj = {}
obj.__index = obj

obj.name = "Backtalk"
obj.version = "1.0"
obj.author = "MacKinley Smith"
obj.license = "MIT - https://opensource.org/licenses/MIT"

local SCREEN_SHARING = "com.apple.ScreenSharing"
local V = hs.keycodes.map.v
local types = hs.eventtap.event.types
local SOURCE_PID = hs.eventtap.event.properties.eventSourceUnixProcessID

-- Copy stdin to the remote clipboard (UTF-8 safe), then paste into its focused app.
local PASTE_CMD = [[LANG=en_US.UTF-8 pbcopy && osascript -e 'tell application "System Events" to keystroke "v" using command down']]
-- Exits 0 while someone is screen-sharing the remote Mac, 1 once nobody is.
-- Only the local-address column counts, so its own outgoing sessions don't.
local SESSION_CHECK_CMD = [[netstat -an -p tcp | awk '$4 ~ /[.]5900$/ && $6 == "ESTABLISHED" { found = 1 } END { exit !found }']]

-- Reuse one SSH connection so pastes after the first are near-instant.
local SSH_OPTS = {
  "-o", "BatchMode=yes",
  "-o", "ConnectTimeout=3",
  -- Notice a connection that died while either Mac slept, instead of hanging on it.
  "-o", "ServerAliveInterval=5",
  "-o", "ServerAliveCountMax=2",
  "-o", "ControlMaster=auto",
  "-o", "ControlPath=~/.ssh/cm-backtalk-%C",
  "-o", "ControlPersist=10m",
}

-- Push-to-talk dictation apps, by their name in /Applications.
local DEFAULT_PAUSE_APPS = {
  "Wispr Flow", "superwhisper", "VoiceInk", "MacWhisper",
  "Aqua Voice", "Spokenly", "Handy", "Hex",
}
local DEFAULT_OPEN_ARGS = { "-g" } -- launch in the background
-- On the remote Mac: the apps we quit, so we reopen only those (even after a reload).
local PAUSED_FILE = "~/.backtalk-paused"

-- Even with `open -g`, some apps (Wispr Flow) pop their main window to the front
-- a couple of seconds after launch. For 10s after reopening, close any standard
-- windows of the app with this bundle ID; floating panels (the dictation pill) stay.
local CLOSE_WINDOWS_SCRIPT = [[
on run argv
  set bundleID to item 1 of argv
  tell application "System Events"
    repeat with p in (processes whose bundle identifier is bundleID)
      repeat with w in (windows of p whose subrole is "AXStandardWindow")
        click (first button of w whose subrole is "AXCloseButton")
      end repeat
    end repeat
  end tell
end run]]

--- Quotes `s` as a single shell word.
local function shellQuote(s)
  return "'" .. s:gsub("'", [['\'']]) .. "'"
end

--- Shell commands that quit the running `apps` on a remote Mac (remembering
--- which, in PAUSED_FILE) and later reopen just those.
local function pauseCommands(apps)
  local pause, resume = { "f=" .. PAUSED_FILE }, { "f=" .. PAUSED_FILE, '[ -f "$f" ] || exit 0' }
  for _, entry in ipairs(apps) do
    local opts = type(entry) == "table" and entry or { entry }
    local name, openArgs = opts[1], opts.openArgs or DEFAULT_OPEN_ARGS
    local path = "/Applications/" .. name .. ".app"
    -- Matches every process inside the bundle (Wispr Flow runs a helper app too).
    local pattern = shellQuote("^" .. path:gsub("[%^%$%(%)%.%[%]%*%+%?{}|\\]", "\\%0") .. "/")
    local qname = shellQuote(name)
    table.insert(pause, ("if pgrep -qf %s; then pkill -f %s; grep -qxF %s \"$f\" 2>/dev/null || echo %s >> \"$f\"; fi")
      :format(pattern, pattern, qname, qname))
    -- `open -a <name>` reports success over SSH without launching Wispr Flow, so use the path.
    local open = ("open %s %s;"):format(table.concat(hs.fnutils.imap(openArgs, shellQuote), " "), shellQuote(path))
    if opts.closeWindows ~= false then
      local osa = table.concat(hs.fnutils.imap(hs.fnutils.split(CLOSE_WINDOWS_SCRIPT, "\n"), function(line)
        return "-e " .. shellQuote(line)
      end), " ")
      open = open .. (" (id=$(defaults read %s CFBundleIdentifier); for i in $(seq 20); do sleep 0.5; osascript %s \"$id\"; done) >/dev/null 2>&1 &")
        :format(shellQuote(path .. "/Contents/Info"), osa)
    end
    table.insert(resume, ("if grep -qxF %s \"$f\"; then %s fi"):format(qname, open))
  end
  table.insert(pause, "true")
  table.insert(resume, 'rm -f "$f"')
  return table.concat(pause, "; "), table.concat(resume, "; ")
end

--- Runs `cmd` on `host`, optionally feeding it `input` on stdin. Calls
--- `onDone(exitCode)` when it finishes (255 means SSH itself failed), or alerts
--- on failure if no `onDone` is given.
local function runRemotely(host, cmd, input, onDone)
  local args = hs.fnutils.concat(hs.fnutils.copy(SSH_OPTS), { host, cmd })
  local task = hs.task.new("/usr/bin/ssh", function(code, _, stderr)
    if onDone then
      onDone(code)
    elseif code ~= 0 then
      hs.alert.show("Backtalk failed: " .. (stderr ~= "" and stderr or ("exit " .. code)))
    end
  end, args)
  if input then task:setInput(input) end
  task:start()
end

--- Remote computer name from a Screen Sharing window title, e.g.
--- "Office Mac – Locked" → "Office Mac".
local function computerName(window)
  local title = window:title() or ""
  return title:match("^(.-) – ") or title
end

--- True for a ⌘V posted by another app (not the keyboard) into Screen Sharing.
local function isSyntheticPasteIntoScreenSharing(event)
  if event:getKeyCode() ~= V or not event:getFlags():containExactly({ "cmd" }) then
    return false
  end
  -- Hardware key events have no source process.
  if event:getProperty(SOURCE_PID) == 0 then return false end
  local app = hs.application.frontmostApplication()
  return app ~= nil and app:bundleID() == SCREEN_SHARING
end

--- Backtalk:start(config) -> Backtalk
--- Method
--- Starts intercepting pastes into Screen Sharing.
---
--- Parameters:
---  * config - A table with:
---    * hosts - Maps each remote computer's name, as shown in the Screen Sharing
---      window title, to anything `ssh` accepts (alias, hostname, user@host).
---    * pauseApps - Optional list of apps (names in /Applications) to quit on a
---      remote Mac while you're screen-sharing it, and reopen afterwards. Only
---      apps that were running get reopened. Screen Sharing forwards push-to-talk
---      hotkeys, so otherwise the remote copy would listen on its own mic.
---      Defaults to common dictation apps; `{}` turns it off. Reopened apps start
---      in the background and have their main windows closed so they don't pop
---      up. An entry can be a table to change that, e.g.
---      `{ "Some App", openArgs = { "-g", "-j" }, closeWindows = false }`.
function obj:start(config)
  local hosts = config.hosts
  local pauseApps = config.pauseApps or DEFAULT_PAUSE_APPS
  self:stop()

  self.tap = hs.eventtap.new({ types.keyDown, types.keyUp }, function(event)
    if not isSyntheticPasteIntoScreenSharing(event) then return false end
    if event:getType() == types.keyDown then
      local window = hs.application.frontmostApplication():focusedWindow()
      local name = window and computerName(window)
      local host = name and hosts[name]
      local text = hs.pasteboard.getContents()
      if not host then
        hs.alert.show("Backtalk: no host configured for \"" .. tostring(name) .. "\"")
      elseif text and text ~= "" then
        runRemotely(host, PASTE_CMD, text)
      end
    end
    return true -- swallow both halves so the remote never sees the "v"
  end)
  self.tap:start()

  if #pauseApps == 0 then return self end

  local quitCmd, openCmd = pauseCommands(pauseApps)

  -- Keep pauseApps quit on exactly the hosts we're live-sharing: a Screen Sharing
  -- window is open to it, and the remote hasn't reported the session ended (a
  -- window stays open after the remote presses Escape, or the network drops).
  -- A host only counts as paused/resumed once its SSH command succeeds; until
  -- then (e.g. it went to sleep mid-session) we keep retrying.
  local windowOpen, ended, paused, busy, checking = {}, {}, {}, {}, {}

  local function reconcile()
    local pending = hs.fnutils.copy(paused)
    for host in pairs(windowOpen) do pending[host] = true end
    for host in pairs(pending) do
      local want = windowOpen[host] == true and not ended[host]
      if (paused[host] == true) ~= want and not busy[host] then
        busy[host] = true
        runRemotely(host, want and quitCmd or openCmd, nil, function(code)
          busy[host] = nil
          if code == 0 then paused[host] = want or nil end
        end)
      end
    end
  end

  local function sync()
    windowOpen = {}
    local app = hs.application.get(SCREEN_SHARING)
    for _, window in ipairs(app and app:allWindows() or {}) do
      local host = hosts[computerName(window)]
      if host then windowOpen[host] = true end
    end
    for host in pairs(ended) do
      if not windowOpen[host] then ended[host] = nil end
    end
    reconcile()
  end

  -- Ask each host with an open window whether it's still being shared. If SSH
  -- itself fails we learn nothing and keep the last answer.
  local function checkSessions()
    for host in pairs(windowOpen) do
      if not checking[host] then
        checking[host] = true
        runRemotely(host, SESSION_CHECK_CMD, nil, function(code)
          checking[host] = nil
          if code == 0 then ended[host] = nil elseif code == 1 then ended[host] = true end
          reconcile()
        end)
      end
    end
    reconcile()
  end

  -- We may have reloaded mid-session, so treat every host as possibly paused.
  -- Hosts we aren't sharing get a resume, which only reopens what PAUSED_FILE
  -- says we quit (and does nothing if it's absent).
  for _, host in pairs(hosts) do paused[host] = true end

  self.retryTimer = hs.timer.doEvery(15, checkSessions)

  self.windowFilter = hs.window.filter.new(false):setAppFilter("Screen Sharing", {})
  self.windowFilter:subscribe({
    hs.window.filter.windowCreated,
    hs.window.filter.windowDestroyed,
    hs.window.filter.windowTitleChanged,
  }, sync)

  -- Quitting the app doesn't always report each window closing.
  self.appWatcher = hs.application.watcher.new(function(_, event, app)
    if event == hs.application.watcher.terminated and app and app:bundleID() == SCREEN_SHARING then
      sync()
    end
  end)
  self.appWatcher:start()

  sync() -- Screen Sharing may already be open when Hammerspoon (re)loads.
  return self
end

--- Backtalk:stop() -> Backtalk
--- Method
--- Stops intercepting pastes and watching Screen Sharing windows.
function obj:stop()
  if self.tap then self.tap:stop() end
  if self.windowFilter then self.windowFilter:unsubscribeAll() end
  if self.appWatcher then self.appWatcher:stop() end
  if self.retryTimer then self.retryTimer:stop() end
  self.tap, self.windowFilter, self.appWatcher, self.retryTimer = nil, nil, nil, nil
  return self
end

return obj
