import { describe, expect, it } from "vitest";
import {
  LatencyObservationStore,
  serializeLatencyEvidence,
} from "./LatencyObservation";

describe("LatencyObservationStore", () => {
  it("keeps queued, playable, and audible boundaries separate without content", () => {
    let now = 10;
    const store = new LatencyObservationStore(() => now);
    const id = store.begin("progressive_playback", "play_requested");
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
          { transition: "play_requested", elapsedMs: 0 },
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

  it("rejects out-of-order browser readiness events", () => {
    let now = 10;
    const store = new LatencyObservationStore(() => now);
    const id = store.begin("progressive_playback", "play_requested");
    now = 20;
    expect(store.record(id, "audio_playable")).toBe(false);
    expect(store.record(id, "audio_audible")).toBe(false);
    expect(store.record(id, "audio_queued")).toBe(true);
    now = 30;
    expect(store.record(id, "audio_audible")).toBe(false);
    expect(store.record(id, "audio_playable")).toBe(true);
    expect(store.record(id, "audio_audible")).toBe(true);

    expect(store.snapshot()[0].records).toEqual([
      { transition: "play_requested", elapsedMs: 0 },
      { transition: "audio_queued", elapsedMs: 10 },
      { transition: "audio_playable", elapsedMs: 20 },
      { transition: "audio_audible", elapsedMs: 20 },
    ]);
  });

  it("exports browser-safe evidence with the shared vocabulary and no caller metadata", () => {
    let now = 100;
    const store = new LatencyObservationStore(() => now);
    const id = store.begin("reader_open", "open_requested", {
      cacheState: "warm",
      resourcePolicy: "foreground_priority",
    });
    now = 180;
    store.record(id, "readable_content");
    store.record(id, "controls_usable");
    store.finish(id);

    const evidence = JSON.parse(serializeLatencyEvidence(store.snapshot()));
    expect(evidence.schemaVersion).toBe(1);
    expect(evidence.observations[0]).toMatchObject({
      kind: "reader_open",
      cacheState: "warm",
      resourcePolicy: "foreground_priority",
    });
    expect(
      evidence.observations[0].records.map(
        (record: { transition: string }) => record.transition,
      ),
    ).toEqual(["open_requested", "readable_content", "controls_usable"]);
    expect(JSON.stringify(evidence)).not.toContain("book");
    expect(JSON.stringify(evidence)).not.toContain("title");
  });
});
