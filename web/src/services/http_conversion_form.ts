import type { ConversionFormValues } from '../types/conversion';

export function buildFormData(values: ConversionFormValues): FormData {
  const formData = new FormData();
  const uploadId = values.uploadId?.trim();
  const hasUploadId = Boolean(uploadId);
  if (uploadId) {
    formData.append('upload_id', uploadId);
  }
  // Never re-send the file if an uploadId already exists
  if (values.file && !hasUploadId) {
    formData.append('file', values.file);
  }
  formData.append('engine', values.engine);
  if (values.voice) {
    formData.append('voice', values.voice);
  }
  if (values.model) {
    formData.append('model', values.model);
  }
  if (values.chapters) {
    formData.append('chapters', values.chapters);
  }
  if (values.sections) {
    formData.append('sections', values.sections);
  }
  if (values.fromChapterToEnd) {
    formData.append('fromChapterToEnd', values.fromChapterToEnd);
  }
  if (values.fromChapterToChapter) {
    formData.append('fromChapterToChapter', values.fromChapterToChapter);
  }
  if (values.priority) {
    formData.append('priority', values.priority);
  }
  if (values.footnoteMode) {
    formData.append('footnote_mode', values.footnoteMode);
  }
  if (values.language) {
    formData.append('language', values.language);
  }
  if (typeof values.formattingCues === 'boolean') {
    formData.append('formatting_cues', values.formattingCues ? 'on' : 'off');
  }
  if (typeof values.enableCharacterVoices === 'boolean') {
    formData.append('enable_character_voices', values.enableCharacterVoices ? 'on' : 'off');
  }
  if (values.narratorVoice) {
    formData.append('narrator_voice', values.narratorVoice);
  }
  if (values.characterVoice) {
    formData.append('character_voice', values.characterVoice);
  }
  if (typeof values.exportToIphone === 'boolean') {
    formData.append('export_to_iphone', values.exportToIphone ? 'on' : 'off');
  }
  if (values.noParallel) {
    formData.append('no_parallel', 'on');
  }
  if (values.multiEngineParallel) {
    formData.append('multi_engine_parallel', 'on');
  }
  if (typeof values.maxPerformance === 'boolean') {
    formData.append('max_performance', values.maxPerformance ? 'on' : 'off');
  }
  if (typeof values.parallelSlots === 'number' && Number.isFinite(values.parallelSlots)) {
    formData.append('parallel_slots', String(values.parallelSlots));
  }
  if (
    typeof values.chapterStallSeconds === 'number' &&
    Number.isFinite(values.chapterStallSeconds)
  ) {
    formData.append('chapter_stall_seconds', String(values.chapterStallSeconds));
  }
  if (values.edgeNetworkTier) {
    formData.append('edge_network_tier', values.edgeNetworkTier);
  }
  if (typeof values.edgeChunkChars === 'number' && Number.isFinite(values.edgeChunkChars)) {
    formData.append('edge_chunk_chars', String(values.edgeChunkChars));
  }
  if (
    typeof values.edgeMaxSegmentSeconds === 'number' &&
    Number.isFinite(values.edgeMaxSegmentSeconds)
  ) {
    formData.append('edge_max_segment_seconds', String(values.edgeMaxSegmentSeconds));
  }
  if (typeof values.edgeEnableParallel === 'boolean') {
    formData.append('edge_enable_parallel', values.edgeEnableParallel ? 'on' : 'off');
  }
  if (typeof values.edgeAutoTune === 'boolean') {
    formData.append('edge_auto_tune', values.edgeAutoTune ? 'on' : 'off');
  }
  if (typeof values.edgeStableMode === 'boolean') {
    formData.append('edge_stable_mode', values.edgeStableMode ? 'on' : 'off');
  }
  if (typeof values.piperMaxProcs === 'number' && Number.isFinite(values.piperMaxProcs)) {
    formData.append('piper_max_procs', String(values.piperMaxProcs));
  }
  if (typeof values.engineChainFallback === 'boolean') {
    formData.append('engine_chain_fallback', values.engineChainFallback ? 'on' : 'off');
  }
  if (values.bitrate) {
    formData.append('bitrate', values.bitrate);
  }
  if (typeof values.sampleRate === 'number' && Number.isFinite(values.sampleRate)) {
    formData.append('sample_rate', String(values.sampleRate));
  }
  if (typeof values.channels === 'number' && Number.isFinite(values.channels)) {
    formData.append('channels', String(values.channels));
  }
  if (typeof values.clearCache === 'boolean') {
    formData.append('clear_cache', values.clearCache ? 'on' : 'off');
  }
  if (typeof values.forceReprocess === 'boolean') {
    formData.append('force_reprocess', values.forceReprocess ? 'on' : 'off');
  }
  if (typeof values.filterChapters === 'boolean') {
    formData.append('filter_chapters', values.filterChapters ? 'on' : 'off');
  }
  if (typeof values.verbose === 'boolean') {
    formData.append('verbose', values.verbose ? 'on' : 'off');
  }
  if (typeof values.useLanguageDetection === 'boolean') {
    formData.append('use_language_detection', values.useLanguageDetection ? 'on' : 'off');
  }
  if (typeof values.prioritizePrimaryLanguage === 'boolean') {
    formData.append('prioritize_primary_language', values.prioritizePrimaryLanguage ? 'on' : 'off');
  }
  if (
    typeof values.healthCheckIntervalSeconds === 'number' &&
    Number.isFinite(values.healthCheckIntervalSeconds)
  ) {
    formData.append('health_check_interval_seconds', String(values.healthCheckIntervalSeconds));
  }
  if (
    typeof values.healthCheckSlowEdgeCps === 'number' &&
    Number.isFinite(values.healthCheckSlowEdgeCps)
  ) {
    formData.append('health_check_slow_edge_cps', String(values.healthCheckSlowEdgeCps));
  }
  if (typeof values.healthCheckSlowCps === 'number' && Number.isFinite(values.healthCheckSlowCps)) {
    formData.append('health_check_slow_cps', String(values.healthCheckSlowCps));
  }
  if (typeof values.healthCheckHighCpu === 'number' && Number.isFinite(values.healthCheckHighCpu)) {
    formData.append('health_check_high_cpu', String(values.healthCheckHighCpu));
  }
  if (typeof values.healthCheckHighMem === 'number' && Number.isFinite(values.healthCheckHighMem)) {
    formData.append('health_check_high_mem', String(values.healthCheckHighMem));
  }
  if (typeof values.healthCheckOkCpu === 'number' && Number.isFinite(values.healthCheckOkCpu)) {
    formData.append('health_check_ok_cpu', String(values.healthCheckOkCpu));
  }
  if (typeof values.healthCheckOkMem === 'number' && Number.isFinite(values.healthCheckOkMem)) {
    formData.append('health_check_ok_mem', String(values.healthCheckOkMem));
  }
  if (
    typeof values.healthCheckSlowStreak === 'number' &&
    Number.isFinite(values.healthCheckSlowStreak)
  ) {
    formData.append('health_check_slow_streak', String(values.healthCheckSlowStreak));
  }
  if (values.uiLanguage) {
    formData.append('ui_language', values.uiLanguage);
  }
  return formData;
}
