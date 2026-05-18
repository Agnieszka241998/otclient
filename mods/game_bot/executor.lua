function executeBot(config, storage, tabs, msgCallback, saveConfigCallback, reloadCallback, websockets)
  local currentScript = "<bootstrap>"
  local missingGlobalsByScript = {}
  local lastMissingGlobalByScript = {}

  local function reportDiagnostic(level, text)
    local line = "[vBot debug] " .. tostring(text)
    pcall(function()
      msgCallback(level, line)
    end)
    pcall(function()
      if level == "error" and g_logger.error then
        g_logger.error(line)
      elseif g_logger.warning then
        g_logger.warning(line)
      end
    end)
  end

  local function buildTraceback(err)
    err = tostring(err)
    if debug and debug.traceback then
      return debug.traceback(err, 2)
    end
    return err
  end

  local function noteMissingGlobal(name)
    if type(name) ~= "string" then
      return
    end

    local scriptName = currentScript or "<unknown>"
    local scriptGlobals = missingGlobalsByScript[scriptName]
    if not scriptGlobals then
      scriptGlobals = {}
      missingGlobalsByScript[scriptName] = scriptGlobals
    end

    if scriptGlobals[name] then
      return
    end

    scriptGlobals[name] = true
    lastMissingGlobalByScript[scriptName] = name
    reportDiagnostic("warn", string.format("missing global '%s' while running %s", name, scriptName))
  end

  local function summarizeMissingGlobals(scriptName)
    local scriptGlobals = missingGlobalsByScript[scriptName]
    if not scriptGlobals then
      return nil
    end

    local names = {}
    for name in pairs(scriptGlobals) do
      table.insert(names, name)
    end

    if #names == 0 then
      return nil
    end

    table.sort(names)
    return table.concat(names, ", ")
  end

  local function normalizeSourceName(source)
    if type(source) ~= "string" then
      return ""
    end
    local prefix = source:sub(1, 1)
    if prefix == "@" or prefix == "=" then
      return source:sub(2)
    end
    return source
  end

  local function shouldFailOnMissingGlobal(scriptName)
    return type(scriptName) == "string" and scriptName:find("PvPScripts3", 1, true) ~= nil
  end

  local function createExecutionProbe(file)
    local probe = {
      file = file,
      active = file:find("PvPScripts3", 1, true) ~= nil,
      lastSource = nil,
      lastLine = nil,
      lastFunc = nil,
      pcByFunc = {},
      errorFrames = nil
    }

    if not probe.active or not debug or not debug.sethook or not debug.getinfo then
      return probe
    end

    probe.hook = function()
      local info = debug.getinfo(2, "Sfl")
      if not info then
        return
      end

      local source = normalizeSourceName(info.source)
      if source ~= file then
        return
      end

      probe.lastSource = source
      probe.lastLine = info.currentline
      probe.lastFunc = info.func
      if info.func then
        local count = (probe.pcByFunc[info.func] or 0) + 1
        probe.pcByFunc[info.func] = count
      end
    end

    probe.start = function()
      debug.sethook(probe.hook, "", 1)
    end

    probe.stop = function()
      debug.sethook()
    end

    return probe
  end

  local function captureErrorFrames()
    local frames = {}
    if not debug or not debug.getinfo then
      return frames
    end

    for level = 2, 12 do
      local info = debug.getinfo(level, "Slnf")
      if not info then
        break
      end

      table.insert(frames, {
        level = level,
        source = normalizeSourceName(info.source),
        currentline = info.currentline,
        name = info.name,
        func = info.func
      })
    end

    return frames
  end

  local function appendLuaJitProbeDump(lines, probe)
    if not probe or not probe.active then
      return
    end

    if probe.lastSource or probe.lastLine then
      table.insert(lines, string.format("Last probe frame: %s:%s", tostring(probe.lastSource or probe.file), tostring(probe.lastLine)))
    end

    if not probe.lastFunc then
      return
    end

    local okUtil, jitUtil = pcall(require, "jit.util")
    local okVmdef, jitVmdef = pcall(require, "jit.vmdef")
    if not okUtil or not okVmdef or type(jitUtil) ~= "table" or type(jitVmdef) ~= "table" then
      table.insert(lines, "LuaJIT probe: jit.util/jit.vmdef unavailable")
      return
    end

    local approxPc = probe.pcByFunc[probe.lastFunc]
    if not approxPc then
      table.insert(lines, "LuaJIT probe: no approximate PC captured")
      return
    end

    table.insert(lines, string.format("Approx source frame: %s:%s", probe.lastSource or probe.file, tostring(probe.lastLine)))
    table.insert(lines, string.format("Approx LuaJIT PC: %d", approxPc))

    local bitlib = rawget(_G, "bit32") or rawget(_G, "bit")
    if not bitlib or type(bitlib.band) ~= "function" then
      return
    end

    local startPc = math.max(1, approxPc - 8)
    local endPc = approxPc + 8
    table.insert(lines, "Nearby bytecode:")
    for pc = startPc, endPc do
      local okBc, ins, mode = pcall(jitUtil.funcbc, probe.lastFunc, pc)
      if okBc and ins then
        local opcode = bitlib.band(ins, 0xff)
        local nameOffset = opcode * 6 + 1
        local opname = jitVmdef.bcnames:sub(nameOffset, nameOffset + 5):match("^%s*(.-)%s*$")
        local marker = (pc == approxPc) and ">>" or "  "
        table.insert(lines, string.format("%s pc=%d op=%s raw=0x%08X mode=%s", marker, pc, opname ~= "" and opname or "?", ins, tostring(mode)))
      end
    end
  end

  local function buildDetailedError(file, err, probe)
    local lines = {
      string.format("Bot script failure in %s", file),
      tostring(err)
    }

    local missingSummary = summarizeMissingGlobals(file)
    if missingSummary then
      table.insert(lines, "Missing globals seen before failure: " .. missingSummary)
    end
    if lastMissingGlobalByScript[file] then
      table.insert(lines, "Last missing global in script: " .. tostring(lastMissingGlobalByScript[file]))
    end

    if probe and probe.errorFrames and #probe.errorFrames > 0 then
      table.insert(lines, "Lua stack snapshot:")
      for _, frame in ipairs(probe.errorFrames) do
        table.insert(lines, string.format("  [%d] %s:%s (%s)", frame.level, frame.source ~= "" and frame.source or "<unknown>", tostring(frame.currentline), tostring(frame.name or "?")))
      end
    end

    appendLuaJitProbeDump(lines, probe)
    return table.concat(lines, "\n")
  end

  local function normalizeBotScriptPath(file)
    if type(file) ~= "string" then
      error("script path must be a string")
    end

    if file:sub(1, 5) == "/bot/" then
      return file
    end

    if file:sub(1, 6) == "/vBot/" then
      return "/bot/" .. config .. file
    end

    if file:sub(1, 1) == "/" then
      return "/bot/" .. config .. file
    end

    return "/bot/" .. config .. "/" .. file
  end

  -- load lua and otui files
  local configFiles = g_resources.listDirectoryFiles("/bot/" .. config, true, false)
  local luaFiles = {}
  local uiFiles = {}
  for i, file in ipairs(configFiles) do
    local ext = file:split(".")
    if ext[#ext]:lower() == "lua" then
      table.insert(luaFiles, file)
    end
    if ext[#ext]:lower() == "ui" or ext[#ext]:lower() == "otui" then
      table.insert(uiFiles, file)
    end
  end

  if #luaFiles == 0 then
    return error("Config (/bot/" .. config .. ") doesn't have lua files")
  end

  -- init bot variables
  local context = {}
  context.configDir = "/bot/".. config
  context.tabs = tabs
  context.mainTab = context.tabs:addTabGrid("Main", g_ui.createWidget('BotPanel'), nil,modules.game_bot.getBotTabs()).tabPanel.content
  context.panel = context.mainTab
  context.saveConfig = saveConfigCallback
  context.reload = reloadCallback

  context.storage = storage
  if context.storage._macros == nil then
    context.storage._macros = {} -- active macros
  end
  context.UI = context.UI or {}

  -- websockets, macros, hotkeys, scheduler, icons, callbacks
  context._websockets = websockets
  context._macros = {}
  context._hotkeys = {}
  context._scheduler = {}
  context._currentExecution = false
  context._callbacks = {
    onKeyDown = {},
    onKeyUp = {},
    onKeyPress = {},
    onTalk = {},
    onTextMessage = {},
    onLoginAdvice = {},
    onAddThing = {},
    onRemoveThing = {},
    onCreatureAppear = {},
    onCreatureDisappear = {},
    onCreaturePositionChange = {},
    onCreatureHealthPercentChange = {},
    onUse = {},
    onUseWith = {},
    onContainerOpen = {},
    onContainerClose = {},
    onContainerUpdateItem = {},
    onMissle = {},
    onAnimatedText = {},
    onStaticText = {},
    onChannelList = {},
    onOpenChannel = {},
    onCloseChannel = {},
    onChannelEvent = {},
    onTurn = {},
    onWalk = {},
    onImbuementWindow = {},
    onModalDialog = {},
    onAttackingCreatureChange = {},
    onManaChange = {},
    onStatesChange = {},
    onAddItem = {},
    onGameEditText = {},
    onGroupSpellCooldown = {},
    onSpellCooldown = {},
    onRemoveItem = {},
    onInventoryChange = {}
  }

  -- basic functions & classes
  context.print = print
  context.bit32 = bit32
  context.bit = bit
  context.pairs = pairs
  context.ipairs = ipairs
  context.tostring = tostring
  context.math = math
  context.table = table
  context.setmetatable = setmetatable
  context.string = string
  context.tonumber = tonumber
  context.type = type
  context.pcall = pcall
  context.os = {
    time = os.time,
    difftime = os.difftime,
    date = os.date,
    clock = os.clock
  }
  if _VERSION == "Lua 5.1" and type(jit) ~= "table" then
    context.load = function(str)
      local func = assert(loadstring(str))
      setfenv(func, context)
      return func
    end
    context.dofile = function(file) 
      local func = assert(loadstring(g_resources.readFileContents("/bot/" .. config .. "/" .. file)))
      setfenv(func, context)
      func()
    end
  else
    context.load = function(str) return assert(load(str, nil, nil, context)) end
    context.dofile = function(file) assert(load(g_resources.readFileContents("/bot/" .. config .. "/" .. file), file, nil, context))() end
  end
  context.loadstring = context.load
  context.assert = assert
  context.gcinfo = gcinfo
  context.tr = tr
  context.json = json
  context.base64 = base64
  context.regexMatch = regexMatch
  context.getDistanceBetween = function(p1, p2)
    return math.max(math.abs(p1.x - p2.x), math.abs(p1.y - p2.y))
  end
  context.isMobile = g_app.isMobile
  context.getVersion = g_app.getVersion

  -- classes
  context.g_resources = g_resources
  context.g_game = g_game
  context.g_map = g_map
  context.g_ui = g_ui
  context.g_sounds = g_sounds
  context.g_window = g_window
  context.g_mouse = g_mouse
  context.g_keyboard = g_keyboard
  context.g_things = g_things
  context.g_settings = g_settings
  context.g_platform = {
    openUrl = g_platform.openUrl,
    openDir = g_platform.openDir,
  }
  context.g_clock = g_clock
	
  context.Item = Item
  context.Creature = Creature
  context.ThingType = ThingType
  context.Effect = Effect
  context.Missile = Missile
  context.Player = Player
  context.Monster = Monster
  context.StaticText = StaticText
  context.HTTP = HTTP
  context.OutputMessage = OutputMessage
  local function createModuleProxy(source)
    local overrides = {}
    return setmetatable({}, {
      __index = function(_, key)
        if overrides[key] ~= nil then
          return overrides[key]
        end
        return source and source[key] or nil
      end,
      __newindex = function(_, key, value)
        overrides[key] = value
      end
    })
  end

  context.modules = createModuleProxy(modules)
  context.Directions = Directions

  local compatModules = context.modules
  compatModules.client = createModuleProxy(modules.client or {})
  compatModules.corelib = createModuleProxy(modules.corelib or {})
  compatModules.game_interface = createModuleProxy(modules.game_interface or {})
  compatModules.game_walking = createModuleProxy(modules.game_walking or modules.game_walk or {})
  compatModules.game_console = createModuleProxy(modules.game_console or {})

  compatModules.client.g_platform = compatModules.client.g_platform or g_platform

  compatModules.corelib.G = compatModules.corelib.G or G
  compatModules.corelib.g_http = compatModules.corelib.g_http or g_http
  compatModules.corelib.g_clock = compatModules.corelib.g_clock or g_clock
  compatModules.corelib.HTTP = compatModules.corelib.HTTP or HTTP
  compatModules.corelib.retranslateKeyComboDesc = compatModules.corelib.retranslateKeyComboDesc or retranslateKeyComboDesc

  if not compatModules.game_interface.gameMapPanel and compatModules.game_interface.getMapPanel then
    compatModules.game_interface.gameMapPanel = compatModules.game_interface.getMapPanel()
  end

  -- log functions
  context.info = function(text) return msgCallback("info", tostring(text)) end
  context.warn = function(text) return msgCallback("warn", tostring(text)) end
  context.error = function(text) return msgCallback("error", tostring(text)) end
  context.warning = context.warn

  setmetatable(context, {
    __index = function(_, key)
      local value = rawget(_G, key)
      if value ~= nil then
        return value
      end

      noteMissingGlobal(key)
      if shouldFailOnMissingGlobal(currentScript) then
        error(string.format("Missing global '%s' while initializing %s", tostring(key), tostring(currentScript)), 2)
      end
      return nil
    end
  })

  local function loadBotChunk(file)
    file = normalizeBotScriptPath(file)
    local contents = g_resources.readFileContents(file)
    if _VERSION == "Lua 5.1" and type(jit) ~= "table" then
      local func = assert(loadstring(contents))
      setfenv(func, context)
      return func
    end

    return assert(load(contents, file, nil, context))
  end

  local function executeBotChunk(file)
    file = normalizeBotScriptPath(file)
    local previousScript = currentScript
    currentScript = file
    local probe = createExecutionProbe(file)
    local chunkFunc = loadBotChunk(file)

    if probe.start then
      probe.start()
    end

    local function errorHandler(err)
      probe.errorFrames = captureErrorFrames()
      return buildTraceback(err)
    end

    local ok, result = xpcall(function()
      return chunkFunc()
    end, errorHandler)

    if probe.stop then
      probe.stop()
    end

    currentScript = previousScript

    if not ok then
      error(buildDetailedError(file, result, probe))
    end

    return result
  end

  context.dofile = function(file)
    return executeBotChunk(file)
  end

  -- init context
  context.now = g_clock.millis()
  context.time = g_clock.millis()
  context.player = g_game.getLocalPlayer()

  -- init functions
  G.botContext = context
  dofiles("functions")
  context.Panels = {}
  dofiles("panels")
  G.botContext = nil

  -- run ui scripts
  for i, file in ipairs(uiFiles) do
    g_ui.importStyle(file)
  end

  -- run lua script
  for i, file in ipairs(luaFiles) do
    executeBotChunk(file)
    context.panel = context.mainTab -- reset default tab
  end

  return {
    script = function()
      context.now = g_clock.millis()
      context.time = g_clock.millis()

      for i, macro in ipairs(context._macros) do
        if macro.lastExecution + macro.timeout <= context.now and macro.enabled then
          local status, result = pcall(function()
            if macro.callback(macro) then
                macro.lastExecution = context.now
            end
          end)
          if not status then
            context.error("Macro: " .. macro.name .. " execution error: " .. result)
          end
        end
      end

      while #context._scheduler > 0 and context._scheduler[1].execution <= g_clock.millis() do
        local status, result = pcall(function()
          context._scheduler[1].callback()
        end)
        if not status then
          context.error("Schedule execution error: " .. result)
        end
        table.remove(context._scheduler, 1)
      end
    end,
    callbacks = {
      onKeyDown = function(keyCode, keyboardModifiers)
        local keyDesc = determineKeyComboDesc(keyCode, keyboardModifiers)
        for i, macro in ipairs(context._macros) do
          if macro.switch and macro.hotkey == keyDesc then
            macro.switch:onClick()
          end
        end
        local hotkey = context._hotkeys[keyDesc]
        if hotkey then
          if hotkey.single then
            if hotkey.callback() then
              hotkey.lastExecution = context.now
            end
          end
          if hotkey.switch then
            hotkey.switch:setOn(true)
          end
        end
        for i, callback in ipairs(context._callbacks.onKeyDown) do
          callback(keyDesc)
        end
      end,
      onKeyUp = function(keyCode, keyboardModifiers)
        local keyDesc = determineKeyComboDesc(keyCode, keyboardModifiers)
        local hotkey = context._hotkeys[keyDesc]
        if hotkey then
          if hotkey.switch then
            hotkey.switch:setOn(false)
          end
        end
        for i, callback in ipairs(context._callbacks.onKeyUp) do
          callback(keyDesc)
        end
      end,
      onKeyPress = function(keyCode, keyboardModifiers, autoRepeatTicks)
        local keyDesc = determineKeyComboDesc(keyCode, keyboardModifiers)
        local hotkey = context._hotkeys[keyDesc]
        if hotkey and not hotkey.single then
          if hotkey.callback() then
            hotkey.lastExecution = context.now
          end
        end
        for i, callback in ipairs(context._callbacks.onKeyPress) do
          callback(keyDesc, autoRepeatTicks)
        end
      end,
      onTalk = function(name, level, mode, text, channelId, pos)
        for i, callback in ipairs(context._callbacks.onTalk) do
          callback(name, level, mode, text, channelId, pos)
        end
      end,
      onImbuementWindow = function(itemId, slots, activeSlots, imbuements, needItems)
        for i, callback in ipairs(context._callbacks.onImbuementWindow) do
          callback(itemId, slots, activeSlots, imbuements, needItems)
        end
      end,
      onTextMessage = function(mode, text)
        for i, callback in ipairs(context._callbacks.onTextMessage) do
          callback(mode, text)
        end
      end,
      onLoginAdvice = function(message)
        for i, callback in ipairs(context._callbacks.onLoginAdvice) do
          callback(message)
        end
      end,
      onAddThing = function(tile, thing)
        for i, callback in ipairs(context._callbacks.onAddThing) do
          callback(tile, thing)
        end
      end,
      onRemoveThing = function(tile, thing)
        for i, callback in ipairs(context._callbacks.onRemoveThing) do
          callback(tile, thing)
        end
      end,
      onCreatureAppear = function(creature)
        for i, callback in ipairs(context._callbacks.onCreatureAppear) do
          callback(creature)
        end
      end,
      onCreatureDisappear = function(creature)
        for i, callback in ipairs(context._callbacks.onCreatureDisappear) do
          callback(creature)
        end
      end,
      onCreaturePositionChange = function(creature, newPos, oldPos)
        for i, callback in ipairs(context._callbacks.onCreaturePositionChange) do
          callback(creature, newPos, oldPos)
        end
      end,
      onCreatureHealthPercentChange = function(creature, healthPercent)
        for i, callback in ipairs(context._callbacks.onCreatureHealthPercentChange) do
          callback(creature, healthPercent)
        end
      end,
      onUse = function(pos, itemId, stackPos, subType)
        for i, callback in ipairs(context._callbacks.onUse) do
          callback(pos, itemId, stackPos, subType)
        end
      end,
      onUseWith = function(pos, itemId, target, subType)
        for i, callback in ipairs(context._callbacks.onUseWith) do
          callback(pos, itemId, target, subType)
        end
      end,
      onContainerOpen = function(container, previousContainer)
        for i, callback in ipairs(context._callbacks.onContainerOpen) do
          callback(container, previousContainer)
        end
      end,
      onContainerClose = function(container)
        for i, callback in ipairs(context._callbacks.onContainerClose) do
          callback(container)
        end
      end,
      onContainerUpdateItem = function(container, slot, item, oldItem)
        for i, callback in ipairs(context._callbacks.onContainerUpdateItem) do
          callback(container, slot, item, oldItem)
        end
      end,
      onMissle = function(missle)
        for i, callback in ipairs(context._callbacks.onMissle) do
          callback(missle)
        end
      end,
      onAnimatedText = function(thing, text)
        for i, callback in ipairs(context._callbacks.onAnimatedText) do
          callback(thing, text)
        end
      end,
      onStaticText = function(thing, text)
        for i, callback in ipairs(context._callbacks.onStaticText) do
          callback(thing, text)
        end
      end,
      onChannelList = function(channels)
        for i, callback in ipairs(context._callbacks.onChannelList) do
          callback(channels)
        end
      end,
      onOpenChannel = function(channelId, channelName)
        for i, callback in ipairs(context._callbacks.onOpenChannel) do
          callback(channels)
        end
      end,
      onCloseChannel = function(channelId)
        for i, callback in ipairs(context._callbacks.onCloseChannel) do
          callback(channelId)
        end
      end,
      onChannelEvent = function(channelId, name, event)
        for i, callback in ipairs(context._callbacks.onChannelEvent) do
          callback(channelId, name, event)
        end
      end,
      onTurn = function(creature, direction)
        for i, callback in ipairs(context._callbacks.onTurn) do
          callback(creature, direction)
        end
      end,
      onWalk = function(creature, oldPos, newPos)
        for i, callback in ipairs(context._callbacks.onWalk) do
          callback(creature, oldPos, newPos)
        end
      end,
      onModalDialog = function(id, title, message, buttons, enterButton, escapeButton, choices, priority)
        for i, callback in ipairs(context._callbacks.onModalDialog) do
          callback(id, title, message, buttons, enterButton, escapeButton, choices, priority)
        end
      end,
      onGameEditText = function(id, itemId, maxLength, text, writer, time)
        for i, callback in ipairs(context._callbacks.onGameEditText) do
          callback(id, itemId, maxLength, text, writer, time)
        end
      end,
      onAttackingCreatureChange = function(creature, oldCreature)
        for i, callback in ipairs(context._callbacks.onAttackingCreatureChange) do
          callback(creature, oldCreature)
        end
      end,
      onManaChange = function(player, mana, maxMana, oldMana, oldMaxMana)
        for i, callback in ipairs(context._callbacks.onManaChange) do
          callback(player, mana, maxMana, oldMana, oldMaxMana)
        end
      end,
      onAddItem = function(container, slot, item)
        for i, callback in ipairs(context._callbacks.onAddItem) do
          callback(container, slot, item)
        end
      end,
      onRemoveItem = function(container, slot, item)
        for i, callback in ipairs(context._callbacks.onRemoveItem) do
          callback(container, slot, item)
        end
      end,
      onStatesChange = function(player, states, oldStates)
        for i, callback in ipairs(context._callbacks.onStatesChange) do
          callback(player, states, oldStates)
        end
      end,
      onGroupSpellCooldown = function(iconId, duration)
        for i, callback in ipairs(context._callbacks.onGroupSpellCooldown) do
          callback(iconId, duration)
        end
      end,
      onSpellCooldown = function(iconId, duration)
        for i, callback in ipairs(context._callbacks.onSpellCooldown) do
          callback(iconId, duration)
        end
      end,
      onInventoryChange = function(player, slot, item, oldItem)
        for i, callback in ipairs(context._callbacks.onInventoryChange) do
          callback(player, slot, item, oldItem)
        end
      end
    }
  }
end
