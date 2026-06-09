import express, { Request, Response } from 'express';
import WebSocket from 'ws';
import winston from 'winston';
import * as fs from 'fs';
import * as path from 'path';

// ─────────────────────────────────────────────────────────────────────────────
// Config loader
// ─────────────────────────────────────────────────────────────────────────────
function loadConfig() {
  const configPath = path.join(process.cwd(), 'TakaroConfig.txt');
  if (!fs.existsSync(configPath)) {
    console.error('ERROR: TakaroConfig.txt not found. Copy the template and fill in your tokens.');
    process.exit(1);
  }
  const content = fs.readFileSync(configPath, 'utf-8');
  content.split('\n').forEach(line => {
    line = line.trim();
    if (line && !line.startsWith('#')) {
      const idx = line.indexOf('=');
      if (idx > 0) {
        const key = line.slice(0, idx).trim();
        const val = line.slice(idx + 1).trim();
        if (key && val) process.env[key] = val;
      }
    }
  });
}
loadConfig();

// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────
const TAKARO_WS_URL      = 'wss://connect.takaro.io/';
const IDENTITY_TOKEN     = process.env.SERVER_NAME         || process.env.IDENTITY_TOKEN    || '';
const REGISTRATION_TOKEN = process.env.REGISTRATION_TOKEN  || '';
const HTTP_PORT         = parseInt(process.env.HTTP_PORT || '3003', 10);

const BASE_RECONNECT_MS = 3_000;
const MAX_RECONNECT_MS  = 60_000;

// ─────────────────────────────────────────────────────────────────────────────
// Logger
// ─────────────────────────────────────────────────────────────────────────────
const logger = winston.createLogger({
  level: 'info',
  format: winston.format.combine(
    winston.format.timestamp(),
    winston.format.printf(({ timestamp, level, message }) =>
      `${timestamp} [${(level as string).toUpperCase()}] ${message}`)
  ),
  transports: [
    new winston.transports.Console(),
    new winston.transports.File({ filename: 'voxelturf-bridge.log' }),
  ],
});

// ─────────────────────────────────────────────────────────────────────────────
// State
// ─────────────────────────────────────────────────────────────────────────────
interface Player {
  gameId:  string;
  name:    string;
  steamId: string;
}

interface PendingCommand {
  requestId: string;
  action:    string;
  args:      Record<string, unknown>;
}

const playerCache    = new Map<string, Player>();
const pendingCommands: PendingCommand[] = [];
const pendingResponses = new Map<string, (result: unknown) => void>();
const responseTimeouts = new Map<string, NodeJS.Timeout>();
const RESPONSE_TIMEOUT_MS = 30_000;

let takaroWs:         WebSocket | null = null;
let isConnected       = false;
let reconnectAttempts = 0;
let reconnectTimer:   NodeJS.Timeout | null = null;

// ─────────────────────────────────────────────────────────────────────────────
// Takaro WebSocket
// ─────────────────────────────────────────────────────────────────────────────
function connectToTakaro() {
  if (takaroWs && takaroWs.readyState === WebSocket.OPEN) return;

  logger.info(`Connecting to Takaro (attempt ${reconnectAttempts + 1})`);
  takaroWs = new WebSocket(TAKARO_WS_URL);

  takaroWs.on('open', () => {
    logger.info('Connected to Takaro WebSocket');
    reconnectAttempts = 0;
    sendToTakaro({ type: 'identify', payload: identifyPayload() });
  });

  takaroWs.on('message', (raw: WebSocket.Data) => {
    try {
      handleTakaroMessage(JSON.parse(raw.toString()));
    } catch (e) {
      logger.error(`Failed to parse Takaro message: ${e}`);
    }
  });

  takaroWs.on('close', () => {
    logger.warn('Disconnected from Takaro');
    isConnected = false;
    scheduleReconnect();
  });

  takaroWs.on('error', (err: Error) => {
    logger.error(`Takaro WS error: ${err.message}`);
  });
}

function identifyPayload() {
  const p: Record<string, string> = { identityToken: IDENTITY_TOKEN };
  if (REGISTRATION_TOKEN) p.registrationToken = REGISTRATION_TOKEN;
  return p;
}

function scheduleReconnect() {
  if (reconnectTimer) clearTimeout(reconnectTimer);
  reconnectAttempts++;
  const delay = Math.min(BASE_RECONNECT_MS * 2 ** (reconnectAttempts - 1), MAX_RECONNECT_MS);
  logger.info(`Reconnecting in ${Math.round(delay / 1000)}s`);
  reconnectTimer = setTimeout(connectToTakaro, delay);
}

function sendToTakaro(msg: object): boolean {
  if (!takaroWs || takaroWs.readyState !== WebSocket.OPEN) return false;
  try {
    takaroWs.send(JSON.stringify(msg));
    return true;
  } catch (e) {
    logger.error(`Failed to send to Takaro: ${e}`);
    return false;
  }
}

function sendGameEvent(eventType: string, data: Record<string, unknown>) {
  if (!isConnected) {
    logger.warn(`Cannot send ${eventType}: not connected`);
    return;
  }
  logger.info(`Game event -> Takaro: ${eventType}`);
  sendToTakaro({
    type: 'gameEvent',
    payload: {
      type: eventType,
      data: { type: eventType, ...data },
    },
  });
}

function sendResponse(requestId: string, payload: unknown) {
  sendToTakaro({ type: 'response', requestId, payload });
}

// ─────────────────────────────────────────────────────────────────────────────
// Takaro message handler
// ─────────────────────────────────────────────────────────────────────────────
function handleTakaroMessage(msg: Record<string, unknown>) {
  logger.info(`Takaro -> bridge: ${msg.type}`);

  switch (msg.type) {
    case 'identifyResponse': {
      const p = msg.payload as Record<string, unknown> | undefined;
      if (p?.error) {
        logger.error(`Identify failed: ${p.error}`);
      } else {
        logger.info('Identified with Takaro');
        isConnected = true;
      }
      break;
    }

    case 'connected':
      logger.info('Takaro confirmed connection');
      break;

    case 'ping':
      sendToTakaro({ type: 'pong' });
      break;

    case 'request':
      handleTakaroRequest(
        msg.requestId as string,
        msg.payload as Record<string, unknown>
      );
      break;

    case 'response': {
      const rid = msg.requestId as string;
      const resolver = pendingResponses.get(rid);
      if (resolver) {
        resolver(msg.payload);
        pendingResponses.delete(rid);
        const t = responseTimeouts.get(rid);
        if (t) { clearTimeout(t); responseTimeouts.delete(rid); }
      }
      break;
    }

    case 'error':
      logger.error(`Takaro error: ${JSON.stringify(msg.payload ?? msg)}`);
      break;

    default:
      logger.warn(`Unknown Takaro message type: ${msg.type}`);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Takaro request handler
// ─────────────────────────────────────────────────────────────────────────────
function handleTakaroRequest(requestId: string, payload: Record<string, unknown>) {
  const action = payload.action as string;
  const rawArgs = payload.args;
  const args: Record<string, unknown> = typeof rawArgs === 'string'
    ? JSON.parse(rawArgs)
    : (rawArgs as Record<string, unknown>) ?? {};

  logger.info(`Takaro request: ${action} (${requestId})`);

  switch (action) {

    case 'testReachability':
      sendResponse(requestId, { connectable: true });
      break;

    case 'getPlayers': {
      const players = Array.from(playerCache.values()).map(p => ({
        gameId:     p.gameId,
        name:       p.name,
        platformId: `voxelturf:${p.steamId || p.gameId}`,
        steamId:    p.steamId || undefined,
      }));
      logger.info(`getPlayers: ${players.length} cached`);
      sendResponse(requestId, players);
      break;
    }

    case 'getServerInfo':
      sendResponse(requestId, {
        name:    'VoxelTurf Server',
        version: 'unknown',
      });
      break;

    case 'listBans':
      sendResponse(requestId, []);
      break;

    case 'getPlayerLocation':
      sendResponse(requestId, { x: 0, y: 0, z: 0 });
      break;

    case 'getPlayerInventory':
      sendResponse(requestId, []);
      break;

    case 'listItems':
      sendResponse(requestId, []);
      break;

    // Commands that must be executed in-game (queued for Lua mod to pick up)
    case 'sendMessage':
    case 'sendMessageToPlayer':
    case 'executeCommand':
    case 'executeConsoleCommand':
    case 'kickPlayer':
    case 'banPlayer':
    case 'unbanPlayer':
    case 'giveItem':
    case 'teleportPlayer': {
      const cmd: PendingCommand = { requestId, action, args };
      pendingCommands.push(cmd);
      logger.info(`Queued command for Lua: ${action}`);
      // Response is sent when Lua posts /result
      // Set a timeout in case Lua never picks it up
      const t = setTimeout(() => {
        if (pendingResponses.has(requestId)) {
          logger.warn(`Command ${action} (${requestId}) timed out`);
          sendResponse(requestId, { success: false, error: 'Command timeout - Lua mod may be offline' });
          pendingResponses.delete(requestId);
          responseTimeouts.delete(requestId);
        }
      }, RESPONSE_TIMEOUT_MS);
      pendingResponses.set(requestId, (result) => sendResponse(requestId, result));
      responseTimeouts.set(requestId, t);
      break;
    }

    default:
      logger.warn(`Unknown action: ${action}`);
      sendResponse(requestId, { success: false, error: `Unsupported action: ${action}` });
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Express HTTP server (for Lua mod communication)
// ─────────────────────────────────────────────────────────────────────────────
const app = express();
app.use(express.json());

// Health check
app.get('/health', (_req: Request, res: Response) => {
  res.json({
    status:          'ok',
    takaroConnected: isConnected,
    cachedPlayers:   playerCache.size,
    pendingCommands: pendingCommands.length,
  });
});

// Lua mod -> bridge: game events
app.post('/event', (req: Request, res: Response) => {
  const { type, data } = req.body as { type?: string; data?: Record<string, unknown> };
  if (!type) return res.status(400).json({ error: 'missing type' }) as unknown as void;

  logger.info(`Lua event: ${type}`);

  // Maintain player cache for getPlayers
  if (type === 'player-connected' && data?.player) {
    const p = data.player as Player;
    if (p.gameId) playerCache.set(p.gameId, p);
  } else if (type === 'player-disconnected' && data?.player) {
    const p = data.player as Player;
    if (p.gameId) playerCache.delete(p.gameId);
  }

  // Forward to Takaro (don't forward log events)
  if (type !== 'log') {
    sendGameEvent(type, data ?? {});
  }

  res.json({ success: true });
});

// Lua mod polls for next pending command
app.get('/poll', (_req: Request, res: Response) => {
  if (pendingCommands.length > 0) {
    const cmd = pendingCommands.shift()!;
    logger.info(`Poll: delivering command ${cmd.action} (${cmd.requestId})`);
    res.json({ hasCommand: true, command: cmd });
  } else {
    res.json({ hasCommand: false });
  }
});

// Lua mod -> bridge: command result
app.post('/result', (req: Request, res: Response) => {
  const { requestId, result } = req.body as { requestId?: string; result?: unknown };
  if (!requestId) return res.status(400).json({ error: 'missing requestId' }) as unknown as void;

  logger.info(`Lua result for ${requestId}`);
  const resolver = pendingResponses.get(requestId);
  if (resolver) {
    resolver(result);
    pendingResponses.delete(requestId);
    const t = responseTimeouts.get(requestId);
    if (t) { clearTimeout(t); responseTimeouts.delete(requestId); }
  } else {
    // Not in pending map (may have already been handled or timed out)
    // Still forward to Takaro directly
    sendResponse(requestId, result);
  }

  res.json({ success: true });
});

// ─────────────────────────────────────────────────────────────────────────────
// Start
// ─────────────────────────────────────────────────────────────────────────────
app.listen(HTTP_PORT, '127.0.0.1', () => {
  logger.info(`HTTP server listening on http://127.0.0.1:${HTTP_PORT}`);
});

connectToTakaro();

const shutdown = () => {
  logger.info('Shutting down...');
  takaroWs?.close();
  process.exit(0);
};
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
