import { dashboardSnapshotSchema, type DashboardSnapshot } from "@herdr/contracts";

export async function loadSnapshot(signal: AbortSignal): Promise<DashboardSnapshot> {
  const response = await fetch("/api/snapshot", {
    signal,
    headers: { accept: "application/json" },
  });
  if (!response.ok) throw new Error("snapshot unavailable");
  const body: unknown = await response.json();
  return dashboardSnapshotSchema.parse(body);
}

export function subscribeSnapshots(onSnapshot: (snapshot: DashboardSnapshot) => void): () => void {
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
  source.onerror = () => undefined;
  return () => {
    source.removeEventListener("snapshot", onEvent);
    source.close();
  };
}

export function isAbortError(error: unknown): boolean {
  return typeof error === "object" && error !== null && "name" in error && error.name === "AbortError";
}
