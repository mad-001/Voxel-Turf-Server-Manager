// VoxelTurf Takaro Bridge v2.2.1
// Uses VoxelTurf N_EXTERNAL UDP API — no HTTP server needed.
// Launched by winmm.dll / takaro.dll (via the version.dll proxy) with the game PID as argv[1].
// Monitors game PID and exits immediately when the game process dies.
// Hooks: start, stop, save, join, leave, chat, death, inventory.
// REQUIRES VoxelTurf dedicated server 1.9.9 beta (the N_EXTERNAL API does not exist in 1.9.8).

'use strict';
const path   = require('path');
const fs     = require('fs');
const dgram  = require('dgram');
const WebSocket = require('ws');

// Under pkg (bridge.exe) __dirname is a virtual snapshot path; use the real exe
// directory so we read TakaroConfig.txt and write logs next to the actual files.
const BASE_DIR = process.pkg ? path.dirname(process.execPath) : __dirname;

// ─── Config ──────────────────────────────────────────────────────────────────
const cfgPath = path.join(BASE_DIR, '..', 'TakaroConfig.txt');
const cfg = {};
if (fs.existsSync(cfgPath)) {
  fs.readFileSync(cfgPath, 'utf-8').split('\n').forEach(line => {
    line = line.trim();
    if (line && !line.startsWith('#')) {
      const i = line.indexOf('=');
      if (i > 0) cfg[line.slice(0, i).trim()] = line.slice(i + 1).trim();
    }
  });
}
const IDENTITY_TOKEN     = cfg.SERVER_NAME        || cfg.IDENTITY_TOKEN   || '';
const REGISTRATION_TOKEN = cfg.REGISTRATION_TOKEN || '';
const GAME_HOST          = cfg.GAME_HOST          || '127.0.0.1';
const GAME_PORT          = parseInt(cfg.GAME_PORT  || '5728', 10);
const EXTERNAL_SECRET    = parseInt(cfg.EXTERNAL_SECRET || '123456', 10);
const POLL_INTERVAL_MS   = parseInt(cfg.POLL_INTERVAL_MS || '2000', 10);
const TAKARO_URL         = 'wss://connect.takaro.io/';
const LOG_FILE           = path.join(BASE_DIR, '..', 'bridge.log');
// PID is argv[2] when launched as `node bridge.js <pid>`, or argv[1] as `bridge.exe <pid>`.
const GAME_PID           = parseInt(process.argv[2]) || parseInt(process.argv[1]) || null;

// ─── Logging ─────────────────────────────────────────────────────────────────
function log(msg) {
  const line = new Date().toISOString() + ' ' + msg;
  console.log(line);
  try { fs.appendFileSync(LOG_FILE, line + '\n'); } catch (_) {}
}

// ─── Game process monitor ─────────────────────────────────────────────────────
// Exit immediately when the game process dies — no waiting around.
if (GAME_PID) {
  setInterval(() => {
    try {
      process.kill(GAME_PID, 0);  // signal 0 = existence check only
    } catch (_) {
      shutdown('game process ' + GAME_PID + ' exited');
    }
  }, 2000);
}

// ─── UDP ─────────────────────────────────────────────────────────────────────
const N_EXTERNAL = 103;
const udp = dgram.createSocket('udp4');

// Sequential request queue — one UDP round-trip at a time
let udpBusy          = false;
let udpPendingResolve = null;
let udpPendingReject  = null;
let udpTimeout        = null;
const udpQueue       = [];

function udpFlush() {
  if (udpBusy || udpQueue.length === 0) return;
  udpBusy = true;
  const { payload, resolve, reject } = udpQueue.shift();
  udpPendingResolve = resolve;
  udpPendingReject  = reject;

  const msgBuf = Buffer.from(JSON.stringify(payload));
  const header = Buffer.allocUnsafe(5);
  header.writeUInt8(N_EXTERNAL, 0);
  header.writeUInt32LE(EXTERNAL_SECRET, 1);
  const pkt = Buffer.concat([header, msgBuf]);

  udpTimeout = setTimeout(() => {
    log('UDP timeout waiting for game response');
    udpBusy = false;
    udpPendingResolve = null;
    udpPendingReject  = null;
    udpTimeout = null;
    reject(new Error('UDP response timeout'));
    udpFlush();
  }, 5000);

  udp.send(pkt, GAME_PORT, GAME_HOST, err => {
    if (err) {
      clearTimeout(udpTimeout); udpTimeout = null;
      udpBusy = false; udpPendingResolve = null; udpPendingReject = null;
      reject(err); udpFlush();
    }
  });
}

function udpRequest(payload) {
  return new Promise((resolve, reject) => {
    udpQueue.push({ payload, resolve, reject });
    udpFlush();
  });
}

udp.on('message', (raw, rinfo) => {
  if (!udpPendingResolve) return;
  clearTimeout(udpTimeout); udpTimeout = null;
  const resolve = udpPendingResolve;
  udpPendingResolve = null;
  udpPendingReject  = null;
  udpBusy = false;
  // Game response starts with the N_EXTERNAL opcode byte (103 = 'g') — skip it
  try { resolve(JSON.parse(raw.slice(1).toString())); } catch (e) { resolve(null); }
  udpFlush();
});

udp.on('error', err => log('UDP error: ' + err.message));

// ─── Poll loop ────────────────────────────────────────────────────────────────
let consecutiveTimeouts = 0;
const MAX_TIMEOUTS = 6; // 6 × 5s = 30s of silence → assume game stopped

// VoxelTurf reports the 32-bit Steam account id; Takaro expects the full SteamID64.
// SteamID64 = accountId + 76561197960265728. Use BigInt — the value exceeds 2^53.
const STEAM64_BASE = 76561197960265728n;
function toSteamId64(acct) {
  const s = String(acct == null ? '' : acct).trim();
  if (!/^\d+$/.test(s)) return s || undefined;          // non-numeric -> leave as-is
  const n = BigInt(s);
  return (n < STEAM64_BASE ? n + STEAM64_BASE : n).toString();  // already a 64? leave it
}

async function poll() {
  try {
    const res = await udpRequest({ type: 'poll' });
    consecutiveTimeouts = 0;
    if (!res) return;

    // 'start' hook — first time the game answers a poll while we're connected to Takaro
    if (!startupSent && connected) { startupSent = true; sendLog('VoxelTurf server started'); }

    // Update player cache — Lua JSON encoder may return {} for empty arrays
    const players = Array.isArray(res.players) ? res.players : Object.values(res.players || {});
    players.forEach(p => { if (p && p.steamId) p.steamId = toSteamId64(p.steamId); });
    playerCache.clear();
    players.forEach(p => playerCache.set(p.gameId, p));

    // Forward events to Takaro
    const events = Array.isArray(res.events) ? res.events : Object.values(res.events || {});
    events.forEach(ev => {
      if (!ev || !ev.type) return;
      const d = ev.data || {};
      if (d.player && d.player.steamId) d.player.steamId = toSteamId64(d.player.steamId);
      if (ev.type === 'player-connected' && d.player)
        playerCache.set(d.player.gameId, d.player);
      if (ev.type === 'player-disconnected' && d.player)
        playerCache.delete(d.player.gameId);
      sendEvent(ev.type, d);
    });
  } catch (_) {
    // Game not responding — it may be loading or between maps; PID monitor handles exit
  }
}

// ─── State ───────────────────────────────────────────────────────────────────
let ws             = null;
let connected      = false;
let startupSent    = false;
let reconnectDelay = 3000;
let reconnectTimer = null;
const playerCache  = new Map();
const pendingRes   = new Map();
const resTimeouts  = new Map();
const RES_TIMEOUT  = 30000;

// ─── Takaro WebSocket ─────────────────────────────────────────────────────────
function connect() {
  if (ws && ws.readyState === WebSocket.OPEN) return;
  log('Connecting to Takaro...');
  ws = new WebSocket(TAKARO_URL);

  ws.on('open', () => {
    log('Connected. Identifying as "' + IDENTITY_TOKEN + '"');
    reconnectDelay = 3000;
    const payload = { identityToken: IDENTITY_TOKEN };
    if (REGISTRATION_TOKEN) payload.registrationToken = REGISTRATION_TOKEN;
    wsSend({ type: 'identify', payload });
  });

  ws.on('message', raw => {
    try { handle(JSON.parse(raw.toString())); }
    catch (e) { log('Parse error: ' + e); }
  });

  ws.on('close', () => {
    log('Disconnected. Reconnecting in ' + reconnectDelay / 1000 + 's');
    connected = false;
    scheduleReconnect();
  });

  ws.on('error', e => log('WS error: ' + e.message));
}

function scheduleReconnect() {
  if (reconnectTimer) clearTimeout(reconnectTimer);
  reconnectTimer = setTimeout(() => {
    reconnectDelay = Math.min(reconnectDelay * 2, 60000);
    connect();
  }, reconnectDelay);
}

function wsSend(obj) {
  if (!ws || ws.readyState !== WebSocket.OPEN) return false;
  try { ws.send(JSON.stringify(obj)); return true; } catch (e) { log('WS send error: ' + e); return false; }
}

function sendEvent(type, data) {
  if (!connected) return;
  wsSend({ type: 'gameEvent', payload: { type, data: { type, ...data } } });
  log('Event -> Takaro: ' + type);
}

// Takaro has no native server start/stop/save event — surface them as 'log' events
// (EventLogLine) so modules can hook on the message text.
function sendLog(msg) {
  if (!connected) { log('(log event queued, not yet connected) ' + msg); return false; }
  wsSend({ type: 'gameEvent', payload: { type: 'log', data: { type: 'log', msg } } });
  log('Event -> Takaro: log :: ' + msg);
  return true;
}

function sendResponse(requestId, payload) {
  wsSend({ type: 'response', requestId, payload });
}

// 'stop' hook — emit a log event, give it a moment to flush, then close cleanly.
let shuttingDown = false;
function shutdown(reason) {
  if (shuttingDown) return;
  shuttingDown = true;
  log('Shutting down: ' + reason);
  sendLog('VoxelTurf server stopped (' + reason + ')');
  setTimeout(() => {
    try { ws && ws.close(); } catch (_) {}
    try { udp.close(); } catch (_) {}
    process.exit(0);
  }, 300);
}

function handle(msg) {
  switch (msg.type) {
    case 'identifyResponse':
      if (msg.payload && msg.payload.error) log('Identify failed: ' + msg.payload.error);
      else { log('Identified with Takaro'); connected = true; }
      break;
    case 'connected': log('Takaro confirmed connection'); break;
    case 'ping': wsSend({ type: 'pong' }); break;
    case 'request': handleRequest(msg.requestId, msg.payload || {}); break;
    case 'response': {
      const r = pendingRes.get(msg.requestId);
      if (r) {
        r(msg.payload);
        pendingRes.delete(msg.requestId);
        clearTimeout(resTimeouts.get(msg.requestId));
        resTimeouts.delete(msg.requestId);
      }
      break;
    }
    case 'error': log('Takaro error: ' + JSON.stringify(msg.payload || msg)); break;
    default: log('Unknown msg: ' + msg.type);
  }
}

async function handleRequest(requestId, payload) {
  const action  = payload.action || '';
  const rawArgs = payload.args;
  const args    = typeof rawArgs === 'string' ? JSON.parse(rawArgs) : (rawArgs || {});
  log('Request: ' + action + ' (' + requestId + ')');

  switch (action) {
    case 'testReachability':
      sendResponse(requestId, { connectable: true });
      return;
    case 'getPlayers': {
      const list = Array.from(playerCache.values()).map(p => ({
        gameId:     p.gameId,
        name:       p.name,
        platformId: 'voxelturf:' + (p.steamId || p.gameId),
        steamId:    p.steamId || undefined,
      }));
      sendResponse(requestId, list);
      return;
    }
    case 'getServerInfo':
      sendResponse(requestId, { name: IDENTITY_TOKEN || 'VoxelTurf Server', version: 'unknown' });
      return;
    case 'listBans':
    case 'listItems':
    case 'listEntities':
      sendResponse(requestId, []);
      return;
    case 'getPlayerLocation':
      sendResponse(requestId, { x: 0, y: 0, z: 0 });
      return;
  }

  // Game-side commands — send via UDP
  const GAME_ACTIONS = ['sendMessage','sendMessageToPlayer','executeCommand','executeConsoleCommand',
                        'kickPlayer','banPlayer','unbanPlayer','giveItem','teleportPlayer','getPlayerInventory'];
  if (!GAME_ACTIONS.includes(action)) {
    sendResponse(requestId, { success: false, error: 'Unsupported: ' + action });
    return;
  }

  try {
    const res = await udpRequest({ type: 'command', requestId, action, args });
    if (res && res.result !== undefined) sendResponse(requestId, res.result);
    else sendResponse(requestId, { success: false, error: 'No result from game' });
  } catch (e) {
    sendResponse(requestId, { success: false, error: 'UDP error: ' + e.message });
  }
}

// ─── Wait for server to fully load before polling ────────────────────────────
// server_status.txt is updated every 30s while vtserver is running.
// We check its mtime to know when the server has finished loading.
// This prevents sending N_EXTERNAL packets before the server has initialized
// the external API handler (which causes a SIGSEGV in vtserver 1.9.9).
const STATUS_FILE = path.join(BASE_DIR, '..', '..', '..', 'logs', 'server_status.txt');

// ─── 'save' hook ──────────────────────────────────────────────────────────────
// VoxelTurf exposes no Lua save callback, so detect saves by watching the
// savegames directory's newest file mtime. A save rewrites save files, bumping
// the mtime. Debounced so one save (many files) = one event.
const SAVE_DIR = path.join(BASE_DIR, '..', '..', '..', 'savegames');
let lastSaveMtime = 0;
let lastSaveEmit  = 0;

function newestMtime(dir, depth) {
  let max = 0;
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (_) { return 0; }
  for (const e of entries) {
    const full = path.join(dir, e.name);
    try {
      if (e.isDirectory()) {
        if (depth > 0) { const m = newestMtime(full, depth - 1); if (m > max) max = m; }
      } else {
        const m = fs.statSync(full).mtimeMs;
        if (m > max) max = m;
      }
    } catch (_) {}
  }
  return max;
}

function checkSave() {
  // Don't watch until the server has fully loaded — world generation writes the
  // save files and would otherwise fire a bogus 'saved' during startup.
  if (!startupSent) return;
  const m = newestMtime(SAVE_DIR, 2);
  if (m === 0) return;
  if (lastSaveMtime === 0) { lastSaveMtime = m; return; } // baseline, don't fire on startup
  if (m > lastSaveMtime + 1500) {
    lastSaveMtime = m;
    const now = Date.now();
    if (now - lastSaveEmit > 15000) { lastSaveEmit = now; sendLog('VoxelTurf world saved'); }
  }
}

async function waitForServer() {
  log('Waiting for server to fully load (watching ' + STATUS_FILE + ')...');
  while (true) {
    try {
      const stat = fs.statSync(STATUS_FILE);
      const ageMs = Date.now() - stat.mtimeMs;
      if (ageMs < 60000) {
        log('Server status file fresh (' + Math.round(ageMs / 1000) + 's old) — server is up');
        return;
      }
    } catch (_) {}
    await new Promise(r => setTimeout(r, 5000));
  }
}

// ─── Start ────────────────────────────────────────────────────────────────────
udp.bind(0, async () => {
  const port = udp.address().port;
  log('UDP socket bound on port ' + port + ', polling game at ' + GAME_HOST + ':' + GAME_PORT);
  await waitForServer();
  setInterval(poll, POLL_INTERVAL_MS);
  setTimeout(poll, 1000);
  setInterval(checkSave, 8000);
});

connect();

process.on('SIGINT',  () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));

log('VoxelTurf Takaro Bridge v2.2.1 started (UDP mode, game=' + GAME_HOST + ':' + GAME_PORT + ', secret=' + EXTERNAL_SECRET + ') — hooks: start/stop/save/join/leave/chat/death/inventory');
