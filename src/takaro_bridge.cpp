// takaro_bridge.cpp — VoxelTurf <-> Takaro bridge, embedded in winmm.dll.
// C++ port of bridge.js. Replaces the separate bridge.exe: runs in-process, talks to
// Takaro over a WinHTTP secure WebSocket (TLS + framing handled by the OS) and to the
// game over the N_EXTERNAL UDP API. No Node, no external libs.
//
// Entry point: StartTakaroBridge()  — call once from a worker thread on DLL load.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winhttp.h>
#include <winsock2.h>
#include <ws2tcpip.h>

#include <string>
#include <vector>
#include <map>
#include <mutex>
#include <atomic>
#include <thread>
#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <ctime>
#include <sys/stat.h>

#include "json.hpp"
using nlohmann::json;

namespace {

// ─── Config ────────────────────────────────────────────────────────────────────
std::string IDENTITY_TOKEN, REGISTRATION_TOKEN;
std::string GAME_HOST = "127.0.0.1";
int   GAME_PORT       = 5728;
unsigned int EXTERNAL_SECRET = 123456;
int   POLL_INTERVAL_MS = 2000;
bool  ENABLED          = true;

std::string g_gameDir, g_configPath, g_logPath, g_statusPath, g_saveDir;

// ─── State ─────────────────────────────────────────────────────────────────────
std::atomic<bool> g_running{true};
std::atomic<bool> g_connected{false};
std::atomic<bool> g_startupSent{false};

HINTERNET g_wsSession = NULL, g_wsConn = NULL, g_ws = NULL;
std::mutex g_wsMutex;     // guards g_ws + sends
std::mutex g_udpMutex;    // serialises UDP request/reply
std::mutex g_logMutex;
std::mutex g_cacheMutex;

SOCKET g_udp = INVALID_SOCKET;

struct PlayerInfo { std::string gameId, name, steamId; };
std::map<std::string, PlayerInfo> g_players;   // by gameId

json       g_itemsCache = json::array();       // item catalog, enumerated once at startup
std::mutex g_itemsMutex;

const uint64_t STEAM64_BASE = 76561197960265728ULL;

// ─── Logging ───────────────────────────────────────────────────────────────────
std::string nowStamp() {
    SYSTEMTIME st; GetSystemTime(&st);
    char b[40];
    _snprintf(b, sizeof(b), "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
              st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, st.wMilliseconds);
    return b;
}

void logmsg(const std::string& m) {
    std::lock_guard<std::mutex> lk(g_logMutex);
    std::string line = nowStamp() + " " + m + "\n";
    FILE* f = fopen(g_logPath.c_str(), "ab");
    if (f) { fwrite(line.data(), 1, line.size(), f); fclose(f); }
}

// ─── Path / config helpers ──────────────────────────────────────────────────────
std::string trim(const std::string& s) {
    size_t a = s.find_first_not_of(" \t\r\n");
    if (a == std::string::npos) return "";
    size_t b = s.find_last_not_of(" \t\r\n");
    return s.substr(a, b - a + 1);
}

void computePaths() {
    char exe[MAX_PATH]; GetModuleFileNameA(NULL, exe, MAX_PATH);
    char* sl = strrchr(exe, '\\'); if (sl) *sl = '\0';
    g_gameDir    = exe;
    g_configPath = g_gameDir + "\\mods\\TakaroConnector\\TakaroConfig.txt";
    g_logPath    = g_gameDir + "\\mods\\TakaroConnector\\bridge.log";
    g_statusPath = g_gameDir + "\\logs\\server_status.txt";
    g_saveDir    = g_gameDir + "\\savegames";
}

void loadConfig() {
    FILE* f = fopen(g_configPath.c_str(), "rb");
    if (!f) return;
    std::string data; char buf[4096]; size_t n;
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0) data.append(buf, n);
    fclose(f);
    std::map<std::string, std::string> cfg;
    size_t pos = 0;
    while (pos < data.size()) {
        size_t nl = data.find('\n', pos);
        std::string line = trim(data.substr(pos, nl == std::string::npos ? std::string::npos : nl - pos));
        pos = (nl == std::string::npos) ? data.size() : nl + 1;
        if (line.empty() || line[0] == '#') continue;
        size_t eq = line.find('=');
        if (eq == std::string::npos) continue;
        cfg[trim(line.substr(0, eq))] = trim(line.substr(eq + 1));
    }
    auto get = [&](const char* k) -> std::string {
        auto it = cfg.find(k); return it == cfg.end() ? std::string() : it->second;
    };
    IDENTITY_TOKEN     = !get("SERVER_NAME").empty() ? get("SERVER_NAME") : get("IDENTITY_TOKEN");
    REGISTRATION_TOKEN = get("REGISTRATION_TOKEN");
    if (!get("GAME_HOST").empty())       GAME_HOST       = get("GAME_HOST");
    if (!get("GAME_PORT").empty())       GAME_PORT       = atoi(get("GAME_PORT").c_str());
    if (!get("EXTERNAL_SECRET").empty()) EXTERNAL_SECRET = (unsigned)strtoul(get("EXTERNAL_SECRET").c_str(), NULL, 10);
    if (!get("POLL_INTERVAL_MS").empty())POLL_INTERVAL_MS= atoi(get("POLL_INTERVAL_MS").c_str());
    std::string en = get("ENABLED");
    if (!en.empty()) ENABLED = (en != "false" && en != "0");
}

// Rotate bridge.log on startup; keep the newest 5 archives.
void rotateLog() {
    struct _stat64 stx;
    if (_stat64(g_logPath.c_str(), &stx) != 0) return;
    SYSTEMTIME st; GetLocalTime(&st);
    char ts[40];
    _snprintf(ts, sizeof(ts), "bridge_%04d-%02d-%02dT%02d-%02d-%02d-%03d.log",
              st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, st.wMilliseconds);
    std::string dir = g_gameDir + "\\mods\\TakaroConnector\\";
    MoveFileA(g_logPath.c_str(), (dir + ts).c_str());
    // keep newest 5
    std::vector<std::pair<long long, std::string>> arcs;
    WIN32_FIND_DATAA fd; HANDLE h = FindFirstFileA((dir + "bridge_*.log").c_str(), &fd);
    if (h != INVALID_HANDLE_VALUE) {
        do {
            ULARGE_INTEGER t; t.LowPart = fd.ftLastWriteTime.dwLowDateTime; t.HighPart = fd.ftLastWriteTime.dwHighDateTime;
            arcs.push_back({(long long)t.QuadPart, dir + fd.cFileName});
        } while (FindNextFileA(h, &fd));
        FindClose(h);
    }
    std::sort(arcs.begin(), arcs.end(), [](auto& a, auto& b){ return a.first > b.first; });
    for (size_t i = 5; i < arcs.size(); i++) DeleteFileA(arcs[i].second.c_str());
}

std::string toSteamId64(const std::string& acct) {
    std::string s = trim(acct);
    if (s.empty()) return "";
    for (char c : s) if (c < '0' || c > '9') return s;   // non-numeric -> leave
    uint64_t n = strtoull(s.c_str(), NULL, 10);
    if (n < STEAM64_BASE) n += STEAM64_BASE;
    char b[32]; _snprintf(b, sizeof(b), "%llu", (unsigned long long)n);
    return b;
}

// ─── UDP to the game ─────────────────────────────────────────────────────────────
// Returns the parsed reply, or a null json on timeout/error. Serialised by g_udpMutex.
json udpRequest(const json& payload) {
    std::lock_guard<std::mutex> lk(g_udpMutex);
    if (g_udp == INVALID_SOCKET) return json();

    std::string body = payload.dump();
    std::vector<char> pkt;
    pkt.push_back((char)103);
    unsigned int sec = EXTERNAL_SECRET;
    pkt.push_back((char)(sec & 0xFF)); pkt.push_back((char)((sec >> 8) & 0xFF));
    pkt.push_back((char)((sec >> 16) & 0xFF)); pkt.push_back((char)((sec >> 24) & 0xFF));
    pkt.insert(pkt.end(), body.begin(), body.end());

    sockaddr_in addr{}; addr.sin_family = AF_INET; addr.sin_port = htons((u_short)GAME_PORT);
    inet_pton(AF_INET, GAME_HOST.c_str(), &addr.sin_addr);

    if (sendto(g_udp, pkt.data(), (int)pkt.size(), 0, (sockaddr*)&addr, sizeof(addr)) == SOCKET_ERROR)
        return json();

    std::vector<char> rbuf(65536);
    int got = recvfrom(g_udp, rbuf.data(), (int)rbuf.size(), 0, NULL, NULL);
    if (got <= 1) return json();   // <=1 means just the opcode or nothing
    try {
        return json::parse(std::string(rbuf.data() + 1, got - 1));   // strip opcode byte
    } catch (...) { return json(); }
}

// ─── WebSocket send ──────────────────────────────────────────────────────────────
bool wsSend(const json& obj) {
    std::string s = obj.dump();
    std::lock_guard<std::mutex> lk(g_wsMutex);
    if (!g_ws) return false;
    DWORD rc = WinHttpWebSocketSend(g_ws, WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE,
                                    (PVOID)s.data(), (DWORD)s.size());
    return rc == 0;
}

void sendResponse(const std::string& requestId, const json& payload) {
    wsSend(json{{"type","response"},{"requestId",requestId},{"payload",payload}});
}

void sendEvent(const std::string& type, json data) {
    if (!g_connected) return;
    if (!data.is_object()) data = json::object();
    data["type"] = type;                       // data: { type, ...data }
    wsSend(json{{"type","gameEvent"},{"payload",{{"type",type},{"data",data}}}});
    logmsg("Event -> Takaro: " + type);
}

void sendLog(const std::string& msg) {
    if (!g_connected) { logmsg("(log event queued, not yet connected) " + msg); return; }
    wsSend(json{{"type","gameEvent"},{"payload",{{"type","log"},{"data",{{"type","log"},{"msg",msg}}}}}});
    logmsg("Event -> Takaro: log :: " + msg);
}

// ─── Console help + targeting (ported from bridge.js) ────────────────────────────
const char* HELP_TEXT =
"=== Takaro -> Voxel Turf Console ===\n"
"Syntax:  <command> <player> <args>\n"
"  <player> = name, \"quoted name with spaces\", Steam ID, or game id.\n"
"\n"
"ECONOMY / ITEMS\n"
"  money <player> <amount>         e.g. money Bob 1000  (max ~21,000,000)\n"
"  credits <player> <amount>       e.g. credits Bob 500\n"
"  give <player> <item> <amount>   e.g. give Bob wood 50\n"
"  giveinf <player> <item>         e.g. giveinf Bob stone\n"
"  reputation <player> <-100..100> e.g. reputation Bob 100\n"
"  exp <player> <amount>           e.g. exp Bob 5000\n"
"  marks <player> on|off|clear\n"
"\n"
"PLAYER STATE\n"
"  heal <player>\n"
"  godmode <player>                (toggle)\n"
"  fly <player>                    (toggle)\n"
"  invisible <player>              (toggle)\n"
"  loadout <player>                (all weapons + explosives)\n"
"  die <player>\n"
"  tp <player> <x> <z>             e.g. tp Bob 100 200\n"
"  tp <player> <x> <y> <z>         (with height)\n"
"  mode <player> v|h|o|s|-v\n"
"  m <player> <message>\n"
"\n"
"MODERATION\n"
"  kick <player>\n"
"  ban <player> [reason]\n"
"  unban <player>\n"
"  ipban <player> [reason]\n"
"  whitelist <player>\n"
"  unwhitelist <player>\n"
"\n"
"WORLD / SERVER\n"
"  say <message>                   broadcast a chat message to everyone\n"
"  save                            save the world now\n"
"  shutdown                        stop the server (auto-restarts if start.bat loops)\n"
"  motd <text>                     set the message of the day\n"
"  me <text>                       emote in chat";

bool isVtCommand(const std::string& c) {
    static const char* CMDS[] = {
        "give","giveinf","me","m","mode","save","credits","money","tp","lua","exit",
        "fill","replace","copy","rdecal","mirror","rotate","kick","ban","unban","ipban",
        "die","whitelist","unwhitelist","votekick","lot","lotrange","road","notoriety",
        "fly","reputation","exp","motd","loadout","assignmission","eliminate","annex",
        "yesman","ftick","specialbuild","heal","godmode","nofuzz","dungeonspawn",
        "revealdungeons","status","s","winmissions","marks","invisible","ddebug",
        "shutdown","stop","say","announce","broadcast","help","commands","?", NULL };
    for (int i = 0; CMDS[i]; i++) if (c == CMDS[i]) return true;
    return false;
}

std::string lower(std::string s) { for (auto& c : s) c = (char)tolower((unsigned char)c); return s; }

void parseFirstToken(const std::string& in, std::string& first, std::string& rest, bool& quoted) {
    std::string s = trim(in);
    quoted = false;
    if (!s.empty() && (s[0] == '"' || s[0] == '\'')) {
        char q = s[0]; size_t end = s.find(q, 1);
        if (end != std::string::npos) {
            first = s.substr(1, end - 1);
            rest = trim(s.substr(end + 1));
            quoted = true;
            return;
        }
    }
    size_t sp = s.find_first_of(" \t");
    if (sp == std::string::npos) { first = s; rest = ""; }
    else { first = s.substr(0, sp); rest = trim(s.substr(sp + 1)); }
}

// Resolve a player from the cache by gameId / SteamID64 / platformId / name.
bool resolvePlayer(const std::string& token, PlayerInfo& out) {
    std::string t = trim(token), tl = lower(t);
    std::lock_guard<std::mutex> lk(g_cacheMutex);
    for (auto& kv : g_players) {
        const PlayerInfo& p = kv.second;
        std::string sid = p.steamId, gid = p.gameId;
        if (gid == t) { out = p; return true; }
        if (!sid.empty() && sid == t) { out = p; return true; }
        if (!sid.empty() && ("voxelturf:" + sid) == tl) { out = p; return true; }
        if (lower("voxelturf:" + gid) == tl) { out = p; return true; }
        if (!p.name.empty() && lower(p.name) == tl) { out = p; return true; }
    }
    return false;
}

// Commands whose 2nd token is a target player.
bool isPlayerArgCmd(const std::string& c) {
    static const char* P[] = {"money","credits","give","giveinf","heal","reputation","exp",
        "marks","loadout","fly","godmode","invisible","die","tp","m","mode","kick",
        "ban","unban","ipban","whitelist","unwhitelist", NULL};
    for (int i = 0; P[i]; i++) if (c == P[i]) return true;
    return false;
}
// Moderation commands whose target may be OFFLINE (resolve may fail -> pass raw name).
bool isOfflineOkCmd(const std::string& c) {
    static const char* O[] = {"ban","unban","ipban","whitelist","unwhitelist", NULL};
    for (int i = 0; O[i]; i++) if (c == O[i]) return true;
    return false;
}

// Syntax: <command> <player> <args>. Returns true + fills `reply` if handled locally
// (help / errors). Otherwise rewrites args: command (player stripped) + asGameId/asPlayer,
// and returns false to forward to the game.
bool prepareConsole(json& args, json& reply) {
    std::string raw;
    if (args.contains("command"))         raw = args["command"].get<std::string>();
    else if (args.contains("rawCommand")) raw = args["rawCommand"].get<std::string>();
    else if (args.contains("message"))    raw = args["message"].get<std::string>();
    raw = trim(raw);

    // First word = command.
    std::string cmd, afterCmd;
    size_t sp = raw.find_first_of(" \t");
    if (sp == std::string::npos) { cmd = raw; afterCmd = ""; }
    else { cmd = raw.substr(0, sp); afterCmd = trim(raw.substr(sp + 1)); }
    std::string cmdl = lower(cmd);

    if (raw.empty() || cmdl == "help" || cmdl == "commands" || cmdl == "?") {
        reply = json{{"success",true},{"rawResult",HELP_TEXT}};
        return true;
    }
    if (!isVtCommand(cmdl)) {
        reply = json{{"success",false},{"rawResult","Unknown command: '" + cmd + "'. Type 'help'."}};
        return true;
    }
    if (!isPlayerArgCmd(cmdl)) {
        args["command"] = raw;   // no-player command (save/motd/me/build tools) -> acts on admin
        return false;
    }

    // Player-arg command: the next token is the player (honour "quoted names").
    std::string playerTok, argsRest; bool quoted;
    parseFirstToken(afterCmd, playerTok, argsRest, quoted);
    if (playerTok.empty()) {
        reply = json{{"success",false},{"rawResult","Usage: " + cmdl + " <player> ..."}};
        return true;
    }
    std::string newcmd = cmdl;
    if (!argsRest.empty()) newcmd += " " + argsRest;
    args["command"] = newcmd;

    PlayerInfo p;
    if (resolvePlayer(playerTok, p)) {
        args["asGameId"] = p.gameId;
        args["asPlayer"] = p.name;
    } else if (isOfflineOkCmd(cmdl)) {
        args["asPlayer"] = playerTok;   // offline-capable: pass the raw name through
    } else {
        reply = json{{"success",false},{"rawResult","Player not online: '" + playerTok + "'. Type 'help'."}};
        return true;
    }
    return false;
}

// ─── Request handling (Takaro -> us) ─────────────────────────────────────────────
bool isGameAction(const std::string& a) {
    static const char* A[] = {"sendMessage","sendMessageToPlayer","executeCommand","executeConsoleCommand",
        "kickPlayer","banPlayer","unbanPlayer","giveItem","teleportPlayer","getPlayerInventory","getPlayerLocation",
        "shutdown", NULL};
    for (int i = 0; A[i]; i++) if (a == A[i]) return true;
    return false;
}

void handleRequest(const std::string& requestId, const json& payload) {
    std::string action = payload.value("action", "");
    json args;
    if (payload.contains("args")) {
        const json& ra = payload["args"];
        if (ra.is_string()) { try { args = json::parse(ra.get<std::string>()); } catch (...) { args = json::object(); } }
        else if (ra.is_object()) args = ra;
        else args = json::object();
    } else args = json::object();

    logmsg("Request: " + action + " (" + requestId + ")");

    if (action == "testReachability") { sendResponse(requestId, json{{"connectable",true}}); return; }
    if (action == "getPlayers") {
        json list = json::array();
        std::lock_guard<std::mutex> lk(g_cacheMutex);
        for (auto& kv : g_players) {
            const PlayerInfo& p = kv.second;
            json e{{"gameId",p.gameId},{"name",p.name},
                   {"platformId","voxelturf:" + (p.steamId.empty() ? p.gameId : p.steamId)}};
            if (!p.steamId.empty()) e["steamId"] = p.steamId;
            list.push_back(e);
        }
        sendResponse(requestId, list);
        return;
    }
    if (action == "getServerInfo") { sendResponse(requestId, json{{"name", IDENTITY_TOKEN.empty()?"VoxelTurf Server":IDENTITY_TOKEN},{"version","unknown"}}); return; }
    if (action == "listItems") {
        std::lock_guard<std::mutex> lk(g_itemsMutex);
        sendResponse(requestId, g_itemsCache);
        return;
    }
    if (action == "listBans" || action == "listEntities") { sendResponse(requestId, json::array()); return; }

    if (!isGameAction(action)) { sendResponse(requestId, json{{"success",false},{"error","Unsupported: " + action}}); return; }

    bool isConsole = (action == "executeCommand" || action == "executeConsoleCommand");
    if (isConsole) {
        json reply;
        if (prepareConsole(args, reply)) { sendResponse(requestId, reply); return; }
    }

    json req{{"type","command"},{"requestId",requestId},{"action",action},{"args",args}};
    json res = udpRequest(req);
    if (res.is_object() && res.contains("result")) {
        json result = res["result"];
        if (isConsole && (!result.contains("rawResult") || result["rawResult"].is_null())) {
            std::string bf = result.value("error", "");
            if (bf.empty()) bf = result.value("success", false) ? "OK" : "Command failed";
            result["rawResult"] = bf;
        }
        sendResponse(requestId, result);
    } else if (isConsole) {
        sendResponse(requestId, json{{"success",false},{"rawResult","No result from game"}});
    } else {
        sendResponse(requestId, json{{"success",false},{"error","No result from game"}});
    }
}

// ─── Poll loop (us -> game) ──────────────────────────────────────────────────────
json asArray(const json& v) {
    if (v.is_array()) return v;
    json out = json::array();
    if (v.is_object()) for (auto& kv : v.items()) out.push_back(kv.value());
    return out;
}

void poll() {
    json res = udpRequest(json{{"type","poll"}});
    if (!res.is_object()) return;

    if (!g_startupSent && g_connected) { g_startupSent = true; sendLog("VoxelTurf server started"); }

    // players
    json players = asArray(res.contains("players") ? res["players"] : json::array());
    {
        std::lock_guard<std::mutex> lk(g_cacheMutex);
        g_players.clear();
        for (auto& p : players) {
            if (!p.is_object()) continue;
            PlayerInfo pi;
            pi.gameId = p.value("gameId", "");
            pi.name   = p.value("name", "");
            pi.steamId= toSteamId64(p.value("steamId", ""));
            if (!pi.gameId.empty()) g_players[pi.gameId] = pi;
        }
    }

    // events
    json events = asArray(res.contains("events") ? res["events"] : json::array());
    for (auto& ev : events) {
        if (!ev.is_object() || !ev.contains("type")) continue;
        std::string type = ev["type"].get<std::string>();
        json data = ev.contains("data") && ev["data"].is_object() ? ev["data"] : json::object();
        if (data.contains("player") && data["player"].is_object() && data["player"].contains("steamId"))
            data["player"]["steamId"] = toSteamId64(data["player"]["steamId"].get<std::string>());
        sendEvent(type, data);
    }
}

// ─── save detection ──────────────────────────────────────────────────────────────
long long g_lastSaveMtime = 0, g_lastSaveEmit = 0;

long long newestMtime(const std::string& dir, int depth) {
    long long maxt = 0;
    WIN32_FIND_DATAA fd; HANDLE h = FindFirstFileA((dir + "\\*").c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) return 0;
    do {
        std::string name = fd.cFileName;
        if (name == "." || name == "..") continue;
        std::string full = dir + "\\" + name;
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
            if (depth > 0) { long long m = newestMtime(full, depth - 1); if (m > maxt) maxt = m; }
        } else {
            ULARGE_INTEGER t; t.LowPart = fd.ftLastWriteTime.dwLowDateTime; t.HighPart = fd.ftLastWriteTime.dwHighDateTime;
            long long ms = (long long)(t.QuadPart / 10000ULL);   // 100ns -> ms
            if (ms > maxt) maxt = ms;
        }
    } while (FindNextFileA(h, &fd));
    FindClose(h);
    return maxt;
}

long long nowMs() { return (long long)GetTickCount64(); }

void checkSave() {
    if (!g_startupSent) return;
    long long m = newestMtime(g_saveDir, 2);
    if (m == 0) return;
    if (g_lastSaveMtime == 0) { g_lastSaveMtime = m; return; }
    if (m > g_lastSaveMtime + 1500) {
        g_lastSaveMtime = m;
        long long now = nowMs();
        if (now - g_lastSaveEmit > 15000) { g_lastSaveEmit = now; sendLog("VoxelTurf world saved"); }
    }
}

// Enumerate the item catalog ONCE at startup (the Lua returns it in batches; we stitch
// them), cache it for listItems, and write items.json next to the config for visibility.
void enumerateItems() {
    json all = json::array();
    std::map<std::string, bool> seenName;   // dedupe by code/name
    long long start = 1;
    for (int guard = 0; guard < 1000; guard++) {
        json res = udpRequest(json{{"type","command"},{"action","listItems"},{"args",{{"start",start}}}});
        if (!res.is_object() || !res.contains("result")) break;
        json result = res["result"];
        if (result.contains("probe") && result["probe"].is_string())
            logmsg("listItems probe: " + result["probe"].get<std::string>());
        if (result.contains("items") && result["items"].is_array())
            for (auto& it : result["items"]) {
                std::string code = it.value("code", "");
                if (code.empty() || seenName.count(code)) continue;
                seenName[code] = true;
                all.push_back(it);
            }
        long long nextId = (result.contains("nextId") && result["nextId"].is_number()) ? result["nextId"].get<long long>() : 0;
        if (nextId <= 0) break;
        start = nextId;
    }
    { std::lock_guard<std::mutex> lk(g_itemsMutex); g_itemsCache = all; }
    std::string path = g_gameDir + "\\mods\\TakaroConnector\\items.json";
    FILE* f = fopen(path.c_str(), "wb");
    if (f) { std::string s = all.dump(2); fwrite(s.data(), 1, s.size(), f); fclose(f); }
    logmsg("Items enumerated: " + std::to_string(all.size()) + " -> items.json");
}

void waitForServer() {
    logmsg("Waiting for server to fully load (watching " + g_statusPath + ")...");
    while (g_running) {
        struct _stat64 st;
        if (_stat64(g_statusPath.c_str(), &st) == 0) {
            long long ageSec = (long long)time(NULL) - (long long)st.st_mtime;
            if (ageSec < 60) { logmsg("Server status fresh (" + std::to_string(ageSec) + "s old) — server is up"); return; }
        }
        Sleep(5000);
    }
}

// ─── WebSocket connect + receive loop ────────────────────────────────────────────
void handleMessage(const json& msg) {
    std::string type = msg.value("type", "");
    if (type == "identifyResponse") {
        if (msg.contains("payload") && msg["payload"].is_object() && msg["payload"].contains("error"))
            logmsg("Identify failed: " + msg["payload"]["error"].dump());
        else { logmsg("Identified with Takaro"); g_connected = true; }
    } else if (type == "connected") {
        logmsg("Takaro confirmed connection");
    } else if (type == "ping") {
        wsSend(json{{"type","pong"}});
    } else if (type == "request") {
        handleRequest(msg.value("requestId", ""), msg.contains("payload") ? msg["payload"] : json::object());
    } else if (type == "error") {
        logmsg("Takaro error: " + (msg.contains("payload") ? msg["payload"].dump() : msg.dump()));
    } else if (type == "response") {
        // bridge never issues requests to Takaro; nothing to correlate.
    } else {
        logmsg("Unknown msg: " + type);
    }
}

// Returns false when the connection is closed/failed (caller reconnects).
bool wsRunOnce() {
    g_wsSession = WinHttpOpen(L"VoxelTurfTakaroBridge", WINHTTP_ACCESS_TYPE_NO_PROXY,
                              WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!g_wsSession) return false;
    g_wsConn = WinHttpConnect(g_wsSession, L"connect.takaro.io", 443, 0);
    if (!g_wsConn) { WinHttpCloseHandle(g_wsSession); g_wsSession = NULL; return false; }

    HINTERNET req = WinHttpOpenRequest(g_wsConn, L"GET", L"/", NULL, WINHTTP_NO_REFERER,
                                       WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE);
    bool ok = req &&
        WinHttpSetOption(req, WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET, NULL, 0) &&
        WinHttpSendRequest(req, WINHTTP_NO_ADDITIONAL_HEADERS, 0, NULL, 0, 0, 0) &&
        WinHttpReceiveResponse(req, NULL);
    HINTERNET ws = ok ? WinHttpWebSocketCompleteUpgrade(req, 0) : NULL;
    if (req) WinHttpCloseHandle(req);
    if (!ws) {
        if (g_wsConn) WinHttpCloseHandle(g_wsConn); g_wsConn = NULL;
        if (g_wsSession) WinHttpCloseHandle(g_wsSession); g_wsSession = NULL;
        return false;
    }
    { std::lock_guard<std::mutex> lk(g_wsMutex); g_ws = ws; }

    logmsg("Connected. Identifying as \"" + IDENTITY_TOKEN + "\"");
    json idp{{"identityToken", IDENTITY_TOKEN}};
    if (!REGISTRATION_TOKEN.empty()) idp["registrationToken"] = REGISTRATION_TOKEN;
    wsSend(json{{"type","identify"},{"payload",idp}});

    std::string acc;
    BYTE buf[8192];
    while (g_running) {
        DWORD got = 0; WINHTTP_WEB_SOCKET_BUFFER_TYPE bt;
        DWORD rc = WinHttpWebSocketReceive(ws, buf, sizeof(buf), &got, &bt);
        if (rc != 0) break;
        if (bt == WINHTTP_WEB_SOCKET_CLOSE_BUFFER_TYPE) break;
        acc.append((char*)buf, got);
        if (bt == WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE || bt == WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE) {
            try { handleMessage(json::parse(acc)); } catch (...) { logmsg("Parse error on WS message"); }
            acc.clear();
        }
        // FRAGMENT types just keep accumulating
    }

    g_connected = false;
    { std::lock_guard<std::mutex> lk(g_wsMutex);
      WinHttpWebSocketClose(ws, WINHTTP_WEB_SOCKET_SUCCESS_CLOSE_STATUS, NULL, 0);
      WinHttpCloseHandle(ws); g_ws = NULL; }
    if (g_wsConn) { WinHttpCloseHandle(g_wsConn); g_wsConn = NULL; }
    if (g_wsSession) { WinHttpCloseHandle(g_wsSession); g_wsSession = NULL; }
    return false;
}

void wsLoop() {
    int delay = 3000;
    while (g_running) {
        wsRunOnce();
        if (!g_running) break;
        logmsg("Disconnected. Reconnecting in " + std::to_string(delay / 1000) + "s");
        Sleep(delay);
        delay = (delay * 2 > 60000) ? 60000 : delay * 2;
        // reset backoff handled implicitly: a successful identify resets via wsRunOnce path
        if (g_connected) delay = 3000;
    }
}

void pollLoop() {
    waitForServer();
    Sleep(1000);
    enumerateItems();   // build the item catalog once, now that the game is up
    long long lastSaveCheck = 0;
    while (g_running) {
        poll();
        long long now = nowMs();
        if (now - lastSaveCheck > 8000) { lastSaveCheck = now; checkSave(); }
        Sleep(POLL_INTERVAL_MS);
    }
}

void bridgeBoot() {
    computePaths();
    rotateLog();
    loadConfig();

    if (!ENABLED) { logmsg("TakaroConnector disabled (ENABLED=false)"); return; }

    WSADATA wsa; WSAStartup(MAKEWORD(2, 2), &wsa);
    g_udp = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (g_udp != INVALID_SOCKET) {
        sockaddr_in local{}; local.sin_family = AF_INET; local.sin_addr.s_addr = INADDR_ANY; local.sin_port = 0;
        bind(g_udp, (sockaddr*)&local, sizeof(local));
        DWORD tmo = 5000;
        setsockopt(g_udp, SOL_SOCKET, SO_RCVTIMEO, (const char*)&tmo, sizeof(tmo));
    }

    logmsg("VoxelTurf Takaro Bridge (in-DLL) started — game=" + GAME_HOST + ":" + std::to_string(GAME_PORT) +
           ", secret=" + std::to_string(EXTERNAL_SECRET));

    std::thread(wsLoop).detach();
    std::thread(pollLoop).detach();
}

} // namespace

// Called once from winmm.dll's launcher thread (NOT from DllMain directly).
// bridgeBoot returns quickly after detaching the ws + poll worker threads.
extern "C" void StartTakaroBridge() {
    bridgeBoot();
}
