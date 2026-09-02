# Hourly 图表时间范围筛选（Today / 3H / 1H）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 菜单栏 popover 的 HOURLY 图表支持 Today（1h 桶）/ 3H（15min 桶）/ 1H（5min 桶）三档，Settings → General 设默认档，图表头部可快速切换（切换写回 Settings）。

**Architecture:** daemon 端 5 个 agent parser 的索引/parse 层固定产出 5min 细粒度桶（bump `parserVersion` 使旧磁盘索引自动重建），`/api/blocks` 新增可选 `granularity=hour|15m|5m` 参数由 API 层向上聚合（hour 响应零回归，缓存 key 仅在细粒度时追加后缀）。Swift 端新增 `HourlyRange` 设置（UserDefaults）、`TimeBucket` 泛化模型 + 纯函数聚合器，`HourlyChartView` 改为 Date 轴三档渲染。

**Tech Stack:** TypeScript (Express + Zod + Vitest) / Swift 5.10 (SwiftUI + Swift Charts + XCTest)

**Spec:** `docs/superpowers/specs/2026-09-01-hourly-chart-time-filter-design.md`（已批准）

---

## File Structure

**Part 1 — daemon（可独立合入，向后兼容）**

| 文件 | 动作 | 职责 |
|------|------|------|
| `src/server/claudeJsonlParser.ts` | 修改 | 新增导出 `getFiveMinKey` / `coarsenBucketKey` 纯函数；summary.blocks/projectBlocks 改 5min 桶；`getBlocksResponse` 加 granularity 聚合；bump `CLAUDE_INDEX_VERSION` |
| `src/server/codexParser.ts` | 修改 | 同上模式；`groupSessions` 的 groupBy 加 `'fivemin'`；细粒度绕过 bundle 缓存直接从 summaries 聚合；bump `CODEX_INDEX_VERSION` |
| `src/server/opencodeParser.ts` | 修改 | 5min 基座 + coarsen（无索引缓存） |
| `src/server/openclawParser.ts` | 修改 | 同 opencode |
| `src/server/piParser.ts` | 修改 | `groupSessions` 加 `'fivemin'`；bump `PI_INDEX_VERSION` |
| `src/server/routes/blocks.ts` | 修改 | 解析 `granularity` query（非法值回落 hour）、缓存 key 追加后缀、透传 parser |
| `src/__tests__/server/blocksGranularity.test.ts` | 新建 | 纯函数层测试：key 生成/coarsen/时区/跨天 |

**Part 2 — Swift 菜单栏 app**

| 文件 | 动作 | 职责 |
|------|------|------|
| `TokenDashSwift/Sources/TokenDash/Models/SettingsStore.swift` | 修改 | 新增 `HourlyRange` enum + 持久化 |
| `TokenDashSwift/Sources/TokenDash/Services/APIClient.swift` | 修改 | protocol + 实现加 `BlocksGranularity` 参数 |
| `TokenDashSwift/Sources/TokenDash/Models/UsageBucketAggregator.swift` | 新建 | 纯函数：blocks → `TimeBucket[]`（三档/跨天/降级检测） |
| `TokenDashSwift/Sources/TokenDash/Models/APIModels.swift` | 修改 | `HourBucket` → `TimeBucket` |
| `TokenDashSwift/Sources/TokenDash/Models/AppState.swift` | 修改 | `hourlyData` 类型改 `[TimeBucket]` |
| `TokenDashSwift/Sources/TokenDash/BadgeUpdater.swift` | 修改 | 按档位请求粒度、`refetchDetailForRangeChange()`、5min 节流 |
| `TokenDashSwift/Sources/TokenDash/Views/SettingsView.swift` | 修改 | General 卡片加 "Hourly Chart" 行 |
| `TokenDashSwift/Sources/TokenDash/Views/HourlyChartView.swift` | 修改 | modeTabs 三档 + Date 轴渲染 |
| `TokenDashSwift/Tests/TokenDashTests/*` | 修改/新建 | SettingsStore / Aggregator / BadgeUpdater 粒度测试 |

---

## Part 1 — daemon

### Task 1: claudeJsonlParser — 5min 基座 + coarsen 纯函数

**Files:**
- Modify: `src/server/claudeJsonlParser.ts`
- Test: `src/__tests__/server/blocksGranularity.test.ts`（新建）

- [ ] **Step 1: 写失败测试（纯函数层）**

新建 `src/__tests__/server/blocksGranularity.test.ts`：

```typescript
import { describe, it, expect } from 'vitest';
import { getFiveMinKey, coarsenBucketKey } from '../../server/claudeJsonlParser.js';

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
```

- [ ] **Step 2: 运行确认失败**

Run: `npx vitest run src/__tests__/server/blocksGranularity.test.ts`
Expected: FAIL — `getFiveMinKey` / `coarsenBucketKey` 未导出。

- [ ] **Step 3: 实现纯函数 + 接入 parser**

`src/server/claudeJsonlParser.ts`，在现有 `getHourKey`（~line 278）下方新增：

```typescript
export type BlockGranularity = 'hour' | '15m' | '5m';

const GRANULARITY_MINUTES: Record<BlockGranularity, number> = { hour: 60, '15m': 15, '5m': 5 };

/// Bucket key at a fixed 5-minute granularity — the parse/index layer always
/// produces this fine base so cached summaries stay granularity-agnostic.
export function getFiveMinKey(timestamp: string, tz: string): string {
  const offset = (TZ_OFFSETS[tz] ?? 8) * 3_600_000;
  const d = new Date(new Date(timestamp).getTime() + offset);
  const yyyy = d.getUTCFullYear();
  const mm = String(d.getUTCMonth() + 1).padStart(2, '0');
  const dd = String(d.getUTCDate()).padStart(2, '0');
  const hh = String(d.getUTCHours()).padStart(2, '0');
  const minute = String(Math.floor(d.getUTCMinutes() / 5) * 5).padStart(2, '0');
  return `${yyyy}-${mm}-${dd}T${hh}:${minute}`;
}

/// Coarsen a 5-min bucket key ('yyyy-MM-ddTHH:mm') up to the requested
/// granularity. 'hour' yields the legacy getHourKey format ('yyyy-MM-ddTHH').
export function coarsenBucketKey(key: string, granularity: BlockGranularity): string {
  if (granularity === '5m') return key;
  if (granularity === 'hour') return key.slice(0, 13);   // 'yyyy-MM-ddTHH'
  const minute = String(Math.floor(Number(key.slice(14, 16)) / 15) * 15).padStart(2, '0');
  return `${key.slice(0, 14)}${minute}`;
}
```

聚合点（~line 233）改为 5min 基座（`daily` 不动）：

```typescript
    const dayKey = getDateKey(timestamp, DEFAULT_TZ);
    const bucketKey = getFiveMinKey(timestamp, DEFAULT_TZ);

    addUsageToBucket(claudeBucketFor(summary.daily, dayKey), parsedUsage);
    addUsageToBucket(claudeBucketFor(summary.blocks, bucketKey), parsedUsage);

    if (!summary.projects[projectName]) summary.projects[projectName] = {};
    addUsageToBucket(claudeBucketFor(summary.projects[projectName], dayKey), parsedUsage);

    if (!summary.projectBlocks[projectName]) summary.projectBlocks[projectName] = {};
    addUsageToBucket(claudeBucketFor(summary.projectBlocks[projectName], bucketKey), parsedUsage);
```

bump 版本（~line 106）：`const CLAUDE_INDEX_VERSION = 'claude-aggregate-v2-5min';`

`getBlocksResponse`（~line 462）加 granularity 聚合：

```typescript
export function getBlocksResponse(
  project?: string | null,
  tz = DEFAULT_TZ,
  granularity: BlockGranularity = 'hour',
): { blocks: BlockEntry[] } {
  const fiveMinBuckets: Record<string, ClaudeAggregateBucket> = {};

  for (const summary of loadClaudeAggregates()) {
    const source = project ? summary.projectBlocks[extractProjectName(project)] || {} : summary.blocks;
    for (const [key, bucket] of Object.entries(source)) {
      mergeClaudeBucket(claudeBucketFor(fiveMinBuckets, coarsenBucketKey(key, granularity)), bucket);
    }
  }

  const granMinutes = GRANULARITY_MINUTES[granularity];
  const blocks: BlockEntry[] = Object.entries(fiveMinBuckets)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([key, bucket], idx) => ({
      id: `claude-${idx}`,
      startTime: granularity === 'hour' ? `${key}:00:00` : `${key}:00`,
      endTime: granularity === 'hour'
        ? `${key}:59:59`
        : `${key.slice(0, 14)}${String(Number(key.slice(14, 16)) + granMinutes - 1).padStart(2, '0')}:59`,
      actualEndTime: null,
      isActive: false,
      isGap: false,
      entries: bucket.totalTokens > 0 ? 1 : 0,
      tokenCounts: {
        inputTokens: bucket.inputTokens,
        outputTokens: bucket.outputTokens,
        cacheCreationInputTokens: bucket.cacheCreationTokens,
        cacheReadInputTokens: bucket.cacheReadTokens,
      },
      totalTokens: bucket.totalTokens,
      costUSD: Math.round(bucket.totalCost * 10000) / 10000,
      models: Object.keys(bucket.models),
    }));
  return { blocks };
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `npx vitest run src/__tests__/server/blocksGranularity.test.ts`
Expected: PASS（全部用例）。

- [ ] **Step 5: 回归现有 claude 测试**

Run: `npx vitest run src/__tests__/server/claudeJsonlParser.test.ts`
Expected: PASS（getHourKey 等 pure 函数未被破坏）。

- [ ] **Step 6: Commit**

```bash
git add src/server/claudeJsonlParser.ts src/__tests__/server/blocksGranularity.test.ts
git commit -m "Add 5-minute bucket base and granularity coarsening to the Claude parser"
```

### Task 2: codexParser — 5min 基座 + 绕过 bundle 的细粒度路径

**Files:**
- Modify: `src/server/codexParser.ts`
- Test: `src/__tests__/server/blocksGranularity.test.ts`（追加）

- [ ] **Step 1: 追加失败测试**

在 `blocksGranularity.test.ts` 追加（codex 的 key 族用空格分隔 `yyyy-MM-dd HH:mm`）：

```typescript
import { getFiveMinKey as codexFiveMinKey, coarsenBucketKey as codexCoarsen } from '../../server/codexParser.js';

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
```

- [ ] **Step 2: 运行确认失败**

Run: `npx vitest run src/__tests__/server/blocksGranularity.test.ts`
Expected: FAIL — codex 未导出这两个函数。

- [ ] **Step 3: 实现**

`src/server/codexParser.ts`：

1) 在 `getHourKey`（~line 497）旁新增（导出，与 claude 同逻辑但空格分隔）：

```typescript
export function getFiveMinKey(ts: string, tz: string): string {
  const offset = (TZ_OFFSETS[tz] ?? 8) * 3_600_000;
  const d = new Date(new Date(ts).getTime() + offset);
  const yyyy = d.getUTCFullYear();
  const mm = String(d.getUTCMonth() + 1).padStart(2, '0');
  const dd = String(d.getUTCDate()).padStart(2, '0');
  const hh = String(d.getUTCHours()).padStart(2, '0');
  const minute = String(Math.floor(d.getUTCMinutes() / 5) * 5).padStart(2, '0');
  return `${yyyy}-${mm}-${dd} ${hh}:${minute}`;
}

export function coarsenBucketKey(key: string, granularity: BlockGranularity): string {
  if (granularity === '5m') return key;
  if (granularity === 'hour') return key.slice(0, 13);   // 'yyyy-MM-dd HH'
  const minute = String(Math.floor(Number(key.slice(14, 16)) / 15) * 15).padStart(2, '0');
  return `${key.slice(0, 14)}${minute}`;
}
```

`BlockGranularity` / `GRANULARITY_MINUTES` 类型从 claude parser import（`import { type BlockGranularity } from './claudeJsonlParser.js'`），`GRANULARITY_MINUTES` 在本文件重声明一份（避免循环依赖）：

```typescript
const GRANULARITY_MINUTES: Record<BlockGranularity, number> = { hour: 60, '15m': 15, '5m': 5 };
```

2) summary 聚合点（~line 446）：`const hourKey = getHourKey(ev.timestamp, DEFAULT_TZ);` 改：

```typescript
    const bucketKey = getFiveMinKey(ev.timestamp, DEFAULT_TZ);
```

（下方 `bucketFor(summary.blocks, ...)` 与 `summary.projectBlocks` 两处同步换 `bucketKey`。）

3) `groupSessions` 的 switch（~line 649）加 case：

```typescript
        case 'fivemin': key = getFiveMinKey(ev.timestamp, tz); break;
```

`AggregateOptions.groupBy` 类型定义处（搜 `groupBy:` 的类型声明）追加 `'fivemin'`。

4) `buildBlocksResponseFromSummaries`（~line 743）加 granularity 参数并在合并时 coarsen：

```typescript
function buildBlocksResponseFromSummaries(
  summaries: CodexFileAggregate[],
  project?: string | null,
  granularity: BlockGranularity = 'hour',
): BlocksResponse {
  const blockBuckets: Record<string, CodexSerializedBucket> = {};

  for (const summary of summaries) {
    const source = project ? summary.projectBlocks[extractProjectName(project)] || {} : summary.blocks;
    for (const [key, bucket] of Object.entries(source)) {
      mergeSerializedBucket(bucketFor(blockBuckets, coarsenBucketKey(key, granularity)), bucket);
    }
  }
  // ……startTime/endTime 拼装按 granularity 分支（与 Task 1 Step 3 的 claude 版相同模式，分隔符换成 'T' 拼接时保持原样：现有代码 `${datePart}T${hour}:00:00`，细粒度改为 `${datePart}T${hh}:${mm}:00`）
```

完整映射段（替换现有 `.map(([hourKey, bucket], idx) => ...)`）：

```typescript
  const granMinutes = GRANULARITY_MINUTES[granularity];
  const blocks: BlockEntry[] = Object.entries(blockBuckets)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([key, bucket], idx) => {
      const cost = Object.values(bucket.models).reduce((sum, m) => sum + (m as { cost: number }).cost, 0);
      const [datePart, timePart] = key.split(' ');
      const hour = timePart.slice(0, 2);
      return {
        id: `codex-${granularity}-${idx}`,
        startTime: granularity === 'hour' ? `${datePart}T${hour}:00:00` : `${datePart}T${timePart}:00`,
        endTime: granularity === 'hour'
          ? `${datePart}T${hour}:59:59`
          : `${datePart}T${timePart.slice(0, 3)}${String(Number(timePart.slice(3, 5)) + granMinutes - 1).padStart(2, '0')}:59`,
        actualEndTime: null,
        isActive: false,
        isGap: false,
        entries: bucket.totalTokens > 0 ? 1 : 0,
        tokenCounts: {
          inputTokens: displayInputTokens(bucket.inputTokens, bucket.cachedInputTokens),
          outputTokens: bucket.outputTokens,
          cacheCreationInputTokens: 0,
          cacheReadInputTokens: bucket.cachedInputTokens,
        },
        totalTokens: bucket.totalTokens,
        costUSD: cost,
        models: Object.keys(bucket.models),
      };
    });
  return { blocks };
}
```

> 注意：`bucket.models` / cost 字段结构以文件内现有代码为准（实现时若现有 reduce 写法不同，保持现有 cost 计算逻辑只改 key 解析与 startTime/endTime 拼装）。

5) `buildBlocksResponse`（~line 880）同样加 `granularity` 参数：`groupSessions(sessions, { groupBy: 'fivemin', ...options })` + coarsen + 同样的 startTime/endTime 分支。

6) `getBlocksResponse`（~line 928）细粒度绕过 bundle：

```typescript
export function getBlocksResponse(options?: Partial<AggregateOptions> & { granularity?: BlockGranularity }): BlocksResponse {
  const granularity = options?.granularity ?? 'hour';
  if (granularity === 'hour' && usesDefaultBundleOptions(options)) {
    return getCodexResponses(options).blocks;
  }
  if (!options?.since && !options?.until && (!options?.timezone || options.timezone === DEFAULT_TZ)) {
    return buildBlocksResponseFromSummaries(loadIndexedAggregates().summaries, options?.project, granularity);
  }
  return buildBlocksResponse(loadIndexedSessions().sessions, { ...options, granularity });
}
```

7) bump：`const CODEX_INDEX_VERSION = 'codex-session-v6-5min';`

- [ ] **Step 4: 运行测试确认通过**

Run: `npx vitest run src/__tests__/server/blocksGranularity.test.ts src/__tests__/server/codexParser.test.ts`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add src/server/codexParser.ts src/__tests__/server/blocksGranularity.test.ts
git commit -m "Serve fine-grained codex blocks from the 5-minute summary base"
```

### Task 3: opencode / openclaw / pi parser

**Files:**
- Modify: `src/server/opencodeParser.ts`、`src/server/openclawParser.ts`、`src/server/piParser.ts`
- Test: `src/__tests__/server/blocksGranularity.test.ts`（追加）

- [ ] **Step 1: 追加失败测试（pi 的导出纯函数）**

pi 有索引缓存、走 5min 基座；opencode/openclaw 现解析、直接目标粒度分桶（无需基座函数导出，测试走 pi 代表空格族已覆盖，opencode/openclaw 逻辑与 pi 同构、由路由级冒烟覆盖）：

```typescript
import { getFiveMinKey as piFiveMinKey, coarsenBucketKey as piCoarsen } from '../../server/piParser.js';

describe('pi 5-min keys', () => {
  it('floors to 5-min at Shanghai tz', () => {
    expect(piFiveMinKey('2026-04-15T08:07:59.000Z', 'Asia/Shanghai')).toBe('2026-04-15 16:05');
  });
  it('coarsens to 15m', () => {
    expect(piCoarsen('2026-04-15 16:35', '15m')).toBe('2026-04-15 16:30');
  });
});
```

- [ ] **Step 2: 运行确认失败**

Run: `npx vitest run src/__tests__/server/blocksGranularity.test.ts`
Expected: FAIL — pi 未导出。

- [ ] **Step 3: 实现三个 parser**

**piParser.ts**：`getHourKey`（~line 224）旁加与 Task 2 相同的 `getFiveMinKey` / `coarsenBucketKey`（导出）；`groupSessions` 的 groupBy 加 `'fivemin'` case（类型同步）；`getBlocksResponse`（~line 384）改为：

```typescript
export function getBlocksResponse(options?: { project?: string | null; timezone?: string; granularity?: BlockGranularity }): BlocksResponse {
  const tz = options?.timezone || DEFAULT_TZ;
  const granularity = options?.granularity ?? 'hour';
  const sessions = loadSessions();
  const grouped = groupSessions(sessions, 'fivemin', tz, options?.project);
  // coarsen 分组（同 Task 2 模式），startTime/endTime 按 granularity 分支拼装
```

（映射段照 Task 2 Step 3-4 的模式重写，id 前缀 `pi-${granularity}-`。）bump `PI_INDEX_VERSION = 'pi-session-v2-5min'`。

**opencodeParser.ts**：`getBlocksResponse`（~line 336）签名加 `granularity?: BlockGranularity`；聚合 key 直接用目标粒度：

```typescript
export function getBlocksResponse(options?: OpenCodeAggregateOptions & { granularity?: BlockGranularity }): BlocksResponse {
  const events = parseAllOpenCodeEvents(options?.project);
  const tz = options?.timezone || 'Asia/Shanghai';
  const granularity = options?.granularity ?? 'hour';
  const granMinutes = granularity === 'hour' ? 60 : granularity === '15m' ? 15 : 5;

  const grouped = new Map<string, { acc: TokenAccumulator; models: Set<string> }>();

  for (const ev of events) {
    const key = granularity === 'hour'
      ? getHourKey(ev.timestampMs, tz)
      : getGranularityKey(ev.timestampMs, tz, granMinutes);
    // ……与现有循环相同
```

在本文件加（不导出，`getGranularityKey` 复用 `getHourKey` 的 tz 偏移逻辑）：

```typescript
function getGranularityKey(ms: number, tz: string, minutes: number): string {
  const offset = (TZ_OFFSETS[tz] ?? 8) * 3_600_000;
  const d = new Date(ms + offset);
  const yyyy = d.getUTCFullYear();
  const mm = String(d.getUTCMonth() + 1).padStart(2, '0');
  const dd = String(d.getUTCDate()).padStart(2, '0');
  const hh = String(d.getUTCHours()).padStart(2, '0');
  const minute = String(Math.floor(d.getUTCMinutes() / minutes) * minutes).padStart(2, '0');
  return `${yyyy}-${mm}-${dd} ${hh}:${minute}`;
}
```

映射段：`hour` 走现有 `${datePart}T${hour}:00:00`；细粒度 `startTime: \`${datePart}T${timePart}:00\``、`endTime: \`${datePart}T${timePart.slice(0, 3)}${...+granMinutes-1}:59\``（同 Task 2 模式），id 前缀 `opencode-${granularity}-`。

**openclawParser.ts**：与 opencode 完全同构（getBlocksResponse ~line 430，id 前缀 `openclaw-${granularity}-`）。

> `TZ_OFFSETS` 若 opencode/openclaw 文件内没有该表，直接用与 `getHourKey` 相同的偏移取得方式（照各文件 getHourKey 现有实现抄）。

- [ ] **Step 4: 运行测试确认通过**

Run: `npx vitest run src/__tests__/server/blocksGranularity.test.ts`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add src/server/opencodeParser.ts src/server/openclawParser.ts src/server/piParser.ts src/__tests__/server/blocksGranularity.test.ts
git commit -m "Support fine-grained blocks for opencode, openclaw, and pi"
```

### Task 4: blocks 路由 — granularity 参数 + 缓存 key

**Files:**
- Modify: `src/server/routes/blocks.ts`

- [ ] **Step 1: 实现路由改动（行为简单，走冒烟验证；现有路由无单测文件，不新增 HTTP 层测试）**

`src/server/routes/blocks.ts` 改为：

```typescript
import { type Request, type Response } from 'express';
import { cache } from '../cache.js';
import { validateBlocks } from '../../shared/schemas.js';
import { type BlockGranularity } from '../claudeJsonlParser.js';
import { getBlocksResponse as getCodexBlocksResponse } from '../codexParser.js';
import { getBlocksResponse as getOpenClawBlocksResponse } from '../openclawParser.js';
import { getBlocksResponse as getOpencodeBlocksResponse } from '../opencodeParser.js';
import { getBlocksResponse as getClaudeBlocksResponse } from '../claudeJsonlParser.js';
import { getBlocksResponse as getPiBlocksResponse } from '../piParser.js';

function parseGranularity(raw: unknown): BlockGranularity {
  return raw === '15m' || raw === '5m' ? raw : 'hour';   // 非法值回落 hour
}

export async function getBlocks(req: Request, res: Response): Promise<void> {
  const agent = req.query.agent as string || 'claude';
  const project = req.query.project as string || undefined;
  const force = req.query.refresh === '1' || req.query.refresh === 'true';
  const granularity = parseGranularity(req.query.granularity);

  try {
    const cacheKey = `blocks:${agent}:${project || 'all'}${granularity !== 'hour' ? `:${granularity}` : ''}`;
    if (!force) {
      const cached = cache.get(cacheKey);
      if (cached) {
        res.json(cached);
        return;
      }

      // Stale-while-revalidate
      const stale = cache.getStale(cacheKey);
      if (stale) {
        refreshBlocksCache(agent, project, cacheKey, granularity);
        res.json(stale);
        return;
      }
    }

    const data = fetchBlocksData(agent, project, granularity);
    cache.set(cacheKey, data);
    res.json(data);
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Unknown error';
    console.error('Error fetching blocks data:', error);
    res.status(502).json({
      error: 'Failed to fetch blocks data',
      hint: message,
    });
  }
}

function fetchBlocksData(agent: string, project: string | undefined, granularity: BlockGranularity) {
  if (agent === 'openclaw') {
    return validateBlocks(getOpenClawBlocksResponse({ project: project || null, granularity }));
  } else if (agent === 'opencode') {
    return validateBlocks(getOpencodeBlocksResponse({ project: project || null, granularity }));
  } else if (agent === 'codex') {
    return validateBlocks(getCodexBlocksResponse({ granularity }));
  } else if (agent === 'pi') {
    return validateBlocks(getPiBlocksResponse({ project: project || null, granularity }));
  } else {
    // Claude Code: parse JSONL directly (fast, no CLI)
    return validateBlocks(getClaudeBlocksResponse(project || null, undefined, granularity));
  }
}

function refreshBlocksCache(
  agent: string,
  project: string | undefined,
  cacheKey: string,
  granularity: BlockGranularity,
): void {
  Promise.resolve()
    .then(() => { const data = fetchBlocksData(agent, project, granularity); cache.set(cacheKey, data); })
    .catch(err => console.error('Background refresh failed (blocks):', err));
}
```

> `claudeJsonlParser.getClaudeBlocksResponse(project, tz, granularity)` 的 tz 参数保持缺省；codex 原调用未传 project（`getCodexBlocksResponse(options)`），保持现状只加 granularity。

- [ ] **Step 2: 类型检查 + 全量 npm 测试**

Run: `npm test`
Expected: 全部 PASS（含既有 schemas/electron/nativeAppPackaging 等回归）。

- [ ] **Step 3: 手动冒烟（daemon 实测三粒度）**

```bash
node dist/daemon.cjs --port 3457 &   # 或 npm run build 后的现有 daemon 产物；端口避开 3456
curl -s 'http://127.0.0.1:3457/api/blocks?agent=claude' | head -c 400
curl -s 'http://127.0.0.1:3457/api/blocks?agent=claude&granularity=15m' | python3 -c "import json,sys; d=json.load(sys.stdin); print([b['startTime'] for b in d['blocks'][-3:]])"
curl -s 'http://127.0.0.1:3457/api/blocks?agent=claude&granularity=5m' | python3 -c "import json,sys; d=json.load(sys.stdin); print([b['startTime'] for b in d['blocks'][-3:]])"
kill %1
```

Expected: 无参 startTime 分钟位为 `00`；`15m` 出现 `:00/:15/:30/:45`；`5m` 出现 5 的倍数分钟。

- [ ] **Step 4: Commit**

```bash
git add src/server/routes/blocks.ts
git commit -m "Accept a granularity parameter on the blocks API"
```

---

## Part 2 — Swift

### Task 5: SettingsStore.HourlyRange

**Files:**
- Modify: `TokenDashSwift/Sources/TokenDash/Models/SettingsStore.swift`
- Test: `TokenDashSwift/Tests/TokenDashTests/SettingsStoreHourlyRangeTests.swift`（新建）

- [ ] **Step 1: 写失败测试**

```swift
import XCTest
@testable import TokenDash

final class SettingsStoreHourlyRangeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "settings.hourlyRange")
    }

    func testDefaultRangeIsToday() {
        XCTAssertEqual(SettingsStore.shared.hourlyRange, .today, "升级用户默认保持 Today 视图")
    }

    func testRawValueRoundTrip() {
        XCTAssertEqual(SettingsStore.HourlyRange(rawValue: "threeHours"), .threeHours)
        XCTAssertEqual(SettingsStore.HourlyRange(rawValue: "oneHour"), .oneHour)
        XCTAssertNil(SettingsStore.HourlyRange(rawValue: "bogus"), "损坏的持久化值应返回 nil 走默认")
    }

    func testBucketMinutes() {
        XCTAssertEqual(SettingsStore.HourlyRange.today.bucketMinutes, 60)
        XCTAssertEqual(SettingsStore.HourlyRange.threeHours.bucketMinutes, 15)
        XCTAssertEqual(SettingsStore.HourlyRange.oneHour.bucketMinutes, 5)
    }

    func testLabels() {
        XCTAssertEqual(SettingsStore.HourlyRange.threeHours.label, "Last 3 Hours")
        XCTAssertEqual(SettingsStore.HourlyRange.oneHour.shortLabel, "1H")
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd TokenDashSwift && swift test --filter HourlyRange`
Expected: 编译 FAIL — `hourlyRange` 不存在。

- [ ] **Step 3: 实现（照 RefreshInterval 模式）**

`SettingsStore.swift` 在 `Appearance` enum 后加：

```swift
    /// Popover hourly chart time range.
    enum HourlyRange: String, CaseIterable, Identifiable {
        case today, threeHours, oneHour
        var id: String { rawValue }
        var label: String {
            switch self {
            case .today: return "Today"
            case .threeHours: return "Last 3 Hours"
            case .oneHour: return "Last Hour"
            }
        }
        /// Compact tab label for the chart header.
        var shortLabel: String {
            switch self {
            case .today: return "Today"
            case .threeHours: return "3H"
            case .oneHour: return "1H"
            }
        }
        var bucketMinutes: Int {
            switch self {
            case .today: return 60
            case .threeHours: return 15
            case .oneHour: return 5
            }
        }
    }
```

属性区（`appearance` 后）：

```swift
    var hourlyRange: HourlyRange {
        didSet { defaults.set(hourlyRange.rawValue, forKey: Keys.hourlyRange) }
    }
```

`Keys` 加 `static let hourlyRange = "settings.hourlyRange"`；`init()` 加：

```swift
        self.hourlyRange = HourlyRange(rawValue: d.string(forKey: Keys.hourlyRange) ?? "") ?? .today
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cd TokenDashSwift && swift test --filter HourlyRange`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add TokenDashSwift/Sources/TokenDash/Models/SettingsStore.swift TokenDashSwift/Tests/TokenDashTests/SettingsStoreHourlyRangeTests.swift
git commit -m "Add the hourly chart range setting"
```

### Task 6: APIClient granularity 参数

**Files:**
- Modify: `TokenDashSwift/Sources/TokenDash/Services/APIClient.swift`、`TokenDashSwift/Tests/TokenDashTests/BadgeUpdaterModeTests.swift`（3 个 mock 同步签名）

- [ ] **Step 1: protocol 与实现加参数**

`APIClientProtocol`：

```swift
enum BlocksGranularity: String {
    case hour, fifteenMin = "15m", fiveMin = "5m"
}

protocol APIClientProtocol {
    func getAgents() async throws -> AgentsResponse
    func getDaily(agent: String, refresh: Bool) async throws -> DailyResponse
    func getBlocks(agent: String, refresh: Bool, granularity: BlocksGranularity) async throws -> BlocksResponse
    func getProjects(agent: String, refresh: Bool) async throws -> ProjectsResponse
    func getQuota(refresh: Bool) async throws -> QuotaResponse
}
```

`actor APIClient` 实现改（协议方法无默认参数，实现处给默认值保持既有调用点不破）：

```swift
    func getBlocks(agent: String, refresh: Bool = false, granularity: BlocksGranularity = .hour) async throws -> BlocksResponse {
        try await fetch("/blocks?agent=\(agent)&granularity=\(granularity.rawValue)\(refreshQuery(refresh))")
    }
```

`BadgeUpdaterModeTests.swift` 里 `MockAPIClient` / `BlockingAPIClient` / `FailingQuotaAPIClient` 三个 mock 的 `getBlocks` 签名同步加 `granularity: BlocksGranularity`（实现可带 `= .hour` 默认值），`MockAPIClient` 加记录字段供 Task 8 断言：

```swift
    private(set) var lastBlocksGranularity: BlocksGranularity? = nil
    // getBlocks 实现里：
    func getBlocks(agent: String, refresh: Bool, granularity: BlocksGranularity = .hour) async throws -> BlocksResponse {
        blocks += 1
        lastBlocksGranularity = granularity
        return BlocksResponse(blocks: [])
    }
```

`Snapshot` 不动（granularity 单独读）。

- [ ] **Step 2: 编译确认**

Run: `cd TokenDashSwift && swift build`
Expected: BUILD SUCCEEDED（BadgeUpdater 现有调用点 `api.getBlocks(agent: agent, refresh: forceRefresh)` 命中默认参数）。

- [ ] **Step 3: Commit**

```bash
git add TokenDashSwift/Sources/TokenDash/Services/APIClient.swift TokenDashSwift/Tests/TokenDashTests/BadgeUpdaterModeTests.swift
git commit -m "Pass blocks granularity through the API client"
```

### Task 7: UsageBucketAggregator（TimeBucket 纯函数聚合，TDD）

**Files:**
- Create: `TokenDashSwift/Sources/TokenDash/Models/UsageBucketAggregator.swift`
- Modify: `TokenDashSwift/Sources/TokenDash/Models/APIModels.swift`（`HourBucket` → `TimeBucket`）、`Models/AppState.swift`（`hourlyData: [TimeBucket]`）
- Test: `TokenDashSwift/Tests/TokenDashTests/UsageBucketAggregatorTests.swift`（新建）

- [ ] **Step 1: 写失败测试**

```swift
import XCTest
@testable import TokenDash

final class UsageBucketAggregatorTests: XCTestCase {
    private var formatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.timeZone = TimeZone.current
        return f
    }

    private func blocks(_ starts: [String], tokens: Int = 100) -> BlocksResponse {
        BlocksResponse(blocks: starts.map {
            BlockEntry(startTime: $0, totalTokens: tokens)
        })
    }

    private var now: Date { formatter.date(from: "2026-09-01T14:07:00")! }

    func testTodayBucketsFull24HourSkeleton() {
        let resp = blocks(["2026-09-01T09:30:00", "2026-09-01T10:45:00", "2026-08-31T23:00:00"])
        let result = UsageBucketAggregator.aggregate([resp], range: .today, now: now)
        // 聚合器返回完整 24 桶骨架（elapsed 过滤由视图 displayBuckets 做）
        XCTAssertEqual(result.buckets.count, 24)
        XCTAssertEqual(result.buckets[9].tokens, 100)
        XCTAssertEqual(result.buckets[10].tokens, 100)
        XCTAssertEqual(result.buckets[14].tokens, 0, "未来小时为 0")
        XCTAssertTrue(result.granularityMatched, "today 恒为 true（无降级概念）")
    }

    func testThreeHoursProducesTwelveFifteenMinBuckets() {
        let resp = blocks(["2026-09-01T11:30:00", "2026-09-01T14:00:00", "2026-09-01T10:59:00"])
        let result = UsageBucketAggregator.aggregate([resp], range: .threeHours, now: now)
        // 窗口 = floor(14:07, 15m) - 3h + 15m = [11:15, 14:15)，12 桶
        XCTAssertEqual(result.buckets.count, 12)
        let byStart = Dictionary(uniqueKeysWithValues: result.buckets.map { ($0.start, $0.tokens) })
        let t1115 = formatter.date(from: "2026-09-01T11:15:00")!
        let t1400 = formatter.date(from: "2026-09-01T14:00:00")!
        XCTAssertEqual(byStart[t1115], 100, "11:30 落 11:15 桶")
        XCTAssertEqual(byStart[t1400], 100, "14:00 是当前进行中桶")
        XCTAssertNil(byStart[formatter.date(from: "2026-09-01T10:59:00")!], "窗口外丢弃（其桶 10:45 不在窗口）")
    }

    func testOneHourProducesTwelveFiveMinBuckets() {
        let resp = blocks(["2026-09-01T13:07:00", "2026-09-01T13:59:00"])
        let result = UsageBucketAggregator.aggregate([resp], range: .oneHour, now: now)
        XCTAssertEqual(result.buckets.count, 12)
        let starts = result.buckets.map { formatter.string(from: $0.start) }
        XCTAssertEqual(starts.first, "2026-09-01T13:05:00", "窗口起点 = floor(14:07,5m)-1h+5m = 13:05")
        XCTAssertEqual(starts.last, "2026-09-01T14:05:00")
    }

    func testMultipleAgentsSumIntoSameBuckets() {
        let a = blocks(["2026-09-01T13:07:00"], tokens: 100)
        let b = blocks(["2026-09-01T13:08:00"], tokens: 40)
        let result = UsageBucketAggregator.aggregate([a, b], range: .oneHour, now: now)
        let t1305 = formatter.date(from: "2026-09-01T13:05:00")!
        XCTAssertEqual(result.buckets.first { $0.start == t1305 }?.tokens, 140)
    }

    func testCrossDayWindowIncludesYesterdayBuckets() {
        // now = 凌晨 00:07，3h 窗口跨到昨天 21:15
        let lateNight = formatter.date(from: "2026-09-02T00:07:00")!
        let resp = blocks(["2026-09-01T22:30:00"])
        let result = UsageBucketAggregator.aggregate([resp], range: .threeHours, now: lateNight)
        XCTAssertEqual(result.buckets.first.map { formatter.string(from: $0.start) }, "2026-09-01T21:15:00")
        XCTAssertTrue(result.buckets.contains { $0.tokens == 100 })
    }

    func testGranularityMismatchDetectedForLegacyDaemon() {
        // 细粒度请求但返回全是整点（旧 daemon 忽略参数）→ matched=false
        let resp = blocks(["2026-09-01T13:00:00", "2026-09-01T14:00:00"])
        let result = UsageBucketAggregator.aggregate([resp], range: .oneHour, now: now)
        XCTAssertFalse(result.granularityMatched, "旧 daemon 返回小时数据时应触发降级")
    }

    func testIsPeakFlagsMaxBucketOnly() {
        let resp = blocks(["2026-09-01T13:07:00", "2026-09-01T13:12:00", "2026-09-01T13:12:30"], tokens: 50)
        let result = UsageBucketAggregator.aggregate([resp], range: .oneHour, now: now)
        XCTAssertEqual(result.buckets.filter(\.isPeak).count, 1)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd TokenDashSwift && swift test --filter UsageBucketAggregator`
Expected: 编译 FAIL — 类型不存在。

- [ ] **Step 3: 实现**

`APIModels.swift`：`HourBucket` 整体替换为：

```swift
struct TimeBucket: Identifiable {
    let start: Date     // 桶起始时间（本地时区语义，与 daemon 的 Asia/Shanghai 聚合对齐）
    let minutes: Int    // 桶时长（60 / 15 / 5）
    let tokens: Int
    let isPeak: Bool
    var id: Date { start }
}
```

（全仓 `HourBucket` 引用此刻会编译失败——`AppState.hourlyData` 与 `BadgeUpdater.computeHourly` 在本 Task 一并切换最小接线：`AppState.hourlyData: [TimeBucket] = []`；`BadgeUpdater.computeHourly` 函数体临时替换为返回 `UsageBucketAggregator.aggregate(blocks, range: .today, now: Date()).buckets`，Task 8 再完整接线。）

新建 `UsageBucketAggregator.swift`：

```swift
import Foundation

/// Aggregates daemon blocks into chart buckets for a given hourly range.
/// Pure function so it is directly unit-testable without the network layer.
enum UsageBucketAggregator {

    struct Aggregation {
        let buckets: [TimeBucket]
        /// false when a fine-grained request came back hour-aligned only
        /// (legacy daemon ignored the granularity parameter) — callers fall
        /// back to rendering the Today view instead.
        let granularityMatched: Bool
    }

    static func aggregate(_ responses: [BlocksResponse], range: SettingsStore.HourlyRange, now: Date) -> Aggregation {
        let calendar = Calendar.current
        let bucketMinutes = range.bucketMinutes

        let windowStart: Date
        switch range {
        case .today:
            windowStart = calendar.startOfDay(for: now)
        case .threeHours, .oneHour:
            let windowSeconds: TimeInterval = range == .threeHours ? 3 * 3600 : 3600
            let alignedNow = align(now, to: bucketMinutes, calendar: calendar)
            windowStart = alignedNow.addingTimeInterval(-windowSeconds + TimeInterval(bucketMinutes) * 60)
        }

        var totals: [Date: Int] = [:]
        var sawSubHourBucket = false
        let parseFormatter = ISO8601LocalFormatter.shared

        for response in responses {
            for block in response.blocks {
                guard let start = parseFormatter.date(from: block.startTime) else { continue }
                guard start >= windowStart, start <= now.addingTimeInterval(TimeInterval(bucketMinutes) * 60) else { continue }
                let bucketStart = align(start, to: bucketMinutes, calendar: calendar)
                totals[bucketStart, default: 0] += block.totalTokens
                // A start minute that is not hour-aligned proves the daemon
                // honored the fine-grained request (legacy data is :00 only).
                if bucketMinutes < 60, calendar.component(.minute, from: start) % 60 != 0 {
                    sawSubHourBucket = true
                }
            }
        }

        // Bucket skeleton for the window
        var buckets: [TimeBucket] = []
        var cursor = windowStart
        let windowEnd = range == .today
            ? calendar.startOfDay(for: now).addingTimeInterval(24 * 3600)
            : windowStart.addingTimeInterval(range == .threeHours ? 3 * 3600 : 3600)
        let maxTokens = totals.values.max() ?? 0
        while cursor < windowEnd {
            let tokens = totals[cursor] ?? 0
            buckets.append(TimeBucket(
                start: cursor,
                minutes: bucketMinutes,
                tokens: tokens,
                isPeak: tokens > 0 && tokens == maxTokens
            ))
            cursor = cursor.addingTimeInterval(TimeInterval(bucketMinutes) * 60)
        }

        // For .today keep only elapsed hours (matches existing 0...currentHour filter,
        // applied by the chart via displayBuckets rather than here when needed).
        let matched = range == .today
            || sawSubHourBucket
            || buckets.allSatisfy { $0.tokens == 0 }   // empty window can't disprove
        return Aggregation(buckets: buckets, granularityMatched: matched)
    }

    private static func align(_ date: Date, to minutes: Int, calendar: Calendar) -> Date {
        guard let aligned = calendar.dateInterval(of: .minute, value: minutes, for: date)?.start else {
            return date
        }
        return aligned
    }
}

/// daemon blocks startTime is "yyyy-MM-dd'T'HH:mm[:ss]" with no zone — parsed
/// in the local timezone, matching how the daemon aggregates at Asia/Shanghai.
final class ISO8601LocalFormatter {
    static let shared: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.timeZone = TimeZone.current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    func date(from string: String) -> Date? {
        if let d = Self.shared.date(from: string) { return d }          // ...:00 (fine-grained)
        // hour entries are "yyyy-MM-dd'T'HH:00:00" — same shape; tolerate
        // second-less variants just in case.
        let alt = DateFormatter()
        alt.dateFormat = "yyyy-MM-dd'T'HH:mm"
        alt.timeZone = TimeZone.current
        alt.locale = Locale(identifier: "en_US_POSIX")
        return alt.date(from: string)
    }
}
```

> `.today` 的 elapsed 过滤（只渲染 0…当前小时）由 `HourlyChartView.displayBuckets`（Task 9）完成，聚合器始终返回完整 24 桶骨架——`testTodayBucketsFull24HourSkeleton` 按此断言。

- [ ] **Step 4: 运行测试确认通过**

Run: `cd TokenDashSwift && swift test --filter UsageBucketAggregator`
Expected: PASS（7 个用例）。

- [ ] **Step 5: Commit**

```bash
git add TokenDashSwift/Sources/TokenDash/Models/UsageBucketAggregator.swift TokenDashSwift/Sources/TokenDash/Models/APIModels.swift TokenDashSwift/Sources/TokenDash/Models/AppState.swift TokenDashSwift/Sources/TokenDash/BadgeUpdater.swift TokenDashSwift/Tests/TokenDashTests/UsageBucketAggregatorTests.swift
git commit -m "Aggregate daemon blocks into per-range time buckets"
```

### Task 8: BadgeUpdater 接线（粒度请求 + 档位切换重拉 + 5min 节流）

**Files:**
- Modify: `TokenDashSwift/Sources/TokenDash/BadgeUpdater.swift`
- Test: `TokenDashSwift/Tests/TokenDashTests/BadgeUpdaterModeTests.swift`（追加 3 个用例）

- [ ] **Step 1: 追加失败测试**

```swift
    // MARK: - hourly range granularity

    func testFullUpdateRequestsGranularityMatchingRange() async throws {
        let state = AppState()
        let mock = MockAPIClient()
        let updater = BadgeUpdater(state: state, client: mock)
        let original = SettingsStore.shared.hourlyRange
        defer { SettingsStore.shared.hourlyRange = original }

        SettingsStore.shared.hourlyRange = .threeHours
        await updater.performFullUpdate(forceRefresh: false, forceQuota: false)
        let granularity = await mock.lastBlocksGranularity
        XCTAssertEqual(granularity, .fifteenMin, "3H 档位必须请求 15m 粒度")

        SettingsStore.shared.hourlyRange = .oneHour
        await updater.performFullUpdate(forceRefresh: false, forceQuota: false)
        let granularity2 = await mock.lastBlocksGranularity
        XCTAssertEqual(granularity2, .fiveMin, "1H 档位必须请求 5m 粒度")
    }

    func testRangeChangeTriggersCacheServedRefetch() async throws {
        let state = AppState()
        let mock = MockAPIClient()
        let updater = BadgeUpdater(state: state, client: mock)
        let original = SettingsStore.shared.hourlyRange
        defer { SettingsStore.shared.hourlyRange = original }

        await updater.performFullUpdate(forceRefresh: false, forceQuota: false)
        let counts = await mock.snapshot()

        updater.refetchDetailForRangeChange()
        try await waitUntil { await mock.snapshot().blocks > counts.blocks }

        let lastDailyRefresh = await mock.lastDailyRefresh
        XCTAssertEqual(lastDailyRefresh, false, "档位切换重拉走缓存（refresh=false），不强扫 JSONL")
    }

    func testFineGrainedRangeTightensPopoverThrottleToFiveMinutes() async throws {
        let state = AppState()
        let mock = MockAPIClient()
        var now = Date(timeIntervalSinceReferenceDate: 1_000)
        let updater = BadgeUpdater(
            state: state, client: mock, now: { now }, popoverRefreshInterval: 30 * 60
        )
        let original = SettingsStore.shared.hourlyRange
        defer { SettingsStore.shared.hourlyRange = original }

        await updater.performFullUpdate(forceRefresh: true, forceQuota: false)
        let countsAfterFirst = await mock.snapshot().daily

        now.addTimeInterval(6 * 60)   // 6min：30min 节流内、5min 节流外
        SettingsStore.shared.hourlyRange = .oneHour
        let refreshed = await updater.refreshOnPopoverOpenIfNeeded()
        XCTAssertTrue(refreshed, "1H 档位下 popover 打开的节流必须收紧到 5min")
        let countsAfterOpen = await mock.snapshot().daily
        XCTAssertGreaterThan(countsAfterOpen, countsAfterFirst)
    }
```

- [ ] **Step 2: 运行确认失败**

Run: `cd TokenDashSwift && swift test --filter BadgeUpdaterModeTests`
Expected: FAIL — `refetchDetailForRangeChange` 不存在、granularity 断言失败。

- [ ] **Step 3: 实现**

`BadgeUpdater.swift`：

1) granularity 映射 + 请求处（`performFullUpdate` 内 `api.getBlocks` 行）：

```swift
    static func blocksGranularity(for range: SettingsStore.HourlyRange) -> BlocksGranularity {
        switch range {
        case .today: return .hour
        case .threeHours: return .fifteenMin
        case .oneHour: return .fiveMin
        }
    }
```

```swift
                let granularity = Self.blocksGranularity(for: SettingsStore.shared.hourlyRange)
                if let b = try? await api.getBlocks(agent: agent, refresh: forceRefresh, granularity: granularity) { blockResults.append(b) }
```

2) `computeHourly` 替换为聚合器调用（含降级）：

```swift
    private func computeBuckets(blocks: [BlocksResponse]) -> (buckets: [TimeBucket], matched: Bool) {
        let range = SettingsStore.shared.hourlyRange
        let result = UsageBucketAggregator.aggregate(blocks, range: range, now: Date())
        guard result.granularityMatched || range == .today else {
            // Legacy daemon ignored granularity — fall back to the Today view.
            let fallback = UsageBucketAggregator.aggregate(blocks, range: .today, now: Date())
            return (fallback.buckets, false)
        }
        return (result.buckets, result.granularityMatched)
    }
```

`performFullUpdate` 中原 `let computedHourly = computeHourly(blocks: blockResults, today: today)` 改：

```swift
            let (computedBuckets, _) = computeBuckets(blocks: blockResults)
```

下方 stale-while-revalidate 判断 `computedHourly.allSatisfy { $0.tokens == 0 }` 同步换 `computedBuckets`；`self.state.hourlyData = hourly` 的 `hourly` 变量同步为 `computedBuckets`（保留 stale 回退逻辑不变）。

3) 档位切换重拉：

```swift
    /// Range changed (Settings picker or chart tabs) — refetch detail with the
    /// new granularity. Cache-served: the daemon's 5-min response cache makes
    /// repeat toggles cheap; a cold key triggers one parse server-side.
    func refetchDetailForRangeChange() {
        guard mode != .suspended else { return }
        Task { await self.performFullUpdate(forceRefresh: false, forceQuota: false) }
    }
```

4) 节流收紧（`refreshOnPopoverOpenIfNeeded`）：

```swift
        let currentTime = now()
        let throttle: TimeInterval = SettingsStore.shared.hourlyRange == .today
            ? popoverRefreshInterval
            : min(popoverRefreshInterval, 5 * 60)
        if let lastUpdatedAt = state.lastUpdatedAt,
           currentTime.timeIntervalSince(lastUpdatedAt) < throttle {
            return false
        }
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cd TokenDashSwift && swift test`
Expected: 全部 PASS（含既有 13 个模式用例回归）。

- [ ] **Step 5: Commit**

```bash
git add TokenDashSwift/Sources/TokenDash/BadgeUpdater.swift TokenDashSwift/Tests/TokenDashTests/BadgeUpdaterModeTests.swift
git commit -m "Fetch and throttle hourly data by the selected range"
```

### Task 9: SettingsView 行 + HourlyChartView 三档 UI

**Files:**
- Modify: `TokenDashSwift/Sources/TokenDash/Views/SettingsView.swift`、`Views/HourlyChartView.swift`

- [ ] **Step 1: SettingsView General 卡片加行**

`generalCard` 中 "Background Refresh" 行后插入（原 Appearance 行 `showDivider: false` 改 `true`）：

```swift
                SettingsRow(icon: "chart.xyaxis.line", title: "Hourly Chart", showDivider: true) {
                    Picker("", selection: $settings.hourlyRange) {
                        ForEach(SettingsStore.HourlyRange.allCases) { range in
                            Text(range.label).tag(range)
                        }
                    }
                    .pickerStyle(.menu).controlSize(.small).frame(width: 150).labelsHidden()
                    .onChange(of: settings.hourlyRange) { _, _ in
                        state.badgeUpdater?.refetchDetailForRangeChange()
                    }
                }
```

（Appearance 行改为 `showDivider: false` 收尾。）

- [ ] **Step 2: HourlyChartView 三档化（Date 轴）**

核心改动（保留 pulse 相关结构不动，`pulseEnabled` 仍 false）：

```swift
struct HourlyChartView: View {
    let data: [TimeBucket]
    let pulseSamples: [TokenPulseSample]
    @Environment(AppState.self) private var state
    @Bindable private var settings = SettingsStore.shared
    @State private var hoveredBucketID: Date?
    @Namespace private var selectorAnimation

    private var range: SettingsStore.HourlyRange { settings.hourlyRange }

    private var now: Date { Date() }

    private var calendar: Calendar { Calendar.current }

    /// today：仅展示已流逝小时；细粒度档展示全部窗口桶。
    private var displayBuckets: [TimeBucket] {
        switch range {
        case .today:
            let currentHourStart = calendar.dateInterval(of: .hour, for: now)?.start ?? now
            return data.filter { $0.start <= currentHourStart }
        case .threeHours, .oneHour:
            return data
        }
    }

    private var currentBucketStart: Date? {
        calendar.dateInterval(of: .minute, value: range.bucketMinutes, for: now)?.start
    }

    private var hoveredBucket: TimeBucket? {
        guard let hoveredBucketID else { return nil }
        return displayBuckets.first { $0.start == hoveredBucketID }
    }

    private var yAxisUpperBound: Int {
        let maximum = displayBuckets.map(\.tokens).max() ?? 0
        return max(1, Int(ceil(Double(maximum) * 1.15)))
    }

    private var xDomain: (min: Date, max: Date) {
        switch range {
        case .today:
            let start = calendar.startOfDay(for: now)
            return (start, start.addingTimeInterval(24 * 3600))
        case .threeHours, .oneHour:
            let window: TimeInterval = range == .threeHours ? 3 * 3600 : 3600
            let alignedNow = calendar.dateInterval(of: .minute, value: range.bucketMinutes, for: now)?.start ?? now
            return (alignedNow.addingTimeInterval(-window + TimeInterval(range.bucketMinutes) * 60),
                    alignedNow.addingTimeInterval(TimeInterval(range.bucketMinutes) * 60))
        }
    }
```

`ChartMode` enum 删除，`selectedMode` 删除；`header` 的 tabs 分支改为无条件渲染（`pulseEnabled` 为 false 时原 pulse 分支已不进）：

```swift
            Spacer()

            modeTabs
```

`modeTabs` 重写（绑定 settings.hourlyRange）：

```swift
    private var modeTabs: some View {
        HStack(spacing: 2) {
            ForEach(SettingsStore.HourlyRange.allCases) { range in
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        settings.hourlyRange = range
                    }
                    state.badgeUpdater?.refetchDetailForRangeChange()
                } label: {
                    Text(range.shortLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(self.range == range ? Color.white : Color.secondaryLabel)
                        .padding(.horizontal, 11)
                        .frame(height: 24)
                        .background {
                            if self.range == range {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.accentGreen)
                                    .matchedGeometryEffect(id: "hour-mode-selection", in: selectorAnimation)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(self.range == range ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .fixedSize()
        .animation(.easeInOut(duration: 0.12), value: range)
    }
```

`chartArea` 重写为 Date 轴：

```swift
    private var chartArea: some View {
        Chart {
            ForEach(displayBuckets) { bucket in
                AreaMark(
                    x: .value("Time", bucket.start),
                    y: .value("Tokens", bucket.tokens)
                )
                .foregroundStyle(
                    .linearGradient(
                        colors: [Color.accentGreen.opacity(0.3), Color.accentGreen.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("Time", bucket.start),
                    y: .value("Tokens", bucket.tokens)
                )
                .foregroundStyle(Color.accentGreen)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.catmullRom)

                if bucket.start == currentBucketStart {
                    PointMark(x: .value("Time", bucket.start), y: .value("Tokens", bucket.tokens))
                        .foregroundStyle(Color.accentGreen.opacity(0.12))
                        .symbolSize(80)

                    PointMark(x: .value("Time", bucket.start), y: .value("Tokens", bucket.tokens))
                        .foregroundStyle(Color.accentGreen)
                        .symbolSize(20)
                }
            }

            if let hoveredBucket {
                RuleMark(x: .value("Selected time", hoveredBucket.start))
                    .foregroundStyle(.secondary.opacity(0.25))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))

                PointMark(
                    x: .value("Selected time", hoveredBucket.start),
                    y: .value("Selected tokens", hoveredBucket.tokens)
                )
                .foregroundStyle(Color.accentGreen)
                .symbolSize(34)
                .annotation(position: .top, spacing: 6) {
                    hoverLabel(for: hoveredBucket)
                }
            }
        }
        .chartXScale(domain: xDomain.min...xDomain.max)
        .chartYScale(domain: 0...yAxisUpperBound)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.primary.opacity(0.05))
                AxisValueLabel {
                    if let tokens = value.as(Int.self) {
                        Text(formatTokens(tokens))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color.tertiaryLabel)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: xAxisValues) { value in
                if let date = value.as(Date.self) {
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        .foregroundStyle(.primary.opacity(0.03))
                    AxisValueLabel {
                        Text(xAxisLabel(for: date))
                            .font(.system(size: 9, weight: date == currentBucketStart ? .semibold : .medium))
                            .foregroundStyle(timeLabelColor(for: date))
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            updateHoveredBucket(at: location, proxy: proxy, geometry: geometry)
                        case .ended:
                            hoveredBucketID = nil
                        }
                    }
            }
        }
        .frame(height: 110)
    }

    private var xAxisValues: [Date] {
        switch range {
        case .today:
            let start = calendar.startOfDay(for: now)
            return [0, 3, 6, 9, 12, 15, 18, 21].compactMap {
                calendar.date(byAdding: .hour, value: $0, to: start)
            }
        case .threeHours, .oneHour:
            // 窗口内均匀取 4 个对齐刻度（含起点）
            let minutes = range.bucketMinutes
            let step = range == .threeHours ? 60 : 15
            var values: [Date] = []
            var cursor = xDomain.min
            while cursor <= xDomain.max {
                values.append(cursor)
                cursor = cursor.addingTimeInterval(TimeInterval(step) * 60)
            }
            _ = minutes
            return values
        }
    }

    private func xAxisLabel(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        switch range {
        case .today:
            f.dateFormat = "H"                    // 保持现状 "0"..."21"
            return f.string(from: date)
        case .threeHours, .oneHour:
            f.dateFormat = "HH:mm"
            return f.string(from: date)
        }
    }

    private func timeLabelColor(for date: Date) -> Color {
        if date == currentBucketStart { return Color.accentGreen }
        if date > now { return Color.futureLabelColor }
        return Color.tertiaryLabel
    }

    private func updateHoveredBucket(
        at location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) {
        guard let plotFrame = proxy.plotFrame else {
            hoveredBucketID = nil
            return
        }
        let frame = geometry[plotFrame]
        guard frame.contains(location) else {
            hoveredBucketID = nil
            return
        }
        let plotX = location.x - frame.minX
        guard let date: Date = proxy.value(atX: plotX) else {
            hoveredBucketID = nil
            return
        }
        // 落到最近的桶起始
        let minutes = range.bucketMinutes
        let aligned = calendar.dateInterval(of: .minute, value: minutes, for: date)?.start ?? date
        hoveredBucketID = displayBuckets.contains { $0.start == aligned } ? aligned : nil
    }

    private func hoverLabel(for bucket: TimeBucket) -> some View {
        VStack(spacing: 1) {
            let f = DateFormatter()
            // 构造处设置（无法在 ViewBuilder 内声明 formatter 后立即用，提到属性即可）
            Text(bucketLabel(for: bucket))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text("\(formatTokens(bucket.tokens)) tokens")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(.primary.opacity(0.08), lineWidth: 0.5)
        }
    }

    private func bucketLabel(for bucket: TimeBucket) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = range == .today ? "HH:00" : "HH:mm"
        return f.string(from: bucket.start)
    }
```

> hoverLabel 中不能内联 `let f`，用 `bucketLabel(for:)` 辅助（上面已给出）。`xAxisValues` 里 `_ = minutes` 一行删除（遗留说明）。`currentHour`/`elapsedData`/`hoveredHour`/`updateHoveredHour` 等旧 Int-hour 辅助整体删除。

`body` 的空态分支同步改（细粒度档空窗口渲染 0 折线，不走空态文案；空态仅保留给 Today，与现状一致）：

```swift
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 10)

            if pulseEnabled && settings.hourlyRange != .today {
                // pulse 分支结构保留（pulseEnabled=false 永不进入）
                EmptyView()
            } else if range == .today && data.allSatisfy({ $0.tokens == 0 }) {
                emptyChart
            } else {
                chartArea
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
```

（`pulseEnabled && selectedMode == .pulse` 的两个旧引用——body 与 header——随 `selectedMode` 删除一并清理：header 保留现有 "HOURLY" 标题分支与 `Spacer()` + `modeTabs`。）

- [ ] **Step 3: 编译 + 全量 Swift 测试**

Run: `cd TokenDashSwift && swift test`
Expected: BUILD SUCCEEDED，全部 PASS。

- [ ] **Step 4: Commit**

```bash
git add TokenDashSwift/Sources/TokenDash/Views/SettingsView.swift TokenDashSwift/Sources/TokenDash/Views/HourlyChartView.swift
git commit -m "Render the hourly chart across today, 3-hour, and 1-hour ranges"
```

### Task 10: 端到端验证（构建、替换 bundle、重启实测）

**Files:** 无新文件（验证 + `.wolf` 记录）

- [ ] **Step 1: 全量测试**

Run: `npm test && cd TokenDashSwift && swift test`
Expected: 全部 PASS。

- [ ] **Step 2: 构建 Swift 二进制并替换进 /Applications 的 app bundle（cerebrum 已知捷径）**

```bash
cd TokenDashSwift && swift build -c release
cp .build/release/TokenDash /Applications/TokenDash.app/Contents/MacOS/TokenDash
install_name_tool -add_rpath '@executable_path/../Frameworks' /Applications/TokenDash.app/Contents/MacOS/TokenDash
codesign --force --sign - /Applications/TokenDash.app/Contents/MacOS/TokenDash
codesign --force --sign - /Applications/TokenDash.app
open /Applications/TokenDash.app
```

同时重建 daemon 产物（daemon 是 app bundle 内打包的 node 产物；本地开发用 `npm run build` 后 daemon 从 dist 跑——按 `DaemonManager` 现状，若 app 从 bundle Resources 跑 daemon 则需要重新 package-app.sh；优先先 `npm run build` + 让 app 连 3456 现有 daemon 验证 API，再决定是否全量打包）。验证顺序：

1. `npm run build && node dist/daemon.cjs &` → curl 三粒度（同 Task 4 Step 3）
2. 打开 popover：默认 Today 视图与升级前一致（24h、整点轴）
3. 图表头部切 3H：12 桶、HH:mm 轴、当前桶高亮点；Settings → General → Hourly Chart 同步显示 "Last 3 Hours"
4. 切 1H：12 桶 5min；悬浮 tooltip 显示 HH:mm
5. Settings 里切回 Today：图表立即回到 24h 视图并触发重拉
6. 凌晨跨天场景可次日观察（窗口含昨天桶，X 轴日期自然回退）

- [ ] **Step 3: 修复发现的问题（如有），重跑 Step 1-2**

任何 UI/数据问题：修复 → swift test → 重新替换二进制 → 重开 app 复验。

- [ ] **Step 4: 更新 OpenWolf 记录 + 最终 commit**

```bash
# .wolf/memory.md 追加验证结果行；.wolf/anatomy.md 若有新文件（UsageBucketAggregator.swift 等）已在前序 task 记录则跳过
git add .wolf/memory.md
git commit -m "Verify the hourly range filter end to end"
```

---

## Self-Review 记录

- **Spec coverage**：PRD §2 三档（Task 1-4 数据 + Task 7 聚合 + Task 9 UI）✓；Settings General 配置（Task 9 Step 1）✓；tabs 写回 Settings（Task 9 modeTabs 绑定 settings.hourlyRange）✓；5min 节流（Task 8）✓；跨天（Task 7 测试）✓；降级（Task 7/8）✓；空窗口 0 折线（聚合器骨架桶天然为 0，图表不再走 emptyChart 判定——`data.allSatisfy { $0.tokens == 0 }` 分支仅 today 保留为原空态，细粒度档跳过空态判断直接渲染 0 线，Task 9 body 的条件改为 `range == .today && data.allSatisfy...` 时走 emptyChart）✓
- **Type consistency**：`BlockGranularity`（TS）/`BlocksGranularity`（Swift）命名区分；`TimeBucket` 全链路一致；`getFiveMinKey`/`coarsenBucketKey` 在 codex/pi 测试中用 alias 导入避免重名冲突 ✓
- **已知实现期注意点**：codex `buildBlocksResponseFromSummaries` 的 bucket 内部结构（models/cost 形状）以文件现状为准；Swift Charts `dateInterval(of:value:)` 需 macOS 13+（项目为 macOS 26+ 目标，无碍）
