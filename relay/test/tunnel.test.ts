import { describe, expect, test } from "bun:test";
import {
  REPLACED_CLOSE_CODE,
  TunnelObject,
  type TunnelDeps,
  type TunnelSocket,
  type TunnelState,
  negotiateVersion,
  parseBearerToken,
  selectCurrentSocket,
  sha256Hex,
  verifyToken,
} from "../src/tunnel";

const OPEN = 1;
const CLOSING = 2;
const CLOSED = 3;

const token = "a".repeat(43);
const tokenHash = await sha256Hex(token);

class FakeSocket implements TunnelSocket {
  readyState = OPEN;
  attachment: unknown = null;
  closed: { code?: number; reason?: string } | null = null;

  send(): void {}

  serializeAttachment(value: unknown): void {
    this.attachment = structuredClone(value);
  }

  deserializeAttachment(): unknown {
    return this.attachment;
  }

  close(code?: number, reason?: string): void {
    this.closed = { code, reason };
    this.readyState = CLOSING;
  }
}

class FakeState implements TunnelState {
  sockets: FakeSocket[] = [];
  autoResponse: [string, string] | null = null;
  acceptCalls = 0;

  acceptWebSocket(ws: TunnelSocket): void {
    this.acceptCalls += 1;
    this.sockets.push(ws as FakeSocket);
  }

  getWebSockets(): TunnelSocket[] {
    return this.sockets;
  }

  setWebSocketAutoResponse(pair: unknown): void {
    this.autoResponse = pair as [string, string];
  }
}

function makeObject(state = new FakeState(), now = () => 1000) {
  const created: FakeSocket[] = [];
  const deps: TunnelDeps = {
    createPair: () => {
      const server = new FakeSocket();
      created.push(server);
      return { client: {}, server };
    },
    upgradeResponse: (_client, protocol) =>
      new Response(null, { status: 200, headers: { "x-upgrade": "1", "sec-websocket-protocol": protocol } }),
    autoResponsePair: (request, response) => [request, response],
    now,
  };
  return { state, created, object: new TunnelObject(state, { TOKEN_SHA256: tokenHash }, deps) };
}

function upgradeRequest(headers: Record<string, string>): Request {
  return new Request("https://relay.example/_padserver/tunnel", {
    headers: { upgrade: "websocket", ...headers },
  });
}

const good = { authorization: `Bearer ${token}`, "sec-websocket-protocol": "padserver-relay.v1" };

describe("parseBearerToken", () => {
  test("extracts the token", () => expect(parseBearerToken("Bearer abc")).toBe("abc"));
  test("rejects a missing header", () => expect(parseBearerToken(null)).toBeNull());
  test("rejects a non Bearer scheme", () => expect(parseBearerToken("Basic abc")).toBeNull());
  test("rejects an empty token", () => expect(parseBearerToken("Bearer ")).toBeNull());
});

describe("verifyToken", () => {
  test("accepts the right token", async () => expect(await verifyToken(`Bearer ${token}`, tokenHash)).toBe(true));
  test("rejects a wrong token", async () => expect(await verifyToken("Bearer wrong", tokenHash)).toBe(false));
  test("rejects a missing token", async () => expect(await verifyToken(null, tokenHash)).toBe(false));
  test("rejects a non Bearer header", async () => expect(await verifyToken(`Token ${token}`, tokenHash)).toBe(false));
  test("rejects an expected hash of the wrong length", async () =>
    expect(await verifyToken(`Bearer ${token}`, tokenHash.slice(0, 32))).toBe(false));
  test("rejects an uppercase expected hash", async () =>
    expect(await verifyToken(`Bearer ${token}`, tokenHash.toUpperCase())).toBe(false));
  test("rejects when the secret is unset", async () => expect(await verifyToken(`Bearer ${token}`, undefined)).toBe(false));
});

describe("negotiateVersion", () => {
  test("accepts version 1", () => expect(negotiateVersion("padserver-relay.v1")).toBe(1));
  test("picks the supported version among several", () =>
    expect(negotiateVersion("padserver-relay.v2, padserver-relay.v1")).toBe(1));
  test("returns null with no common version", () => expect(negotiateVersion("padserver-relay.v2")).toBeNull());
  test("returns null for a missing header", () => expect(negotiateVersion(null)).toBeNull());
  test("ignores unrelated protocols", () => expect(negotiateVersion("chat, padserver-relay.v1")).toBe(1));
  test("rejects a malformed version", () => expect(negotiateVersion("padserver-relay.v1x")).toBeNull());
});

describe("selectCurrentSocket", () => {
  function socket(readyState: number, attachment: unknown): FakeSocket {
    const s = new FakeSocket();
    s.readyState = readyState;
    s.attachment = attachment;
    return s;
  }

  test("returns null with no sockets", () => expect(selectCurrentSocket([])).toBeNull());
  test("prefers the newest OPEN socket", () => {
    const older = socket(OPEN, { connectedAt: 1 });
    const newer = socket(OPEN, { connectedAt: 2 });
    expect(selectCurrentSocket([newer, older])).toBe(newer);
  });
  test("skips CLOSING and CLOSED sockets", () => {
    const open = socket(OPEN, { connectedAt: 1 });
    const closing = socket(CLOSING, { connectedAt: 5 });
    const closed = socket(CLOSED, { connectedAt: 6 });
    expect(selectCurrentSocket([closing, closed, open])).toBe(open);
  });
  test("skips a replaced socket even while OPEN", () => {
    const replaced = socket(OPEN, { connectedAt: 9, replaced: true });
    const current = socket(OPEN, { connectedAt: 1 });
    expect(selectCurrentSocket([replaced, current])).toBe(current);
  });
  test("returns null when only CLOSING sockets remain", () =>
    expect(selectCurrentSocket([socket(CLOSING, { connectedAt: 1 })])).toBeNull());
  test("ignores sockets with a malformed attachment", () =>
    expect(selectCurrentSocket([socket(OPEN, null)])).toBeNull());
});

describe("TunnelObject.fetch", () => {
  test("sets the ping/pong auto response", () => {
    const { state } = makeObject();
    expect(state.autoResponse).toEqual(["ping", "pong"]);
  });

  test("accepts an authenticated upgrade and echoes the subprotocol", async () => {
    const { object, state, created } = makeObject();
    const res = await object.fetch(upgradeRequest(good));
    expect(res.headers.get("x-upgrade")).toBe("1");
    expect(res.headers.get("sec-websocket-protocol")).toBe("padserver-relay.v1");
    expect(state.acceptCalls).toBe(1);
    expect(created[0]?.attachment).toEqual({ connectedAt: 1000 });
  });

  test("rejects a wrong token with 401 and never accepts", async () => {
    const { object, state, created } = makeObject();
    const res = await object.fetch(upgradeRequest({ ...good, authorization: "Bearer wrong" }));
    expect(res.status).toBe(401);
    expect(await res.text()).toBe("unauthorized");
    expect(state.acceptCalls).toBe(0);
    expect(created.length).toBe(0);
  });

  test("rejects a missing token with the same 401", async () => {
    const { object, state } = makeObject();
    const res = await object.fetch(upgradeRequest({ "sec-websocket-protocol": "padserver-relay.v1" }));
    expect(res.status).toBe(401);
    expect(await res.text()).toBe("unauthorized");
    expect(state.acceptCalls).toBe(0);
  });

  test("rejects an unsupported version with 400", async () => {
    const { object, state } = makeObject();
    const res = await object.fetch(upgradeRequest({ ...good, "sec-websocket-protocol": "padserver-relay.v2" }));
    expect(res.status).toBe(400);
    expect(await res.text()).toBe("unsupported protocol version");
    expect(state.acceptCalls).toBe(0);
  });

  test("answers 401 before 400 when both are wrong", async () => {
    const { object } = makeObject();
    const res = await object.fetch(
      upgradeRequest({ authorization: "Bearer wrong", "sec-websocket-protocol": "padserver-relay.v2" }),
    );
    expect(res.status).toBe(401);
  });

  test("rejects a request that is not a websocket upgrade", async () => {
    const { object, state } = makeObject();
    const res = await object.fetch(
      new Request("https://relay.example/_padserver/tunnel", {
        headers: { authorization: good.authorization, "sec-websocket-protocol": "padserver-relay.v1" },
      }),
    );
    expect(res.status).toBe(426);
    expect(state.acceptCalls).toBe(0);
  });

  test("a new socket replaces the old one with code 4000", async () => {
    let clock = 1000;
    const { object, state, created } = makeObject(new FakeState(), () => clock);
    await object.fetch(upgradeRequest(good));
    clock = 2000;
    await object.fetch(upgradeRequest(good));
    const [first, second] = created;
    expect(first?.closed).toEqual({ code: REPLACED_CLOSE_CODE, reason: "replaced" });
    expect(REPLACED_CLOSE_CODE).toBe(4000);
    expect(first?.attachment).toEqual({ connectedAt: 1000, replaced: true });
    expect(second?.closed).toBeNull();
    expect(selectCurrentSocket(state.getWebSockets())).toBe(second ?? null);
  });

  test("a late close of the replaced socket leaves the new socket alone", async () => {
    let clock = 1000;
    const { object, state, created } = makeObject(new FakeState(), () => clock);
    await object.fetch(upgradeRequest(good));
    clock = 2000;
    await object.fetch(upgradeRequest(good));
    const [first, second] = created;
    if (!first || !second) throw new Error("sockets missing");
    await object.webSocketClose(first, REPLACED_CLOSE_CODE, "replaced", true);
    expect(second.closed).toBeNull();
    expect(second.readyState).toBe(OPEN);
    expect(selectCurrentSocket(state.getWebSockets())).toBe(second);
  });
});

describe("TunnelObject close and error handlers", () => {
  test("webSocketClose completes the close handshake with a valid code", async () => {
    const { object } = makeObject();
    const ws = new FakeSocket();
    await object.webSocketClose(ws, 1001, "going away", true);
    expect(ws.closed?.code).toBe(1001);
  });

  test("webSocketClose maps a reserved code to 1000", async () => {
    const { object } = makeObject();
    const ws = new FakeSocket();
    await object.webSocketClose(ws, 1006, "", false);
    expect(ws.closed?.code).toBe(1000);
  });

  test("webSocketClose skips a socket that is already CLOSED", async () => {
    const { object } = makeObject();
    const ws = new FakeSocket();
    ws.readyState = CLOSED;
    await object.webSocketClose(ws, 1000, "", true);
    expect(ws.closed).toBeNull();
  });

  test("webSocketError closes the socket", async () => {
    const { object } = makeObject();
    const ws = new FakeSocket();
    await object.webSocketError(ws, new Error("boom"));
    expect(ws.closed?.code).toBe(1011);
  });

  test("webSocketMessage ignores messages", () => {
    const { object } = makeObject();
    expect(() => object.webSocketMessage(new FakeSocket(), "hello")).not.toThrow();
  });
});
