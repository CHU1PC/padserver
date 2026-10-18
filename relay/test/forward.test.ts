import { describe, expect, test } from "bun:test";
import {
  FrameType,
  decodeFrame,
  decodeReqHead,
  encodeFrame,
  encodeResHead,
  type Frame,
  type HeaderPair,
} from "../src/frame";
import { requestHeaderPairs, responseHeaders } from "../src/forward";
import { TunnelObject, sha256Hex, type TunnelDeps, type TunnelSocket, type TunnelState } from "../src/tunnel";

const OPEN = 1;
const EMPTY = new Uint8Array(0);

class FakeSocket implements TunnelSocket {
  readyState = OPEN;
  attachment: unknown = { connectedAt: 1 };
  sent: Frame[] = [];
  closed: { code?: number; reason?: string } | null = null;

  send(message: Uint8Array): void {
    this.sent.push(decodeFrame(message));
  }
  serializeAttachment(value: unknown): void {
    this.attachment = structuredClone(value);
  }
  deserializeAttachment(): unknown {
    return this.attachment;
  }
  close(code?: number, reason?: string): void {
    this.closed = { code, reason };
    this.readyState = 2;
  }
}

class FakeState implements TunnelState {
  sockets: FakeSocket[] = [];
  acceptWebSocket(ws: TunnelSocket): void {
    this.sockets.push(ws as FakeSocket);
  }
  getWebSockets(): TunnelSocket[] {
    return this.sockets;
  }
  setWebSocketAutoResponse(): void {}
}

const deps: TunnelDeps = {
  createPair: () => ({ client: {}, server: new FakeSocket() }),
  upgradeResponse: () => new Response(null, { status: 200 }),
  autoResponsePair: () => null,
  now: () => 1,
};

function setup() {
  const state = new FakeState();
  const ws = new FakeSocket();
  state.sockets.push(ws);
  const object = new TunnelObject(state, {}, deps);
  return { state, ws, object };
}

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

function resHead(status: number, headers: HeaderPair[] = []): Uint8Array {
  return encodeResHead({ status, headers });
}

function send(object: TunnelObject, ws: FakeSocket, type: number, id: number, payload: Uint8Array = EMPTY): void {
  object.webSocketMessage(ws, encodeFrame(type as never, id, payload).buffer as ArrayBuffer);
}

describe("header filtering", () => {
  test("drops hop-by-hop, host, and forwarding headers from a request", () => {
    const headers = new Headers({
      Host: "a.example",
      Connection: "close",
      "X-Forwarded-For": "1.2.3.4",
      "X-Forwarded-Host": "evil.example",
      "X-Real-IP": "1.2.3.4",
      Forwarded: "for=1.2.3.4",
      "CF-Connecting-IP": "1.2.3.4",
      Range: "bytes=0-9",
      Authorization: "Bearer x",
      Cookie: "a=b",
    });
    expect(requestHeaderPairs(headers)).toEqual([
      ["authorization", "Bearer x"],
      ["cookie", "a=b"],
      ["range", "bytes=0-9"],
    ]);
  });

  test("drops transport headers from a response and keeps repeated names", () => {
    const headers = responseHeaders([
      ["content-encoding", "gzip"],
      ["transfer-encoding", "chunked"],
      ["content-length", "3"],
      ["set-cookie", "a=1"],
      ["set-cookie", "b=2"],
    ]);
    expect(headers.get("content-encoding")).toBeNull();
    expect(headers.get("transfer-encoding")).toBeNull();
    expect(headers.get("content-length")).toBe("3");
    expect(headers.getSetCookie()).toEqual(["a=1", "b=2"]);
  });
});

describe("forwarding a request", () => {
  test("answers 502 when no tunnel is connected", async () => {
    const object = new TunnelObject(new FakeState(), {}, deps);
    const response = await object.fetch(new Request("https://relay.example/a"));
    expect(response.status).toBe(502);
    expect(await response.text()).toBe("agent not connected");
  });

  test("sends ReqHead with the original host and no body frames for a GET", async () => {
    const { ws, object } = setup();
    const pending = object.fetch(new Request("https://Songs.Example.com/a%20b?x=1", { headers: { range: "bytes=0-1" } }));
    expect(ws.sent).toHaveLength(1);
    const [frame] = ws.sent;
    expect(frame?.type).toBe(FrameType.ReqHead);
    expect(frame?.id).toBe(1);
    expect(decodeReqHead(frame!.payload)).toEqual({
      method: "GET",
      path: "/a%20b?x=1",
      host: "songs.example.com",
      headers: [["range", "bytes=0-1"]],
      hasBody: false,
    });
    send(object, ws, FrameType.ResHead, 1, resHead(200));
    send(object, ws, FrameType.ResEnd, 1);
    expect((await pending).status).toBe(200);
  });

  test("streams response chunks in order and ends the stream", async () => {
    const { ws, object } = setup();
    const pending = object.fetch(new Request("https://relay.example/a"));
    send(object, ws, FrameType.ResHead, 1, resHead(200, [["content-type", "text/plain"]]));
    const response = await pending;
    expect(response.headers.get("content-type")).toBe("text/plain");
    send(object, ws, FrameType.ResBody, 1, new TextEncoder().encode("abc"));
    send(object, ws, FrameType.ResBody, 1, new TextEncoder().encode("de"));
    send(object, ws, FrameType.ResEnd, 1);
    expect(await response.text()).toBe("abcde");
  });

  test("returns a bodyless response for HEAD and 204", async () => {
    const { ws, object } = setup();
    const head = object.fetch(new Request("https://relay.example/a", { method: "HEAD" }));
    send(object, ws, FrameType.ResHead, 1, resHead(200, [["content-length", "5"]]));
    send(object, ws, FrameType.ResBody, 1, new TextEncoder().encode("hello"));
    send(object, ws, FrameType.ResEnd, 1);
    const headResponse = await head;
    expect(headResponse.body).toBeNull();
    expect(headResponse.headers.get("content-length")).toBe("5");

    const noContent = object.fetch(new Request("https://relay.example/b"));
    send(object, ws, FrameType.ResHead, 2, resHead(204));
    send(object, ws, FrameType.ResEnd, 2);
    expect((await noContent).status).toBe(204);
  });

  test("buffers a request body into 256 KiB chunks and ends with ReqEnd", async () => {
    const { ws, object } = setup();
    const size = 262_144 * 2 + 10;
    const body = new Uint8Array(size).fill(7);
    const pending = object.fetch(new Request("https://relay.example/up", { method: "POST", body }));
    await tick();
    const types = ws.sent.map((f) => f.type);
    expect(types).toEqual([FrameType.ReqHead, FrameType.ReqBody, FrameType.ReqBody, FrameType.ReqBody, FrameType.ReqEnd]);
    expect(decodeReqHead(ws.sent[0]!.payload).hasBody).toBe(true);
    expect(ws.sent.slice(1, 4).map((f) => f.payload.length)).toEqual([262_144, 262_144, 10]);
    send(object, ws, FrameType.ResHead, 1, resHead(200));
    send(object, ws, FrameType.ResEnd, 1);
    await pending;
  });

  test("sends ReqEnd for an empty body that is declared", async () => {
    const { ws, object } = setup();
    const pending = object.fetch(new Request("https://relay.example/up", { method: "POST", body: new Uint8Array(0) }));
    await tick();
    expect(ws.sent.map((f) => f.type)).toEqual([FrameType.ReqHead, FrameType.ReqEnd]);
    send(object, ws, FrameType.ResHead, 1, resHead(200));
    send(object, ws, FrameType.ResEnd, 1);
    await pending;
  });

  test("keeps concurrent requests apart by id", async () => {
    const { ws, object } = setup();
    const first = object.fetch(new Request("https://relay.example/1"));
    const second = object.fetch(new Request("https://relay.example/2"));
    expect(ws.sent.map((f) => f.id)).toEqual([1, 2]);
    send(object, ws, FrameType.ResHead, 2, resHead(202));
    send(object, ws, FrameType.ResHead, 1, resHead(201));
    send(object, ws, FrameType.ResEnd, 1);
    send(object, ws, FrameType.ResEnd, 2);
    expect([(await first).status, (await second).status]).toEqual([201, 202]);
  });

  test("ignores frames for unknown ids and text messages", async () => {
    const { ws, object } = setup();
    send(object, ws, FrameType.ResHead, 99, resHead(200));
    object.webSocketMessage(ws, "pong");
    expect(ws.closed).toBeNull();
  });
});

describe("failures", () => {
  test("answers 502 when the app cancels before ResHead", async () => {
    const { ws, object } = setup();
    const pending = object.fetch(new Request("https://relay.example/a"));
    send(object, ws, FrameType.Cancel, 1);
    const response = await pending;
    expect(response.status).toBe(502);
    expect(await response.text()).toBe("agent cancelled");
  });

  test("answers 502 and cancels when ResHead is invalid", async () => {
    const { ws, object } = setup();
    const pending = object.fetch(new Request("https://relay.example/a"));
    send(object, ws, FrameType.ResHead, 1, new TextEncoder().encode("{"));
    const response = await pending;
    expect(response.status).toBe(502);
    expect(await response.text()).toBe("invalid agent response");
    expect(ws.sent.at(-1)?.type).toBe(FrameType.Cancel);
  });

  test("errors the stream when the app cancels after ResHead", async () => {
    const { ws, object } = setup();
    const pending = object.fetch(new Request("https://relay.example/a"));
    send(object, ws, FrameType.ResHead, 1, resHead(200));
    const response = await pending;
    send(object, ws, FrameType.Cancel, 1);
    await expect(response.text()).rejects.toThrow();
  });

  test("closes the tunnel with 4001 on an unknown frame type", () => {
    const { ws, object } = setup();
    object.webSocketMessage(ws, new Uint8Array([99, 0, 0, 0, 1]).buffer);
    expect(ws.closed).toEqual({ code: 4001, reason: "protocol error" });
  });

  test("closes the tunnel with 4001 on an oversized body chunk", async () => {
    const { ws, object } = setup();
    const pending = object.fetch(new Request("https://relay.example/a"));
    send(object, ws, FrameType.ResHead, 1, resHead(200));
    await pending;
    send(object, ws, FrameType.ResBody, 1, new Uint8Array(1_048_577));
    expect(ws.closed?.code).toBe(4001);
  });

  test("answers 502 when the tunnel closes before ResHead", async () => {
    const { ws, object } = setup();
    const pending = object.fetch(new Request("https://relay.example/a"));
    await object.webSocketClose(ws, 1006, "", false);
    const response = await pending;
    expect(response.status).toBe(502);
    expect(await response.text()).toBe("agent disconnected");
  });

  test("answers 502 agent replaced when a new tunnel takes over", async () => {
    const token = "a".repeat(43);
    const state = new FakeState();
    const ws = new FakeSocket();
    state.sockets.push(ws);
    const object = new TunnelObject(state, { TOKEN_SHA256: await sha256Hex(token) }, deps);
    const pending = object.fetch(new Request("https://relay.example/a"));
    await object.fetch(
      new Request("https://relay.example/_padserver/tunnel", {
        headers: {
          upgrade: "websocket",
          authorization: `Bearer ${token}`,
          "sec-websocket-protocol": "padserver-relay.v1",
        },
      }),
    );
    expect(ws.closed?.code).toBe(4000);
    const response = await pending;
    expect(response.status).toBe(502);
    expect(await response.text()).toBe("agent replaced");
  });

  test("does not fail a request on another tunnel when an old one closes", async () => {
    const { state, ws, object } = setup();
    const old = new FakeSocket();
    old.attachment = { connectedAt: 0 };
    state.sockets.unshift(old);
    const pending = object.fetch(new Request("https://relay.example/a"));
    await object.webSocketClose(old, 1006, "", false);
    send(object, ws, FrameType.ResHead, 1, resHead(200));
    send(object, ws, FrameType.ResEnd, 1);
    expect((await pending).status).toBe(200);
  });

  test("ignores frames for a request from a socket that does not own it", async () => {
    const { state, ws, object } = setup();
    const other = new FakeSocket();
    other.attachment = { connectedAt: 0 };
    state.sockets.push(other);
    const pending = object.fetch(new Request("https://relay.example/a"));
    send(object, other, FrameType.ResHead, 1, resHead(500));
    send(object, ws, FrameType.ResHead, 1, resHead(200));
    send(object, ws, FrameType.ResEnd, 1);
    expect((await pending).status).toBe(200);
  });
});
