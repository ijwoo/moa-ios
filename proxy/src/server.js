import { createServer } from "node:http";
import { timingSafeEqual } from "node:crypto";
import { createClient, summarize, validateInput, InputError, SummaryError, MODEL } from "./summarize.js";
import { ask, validateAskInput } from "./ask.js";

const MAX_BODY_BYTES = 2 * 1024 * 1024; // 1시간 회의 텍스트는 수백 KB 수준

/**
 * 요청 횟수 제한.
 * - 기기(앱이 보내는 X-Device-ID, 없으면 IP)마다 10분에 10회
 * - 서버 전체 하루 DAILY_LIMIT회 (API 비용 보호)
 */
export class Limiter {
  constructor({ perClient = 10, windowMs = 10 * 60_000, daily = 300, now = () => Date.now() } = {}) {
    Object.assign(this, { perClient, windowMs, daily, now });
    this.hits = new Map();
    this.day = this.#dayKey();
    this.dailyCount = 0;
  }

  #dayKey() {
    return new Date(this.now()).toISOString().slice(0, 10);
  }

  /** 허용되면 null, 아니면 거절 사유 */
  check(clientKey) {
    const today = this.#dayKey();
    if (today !== this.day) {
      this.day = today;
      this.dailyCount = 0;
    }
    if (this.dailyCount >= this.daily) return "daily_limit";

    const now = this.now();
    const recent = (this.hits.get(clientKey) ?? []).filter((t) => now - t < this.windowMs);
    if (recent.length >= this.perClient) {
      this.hits.set(clientKey, recent);
      return "rate_limited";
    }
    recent.push(now);
    this.hits.set(clientKey, recent);
    this.dailyCount += 1;
    return null;
  }
}

function sendJSON(res, status, body) {
  const data = JSON.stringify(body);
  res.writeHead(status, { "content-type": "application/json; charset=utf-8", "content-length": Buffer.byteLength(data) });
  res.end(data);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        reject(new InputError("요청이 너무 큽니다."));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

function tokenMatches(header, expected) {
  if (!expected) return false;
  const given = (header ?? "").replace(/^Bearer\s+/i, "");
  const a = Buffer.from(given);
  const b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}

/** 회의 내용은 로그에 남기지 않는다. 길이·결과·토큰 수만 기록한다. */
function log(fields) {
  console.log(JSON.stringify({ time: new Date().toISOString(), ...fields }));
}

/**
 * 경로별 처리. 인증·횟수 제한·오류 응답은 공통.
 * - /v1/summarize: 회의 요약
 * - /v1/ask: 지난 회의에 대한 질문
 */
export function createApp({ client, appToken, limiter, askLimiter = new Limiter({ perClient: 30, daily: 500 }), model = MODEL }) {
  const routes = {
    "/v1/summarize": {
      limiter,
      validate: validateInput,
      run: async (input) => {
        const { summary, usage, model: used } = await summarize(client, input, model);
        return { body: { summary }, usage, used, meta: { utterances: input.utterances?.length ?? 0 } };
      },
    },
    "/v1/ask": {
      limiter: askLimiter,
      validate: validateAskInput,
      run: async (input) => {
        const { answer, usage, model: used } = await ask(client, input, model);
        return {
          body: { answer }, usage, used,
          meta: { meetings: input.meetings.length, history: input.history.length, citations: answer.citations.length },
        };
      },
    },
  };

  return createServer(async (req, res) => {
    const started = Date.now();
    const url = new URL(req.url, "http://localhost");

    if (req.method === "GET" && url.pathname === "/healthz") {
      return sendJSON(res, 200, { ok: true, model });
    }
    const route = req.method === "POST" ? routes[url.pathname] : undefined;
    if (!route) {
      return sendJSON(res, 404, { error: { code: "not_found", message: "없는 경로입니다." } });
    }
    if (!tokenMatches(req.headers.authorization, appToken)) {
      log({ path: url.pathname, status: 401 });
      return sendJSON(res, 401, { error: { code: "unauthorized", message: "인증되지 않은 요청입니다." } });
    }

    const clientKey = String(req.headers["x-device-id"] ?? req.headers["x-forwarded-for"] ?? req.socket.remoteAddress);
    const limited = route.limiter.check(clientKey);
    if (limited) {
      log({ path: url.pathname, status: 429, reason: limited });
      return sendJSON(res, 429, {
        error: { code: limited, message: "요청이 너무 많습니다. 잠시 후 다시 시도하세요.", retryable: true },
      });
    }

    let input;
    let raw;
    try {
      raw = await readBody(req);
      input = route.validate(JSON.parse(raw));
    } catch (error) {
      const message = error instanceof InputError ? error.message : "JSON 형식이 올바르지 않습니다.";
      log({ path: url.pathname, status: 400 });
      return sendJSON(res, 400, { error: { code: "bad_request", message } });
    }

    try {
      const { body, usage, used, meta } = await route.run(input);
      log({
        path: url.pathname, status: 200, ms: Date.now() - started, model: used, chars: raw.length, ...meta,
        input_tokens: usage?.input_tokens, output_tokens: usage?.output_tokens,
      });
      return sendJSON(res, 200, body);
    } catch (error) {
      const e = error instanceof SummaryError ? error : new SummaryError("internal", 500, "알 수 없는 오류입니다.");
      log({ path: url.pathname, status: e.status, code: e.code, ms: Date.now() - started });
      return sendJSON(res, e.status, { error: { code: e.code, message: e.message, retryable: e.retryable } });
    }
  });
}

// 직접 실행할 때만 서버를 띄운다 (테스트에서는 createApp만 쓴다).
if (import.meta.url === `file://${process.argv[1]}`) {
  const appToken = process.env.APP_TOKEN;
  if (!process.env.ANTHROPIC_API_KEY || !appToken) {
    console.error("ANTHROPIC_API_KEY와 APP_TOKEN이 필요합니다 (.env).");
    process.exit(1);
  }
  const port = Number(process.env.PORT ?? 3100);
  const host = process.env.HOST ?? "127.0.0.1";
  const app = createApp({
    client: createClient({ timeout: 180_000, maxRetries: 2 }),
    appToken,
    limiter: new Limiter({ daily: Number(process.env.DAILY_LIMIT ?? 300) }),
  });
  app.listen(port, host, () => console.log(`meeting-summary-proxy on http://${host}:${port}`));
}
