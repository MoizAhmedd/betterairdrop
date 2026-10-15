// What a client may send to POST /v1/name (a photo) and POST /v1/name-text (a PDF's text), and the
// checks that run before anything costs money.

import { jpegSize } from "./jpeg";

/** The app's upload: a 768 px JPEG (UploadImage.swift). 400 KB is about 4x what it sends. */
export const MAX_IMAGE_BYTES = 400 * 1024;
export const MAX_IMAGE_EDGE = 768;
/** ClaudePrompt.context is ~10 short lines with a 300-character OCR snippet: well under 2,000. */
export const MAX_CONTEXT_CHARS = 2000;
export const CONTEXT_PREFIX = "Context worked out on the user's Mac:";
/** Base64 of the largest image, plus the context JSON-escaped, plus slack. */
export const MAX_BODY_BYTES = Math.ceil(MAX_IMAGE_BYTES / 3) * 4 + MAX_CONTEXT_CHARS * 6 + 1024;

/** A PDF's text, cut to 4,000 UTF-16 units by the app (PDFText.maxChars); 6,000 leaves slack. */
export const MAX_TEXT_CHARS = 6000;
/** DocumentPrompt.context: a header line, the page count, where the text came from, a title. */
export const MAX_TEXT_CONTEXT_CHARS = 1000;
export const TEXT_CONTEXT_PREFIX = "PDF worked out on the user's Mac:";
/** Both fields JSON-escaped at worst (\uXXXX is 6 bytes a character), plus slack. */
export const MAX_TEXT_BODY_BYTES = (MAX_TEXT_CHARS + MAX_TEXT_CONTEXT_CHARS) * 6 + 1024;

export interface NameTextRequest {
  /** DocumentPrompt.context: facts about the PDF, never its file name. */
  context: string;
  /** Text read from the PDF on the user's Mac. Never the file. */
  text: string;
}

export interface NameRequest {
  /** Base64 JPEG, passed to Anthropic as it came (no decode and re-encode). */
  image: string;
  context: string;
}

export class RequestError extends Error {
  constructor(
    readonly status: number,
    readonly type: string,
    message: string,
  ) {
    super(message);
  }
}

/** The license key from `Authorization: Bearer <key>`, or null. */
export function bearerKey(req: Request): string | null {
  const h = req.headers.get("authorization") ?? "";
  const m = /^Bearer\s+(\S+)\s*$/i.exec(h);
  return m?.[1] ?? null;
}

/** The free trial's install ID from `Authorization: Trial <id>`, or null. */
export function trialId(req: Request): string | null {
  const h = req.headers.get("authorization") ?? "";
  const m = /^Trial\s+(\S+)\s*$/i.exec(h);
  return m?.[1] ?? null;
}

/** The app makes a random UUID per install (TrialStore.swift). */
export function plausibleTrialId(id: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id);
}

/**
 * What the trial's per-network count is keyed on (before it's hashed with the salt and the day):
 * an IPv4 address as it is, an IPv6 address cut to its /64 (one home or phone gets a whole /64, so
 * the full address would be a new network per request).
 */
export function network(ip: string | null): string {
  if (!ip) return "unknown";
  const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/i.exec(ip);
  if (mapped) return mapped[1]!;
  if (!ip.includes(":")) return ip;
  const [head = "", tail = ""] = ip.split("::");
  const h = head ? head.split(":") : [];
  const t = tail ? tail.split(":") : [];
  const groups = ip.includes("::") ? [...h, ...Array<string>(Math.max(8 - h.length - t.length, 0)).fill("0"), ...t] : h;
  return groups.slice(0, 4).map((g) => (Number.parseInt(g, 16) || 0).toString(16)).join(":") + "::/64";
}

/** Polar keys are short ASCII tokens. Anything else is rejected without asking Polar. */
export function plausibleKey(key: string): boolean {
  return key.length >= 8 && key.length <= 128 && /^[A-Za-z0-9_-]+$/.test(key);
}

/** Reads at most `limit` bytes; throws 413 past that, whether or not Content-Length was sent. */
export async function readLimited(req: Request, limit = MAX_BODY_BYTES, tooLarge: () => RequestError = imageTooLarge): Promise<string> {
  const declared = Number(req.headers.get("content-length") ?? "NaN");
  if (Number.isFinite(declared) && declared > limit) throw tooLarge();
  if (!req.body) return "";
  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > limit) {
      await reader.cancel();
      throw tooLarge();
    }
    chunks.push(value);
  }
  const all = new Uint8Array(total);
  let at = 0;
  for (const c of chunks) {
    all.set(c, at);
    at += c.byteLength;
  }
  return new TextDecoder().decode(all);
}

export function imageTooLarge(): RequestError {
  return new RequestError(413, "payload_too_large", `The image must be a JPEG of at most ${MAX_IMAGE_BYTES / 1024} KB.`);
}

export function textTooLarge(): RequestError {
  return new RequestError(413, "payload_too_large", `The text must be at most ${MAX_TEXT_CHARS.toLocaleString("en-US")} characters.`);
}

/**
 * Exactly `{"context": DocumentPrompt.context, "text": the PDF's text}`. Any other field (an image,
 * a system prompt, a model…) is refused: the Worker builds the Anthropic request itself, and only
 * six short naming fields come back, so free text in `text` can't be turned into anything else.
 */
export function parseNameTextRequest(body: string): NameTextRequest {
  const obj = jsonObject(body);
  const extra = Object.keys(obj).filter((k) => k !== "context" && k !== "text");
  if (extra.length > 0) {
    throw new RequestError(400, "invalid_request", `Unknown field: ${extra[0]!.slice(0, 40)}. Only context and text are accepted.`);
  }
  const { context, text } = obj;
  if (typeof context !== "string" || typeof text !== "string") {
    throw new RequestError(400, "invalid_request", "context and text (the PDF's text) are required.");
  }
  if (text.length > MAX_TEXT_CHARS) throw textTooLarge();
  if (!/[\p{L}\p{N}]/u.test(text)) throw new RequestError(400, "invalid_request", "text must contain some text from the PDF.");
  if (context.length > MAX_TEXT_CONTEXT_CHARS) {
    throw new RequestError(400, "invalid_request", `context must be at most ${MAX_TEXT_CONTEXT_CHARS} characters.`);
  }
  const lines = context.split("\n");
  if (lines[0] !== TEXT_CONTEXT_PREFIX || lines.slice(1).some((l) => !l.startsWith("- "))) {
    throw new RequestError(400, "invalid_request", "context must be the app's PDF context.");
  }
  return { context, text };
}

function jsonObject(body: string): Record<string, unknown> {
  let obj: unknown;
  try {
    obj = JSON.parse(body);
  } catch {
    throw new RequestError(400, "invalid_request", "The body must be JSON.");
  }
  if (typeof obj !== "object" || obj === null || Array.isArray(obj)) {
    throw new RequestError(400, "invalid_request", "The body must be a JSON object.");
  }
  return obj as Record<string, unknown>;
}

/**
 * Exactly `{"image": base64 JPEG, "context": text}`. Any other field (a system prompt, a model,
 * max_tokens…) is refused: the Worker builds the Anthropic request itself.
 */
export function parseNameRequest(body: string): NameRequest {
  const obj = jsonObject(body);
  const extra = Object.keys(obj).filter((k) => k !== "image" && k !== "context");
  if (extra.length > 0) {
    throw new RequestError(400, "invalid_request", `Unknown field: ${extra[0]!.slice(0, 40)}. Only image and context are accepted.`);
  }
  const { image, context } = obj;
  if (typeof image !== "string" || typeof context !== "string") {
    throw new RequestError(400, "invalid_request", "image (base64 JPEG) and context (text) are required.");
  }
  checkImage(image);
  checkContext(context);
  return { image, context };
}

function checkImage(b64: string): void {
  if (b64.length === 0 || b64.length % 4 !== 0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(b64)) {
    throw new RequestError(400, "invalid_request", "image must be base64 without line breaks.");
  }
  const padding = b64.endsWith("==") ? 2 : b64.endsWith("=") ? 1 : 0;
  if ((b64.length / 4) * 3 - padding > MAX_IMAGE_BYTES) throw imageTooLarge();
  const size = jpegSize(b64);
  if (!size) throw new RequestError(400, "invalid_request", "image must be a baseline or progressive JPEG.");
  if (Math.max(size.width, size.height) > MAX_IMAGE_EDGE) {
    throw new RequestError(413, "payload_too_large", `The image's long edge must be at most ${MAX_IMAGE_EDGE} px.`);
  }
}

function checkContext(context: string): void {
  if (context.length > MAX_CONTEXT_CHARS) {
    throw new RequestError(400, "invalid_request", `context must be at most ${MAX_CONTEXT_CHARS} characters.`);
  }
  // The app's context is a header line and "- " lines (ClaudePrompt.context). Holding clients to
  // that shape keeps this endpoint a photo namer, not a general prompt box.
  const lines = context.split("\n");
  if (lines[0] !== CONTEXT_PREFIX || lines.slice(1).some((l) => !l.startsWith("- "))) {
    throw new RequestError(400, "invalid_request", "context must be the app's photo context.");
  }
}
