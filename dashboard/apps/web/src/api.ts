import { dashboardSnapshotSchema, type DashboardSnapshot } from "@herdr/contracts";

/** "live" while the event stream is open, "reconnecting" while EventSource retries. */
export type Connection = "connecting" | "live" | "reconnecting";

export async function loadSnapshot(signal: AbortSignal): Promise<DashboardSnapshot> {
  const response = await fetch("/api/snapshot", {
    signal,
    headers: { accept: "application/json" },
  });
  if (!response.ok) throw new Error("snapshot unavailable");
  const body: unknown = await response.json();
  return dashboardSnapshotSchema.parse(body);
}

/**
 * The one-shot fetch can resolve after the event stream has already delivered a
 * newer snapshot. Keep whichever is newer. Stream frames are applied as they
 * arrive, so a server restart (sequence back to 1) still replaces the page.
 */
export function preferNewer(current: DashboardSnapshot | null, fetched: DashboardSnapshot): DashboardSnapshot {
  if (current && current.sequence >= fetched.sequence) return current;
  return fetched;
}

export function subscribeSnapshots(
  onSnapshot: (snapshot: DashboardSnapshot) => void,
  onConnection: (state: Connection) => void = () => undefined,
): () => void {
  const source = new EventSource("/api/events");
  const onEvent = (event: Event): void => {
    if (!(event instanceof MessageEvent) || typeof event.data !== "string") return;
    try {
      const parsed: unknown = JSON.parse(event.data);
      onSnapshot(dashboardSnapshotSchema.parse(parsed));
    } catch {
      // Ignore a malformed frame. The last valid snapshot stays on screen.
    }
  };
  source.addEventListener("snapshot", onEvent);
  source.onopen = () => onConnection("live");
  // EventSource retries on its own. Surface the gap so old data is not read as current.
  source.onerror = () => onConnection("reconnecting");
  return () => {
    source.removeEventListener("snapshot", onEvent);
    source.onopen = null;
    source.onerror = null;
    source.close();
  };
}

export function isAbortError(error: unknown): boolean {
  return typeof error === "object" && error !== null && "name" in error && error.name === "AbortError";
}
