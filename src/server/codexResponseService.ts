import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { Worker } from 'node:worker_threads';
import type { DailyResponse, ProjectsResponse, BlocksResponse } from '../shared/types.js';
import { getBlocksResponse, getCodexResponses, getDailyResponse, getProjectsResponse, type AggregateOptions } from './codexParser.js';

interface CodexResponseBundle {
  daily: DailyResponse;
  projects: ProjectsResponse;
  blocks: BlocksResponse;
}

type CodexResponseKind = 'bundle' | 'daily' | 'projects' | 'blocks';

type CodexResponseByKind<K extends CodexResponseKind> =
  K extends 'bundle' ? CodexResponseBundle :
  K extends 'daily' ? DailyResponse :
  K extends 'projects' ? ProjectsResponse :
  BlocksResponse;

interface SerializedAggregateOptions {
  groupBy?: AggregateOptions['groupBy'];
  project?: string | null;
  since?: string | null;
  until?: string | null;
  timezone?: string;
}

interface WorkerSuccess<K extends CodexResponseKind> {
  id: number;
  ok: true;
  data: CodexResponseByKind<K>;
}

interface WorkerFailure {
  id: number;
  ok: false;
  error: string;
  stack?: string;
}

const DEFAULT_WORKER_TIMEOUT_MS = 120_000;
const RESULT_TTL_MS = 30_000;
let nextRequestId = 1;
const inFlight = new Map<string, Promise<unknown>>();
const resultCache = new Map<string, { data: unknown; expiresAt: number }>();

function serializeOptions(options?: Partial<AggregateOptions>): SerializedAggregateOptions | undefined {
  if (!options) return undefined;
  return {
    groupBy: options.groupBy,
    project: options.project,
    since: options.since ? options.since.toISOString() : options.since,
    until: options.until ? options.until.toISOString() : options.until,
    timezone: options.timezone,
  };
}

function requestKey(kind: CodexResponseKind, options?: Partial<AggregateOptions>): string {
  return `${kind}:${JSON.stringify(serializeOptions(options) ?? {})}`;
}

function workerTimeoutMs(): number {
  const raw = Number.parseInt(process.env.TOKENDASH_CODEX_WORKER_TIMEOUT_MS || '', 10);
  return Number.isFinite(raw) && raw > 0 ? raw : DEFAULT_WORKER_TIMEOUT_MS;
}

export function resolveCodexWorkerPath(moduleUrl = import.meta.url): string {
  const currentPath = fileURLToPath(moduleUrl);
  const currentDir = dirname(currentPath);

  // Bundled daemon/electron-server entries live at dist/*.cjs while tsc emits
  // worker modules to dist/server/*.js. Keep the worker outside the bundle so
  // heavy Codex parsing cannot block the HTTP server's main event loop.
  if (currentPath.endsWith('.cjs')) {
    return join(currentDir, 'server', 'codexResponseWorker.js');
  }

  const ext = currentPath.endsWith('.ts') ? '.ts' : '.js';
  const sameDir = join(currentDir, `codexResponseWorker${ext}`);
  if (existsSync(sameDir)) return sameDir;

  const distServer = join(currentDir, 'server', 'codexResponseWorker.js');
  if (existsSync(distServer)) return distServer;

  return sameDir;
}

function workerExecArgv(workerPath: string): string[] {
  if (!workerPath.endsWith('.ts')) return process.execArgv;
  const alreadyLoadsTsx = process.execArgv.some(arg => arg.includes('tsx'));
  if (alreadyLoadsTsx) return process.execArgv;
  return [...process.execArgv, '--import', 'tsx'];
}

function runSync<K extends CodexResponseKind>(kind: K, options?: Partial<AggregateOptions>): CodexResponseByKind<K> {
  switch (kind) {
    case 'bundle':
      return getCodexResponses(options) as CodexResponseByKind<K>;
    case 'daily':
      return getDailyResponse(options) as CodexResponseByKind<K>;
    case 'projects':
      return getProjectsResponse(options) as CodexResponseByKind<K>;
    case 'blocks':
      return getBlocksResponse(options) as CodexResponseByKind<K>;
  }
}

function runInWorker<K extends CodexResponseKind>(kind: K, options?: Partial<AggregateOptions>): Promise<CodexResponseByKind<K>> {
  const workerPath = resolveCodexWorkerPath();
  if (workerPath.endsWith('.ts')) {
    return Promise.resolve(runSync(kind, options));
  }
  const id = nextRequestId++;

  return new Promise<CodexResponseByKind<K>>((resolve, reject) => {
    const worker = new Worker(pathToFileURL(workerPath), {
      execArgv: workerExecArgv(workerPath),
      env: process.env,
    });
    let settled = false;
    const timeout = setTimeout(() => {
      if (settled) return;
      settled = true;
      void worker.terminate();
      reject(new Error(`Codex usage parsing timed out after ${workerTimeoutMs()}ms`));
    }, workerTimeoutMs());

    const finish = (fn: () => void) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      fn();
    };

    worker.once('message', (message: WorkerSuccess<K> | WorkerFailure) => {
      finish(() => {
        void worker.terminate();
        if (message.ok) {
          resolve(message.data);
        } else {
          const error = new Error(message.error);
          if (message.stack) error.stack = message.stack;
          reject(error);
        }
      });
    });

    worker.once('error', error => {
      finish(() => {
        void worker.terminate();
        reject(error);
      });
    });

    worker.once('exit', code => {
      if (code === 0 || settled) return;
      finish(() => reject(new Error(`Codex usage worker exited with code ${code}`)));
    });

    worker.postMessage({ id, kind, options: serializeOptions(options) });
  });
}

export async function getCodexResponse<K extends CodexResponseKind>(
  kind: K,
  options?: Partial<AggregateOptions>,
): Promise<CodexResponseByKind<K>> {
  if (process.env.TOKENDASH_DISABLE_CODEX_WORKER === '1') {
    return runSync(kind, options);
  }

  const key = requestKey(kind, options);
  const cached = resultCache.get(key) as { data: CodexResponseByKind<K>; expiresAt: number } | undefined;
  if (cached && Date.now() <= cached.expiresAt) return cached.data;

  const existing = inFlight.get(key) as Promise<CodexResponseByKind<K>> | undefined;
  if (existing) return existing;

  const promise = runInWorker(kind, options)
    .then(data => {
      resultCache.set(key, { data, expiresAt: Date.now() + RESULT_TTL_MS });
      return data;
    })
    .finally(() => {
      inFlight.delete(key);
    });
  inFlight.set(key, promise);
  return promise;
}

function usesDefaultBundleOptions(options?: Partial<AggregateOptions>): boolean {
  return !options || (
    !options.project
    && !options.since
    && !options.until
    && !options.groupBy
    && (!options.timezone || options.timezone === 'Asia/Shanghai')
  );
}

export async function getCodexDailyResponse(options?: Partial<AggregateOptions>): Promise<DailyResponse> {
  if (usesDefaultBundleOptions(options)) return (await getCodexResponse('bundle')).daily;
  return getCodexResponse('daily', options);
}

export async function getCodexProjectsResponse(options?: Partial<AggregateOptions>): Promise<ProjectsResponse> {
  if (usesDefaultBundleOptions(options)) return (await getCodexResponse('bundle')).projects;
  return getCodexResponse('projects', options);
}

export async function getCodexBlocksResponse(options?: Partial<AggregateOptions>): Promise<BlocksResponse> {
  if (usesDefaultBundleOptions(options)) return (await getCodexResponse('bundle')).blocks;
  return getCodexResponse('blocks', options);
}
