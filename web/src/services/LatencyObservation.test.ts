import { describe, expect, it } from "vitest";
import { LatencyObservationStore } from "./LatencyObservation";

describe("LatencyObservationStore", () => {
  it("keeps queued, playable, and audible boundaries separate without content", () => {
    let now = 10;
    const store = new LatencyObservationStore(() => now);
    const id = store.begin("progressive_playback", "interaction_requested");
    now = 30;
    store.record(id, "audio_queued");
    now = 40;
    store.record(id, "audio_playable");
    now = 55;
    store.record(id, "audio_audible");
    store.finish(id);

    expect(store.snapshot()).toEqual([
      expect.objectContaining({
        kind: "progressive_playback",
        records: [
          { transition: "interaction_requested", elapsedMs: 0 },
          { transition: "audio_queued", elapsedMs: 20 },
          { transition: "audio_playable", elapsedMs: 30 },
          { transition: "audio_audible", elapsedMs: 45 },
        ],
      }),
    ]);
  });
});
