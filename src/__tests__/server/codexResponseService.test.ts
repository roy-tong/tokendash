import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { tmpdir } from 'node:os';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { getCodexDailyResponse, resolveCodexWorkerPath } from '../../server/codexResponseService.js';
import { cache } from '../../server/cache.js';
import { clearUsageFileIndexMemory } from '../../server/usageFileIndex.js';

const tempDirs: string[] = [];
const originalCodexHome = process.env.CODEX_HOME;
const originalSettingsFile = process.env.TOKENDASH_SETTINGS_FILE;
const originalIndexDir = process.env.TOKENDASH_USAGE_INDEX_DIR;
const originalDisableWorker = process.env.TOKENDASH_DISABLE_CODEX_WORKER;

function tokenCount(timestamp: string, totalTokens: number): unknown {
  return {
    timestamp,
    type: 'event_msg',
    payload: {
      type: 'token_count',
      info: {
        total_token_usage: {
          input_tokens: totalTokens - 10,
          cached_input_tokens: 0,
          output_tokens: 10,
          reasoning_output_tokens: 0,
          total_tokens: totalTokens,
        },
      },
    },
  };
}

beforeEach(() => {
  const root = mkdtempSync(join(tmpdir(), 'tokendash-codex-worker-'));
  const settingsDir = mkdtempSync(join(tmpdir(), 'tokendash-codex-worker-settings-'));
  const indexDir = mkdtempSync(join(tmpdir(), 'tokendash-codex-worker-index-'));
  tempDirs.push(root, settingsDir, indexDir);
  process.env.CODEX_HOME = root;
  process.env.TOKENDASH_SETTINGS_FILE = join(settingsDir, 'settings.json');
  process.env.TOKENDASH_USAGE_INDEX_DIR = indexDir;
  delete process.env.TOKENDASH_DISABLE_CODEX_WORKER;

  const sessionDir = join(root, 'sessions', '2026', '09', '02');
  mkdirSync(sessionDir, { recursive: true });
  writeFileSync(join(sessionDir, 'rollout-worker.jsonl'), [
    {
      type: 'session_meta',
      payload: {
        id: 'worker-session',
        cwd: '/tmp/project-a',
        timestamp: '2026-09-02T00:00:00.000Z',
      },
    },
    { type: 'turn_context', payload: { model: 'gpt-5.5' } },
    tokenCount('2026-09-02T00:00:01.000Z', 100),
    tokenCount('2026-09-02T00:00:02.000Z', 175),
  ].map(line => JSON.stringify(line)).join('\n'));
});

afterEach(() => {
  cache.clear();
  clearUsageFileIndexMemory();
  if (originalCodexHome === undefined) delete process.env.CODEX_HOME;
  else process.env.CODEX_HOME = originalCodexHome;
  if (originalSettingsFile === undefined) delete process.env.TOKENDASH_SETTINGS_FILE;
  else process.env.TOKENDASH_SETTINGS_FILE = originalSettingsFile;
  if (originalIndexDir === undefined) delete process.env.TOKENDASH_USAGE_INDEX_DIR;
  else process.env.TOKENDASH_USAGE_INDEX_DIR = originalIndexDir;
  if (originalDisableWorker === undefined) delete process.env.TOKENDASH_DISABLE_CODEX_WORKER;
  else process.env.TOKENDASH_DISABLE_CODEX_WORKER = originalDisableWorker;
  while (tempDirs.length > 0) {
    const dir = tempDirs.pop();
    if (dir) rmSync(dir, { recursive: true, force: true });
  }
});

describe('codex response worker', () => {
  it('computes Codex usage through the non-blocking response service', async () => {
    const daily = await getCodexDailyResponse({ timezone: 'UTC' });

    expect(daily.daily).toHaveLength(1);
    expect(daily.daily[0]).toMatchObject({
      date: '2026-09-02',
      inputTokens: 165,
      outputTokens: 10,
      totalTokens: 175,
    });
  });

  it('resolves the sidecar worker next to the compiled bundled daemon', () => {
    const worker = resolveCodexWorkerPath('file:///tmp/tokendash/dist/daemon.cjs');

    expect(dirname(worker)).toBe('/tmp/tokendash/dist/server');
    expect(worker.endsWith('codexResponseWorker.js')).toBe(true);
  });
});
