import { RequestForwarder, textResponse } from "./forward";

const SUPPORTED_VERSIONS = [1];
const PROTOCOL_PREFIX = "padserver-relay.v";
const READY_STATE_OPEN = 1;
const READY_STATE_CLOSED = 3;

export const REPLACED_CLOSE_CODE = 4000;

export const TUNNEL_PATH = "/_padserver/tunnel";

export interface TunnelSocket {
  readonly readyState: number;
  send(message: Uint8Array): void;
  close(code?: number, reason?: string): void;
  serializeAttachment(value: unknown): void;
  deserializeAttachment(): unknown;
}

export interface TunnelState {
  acceptWebSocket(ws: TunnelSocket): void;
  getWebSockets(): TunnelSocket[];
  setWebSocketAutoResponse(pair: unknown): void;
}

export interface TunnelEnv {
  TOKEN_SHA256?: string;
}

export interface TunnelDeps {
  createPair(): { client: unknown; server: TunnelSocket };
  upgradeResponse(client: unknown, protocol: string): Response;
  autoResponsePair(request: string, response: string): unknown;
  now(): number;
}

interface SocketAttachment {
  connectedAt: number;
  replaced?: true;
}

declare class WebSocketPair {
  0: unknown;
  1: TunnelSocket;
}

declare class WebSocketRequestResponsePair {
  constructor(request: string, response: string);
}

const workersDeps: TunnelDeps = {
  createPair: () => {
    const pair = new WebSocketPair();
    return { client: pair[0], server: pair[1] };
  },
  upgradeResponse: (client, protocol) =>
    new Response(null, {
      status: 101,
      webSocket: client,
      headers: { "sec-websocket-protocol": protocol },
    } as ResponseInit),
  autoResponsePair: (request, response) => new WebSocketRequestResponsePair(request, response),
  now: () => Date.now(),
};

export async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

export function parseBearerToken(header: string | null): string | null {
  if (header === null || !header.startsWith("Bearer ")) return null;
  const token = header.slice("Bearer ".length);
  return token === "" ? null : token;
}

function constantTimeEqual(a: string, b: string): boolean {
  const left = new TextEncoder().encode(a);
  const right = new TextEncoder().encode(b);
  if (left.length !== right.length) return false;
  let diff = 0;
  for (let i = 0; i < left.length; i++) diff |= (left[i] ?? 0) ^ (right[i] ?? 0);
  return diff === 0;
}

export async function verifyToken(authorization: string | null, expectedSha256: string | undefined): Promise<boolean> {
  const token = parseBearerToken(authorization);
  if (token === null || expectedSha256 === undefined) return false;
  return constantTimeEqual(await sha256Hex(token), expectedSha256);
}

export function negotiateVersion(header: string | null): number | null {
  if (header === null) return null;
  let best: number | null = null;
  for (const entry of header.split(",")) {
    const protocol = entry.trim();
    if (!protocol.startsWith(PROTOCOL_PREFIX)) continue;
    const digits = protocol.slice(PROTOCOL_PREFIX.length);
    if (!/^[0-9]+$/.test(digits)) continue;
    const version = Number(digits);
    if (SUPPORTED_VERSIONS.includes(version) && (best === null || version > best)) best = version;
  }
  return best;
}

function readAttachment(ws: TunnelSocket): SocketAttachment | null {
  const value = ws.deserializeAttachment();
  if (typeof value !== "object" || value === null) return null;
  const { connectedAt, replaced } = value as { connectedAt?: unknown; replaced?: unknown };
  if (typeof connectedAt !== "number") return null;
  return replaced === true ? { connectedAt, replaced } : { connectedAt };
}

export function selectCurrentSocket(sockets: TunnelSocket[]): TunnelSocket | null {
  let current: TunnelSocket | null = null;
  let currentAt = -Infinity;
  for (const ws of sockets) {
    if (ws.readyState !== READY_STATE_OPEN) continue;
    const attachment = readAttachment(ws);
    if (attachment === null || attachment.replaced) continue;
    if (attachment.connectedAt >= currentAt) {
      current = ws;
      currentAt = attachment.connectedAt;
    }
  }
  return current;
}

function closeCodeFor(code: number): number {
  return code >= 1000 && code < 5000 && code !== 1005 && code !== 1006 && code !== 1015 ? code : 1000;
}

export class TunnelObject {
  private readonly forwarder = new RequestForwarder();

  constructor(
    private readonly state: TunnelState,
    private readonly env: TunnelEnv,
    private readonly deps: TunnelDeps = workersDeps,
  ) {
    state.setWebSocketAutoResponse(deps.autoResponsePair("ping", "pong"));
  }

  async fetch(request: Request): Promise<Response> {
    if (new URL(request.url).pathname !== TUNNEL_PATH) return this.forward(request);
    if (!(await verifyToken(request.headers.get("authorization"), this.env.TOKEN_SHA256))) {
      return textResponse(401, "unauthorized");
    }
    const version = negotiateVersion(request.headers.get("sec-websocket-protocol"));
    if (version === null) return textResponse(400, "unsupported protocol version");
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") return textResponse(426, "upgrade required");

    this.replaceCurrentSockets();
    const { client, server } = this.deps.createPair();
    this.state.acceptWebSocket(server);
    server.serializeAttachment({ connectedAt: this.deps.now() } satisfies SocketAttachment);
    return this.deps.upgradeResponse(client, `${PROTOCOL_PREFIX}${version}`);
  }

  webSocketMessage(ws: TunnelSocket, message: string | ArrayBuffer): void {
    this.forwarder.handleMessage(ws, message);
  }

  async webSocketClose(ws: TunnelSocket, code: number, _reason: string, _wasClean: boolean): Promise<void> {
    this.forwarder.failSocket(ws, "agent disconnected");
    if (ws.readyState === READY_STATE_CLOSED) return;
    ws.close(closeCodeFor(code));
  }

  async webSocketError(ws: TunnelSocket, _error: unknown): Promise<void> {
    this.forwarder.failSocket(ws, "agent disconnected");
    if (ws.readyState === READY_STATE_CLOSED) return;
    ws.close(1011, "error");
  }

  private forward(request: Request): Promise<Response> {
    const ws = selectCurrentSocket(this.state.getWebSockets());
    if (ws === null) return Promise.resolve(textResponse(502, "agent not connected"));
    return this.forwarder.forward(request, ws);
  }

  private replaceCurrentSockets(): void {
    for (const ws of this.state.getWebSockets()) {
      const attachment = readAttachment(ws);
      if (ws.readyState !== READY_STATE_OPEN || attachment === null || attachment.replaced) continue;
      ws.serializeAttachment({ ...attachment, replaced: true } satisfies SocketAttachment);
      ws.close(REPLACED_CLOSE_CODE, "replaced");
      this.forwarder.failSocket(ws, "agent replaced");
    }
  }
}
