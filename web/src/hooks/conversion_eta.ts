import { JobSnapshot, ChapterProgressEntry, ConversionSummary } from '../types/conversion';
import type { SystemStats } from './useSystemStats';

export type AdaptiveTolerances = {
  healthPingTimeoutMs: number;
  healthCheckFirstTimeoutMs: number;
  healthCheckTimeoutMs: number;
  healthFailureLimit: number;
  pollFailureLimit: number;
  activeSnapshotGraceMs: number;
};

export const DEFAULT_TOLERANCES: AdaptiveTolerances = {
  healthPingTimeoutMs: 8000,
  healthCheckFirstTimeoutMs: 8000,
  healthCheckTimeoutMs: 5000,
  healthFailureLimit: 3,
  pollFailureLimit: 3,
  activeSnapshotGraceMs: 60000,
};

export const clampNumber = (value: number, min: number, max: number): number => {
  return Math.min(max, Math.max(min, value));
};

export const resolveRecentSpeed = (summary?: ConversionSummary): number | null => {
  const entries = summary?.chapterProgress;
  if (!entries || entries.length === 0) {
    return null;
  }
  for (let idx = entries.length - 1; idx >= 0; idx -= 1) {
    const speed = entries[idx]?.charsPerSecond;
    if (typeof speed === 'number' && speed > 0) {
      return speed;
    }
  }
  return null;
};

export const resolveTelemetrySpeed = (
  stats: SystemStats | null,
  engine?: string,
): number | null => {
  const telemetry = stats?.telemetry;
  if (!telemetry) {
    return null;
  }
  const engineKey = (engine || '').toLowerCase();
  const engineEntry = engineKey ? telemetry[engineKey] : undefined;
  const engineSpeed = engineEntry?.avg_chars_per_second;
  if (typeof engineSpeed === 'number' && engineSpeed > 0) {
    return engineSpeed;
  }
  let best = 0;
  Object.values(telemetry).forEach((entry) => {
    const speed = entry?.avg_chars_per_second;
    if (typeof speed === 'number' && speed > best) {
      best = speed;
    }
  });
  return best > 0 ? best : null;
};

export const deriveAdaptiveTolerances = (
  stats: SystemStats | null,
  recentSpeed: number | null,
  engine?: string,
): AdaptiveTolerances => {
  if (!stats) {
    return DEFAULT_TOLERANCES;
  }
  const cpuPercent = Number(stats.cpu?.percent ?? 0);
  const memPercent = Number(stats.memory?.percent ?? 0);
  const logical = Number(stats.cpu?.logical ?? stats.cpu?.physical ?? 1);
  const totalMemBytes = Number(stats.memory?.total ?? 0);
  const totalMemGb = totalMemBytes > 0 ? totalMemBytes / 1024 ** 3 : 0;
  const gpuCount = stats.gpus?.length ?? 0;
  const inFlight = Number(stats.jobs?.inFlight ?? 0);
  const recSlots = Number(stats.recommendations?.parallelSlots ?? 0);

  const telemetrySpeed = resolveTelemetrySpeed(stats, engine);
  const speed = typeof recentSpeed === 'number' && recentSpeed > 0 ? recentSpeed : telemetrySpeed;

  let multiplier = 1.0;

  if (totalMemGb > 0 && totalMemGb < 6) {
    multiplier += 0.2;
  }
  if (totalMemGb > 0 && totalMemGb < 4) {
    multiplier += 0.2;
  }
  if (logical <= 4) {
    multiplier += 0.2;
  }
  if (logical <= 2) {
    multiplier += 0.2;
  }
  if (cpuPercent >= 85 || memPercent >= 85) {
    multiplier += 0.25;
  } else if (cpuPercent >= 70 || memPercent >= 70) {
    multiplier += 0.15;
  }
  if (inFlight > 1 || recSlots >= 6) {
    multiplier += 0.15;
  }
  if (typeof speed === 'number') {
    if (speed < 60) {
      multiplier += 0.35;
    } else if (speed < 100) {
      multiplier += 0.2;
    } else if (speed > 200) {
      multiplier -= 0.1;
    }
  }
  if (gpuCount > 0 && logical >= 8 && totalMemGb >= 12) {
    multiplier -= 0.05;
  }

  multiplier = clampNumber(multiplier, 0.85, 2.8);

  const scale = (base: number, min: number, max: number): number => {
    return clampNumber(Math.round(base * multiplier), min, max);
  };

  return {
    healthPingTimeoutMs: scale(DEFAULT_TOLERANCES.healthPingTimeoutMs, 6000, 20000),
    healthCheckFirstTimeoutMs: scale(DEFAULT_TOLERANCES.healthCheckFirstTimeoutMs, 6000, 20000),
    healthCheckTimeoutMs: scale(DEFAULT_TOLERANCES.healthCheckTimeoutMs, 4000, 15000),
    healthFailureLimit: clampNumber(
      Math.round(DEFAULT_TOLERANCES.healthFailureLimit * multiplier),
      2,
      6,
    ),
    pollFailureLimit: clampNumber(
      Math.round(DEFAULT_TOLERANCES.pollFailureLimit * multiplier),
      2,
      6,
    ),
    activeSnapshotGraceMs: scale(DEFAULT_TOLERANCES.activeSnapshotGraceMs, 45000, 180000),
  };
};

export function estimateEtaSeconds(
  snapshot: JobSnapshot,
  startedAt: number | null,
): number | undefined {
  const wordsBasedEta = estimateWordsBasedEtaSeconds(snapshot);
  if (typeof snapshot.etaSeconds === 'number') {
    if (typeof wordsBasedEta === 'number') {
      return Math.max(snapshot.etaSeconds, wordsBasedEta);
    }
    return snapshot.etaSeconds;
  }
  if (typeof wordsBasedEta === 'number') {
    return wordsBasedEta;
  }
  let progress = typeof snapshot.progress === 'number' ? snapshot.progress : null;
  if (
    (progress === null || progress === undefined) &&
    typeof snapshot.progressPercent === 'number'
  ) {
    progress = snapshot.progressPercent / 100;
  }
  if (!startedAt || progress === null || progress <= 0 || progress >= 1) {
    return undefined;
  }
  const elapsedSeconds = (Date.now() - startedAt) / 1000;
  if (elapsedSeconds <= 0) {
    return undefined;
  }
  return elapsedSeconds * ((1 - progress) / progress);
}

export function estimateWordsBasedEtaSeconds(snapshot: JobSnapshot): number | undefined {
  const entries = snapshot.chapterProgress;
  if (!Array.isArray(entries) || entries.length === 0) {
    return undefined;
  }

  const totals = entries.reduce(
    (acc, entry) => {
      if (
        typeof entry.wordCount === 'number' &&
        Number.isFinite(entry.wordCount) &&
        entry.wordCount > 0
      ) {
        acc.totalWords += entry.wordCount;
      }
      if (
        typeof entry.chars === 'number' &&
        Number.isFinite(entry.chars) &&
        entry.chars > 0 &&
        typeof entry.wordCount === 'number' &&
        Number.isFinite(entry.wordCount) &&
        entry.wordCount > 0
      ) {
        acc.totalChars += entry.chars;
        acc.weightedWords += entry.wordCount;
      }
      return acc;
    },
    { totalWords: 0, totalChars: 0, weightedWords: 0 },
  );

  if (totals.totalWords <= 0 || totals.totalChars <= 0 || totals.weightedWords <= 0) {
    return undefined;
  }

  const charsPerWord = totals.totalChars / totals.weightedWords;
  if (!Number.isFinite(charsPerWord) || charsPerWord <= 0) {
    return undefined;
  }

  const completedWords = entries.reduce((sum, entry) => {
    const wordCount =
      typeof entry.wordCount === 'number' && Number.isFinite(entry.wordCount) ? entry.wordCount : 0;
    if (wordCount <= 0) {
      return sum;
    }
    if (
      entry.status === 'completed' ||
      entry.status === 'skipped' ||
      entry.status === 'cancelled'
    ) {
      return sum + wordCount;
    }
    if (
      typeof entry.chars === 'number' &&
      entry.chars > 0 &&
      typeof entry.charsProcessed === 'number' &&
      entry.charsProcessed > 0
    ) {
      const ratio = Math.max(0, Math.min(1, entry.charsProcessed / entry.chars));
      return sum + wordCount * ratio;
    }
    if (typeof entry.progressRatio === 'number' && entry.progressRatio > 0) {
      return sum + wordCount * Math.max(0, Math.min(1, entry.progressRatio));
    }
    return sum;
  }, 0);

  const remainingWords = Math.max(0, totals.totalWords - completedWords);
  if (remainingWords <= 0) {
    return 0;
  }

  const currentCps = resolveCurrentCharsPerSecond(entries);
  if (currentCps === undefined || !Number.isFinite(currentCps) || currentCps <= 0) {
    return undefined;
  }

  const currentWpm = (currentCps / charsPerWord) * 60;
  if (!Number.isFinite(currentWpm) || currentWpm <= 0) {
    return undefined;
  }

  return Math.ceil((remainingWords / currentWpm) * 60);
}

export function resolveCurrentCharsPerSecond(entries: ChapterProgressEntry[]): number | undefined {
  const inFlight = entries
    .filter(
      (entry) =>
        (entry.status === 'processing' || entry.status === 'retrying') &&
        typeof entry.charsPerSecond === 'number' &&
        Number.isFinite(entry.charsPerSecond) &&
        entry.charsPerSecond > 0,
    )
    .map((entry) => entry.charsPerSecond as number);
  if (inFlight.length > 0) {
    return inFlight[inFlight.length - 1];
  }

  const completed = entries
    .filter(
      (entry) =>
        typeof entry.charsPerSecond === 'number' &&
        Number.isFinite(entry.charsPerSecond) &&
        entry.charsPerSecond > 0,
    )
    .map((entry) => entry.charsPerSecond as number);
  if (completed.length === 0) {
    return undefined;
  }
  return completed[completed.length - 1];
}
