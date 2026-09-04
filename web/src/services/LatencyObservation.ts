export type LatencyJourneyKind = "reader_open" | "progressive_playback" | "seek";

export type LatencyTransition =
  | "interaction_requested"
  | "reader_usable"
  | "audio_queued"
  | "audio_playable"
  | "audio_audible"
  | "seek_requested"
  | "seek_target_reached"
  | "cancelled";

export interface LatencyObservation {
  id: string;
  kind: LatencyJourneyKind;
  records: Array<{ transition: LatencyTransition; elapsedMs: number }>;
  terminal: boolean;
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

  begin(kind: LatencyJourneyKind, initial: LatencyTransition): string {
    const id = makeID();
    this.active.set(id, {
      startedAt: this.now(),
      observation: { id, kind, records: [{ transition: initial, elapsedMs: 0 }], terminal: false },
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
      return observation ? [{ ...observation, records: [...observation.records] }] : [];
    });
  }

  private isValidTransition(observation: LatencyObservation, transition: LatencyTransition): boolean {
    const recorded = new Set(observation.records.map((record) => record.transition));
    switch (observation.kind) {
      case "reader_open":
        return transition === "reader_usable";
      case "progressive_playback":
        switch (transition) {
          case "audio_queued":
            return !recorded.has("audio_queued") && !recorded.has("audio_playable") && !recorded.has("audio_audible");
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
