"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
const express_1 = __importDefault(require("express"));
const ws_1 = __importDefault(require("ws"));
const winston_1 = __importDefault(require("winston"));
const fs = __importStar(require("fs"));
const path = __importStar(require("path"));
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
                if (key && val)
                    process.env[key] = val;
            }
        }
    });
}
loadConfig();
// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────
const TAKARO_WS_URL = 'wss://connect.takaro.io/';
const IDENTITY_TOKEN = process.env.SERVER_NAME || process.env.IDENTITY_TOKEN || '';
const REGISTRATION_TOKEN = process.env.REGISTRATION_TOKEN || '';
const HTTP_PORT = parseInt(process.env.HTTP_PORT || '3003', 10);
const BASE_RECONNECT_MS = 3000;
const MAX_RECONNECT_MS = 60000;
// ─────────────────────────────────────────────────────────────────────────────
// Logger
// ─────────────────────────────────────────────────────────────────────────────
const logger = winston_1.default.createLogger({
    level: 'info',
    format: winston_1.default.format.combine(winston_1.default.format.timestamp(), winston_1.default.format.printf(({ timestamp, level, message }) => `${timestamp} [${level.toUpperCase()}] ${message}`)),
    transports: [
        new winston_1.default.transports.Console(),
        new winston_1.default.transports.File({ filename: 'voxelturf-bridge.log' }),
    ],
});
const playerCache = new Map();
const pendingCommands = [];
const pendingResponses = new Map();
const responseTimeouts = new Map();
const RESPONSE_TIMEOUT_MS = 30000;
let takaroWs = null;
let isConnected = false;
let reconnectAttempts = 0;
let reconnectTimer = null;
// ─────────────────────────────────────────────────────────────────────────────
// Takaro WebSocket
// ─────────────────────────────────────────────────────────────────────────────
function connectToTakaro() {
    if (takaroWs && takaroWs.readyState === ws_1.default.OPEN)
        return;
    logger.info(`Connecting to Takaro (attempt ${reconnectAttempts + 1})`);
    takaroWs = new ws_1.default(TAKARO_WS_URL);
    takaroWs.on('open', () => {
        logger.info('Connected to Takaro WebSocket');
        reconnectAttempts = 0;
        sendToTakaro({ type: 'identify', payload: identifyPayload() });
    });
    takaroWs.on('message', (raw) => {
        try {
            handleTakaroMessage(JSON.parse(raw.toString()));
        }
        catch (e) {
            logger.error(`Failed to parse Takaro message: ${e}`);
        }
    });
    takaroWs.on('close', () => {
        logger.warn('Disconnected from Takaro');
        isConnected = false;
        scheduleReconnect();
    });
    takaroWs.on('error', (err) => {
        logger.error(`Takaro WS error: ${err.message}`);
    });
}
function identifyPayload() {
    const p = { identityToken: IDENTITY_TOKEN };
    if (REGISTRATION_TOKEN)
        p.registrationToken = REGISTRATION_TOKEN;
    return p;
}
function scheduleReconnect() {
    if (reconnectTimer)
        clearTimeout(reconnectTimer);
    reconnectAttempts++;
    const delay = Math.min(BASE_RECONNECT_MS * 2 ** (reconnectAttempts - 1), MAX_RECONNECT_MS);
    logger.info(`Reconnecting in ${Math.round(delay / 1000)}s`);
    reconnectTimer = setTimeout(connectToTakaro, delay);
}
function sendToTakaro(msg) {
    if (!takaroWs || takaroWs.readyState !== ws_1.default.OPEN)
        return false;
    try {
        takaroWs.send(JSON.stringify(msg));
        return true;
    }
    catch (e) {
        logger.error(`Failed to send to Takaro: ${e}`);
        return false;
    }
}
function sendGameEvent(eventType, data) {
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
function sendResponse(requestId, payload) {
    sendToTakaro({ type: 'response', requestId, payload });
}
// ─────────────────────────────────────────────────────────────────────────────
// Takaro message handler
// ─────────────────────────────────────────────────────────────────────────────
function handleTakaroMessage(msg) {
    logger.info(`Takaro -> bridge: ${msg.type}`);
    switch (msg.type) {
        case 'identifyResponse': {
            const p = msg.payload;
            if (p?.error) {
                logger.error(`Identify failed: ${p.error}`);
            }
            else {
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
            handleTakaroRequest(msg.requestId, msg.payload);
            break;
        case 'response': {
            const rid = msg.requestId;
            const resolver = pendingResponses.get(rid);
            if (resolver) {
                resolver(msg.payload);
                pendingResponses.delete(rid);
                const t = responseTimeouts.get(rid);
                if (t) {
                    clearTimeout(t);
                    responseTimeouts.delete(rid);
                }
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
function handleTakaroRequest(requestId, payload) {
    const action = payload.action;
    const rawArgs = payload.args;
    const args = typeof rawArgs === 'string'
        ? JSON.parse(rawArgs)
        : rawArgs ?? {};
    logger.info(`Takaro request: ${action} (${requestId})`);
    switch (action) {
        case 'testReachability':
            sendResponse(requestId, { connectable: true });
            break;
        case 'getPlayers': {
            const players = Array.from(playerCache.values()).map(p => ({
                gameId: p.gameId,
                name: p.name,
                platformId: `voxelturf:${p.steamId || p.gameId}`,
                steamId: p.steamId || undefined,
            }));
            logger.info(`getPlayers: ${players.length} cached`);
            sendResponse(requestId, players);
            break;
        }
        case 'getServerInfo':
            sendResponse(requestId, {
                name: 'VoxelTurf Server',
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
            const cmd = { requestId, action, args };
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
const app = (0, express_1.default)();
app.use(express_1.default.json());
// Health check
app.get('/health', (_req, res) => {
    res.json({
        status: 'ok',
        takaroConnected: isConnected,
        cachedPlayers: playerCache.size,
        pendingCommands: pendingCommands.length,
    });
});
// Lua mod -> bridge: game events
app.post('/event', (req, res) => {
    const { type, data } = req.body;
    if (!type)
        return res.status(400).json({ error: 'missing type' });
    logger.info(`Lua event: ${type}`);
    // Maintain player cache for getPlayers
    if (type === 'player-connected' && data?.player) {
        const p = data.player;
        if (p.gameId)
            playerCache.set(p.gameId, p);
    }
    else if (type === 'player-disconnected' && data?.player) {
        const p = data.player;
        if (p.gameId)
            playerCache.delete(p.gameId);
    }
    // Forward to Takaro (don't forward log events)
    if (type !== 'log') {
        sendGameEvent(type, data ?? {});
    }
    res.json({ success: true });
});
// Lua mod polls for next pending command
app.get('/poll', (_req, res) => {
    if (pendingCommands.length > 0) {
        const cmd = pendingCommands.shift();
        logger.info(`Poll: delivering command ${cmd.action} (${cmd.requestId})`);
        res.json({ hasCommand: true, command: cmd });
    }
    else {
        res.json({ hasCommand: false });
    }
});
// Lua mod -> bridge: command result
app.post('/result', (req, res) => {
    const { requestId, result } = req.body;
    if (!requestId)
        return res.status(400).json({ error: 'missing requestId' });
    logger.info(`Lua result for ${requestId}`);
    const resolver = pendingResponses.get(requestId);
    if (resolver) {
        resolver(result);
        pendingResponses.delete(requestId);
        const t = responseTimeouts.get(requestId);
        if (t) {
            clearTimeout(t);
            responseTimeouts.delete(requestId);
        }
    }
    else {
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
