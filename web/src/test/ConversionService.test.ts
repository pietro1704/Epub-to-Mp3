import { describe, expect, test } from 'vitest';
import { normalizeAssetUrl } from '../services/ConversionService';

describe('normalizeAssetUrl', () => {
  test('returns absolute URLs unchanged', () => {
    const url = 'https://cdn.example.com/audio/chapter.mp3';
    expect(normalizeAssetUrl('https://api.example.com', url)).toBe(url);
  });

  test('combines absolute base with relative asset', () => {
    const result = normalizeAssetUrl('https://api.example.com', '/api/outputs/job/file.mp3');
    expect(result).toBe('https://api.example.com/api/outputs/job/file.mp3');
  });

  test('uses window origin when base is relative', () => {
    const result = normalizeAssetUrl('/api', '/api/outputs/job/file.mp3');
    expect(result).toBe(`${window.location.origin}/api/outputs/job/file.mp3`);
  });

  test('falls back to origin when base is empty', () => {
    const result = normalizeAssetUrl('', 'outputs/job/file.mp3');
    expect(result).toBe(`${window.location.origin}/outputs/job/file.mp3`);
  });
});
