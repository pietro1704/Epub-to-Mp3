export const POLL_INTERVAL_MS = 1500;

export const PLAYBACK_RATES = [0.75, 1, 1.25, 1.5, 2] as const;

export const SPEED_KEY = 'epub-to-mp3:player-speed';

export const positionKey = (id: string) => `epub-to-mp3:player-pos:${id}`;
