import type { Subprocess } from "bun";

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required`);
  return value;
}

const relayUrl = requireEnv("RELAY_URL");
const token = requireEnv("SPIKE_TOKEN");
const headers = { "x-spike-token": token };
const clientDir = new URL("../client/", import.meta.url).pathname;
const workerDir = new URL("../worker/", import.meta.url).pathname;

interface Sample {
  start: number;
  end: number;
  result: string;
}

interface Mark {
  at: number;
  text: string;
}

interface Agent {
  name: string;
  proc: Subprocess;
  events: { event: string; at: number; [key: string]: string | number }[];
}

function spawnAgent(name: string, env: Record<string, string>): Agent {
  const proc = Bun.spawn(["bun", `${clientDir}agent.ts`], {
    env: { ...process.env, RELAY_URL: relayUrl, SPIKE_TOKEN: token, ...env },
    stdout: "pipe",
    stderr: "inherit",
  });
  const agent: Agent = { name, proc, events: [] };
  void proc.exited.then((code) => agent.events.push({ event: "process-exit", at: Date.now(), code }));
  void (async () => {
    const decoder = new TextDecoder();
    let rest = "";
    for await (const chunk of proc.stdout as ReadableStream<Uint8Array>) {
      rest += decoder.decode(chunk);
      const lines = rest.split("\n");
      rest = lines.pop() ?? "";
      for (const line of lines) agent.events.push(JSON.parse(line));
    }
  })();
  return agent;
}

// Bun の proc.kill("SIGSTOP") などは macOS で別の signal に変わるので, kill コマンドを使う
function signal(agent: Agent, name: "STOP" | "CONT" | "USR2"): void {
  Bun.spawnSync(["kill", `-${name}`, String(agent.proc.pid)]);
}

async function probeOnce(path: string, timeoutMs: number, extra: Record<string, string> = {}): Promise<Sample> {
  const start = Date.now();
  try {
    const response = await fetch(relayUrl + path, {
      headers: { ...headers, ...extra },
      signal: AbortSignal.timeout(timeoutMs),
    });
    const text = await response.text();
    return { start, end: Date.now(), result: `${response.status} ${text.slice(0, 160).replace(/\s+/g, " ")}` };
  } catch (error) {
    return { start, end: Date.now(), result: `error ${(error as Error).name}` };
  }
}

class Prober {
  readonly samples: Sample[] = [];
  readonly statuses: Sample[] = [];
  readonly versions: Sample[] = [];
  private running = true;
  private readonly loops: Promise<void>[];

  constructor(intervalMs: number, timeoutMs: number, extra: Record<string, string>) {
    const loop = async (path: string, sink: Sample[], timeout: number, headersExtra: Record<string, string>) => {
      while (this.running) {
        sink.push(await probeOnce(path, timeout, headersExtra));
        await Bun.sleep(intervalMs);
      }
    };
    this.loops = [
      loop("/ping", this.samples, timeoutMs, extra), loop("/_status", this.statuses, timeoutMs, {}),
      loop("/_version", this.versions, timeoutMs, {}),
    ];
  }

  async stop(): Promise<void> {
    this.running = false;
    await Promise.all(this.loops);
  }
}

// 結果が前の標本から変わった標本だけを時系列に並べる
function transitions(samples: Sample[], t0: number, label: string, normalize: (r: string) => string): string[] {
  const out: string[] = [];
  let last = "";
  for (const s of samples) {
    const key = normalize(s.result);
    if (key !== last) {
      out.push(`  +${((s.start - t0) / 1000).toFixed(3)}s ${label} ${s.result} (took ${s.end - s.start}ms)`);
      last = key;
    }
  }
  return out;
}

function summarize(
  title: string,
  t0: number,
  marks: Mark[],
  prober: Prober,
  agents: Agent[],
): { firstFailMs: number | null; recoverMs: number | null } {
  console.log(`SCENARIO ${title}`);
  const lines: { at: number; text: string }[] = marks.map((m) => ({ at: m.at, text: `mark ${m.text}` }));
  for (const agent of agents) {
    for (const e of agent.events) {
      const { event, at, ...rest } = e;
      lines.push({ at, text: `${agent.name} ${event} ${JSON.stringify(rest)}` });
    }
  }
  const fail = prober.samples.find((s) => s.start >= t0 && !s.result.startsWith("200"));
  const recover = fail ? prober.samples.find((s) => s.start > fail.start && s.result.startsWith("200")) : undefined;
  lines.sort((a, b) => a.at - b.at);
  for (const line of lines) console.log(`  +${((line.at - t0) / 1000).toFixed(3)}s ${line.text}`);
  for (const line of transitions(prober.samples.filter((s) => s.start >= t0 - 500), t0, "public", (r) => r)) console.log(line);
  const statusKey = (r: string): string => {
    const sockets = /"sockets":(\[.*?\])/.exec(r)?.[1]?.replace(/"pingAgeMs":\d+/g, "pingAge");
    const deployN = /"rev":"([^"]+)"/.exec(r)?.[1];
    return `${deployN} ${sockets ?? r}`;
  };
  for (const line of transitions(prober.statuses.filter((s) => s.start >= t0 - 500), t0, "status", statusKey)) console.log(line);
  for (const line of transitions(prober.versions.filter((s) => s.start >= t0 - 500), t0, "worker_version", (r) => r)) console.log(line);
  let nextAge = 0;
  for (const s of prober.statuses) {
    if (s.start - t0 < nextAge) continue;
    nextAge = s.start - t0 + 10000;
    console.log(`  +${((s.start - t0) / 1000).toFixed(1)}s status_sample ${s.result}`);
  }
  const firstFailMs = fail ? fail.start - t0 : null;
  const recoverMs = recover ? recover.end - t0 : null;
  console.log(`RESULT ${title} first_non200_ms=${firstFailMs} first_200_after_ms=${recoverMs}`);
  return { firstFailMs, recoverMs };
}

async function waitFor200(timeoutMs: number): Promise<void> {
  const until = Date.now() + timeoutMs;
  while (Date.now() < until) {
    if ((await probeOnce("/ping", 3000)).result.startsWith("200")) return;
    await Bun.sleep(200);
  }
  throw new Error("relay did not become reachable");
}

async function stopAll(agents: Agent[]): Promise<void> {
  for (const agent of agents) {
    signal(agent, "CONT");
    agent.proc.kill("SIGKILL");
    await agent.proc.exited;
  }
}

const base = (extra: Record<string, string> = {}): Record<string, string> => ({ PING_MS: process.env.PING_MS ?? "20000", ...extra });

async function scenario(mode: string, run: number, arg: number): Promise<void> {
  const agent = spawnAgent("A", base());
  const agents = [agent];
  await waitFor200(15000);
  await Bun.sleep(1000);
  const marks: Mark[] = [];
  const stale: Record<string, string> = process.env.STALE_MS ? { "x-spike-stale-ms": process.env.STALE_MS } : {};
  const prober = new Prober(100, mode === "freeze" || mode === "takeover" ? 5000 : 3000, stale);
  await Bun.sleep(2000);
  const t0 = Date.now();
  if (mode === "terminate") {
    marks.push({ at: t0, text: "send SIGUSR2 (socket terminate)" });
    signal(agent, "USR2");
    await Bun.sleep(6000);
  } else if (mode === "kill") {
    marks.push({ at: t0, text: "kill -9 agent A, spawn agent B" });
    agent.proc.kill("SIGKILL");
    agents.push(spawnAgent("B", base()));
    await Bun.sleep(6000);
  } else if (mode === "freeze") {
    marks.push({ at: t0, text: `SIGSTOP agent A for ${arg}s` });
    signal(agent, "STOP");
    await Bun.sleep(arg * 1000);
    marks.push({ at: Date.now(), text: "SIGCONT agent A" });
    signal(agent, "CONT");
    await Bun.sleep(8000);
  } else if (mode === "takeover") {
    marks.push({ at: t0, text: "SIGSTOP agent A, spawn agent B" });
    signal(agent, "STOP");
    agents.push(spawnAgent("B", base()));
    await Bun.sleep(8000);
    marks.push({ at: Date.now(), text: "SIGCONT agent A" });
    signal(agent, "CONT");
    await Bun.sleep(8000);
  }
  await prober.stop();
  summarize(`${mode} run=${run}`, t0, marks, prober, agents);
  const connected = await probeOnce("/_status", 5000);
  console.log(`FINAL status ${connected.result}`);
  await stopAll(agents);
}

// wrangler deploy を実行する. BUMP_CODE=1 なら, 配備の間だけ CODE_REV を書き換えて code を変える
async function wranglerDeploy(): Promise<number> {
  const sourcePath = `${workerDir}src/index.ts`;
  const original = await Bun.file(sourcePath).text();
  if (process.env.BUMP_CODE === "1") await Bun.write(sourcePath, original.replace(/CODE_REV = "r\d+"/, `CODE_REV = "r${Date.now()}"`));
  const proc = Bun.spawn(
    ["bunx", "wrangler", "deploy", "--var", `SPIKE_TOKEN:${token}`, "--var", `DEPLOY_N:${Date.now()}`],
    { cwd: workerDir, stdout: "pipe", stderr: "pipe" },
  );
  const code = await proc.exited;
  await Bun.write(sourcePath, original);
  return code;
}

// wrangler deploy をくり返し, 要求の流れと SSE の stream を同時に観察する
async function deploy(run: number): Promise<void> {
  const agent = spawnAgent("A", base());
  await waitFor200(15000);
  await Bun.sleep(1000);
  const prober = new Prober(Number(process.env.PROBE_INTERVAL_MS ?? 100), 3000, {});
  const sse = (async () => {
    const start = Date.now();
    let events = 0;
    try {
      const response = await fetch(`${relayUrl}/sse?count=600&interval=100`, { headers });
      const reader = response.body?.getReader();
      for (;;) {
        const chunk = await reader?.read();
        if (!chunk || chunk.done) return `ended normally events~${events} after ${Date.now() - start}ms`;
        events += 1;
      }
    } catch (error) {
      return `failed ${(error as Error).message} chunks=${events} after ${Date.now() - start}ms`;
    }
  })();
  await Bun.sleep(3000);
  const t0 = Date.now();
  const marks: Mark[] = [{ at: t0, text: "wrangler deploy start" }];
  const code = await wranglerDeploy();
  marks.push({ at: Date.now(), text: `wrangler deploy end exit=${code}` });
  await Bun.sleep(Number(process.env.DEPLOY_WAIT_MS ?? 12000));
  await prober.stop();
  summarize(`deploy run=${run}`, t0, marks, prober, [agent]);
  console.log(`SSE ${await Promise.race([sse, Bun.sleep(1000).then(() => "still running")])}`);
  await stopAll([agent]);
}

// 要求を流さず idle にして (hibernation に入れて) から配備し, 前後の状態を見る
async function deployIdle(run: number): Promise<void> {
  const agent = spawnAgent("A", base());
  await waitFor200(15000);
  console.log(`SCENARIO deploy-idle run=${run}`);
  console.log(`  before ${(await probeOnce("/_status", 5000)).result}`);
  await Bun.sleep(30000);
  const t0 = Date.now();
  const code = await wranglerDeploy();
  console.log(`  deploy exit=${code} took ${Date.now() - t0}ms`);
  await Bun.sleep(30000);
  console.log(`  after_version ${(await probeOnce("/_version", 5000)).result}`);
  console.log(`  after_status ${(await probeOnce("/_status", 5000)).result}`);
  for (const e of agent.events) console.log(`  agent ${JSON.stringify(e)}`);
  await stopAll([agent]);
}

// 凍らせた agent A を agent B が追い出し, DO が hibernation に入った後に, A の socket がどう見えるかを見る
async function ghost(run: number): Promise<void> {
  const a = spawnAgent("A", base());
  await waitFor200(15000);
  signal(a, "STOP");
  const b = spawnAgent("B", base());
  console.log(`SCENARIO ghost run=${run}`);
  await Bun.sleep(3000);
  console.log(`  +3s status ${(await probeOnce("/_status", 5000)).result}`);
  await Bun.sleep(45000);
  for (let i = 0; i < 5; i++) {
    const status = await probeOnce("/_status", 5000);
    const ping = await probeOnce("/ping", 8000);
    console.log(`  idle45s+${i} public=${ping.result} (${ping.end - ping.start}ms) status ${status.result}`);
    await Bun.sleep(1000);
  }
  await stopAll([a, b]);
}

// keepalive 無しで idle にして, 数分後の最初の要求が通るかと, 起こす時間を見る
async function idle(run: number, seconds: number, pingMs: string): Promise<void> {
  const agent = spawnAgent("A", base({ PING_MS: pingMs }));
  await waitFor200(15000);
  const t0 = Date.now();
  console.log(`SCENARIO idle run=${run} seconds=${seconds} ping_ms=${pingMs}`);
  for (let elapsed = 0; elapsed < seconds; elapsed += 30) {
    await Bun.sleep(30000);
    const ping = await probeOnce("/ping", 20000);
    const status = await probeOnce("/_status", 20000);
    console.log(`  +${((Date.now() - t0) / 1000).toFixed(0)}s public=${ping.result} (${ping.end - ping.start}ms) status=${status.result}`);
  }
  for (const e of agent.events) console.log(`  agent ${JSON.stringify(e)}`);
  await stopAll([agent]);
}

const [mode, runArg, extraArg, thirdArg] = process.argv.slice(2);
const run = Number(runArg ?? 1);
if (mode === "deploy") await deploy(run);
else if (mode === "ghost") await ghost(run);
else if (mode === "deploy-idle") await deployIdle(run);
else if (mode === "idle") await idle(run, Number(extraArg ?? 300), thirdArg ?? "0");
else if (mode === "terminate" || mode === "kill" || mode === "freeze" || mode === "takeover") {
  await scenario(mode, run, Number(extraArg ?? 60));
} else {
  throw new Error("usage: measure.ts terminate|kill|freeze|takeover|deploy|idle <run> [arg]");
}
