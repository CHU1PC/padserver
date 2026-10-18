import { describe, expect, test } from "bun:test";
import worker, { TunnelObject, type Env } from "../src/index";

function makeEnv(reply = new Response("from object")) {
  const forwarded: Request[] = [];
  const names: string[] = [];
  const env: Env = {
    TUNNEL: {
      idFromName: (name) => {
        names.push(name);
        return name;
      },
      get: () => ({
        fetch: async (request) => {
          forwarded.push(request);
          return reply;
        },
      }),
    },
  };
  return { env, forwarded, names };
}

describe("Worker routing", () => {
  test("exports the Durable Object class", () => expect(typeof TunnelObject).toBe("function"));

  test("passes a public request to the Durable Object", async () => {
    const { env, forwarded, names } = makeEnv();
    const response = await worker.fetch(new Request("https://relay.example/songs/a.mp3?x=1"), env);
    expect(await response.text()).toBe("from object");
    expect(forwarded.map((r) => r.url)).toEqual(["https://relay.example/songs/a.mp3?x=1"]);
    expect(names).toEqual(["tunnel"]);
  });

  test("passes the tunnel path to the Durable Object", async () => {
    const { env, forwarded } = makeEnv();
    await worker.fetch(new Request("https://relay.example/_padserver/tunnel", { headers: { upgrade: "websocket" } }), env);
    expect(forwarded).toHaveLength(1);
  });

  test("answers 404 for other private paths", async () => {
    const { env, forwarded } = makeEnv();
    const response = await worker.fetch(new Request("https://relay.example/_padserver/other"), env);
    expect(response.status).toBe(404);
    expect(await response.text()).toBe("not found");
    expect(forwarded).toHaveLength(0);
  });

  test("answers 501 for a visitor WebSocket upgrade", async () => {
    const { env, forwarded } = makeEnv();
    const response = await worker.fetch(new Request("https://relay.example/live", { headers: { upgrade: "websocket" } }), env);
    expect(response.status).toBe(501);
    expect(await response.text()).toBe("websocket not supported");
    expect(forwarded).toHaveLength(0);
  });
});
