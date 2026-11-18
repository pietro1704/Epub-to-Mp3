# Strings the conversion controllers render from browser job state. They are
# resolved here in the request locale and handed to Stimulus as one JSON value,
# so no user-facing literal lives in JavaScript. Placeholders use the
# `{name}` form the controllers fill in.
module ConversionHelper
  LOG_KEYS = {
    job_started: "flow.jobStarted", job_event: "flow.jobEvent", job_queued: "flow.jobQueued",
    job_running: "flow.jobRunning", job_finished: "flow.jobFinished", job_failed: "flow.failure",
    job_cancelled: "flow.cancelled", job_interrupted: "flow.jobInterrupted", job_rejected: "flow.error",
    batch_cancelled: "flow.batchCancelled", job_resumed: "flow.resuming"
  }.freeze

  def conversion_strings
    {
      phases: t("status.phases"),
      chapterStatuses: t("status.chapterStatuses"),
      jobStates: t("recentJobs.stateLabels"),
      errorCategoryHints: t("status.errorCategoryHints"),
      etaCalculating: t("status.etaCalculating"), etaSoon: t("status.etaSoon"), etaDone: t("status.etaDone"),
      jobLabel: t("status.jobLabel", jobId: "{jobId}"), errorPrefix: t("status.errorPrefix"),
      toggleShow: t("status.toggleShow"), toggleHide: t("status.toggleHide"),
      cancelPending: t("status.cancelButtonPending"), defaultFailure: t("flow.defaultFailure"),
      cancelConfirm: t("flow.cancelConfirm"), skipConfirm: t("flow.skipConfirm"),
      batchPosition: t("flow.batchPosition"), bookFallbackTitle: t("status.bookFallbackTitle"),
      bookFallbackAuthor: t("status.bookFallbackAuthor"), chaptersProgress: t("status.chaptersProgress"),
      queueLabel: t("queue.displayQueueLabel"),
      savedBatchTitle: t("tabs.setup.savedBatchTitle"), savedBatchNeedsReupload: t("tabs.setup.savedBatchNeedsReupload"),
      resumableProgress: t("resumableJobs.progressLabel"), resumableEngine: t("resumableJobs.engineLabel"),
      resumableVoice: t("resumableJobs.voiceLabel"), resumableLanguage: t("resumableJobs.languageLabel"),
      log: LOG_KEYS.transform_values { |key| t(key) }
    }
  end

  def conversion_strings_json = conversion_strings.to_json
end
