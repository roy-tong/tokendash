import { describe, it, expect } from 'vitest';
import { getMinuteKey, coarsenBucketKey } from '../../server/claudeJsonlParser.js';
import { getMinuteKey as codexMinuteKey, coarsenBucketKey as codexCoarsen } from '../../server/codexParser.js';
import { getMinuteKey as piMinuteKey, coarsenBucketKey as piCoarsen } from '../../server/piParser.js';

describe('claude getMinuteKey', () => {
  it('converts UTC timestamp to Asia/Shanghai minute key', () => {
    // 2026-04-15T08:03:17Z = 16:03:17 in UTC+8
    expect(getMinuteKey('2026-04-15T08:03:17.000Z', 'Asia/Shanghai')).toBe('2026-04-15T16:03');
  });

  it('keeps the exact minute without flooring', () => {
    expect(getMinuteKey('2026-04-15T08:07:59.000Z', 'Asia/Shanghai')).toBe('2026-04-15T16:07');
  });

  it('rolls over to next day after midnight Shanghai time', () => {
    // 2026-04-15T16:02:00Z = 2026-04-16 00:02+8
    expect(getMinuteKey('2026-04-15T16:02:00.000Z', 'Asia/Shanghai')).toBe('2026-04-16T00:02');
  });
});

describe('claude coarsenBucketKey', () => {
  it('hour granularity truncates to hour', () => {
    expect(coarsenBucketKey('2026-04-15T16:35', 'hour')).toBe('2026-04-15T16');
  });
  it('15m granularity floors to quarter hour', () => {
    expect(coarsenBucketKey('2026-04-15T16:35', '15m')).toBe('2026-04-15T16:30');
  });
  it('5m granularity floors to the 5-minute grid', () => {
    expect(coarsenBucketKey('2026-04-15T16:37', '5m')).toBe('2026-04-15T16:35');
  });
  it('1m granularity returns the key unchanged', () => {
    expect(coarsenBucketKey('2026-04-15T16:37', '1m')).toBe('2026-04-15T16:37');
  });
});

describe('codex minute keys (space-separated key family)', () => {
  it('produces exact minute key at Shanghai tz', () => {
    expect(codexMinuteKey('2026-04-15T08:07:59.000Z', 'Asia/Shanghai')).toBe('2026-04-15 16:07');
  });
  it('coarsens to hour with space separator', () => {
    expect(codexCoarsen('2026-04-15 16:35', 'hour')).toBe('2026-04-15 16');
  });
  it('coarsens to 15m', () => {
    expect(codexCoarsen('2026-04-15 16:35', '15m')).toBe('2026-04-15 16:30');
  });
});

describe('pi minute keys', () => {
  it('keeps the exact minute at Shanghai tz', () => {
    expect(piMinuteKey('2026-04-15T08:07:59.000Z', 'Asia/Shanghai')).toBe('2026-04-15 16:07');
  });
  it('coarsens to 15m', () => {
    expect(piCoarsen('2026-04-15 16:35', '15m')).toBe('2026-04-15 16:30');
  });
});
