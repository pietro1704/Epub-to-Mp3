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

  it("records cancellation and rejects later ready boundaries", () => {
    let now = 10;
    const store = new LatencyObservationStore(() => now);
    const id = store.begin("seek", "seek_requested");
    now = 18;
    store.cancel(id);

    expect(store.record(id, "seek_target_reached")).toBe(false);
    expect(store.snapshot()[0].records).toEqual([
      { transition: "seek_requested", elapsedMs: 0 },
      { transition: "cancelled", elapsedMs: 8 },
    ]);
  });
});
