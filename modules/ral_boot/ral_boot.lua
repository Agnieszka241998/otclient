-- RAL: Restart + Autologin + Wybór ostatniej postaci (OTCv8)
-- - 8 profile: !res1..8 / !restart1..8 (oddzielne konta i exe)
-- - Oryginalne okna Enter Game / Character List (bez niszczenia/close)
-- - Po zalogowaniu: miękki hide Character List
-- - Blokada „raz na postać” (RAL_ClearBlock, RAL_SetProfile)
-- - Działa zarówno dla wpisu w czacie, jak i programowego say("!res1")
-- + vBot: NICK -> CONFIG (zamiast profile -> config)

g_logger.info("[RAL] Boot (profiles, original windows, hide CL, chat & say hooks + nick vBot).")

-- =========================
-- KONFIGURACJA
-- =========================
local OPT = {
  -- Domyślny exe jeśli profil nie ma własnego
  exePathDefault = [[C:\Users\najs1\Desktop\otclientv8-master\otclient_dx.exe]],

  -- >>> UZUPEŁNIJ SWOJE KONTA I ŚCIEŻKI DO KLIENTÓW <<<
  accounts = {
    [1] = { account = "qeti333", password = "pop123..", exePath = [[C:\Users\qeti1\Desktop\OTC 15\otclient_dx.exe]] },
    [2] = { account = "najs111", password = "pop123..", exePath = [[C:\Users\qeti1\Desktop\otclientv8-master\otclient_dx.exe]] },
    [3] = { account = "furlan", password = "pop123..", exePath =  [[C:\Users\qeti1\Desktop\otclientv8-master\otclient_dx.exe]] },
    [4] = { account = "najs333", password = "pop123..", exePath = [[C:\Users\qeti1\Desktop\otclientv8-master\otclient_gl.exe]] },
    [5] = { account = "najs444", password = "pop123..", exePath = [[C:\Users\qeti1\Desktop\otclientv8-master\otclient_gl.exe]] },
    [6] = { account = "najs321", password = "pop123..", exePath = [[C:\Users\qeti1\Desktop\otclientv8-master\otclient_gl.exe]] },
    [7] = { account = "KONTO_RES7", password = "HASLO_RES7", exePath = [[C:\Sciezka\Klient7\otclient_dx.exe]] },
    [8] = { account = "KONTO_RES8", password = "HASLO_RES8", exePath = [[C:\Sciezka\Klient8\otclient_dx.exe]] },
  },

  defaultProfile = 1,

  -- Zachowanie dodatków
  behavior = {
    forwardCommandToServer = true,   -- wyślij !resN także na serwer (jako normalną wiadomość)
    captureProgrammaticSay = true,   -- przechwytuj również say("!resN") / g_game.talk("!resN") z kodu
    autoBPOnRes1          = true,    -- przy !res1 włącz autoBP.setOn()
    autoBPDelayMs         = 700      -- zwłoka przed autoBP.setOn() (ms)
  },

  -- Timingi UI
  uiPollMs = 300,
  maxTries = 240,
  delays = {
    afterLogoutMs      = 900,   -- po OFFLINE zanim start nowej instancji
    beforeLoginClickMs = 900,   -- po wpisaniu account/hasła zanim klik Login
    beforePickMs       = 1000,  -- po pokazaniu listy zanim wybór postaci
    beforeWorldLoginMs = 1200   -- po zaznaczeniu postaci zanim loginWorld
  },

  -- vBot (dropdown "Bot" -> config + OFF/ON)
  -- Nazwy configów MUSZĄ być 1:1 takie jak w comboboxie
  vbot = {
    applyDelayMs = 800,   -- ile po wejściu do gry czekać zanim ustawi config (ms)
    uiDelayMs    = 200,   -- mały delay po przełączeniu configu zanim sprawdzi OFF/ON (ms)
    autoEnableIfOff = true
  },

  -- >>> NICK -> CONFIG <<<
  vbotByCharacter = {
    ["Run Or Cry"]   = "Run Or Cry",
    ["Forest Run Run"]   = "Run Or Cry",
    ["Cry Or Run"] = "Run Or Cry",
    ["Run Forest Run"]  = "Run Or Cry",

    ["Wiesiek Wszyswka"] = "Club EK",
    ["Bolcowaty Bolec"]  = "Club EK",
    ["Marchelski Marek"] = "Club EK",
    ["Czarek Bolcowaty"] = "Club EK",

    ["Wisiek Lolek"] = "Bolek",
    ["Lolek Bolek"]  = "Bolek",
    ["Czarek Lolek"] = "Bolek",
    ["Karol Bolek"]  = "Bolek",

    ["Lizak Jeden"]  = "Ek Ixo",
    ["Lizak Dwa"]    = "Ek Ixo",
    ["Lizak Trzy"]   = "Ek Ixo",
    ["Lizak Cztery"] = "Ek Ixo"
  }
}

-- =========================
-- STAN / USTAWIENIA
-- =========================
local KEY_PENDING    = 'ral_pending'
local KEY_LASTCHAR   = 'ral_lastchar'
local KEY_BLOCKCHAR  = 'ral_blockchar'
local KEY_PROFILE    = 'ral_profile'

local function log(s) g_logger.info("[RAL] "..s) end
local function root() return g_ui and g_ui.getRootWidget and g_ui.getRootWidget() end
local function save()  pcall(function() if g_settings.save then g_settings.save() end end) end
local function getS(k, d) local v=g_settings.get(k); if v==nil or v=='' then return d end; return v end
local function setS(k, v) g_settings.set(k, v); save() end

local function getPending() return getS(KEY_PENDING,'0')=='1' end
local function setPending(v) setS(KEY_PENDING, v and '1' or '0') end
local function getLast() return getS(KEY_LASTCHAR,'') end
local function setLast(n) if n and #n>0 then setS(KEY_LASTCHAR, n) end end
local function getBlockChar() return getS(KEY_BLOCKCHAR,'') end
local function setBlockChar(n) setS(KEY_BLOCKCHAR, n or '') end
local function clampProfile(n) n=tonumber(n) or OPT.defaultProfile; if n<1 then n=1 end; if n>8 then n=8 end; return n end
local function setProfile(n) n=clampProfile(n); setS(KEY_PROFILE, tostring(n)); return n end
local function getProfile() return clampProfile(getS(KEY_PROFILE, tostring(OPT.defaultProfile))) end

local function getCred(p)
  p = clampProfile(p or getProfile())
  local c = OPT.accounts[p] or {}
  local account  = c.account or ""
  local password = c.password or ""
  local exePath  = (c.exePath and c.exePath ~= "") and c.exePath or (OPT.exePathDefault or "")
  return account, password, p, exePath
end

-- =========================
-- HELPERY
-- =========================
local function idOf(w)   return (w and w.getId   and w:getId())   or "" end
local function focusAndType(w, val)
  if not w then return false end
  pcall(function() if w.focus     then w:focus()     end end)
  pcall(function() if w.clearText then w:clearText() end end)
  local ok = pcall(function() w:setText(val) end)
  if ok then scheduleEvent(function() pcall(function() w:setText(val) end) end, 60) end
  return ok
end
local function clickWidget(w)
  if not w then return false end
  return pcall(function() if w.onClick then w:onClick() elseif w.click then w:click() end end)
end
local function normalizeName(s)
  if not s then return "" end
  s = tostring(s):gsub("%s*%b()", ""):gsub("%s+%-.*$",""):gsub("^%s+",""):gsub("%s+$","")
  return s:lower()
end
local function safeSay(msg)
  if type(msg) ~= 'string' or #msg == 0 then return end
  local ok = pcall(function()
    if _G.say then _G.say(msg)
    elseif g_game and g_game.talk then g_game.talk(msg) end
  end)
  return ok
end

-- =========================
-- vBot: wybór configu (combobox id="config") + włącz jeśli OFF (button id="enableButton")
-- =========================
local function getVBotWindow()
  local root = g_ui and g_ui.getRootWidget and g_ui.getRootWidget()
  if not root then return nil end
  return root:recursiveGetChildById("botWindow")
end

local function setVBotConfig(configName)
  if not configName or configName == "" then return false end
  local bw = getVBotWindow()
  if not bw then return false end
  local combo = bw:recursiveGetChildById("config")
  if not combo or not combo.setCurrentOption then return false end

  -- unikaj niepotrzebnego przełączania
  if combo.getCurrentOption then
    local cur = combo:getCurrentOption()
    if cur == configName then return true end
  end

  combo:setCurrentOption(configName)
  return true
end

local function ensureVBotOnIfOff()
  local bw = getVBotWindow()
  if not bw then return false end
  local btn = bw:recursiveGetChildById("enableButton")
  if not btn or not btn.getText then return false end

  local t = btn:getText()
  if t == "OFF" or t == "Off" then
    if btn.onClick then btn:onClick()
    elseif btn.press then btn:press()
    elseif btn.click then btn:click() end
    return true
  end
  return false
end

-- >>> ZAMIANA: profile -> nick <<<
local function applyVBotForCurrentCharacter()
  if not g_game.isOnline() then return end

  local player = g_game.getLocalPlayer and g_game.getLocalPlayer()
  if not player then return end

  local charName = player:getName()
  if not charName then return end

  local cfg = OPT.vbotByCharacter and OPT.vbotByCharacter[charName]
  if not cfg or cfg == "" then return end

  local tries = 0
  local function go()
    tries = tries + 1
    if setVBotConfig(cfg) then
      if OPT.vbot.autoEnableIfOff then
        scheduleEvent(function() ensureVBotOnIfOff() end, OPT.vbot.uiDelayMs or 200)
      end
      g_logger.info(string.format("[RAL] vBot: '%s' -> config '%s'", charName, cfg))
      return
    end
    if tries < 6 then scheduleEvent(go, 400) end
  end
  go()
end

-- =========================
-- START NOWEJ INSTANCJI (per profil)
-- =========================
local function startNewInstance(profileIndex)
  local _, _, pidx, exePath = getCred(profileIndex)
  local launched = false
  if exePath ~= "" and os and os.execute then
    local cmd = ('cmd /c start "" "%s"'):format(exePath)
    local ok  = os.execute(cmd)
    launched  = (ok == true or ok == 0)
    if launched then log(string.format("Start nowej instancji (profil %d): %s", pidx, exePath)) end
  end
  if (not launched) and exePath ~= "" and g_platform and g_platform.openUrl then
    launched = pcall(function() g_platform.openUrl("file:///" .. exePath:gsub("\\","/")) end) or false
  end
  if not launched then
    launched = pcall(function() g_app.restart() end) or false
    if launched then log("Użyto g_app.restart() (fallback).") end
  end
  return launched
end

-- =========================
-- ENTER GAME (oryginalne okno)
-- =========================
local egAttempted = false
local function findEnterGameWindow()
  local r = root(); if not r then return nil end
  for _, id in ipairs({ 'enterGame','enterGameWindow' }) do
    local w = r:recursiveGetChildById(id); if w then return w end
  end
  if getPending() and not egAttempted and EnterGame and EnterGame.openWindow then
    egAttempted = true
    pcall(function() EnterGame.openWindow() end)
  end
  return nil
end

local function collectTextEdits(container)
  local out = {}
  local function rec(w)
    if not w or not w.getChildren then return end
    if w.setText then table.insert(out, w) end
    for _, c in ipairs(w:getChildren()) do rec(c) end
  end
  rec(container); return out
end

local function findEditByLabel(win, labelText)
  labelText = labelText:lower()
  local function rec(w)
    if not w or not w.getChildren then return nil end
    if w.getText and w:getText() and w:getText():lower():find(labelText,1,true) then
      local p = w:getParent()
      if p and p.getChildren then
        local seen=false
        for _,c in ipairs(p:getChildren()) do
          if seen and c.setText then return c end
          if c==w then seen=true end
        end
      end
    end
    for _,c in ipairs(w:getChildren()) do local m=rec(c); if m then return m end end
  end
  return rec(win)
end

local function fillLoginForm(win)
  if not win then return false end
  local r = root(); if not r then return false end
  local account, password, pidx = getCred()

  local function byIds(ids)
    for _, id in ipairs(ids) do
      local w = win:recursiveGetChildById(id) or r:recursiveGetChildById(id)
      if w then return w end
    end
  end
  local acc = byIds({ "accountNameTextEdit","accountName","account","accountEdit","login","name","username","loginEdit","nameEdit","user" })
  local pwd = byIds({ "accountPasswordTextEdit","accountPassword","password","passwordEdit","pass","passEdit","passField" })
  if not acc then acc = findEditByLabel(win, "account name") end
  if not pwd then pwd = findEditByLabel(win, "password") end
  if not acc or not pwd then
    local edits = collectTextEdits(win); if #edits==0 then log("Brak pól w Enter Game."); return false end
    acc = acc or edits[1]; pwd = pwd or edits[2]
  end
  log(string.format("Profil %d → wpisuję account/password (id='%s'/'%s')", pidx, idOf(acc), idOf(pwd)))
  local ok1 = focusAndType(acc, account)
  local ok2 = focusAndType(pwd, password)

  scheduleEvent(function()
    local btn = byIds({ 'loginButton','enterGameButton','okButton','loginBtn','enterBtn' })
    if btn then log("Klikam Login (id='"..idOf(btn).."')."); clickWidget(btn) end
    if EnterGame and EnterGame.doLogin then pcall(function() EnterGame.doLogin() end) end
  end, OPT.delays.beforeLoginClickMs)

  return ok1 or ok2
end

local function autologinPump(try)
  if not getPending() then return end
  try = (try or 0) + 1
  if try > OPT.maxTries then log("Autologin timeout."); return end
  local win = findEnterGameWindow()
  if not win then
    if try % 10 == 1 then log("Czekam na okno Enter Game… ("..try..")") end
    return scheduleEvent(function() autologinPump(try) end, OPT.uiPollMs)
  end
  local ok = fillLoginForm(win)
  if not ok then
    if try % 10 == 1 then log("Nie znalazłem jeszcze właściwych pól… ("..try..")") end
    return scheduleEvent(function() autologinPump(try) end, OPT.uiPollMs)
  end
  scheduleEvent(function() pickCharPump(0) end, OPT.delays.beforePickMs)
end

-- =========================
-- CHARACTER LIST (oryginalne okno)
-- =========================
local function characterListWidget()
  local r = root(); if not r then return nil end
  for _, id in ipairs({ 'characterList','characters','charactersList','characterPanel','charactersPanel','nameList' }) do
    local w = r:recursiveGetChildById(id); if w then return w end
  end
  return nil
end

local function resolveFirstChild(list)
  local first=nil
  if list and list.getFirstChild then first=list:getFirstChild() end
  if not first and list and list.getChildren then local ch=list:getChildren(); first=ch and ch[1] or nil end
  return first
end

local function rowTextDeep(w)
  if not w then return "" end
  local txt=""
  local function rec(n)
    if not n or not n.getChildren then return end
    if n.getText then local t=n:getText(); if t and #t>0 then txt=txt.." "..t end end
    for _,c in ipairs(n:getChildren()) do rec(c) end
  end
  rec(w)
  return (txt:gsub("^%s+",""):gsub("%s+$",""))
end

local function hideCharacterListSoft()
  local r = root(); if not r then return end
  if CharacterList and CharacterList.hide then pcall(function() CharacterList.hide() end) end
  for _, id in ipairs({ 'characterListWindow','characterWindow','charactersWindow' }) do
    local w = r:recursiveGetChildById(id)
    if w and w.hide then pcall(function() w:hide() end) end
  end
  local list = r:recursiveGetChildById('characterList')
  if list then
    local w = list
    while w and w.getParent do
      local p = w:getParent(); if not p then break end; w = p
      if w.getTitle and w.hide then pcall(function() w:hide() end); break end
    end
  end
end

local worldAttempted=false
function pickCharPump(try)
  if not getPending() then return end
  try = (try or 0) + 1
  if try > OPT.maxTries then log("Picker timeout."); return end

  if g_game.isOnline and g_game.isOnline() then
    setPending(false)
    log("Zalogowano do gry (okna zamkną się naturalnie; Character List ukryję).")
    scheduleEvent(hideCharacterListSoft, 100)
    scheduleEvent(hideCharacterListSoft, 400)
    scheduleEvent(hideCharacterListSoft, 1200)
    return
  end

  local list = characterListWidget()
  if not (CharacterList and CharacterList.isVisible and CharacterList.isVisible()) or not list then
    if try % 10 == 1 then log("Czekam na okno Character List… ("..try..")") end
    return scheduleEvent(function() pickCharPump(try) end, OPT.uiPollMs)
  end
  if list.hasChildren and not list:hasChildren() then
    if try % 10 == 1 then log("Lista jeszcze bez dzieci… ("..try..")") end
    return scheduleEvent(function() pickCharPump(try) end, OPT.uiPollMs)
  end

  local target = normalizeName(getLast())
  if try == 1 then
    if target ~= "" then log("Szukam postaci: '"..getLast().."'.") else log("Brak zapamiętanej postaci — wybiorę pierwszą.") end
  end

  if target ~= "" and CharacterList and CharacterList.selectCharacter then
    pcall(function() CharacterList.selectCharacter(getLast()) end)
  end

  local row=nil
  if target ~= "" then
    for _,child in ipairs(list:getChildren()) do
      local t=rowTextDeep(child)
      if normalizeName(t):find(target,1,true) or normalizeName(t)==target then row=child; break end
    end
  end
  if not row then row = resolveFirstChild(list); if try==1 then log("Wybieram pierwszą postać (fallback).") end end

  if row then
    scheduleEvent(function()
      if list.focusChild then list:focusChild(row, ActiveFocusReason) end
      if row.onClick then pcall(function() row:onClick() end) end
      if row.onDoubleClick then scheduleEvent(function() pcall(function() row:onDoubleClick() end) end, 150) end
    end, 150)
  end

  if not worldAttempted then
    worldAttempted = true
    scheduleEvent(function()
      local charName = row and (row.characterName or (row.getText and row:getText())) or ''
      if charName=='' and row then local t=rowTextDeep(row); charName = t:match("^%s*([^%(]+)") or t end
      local worldName = (row and (row.worldName or row.world)) or 'Gunzodus'
      local worldHost = (row and (row.worldHost or row.worldIp or row.host)) or 'login-gunz.gunzot.com'
      local worldPort = (row and (row.worldPort or row.port)) or 7172

      local account, password, pidx = getCred()
      if charName and charName~='' then
        log(string.format("Profil %d → loginWorld: char='%s', world='%s' (%s:%s)", pidx, charName, tostring(worldName), tostring(worldHost), tostring(worldPort)))
        local token = (G and G.authenticatorToken) or ''
        local sess  = (G and G.sessionKey) or ''
        local ok = pcall(function()
          g_game.loginWorld(account, password, worldName, worldHost, worldPort, charName, token, sess)
        end)
        if not ok then pcall(function()
          g_game.loginWorld(account, password, worldName, worldHost, worldPort, charName)
        end) end
      end
    end, OPT.delays.beforeWorldLoginMs)
  end

  scheduleEvent(function() pickCharPump(try) end, OPT.uiPollMs)
end

-- =========================
-- AUTOSTART + HOOKI
-- =========================
local function autologinStart()
  if not getPending() then return end
  worldAttempted=false
  log(string.format("Autofill start (pending=true, profil %d)…", getProfile()))
  autologinPump(0)
end

local hooksSet=false
local function ensureHooks()
  if hooksSet then return end
  hooksSet=true
  connect(g_game, {
    onGameEnd = function()
      if not getPending() then return end
      scheduleEvent(function()
        if not getPending() then return end
        local pidx = getProfile()
        log(string.format("Restartuję proces klienta (profil %d)…", pidx))
        local started = startNewInstance(pidx)
        scheduleEvent(function() if g_app and g_app.exit then pcall(function() g_app.exit() end) end end, 200)
        if not started then log("Nie udało się włączyć nowej instancji (sprawdź exePath w profilu).") end
      end, OPT.delays.afterLogoutMs)
    end,
    onGameStart = function()
      if getPending() then
        scheduleEvent(hideCharacterListSoft, 100)
        setPending(false)
      end

      -- RAL: NICK -> vBot config (+ auto ON jeśli OFF)
      if OPT.vbot and OPT.vbot.applyDelayMs then
        scheduleEvent(applyVBotForCurrentCharacter, OPT.vbot.applyDelayMs)
      else
        scheduleEvent(applyVBotForCurrentCharacter, 800)
      end
    end
  })
end

-- =========================
-- KOMENDY / CHAT FILTER / SAY HOOK
-- =========================
local chatFilterRegistered = false

local function ensureChatCommand()
  if chatFilterRegistered then return end
  if modules and modules.game_console and modules.game_console.addFilter then
    local function handler(message)
      local original = message
      local msg = message:lower():gsub("%s+", " "):gsub("^%s+",""):gsub("%s+$","")
      local idx = msg:match("^!res%s*([1-8])$") or msg:match("^!res([1-8])$")
      if not idx then idx = msg:match("^!restart%s*([1-8])$") or msg:match("^!restart([1-8])$") end
      if idx then
        local n = tonumber(idx)
        -- opcjonalnie wyślij komendę na serwer (żeby serwerowy skrypt też zareagował)
        if OPT.behavior.forwardCommandToServer then
          scheduleEvent(function() safeSay(original) end, 10)
        end
        -- opcjonalny autoBP dla !res1
        if n == 1 and OPT.behavior.autoBPOnRes1 and autoBP and autoBP.setOn then
          scheduleEvent(function() pcall(function() autoBP.setOn() end) end, OPT.behavior.autoBPDelayMs or 0)
        end
        log(string.format("Komenda czatu !res%d → RAL_BeginRestart(%d).", n, n))
        scheduleEvent(function() if _G.RAL_BeginRestart then _G.RAL_BeginRestart(n) end end, 10)
        return true -- blokujemy oryginalne wysłanie, ale forward wyśle jedną sztukę
      end
      return false
    end
    modules.game_console.addFilter(handler)
    chatFilterRegistered = true
    log("Zarejestrowano komendy czatu: !res1..8 / !restart1..8 (obsługa wpisu ręcznego).")
  end
end

-- Hook na „programowe” say()/g_game.talk() – przechwytuje również say("!res1") z kodu
local sayHookInstalled = false
local function installOutgoingSayHook()
  if sayHookInstalled or not OPT.behavior.captureProgrammaticSay then return end
  sayHookInstalled = true

  local forward = OPT.behavior.forwardCommandToServer
  local oldSay  = rawget(_G, 'say')
  local oldTalk = g_game and g_game.talk

  local function maybeHandle(msg)
    if type(msg) ~= 'string' then return false end
    local compact = msg:lower():gsub("%s+", "")
    local idx = compact:match("^!res([1-8])$") or compact:match("^!restart([1-8])$")
    if idx then
      local n = tonumber(idx)
      if n == 1 and OPT.behavior.autoBPOnRes1 and autoBP and autoBP.setOn then
        scheduleEvent(function() pcall(function() autoBP.setOn() end) end, OPT.behavior.autoBPDelayMs or 0)
      end
      scheduleEvent(function() if _G.RAL_BeginRestart then _G.RAL_BeginRestart(n) end end, 10)
      return true
    end
    return false
  end

  _G.say = function(msg)
    local hit = maybeHandle(msg)
    if hit and not forward then return end
    if oldSay then return oldSay(msg) elseif g_game and g_game.talk then return g_game.talk(msg) end
  end

  if g_game then
    g_game.talk = function(msg)
      local hit = maybeHandle(msg)
      if hit and not forward then return end
      if oldTalk then return oldTalk(msg) end
    end
  end

  log("Zainstalowano hook na say()/g_game.talk() (obsługa wywołań programowych).")
end

-- =========================
-- PUBLIC API
-- =========================
_G.RAL_SetProfile = function(n)
  n = setProfile(n)
  local acc = (OPT.accounts[n] and OPT.accounts[n].account) or "?"
  log(string.format("Ustawiono domyślny profil %d (account='%s').", n, acc))
end

_G.RAL_ClearBlock = function()
  setBlockChar('')
  log("Odblokowano restart dla wszystkich postaci.")
end

_G.RAL_BeginRestart = function(profileIndex)
  if profileIndex then profileIndex = setProfile(profileIndex) end
  local pidx = getProfile()
  local acc, _, _, exep = getCred(pidx)

  local cur = ''
  if g_game.isOnline and g_game.isOnline() then
    local lp = g_game.getLocalPlayer and g_game.getLocalPlayer()
    cur = (lp and lp:getName()) or (g_game.getCharacterName and g_game.getCharacterName()) or ''
  end

  -- blokada „raz na postać”
  local blocked = getBlockChar()
  if blocked ~= '' and cur ~= '' and (blocked:lower() == cur:lower()) then
    log("Blokada: '"..cur.."' już wykonał restart. Zaloguj inną postać albo użyj RAL_ClearBlock().")
    return
  end

  if cur ~= '' then
    setLast(cur)
    setBlockChar(cur)
  end

  setPending(true); save()
  ensureHooks()
  ensureChatCommand()
  installOutgoingSayHook()
  log(string.format("Wylogowuję i szykuję restart… [profil %d, account='%s', exe='%s']", pidx, acc, exep))

  scheduleEvent(function()
    if g_game.isOnline and g_game.isOnline() then
      if g_game.safeLogout then g_game.safeLogout() elseif g_game.logout then g_game.logout() end
    else
      local started = startNewInstance(pidx)
      if started and g_app and g_app.exit then pcall(function() g_app.exit() end) end
    end
  end, 120)
end

_G.RAL_BeginRestart1 = function() _G.RAL_BeginRestart(1) end
_G.RAL_BeginRestart2 = function() _G.RAL_BeginRestart(2) end
_G.RAL_BeginRestart3 = function() _G.RAL_BeginRestart(3) end
_G.RAL_BeginRestart4 = function() _G.RAL_BeginRestart(4) end
_G.RAL_BeginRestart5 = function() _G.RAL_BeginRestart(5) end
_G.RAL_BeginRestart6 = function() _G.RAL_BeginRestart(6) end
_G.RAL_BeginRestart7 = function() _G.RAL_BeginRestart(7) end
_G.RAL_BeginRestart8 = function() _G.RAL_BeginRestart(8) end

-- =========================
-- BOOTSTRAP
-- =========================
addEvent(function()
  ensureChatCommand()
  installOutgoingSayHook()
  ensureHooks()
  if getPending() then
    log(string.format("Pending=true → autologin start (profil %d).", getProfile()))
    autologinStart()
  else
    log("Idle mode (pending=false).")
  end
end)

g_logger.info("[RAL] Ready. Chat: !res1..8  | Console: RAL_BeginRestart([1-8]), RAL_SetProfile(n), RAL_ClearBlock()")