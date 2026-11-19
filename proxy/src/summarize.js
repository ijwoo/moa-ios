import Anthropic from "@anthropic-ai/sdk";

/**
 * 쓸 수 있는 모델. 서버의 SUMMARY_MODEL 환경 변수로 고른다 (기본: Opus 5.5).
 * - fallback: 안전 필터 오탐 거절 시 서버 쪽 자동 재시도 지원 여부 (Haiku 5.5는 미지원)
 */
export const MODELS = {
  "claude-opus-5-5": { fallback: true },
  "claude-sonnet-5-5": { fallback: true },
  "claude-haiku-5-5": { fallback: false },
};

export const MODEL = resolveModel(process.env.SUMMARY_MODEL);

export function resolveModel(name) {
  if (!name) return "claude-opus-5-5";
  if (!(name in MODELS)) throw new Error(`지원하지 않는 SUMMARY_MODEL: ${name}`);
  return name;
}

/** 앱과 약속한 응답 형식. 담당자·기한은 본문에 없으면 null. */
export const SUMMARY_SCHEMA = {
  type: "object",
  properties: {
    topic: { type: "string" },
    summary: { type: "string" },
    decisions: { type: "array", items: { type: "string" } },
    action_items: {
      type: "array",
      items: {
        type: "object",
        properties: {
          task: { type: "string" },
          owner: { anyOf: [{ type: "string" }, { type: "null" }] },
          due: { anyOf: [{ type: "string" }, { type: "null" }] },
        },
        required: ["task", "owner", "due"],
        additionalProperties: false,
      },
    },
    open_questions: { type: "array", items: { type: "string" } },
  },
  required: ["topic", "summary", "decisions", "action_items", "open_questions"],
  additionalProperties: false,
};

const SYSTEM_PROMPT = `당신은 회의·면담 기록을 정리하는 비서입니다. 사용자가 녹음해 받아쓴 대화 원문을 읽고 요약합니다.

원문에 대해:
- 원문은 기기 음성 인식 결과라 잘못 받아쓴 단어가 섞여 있습니다. 앞뒤 맥락으로 뜻이 분명하면 바르게 고쳐 쓰고, 분명하지 않으면 추측해서 채우지 말고 미해결 질문(open_questions)에 "무엇이 불분명한지"를 적으세요.
- 화자 구분은 없습니다. 누가 말했는지 단정하지 마세요.
- [중요 표시]는 사용자가 녹음 중 "여기 중요"를 누른 시각입니다. 사람은 중요한 말을 들은 뒤에 누르므로, 그 시각 직전 내용을 특히 주의해서 요약·결정 사항·할 일에 빠짐없이 반영하세요.

작성 규칙:
- 원문에 근거가 있는 내용만 씁니다. 원문에 없는 사실, 담당자, 기한을 만들어 넣지 않습니다.
- 할 일의 담당자(owner)와 기한(due)은 원문에 명시된 경우에만 원문 표현 그대로 적고, 없으면 null로 둡니다.
- 결정 사항, 할 일, 미해결 질문이 없으면 빈 배열로 둡니다.
- 모든 내용은 한국어로 씁니다.
- topic은 한 줄, summary는 3~6문장으로 씁니다.`;

/** 앱이 보낸 발화·북마크를 프롬프트 본문으로 만든다. */
export function buildUserContent({ title, utterances, transcript, bookmarks }) {
  const lines = [];
  if (title) lines.push(`회의 제목: ${title}`, "");
  if (bookmarks?.length) {
    lines.push(`[중요 표시] ${bookmarks.map(formatTime).join(", ")}`, "");
  }
  lines.push("<원문>");
  if (utterances?.length) {
    for (const u of utterances) lines.push(`[${formatTime(u.start)}] ${u.text}`);
  } else {
    lines.push(transcript ?? "");
  }
  lines.push("</원문>");
  return lines.join("\n");
}

export function formatTime(seconds) {
  const total = Math.max(0, Math.floor(seconds));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const mm = String(m).padStart(2, "0");
  const ss = String(s).padStart(2, "0");
  return h > 0 ? `${h}:${mm}:${ss}` : `${mm}:${ss}`;
}

/** 요청 본문 검증. 잘못되면 메시지를 담은 Error를 던진다. */
export function validateInput(body) {
  if (!body || typeof body !== "object") throw new InputError("JSON 객체가 필요합니다.");
  const { utterances, transcript, bookmarks, title } = body;
  const hasUtterances = Array.isArray(utterances) && utterances.length > 0;
  const hasTranscript = typeof transcript === "string" && transcript.trim().length > 0;
  if (!hasUtterances && !hasTranscript) throw new InputError("utterances 또는 transcript가 필요합니다.");
  if (hasUtterances) {
    for (const u of utterances) {
      if (typeof u?.text !== "string" || typeof u?.start !== "number") {
        throw new InputError("utterances 항목은 {start: number, text: string} 형식이어야 합니다.");
      }
    }
  }
  if (bookmarks !== undefined && !(Array.isArray(bookmarks) && bookmarks.every((t) => typeof t === "number"))) {
    throw new InputError("bookmarks는 숫자 배열이어야 합니다.");
  }
  if (title !== undefined && typeof title !== "string") throw new InputError("title은 문자열이어야 합니다.");
  const input = { title, utterances: hasUtterances ? utterances : undefined, transcript, bookmarks };
  if (contentLength(input) < MIN_CONTENT_CHARS) {
    throw new InputError(`요약하기에는 내용이 너무 짧습니다. (${MIN_CONTENT_CHARS}자 미만)`);
  }
  return input;
}

export class InputError extends Error {}

/** 요약할 가치가 있는 최소 분량 (공백 제외 글자 수). 앱과 같은 기준. */
export const MIN_CONTENT_CHARS = 30;

export function contentLength({ utterances, transcript }) {
  const text = utterances?.length ? utterances.map((u) => u.text).join("") : (transcript ?? "");
  return text.replace(/\s/g, "").length;
}

/** Claude 응답이 약속한 형식인지 한 번 더 확인한다 (구조화 출력이 보장하지만 앱을 위해 방어). */
export function isValidSummary(value) {
  const isStringArray = (a) => Array.isArray(a) && a.every((x) => typeof x === "string");
  const isNullableString = (x) => x === null || typeof x === "string";
  return (
    value && typeof value === "object" &&
    typeof value.topic === "string" &&
    typeof value.summary === "string" &&
    isStringArray(value.decisions) &&
    isStringArray(value.open_questions) &&
    Array.isArray(value.action_items) &&
    value.action_items.every((i) => i && typeof i.task === "string" && isNullableString(i.owner) && isNullableString(i.due))
  );
}

/** 요약 실패를 앱이 구분할 수 있게 코드로 나눈다. */
export class SummaryError extends Error {
  constructor(code, status, message, { retryable = false } = {}) {
    super(message);
    this.code = code;
    this.status = status;
    this.retryable = retryable;
  }
}

export function createClient(options = {}) {
  return new Anthropic(options);
}

/**
 * Claude에 요약을 요청하고 검증된 JSON을 돌려준다.
 * @returns {{ summary: object, usage: object, model: string }}
 */
export async function summarize(client, input, model = MODEL) {
  let response;
  const fallback = MODELS[model].fallback
    ? { betas: ["server-side-fallback-2026-07-01"], fallbacks: "default" }
    : {};
  try {
    response = await client.beta.messages.create({
      model,
      max_tokens: 16000,
      // 요약 정확도(근거 없는 내용 금지)가 중요해 기본값(medium)보다 한 단계 올린다.
      output_config: {
        effort: "high",
        format: { type: "json_schema", schema: SUMMARY_SCHEMA },
      },
      // 안전 필터가 오탐으로 거절하면 서버 쪽에서 권장 모델로 다시 시도한다 (지원 모델만).
      ...fallback,
      system: SYSTEM_PROMPT,
      messages: [{ role: "user", content: buildUserContent(input) }],
    });
  } catch (error) {
    throw mapApiError(error);
  }

  if (response.stop_reason === "refusal") {
    throw new SummaryError("refusal", 422, "요약 요청이 거절되었습니다.", { retryable: false });
  }
  if (response.stop_reason === "max_tokens") {
    throw new SummaryError("too_long", 502, "응답이 너무 길어 잘렸습니다.", { retryable: false });
  }

  const text = response.content
    .filter((block) => block.type === "text")
    .map((block) => block.text)
    .join("");
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new SummaryError("invalid_output", 502, "요약 응답을 해석하지 못했습니다.", { retryable: true });
  }
  if (!isValidSummary(parsed)) {
    throw new SummaryError("invalid_output", 502, "요약 응답 형식이 올바르지 않습니다.", { retryable: true });
  }
  return { summary: parsed, usage: response.usage, model: response.model };
}

export function mapApiError(error) {
  if (error instanceof Anthropic.RateLimitError) {
    return new SummaryError("upstream_busy", 503, "요약 서버가 바쁩니다. 잠시 후 다시 시도하세요.", { retryable: true });
  }
  if (error instanceof Anthropic.AuthenticationError || error instanceof Anthropic.PermissionDeniedError) {
    return new SummaryError("upstream_auth", 502, "요약 서버 설정 오류입니다.", { retryable: false });
  }
  if (error instanceof Anthropic.BadRequestError) {
    return new SummaryError("upstream_rejected", 502, `요약 요청이 거부되었습니다: ${error.message}`, { retryable: false });
  }
  if (error instanceof Anthropic.APIConnectionError) {
    return new SummaryError("upstream_unreachable", 503, "요약 서버에 연결하지 못했습니다.", { retryable: true });
  }
  if (error instanceof Anthropic.APIError) {
    const retryable = (error.status ?? 500) >= 500;
    return new SummaryError("upstream_error", 502, `요약 서버 오류 (${error.status}).`, { retryable });
  }
  return new SummaryError("internal", 500, "알 수 없는 오류입니다.", { retryable: false });
}
