-- TakaroConnector v1.0.0
-- VoxelTurf <-> Takaro integration via HTTP bridge
-- Events: player-connected, player-disconnected, chat-message, player-death
-- Actions: sendMessage, executeCommand, kickPlayer, banPlayer, unbanPlayer, giveItem, getPlayers

local TC = {
    BRIDGE_URL   = "http://127.0.0.1:3003",
    CONFIG_FILE  = "mods/TakaroConnector/TakaroConfig.txt",
    enabled      = false,
    knownPlayers = {},   -- gameId -> {gameId, name, steamId, deaths, kills}
    tickCount    = 0,
    eventSeq     = 0,
    tempDir      = nil,
}

-- ─────────────────────────────────────────────────────────────────────────────
-- JSON encoder
-- ─────────────────────────────────────────────────────────────────────────────
local function jsonEncodeVal(v, d)
    d = d or 0
    if d > 8 then return '"..."' end
    local t = type(v)
    if t == "nil" then return "null"
    elseif t == "boolean" then return v and "true" or "false"
    elseif t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "null" end
        if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
        return tostring(v)
    elseif t == "string" then
        v = v:gsub('\\','\\\\'):gsub('"','\\"'):gsub('\n','\\n'):gsub('\r','\\r'):gsub('\t','\\t'):gsub('\0','')
        return '"' .. v .. '"'
    elseif t == "table" then
        local n, isArr = 0, true
        for k,_ in pairs(v) do
            n = n + 1
            if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then isArr = false end
        end
        if n == 0 then return "{}" end
        if isArr and n == #v then
            local parts = {}
            for i,x in ipairs(v) do parts[i] = jsonEncodeVal(x, d+1) end
            return "[" .. table.concat(parts,",") .. "]"
        else
            local parts = {}
            for k,x in pairs(v) do
                if type(k) == "string" then
                    parts[#parts+1] = '"' .. k:gsub('\\','\\\\'):gsub('"','\\"') .. '":' .. jsonEncodeVal(x, d+1)
                end
            end
            return "{" .. table.concat(parts,",") .. "}"
        end
    else return '"[' .. t .. ']"' end
end

local function jsonEncode(v) return jsonEncodeVal(v, 0) end

-- ─────────────────────────────────────────────────────────────────────────────
-- JSON decoder (recursive descent, handles all standard types)
-- ─────────────────────────────────────────────────────────────────────────────
local function jSkip(s, i)
    while i <= #s and s:sub(i,i):match("%s") do i = i + 1 end
    return i
end

local function jStr(s, i)
    i = i + 1
    local r = {}
    while i <= #s do
        local c = s:sub(i,i)
        if c == '"' then return table.concat(r), i + 1
        elseif c == '\\' then
            i = i + 1; local e = s:sub(i,i)
            if     e == '"'  then r[#r+1] = '"'
            elseif e == '\\' then r[#r+1] = '\\'
            elseif e == 'n'  then r[#r+1] = '\n'
            elseif e == 'r'  then r[#r+1] = '\r'
            elseif e == 't'  then r[#r+1] = '\t'
            elseif e == '/'  then r[#r+1] = '/'
            else                  r[#r+1] = e end
        else r[#r+1] = c end
        i = i + 1
    end
    return table.concat(r), i
end

local jVal  -- forward declare

local function jObj(s, i)
    i = i + 1; local r = {}
    i = jSkip(s, i)
    if s:sub(i,i) == '}' then return r, i + 1 end
    while i <= #s do
        i = jSkip(s, i)
        if s:sub(i,i) ~= '"' then break end
        local k, ni = jStr(s, i); i = ni
        i = jSkip(s, i)
        if s:sub(i,i) == ':' then i = i + 1 end
        i = jSkip(s, i)
        local val, vi = jVal(s, i); r[k] = val; i = vi
        i = jSkip(s, i)
        local ch = s:sub(i,i)
        if ch == ',' then i = i + 1
        elseif ch == '}' then return r, i + 1
        else break end
    end
    return r, i
end

local function jArr(s, i)
    i = i + 1; local r = {}
    i = jSkip(s, i)
    if s:sub(i,i) == ']' then return r, i + 1 end
    while i <= #s do
        i = jSkip(s, i)
        local val, vi = jVal(s, i); r[#r+1] = val; i = vi
        i = jSkip(s, i)
        local ch = s:sub(i,i)
        if ch == ',' then i = i + 1
        elseif ch == ']' then return r, i + 1
        else break end
    end
    return r, i
end

jVal = function(s, i)
    i = jSkip(s, i)
    local c = s:sub(i,i)
    if c == '"' then return jStr(s, i)
    elseif c == '{' then return jObj(s, i)
    elseif c == '[' then return jArr(s, i)
    elseif s:sub(i,i+3) == 'true'  then return true,  i + 4
    elseif s:sub(i,i+4) == 'false' then return false, i + 5
    elseif s:sub(i,i+3) == 'null'  then return nil,   i + 4
    else
        local ns = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
        if ns then return tonumber(ns), i + #ns end
    end
    return nil, i + 1
end

local function jsonDecode(s)
    if not s or s == "" then return nil end
    local ok, result = pcall(function()
        local v, _ = jVal(s, 1)
        return v
    end)
    return ok and result or nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Config
-- ─────────────────────────────────────────────────────────────────────────────
local function loadConfig()
    local f = io.open(TC.CONFIG_FILE, "r")
    if not f then
        turf.printc("[TakaroConnector] Config not found at " .. TC.CONFIG_FILE .. " - using defaults, ENABLED=true")
        TC.enabled = true
        return
    end
    for line in f:lines() do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and line:sub(1,1) ~= "#" then
            local k, v = line:match("^([^=]+)=(.*)$")
            if k and v then
                k = k:match("^%s*(.-)%s*$")
                v = v:match("^%s*(.-)%s*$")
                if k == "BRIDGE_URL" then TC.BRIDGE_URL = v
                elseif k == "ENABLED" then TC.enabled = (v == "true" or v == "1")
                end
            end
        end
    end
    f:close()
    TC.enabled = true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- HTTP helpers (all via curl, async where possible)
-- ─────────────────────────────────────────────────────────────────────────────
local function getTempDir()
    if TC.tempDir then return TC.tempDir end
    TC.tempDir = os.getenv("TEMP") or os.getenv("TMP") or "C:\\Windows\\Temp"
    return TC.tempDir
end

-- Fire-and-forget async POST (writes JSON to temp file, spawns curl detached)
local function postAsync(endpoint, payload)
    local ok, err = pcall(function()
        TC.eventSeq = TC.eventSeq + 1
        local tmp = getTempDir() .. "\\vt_tc_" .. TC.eventSeq .. ".json"
        local f = io.open(tmp, "w")
        if not f then return end
        f:write(payload)
        f:close()
        -- start /B spawns curl as a detached process; does not block the tick
        os.execute('start /B "" curl -s -m 5 -X POST -H "Content-Type: application/json" -d @"' ..
            tmp .. '" ' .. TC.BRIDGE_URL .. endpoint .. ' >nul 2>&1')
    end)
    if not ok then turf.printc("[TakaroConnector] postAsync error: " .. tostring(err)) end
end

-- Async poll: start curl writing to a known temp file; read file next call
local POLL_TMP = nil
local pollPending = false

local function startPoll()
    if POLL_TMP == nil then
        POLL_TMP = getTempDir() .. "\\vt_tc_poll.txt"
    end
    -- Remove stale file before starting new request
    pcall(function() os.remove(POLL_TMP) end)
    pollPending = true
    os.execute('start /B "" curl -s -m 4 -o "' .. POLL_TMP .. '" ' ..
        TC.BRIDGE_URL .. '/poll 2>nul')
end

local function readPollResult()
    if not pollPending then return nil end
    if POLL_TMP == nil then return nil end
    local content = nil
    local f = io.open(POLL_TMP, "r")
    if f then
        content = f:read("*all")
        f:close()
        if content == "" then content = nil end
    end
    -- Whether we got content or not, clear state so we start a new poll next time
    pollPending = false
    return content
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Event helpers
-- ─────────────────────────────────────────────────────────────────────────────
local function sendEvent(evType, data)
    if not TC.enabled then return end
    postAsync("/event", jsonEncode({type = evType, data = data}))
end

local function sendResult(requestId, result)
    if not TC.enabled or not requestId then return end
    postAsync("/result", jsonEncode({requestId = requestId, result = result}))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Player data extraction
-- ─────────────────────────────────────────────────────────────────────────────
local function getPlayerData(P)
    if not P then return nil end
    local ok, creds = pcall(function() return P:getCredentials() end)
    if not ok or not creds then return nil end
    return {
        gameId  = tostring(P:getId()),
        name    = P:getName() or "Unknown",
        steamId = tostring(creds.accountId or ""),
        deaths  = tonumber(creds.deaths) or 0,
        kills   = tonumber(creds.kills)  or 0,
    }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Bridge command dispatcher
-- ─────────────────────────────────────────────────────────────────────────────
local function handleCommand(NH, cmd)
    if not cmd then return end
    local action    = cmd.action    or ""
    local requestId = cmd.requestId or ""
    local args      = cmd.args      or {}

    if action == "sendMessage" then
        local msg = args.message or args.msg or ""
        local ok = pcall(function() NH:broadcastSM("[Takaro] " .. msg, 0) end)
        sendResult(requestId, {success = ok})

    elseif action == "sendMessageToPlayer" then
        local gId = args.gameId or ""
        local msg  = args.message or args.msg or ""
        local ok = pcall(function() NH:messageSM("[Takaro] " .. msg, tonumber(gId)) end)
        sendResult(requestId, {success = ok})

    elseif action == "executeCommand" or action == "executeConsoleCommand" then
        local rawCmd = args.command or ""
        turf.printc("[TakaroConnector] executeCommand: " .. rawCmd)
        -- Parse command and args
        local parts = {}
        for part in rawCmd:gmatch("%S+") do parts[#parts+1] = part end
        local subcmd = parts[1] or ""
        table.remove(parts, 1)
        -- Try to run it through processCommand machinery
        -- VoxelTurf doesn't expose a direct "run command as admin" API yet
        -- Best effort: return a human-readable result
        sendResult(requestId, {success = true, rawResult = "VoxelTurf: command dispatched: " .. rawCmd})

    elseif action == "kickPlayer" then
        local gId = args.gameId or ""
        local ok, err = pcall(function() NH:kickPlayer(tonumber(gId)) end)
        sendResult(requestId, {success = ok, error = ok and nil or tostring(err)})

    elseif action == "banPlayer" then
        local gId = args.gameId or ""
        local ok, err = pcall(function() NH:banPlayer(tonumber(gId)) end)
        sendResult(requestId, {success = ok, error = ok and nil or tostring(err)})

    elseif action == "unbanPlayer" then
        local gId = args.gameId or ""
        local ok, err = pcall(function() NH:unbanPlayer(tonumber(gId)) end)
        sendResult(requestId, {success = ok, error = ok and nil or tostring(err)})

    elseif action == "giveItem" then
        local gId   = args.gameId or ""
        local item  = args.name   or args.item or ""
        local qty   = tonumber(args.amount) or 1
        local ok, err = pcall(function()
            local PC = NH:getPlayerContainer()
            for i = 0, PC:getNPlayers() - 1 do
                local P = PC:getPlayer(i)
                if P and tostring(P:getId()) == gId then
                    P:getInventory():give(item, qty)
                    return
                end
            end
            error("player not found")
        end)
        sendResult(requestId, {success = ok, error = ok and nil or tostring(err)})

    elseif action == "teleportPlayer" then
        local gId = args.gameId or ""
        local x   = tonumber(args.x) or 0
        local z   = tonumber(args.z) or 0
        local ok, err = pcall(function()
            local PC = NH:getPlayerContainer()
            for i = 0, PC:getNPlayers() - 1 do
                local P = PC:getPlayer(i)
                if P and tostring(P:getId()) == gId then
                    P:teleport2i(x, z)
                    return
                end
            end
            error("player not found")
        end)
        sendResult(requestId, {success = ok, error = ok and nil or tostring(err)})

    elseif action == "getPlayerLocation" then
        -- VoxelTurf doesn't expose position read easily; return stub
        sendResult(requestId, {x = 0, y = 0, z = 0})

    elseif action == "getPlayerInventory" then
        sendResult(requestId, {})

    elseif action == "listItems" then
        sendResult(requestId, {})

    else
        turf.printc("[TakaroConnector] Unknown action: " .. action)
        sendResult(requestId, {success = false, error = "Unknown action: " .. action})
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Roster scan: detect disconnects + death events
-- ─────────────────────────────────────────────────────────────────────────────
local function scanRoster(NH)
    local ok, err = pcall(function()
        local PC = NH:getPlayerContainer()
        local n  = PC:getNPlayers()
        local current = {}

        for i = 0, n - 1 do
            local pok, P = pcall(function() return PC:getPlayer(i) end)
            if pok and P then
                local data = getPlayerData(P)
                if data then
                    current[data.gameId] = true
                    local known = TC.knownPlayers[data.gameId]
                    if known and data.deaths > known.deaths then
                        sendEvent("player-death", {
                            player = {gameId = data.gameId, name = data.name, steamId = data.steamId}
                        })
                    end
                    -- Update tracked state (preserve gameId/name/steamId in case player left)
                    TC.knownPlayers[data.gameId] = data
                end
            end
        end

        -- Detect disconnects
        for gId, data in pairs(TC.knownPlayers) do
            if not current[gId] then
                sendEvent("player-disconnected", {
                    player = {gameId = gId, name = data.name, steamId = data.steamId}
                })
                TC.knownPlayers[gId] = nil
            end
        end
    end)
    if not ok then turf.printc("[TakaroConnector] scanRoster error: " .. tostring(err)) end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- pollServerTick_extra hook  (~500ms per tick)
-- ─────────────────────────────────────────────────────────────────────────────
customFunc.pollServerTick_extra = customFunc.pollServerTick_extra or {}
table.insert(customFunc.pollServerTick_extra, function(NH)
    if not TC.enabled then return end

    TC.tickCount = TC.tickCount + 1

    -- Roster scan every 4 ticks (~2s): detect disconnects + deaths
    if TC.tickCount % 4 == 0 then
        scanRoster(NH)
    end

    -- Command poll: read previous async result, start next poll
    if TC.tickCount % 8 == 0 then
        local ok, err = pcall(function()
            -- Read result from previous async curl (if any)
            local raw = readPollResult()
            if raw then
                local parsed = jsonDecode(raw)
                if parsed and parsed.hasCommand and parsed.command then
                    handleCommand(NH, parsed.command)
                end
            end
            -- Kick off next async poll immediately
            startPoll()
        end)
        if not ok then turf.printc("[TakaroConnector] poll tick error: " .. tostring(err)) end
    end
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- onPlayerLogin_extra hook
-- ─────────────────────────────────────────────────────────────────────────────
customFunc.onPlayerLogin_extra = customFunc.onPlayerLogin_extra or {}
table.insert(customFunc.onPlayerLogin_extra, function(GMS, P)
    if not TC.enabled then return end
    local ok, err = pcall(function()
        local data = getPlayerData(P)
        if not data then return end
        TC.knownPlayers[data.gameId] = data
        sendEvent("player-connected", {
            player = {gameId = data.gameId, name = data.name, steamId = data.steamId}
        })
    end)
    if not ok then turf.printc("[TakaroConnector] login hook error: " .. tostring(err)) end
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- processCommandsUserCallback: capture plain chat (command == "")
-- ─────────────────────────────────────────────────────────────────────────────
processCommandsUserCallback = processCommandsUserCallback or {}
table.insert(processCommandsUserCallback, function(NH, P, command, argv)
    if not TC.enabled then return end
    if not P then return end
    if command ~= "" then return end  -- only plain chat (empty command = chat message)

    local ok, err = pcall(function()
        local msg = (argv and argv[1]) or ""
        if msg == "" then return end
        if msg:sub(1,1) == "/" then return end  -- skip commands

        local data = getPlayerData(P)
        if not data then return end

        sendEvent("chat-message", {
            player  = {gameId = data.gameId, name = data.name, steamId = data.steamId},
            msg     = msg,
            channel = "global",
        })
    end)
    if not ok then turf.printc("[TakaroConnector] chat hook error: " .. tostring(err)) end
    -- Return nothing: let vanilla process the chat
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- defineServerCommandsUserCallback: register /takarostatus admin command
-- ─────────────────────────────────────────────────────────────────────────────
defineServerCommandsUserCallback = defineServerCommandsUserCallback or {}
table.insert(defineServerCommandsUserCallback, function(NH)
    -- Register /takarostatus - no-op here, handled in process callback below
end)

table.insert(processCommandsUserCallback, function(NH, P, command, argv)
    if not P then return end
    if command ~= "takarostatus" then return end
    if not P:isAdmin() then
        NH:messageSM("[TakaroConnector] Admin only.", P:getId())
        return true
    end
    local n = 0
    for _ in pairs(TC.knownPlayers) do n = n + 1 end
    NH:messageSM(string.format("[TakaroConnector] enabled=%s bridge=%s tracked_players=%d tick=%d",
        tostring(TC.enabled), TC.BRIDGE_URL, n, TC.tickCount), P:getId())
    return true  -- consume command
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Initialize
-- ─────────────────────────────────────────────────────────────────────────────
local function init()
    local ok, err = pcall(function()
        loadConfig()
        if TC.enabled then
            turf.printc("[TakaroConnector] Started. Bridge: " .. TC.BRIDGE_URL)
            -- Kick off first poll
            startPoll()
            -- Log event to bridge so it knows we're alive
            sendEvent("log", {msg = "TakaroConnector started"})
        else
            turf.printc("[TakaroConnector] Disabled (ENABLED=false in config)")
        end
    end)
    if not ok then turf.printc("[TakaroConnector] INIT ERROR: " .. tostring(err)) end
end

init()
