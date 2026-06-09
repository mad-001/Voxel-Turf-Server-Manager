// VoxelTurf Takaro Bridge
// Started automatically by takaro_connector.lua — do not run manually.
// Lives inside the TakaroConnector mod folder; uses bundled node_modules.

'use strict';
const path = require('path');
const fs   = require('fs');
const http = require('http');

// Load ws from our bundled node_modules (not system)
const WebSocket = require(path.join(__dirname, 'node_modules', 'ws'));

// ─── Config ──────────────────────────────────────────────────────────────────
const cfgPath = path.join(__dirname, '..', 'TakaroConfig.txt');
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
const IDENTITY_TOKEN     = cfg.SERVER_NAME         || cfg.IDENTITY_TOKEN    || '';
const REGISTRATION_TOKEN = cfg.REGISTRATION_TOKEN  || '';
const HTTP_PORT          = parseInt(cfg.HTTP_PORT  || '3003', 10);
const TAKARO_URL         = 'wss://connect.takaro.io/';
const LOG_FILE           = path.join(__dirname, '..', 'bridge.log');

// ─── Logging ─────────────────────────────────────────────────────────────────
function log(msg) {
  const line = new Date().toISOString() + ' ' + msg;
  console.log(line);
  try { fs.appendFileSync(LOG_FILE, line + '\n'); } catch (_) {}
}

// ─── State ───────────────────────────────────────────────────────────────────
let ws              = null;
let connected       = false;
let reconnectDelay  = 3000;
let reconnectTimer  = null;
const playerCache   = new Map();
const pendingCmds   = [];
const pendingRes    = new Map();
const resTimeouts   = new Map();
const RES_TIMEOUT   = 30000;

// ─── Takaro WebSocket ─────────────────────────────────────────────────────────
function connect() {
  if (ws && ws.readyState === WebSocket.OPEN) return;
  log('Connecting to Takaro...');
  ws = new WebSocket(TAKARO_URL);

  ws.on('open', () => {
    log('Connected. Identifying...');
    reconnectDelay = 3000;
    const payload = { identityToken: IDENTITY_TOKEN };
    if (REGISTRATION_TOKEN) payload.registrationToken = REGISTRATION_TOKEN;
    send({ type: 'identify', payload });
  });

  ws.on('message', raw => {
    try { handle(JSON.parse(raw.toString())); }
    catch (e) { log('Parse error: ' + e); }
  });

  ws.on('close', () => {
    log('Disconnected. Reconnecting in ' + reconnectDelay / 1000 + 's');
    connected = false;
    schedule();
  });

  ws.on('error', e => log('WS error: ' + e.message));
}

function schedule() {
  if (reconnectTimer) clearTimeout(reconnectTimer);
  reconnectTimer = setTimeout(() => { reconnectDelay = Math.min(reconnectDelay * 2, 60000); connect(); }, reconnectDelay);
}

function send(obj) {
  if (!ws || ws.readyState !== WebSocket.OPEN) return false;
  try { ws.send(JSON.stringify(obj)); return true; } catch (e) { log('Send error: ' + e); return false; }
}

function sendEvent(type, data) {
  if (!connected) return;
  send({ type: 'gameEvent', payload: { type, data: { type, ...data } } });
  log('Event -> Takaro: ' + type);
}

function sendResponse(requestId, payload) {
  send({ type: 'response', requestId, payload });
}

function handle(msg) {
  switch (msg.type) {
    case 'identifyResponse':
      if (msg.payload && msg.payload.error) { log('Identify failed: ' + msg.payload.error); }
      else { log('Identified with Takaro'); connected = true; }
      break;
    case 'connected': log('Takaro confirmed connection'); break;
    case 'ping': send({ type: 'pong' }); break;
    case 'request': handleRequest(msg.requestId, msg.payload || {}); break;
    case 'response': {
      const r = pendingRes.get(msg.requestId);
      if (r) { r(msg.payload); pendingRes.delete(msg.requestId); clearTimeout(resTimeouts.get(msg.requestId)); resTimeouts.delete(msg.requestId); }
      break;
    }
    case 'error': log('Takaro error: ' + JSON.stringify(msg.payload || msg)); break;
    default: log('Unknown msg: ' + msg.type);
  }
}

function handleRequest(requestId, payload) {
  const action = payload.action || '';
  const rawArgs = payload.args;
  const args = typeof rawArgs === 'string' ? JSON.parse(rawArgs) : (rawArgs || {});
  log('Request: ' + action + ' (' + requestId + ')');

  switch (action) {
    case 'testReachability':
      sendResponse(requestId, { connectable: true });
      break;
    case 'getPlayers': {
      const list = Array.from(playerCache.values()).map(p => ({
        gameId: p.gameId, name: p.name,
        platformId: 'voxelturf:' + (p.steamId || p.gameId),
        steamId: p.steamId || undefined,
      }));
      sendResponse(requestId, list);
      break;
    }
    case 'getServerInfo':
      sendResponse(requestId, { name: 'VoxelTurf Server', version: 'unknown' });
      break;
    case 'listBans':
    case 'getPlayerInventory':
    case 'listItems':
      sendResponse(requestId, []);
      break;
    case 'getPlayerLocation':
      sendResponse(requestId, { x: 0, y: 0, z: 0 });
      break;
    case 'sendMessage':
    case 'sendMessageToPlayer':
    case 'executeCommand':
    case 'executeConsoleCommand':
    case 'kickPlayer':
    case 'banPlayer':
    case 'unbanPlayer':
    case 'giveItem':
    case 'teleportPlayer': {
      pendingCmds.push({ requestId, action, args });
      const t = setTimeout(() => {
        if (pendingRes.has(requestId)) {
          sendResponse(requestId, { success: false, error: 'Timeout — Lua mod offline?' });
          pendingRes.delete(requestId); resTimeouts.delete(requestId);
        }
      }, RES_TIMEOUT);
      pendingRes.set(requestId, result => sendResponse(requestId, result));
      resTimeouts.set(requestId, t);
      break;
    }
    default:
      sendResponse(requestId, { success: false, error: 'Unsupported: ' + action });
  }
}

// ─── HTTP server (for Lua mod) ────────────────────────────────────────────────
const server = http.createServer((req, res) => {
  const { pathname } = new URL(req.url, 'http://localhost');
  res.setHeader('Content-Type', 'application/json');

  if (req.method === 'GET' && pathname === '/poll') {
    const cmd = pendingCmds.shift();
    res.end(JSON.stringify(cmd ? { hasCommand: true, command: cmd } : { hasCommand: false }));
    return;
  }

  if (req.method === 'GET' && pathname === '/health') {
    res.end(JSON.stringify({ ok: true, connected, players: playerCache.size }));
    return;
  }

  if (req.method === 'POST') {
    let body = '';
    req.on('data', d => body += d);
    req.on('end', () => {
      try {
        const data = JSON.parse(body);
        if (pathname === '/event') {
          const { type, data: evData } = data;
          if (type === 'player-connected' && evData && evData.player)
            playerCache.set(evData.player.gameId, evData.player);
          if (type === 'player-disconnected' && evData && evData.player)
            playerCache.delete(evData.player.gameId);
          if (type !== 'log') sendEvent(type, evData || {});
          res.end('{"ok":true}');
        } else if (pathname === '/result') {
          const { requestId, result } = data;
          const r = pendingRes.get(requestId);
          if (r) { r(result); pendingRes.delete(requestId); clearTimeout(resTimeouts.get(requestId)); resTimeouts.delete(requestId); }
          else sendResponse(requestId, result);
          res.end('{"ok":true}');
        } else {
          res.writeHead(404); res.end('{"error":"not found"}');
        }
      } catch (e) {
        res.writeHead(400); res.end('{"error":"bad json"}');
      }
    });
    return;
  }

  res.writeHead(404); res.end('{"error":"not found"}');
});

server.listen(HTTP_PORT, '127.0.0.1', () => {
  log('HTTP listening on port ' + HTTP_PORT);
});

connect();

process.on('SIGINT', () => { log('Shutting down'); ws && ws.close(); process.exit(0); });
process.on('SIGTERM', () => { log('Shutting down'); ws && ws.close(); process.exit(0); });

log('VoxelTurf Takaro Bridge started (port ' + HTTP_PORT + ')');
