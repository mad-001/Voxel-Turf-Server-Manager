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
-- Find the online player whose getId() matches a Takaro gameId.
local function pickActor(NH, gId)
    local found = nil
    pcall(function()
        local PC = NH:getPlayerContainer()
        for i = 0, PC:getNPlayers()-1 do
            local P = PC:get(i)
            if P and tostring(P:getId()) == gId then found = P; return end
        end
    end)
    return found
end

-- Pick an online admin/op (or any online player) to act as a console command issuer.
-- Voxel Turf's processCommand() gates every command on the issuing player's rank,
-- so console commands have to run "as" a real, sufficiently-privileged player.
local function pickAdmin(NH)
    local admin, anyP = nil, nil
    pcall(function()
        local PC = NH:getPlayerContainer()
        for i = 0, PC:getNPlayers()-1 do
            local P = PC:get(i)
            if P then
                if not anyP then anyP = P end
                if P:isAdmin() or P:isSOp() or P:isOp() or P:isHOp() then admin = P; return end
            end
        end
    end)
    return admin or anyP
end

-- Every Voxel Turf console command name (from server_commands.lua), plus help
-- aliases. Used to tell "is the first word a command, or a player name?" — if the
-- first word ISN'T in here it's treated as a target player: "Bob money 1000".
local VT_COMMANDS = {}
for _, c in ipairs({
    "give","giveinf","me","m","mode","save","credits","money","tp","lua","exit",
    "fill","replace","copy","rdecal","mirror","rotate","kick","ban","unban","ipban",
    "die","whitelist","unwhitelist","votekick","lot","lotrange","road","notoriety",
    "fly","reputation","exp","motd","loadout","assignmission","eliminate","annex",
    "yesman","ftick","specialbuild","heal","godmode","nofuzz","dungeonspawn",
    "revealdungeons","status","s","winmissions","marks","invisible","ddebug",
    "shutdown","stop","say","announce","broadcast","help","commands","?",
}) do VT_COMMANDS[c] = true end

-- Find an online player by (case-insensitive) name — lets a console command be run
-- on a specific player by naming them first: "<player> <command>".
local function pickActorByName(NH, name)
    if not name or name == "" then return nil end
    local target = string.lower(name)
    local found = nil
    pcall(function()
        local PC = NH:getPlayerContainer()
        for i = 0, PC:getNPlayers()-1 do
            local P = PC:get(i)
            if P and string.lower(tostring(P:getName() or "")) == target then found = P; return end
        end
    end)
    return found
end

-- Takaro sends the player ref unwrapped ({gameId}) for some actions and wrapped
-- ({player={gameId}}) for others — accept both.
local function argGameId(args)
    return tostring(args.gameId or (args.player and args.player.gameId) or "")
end

-- 'help' output: the Takaro actions plus the Voxel Turf console commands.
local function helpText()
    return table.concat({
        "=== Takaro -> Voxel Turf Console ===",
        "Syntax:  <command> <player> <args>",
        "  <player> = name, \"quoted name with spaces\", Steam ID, or game id.",
        "",
        "ECONOMY / ITEMS",
        "  money <player> <amount>         e.g. money Bob 1000  (max ~21,000,000)",
        "  credits <player> <amount>       e.g. credits Bob 500",
        "  give <player> <item> <amount>   e.g. give Bob wood 50",
        "  giveinf <player> <item>         e.g. giveinf Bob stone",
        "  reputation <player> <-100..100> e.g. reputation Bob 100",
        "  exp <player> <amount>           e.g. exp Bob 5000",
        "  marks <player> on|off|clear",
        "",
        "PLAYER STATE",
        "  heal <player>",
        "  godmode <player>                (toggle)",
        "  fly <player>                    (toggle)",
        "  invisible <player>              (toggle)",
        "  loadout <player>                (all weapons + explosives)",
        "  die <player>",
        "  tp <player> <x> <z>             e.g. tp Bob 100 200",
        "  tp <player> <x> <y> <z>         (with height)",
        "  mode <player> v|h|o|s|-v",
        "  m <player> <message>",
        "",
        "MODERATION",
        "  kick <player>",
        "  ban <player> [reason]",
        "  unban <player>",
        "  ipban <player> [reason]",
        "  whitelist <player>",
        "  unwhitelist <player>",
        "",
        "WORLD / SERVER",
        "  say <message>                   broadcast a chat message to everyone",
        "  save                            save the world now",
        "  shutdown                        stop the server (auto-restarts if start.bat loops)",
        "  motd <text>                     set the message of the day",
        "  me <text>                       emote in chat",
    }, "\n")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Direct console-command handlers.   Syntax: <command> <player> <args...>
-- The bridge resolves <player> (name/SteamID/gameId) and passes P (online player)
-- and targetName (resolved or raw name, for offline-capable bans). argv here is
-- {command, ...args} with the player ALREADY stripped, so argv[2] is the first arg.
-- Each handler applies the effect STRAIGHT to the target via the engine methods
-- (verified vs server_commands.lua), bypassing rank gating. Returns (ok, message).
-- ─────────────────────────────────────────────────────────────────────────────
local MONEY_LIM, CREDIT_LIM = 21474836, 2147483647

local function joinFrom(argv, startIdx, default)
    local r = argv[startIdx]
    if not r then return default end
    for i = startIdx + 1, #argv do r = r .. " " .. argv[i] end
    return r
end

local function joinRange(argv, s, e)
    if s > e or not argv[s] then return nil end
    local r = argv[s]
    for i = s + 1, e do r = r .. " " .. argv[i] end
    return r
end

local DIRECT = {}

-- ── Economy / items (act on the online target P) ─────────────────────────────
DIRECT.money = function(NH, P, argv)
    local amt = tonumber(argv[2]) or 1000000
    local note = ""
    if amt >  MONEY_LIM then amt =  MONEY_LIM; note = " (capped)" end
    if amt < -MONEY_LIM then amt = -MONEY_LIM; note = " (capped)" end
    P:getCredentials():transactMoney(amt * 100); P:setMoneyUpdateFlag(); P:markCheated()
    return true, "Gave $" .. string.format("%.0f", amt) .. note .. " to " .. P:getName()
end

DIRECT.credits = function(NH, P, argv)
    local amt = tonumber(argv[2]) or 1000000
    local note = ""
    if amt >  CREDIT_LIM then amt =  CREDIT_LIM; note = " (capped)" end
    if amt < -CREDIT_LIM then amt = -CREDIT_LIM; note = " (capped)" end
    P:getCredentials():transactCredits(amt); P:setMoneyUpdateFlag(); P:markCheated()
    return true, "Gave C" .. string.format("%.0f", amt) .. note .. " to " .. P:getName()
end

DIRECT.give = function(NH, P, argv)
    -- argv = {give, <item words...>, <amount?>}. Item names have spaces, so the trailing
    -- token is the amount only if numeric; everything else (argv[2..]) is the item name.
    local n = #argv
    local qty, itemEnd = 1, n
    local last = tonumber(argv[n])
    if last and n >= 3 then qty = last; itemEnd = n - 1 end
    local itemName = joinRange(argv, 2, itemEnd)
    if not itemName then return false, "give <player> <item> <amount>" end
    local ITC = NH:getItemTypeContainer()
    local id = ITC:getIdByName(itemName)
    if id == turf.ItemTypeContainer.I_NONE then return false, "Unknown item: " .. itemName end
    if qty < 1 then qty = 1 end
    local maxStack = ITC:get(id):getStackSize()
    if maxStack and qty > maxStack then qty = maxStack end
    P:getInventory():give(id, qty); P:getInventory():setClientUpdateFlag(true); P:markCheated()
    return true, "Gave " .. qty .. " " .. itemName .. " to " .. P:getName()
end

DIRECT.giveinf = function(NH, P, argv)
    local itemName = joinRange(argv, 2, #argv)
    if not itemName then return false, "giveinf <player> <item>" end
    local ITC = NH:getItemTypeContainer()
    local id = ITC:getIdByName(itemName)
    if id == turf.ItemTypeContainer.I_NONE then return false, "Unknown item: " .. itemName end
    P:getInventory():give(id, 255); P:getInventory():setClientUpdateFlag(true); P:markCheated()
    return true, "Gave INF " .. itemName .. " to " .. P:getName()
end

DIRECT.heal = function(NH, P, argv)
    P:getRpgStats():addHp(P:getRpgStats().maxHp); P:markCheated()
    return true, "Healed " .. P:getName()
end

DIRECT.reputation = function(NH, P, argv)
    local amt = (tonumber(argv[2]) or 100) * 100
    if amt >  10000 then amt =  10000 end
    if amt < -10000 then amt = -10000 end
    P:getCredentials():setReputationDirectly(amt); P:setMoneyUpdateFlag(); P:markCheated()
    return true, P:getName() .. " reputation = " .. tostring(amt / 100)
end

DIRECT.exp = function(NH, P, argv)
    local amt = tonumber(argv[2]) or 1000
    if amt < 0 then amt = 0 end
    P:getCredentials():addExperience(amt); P:setMoneyUpdateFlag(); P:markCheated()
    return true, P:getName() .. " gained " .. tostring(amt) .. " exp"
end

DIRECT.marks = function(NH, P, argv)
    local a = argv[2]
    if a == "on"  then P:setMarksEnabled(true);  return true, "Marks enabled for "  .. P:getName() end
    if a == "off" then P:setMarksEnabled(false); return true, "Marks disabled for " .. P:getName() end
    if a == "clear" or a == "c" then P:clearMarks(); return true, "Marks cleared for " .. P:getName() end
    return false, "marks <player> on|off|clear"
end

DIRECT.loadout = function(NH, P, argv)
    local inv = P:getInventory()
    inv:give(1283, 80)
    inv:give(12000,6); inv:give(12006,21); inv:give(12012,4); inv:give(12018,55); inv:give(12024,5)
    inv:give(12030,1); inv:give(12032,2); inv:give(12034,1); inv:give(12036,4)
    inv:give(12003,255); inv:give(12009,255); inv:give(12015,255); inv:give(12021,255); inv:give(12027,255)
    inv:give(12031,255); inv:give(12033,255); inv:give(12035,255); inv:give(12037,255)
    inv:give(12039,2); inv:give(12040,2); inv:give(12041,2); inv:give(12046,2); inv:give(12049,2)
    inv:setClientUpdateFlag(true)
    P:getCredentials():addExperience(2000); P:setMoneyUpdateFlag(); P:markCheated()
    return true, "Gave loadout to " .. P:getName()
end

-- ── Player-state toggles (act on the online target P) ────────────────────────
DIRECT.fly = function(NH, P, argv)
    local c = P:getCredentials(); c.flyEnabled = not c.flyEnabled; P:markCheated()
    return true, P:getName() .. (c.flyEnabled and " fly ON" or " fly OFF")
end

DIRECT.godmode = function(NH, P, argv)
    local c = P:getCredentials(); c.godMode = not c.godMode; P:markCheated()
    return true, P:getName() .. (c.godMode and " godmode ON" or " godmode OFF")
end

DIRECT.invisible = function(NH, P, argv)
    local c = P:getCredentials(); c.invisibleEnabled = not c.invisibleEnabled; P:markCheated()
    return true, P:getName() .. (c.invisibleEnabled and " invisible ON" or " invisible OFF")
end

DIRECT.die = function(NH, P, argv)
    P:dealDamage(1000)
    return true, P:getName() .. " was killed"
end

DIRECT.tp = function(NH, P, argv)
    local x  = tonumber(argv[2])
    local v2 = tonumber(argv[3])
    local v3 = tonumber(argv[4])
    if not x or not v2 then return false, "tp <player> <x> <z>  (or <x> <y> <z>)" end
    if v3 then P:teleport3i(x, v2, v3) else P:teleport2i(x, v2) end
    P:markCheated()
    return true, "Teleported " .. P:getName()
end

DIRECT.m = function(NH, P, argv)
    local msg = joinFrom(argv, 2, nil)
    if not msg then return false, "m <player> <message>" end
    NH:messageSM("[Takaro] " .. msg, P:getId())
    return true, "Sent to " .. P:getName() .. ": " .. msg
end

DIRECT.mode = function(NH, P, argv)
    local m = argv[2]
    local val
    if     m == "-v" or m == "0" then val = 0
    elseif m == "v" then val = turf.NetworkHandler.MODE_VOICE
    elseif m == "h" then val = turf.NetworkHandler.MODE_HOP
    elseif m == "o" then val = turf.NetworkHandler.MODE_OP
    elseif m == "s" then val = turf.NetworkHandler.MODE_SOP
    else return false, "mode <player> v|h|o|s|-v" end
    P:setMode(val)
    return true, P:getName() .. " mode -> " .. tostring(m)
end

DIRECT.kick = function(NH, P, argv)
    if NH:kickPlayer(P:getName()) then return true, "Kicked " .. P:getName() end
    return false, "Could not kick " .. P:getName()
end

-- ── Moderation by name (targetName may be an OFFLINE player) ──────────────────
DIRECT.ban = function(NH, P, argv, tn)
    if not tn then return false, "ban <player> [reason]" end
    local reason = joinFrom(argv, 2, "Banned via Takaro")
    local r = NH:banPlayer(tn, NH:getPlayerContainer():getIdByNameCi(tn), reason, "Takaro")
    return true, (type(r) == "string" and r) or ("Banned " .. tn)
end

DIRECT.unban = function(NH, P, argv, tn)
    if not tn then return false, "unban <player>" end
    local r = NH:unbanPlayer(tn, NH:getPlayerContainer():getIdByNameCi(tn))
    return true, (type(r) == "string" and r) or ("Unbanned " .. tn)
end

DIRECT.ipban = function(NH, P, argv, tn)
    if not tn then return false, "ipban <player> [reason]" end
    local reason = joinFrom(argv, 2, "IP banned via Takaro")
    local r = NH:ipBanPlayer(tn, reason, "Takaro")
    return true, (type(r) == "string" and r) or ("IP-banned " .. tn)
end

DIRECT.whitelist = function(NH, P, argv, tn)
    if not tn then return false, "whitelist <player>" end
    local r = NH:whitelistPlayer(tn, NH:getPlayerContainer():getIdByNameCi(tn), "", "Takaro")
    return true, (type(r) == "string" and r) or ("Whitelisted " .. tn)
end

DIRECT.unwhitelist = function(NH, P, argv, tn)
    if not tn then return false, "unwhitelist <player>" end
    local r = NH:unwhitelistPlayer(tn, NH:getPlayerContainer():getIdByNameCi(tn), "", "Takaro")
    return true, (type(r) == "string" and r) or ("Unwhitelisted " .. tn)
end

-- ── World / server (no target player) ────────────────────────────────────────
DIRECT.save = function(NH, P, argv)
    NH:broadcastSM("Saving...", turf.WorldObj.ALL_WORLDS)
    NH:getMultiverse():FullSave()
    NH:broadcastSM("Save complete", turf.WorldObj.ALL_WORLDS)
    return true, "Saved the world"
end

DIRECT.motd = function(NH, P, argv)
    local str = joinFrom(argv, 2, nil)
    if not str then return false, "motd <text>" end
    NH:setMessageOfTheDay(str)
    return true, "MOTD set: " .. str
end

DIRECT.shutdown = function(NH, P, argv)
    NH:broadcastSM("Server shutting down (Takaro)...", turf.WorldObj.ALL_WORLDS)
    NH:flagShutdown()
    return true, "Server shutting down"
end
DIRECT.stop = DIRECT.shutdown
DIRECT.exit = DIRECT.shutdown

-- say/announce/broadcast: send a chat message to EVERY player on the server.
DIRECT.say = function(NH, P, argv)
    local msg = joinFrom(argv, 2, nil)
    if not msg then return false, "say <message>" end
    NH:broadcastSM(msg, turf.WorldObj.ALL_WORLDS)
    return true, "Broadcast: " .. msg
end
DIRECT.announce  = DIRECT.say
DIRECT.broadcast = DIRECT.say

-- Commands whose 2nd token is a player who must be ONLINE (we operate on P).
local DIRECT_NEEDS_P = {
    money=true, credits=true, give=true, giveinf=true, heal=true, reputation=true,
    exp=true, marks=true, loadout=true, fly=true, godmode=true, invisible=true,
    die=true, tp=true, m=true, mode=true, kick=true,
}
-- Moderation by name — target may be offline (we use targetName, not P).
local DIRECT_NEEDS_NAME = {
    ban=true, unban=true, ipban=true, whitelist=true, unwhitelist=true,
}

local function handleCommand(NH, action, args, requestId)
    args = args or {}
    if action == "shutdown" then
        local ok = pcall(function()
            NH:broadcastSM("Server shutting down (Takaro)...", turf.WorldObj.ALL_WORLDS)
            NH:flagShutdown()
        end)
        return {requestId = requestId, result = {success = ok}}

    elseif action == "sendMessage" then
        local ok = pcall(function() NH:broadcastSM("[Takaro] " .. (args.message or args.msg or ""), turf.WorldObj.ALL_WORLDS) end)
        return {requestId = requestId, result = {success = ok}}

    elseif action == "sendMessageToPlayer" then
        local gId = argGameId(args)
        local ok = pcall(function() NH:messageSM("[Takaro] " .. (args.message or ""), tonumber(gId)) end)
        return {requestId = requestId, result = {success = ok}}

    elseif action == "kickPlayer" then
        local gId = argGameId(args)
        local ok,err = pcall(function()
            local P = pickActor(NH, gId)
            if not P then error("player not online") end
            NH:kickPlayer(P:getId())
        end)
        return {requestId = requestId, result = {success = ok, error = ok and nil or tostring(err)}}

    elseif action == "banPlayer" then
        local gId = argGameId(args)
        local reason = tostring(args.reason or "Banned via Takaro")
        local ok,err = pcall(function()
            local P = pickActor(NH, gId)
            if P then NH:banPlayer(P:getName(), P:getId(), reason, "Takaro"); return end
            local nm = args.player and args.player.name
            if nm and nm ~= "" then NH:banPlayer(nm, NH:getPlayerContainer():getIdByNameCi(nm), reason, "Takaro"); return end
            error("player not found")
        end)
        return {requestId = requestId, result = {success = ok, error = ok and nil or tostring(err)}}

    elseif action == "unbanPlayer" then
        local nm = (args.player and args.player.name) or args.name or ""
        local ok,err = pcall(function()
            if nm == "" then error("unban requires a player name") end
            NH:unbanPlayer(nm, NH:getPlayerContainer():getIdByNameCi(nm), "", "Takaro")
        end)
        return {requestId = requestId, result = {success = ok, error = ok and nil or tostring(err)}}

    elseif action == "giveItem" then
        local gId = argGameId(args)
        local itemName = tostring(args.item or args.name or "")
        local qty = tonumber(args.amount) or 1
        local ok,err = pcall(function()
            local ITC = NH:getItemTypeContainer()
            local id = ITC:getIdByName(itemName)
            if id == turf.ItemTypeContainer.I_NONE then error("unknown item: " .. itemName) end
            local P = pickActor(NH, gId)
            if not P then error("player not online") end
            if qty < 1 then qty = 1 end
            local maxStack = ITC:get(id):getStackSize()
            if maxStack and qty > maxStack then qty = maxStack end
            P:getInventory():give(id, qty)
            P:getInventory():setClientUpdateFlag(true)
            P:markCheated()
        end)
        return {requestId = requestId, result = {success = ok, error = ok and nil or tostring(err)}}

    elseif action == "teleportPlayer" then
        local gId = argGameId(args)
        local ok,err = pcall(function()
            local P = pickActor(NH, gId)
            if not P then error("player not online") end
            local x = tonumber(args.x) or 0
            local y = tonumber(args.y)
            local z = tonumber(args.z) or 0
            if y then P:teleport3i(x, y, z) else P:teleport2i(x, z) end
            P:markCheated()
        end)
        return {requestId = requestId, result = {success = ok, error = ok and nil or tostring(err)}}

    elseif action == "executeCommand" or action == "executeConsoleCommand" then
        -- Syntax: <command> <player> <args>. The bridge has already resolved <player>
        -- (name/SteamID/gameId), stripped it from args.command, and passed args.asGameId
        -- (online player) and/or args.asPlayer (resolved or raw name for offline bans).
        local raw = tostring(args.command or args.rawCommand or args.message or "")
        local tokens = {}
        for tok in raw:gmatch("%S+") do tokens[#tokens+1] = tok end
        local cmdName = string.lower(tokens[1] or "")
        if cmdName == "" then
            return {requestId = requestId, result = {success = false, rawResult = "", errorMessage = "Empty command. Try 'help'."}}
        end
        if cmdName == "help" or cmdName == "commands" or cmdName == "?" then
            return {requestId = requestId, result = {success = true, rawResult = helpText()}}
        end

        local asGameId   = args.asGameId and tostring(args.asGameId) or nil
        local targetName = args.asPlayer and tostring(args.asPlayer) or nil
        local P = (asGameId and asGameId ~= "") and pickActor(NH, asGameId) or nil

        local handler = DIRECT[cmdName]
        if handler then
            if DIRECT_NEEDS_P[cmdName] and not P then
                return {requestId = requestId, result = {success = false, rawResult = "",
                    errorMessage = "Player not online for '" .. cmdName .. "'. Usage: " .. cmdName .. " <player> ..."}}
            end
            if DIRECT_NEEDS_NAME[cmdName] and not targetName then
                return {requestId = requestId, result = {success = false, rawResult = "",
                    errorMessage = "Usage: " .. cmdName .. " <player> ..."}}
            end
            local hok, ok, msg = pcall(handler, NH, P, tokens, targetName)
            if not hok then
                return {requestId = requestId, result = {success = false, rawResult = "", errorMessage = tostring(ok)}}
            end
            if ok then
                return {requestId = requestId, result = {success = true, rawResult = tostring(msg)}}
            end
            return {requestId = requestId, result = {success = false, rawResult = "", errorMessage = tostring(msg)}}
        end

        -- Fallback for commands we don't reimplement (build tools: fill/replace/copy/
        -- rotate/mirror/lot/road/..., and `me`). These act on the admin running them.
        if type(processCommand) ~= "function" then
            return {requestId = requestId, result = {success = false, rawResult = "", errorMessage = "processCommand unavailable"}}
        end
        local Padmin = pickAdmin(NH)
        if not Padmin then
            return {requestId = requestId, result = {success = false, rawResult = "",
                errorMessage = "No online admin to run '" .. cmdName .. "'. Have an admin online."}}
        end
        local ret = ""
        local cok,cerr = pcall(function()
            local r = processCommand(NH, Padmin, cmdName, tokens, raw)
            if type(r) == "string" then ret = r end
        end)
        if cok then
            if ret == "" then ret = "OK: " .. raw end
            return {requestId = requestId, result = {success = true, rawResult = ret}}
        end
        return {requestId = requestId, result = {success = false, rawResult = "", errorMessage = tostring(cerr)}}

    elseif action == "getPlayerLocation" then
        -- Always return a valid IPosition. A falsy/empty payload makes Takaro
        -- reject it ("No payload provided but expected DTO: IPosition").
        local gId = argGameId(args)
        local pos = {x = 0, y = 0, z = 0, dimension = "0"}
        local P = pickActor(NH, gId)
        if P then
            pcall(function()
                local function r2(v) return math.floor(v * 100 + 0.5) / 100 end
                pos = {x = r2(P:getPos(0)), y = r2(P:getPos(1)), z = r2(P:getPos(2)), dimension = tostring(P:getWorldId())}
            end)
        end
        return {requestId = requestId, result = pos}

    elseif action == "getPlayerInventory" then
        local gId = argGameId(args)
        local items = {}
        pcall(function()
            local PC = NH:getPlayerContainer()
            for i = 0, PC:getNPlayers()-1 do
                local P = PC:get(i)
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
        -- Enumerate the item catalog in batches (the N_EXTERNAL reply is ONE datagram,
        -- so the bridge calls repeatedly with args.start and stitches the result, then
        -- caches it to items.json at startup). Only include items whose name round-trips
        -- through getIdByName -> id; that filters sentinels/duplicates AND guarantees the
        -- name actually works with `give`.
        local ITC = NH:getItemTypeContainer()
        local startId = math.floor(tonumber(args.start) or 1)
        local MAX_ID, BATCH = 30000, 12   -- small batch: the N_EXTERNAL reply is ONE small datagram
        local items = {}
        local id = startId
        while id <= MAX_ID and #items < BATCH do
            local item = nil
            pcall(function() item = ITC:get(id) end)
            if item ~= nil then
                local nm = nil
                local disabled = false
                pcall(function() disabled = item.isDisabled and true or false end)
                pcall(function() nm = item:getName() end)
                -- Only include items whose name round-trips through getIdByName -> id.
                -- That filters sentinels/dupes AND guarantees the name works with `give`
                -- and the Takaro shop (names are the exact, case-sensitive give-codes).
                if nm and nm ~= "" and not disabled and ITC:getIdByName(nm) == id then
                    items[#items + 1] = {name = nm, code = nm}
                end
            end
            id = id + 1
        end
        local nextId = (id <= MAX_ID) and id or 0   -- 0 = done (JSON has no nil in arrays)
        return {requestId = requestId, result = {items = items, nextId = nextId}}

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
                local pok, P = pcall(function() return PC:get(i) end)
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
        local now = turf.Timestamp.getTimestamp()
        local current = {}

        for i = 0, PC:getNPlayers()-1 do
            local pok, P = pcall(function() return PC:get(i) end)
            if pok and P then
                local data = getPlayerData(P)
                if data then
                    current[data.gameId] = true
                    local known = TC.knownPlayers[data.gameId]
                    if not known then
                        -- First scan that actually sees this player in the roster -> connected.
                        -- Connect is detected HERE (not in onPlayerLogin_extra) because the
                        -- login hook fires before the player is in the container, which raced
                        -- the disconnect check and produced a connect->disconnect flicker.
                        queueEvent("player-connected", {
                            player = {gameId=data.gameId, name=data.name, steamId=data.steamId}
                        })
                    elseif data.deaths > known.deaths then
                        queueEvent("player-death", {
                            player = {gameId=data.gameId, name=data.name, steamId=data.steamId}
                        })
                    end
                    data.lastSeen = now
                    TC.knownPlayers[data.gameId] = data
                end
            end
        end

        -- Disconnect only after the player has been absent for a grace period.
        -- scanRoster runs off externalPoll (many times per second), so this MUST be
        -- time-based, not scan-count based, or a brief roster gap reads as a leave.
        for gId, data in pairs(TC.knownPlayers) do
            if not current[gId] then
                if not data.lastSeen then
                    data.lastSeen = now
                elseif data.lastSeen:getDelta(now) > 6000 then  -- 6s absent
                    queueEvent("player-disconnected", {
                        player = {gameId=gId, name=data.name, steamId=data.steamId}
                    })
                    TC.knownPlayers[gId] = nil
                end
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
    -- player-connected is detected in scanRoster (roster-based) to avoid the
    -- login race that flickered connect->disconnect. Nothing to do here.
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Chat capture
-- ─────────────────────────────────────────────────────────────────────────────
processCommandsUserCallback = processCommandsUserCallback or {}
table.insert(processCommandsUserCallback, {"TakaroConnector_chat", function(NH, P, command, argv)
    if not TC.enabled or not P or command ~= "" then return end
    local ok, err = pcall(function()
        -- VoxelTurf passes the chat line tokenised in argv, so a multi-word
        -- message arrives as argv[1], argv[2], ... Rejoin them or only the
        -- first word reaches Takaro.
        local msg = ""
        if argv then
            for i = 1, #argv do
                if msg == "" then msg = tostring(argv[i]) else msg = msg .. " " .. tostring(argv[i]) end
            end
        end
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
