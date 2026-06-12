-- TakaroConnector v2.0.0
-- VoxelTurf <-> Takaro via N_EXTERNAL UDP API
-- No curl. No HTTP. Pure UDP: bridge polls game, game responds with queued events.

local TC = {
    EXTERNAL_SECRET = 123456,   -- must match bridge EXTERNAL_SECRET
    enabled         = true,
    knownPlayers    = {},       -- gameId -> {gameId, name, steamId, deaths, kills}
    eventQueue      = {},       -- pending events to send on next poll
    tickCount       = 0,
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
-- JSON decoder
-- ─────────────────────────────────────────────────────────────────────────────
local function jSkip(s,i) while i<=#s and s:sub(i,i):match("%s") do i=i+1 end return i end
local function jStr(s,i)
    i=i+1; local r={}
    while i<=#s do
        local c=s:sub(i,i)
        if c=='"' then return table.concat(r),i+1
        elseif c=='\\' then
            i=i+1; local e=s:sub(i,i)
            if e=='"' then r[#r+1]='"' elseif e=='\\' then r[#r+1]='\\'
            elseif e=='n' then r[#r+1]='\n' elseif e=='r' then r[#r+1]='\r'
            elseif e=='t' then r[#r+1]='\t' else r[#r+1]=e end
        else r[#r+1]=c end
        i=i+1
    end
    return table.concat(r),i
end
local jVal
local function jObj(s,i)
    i=i+1; local r={}; i=jSkip(s,i)
    if s:sub(i,i)=='}' then return r,i+1 end
    while i<=#s do
        i=jSkip(s,i); if s:sub(i,i)~='"' then break end
        local k,ni=jStr(s,i); i=ni; i=jSkip(s,i)
        if s:sub(i,i)==':' then i=i+1 end; i=jSkip(s,i)
        local val,vi=jVal(s,i); r[k]=val; i=vi; i=jSkip(s,i)
        local ch=s:sub(i,i)
        if ch==',' then i=i+1 elseif ch=='}' then return r,i+1 else break end
    end
    return r,i
end
local function jArr(s,i)
    i=i+1; local r={}; i=jSkip(s,i)
    if s:sub(i,i)==']' then return r,i+1 end
    while i<=#s do
        i=jSkip(s,i); local val,vi=jVal(s,i); r[#r+1]=val; i=vi; i=jSkip(s,i)
        local ch=s:sub(i,i)
        if ch==',' then i=i+1 elseif ch==']' then return r,i+1 else break end
    end
    return r,i
end
jVal = function(s,i)
    i=jSkip(s,i); local c=s:sub(i,i)
    if c=='"' then return jStr(s,i)
    elseif c=='{' then return jObj(s,i)
    elseif c=='[' then return jArr(s,i)
    elseif s:sub(i,i+3)=='true'  then return true, i+4
    elseif s:sub(i,i+4)=='false' then return false,i+5
    elseif s:sub(i,i+3)=='null'  then return nil,  i+4
    else
        local ns=s:match("^-?%d+%.?%d*[eE]?[+-]?%d*",i)
        if ns then return tonumber(ns),i+#ns end
    end
    return nil,i+1
end
local function jsonDecode(s)
    if not s or s=="" then return nil end
    local ok,result=pcall(function() local v,_=jVal(s,1); return v end)
    return ok and result or nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Event queue
-- ─────────────────────────────────────────────────────────────────────────────
local function queueEvent(evType, data)
    if not TC.enabled then return end
    TC.eventQueue[#TC.eventQueue + 1] = {type = evType, data = data}
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Player data
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
-- Command handler (actions from bridge)
-- ─────────────────────────────────────────────────────────────────────────────
local function handleCommand(NH, action, args, requestId)
    args = args or {}
    if action == "sendMessage" then
        local ok = pcall(function() NH:broadcastSM("[Takaro] " .. (args.message or args.msg or ""), 0) end)
        return {requestId = requestId, result = {success = ok}}

    elseif action == "sendMessageToPlayer" then
        local ok = pcall(function() NH:messageSM("[Takaro] " .. (args.message or ""), tonumber(args.gameId)) end)
        return {requestId = requestId, result = {success = ok}}

    elseif action == "kickPlayer" then
        local ok,err = pcall(function() NH:kickPlayer(tonumber(args.gameId)) end)
        return {requestId = requestId, result = {success = ok, error = ok and nil or tostring(err)}}

    elseif action == "banPlayer" then
        local ok,err = pcall(function() NH:banPlayer(tonumber(args.gameId)) end)
        return {requestId = requestId, result = {success = ok, error = ok and nil or tostring(err)}}

    elseif action == "unbanPlayer" then
        local ok,err = pcall(function() NH:unbanPlayer(tonumber(args.gameId)) end)
        return {requestId = requestId, result = {success = ok, error = ok and nil or tostring(err)}}

    elseif action == "giveItem" then
        local gId = args.gameId or ""; local item = args.name or args.item or ""; local qty = tonumber(args.amount) or 1
        local ok,err = pcall(function()
            local PC = NH:getPlayerContainer()
            for i = 0, PC:getNPlayers()-1 do
                local P = PC:getPlayer(i)
                if P and tostring(P:getId()) == gId then P:getInventory():give(item, qty); return end
            end
            error("player not found")
        end)
        return {requestId = requestId, result = {success = ok, error = ok and nil or tostring(err)}}

    elseif action == "teleportPlayer" then
        local gId = args.gameId or ""
        local ok,err = pcall(function()
            local PC = NH:getPlayerContainer()
            for i = 0, PC:getNPlayers()-1 do
                local P = PC:getPlayer(i)
                if P and tostring(P:getId()) == gId then P:teleport2i(tonumber(args.x) or 0, tonumber(args.z) or 0); return end
            end
            error("player not found")
        end)
        return {requestId = requestId, result = {success = ok, error = ok and nil or tostring(err)}}

    elseif action == "executeCommand" or action == "executeConsoleCommand" then
        turf.printc("[TakaroConnector] executeCommand: " .. (args.command or ""))
        return {requestId = requestId, result = {success = true, rawResult = "dispatched: " .. (args.command or "")}}

    elseif action == "getPlayerLocation" then
        return {requestId = requestId, result = {x = 0, y = 0, z = 0}}

    elseif action == "getPlayerInventory" then
        local gId = tostring(args.gameId or "")
        local items = {}
        pcall(function()
            local PC = NH:getPlayerContainer()
            for i = 0, PC:getNPlayers()-1 do
                local P = PC:getPlayer(i)
                if P and tostring(P:getId()) == gId then
                    local Inv = P:getInventory()
                    if Inv then
                        for s = 0, Inv:getSize()-1 do
                            local I = Inv:getItemAt(s)
                            if I ~= nil then
                                local qok, qty = pcall(function() return Inv:get(s):getQuantity() end)
                                qty = (qok and tonumber(qty)) or 0
                                if qty > 0 then
                                    local code = tostring(Inv:getItemIdentifierAt(s) or "")
                                    local nm = code
                                    local nok, n = pcall(function() return I:getName() end)
                                    if nok and n and n ~= "" then nm = tostring(n) end
                                    if code == "" then code = nm end
                                    items[#items+1] = {name = nm, code = code, amount = qty}
                                end
                            end
                        end
                    end
                    break
                end
            end
        end)
        return {requestId = requestId, result = items}

    elseif action == "listItems" then
        return {requestId = requestId, result = {}}

    else
        return {requestId = requestId, result = {success = false, error = "Unknown action: " .. tostring(action)}}
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- onExternalMessage — global function called by engine when bridge sends a UDP packet
-- externalIpHandle has .host, .port, .id — pass back to NH:sendExternalMessage
-- ─────────────────────────────────────────────────────────────────────────────
function onExternalMessage(externalIpHandle, message)
    local ok, err = pcall(function()
        local NH = turf.NetworkHandler.getInstance()
        local msg = jsonDecode(message)
        if not msg then return end

        if msg.type == "poll" then
            local PC = NH:getPlayerContainer()
            local players = {}
            for i = 0, PC:getNPlayers()-1 do
                local pok, P = pcall(function() return PC:getPlayer(i) end)
                if pok and P then
                    local data = getPlayerData(P)
                    if data then
                        players[#players+1] = {gameId=data.gameId, name=data.name, steamId=data.steamId}
                    end
                end
            end
            local response = jsonEncode({events = TC.eventQueue, players = players})
            TC.eventQueue = {}
            NH:sendExternalMessage(externalIpHandle, response)

        elseif msg.type == "command" then
            local result = handleCommand(NH, msg.action or "", msg.args, msg.requestId)
            NH:sendExternalMessage(externalIpHandle, jsonEncode(result))
        end
    end)
    if not ok then print("[TC] ERROR: " .. tostring(err)) end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Roster scan (disconnect + death detection)
-- ─────────────────────────────────────────────────────────────────────────────
local function scanRoster(NH)
    local ok, err = pcall(function()
        local PC = NH:getPlayerContainer()
        local current = {}

        for i = 0, PC:getNPlayers()-1 do
            local pok, P = pcall(function() return PC:getPlayer(i) end)
            if pok and P then
                local data = getPlayerData(P)
                if data then
                    current[data.gameId] = true
                    local known = TC.knownPlayers[data.gameId]
                    if known and data.deaths > known.deaths then
                        queueEvent("player-death", {
                            player = {gameId=data.gameId, name=data.name, steamId=data.steamId}
                        })
                    end
                    TC.knownPlayers[data.gameId] = data
                end
            end
        end

        for gId, data in pairs(TC.knownPlayers) do
            if not current[gId] then
                queueEvent("player-disconnected", {
                    player = {gameId=gId, name=data.name, steamId=data.steamId}
                })
                TC.knownPlayers[gId] = nil
            end
        end
    end)
    if not ok then turf.printc("[TakaroConnector] scanRoster error: " .. tostring(err)) end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- onPlayerLogin_extra hook
-- ─────────────────────────────────────────────────────────────────────────────
local _prev_onPlayerLogin_extra = customFunc.onPlayerLogin_extra
customFunc.onPlayerLogin_extra = function(GMS, P)
    if _prev_onPlayerLogin_extra then _prev_onPlayerLogin_extra(GMS, P) end
    if not TC.enabled then return end
    local ok, err = pcall(function()
        local data = getPlayerData(P)
        if not data then return end
        TC.knownPlayers[data.gameId] = data
        queueEvent("player-connected", {
            player = {gameId=data.gameId, name=data.name, steamId=data.steamId}
        })
    end)
    if not ok then turf.printc("[TakaroConnector] login hook error: " .. tostring(err)) end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Chat capture
-- ─────────────────────────────────────────────────────────────────────────────
processCommandsUserCallback = processCommandsUserCallback or {}
table.insert(processCommandsUserCallback, {"TakaroConnector_chat", function(NH, P, command, argv)
    if not TC.enabled or not P or command ~= "" then return end
    local ok, err = pcall(function()
        local msg = (argv and argv[1]) or ""
        if msg == "" or msg:sub(1,1) == "/" then return end
        local data = getPlayerData(P)
        if not data then return end
        queueEvent("chat-message", {
            player  = {gameId=data.gameId, name=data.name, steamId=data.steamId},
            msg     = msg,
            channel = "global",
        })
    end)
    if not ok then turf.printc("[TakaroConnector] chat error: " .. tostring(err)) end
end})

-- ─────────────────────────────────────────────────────────────────────────────
-- /takarostatus admin command
-- ─────────────────────────────────────────────────────────────────────────────
defineServerCommandsUserCallback = defineServerCommandsUserCallback or {}
table.insert(defineServerCommandsUserCallback, {"TakaroConnector", function(NH) end})

table.insert(processCommandsUserCallback, {"TakaroConnector_status", function(NH, P, command, argv)
    if not P or command ~= "takarostatus" then return end
    if not P:isAdmin() then NH:messageSM("[TakaroConnector] Admin only.", P:getId()); return true end
    local n = 0; for _ in pairs(TC.knownPlayers) do n=n+1 end
    NH:messageSM(string.format("[TakaroConnector] enabled=%s queued_events=%d tracked_players=%d secret=%d",
        tostring(TC.enabled), #TC.eventQueue, n, TC.EXTERNAL_SECRET), P:getId())
    return true
end})

-- ─────────────────────────────────────────────────────────────────────────────
-- externalPoll — called by engine every server loop tick
-- ─────────────────────────────────────────────────────────────────────────────
function externalPoll()
    if not TC.enabled then return end
    TC.tickCount = TC.tickCount + 1
    if TC.tickCount % 4 == 0 then
        local ok, err = pcall(function()
            scanRoster(turf.NetworkHandler.getInstance())
        end)
        if not ok then turf.printc("[TakaroConnector] externalPoll error: " .. tostring(err)) end
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Register with defineExternalCommandsTable — engine calls defineExternalCommands
-- at startup which iterates this table to call setExternalSecret
-- ─────────────────────────────────────────────────────────────────────────────
print("[TC] takaro_connector.lua loaded OK")
defineExternalCommandsTable = defineExternalCommandsTable or {}
table.insert(defineExternalCommandsTable, {"TakaroConnector", function(NH)
    print("[TC] defineExternalCommands callback called")
    NH:setExternalSecret(TC.EXTERNAL_SECRET)
    turf.printc("[TakaroConnector] Ready. secret=" .. TC.EXTERNAL_SECRET)
end})
