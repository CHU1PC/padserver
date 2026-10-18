import { DurableObject } from "cloudflare:workers";
import {
  FrameType,
  decodeAckPayload,
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
}

const DEFAULT_UP_CHUNK = 256 * 1024;
// 0 は window なし (ack を待たずに送る)
const DEFAULT_UP_WINDOW = 4 * 1024 * 1024;
const EMPTY = new Uint8Array(0);

class PendingRequest {
  constructor(readonly socket: WebSocket) {}

  readonly queue: Uint8Array[] = [];
  queued = 0;
  ended = false;
  failure: Error | null = null;
  uploadInflight = 0;
  private bodyWake: (() => void) | null = null;
  private uploadWake: (() => void) | null = null;
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

  waitUploadAck(): Promise<void> {
    return new Promise((resolve) => {
      this.uploadWake = resolve;
    });
  }

  wakeUpload(): void {
    this.uploadWake?.();
    this.uploadWake = null;
  }

  fail(reason: Error): void {
    this.failure = reason;
    if (!this.headSettled) {
      this.headSettled = true;
      this.rejectHead(reason);
    }
    this.wakeBody();
    this.wakeUpload();
  }
}

function numberHeader(request: Request, name: string, fallback: number): number {
  const value = Number(request.headers.get(name));
  return Number.isFinite(value) && request.headers.has(name) ? value : fallback;
}

export class Relay extends DurableObject<Env> {
  private readonly pending = new Map<number, PendingRequest>();
  private nextId = 1;
  private maxQueued = 0;

  override async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/_ws") {
      for (const old of this.ctx.getWebSockets()) old.close(1000, "replaced");
      const pair = new WebSocketPair();
      this.ctx.acceptWebSocket(pair[1]);
      return new Response(null, { status: 101, webSocket: pair[0] });
    }
    if (url.pathname === "/_stats") {
      const body = { maxQueuedBytes: this.maxQueued, pending: this.pending.size };
      if (url.searchParams.has("reset")) this.maxQueued = 0;
      return Response.json(body);
    }
    const ws = this.ctx.getWebSockets()[0];
    if (!ws) return new Response("agent not connected", { status: 503 });
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

    const headers: [string, string][] = [];
    for (const [name, value] of request.headers) {
      if (name.startsWith("x-spike-") || name.startsWith("cf-") || name === "host") continue;
      headers.push([name, value]);
    }
    const head: ReqHead = {
      method: request.method,
      path: url.pathname + url.search,
      headers,
      hasBody: request.body !== null,
    };
    ws.send(encodeFrame(FrameType.ReqHead, id, encodeJson(head)));
    if (request.body) {
      void this.pumpUpload(
        ws,
        id,
        pending,
        request.body,
        numberHeader(request, "x-spike-up-chunk", DEFAULT_UP_CHUNK),
        numberHeader(request, "x-spike-up-window", DEFAULT_UP_WINDOW),
      );
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
            pending.queued -= chunk.length;
            const ack = new Uint8Array(4);
            new DataView(ack.buffer).setUint32(0, chunk.length);
            ws.send(encodeFrame(FrameType.Ack, id, ack));
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
            ws.send(encodeFrame(FrameType.Cancel, id, EMPTY));
          }
          pending.wakeUpload();
        },
      },
      { highWaterMark: 0 },
    );
    const outHeaders = new Headers();
    for (const [name, value] of resHead.headers) {
      if (["transfer-encoding", "connection", "content-encoding", "keep-alive"].includes(name)) continue;
      outHeaders.append(name, value);
    }
    const noBody = request.method === "HEAD" || resHead.status === 204 || resHead.status === 304;
    return new Response(noBody ? null : body, { status: resHead.status, headers: outHeaders });
  }

  private async pumpUpload(
    ws: WebSocket,
    id: number,
    pending: PendingRequest,
    body: ReadableStream<Uint8Array>,
    chunkSize: number,
    window: number,
  ): Promise<void> {
    const reader = body.getReader();
    // request.body は 4 KiB ほどの小さい塊で届くので, chunkSize になるまで溜めてから送る
    const buffer = new Uint8Array(chunkSize);
    let filled = 0;
    const flush = async (): Promise<boolean> => {
      while (window > 0 && pending.uploadInflight >= window && !pending.finished) {
        await pending.waitUploadAck();
      }
      if (pending.finished) return false;
      ws.send(encodeFrame(FrameType.ReqBody, id, buffer.subarray(0, filled)));
      pending.uploadInflight += filled;
      filled = 0;
      return true;
    };
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        for (let offset = 0; offset < value.length; ) {
          const n = Math.min(chunkSize - filled, value.length - offset);
          buffer.set(value.subarray(offset, offset + n), filled);
          filled += n;
          offset += n;
          if (filled === chunkSize && !(await flush())) {
            await reader.cancel();
            return;
          }
        }
      }
      if (filled > 0 && !(await flush())) return;
      ws.send(encodeFrame(FrameType.ReqEnd, id, EMPTY));
    } catch (error) {
      ws.send(encodeFrame(FrameType.Cancel, id, EMPTY));
      pending.fail(error as Error);
    }
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
        pending.queued += frame.payload.length;
        if (pending.queued > this.maxQueued) this.maxQueued = pending.queued;
        pending.wakeBody();
        break;
      case FrameType.ResEnd:
        pending.ended = true;
        pending.wakeBody();
        break;
      case FrameType.Cancel:
        pending.fail(new Error("cancelled by agent"));
        break;
      case FrameType.Ack:
        pending.uploadInflight -= decodeAckPayload(frame.payload);
        pending.wakeUpload();
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
    if (new URL(request.url).pathname === "/_sink") {
      let bytes = 0;
      if (request.body) for await (const chunk of request.body) bytes += chunk.length;
      return Response.json({ bytes });
    }
    return env.RELAY.get(env.RELAY.idFromName("relay")).fetch(request);
  },
};
