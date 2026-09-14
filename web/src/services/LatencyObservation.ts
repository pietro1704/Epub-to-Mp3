export type LatencyJourneyKind = "reader_open" | "progressive_playback" | "seek";

/** Shared cross-client readiness vocabulary. */
export type LatencyTransition =
  | "open_requested"
  | "readable_content"
  | "controls_usable"
  | "first_pdf_page"
  | "play_requested"
  | "audio_queued"
  | "audio_playable"
  | "audio_audible"
  | "seek_requested"
  | "seek_target_reached"
  | "cancelled";

export type LatencyCacheState = "cold" | "warm" | "unknown";
export type LatencyResourcePolicy =
  | "foreground_priority"
  | "conversion_active"
  | "unknown";

export interface LatencyObservation {
  id: string;
  kind: LatencyJourneyKind;
  cacheState: LatencyCacheState;
  resourcePolicy: LatencyResourcePolicy;
  records: Array<{ transition: LatencyTransition; elapsedMs: number }>;
  terminal: boolean;
}

export interface LatencyJourneyOptions {
  cacheState?: LatencyCacheState;
  resourcePolicy?: LatencyResourcePolicy;
}

const makeID = (): string =>
  globalThis.crypto?.randomUUID?.() ??
  `journey-${Math.random().toString(36).slice(2)}-${Date.now()}`;

/** Local-only, bounded timing diagnostics. No job ID, text, account, URL or
 * other listener data is retained here. */
export class LatencyObservationStore {
  private readonly now: () => number;
  private readonly capacity: number;
  private active = new Map<string, { startedAt: number; observation: LatencyObservation }>();
  private order: string[] = [];

  constructor(now: () => number = () => performance.now(), capacity = 200) {
    this.now = now;
    this.capacity = Math.max(1, capacity);
  }

  begin(
    kind: LatencyJourneyKind,
    initial: LatencyTransition,
    options: LatencyJourneyOptions = {},
  ): string {
    if (!this.isValidInitial(kind, initial)) return "";
    const id = makeID();
    this.active.set(id, {
      startedAt: this.now(),
      observation: {
        id,
        kind,
        cacheState: options.cacheState ?? "unknown",
        resourcePolicy: options.resourcePolicy ?? "unknown",
        records: [{ transition: initial, elapsedMs: 0 }],
        terminal: false,
      },
    });
    this.order.push(id);
    while (this.order.length > this.capacity) this.active.delete(this.order.shift()!);
    return id;
  }

  record(id: string, transition: LatencyTransition): boolean {
    const active = this.active.get(id);
    if (!active || active.observation.terminal || transition === "cancelled") return false;
    const lastRecord = active.observation.records[active.observation.records.length - 1];
    if (lastRecord?.transition === transition || !this.isValidTransition(active.observation, transition)) {
      return false;
    }
    active.observation.records.push({
      transition,
      elapsedMs: Math.max(0, this.now() - active.startedAt),
    });
    return true;
  }

  finish(id: string): void {
    const active = this.active.get(id);
    if (active) active.observation.terminal = true;
  }

  cancel(id: string): void {
    const active = this.active.get(id);
    if (!active || active.observation.terminal) return;
    active.observation.records.push({
      transition: "cancelled",
      elapsedMs: Math.max(0, this.now() - active.startedAt),
    });
    active.observation.terminal = true;
  }

  snapshot(): LatencyObservation[] {
    return this.order.flatMap((id) => {
      const observation = this.active.get(id)?.observation;
      return observation
        ? [{ ...observation, records: [...observation.records] }]
        : [];
    });
  }

  private isValidInitial(kind: LatencyJourneyKind, initial: LatencyTransition): boolean {
    return (
      (kind === "reader_open" && initial === "open_requested") ||
      (kind === "progressive_playback" && initial === "play_requested") ||
      (kind === "seek" && initial === "seek_requested")
    );
  }

  private isValidTransition(observation: LatencyObservation, transition: LatencyTransition): boolean {
    const recorded = new Set(observation.records.map((record) => record.transition));
    switch (observation.kind) {
      case "reader_open":
        return ["readable_content", "controls_usable", "first_pdf_page"].includes(transition)
          && !recorded.has(transition);
      case "progressive_playback":
        switch (transition) {
          case "audio_queued":
            return !recorded.has("audio_queued") && !recorded.has("audio_playable");
          case "audio_playable":
            return recorded.has("audio_queued") && !recorded.has("audio_audible");
          case "audio_audible":
            return recorded.has("audio_playable") && !recorded.has("audio_audible");
          default:
            return false;
        }
      case "seek":
        return transition === "seek_target_reached" && !recorded.has("seek_target_reached");
    }
  }
}

export const latencyObservations = new LatencyObservationStore();

/** Stable JSON export for a user-triggered, controlled-browser evidence run. */
export function serializeLatencyEvidence(observations: LatencyObservation[]): string {
  return JSON.stringify(
    { schemaVersion: 1, observations },
    null,
    2,
  );
}

/** Download without relying on File System Access API or Node-only globals. */
export function downloadLatencyEvidence(
  observations: LatencyObservation[] = latencyObservations.snapshot(),
  filename = "latency-evidence.json",
): void {
  const blob = new Blob([serializeLatencyEvidence(observations)], {
    type: "application/json",
  });
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = filename;
  anchor.click();
  URL.revokeObjectURL(url);
}
