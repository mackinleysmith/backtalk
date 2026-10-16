--- === RemotePaste ===
---
--- Make dictation apps and clipboard managers paste correctly inside Apple's
--- Screen Sharing.
---
--- Apps like Wispr Flow paste by putting text on the clipboard and posting a
--- synthetic ⌘V. Screen Sharing drops the synthetic ⌘, so the remote Mac just
--- gets a "v". RemotePaste intercepts that synthetic ⌘V while Screen Sharing is
--- frontmost, swallows it, and instead ships the clipboard to the remote Mac over
--- SSH, where it's copied and pasted natively.
---
--- Physical ⌘V presses are left alone, as is every other app.

local obj = {}
obj.__index = obj

obj.name = "RemotePaste"
obj.version = "1.0"
obj.author = "MacKinley Smith"
obj.license = "MIT - https://opensource.org/licenses/MIT"

local SCREEN_SHARING = "com.apple.ScreenSharing"
local V = hs.keycodes.map.v
local types = hs.eventtap.event.types
local SOURCE_PID = hs.eventtap.event.properties.eventSourceUnixProcessID

-- Copy stdin to the remote clipboard (UTF-8 safe), then paste into its focused app.
local PASTE_CMD = [[LANG=en_US.UTF-8 pbcopy && osascript -e 'tell application "System Events" to keystroke "v" using command down']]

-- Reuse one SSH connection so pastes after the first are near-instant.
local SSH_OPTS = {
  "-o", "BatchMode=yes",
  "-o", "ConnectTimeout=3",
  -- Notice a connection that died while either Mac slept, instead of hanging on it.
  "-o", "ServerAliveInterval=5",
  "-o", "ServerAliveCountMax=2",
  "-o", "ControlMaster=auto",
  "-o", "ControlPath=~/.ssh/cm-remote-paste-%C",
  "-o", "ControlPersist=10m",
}

--- Quotes `s` as a single shell word.
local function shellQuote(s)
  return "'" .. s:gsub("'", [['\'']]) .. "'"
end

--- Runs `cmd` on `host`, optionally feeding it `input` on stdin. Calls
--- `onDone(ok)` when it finishes, or alerts on failure if no `onDone` is given.
local function runRemotely(host, cmd, input, onDone)
  local args = hs.fnutils.concat(hs.fnutils.copy(SSH_OPTS), { host, cmd })
  local task = hs.task.new("/usr/bin/ssh", function(code, _, stderr)
    if onDone then
      onDone(code == 0)
    elseif code ~= 0 then
      hs.alert.show("RemotePaste failed: " .. (stderr ~= "" and stderr or ("exit " .. code)))
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

--- RemotePaste:start(config) -> RemotePaste
--- Method
--- Starts intercepting pastes into Screen Sharing.
---
--- Parameters:
---  * config - A table with:
---    * hosts - Maps each remote computer's name, as shown in the Screen Sharing
---      window title, to anything `ssh` accepts (alias, hostname, user@host).
---    * pauseApps - Optional list of app names to quit on a remote Mac while a
---      Screen Sharing window to it is open, and reopen when it closes. Useful
---      for push-to-talk dictation apps, since Screen Sharing forwards their
---      hotkey and the remote copy would start listening on its own mic.
function obj:start(config)
  local hosts = config.hosts
  local pauseApps = config.pauseApps or {}
  self:stop()

  self.tap = hs.eventtap.new({ types.keyDown, types.keyUp }, function(event)
    if not isSyntheticPasteIntoScreenSharing(event) then return false end
    if event:getType() == types.keyDown then
      local window = hs.application.frontmostApplication():focusedWindow()
      local name = window and computerName(window)
      local host = name and hosts[name]
      local text = hs.pasteboard.getContents()
      if not host then
        hs.alert.show("RemotePaste: no host configured for \"" .. tostring(name) .. "\"")
      elseif text and text ~= "" then
        runRemotely(host, PASTE_CMD, text)
      end
    end
    return true -- swallow both halves so the remote never sees the "v"
  end)
  self.tap:start()

  if #pauseApps == 0 then return self end

  local quoted = hs.fnutils.imap(pauseApps, shellQuote)
  local quitCmd = "killall " .. table.concat(quoted, " ") .. " 2>/dev/null; true"
  local openCmd = table.concat(hs.fnutils.imap(quoted, function(app)
    return "open -g -a " .. app
  end), "; ")

  -- Keep pauseApps quit on exactly the hosts that have a Screen Sharing window
  -- open. A host only counts as paused/resumed once its SSH command succeeds;
  -- until then (e.g. it went to sleep mid-session) we keep retrying.
  local wanted, paused, busy = {}, {}, {}
  local function reconcile()
    local pending = hs.fnutils.copy(paused)
    for host in pairs(wanted) do pending[host] = true end
    for host in pairs(pending) do
      local want = wanted[host] == true
      if (paused[host] == true) ~= want and not busy[host] then
        busy[host] = true
        runRemotely(host, want and quitCmd or openCmd, nil, function(ok)
          busy[host] = nil
          if ok then paused[host] = want or nil end
        end)
      end
    end
  end

  local function sync()
    wanted = {}
    local app = hs.application.get(SCREEN_SHARING)
    for _, window in ipairs(app and app:allWindows() or {}) do
      local host = hosts[computerName(window)]
      if host then wanted[host] = true end
    end
    reconcile()
  end

  self.retryTimer = hs.timer.doEvery(30, reconcile)

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

--- RemotePaste:stop() -> RemotePaste
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
