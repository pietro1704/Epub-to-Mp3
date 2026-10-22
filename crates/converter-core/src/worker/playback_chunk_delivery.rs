use super::StreamingChunkSink;
use crate::conversion_control::ConversionControl;
use std::sync::atomic::Ordering;

pub(super) fn dispatch_playback_chunk(
    control: Option<&ConversionControl>,
    sink: Option<&StreamingChunkSink>,
    chapter_index: usize,
    chunk_index: usize,
    bytes: &[u8],
    stale_window_cancelled: &std::sync::atomic::AtomicBool,
) -> bool {
    if control.is_some_and(|control| !control.chapter_is_in_playback_window(chapter_index)) {
        stale_window_cancelled.store(true, Ordering::Release);
        return false;
    }
    sink.is_none_or(|sink| sink(chapter_index, chunk_index, bytes))
}
