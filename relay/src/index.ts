import { TUNNEL_PATH, TunnelObject } from "./tunnel";
import { textResponse } from "./forward";

const PRIVATE_PREFIX = "/_padserver/";

interface TunnelNamespace {
  idFromName(name: string): unknown;
  get(id: unknown): { fetch(request: Request): Promise<Response> };
}

export interface Env {
  TUNNEL: TunnelNamespace;
}

async function fetch(request: Request, env: Env): Promise<Response> {
  const { pathname } = new URL(request.url);
  if (pathname.startsWith(PRIVATE_PREFIX) && pathname !== TUNNEL_PATH) return textResponse(404, "not found");
  if (pathname !== TUNNEL_PATH && request.headers.get("upgrade")?.toLowerCase() === "websocket") {
    return textResponse(501, "websocket not supported");
  }
  return env.TUNNEL.get(env.TUNNEL.idFromName("tunnel")).fetch(request);
}

export { TunnelObject };
export default { fetch };
