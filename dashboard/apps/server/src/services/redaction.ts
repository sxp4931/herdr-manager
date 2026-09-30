const SECRET_SENTINEL = "SYNTHETIC_SECRET_SENTINEL";

const FORBIDDEN_KEYS = new Set([
  "screen",
  "rawScreen",
  "raw",
  "stdout",
  "stderr",
  "argv",
  "env",
  "environ",
  "terminal",
  "capture",
  "credential",
  "credentials",
  "token",
  "apiKey",
  "api_key",
]);

function hasControlCharacter(value: string): boolean {
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code <= 31 || code === 127) {
      return true;
    }
  }
  return false;
}

/** Redact one piece of text. The result never contains the synthetic sentinel. */
export function redactText(input: string): string {
  let value = input.replaceAll(SECRET_SENTINEL, "[redacted-secret]");
  value = value.replace(/bearer\s+[A-Za-z0-9._~+/-]+=*/gi, "bearer [redacted]");
  value = value.replace(/([a-z][a-z0-9+.-]*:\/\/)[^/\s:@]+:[^@\s/]+@/gi, "$1[redacted]@");
  value = value.replace(/([?&](?:access_token|token|api_key|key|sig|password)=)[^&\s#]+/gi, "$1[redacted]");
  value = value.replace(/\b(?:sk-ant|sk-proj|github_pat|sk|rk|pk|ghp|xai)-[A-Za-z0-9]{8,}\b/g, "[redacted-secret]");
  value = value.replace(/\bAKIA[A-Z0-9]{8,}\b/g, "[redacted-secret]");
  value = value.replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, "[redacted-email]");
  if (hasControlCharacter(value)) {
    value = value
      .split("")
      .map((character) => {
        const code = character.charCodeAt(0);
        return code <= 31 || code === 127 ? " " : character;
      })
      .join("")
      .replace(/ {2,}/g, " ")
      .trim();
  }
  return value.replaceAll(SECRET_SENTINEL, "[redacted-secret]");
}

export function redactOutbound(value: unknown): unknown {
  return redactValue(value, false);
}

export function redactStored(value: unknown): unknown {
  return redactValue(value, true);
}

function redactValue(value: unknown, rejectRaw: boolean): unknown {
  if (typeof value === "string") {
    return redactText(value);
  }
  if (typeof value === "number" || typeof value === "boolean" || value === null) {
    return value;
  }
  if (Array.isArray(value)) {
    return value.map((entry) => redactValue(entry, rejectRaw));
  }
  if (typeof value === "object") {
    const source = value as Record<string, unknown>;
    const redacted: Record<string, unknown> = {};
    for (const [key, inner] of Object.entries(source)) {
      if (rejectRaw && FORBIDDEN_KEYS.has(key)) {
        throw new Error(`refusing to store raw field ${key}`);
      }
      redacted[key] = redactValue(inner, rejectRaw);
    }
    return redacted;
  }
  return null;
}

export function assertNoSentinel(text: string): void {
  if (text.includes(SECRET_SENTINEL)) {
    throw new Error("redaction failed");
  }
}
