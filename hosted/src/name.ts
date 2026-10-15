// Names one photo with Claude. Everything about the request except the image and the context is
// fixed here: the model, the system prompt (the app's ClaudePrompt, from prompt.json), max_tokens
// and thinking. The answer is checked and trimmed to the six naming fields before it's returned.

import Anthropic from "@anthropic-ai/sdk";
import prompt from "./prompt.json";
import textPrompt from "./prompt-text.json";

/**
 * The cheapest current Haiku with vision: $0.10 / $0.50 per million input / output tokens for
 * prompts up to 100K tokens (platform.claude.com/docs/en/about-claude/pricing, 2026-10-15).
 */
export const MODEL = "claude-haiku-5-5";
/** The answer is ~60 tokens of JSON; 256 is what the app sends Claude too. */
export const MAX_TOKENS = 256;

export const KINDS: readonly string[] = prompt.kinds;

export interface Answer {
  subject: string;
  kind: string;
  merchant: string;
  total: string;
  confidence: number;
  people_present: boolean;
}

export class NamingError extends Error {
  constructor(
    readonly reason: "refusal" | "truncated" | "bad_output",
    message: string,
  ) {
    super(message);
  }
}

/** The exact Messages API body. `structured` adds output_config's JSON schema (the retry). */
export function messageBody(image: string, context: string, structured: boolean): Anthropic.MessageCreateParamsNonStreaming {
  return {
    model: MODEL,
    max_tokens: MAX_TOKENS,
    // Haiku 5.5 thinks by default; a filename needs no reasoning, and thinking would eat max_tokens
    // and add latency. Disabled is accepted at the default effort.
    thinking: { type: "disabled" },
    system: prompt.system + (structured ? "" : prompt.json_instructions),
    messages: [
      {
        role: "user",
        content: [
          { type: "image", source: { type: "base64", media_type: "image/jpeg", data: image } },
          { type: "text", text: context },
        ],
      },
    ],
    ...(structured ? { output_config: { format: { type: "json_schema" as const, schema: prompt.schema } } } : {}),
  };
}

/**
 * JSON in the prompt first (output_config added ~2.3 s per request in docs/perf.md); an answer that
 * doesn't parse is asked for once more with output_config, as ClaudeNamer does. `mayRetry` is asked
 * first: the second request is a second paid call, so it has to fit the global daily budget too.
 */
export async function nameImage(
  client: Anthropic, image: string, context: string, mayRetry: () => Promise<boolean> = async () => true,
): Promise<Answer> {
  const first = parseAnswer(await ask(client, messageBody(image, context, false)));
  if (first) return first;
  if (!(await mayRetry())) throw new NamingError("bad_output", "Claude's answer wasn't the expected JSON object.");
  const second = parseAnswer(await ask(client, messageBody(image, context, true)));
  if (second) return second;
  throw new NamingError("bad_output", "Claude's answer wasn't the expected JSON object.");
}

/** The whole text, or the first {…} in it, as a JSON object; null otherwise. */
function jsonObject(text: string): Record<string, unknown> | null {
  let json = text.trim();
  if (!json.startsWith("{")) {
    const a = json.indexOf("{"), b = json.lastIndexOf("}");
    if (a >= 0 && b > a) json = json.slice(a, b + 1);
  }
  try {
    const v: unknown = JSON.parse(json);
    return typeof v === "object" && v !== null && !Array.isArray(v) ? (v as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

/** The first `n` words, at most `max` characters. */
const words = (v: string, n: number, max: number) => v.trim().split(/\s+/).slice(0, n).join(" ").slice(0, max);

async function ask(client: Anthropic, body: Anthropic.MessageCreateParamsNonStreaming, what = "image"): Promise<string> {
  const msg = await client.messages.create(body);
  if (msg.stop_reason === "refusal") throw new NamingError("refusal", `Claude declined to describe this ${what}.`);
  if (msg.stop_reason === "max_tokens") throw new NamingError("truncated", "Claude's answer was cut off.");
  for (const block of msg.content) if (block.type === "text") return block.text;
  return "";
}

/**
 * ClaudePrompt.parse's rules (the whole text, or the first {…} in it, must be the object; known
 * kind; a real subject; a finite confidence), then each field is trimmed to what a filename can use:
 * the app keeps 6 words of the subject (12 leaves room for the "photo of" and city words it drops),
 * and reads merchant and total only for a receipt. Null if the answer can't be used.
 */
export function parseAnswer(text: string): Answer | null {
  const o = jsonObject(text);
  if (!o) return null;
  const { subject, kind, merchant, total, confidence, people_present } = o;
  if (typeof subject !== "string" || typeof kind !== "string" || !KINDS.includes(kind)) return null;
  if (typeof confidence !== "number" || !Number.isFinite(confidence)) return null;
  const subj = words(subject, 12, 120);
  if ((subj.match(/[\p{L}\p{N}]/gu) ?? []).length < 2) return null;
  const receipt = kind === "receipt";
  const m = receipt && typeof merchant === "string" ? words(merchant, 5, 60) : "";
  const t = receipt && typeof total === "string" ? total.trim() : "";
  return {
    subject: subj,
    kind,
    merchant: m,
    total: /^[0-9]{1,9}([.,][0-9]{1,2})?$/.test(t) ? t : "",
    confidence: Math.min(Math.max(confidence, 0), 1),
    people_present: people_present === true,
  };
}

// MARK: - PDFs (POST /v1/name-text)

export const TEXT_KINDS: readonly string[] = textPrompt.kinds;

/** What /v1/name-text returns: DocumentPrompt.Answer's six fields. */
export interface TextAnswer {
  subject: string;
  kind: string;
  issuer: string;
  amount: string;
  date: string;
  confidence: number;
}

/** The one user message, built exactly as the app's DocumentPrompt.message. */
export function textMessage(context: string, text: string): string {
  return `${context}\n\nText from the PDF (truncated):\n<<<\n${text}\n>>>`;
}

/** The exact Messages API body for a PDF's text: no image, the pinned PDF prompt. */
export function textMessageBody(context: string, text: string, structured: boolean): Anthropic.MessageCreateParamsNonStreaming {
  return {
    model: MODEL,
    max_tokens: MAX_TOKENS,
    thinking: { type: "disabled" },
    system: textPrompt.system + (structured ? "" : textPrompt.json_instructions),
    messages: [{ role: "user", content: [{ type: "text", text: textMessage(context, text) }] }],
    ...(structured ? { output_config: { format: { type: "json_schema" as const, schema: textPrompt.schema } } } : {}),
  };
}

/** `nameImage` for a PDF's text: JSON in the prompt first, then once with output_config if `mayRetry`. */
export async function nameText(
  client: Anthropic, context: string, text: string, mayRetry: () => Promise<boolean> = async () => true,
): Promise<TextAnswer> {
  const first = parseTextAnswer(await ask(client, textMessageBody(context, text, false), "document"));
  if (first) return first;
  if (!(await mayRetry())) throw new NamingError("bad_output", "Claude's answer wasn't the expected JSON object.");
  const second = parseTextAnswer(await ask(client, textMessageBody(context, text, true), "document"));
  if (second) return second;
  throw new NamingError("bad_output", "Claude's answer wasn't the expected JSON object.");
}

/**
 * DocumentPrompt.parse's rules (known PDF kind, a real subject, a finite confidence), then each field
 * trimmed to what a filename uses: 12 words of subject, 5 of issuer, an amount only for an invoice or
 * receipt and only as digits, a date only as YYYY-MM-DD. Null if the answer can't be used.
 */
export function parseTextAnswer(text: string): TextAnswer | null {
  const o = jsonObject(text);
  if (!o) return null;
  const { subject, kind, issuer, amount, date, confidence } = o;
  if (typeof subject !== "string" || typeof kind !== "string" || !TEXT_KINDS.includes(kind)) return null;
  if (typeof confidence !== "number" || !Number.isFinite(confidence)) return null;
  const subj = words(subject, 12, 120);
  if ((subj.match(/[\p{L}\p{N}]/gu) ?? []).length < 2) return null;
  const a = (kind === "invoice" || kind === "receipt") && typeof amount === "string" ? amount.trim() : "";
  const d = typeof date === "string" ? date.trim() : "";
  return {
    subject: subj,
    kind,
    issuer: typeof issuer === "string" ? words(issuer, 5, 60) : "",
    amount: /^[0-9]{1,9}([.,][0-9]{1,2})?$/.test(a) ? a : "",
    date: /^\d{4}-\d{2}-\d{2}$/.test(d) ? d : "",
    confidence: Math.min(Math.max(confidence, 0), 1),
  };
}
