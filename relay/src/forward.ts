import {
  FrameError,
  FrameType,
  checkBodyChunk,
  decodeFrame,
  decodeResHead,
  encodeFrame,
  encodeReqHead,
  type HeaderPair,
} from "./frame";

const REQUEST_CHUNK_SIZE = 262_144;
const NO_BODY_STATUSES = new Set([204, 205, 304]);
const EMPTY = new Uint8Array(0);

export const PROTOCOL_ERROR_CLOSE_CODE = 4001;

const DROPPED_REQUEST_HEADERS = new Set([
  "host",
  "connection",
  "keep-alive",
  "transfer-encoding",
  "upgrade",
  "forwarded",
  "x-real-ip",
]);
const DROPPED_RESPONSE_HEADERS = new Set(["transfer-encoding", "connection", "keep-alive", "content-encoding"]);

export interface ForwardSocket {
  send(message: Uint8Array): void;
  close(code?: number, reason?: string): void;
}

interface PendingRequest {
  ws: ForwardSocket;
  method: string;
  settle: (response: Response) => void;
  headReceived: boolean;
  controller: ReadableStreamDefaultController<Uint8Array> | null;
}

export function textResponse(status: number, body: string, extra: Record<string, string> = {}): Response {
  return new Response(body, {
    status,
    headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store", ...extra },
  });
}

export function requestHeaderPairs(headers: Headers): HeaderPair[] {
  const pairs: HeaderPair[] = [];
  headers.forEach((value, name) => {
    const lower = name.toLowerCase();
    if (DROPPED_REQUEST_HEADERS.has(lower) || lower.startsWith("x-forwarded-") || lower.startsWith("cf-")) return;
    pairs.push([lower, value]);
  });
  return pairs;
}

export function responseHeaders(pairs: HeaderPair[]): Headers {
  const headers = new Headers();
  for (const [name, value] of pairs) {
    if (!DROPPED_RESPONSE_HEADERS.has(name.toLowerCase())) headers.append(name, value);
  }
  return headers;
}

export class RequestForwarder {
  private readonly pending = new Map<number, PendingRequest>();
  private nextId = 1;

  forward(request: Request, ws: ForwardSocket): Promise<Response> {
    const id = this.allocateId();
    const url = new URL(request.url);
    const { method } = request;
    const head = encodeReqHead({
      method,
      path: url.pathname + url.search,
      host: url.host,
      headers: requestHeaderPairs(request.headers),
      hasBody: request.body !== null,
    });
    return new Promise<Response>((settle) => {
      this.pending.set(id, { ws, method, settle, headReceived: false, controller: null });
      ws.send(encodeFrame(FrameType.ReqHead, id, head));
      if (request.body !== null) void this.pumpBody(id, ws, request.body);
    });
  }

  handleMessage(ws: ForwardSocket, message: string | ArrayBuffer): void {
    if (typeof message === "string") return;
    let frame;
    try {
      frame = decodeFrame(message);
    } catch (error) {
      if (error instanceof FrameError) return this.closeForProtocolError(ws);
      throw error;
    }
    const entry = this.pending.get(frame.id);
    if (entry === undefined || entry.ws !== ws) return;
    try {
      this.handleFrame(frame.id, entry, frame.type, frame.payload);
    } catch (error) {
      if (!(error instanceof FrameError)) throw error;
      if (error.level === "connection") return this.closeForProtocolError(ws);
      this.fail(frame.id, entry, 502, "invalid agent response");
      ws.send(encodeFrame(FrameType.Cancel, frame.id, EMPTY));
    }
  }

  failSocket(ws: ForwardSocket, body: string): void {
    for (const [id, entry] of [...this.pending]) {
      if (entry.ws === ws) this.fail(id, entry, 502, body);
    }
  }

  private handleFrame(id: number, entry: PendingRequest, type: number, payload: Uint8Array): void {
    switch (type) {
      case FrameType.ResHead:
        if (!entry.headReceived) this.startResponse(id, entry, payload);
        return;
      case FrameType.ResBody:
        checkBodyChunk(payload);
        if (entry.controller !== null && payload.length > 0) entry.controller.enqueue(payload.slice());
        return;
      case FrameType.ResEnd:
        this.pending.delete(id);
        entry.controller?.close();
        return;
      case FrameType.Cancel:
        this.fail(id, entry, 502, "agent cancelled");
        return;
    }
  }

  private startResponse(id: number, entry: PendingRequest, payload: Uint8Array): void {
    const head = decodeResHead(payload);
    const headers = responseHeaders(head.headers);
    entry.headReceived = true;
    if (entry.method === "HEAD" || NO_BODY_STATUSES.has(head.status)) {
      entry.settle(new Response(null, { status: head.status, headers }));
      return;
    }
    const body = new ReadableStream<Uint8Array>({
      start: (controller) => {
        entry.controller = controller;
      },
      cancel: () => {
        this.pending.delete(id);
      },
    });
    entry.settle(new Response(body, { status: head.status, headers }));
  }

  private fail(id: number, entry: PendingRequest, status: number, body: string): void {
    this.pending.delete(id);
    if (!entry.headReceived) entry.settle(textResponse(status, body));
    else entry.controller?.error(new Error(body));
  }

  private closeForProtocolError(ws: ForwardSocket): void {
    this.failSocket(ws, "agent disconnected");
    ws.close(PROTOCOL_ERROR_CLOSE_CODE, "protocol error");
  }

  private allocateId(): number {
    for (;;) {
      const id = this.nextId;
      this.nextId = id >= 0xffff_ffff ? 1 : id + 1;
      if (!this.pending.has(id)) return id;
    }
  }

  private async pumpBody(id: number, ws: ForwardSocket, body: ReadableStream<Uint8Array>): Promise<void> {
    const buffer = new Uint8Array(REQUEST_CHUNK_SIZE);
    let length = 0;
    const flush = (): void => {
      ws.send(encodeFrame(FrameType.ReqBody, id, buffer.subarray(0, length)));
      length = 0;
    };
    try {
      const reader = body.getReader();
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        if (!this.pending.has(id)) return;
        for (let offset = 0; offset < value.length; ) {
          const size = Math.min(REQUEST_CHUNK_SIZE - length, value.length - offset);
          buffer.set(value.subarray(offset, offset + size), length);
          length += size;
          offset += size;
          if (length === REQUEST_CHUNK_SIZE) flush();
        }
      }
      if (length > 0) flush();
      if (!this.pending.has(id)) return;
      ws.send(encodeFrame(FrameType.ReqEnd, id, EMPTY));
    } catch {
      const entry = this.pending.get(id);
      if (entry === undefined) return;
      this.fail(id, entry, 502, "agent disconnected");
      ws.send(encodeFrame(FrameType.Cancel, id, EMPTY));
    }
  }
}
