import { FrameType, decodeFrame, decodeReqHead, encodeFrame, encodeJson, type ReqHead } from "../shared/protocol.ts";

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required`);
  return value;
}

const relayUrl = requireEnv("RELAY_URL");
const token = requireEnv("SPIKE_TOKEN");
const origin = process.env.ORIGIN_URL ?? "http://127.0.0.1:18080";
// 0 は keepalive なし
const pingMs = Number(process.env.PING_MS ?? 20000);
const pongTimeoutMs = Number(process.env.PONG_TIMEOUT_MS ?? 10000);
const backoffMinMs = Number(process.env.BACKOFF_MIN_MS ?? 500);
const backoffMaxMs = Number(process.env.BACKOFF_MAX_MS ?? 30000);
// relay に追い出された (code 4000) 後に繋ぎ直す (既定は繋ぎ直さない)
const reconnectAfterReplaced = process.env.RECONNECT_AFTER_REPLACED === "1";
const REPLACED_CODE = 4000;
const EMPTY = new Uint8Array(0);

function log(event: string, fields: Record<string, string | number> = {}): void {
  console.log(JSON.stringify({ event, at: Date.now(), ...fields }));
}

const active = new Map<number, AbortController>();
let ws: WebSocket | null = null;
let attempt = 0;
let lastRx = Date.now();
let pingTimer: ReturnType<typeof setInterval> | null = null;

function send(socket: WebSocket, type: FrameType, id: number, payload: Uint8Array): void {
  if (socket.readyState === WebSocket.OPEN) socket.send(encodeFrame(type, id, payload));
}

async function serve(socket: WebSocket, id: number, head: ReqHead, abort: AbortController): Promise<void> {
  try {
    const response = await fetch(origin + head.path, { method: head.method, signal: abort.signal });
    send(socket, FrameType.ResHead, id, encodeJson({ status: response.status, headers: [...response.headers] }));
    if (response.body) {
      for await (const chunk of response.body) send(socket, FrameType.ResBody, id, chunk);
    }
    send(socket, FrameType.ResEnd, id, EMPTY);
  } catch (error) {
    if (!abort.signal.aborted) {
      log("request-failed", { id, message: (error as Error).message });
      send(socket, FrameType.Cancel, id, EMPTY);
    }
  } finally {
    active.delete(id);
  }
}

function stopPing(): void {
  if (pingTimer) clearInterval(pingTimer);
  pingTimer = null;
}

function startPing(socket: WebSocket): void {
  stopPing();
  if (pingMs <= 0) return;
  pingTimer = setInterval(() => {
    if (Date.now() - lastRx > pingMs + pongTimeoutMs) {
      log("pong-timeout", { silentMs: Date.now() - lastRx });
      socket.terminate();
      return;
    }
    if (socket.readyState === WebSocket.OPEN) socket.send("ping");
  }, pingMs);
}

function connect(): void {
  attempt += 1;
  log("connecting", { attempt });
  const socket = new WebSocket(`${relayUrl.replace(/^http/, "ws")}/_ws`, { headers: { "x-spike-token": token } });
  ws = socket;
  socket.binaryType = "arraybuffer";

  socket.addEventListener("open", () => {
    log("open", { attempt });
    attempt = 0;
    lastRx = Date.now();
    startPing(socket);
  });
  socket.addEventListener("message", (event) => {
    lastRx = Date.now();
    if (!(event.data instanceof ArrayBuffer)) return;
    const frame = decodeFrame(event.data);
    if (frame.type === FrameType.ReqHead) {
      const abort = new AbortController();
      active.set(frame.id, abort);
      void serve(socket, frame.id, decodeReqHead(frame.payload), abort);
    } else if (frame.type === FrameType.Cancel) {
      active.get(frame.id)?.abort();
    }
  });
  socket.addEventListener("error", () => log("error"));
  socket.addEventListener("close", (event) => {
    log("close", { code: event.code, reason: event.reason });
    if (ws !== socket) return;
    stopPing();
    for (const abort of active.values()) abort.abort();
    active.clear();
    if (event.code === REPLACED_CODE && !reconnectAfterReplaced) {
      log("giving-up", { reason: "replaced" });
      process.exit(0);
    }
    // 0.5, 1, 2, ... 秒と倍にして, 上限で止める
    const delay = Math.min(backoffMaxMs, backoffMinMs * 2 ** attempt);
    log("retry", { attempt, delayMs: delay });
    setTimeout(connect, delay);
  });
}

// SIGUSR2: 回線の断を模して socket を close frame 無しで破棄する
process.on("SIGUSR2", () => {
  log("terminate-signal");
  ws?.terminate();
});
log("start", { pingMs, pongTimeoutMs, backoffMinMs, backoffMaxMs });
connect();
