use super::VersionedStreamingChunkSink;
use crate::conversion_control::ConversionControl;
use std::sync::atomic::Ordering;

pub(super) fn dispatch_playback_chunk(
    control: Option<&ConversionControl>,
    sink: Option<&VersionedStreamingChunkSink>,
    chapter_index: usize,
    chunk_index: usize,
    bytes: &[u8],
    stale_window_cancelled: &std::sync::atomic::AtomicBool,
) -> bool {
    dispatch_playback_chunk_at_generation(
        control,
        sink,
        chapter_index,
        chunk_index,
        bytes,
        stale_window_cancelled,
        None,
    )
}

pub(super) fn dispatch_playback_chunk_at_generation(
    control: Option<&ConversionControl>,
    sink: Option<&VersionedStreamingChunkSink>,
    chapter_index: usize,
    chunk_index: usize,
    bytes: &[u8],
    stale_window_cancelled: &std::sync::atomic::AtomicBool,
    generation: Option<u64>,
) -> bool {
    let replaced = || control.is_some_and(|control| !control.generation_is_current(generation));
    if control.is_some_and(|control| !control.chapter_is_in_playback_window(chapter_index)) {
        stale_window_cancelled.store(true, Ordering::Release);
        return false;
    }
    if replaced() {
        stale_window_cancelled.store(true, Ordering::Release);
        return false;
    }
    let accepted = sink.is_none_or(|sink| sink(chapter_index, chunk_index, bytes, generation));
    if replaced() {
        stale_window_cancelled.store(true, Ordering::Release);
        return false;
    }
    accepted
}
