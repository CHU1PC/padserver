import { DurableObject } from "cloudflare:workers";
import {
  FrameType,
  decodeFrame,
  decodeResHead,
  encodeFrame,
  encodeJson,
  type ReqHead,
  type ResHead,
} from "../../shared/protocol.ts";

interface Env {
  RELAY: DurableObjectNamespace<Relay>;
  SPIKE_TOKEN: string;
  DEPLOY_N: string;
}

// 配備ごとに書き換えて, 動いている Durable Object が新しい code か見分ける
const CODE_REV = "r1";
const EMPTY = new Uint8Array(0);
// 古い socket を追い出すときの close code. client はこの code では繋ぎ直さない
const REPLACED_CODE = 4000;

class PendingRequest {
  constructor(readonly socket: WebSocket) {}

  readonly queue: Uint8Array[] = [];
  ended = false;
  failure: Error | null = null;
  private bodyWake: (() => void) | null = null;
  headSettled = false;
  resolveHead: (head: ResHead) => void = () => {};
  rejectHead: (reason: Error) => void = () => {};

  get finished(): boolean {
    return this.ended || this.failure !== null;
  }

  waitBody(): Promise<void> {
    return new Promise((resolve) => {
      this.bodyWake = resolve;
    });
  }

  wakeBody(): void {
    this.bodyWake?.();
    this.bodyWake = null;
  }

  fail(reason: Error): void {
    this.failure = reason;
    if (!this.headSettled) {
      this.headSettled = true;
      this.rejectHead(reason);
    }
    this.wakeBody();
  }
}

export class Relay extends DurableObject<Env> {
  private readonly pending = new Map<number, PendingRequest>();
  private nextId = 1;
  // 起動した時刻. Durable Object が作り直されたか (hibernation から起きたか) を見分ける
  private readonly bootedAt = Date.now();

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  override async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/_ws") {
      for (const old of this.ctx.getWebSockets()) old.close(REPLACED_CODE, "replaced");
      const pair = new WebSocketPair();
      this.ctx.acceptWebSocket(pair[1]);
      return new Response(null, { status: 101, webSocket: pair[0] });
    }
    if (url.pathname === "/_status") {
      const now = Date.now();
      const sockets = this.ctx.getWebSockets().map((ws) => {
        const last = this.ctx.getWebSocketAutoResponseTimestamp(ws);
        return { readyState: ws.readyState, pingAgeMs: last ? now - last.getTime() : null };
      });
      return Response.json({ rev: `${CODE_REV}/${this.env.DEPLOY_N}`, sockets, pending: this.pending.size, bootedAgoMs: now - this.bootedAt });
    }
    const open = this.ctx.getWebSockets().filter((ws) => ws.readyState === WebSocket.READY_STATE_OPEN);
    const ws = open[open.length - 1];
    if (!ws) return new Response("agent not connected", { status: 503 });
    const staleMs = Number(request.headers.get("x-spike-stale-ms") ?? 0);
    if (staleMs > 0) {
      const last = this.ctx.getWebSocketAutoResponseTimestamp(ws);
      if (last && Date.now() - last.getTime() > staleMs) return new Response("agent stale", { status: 503 });
    }
    return this.proxy(ws, request);
  }

  private async proxy(ws: WebSocket, request: Request): Promise<Response> {
    const id = this.nextId++;
    const url = new URL(request.url);
    const pending = new PendingRequest(ws);
    this.pending.set(id, pending);
    const headPromise = new Promise<ResHead>((resolve, reject) => {
      pending.resolveHead = resolve;
      pending.rejectHead = reject;
    });
    const head: ReqHead = { method: request.method, path: url.pathname + url.search, headers: [], hasBody: false };
    try {
      ws.send(encodeFrame(FrameType.ReqHead, id, encodeJson(head)));
    } catch (error) {
      this.pending.delete(id);
      return new Response(`relay send failed: ${(error as Error).message}`, { status: 502 });
    }

    let resHead: ResHead;
    try {
      resHead = await headPromise;
    } catch (error) {
      this.pending.delete(id);
      return new Response(`relay failure: ${(error as Error).message}`, { status: 502 });
    }

    const body = new ReadableStream<Uint8Array>(
      {
        pull: async (controller) => {
          while (pending.queue.length === 0 && !pending.finished) await pending.waitBody();
          const chunk = pending.queue.shift();
          if (chunk) {
            controller.enqueue(chunk);
            return;
          }
          this.pending.delete(id);
          if (pending.failure) controller.error(pending.failure);
          else controller.close();
        },
        cancel: () => {
          this.pending.delete(id);
          if (!pending.finished) {
            pending.ended = true;
            if (ws.readyState === WebSocket.READY_STATE_OPEN) ws.send(encodeFrame(FrameType.Cancel, id, EMPTY));
          }
        },
      },
      { highWaterMark: 0 },
    );
    const outHeaders = new Headers();
    for (const [name, value] of resHead.headers) {
      if (["transfer-encoding", "connection", "content-encoding", "keep-alive"].includes(name)) continue;
      outHeaders.append(name, value);
    }
    return new Response(body, { status: resHead.status, headers: outHeaders });
  }

  override webSocketMessage(_ws: WebSocket, message: string | ArrayBuffer): void {
    if (typeof message === "string") return;
    const frame = decodeFrame(message);
    const pending = this.pending.get(frame.id);
    if (!pending) return;
    switch (frame.type) {
      case FrameType.ResHead:
        pending.headSettled = true;
        pending.resolveHead(decodeResHead(frame.payload));
        break;
      case FrameType.ResBody:
        pending.queue.push(frame.payload);
        pending.wakeBody();
        break;
      case FrameType.ResEnd:
        pending.ended = true;
        pending.wakeBody();
        break;
      case FrameType.Cancel:
        pending.fail(new Error("cancelled by agent"));
        break;
      default:
        break;
    }
  }

  override webSocketClose(ws: WebSocket): void {
    this.failAll(ws, "agent disconnected");
  }

  override webSocketError(ws: WebSocket): void {
    this.failAll(ws, "agent socket error");
  }

  private failAll(ws: WebSocket, reason: string): void {
    for (const pending of this.pending.values()) {
      if (pending.socket === ws) pending.fail(new Error(reason));
    }
  }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.headers.get("x-spike-token") !== env.SPIKE_TOKEN) {
      return new Response("forbidden", { status: 403 });
    }
    if (new URL(request.url).pathname === "/_version") return new Response(`${CODE_REV}/${env.DEPLOY_N}`);
    return env.RELAY.get(env.RELAY.idFromName("relay")).fetch(request);
  },
};
