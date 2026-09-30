import {
  providerQuotaSchema,
  type BankedReset,
  type ProviderId,
  type ProviderQuota,
  type QuotaWindow,
  type SourceStatus,
} from "@herdr/contracts";
import { redactText } from "../services/redaction.js";

/** Parser revision stored on quota health. Screen text is not part of the result. */
export const QUOTA_PARSER_VERSION = "quota-1";

const SOURCE_TIMEZONE = "America/New_York";

const WEEKDAYS: Record<string, number> = {
  sun: 0,
  sunday: 0,
  mon: 1,
  monday: 1,
  tue: 2,
  tues: 2,
  tuesday: 2,
  wed: 3,
  wednesday: 3,
  thu: 4,
  thur: 4,
  thurs: 4,
  thursday: 4,
  fri: 5,
  friday: 5,
  sat: 6,
  saturday: 6,
};

const MONTHS: Record<string, number> = {
  jan: 1,
  january: 1,
  feb: 2,
  february: 2,
  mar: 3,
  march: 3,
  apr: 4,
  april: 4,
  may: 5,
  jun: 6,
  june: 6,
  jul: 7,
  july: 7,
  aug: 8,
  august: 8,
  sep: 9,
  sept: 9,
  september: 9,
  oct: 10,
  october: 10,
  nov: 11,
  november: 11,
  dec: 12,
  december: 12,
};

const WEEKDAY_ONLY =
  /^(?:sun|sunday|mon|monday|tue|tues|tuesday|wed|wednesday|thu|thur|thurs|thursday|fri|friday|sat|saturday)\s+\d{1,2}(?::\d{2})?(?::\d{2})?\s*(?:am|pm)?$/i;
const RELATIVE = /^(?:in\s+)?(\d+)\s*(h|hr|hrs|hour|hours|m|min|mins|minute|minutes|d|day|days)$/i;
const ISO_ZONED =
  /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,3}))?)?(Z|([+-])(\d{2}):?(\d{2}))$/;
const NAMED_ZONE = /^(.*\S)\s+(EST|EDT|UTC|GMT)$/i;
const WALL =
  /^(?:(sun|sunday|mon|monday|tue|tues|tuesday|wed|wednesday|thu|thur|thurs|thursday|fri|friday|sat|saturday)\s+)?([A-Za-z]{3,9})\s+(\d{1,2}),\s*(\d{4})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(AM|PM)?$/i;
const NUMERIC =
  /^(?:(sun|sunday|mon|monday|tue|tues|tuesday|wed|wednesday|thu|thur|thurs|thursday|fri|friday|sat|saturday)\s+)?(\d{1,2})\/(\d{1,2})\/(\d{4})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(AM|PM)?$/i;
const USED_PERCENT = /^(\d+(?:\.\d+)?)%\s+used$/i;
const LEFT_PERCENT = /^(\d+(?:\.\d+)?)%\s+left$/i;
const BARE_PERCENT = /^(\d+(?:\.\d+)?)%$/;

interface WallTime {
  year: number;
  month: number;
  day: number;
  hour: number;
  minute: number;
  second: number;
}

interface Section {
  kind: QuotaWindow["kind"];
  scope: string;
  used: number | null;
  left: number | null;
  notApplicable: boolean;
  bad: boolean;
  resetRaw: string | null;
  resetsAt: string | null;
}

export interface QuotaParseInput {
  provider: ProviderId;
  quotaLines: string[];
  inventoryLines: string[] | null;
  now: Date;
  sampledAt: string;
}

export interface QuotaParseResult {
  windows: QuotaWindow[];
  bankedResets: BankedReset[] | null;
  bankedStatus: ProviderQuota["bankedStatus"];
}

export interface QuotaHealthInput {
  cliVersion: string | null;
  provenance: "fixture" | "live";
  status?: SourceStatus;
  reasonCode?: string;
}

export function unknownWindows(sampledAt: string): QuotaWindow[] {
  return (["five_hour", "weekly"] as const).map((kind) => ({
    kind,
    scope: "all",
    availability: "unknown",
    usedPercent: null,
    remainingPercent: null,
    resetsAt: null,
    resetRaw: null,
    sourceTimezone: SOURCE_TIMEZONE,
    sampledAt,
    confidence: "unknown",
  }));
}

export function parseQuotaScreens(input: QuotaParseInput): QuotaParseResult {
  const quotaLines = inventoryUnsafe(input.quotaLines) ? [] : input.quotaLines.map((line) => redactText(line));
  const windows = orderWindows(finishWindows(input.provider, quotaLines, input.now, input.sampledAt));
  if (input.provider !== "codex") {
    return { windows, bankedResets: null, bankedStatus: "not_applicable" };
  }
  if (input.inventoryLines === null || inventoryUnsafe(input.inventoryLines)) {
    return { windows, bankedResets: null, bankedStatus: "unknown" };
  }
  const banked = parseBanked(input.inventoryLines, input.now, input.sampledAt);
  return { windows, bankedResets: banked.bankedResets, bankedStatus: banked.bankedStatus };
}

export function quotaFromScreens(input: QuotaParseInput & QuotaHealthInput): ProviderQuota {
  const parsed = parseQuotaScreens(input);
  const informative = parsed.windows.some(
    (window) => window.availability === "known" || window.availability === "not_applicable",
  );
  const status = input.status ?? (informative ? "ok" : "parse_error");
  const reasonCode = input.reasonCode ?? (status === "ok" ? "ok" : "unparsed_quota");
  return providerQuotaSchema.parse({
    provider: input.provider,
    windows: parsed.windows,
    bankedResets: parsed.bankedResets,
    bankedStatus: parsed.bankedStatus,
    health: {
      sourceId: `${input.provider}-quota`,
      status,
      checkedAt: input.sampledAt,
      lastSuccessAt: status === "ok" ? input.sampledAt : null,
      reasonCode,
      cliVersion: input.cliVersion,
      parserVersion: QUOTA_PARSER_VERSION,
      provenance: input.provenance,
    },
  });
}

/** Relative phrases anchor at `now`. A New York wall time is null in the DST gap and the November fold. */
export function parseClockPhrase(phrase: string, now: Date): string | null {
  const text = phrase.trim();
  if (!text) return null;
  if (WEEKDAY_ONLY.test(text)) return null;
  const relative = parseRelative(text, now);
  if (relative) return relative;
  const iso = ISO_ZONED.exec(text);
  if (iso) return fromIso(iso);
  const named = NAMED_ZONE.exec(text);
  if (named?.[1] && named[2]) {
    const wall = parseWall(named[1].trim());
    if (!wall) return null;
    return applyOffset(wall, zoneOffsetMinutes(named[2]));
  }
  const wall = parseWall(text);
  if (!wall) return null;
  const offset = nyOffsetMinutes(wall);
  if (offset === null) return null;
  return applyOffset(wall, offset);
}

function finishWindows(provider: ProviderId, lines: string[], now: Date, sampledAt: string): QuotaWindow[] {
  const sections = new Map<string, Section>();
  let current: Section | null = null;
  for (const raw of lines) {
    const line = redactText(raw).trim();
    if (!line) continue;
    const header = headerOf(line);
    if (header) {
      const key = `${header.kind}:${header.scope}`;
      const existing = sections.get(key);
      current = existing ?? {
        kind: header.kind,
        scope: header.scope,
        used: null,
        left: null,
        notApplicable: false,
        bad: false,
        resetRaw: null,
        resetsAt: null,
      };
      sections.set(key, current);
      continue;
    }
    if (!current) continue;
    if (/^(?:not applicable|n\/a)$/i.test(line)) {
      if (current.used !== null || current.left !== null) current.bad = true;
      current.notApplicable = true;
      continue;
    }
    const used = USED_PERCENT.exec(line);
    const left = LEFT_PERCENT.exec(line);
    if (used?.[1] || left?.[1]) {
      if (current.notApplicable) current.bad = true;
      const value = Number((used ?? left)?.[1]);
      if (!Number.isFinite(value) || value < 0 || value > 100) {
        current.bad = true;
        continue;
      }
      if (used) {
        if (current.used !== null) current.bad = true;
        current.used = value;
      } else {
        if (current.left !== null) current.bad = true;
        current.left = value;
      }
      continue;
    }
    if (BARE_PERCENT.test(line)) {
      current.bad = true;
      continue;
    }
    const phrase = resetPhrase(line);
    if (phrase) {
      current.resetRaw = phrase;
      current.resetsAt = parseClockPhrase(phrase, now);
    }
  }
  const windows: QuotaWindow[] = [];
  windows.push(materialize(sections.get("five_hour:all"), provider, "five_hour", "all", sampledAt));
  windows.push(materialize(sections.get("weekly:all"), provider, "weekly", "all", sampledAt));
  for (const [key, section] of sections) {
    if (key === "five_hour:all" || key === "weekly:all") continue;
    windows.push(materialize(section, provider, section.kind, section.scope, sampledAt));
  }
  return windows;
}

function materialize(
  section: Section | undefined,
  provider: ProviderId,
  kind: QuotaWindow["kind"],
  scope: string,
  sampledAt: string,
): QuotaWindow {
  if (!section) {
    const grokFive = provider === "grok" && kind === "five_hour" && scope === "all";
    return {
      kind,
      scope,
      availability: grokFive ? "not_applicable" : "unknown",
      usedPercent: null,
      remainingPercent: null,
      resetsAt: null,
      resetRaw: null,
      sourceTimezone: SOURCE_TIMEZONE,
      sampledAt,
      confidence: "unknown",
    };
  }
  const reset = {
    resetsAt: section.resetsAt,
    resetRaw: section.resetRaw,
    sourceTimezone: SOURCE_TIMEZONE,
    sampledAt,
    kind: section.kind,
    scope: section.scope,
  };
  if (section.notApplicable && !section.bad && section.used === null && section.left === null) {
    return { ...reset, availability: "not_applicable", usedPercent: null, remainingPercent: null, confidence: "unknown" };
  }
  const percents = section.bad || section.notApplicable ? null : resolvePercents(section.used, section.left);
  if (!percents) {
    return { ...reset, availability: "unknown", usedPercent: null, remainingPercent: null, confidence: "unknown" };
  }
  return {
    ...reset,
    availability: "known",
    usedPercent: percents.used,
    remainingPercent: percents.remaining,
    confidence: percents.confidence,
  };
}

function resolvePercents(
  used: number | null,
  left: number | null,
): { used: number; remaining: number; confidence: "exact" | "rounded" } | null {
  if (used === null && left === null) return null;
  let nextUsed = used;
  let nextLeft = left;
  if (nextUsed === null && nextLeft !== null) nextUsed = 100 - nextLeft;
  if (nextLeft === null && nextUsed !== null) nextLeft = 100 - nextUsed;
  if (nextUsed === null || nextLeft === null) return null;
  const decimal = !Number.isInteger(nextUsed) || !Number.isInteger(nextLeft);
  if (decimal) {
    nextUsed = Math.round(nextUsed * 10) / 10;
    nextLeft = Math.round(nextLeft * 10) / 10;
  }
  if (nextUsed < 0 || nextLeft < 0 || nextUsed > 100 || nextLeft > 100) return null;
  const tolerance = decimal ? 0.11 : 0.001;
  if (Math.abs(nextUsed + nextLeft - 100) > tolerance) return null;
  return { used: nextUsed, remaining: nextLeft, confidence: decimal ? "rounded" : "exact" };
}

function headerOf(line: string): { kind: QuotaWindow["kind"]; scope: string } | null {
  const text = line.trim().toLowerCase();
  if (text === "current session" || text === "session" || text === "5h limit" || text === "5-hour limit" || text === "5 hour limit") {
    return { kind: "five_hour", scope: "all" };
  }
  if (text === "weekly limit" || text === "weekly") return { kind: "weekly", scope: "all" };
  if (text === "sonnet weekly") return { kind: "weekly", scope: "sonnet" };
  if (text === "opus weekly") return { kind: "weekly", scope: "opus" };
  return null;
}

function resetPhrase(line: string): string | null {
  const match = /^resets\s+(.+)$/i.exec(line.trim());
  const body = match?.[1]?.trim().replace(/^at\s+/i, "").slice(0, 80);
  return body ? body : null;
}

function orderWindows(windows: QuotaWindow[]): QuotaWindow[] {
  const rank = (window: QuotaWindow): number => {
    if (window.kind === "five_hour" && window.scope === "all") return 0;
    if (window.kind === "weekly" && window.scope === "all") return 1;
    if (window.kind === "five_hour") return 2;
    return 3;
  };
  return [...windows].sort((left, right) => rank(left) - rank(right) || left.scope.localeCompare(right.scope) || left.kind.localeCompare(right.kind));
}

function inventoryUnsafe(lines: string[]): boolean {
  const text = lines.join("\n").toLowerCase();
  return text.includes("redeem reset") || /\bapply\b/.test(text) || /\bconfirm\b/.test(text);
}

function parseBanked(
  lines: string[],
  now: Date,
  sampledAt: string,
): { bankedResets: BankedReset[] | null; bankedStatus: "known" | "unknown" } {
  const cleaned = lines.map((line) => redactText(line).trim()).filter((line) => line.length > 0);
  const header = cleaned.findIndex((line) => /^earned resets$/i.test(line));
  if (header < 0) return { bankedResets: null, bankedStatus: "unknown" };
  const body = cleaned.slice(header + 1);
  const hasNone = body.some((line) => /^none$/i.test(line) || /^no earned resets$/i.test(line));
  const hasId = body.some((line) => /^id:/i.test(line));
  const onlyZero =
    body.length > 0 &&
    body.every((line) => /^quantity:\s*0$/i.test(line) || /^none$/i.test(line) || /^no earned resets$/i.test(line));
  if (hasNone && hasId) return { bankedResets: null, bankedStatus: "unknown" };
  if ((hasNone || onlyZero) && !hasId) return { bankedResets: [], bankedStatus: "known" };
  if (!hasId) return { bankedResets: null, bankedStatus: "unknown" };

  const blocks: string[][] = [];
  let current: string[] | null = null;
  for (const line of body) {
    if (/^id:/i.test(line)) {
      current = [line];
      blocks.push(current);
      continue;
    }
    if (current) current.push(line);
  }
  const resets: BankedReset[] = [];
  for (const block of blocks) {
    const parsed = parseBlock(block, now, sampledAt);
    if (parsed === "skip") continue;
    if (parsed === null) return { bankedResets: null, bankedStatus: "unknown" };
    resets.push(parsed);
  }
  return { bankedResets: resets, bankedStatus: "known" };
}

function parseBlock(block: string[], now: Date, sampledAt: string): BankedReset | "skip" | null {
  const idMatch = /^id:\s*([A-Za-z0-9._:-]{1,80})$/.exec(block[0] ?? "");
  const id = idMatch?.[1];
  if (!id) return null;
  let quantity: number | null = null;
  let expiresAt: string | null = null;
  let redeemableAt: string | null = null;
  let eligibility: BankedReset["eligibility"] | null = null;
  let eligibilityReason: string | null = null;
  for (const line of block.slice(1)) {
    const quantityMatch = /^quantity:\s*(\d+)$/i.exec(line);
    if (quantityMatch?.[1]) {
      quantity = Number(quantityMatch[1]);
      continue;
    }
    const expires = /^expires(?:\s+at)?\s+(.+)$/i.exec(line);
    if (expires?.[1]) {
      expiresAt = parseClockPhrase(expires[1].trim().replace(/^at\s+/i, ""), now);
      continue;
    }
    const redeemable = /^redeemable(?:\s+at)?\s+(.+)$/i.exec(line);
    if (redeemable?.[1]) {
      redeemableAt = parseClockPhrase(redeemable[1].trim().replace(/^at\s+/i, ""), now);
      continue;
    }
    const eligibilityMatch = /^eligibility:\s*(eligible|ineligible|unknown)$/i.exec(line);
    if (eligibilityMatch?.[1]) {
      eligibility = eligibilityMatch[1].toLowerCase() as BankedReset["eligibility"];
      continue;
    }
    const reason = /^reason:\s*(.+)$/i.exec(line);
    if (reason?.[1]) {
      eligibilityReason = reason[1].trim().slice(0, 160);
      continue;
    }
    return null;
  }
  if (quantity === null || !Number.isInteger(quantity) || quantity < 0 || eligibility === null) return null;
  if (quantity === 0) return "skip";
  if (expiresAt !== null && Date.parse(expiresAt) < now.getTime()) {
    eligibility = "ineligible";
    eligibilityReason = "expired";
  }
  return {
    id,
    quantity,
    earnedAt: null,
    expiresAt,
    redeemableAt,
    eligibility,
    eligibilityReason,
    sampledAt,
  };
}

function parseRelative(phrase: string, now: Date): string | null {
  const match = RELATIVE.exec(phrase);
  const amount = Number(match?.[1]);
  const unit = match?.[2]?.toLowerCase();
  if (!match || !unit || !Number.isInteger(amount) || amount < 0 || amount > 24 * 366) return null;
  const hour = 60 * 60 * 1000;
  const span = unit.startsWith("h") ? amount * hour : unit.startsWith("m") ? amount * 60 * 1000 : amount * 24 * hour;
  return new Date(now.getTime() + span).toISOString();
}

function fromIso(match: RegExpExecArray): string | null {
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const hour = Number(match[4]);
  const minute = Number(match[5]);
  const second = match[6] ? Number(match[6]) : 0;
  const millis = match[7] ? Number(match[7].padEnd(3, "0")) : 0;
  if (!validDate(year, month, day) || hour > 23 || minute > 59 || second > 59 || millis > 999) return null;
  const local = Date.UTC(year, month - 1, day, hour, minute, second, millis);
  if (match[8] === "Z") return new Date(local).toISOString();
  const sign = match[9] === "-" ? -1 : 1;
  const offsetMinutes = sign * (Number(match[10]) * 60 + Number(match[11]));
  return new Date(local - offsetMinutes * 60_000).toISOString();
}

function parseWall(phrase: string): WallTime | null {
  const named = WALL.exec(phrase);
  if (named) {
    const weekday = named[1]?.toLowerCase();
    const month = MONTHS[named[2]?.toLowerCase() ?? ""];
    const day = Number(named[3]);
    const year = Number(named[4]);
    const hour = hour24(Number(named[5]), named[8]);
    const minute = Number(named[6]);
    const second = named[7] ? Number(named[7]) : 0;
    if (!month || hour === null || minute > 59 || second > 59) return null;
    return checkedWall({ year, month, day, hour, minute, second }, weekday);
  }
  const numeric = NUMERIC.exec(phrase);
  if (!numeric?.[8]) return null;
  const weekday = numeric[1]?.toLowerCase();
  const month = Number(numeric[2]);
  const day = Number(numeric[3]);
  const year = Number(numeric[4]);
  const hour = hour24(Number(numeric[5]), numeric[8]);
  const minute = Number(numeric[6]);
  const second = numeric[7] ? Number(numeric[7]) : 0;
  if (hour === null || minute > 59 || second > 59) return null;
  return checkedWall({ year, month, day, hour, minute, second }, weekday);
}

function checkedWall(wall: WallTime, weekday: string | undefined): WallTime | null {
  if (!validDate(wall.year, wall.month, wall.day)) return null;
  if (weekday) {
    const expected = WEEKDAYS[weekday];
    const actual = new Date(Date.UTC(wall.year, wall.month - 1, wall.day)).getUTCDay();
    if (expected === undefined || expected !== actual) return null;
  }
  return wall;
}

function hour24(hour: number, ampm: string | undefined): number | null {
  if (!ampm) return null;
  if (hour < 1 || hour > 12) return null;
  if (ampm.toUpperCase() === "AM") return hour === 12 ? 0 : hour;
  if (ampm.toUpperCase() === "PM") return hour === 12 ? 12 : hour + 12;
  return null;
}

function validDate(year: number, month: number, day: number): boolean {
  if (!Number.isInteger(year) || year < 2000 || year > 2100 || month < 1 || month > 12 || day < 1) return false;
  const probe = new Date(Date.UTC(year, month - 1, day));
  return probe.getUTCFullYear() === year && probe.getUTCMonth() === month - 1 && probe.getUTCDate() === day;
}

function nthWeekday(year: number, monthIndex: number, weekday: number, n: number): number {
  const first = new Date(Date.UTC(year, monthIndex, 1)).getUTCDay();
  return 1 + ((weekday - first + 7) % 7) + (n - 1) * 7;
}

function nyOffsetMinutes(wall: WallTime): number | null {
  const startDay = nthWeekday(wall.year, 2, 0, 2);
  const endDay = nthWeekday(wall.year, 10, 0, 1);
  const minutes = wall.hour * 60 + wall.minute;
  if (wall.month === 3 && wall.day === startDay && minutes >= 120 && minutes < 180) return null;
  if (wall.month === 11 && wall.day === endDay && minutes >= 60 && minutes < 120) return null;
  return inEdt(wall, startDay, endDay, minutes) ? 4 * 60 : 5 * 60;
}

function inEdt(wall: WallTime, startDay: number, endDay: number, minutes: number): boolean {
  if (wall.month < 3 || wall.month > 11) return false;
  if (wall.month > 3 && wall.month < 11) return true;
  if (wall.month === 3) {
    if (wall.day > startDay) return true;
    if (wall.day < startDay) return false;
    return minutes >= 180;
  }
  if (wall.day < endDay) return true;
  if (wall.day > endDay) return false;
  return minutes < 60;
}

function zoneOffsetMinutes(name: string): number {
  const upper = name.toUpperCase();
  if (upper === "EDT") return 4 * 60;
  if (upper === "EST") return 5 * 60;
  return 0;
}

function applyOffset(wall: WallTime, offsetMinutes: number): string {
  const local = Date.UTC(wall.year, wall.month - 1, wall.day, wall.hour, wall.minute, wall.second);
  return new Date(local + offsetMinutes * 60_000).toISOString();
}
