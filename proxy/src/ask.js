import { MODELS, InputError, SummaryError, formatTime, mapApiError } from "./summarize.js";

/** 질문하기 응답 형식. citations는 앱이 보낸 말풍선 번호(ref)만 담는다. */
export const ANSWER_SCHEMA = {
  type: "object",
  properties: {
    answer: { type: "string" },
    found: { type: "boolean" },
    citations: { type: "array", items: { type: "string" } },
  },
  required: ["answer", "found", "citations"],
  additionalProperties: false,
};

const SYSTEM_PROMPT = `당신은 사용자의 지난 회의·면담 기록을 찾아 질문에 답하는 비서입니다.

자료:
- <회의> 안에는 회의 제목, 일시, 요약, 그리고 받아쓴 말풍선이 있습니다. 각 말풍선 앞의 [m1-u3 · 01:05] 같은 표시가 말풍선 번호와 녹음 시각입니다.
- <다른 회의 목록>은 내용 없이 제목·일시·주제만 있는 회의입니다. 질문이 그 회의를 직접 가리키는데 답을 찾지 못한 경우에만 "그 회의는 내용을 보지 못했다"고 알려 주세요. 그 밖에는 언급하지 않습니다.
- 자료 맨 위에 "오늘 날짜"가 있으면, 질문의 "오늘", "어제", "이번 주" 같은 말은 그 날짜를 기준으로 읽고 회의의 일시와 견주어 어느 회의인지 판단합니다.
- 자료 맨 위에 "질문이 가리키는 날"이 있으면 앱이 날짜로 확인한 사실입니다. 그 날 녹음한 회의가 없다고 적혀 있으면, 답의 첫 문장에서 그 날 녹음한 회의가 없다는 것을 먼저 알립니다. 그다음 다른 날 회의에서 찾은 내용을 답할 때는 어느 날 회의인지 밝히고, 가리킨 날의 회의인 것처럼 말하지 않습니다.
- 받아쓴 원문에는 음성 인식 오류가 섞여 있습니다. 맥락상 분명하면 바르게 읽고, 분명하지 않으면 단정하지 마세요. 화자 구분은 없습니다.

답변 규칙:
- 자료에 근거가 있는 내용만 답합니다. 자료에 없으면 추측하지 말고 found를 false로 하고 "회의 기록에서 찾지 못했다"고 답합니다.
- 답의 근거가 된 말풍선 번호를 citations에 넣습니다 (가장 직접적인 것부터, 최대 5개). 자료에 없는 번호를 만들지 마세요.
- 어느 회의의 내용인지 회의 제목이나 "11월 10일 회의"처럼 날짜로 밝혀 주세요. 연도·초 단위 시각은 쓰지 않습니다.
- 한국어 존댓말(~습니다/~요)로, 핵심부터 간결하게 답합니다 (보통 2~5문장).
- 근거는 citations로만 전달합니다. 답변 본문에 말풍선 번호(m1-u3), "몇 번째 말풍선", 녹음 시각 같은 자료 표기를 쓰지 않습니다.
- 휴대폰 화면에서 읽기 쉽게 씁니다: 한두 문장마다 줄을 바꾸고, 여러 항목은 줄마다 "• "로 시작해 나열합니다. 빈 줄은 넣지 않고, 마크다운 기호(**, #, -)는 쓰지 않습니다.`;

/** 답변 말투. 말투만 바꾸고 위 규칙(근거·인용·형식)은 그대로다. 없으면 기본 문장(존댓말)만 쓴다. */
export const TONES = {
  friendly: "말투: 친근하고 부드러운 해요체(~요)로 답합니다. 가까운 동료에게 말하듯 편하게 쓰되 반말은 쓰지 않습니다. 말투 때문에 자료에 없는 내용을 덧붙이거나 내용을 줄이지 않습니다.",
  formal: "말투: 격식 있는 합니다체(~습니다)로 답합니다. 감탄이나 군말 없이 사실만 간결하게 씁니다.",
};

export function systemPrompt(tone) {
  return tone ? `${SYSTEM_PROMPT}\n- ${TONES[tone]}` : SYSTEM_PROMPT;
}

const MAX_QUESTION_CHARS = 500;
/** 날짜 표기("11월 12일 (목)", "이번 주(11월 9일~11월 15일)") 길이 한도 */
const MAX_DAY_CHARS = 40;

/** 날짜 표기는 자료 맨 위 한 줄로 들어간다. 줄바꿈과 꺾쇠를 지운다 (빈 값은 null) */
function oneLine(text) {
  return (text ?? "").replace(/[\r\n<>]+/g, " ").trim() || null;
}

export function validateAskInput(body) {
  if (!body || typeof body !== "object") throw new InputError("JSON 객체가 필요합니다.");
  const { question, history = [], meetings, other_meetings: others = [], tone, today, day } = body;
  if (today !== undefined && today !== null && (typeof today !== "string" || today.length > MAX_DAY_CHARS)) throw new InputError("today 형식이 올바르지 않습니다.");
  if (day !== undefined && day !== null && (typeof day?.label !== "string" || !day.label.trim() || day.label.length > MAX_DAY_CHARS || typeof day.found !== "boolean")) {
    throw new InputError("day는 {label, found} 형식이어야 합니다.");
  }
  if (tone !== undefined && tone !== null && !Object.hasOwn(TONES, tone)) throw new InputError("tone은 friendly 또는 formal이어야 합니다.");
  if (typeof question !== "string" || !question.trim()) throw new InputError("question이 필요합니다.");
  if (question.length > MAX_QUESTION_CHARS) throw new InputError(`질문은 ${MAX_QUESTION_CHARS}자 이하로 해 주세요.`);
  if (!Array.isArray(meetings) || meetings.length === 0) throw new InputError("meetings가 필요합니다.");
  for (const m of meetings) {
    if (typeof m?.ref !== "string" || !Array.isArray(m.utterances)) {
      throw new InputError("meetings 항목은 {ref, utterances[]} 형식이어야 합니다.");
    }
    for (const u of m.utterances) {
      if (typeof u?.ref !== "string" || typeof u?.text !== "string" || typeof u?.start !== "number") {
        throw new InputError("utterances 항목은 {ref, start, text} 형식이어야 합니다.");
      }
    }
  }
  if (!Array.isArray(history) || !history.every((h) => (h?.role === "user" || h?.role === "assistant") && typeof h.text === "string")) {
    throw new InputError("history 형식이 올바르지 않습니다.");
  }
  if (!Array.isArray(others)) throw new InputError("other_meetings는 배열이어야 합니다.");
  return {
    question: question.trim(), history: history.slice(-6), meetings, others, tone: tone ?? null,
    today: oneLine(today), day: day ? { label: oneLine(day.label), found: day.found } : null,
  };
}

export function buildContext({ meetings, others, today, day }) {
  const lines = [];
  if (today) lines.push(`오늘 날짜: ${today}`);
  if (day) {
    lines.push(day.found
      ? `질문이 가리키는 날: ${day.label}. 그 날 녹음한 회의만 <회의>로 담았습니다.`
      : `질문이 가리키는 날: ${day.label}. 그 날 녹음한 회의는 없습니다. <회의>는 다른 날 회의입니다.`);
  }
  if (lines.length) lines.push("");
  for (const m of meetings) {
    lines.push(`<회의 번호="${m.ref}" 제목="${m.title ?? ""}" 일시="${m.date ?? ""}">`);
    if (m.summary) lines.push(`요약: ${m.summary}`);
    for (const u of m.utterances) lines.push(`[${u.ref} · ${formatTime(u.start)}] ${u.text}`);
    lines.push("</회의>", "");
  }
  if (others.length) {
    lines.push("<다른 회의 목록>");
    for (const o of others) lines.push(`- ${o.title ?? ""} (${o.date ?? ""})${o.topic ? `: ${o.topic}` : ""}`);
    lines.push("</다른 회의 목록>");
  }
  return lines.join("\n");
}

/** 대화 기록 + 자료 + 새 질문 → messages. 자료는 매 질문마다 새로 고른 것을 첫 메시지에 둔다. */
export function buildMessages(input) {
  const context = buildContext(input);
  // 대화는 user로 시작해야 한다. 잘린 기록이 assistant로 시작하면 그 답은 버린다.
  const history = input.history[0]?.role === "assistant" ? input.history.slice(1) : input.history;
  const turns = [
    ...history.map((h) => ({ role: h.role, content: h.role === "user" ? `질문: ${h.text}` : h.text })),
    { role: "user", content: `질문: ${input.question}` },
  ];
  // 자료는 첫 user 메시지 앞에 둔다
  turns[0] = { ...turns[0], content: `${context}\n\n${turns[0].content}` };
  return mergeSameRole(turns);
}

/** 같은 역할이 이어지면 하나로 합친다 (기록이 홀수로 잘렸을 때 대비) */
function mergeSameRole(messages) {
  const merged = [];
  for (const m of messages) {
    const last = merged.at(-1);
    if (last && last.role === m.role) last.content += `\n\n${m.content}`;
    else merged.push({ ...m });
  }
  return merged;
}

export async function ask(client, input, model) {
  const refs = new Set(input.meetings.flatMap((m) => m.utterances.map((u) => u.ref)));
  const fallback = MODELS[model].fallback
    ? { betas: ["server-side-fallback-2026-07-01"], fallbacks: "default" }
    : {};
  let response;
  try {
    response = await client.beta.messages.create({
      model,
      max_tokens: 8000,
      output_config: { format: { type: "json_schema", schema: ANSWER_SCHEMA } },
      ...fallback,
      system: systemPrompt(input.tone),
      messages: buildMessages(input),
    });
  } catch (error) {
    throw mapApiError(error);
  }
  if (response.stop_reason === "refusal") throw new SummaryError("refusal", 422, "질문 처리가 거절되었습니다.");
  const text = response.content.filter((b) => b.type === "text").map((b) => b.text).join("");
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new SummaryError("invalid_output", 502, "답변을 해석하지 못했습니다.", { retryable: true });
  }
  if (typeof parsed?.answer !== "string" || typeof parsed?.found !== "boolean" || !Array.isArray(parsed?.citations)) {
    throw new SummaryError("invalid_output", 502, "답변 형식이 올바르지 않습니다.", { retryable: true });
  }
  // 자료에 없는 번호는 버린다 (지어낸 인용 방지)
  const citations = [...new Set(parsed.citations.filter((c) => typeof c === "string" && refs.has(c)))].slice(0, 5);
  return { answer: { answer: parsed.answer, found: parsed.found, citations }, usage: response.usage, model: response.model };
}
