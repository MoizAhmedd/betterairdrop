// What a client may send to POST /v1/name, and the checks that run before anything costs money.

import { jpegSize } from "./jpeg";

/** The app's upload: a 768 px JPEG (UploadImage.swift). 400 KB is about 4x what it sends. */
export const MAX_IMAGE_BYTES = 400 * 1024;
export const MAX_IMAGE_EDGE = 768;
/** ClaudePrompt.context is ~10 short lines with a 300-character OCR snippet: well under 2,000. */
export const MAX_CONTEXT_CHARS = 2000;
export const CONTEXT_PREFIX = "Context worked out on the user's Mac:";
/** Base64 of the largest image, plus the context JSON-escaped, plus slack. */
export const MAX_BODY_BYTES = Math.ceil(MAX_IMAGE_BYTES / 3) * 4 + MAX_CONTEXT_CHARS * 6 + 1024;

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

/** Polar keys are short ASCII tokens. Anything else is rejected without asking Polar. */
export function plausibleKey(key: string): boolean {
  return key.length >= 8 && key.length <= 128 && /^[A-Za-z0-9_-]+$/.test(key);
}

/** Reads at most `limit` bytes; throws 413 past that, whether or not Content-Length was sent. */
export async function readLimited(req: Request, limit = MAX_BODY_BYTES): Promise<string> {
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

function tooLarge(): RequestError {
  return new RequestError(413, "payload_too_large", `The image must be a JPEG of at most ${MAX_IMAGE_BYTES / 1024} KB.`);
}

/**
 * Exactly `{"image": base64 JPEG, "context": text}`. Any other field (a system prompt, a model,
 * max_tokens…) is refused: the Worker builds the Anthropic request itself.
 */
export function parseNameRequest(body: string): NameRequest {
  let obj: unknown;
  try {
    obj = JSON.parse(body);
  } catch {
    throw new RequestError(400, "invalid_request", "The body must be JSON.");
  }
  if (typeof obj !== "object" || obj === null || Array.isArray(obj)) {
    throw new RequestError(400, "invalid_request", "The body must be a JSON object.");
  }
  const extra = Object.keys(obj).filter((k) => k !== "image" && k !== "context");
  if (extra.length > 0) {
    throw new RequestError(400, "invalid_request", `Unknown field: ${extra[0]!.slice(0, 40)}. Only image and context are accepted.`);
  }
  const { image, context } = obj as Record<string, unknown>;
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
  if ((b64.length / 4) * 3 - padding > MAX_IMAGE_BYTES) throw tooLarge();
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
