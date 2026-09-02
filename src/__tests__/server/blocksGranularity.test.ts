import { describe, it, expect } from 'vitest';
import { getFiveMinKey, coarsenBucketKey } from '../../server/claudeJsonlParser.js';
import { getFiveMinKey as codexFiveMinKey, coarsenBucketKey as codexCoarsen } from '../../server/codexParser.js';

describe('claude getFiveMinKey', () => {
  it('converts UTC timestamp to Asia/Shanghai 5-min key', () => {
    // 2026-04-15T08:03:17Z = 16:03:17 in UTC+8 → floor to 16:00
    expect(getFiveMinKey('2026-04-15T08:03:17.000Z', 'Asia/Shanghai')).toBe('2026-04-15T16:00');
  });

  it('floors minutes to 5-minute boundaries', () => {
    // 08:07:59Z = 16:07:59+8 → 16:05
    expect(getFiveMinKey('2026-04-15T08:07:59.000Z', 'Asia/Shanghai')).toBe('2026-04-15T16:05');
  });

  it('rolls over to next day after midnight Shanghai time', () => {
    // 2026-04-15T16:02:00Z = 2026-04-16 00:02+8 → 00:00
    expect(getFiveMinKey('2026-04-15T16:02:00.000Z', 'Asia/Shanghai')).toBe('2026-04-16T00:00');
  });
});

describe('claude coarsenBucketKey', () => {
  it('hour granularity truncates to hour', () => {
    expect(coarsenBucketKey('2026-04-15T16:35', 'hour')).toBe('2026-04-15T16');
  });
  it('15m granularity floors to quarter hour', () => {
    expect(coarsenBucketKey('2026-04-15T16:35', '15m')).toBe('2026-04-15T16:30');
  });
  it('5m granularity returns key unchanged', () => {
    expect(coarsenBucketKey('2026-04-15T16:35', '5m')).toBe('2026-04-15T16:35');
  });
});

describe('codex 5-min keys (space-separated key family)', () => {
  it('produces 5-min key floored at Shanghai tz', () => {
    expect(codexFiveMinKey('2026-04-15T08:07:59.000Z', 'Asia/Shanghai')).toBe('2026-04-15 16:05');
  });
  it('coarsens to hour with space separator', () => {
    expect(codexCoarsen('2026-04-15 16:35', 'hour')).toBe('2026-04-15 16');
  });
  it('coarsens to 15m', () => {
    expect(codexCoarsen('2026-04-15 16:35', '15m')).toBe('2026-04-15 16:30');
  });
});
