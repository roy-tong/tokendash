import type {
  QuotaCredentialInput,
  QuotaCredentialValidation,
  QuotaSnapshot,
  QuotaProviderId,
  QuotaProviderStatus,
  QuotaResponse,
} from './types.js';
import type { QuotaAdapter, QuotaAdapterRegistry } from './adapter.js';
import { QuotaError } from './adapter.js';
import { QuotaCache } from './cache.js';
import { validateQuotaSnapshot } from './schemas.js';

/**
 * Deep quota service. Owns discovery, concurrency, deduplication, caching,
 * last-good fallback, timeouts, and error classification. Adapters only
 * detect + fetch + normalize; everything cross-cutting lives here.
 */
export class QuotaService {
  /** Cap concurrent upstream calls so a slow provider can't block the others. */
  private readonly fetchTimeoutMs: number;
  /** In-flight promises keyed by provider id, to dedupe concurrent requests. */
  private readonly inflight = new Map<string, Promise<QuotaSnapshot>>();
  /** Monotonic provider generation so superseded requests cannot overwrite fresh cache data. */
  private readonly fetchGeneration = new Map<QuotaProviderId, number>();

  constructor(
    private readonly registry: QuotaAdapterRegistry,
    private readonly cache: QuotaCache = new QuotaCache(),
    private readonly configuredCache: QuotaProviderId[] | null = null,
    fetchTimeoutMs = 8_000,
  ) {
    this.fetchTimeoutMs = fetchTimeoutMs;
  }

  /**
   * List provider ids that are configured locally. Cheap (no network).
   * The dashboard only shows these — not-configured providers are excluded.
   */
  async discover(): Promise<QuotaProviderId[]> {
    const all = this.registry.list();
    const checks = await Promise.all(
      all.map(async (a) => ({ id: a.provider, configured: await safeIsConfigured(a) })),
    );
    return checks.filter((c) => c.configured).map((c) => c.id);
  }

  /**
   * Fetch one provider's snapshot. Fresh if available; last-good retained
   * on failure; never throws (errors become structured statuses).
   */
  async fetchOne(provider: QuotaProviderId): Promise<QuotaSnapshot | null> {
    // 1. Fresh cache hit
    const fresh = this.cache.getFresh(provider);
    if (fresh) return fresh;

    const adapter = this.registry.get(provider);
    if (!adapter) return null;

    // 2. Dedupe concurrent requests for the same provider
    let p = this.inflight.get(provider);
    if (!p) {
      p = this.startFetch(adapter, this.fetchGeneration.get(provider) ?? 0);
    }
    return p;
  }

  /**
   * Fetch all configured providers concurrently. Partial success: one
   * provider's failure never breaks the others. Order = registry order.
   */
  async fetchAll(): Promise<QuotaResponse> {
    const ids = this.configuredCache ?? (await this.discover());
    const byId = new Map<string, QuotaSnapshot>();
    const snapshots = await Promise.all(ids.map((id) => this.fetchOne(id)));
    // Preserve registry order regardless of completion order.
    for (const adapter of this.registry.list()) {
      const snap = snapshots.find((s) => s?.provider === adapter.provider);
      if (snap) byId.set(adapter.provider, snap);
    }
    return { providers: this.registry.list().map((a) => byId.get(a.provider)).filter((s): s is QuotaSnapshot => !!s) };
  }

  /** Force a refresh of all configured providers, bypassing the cache. */
  async refreshAll(): Promise<QuotaResponse> {
    const ids = this.configuredCache ?? (await this.discover());
    const snapshots = await Promise.all(ids.map((provider) => {
      const adapter = this.registry.get(provider);
      if (!adapter) return Promise.resolve(null);
      const generation = (this.fetchGeneration.get(provider) ?? 0) + 1;
      this.fetchGeneration.set(provider, generation);
      this.cache.clear(provider);
      return this.startFetch(adapter, generation);
    }));
    const byId = new Map<QuotaProviderId, QuotaSnapshot>();
    for (const snapshot of snapshots) {
      if (snapshot) byId.set(snapshot.provider, snapshot);
    }
    return {
      providers: this.registry.list()
        .map((adapter) => byId.get(adapter.provider))
        .filter((snapshot): snapshot is QuotaSnapshot => !!snapshot),
    };
  }

  /**
   * Validate a credential without caching it or writing it to disk. This keeps
   * the settings form transactional: only credentials accepted upstream are
   * persisted by the native app.
   */
  async validateCredential(
    provider: QuotaProviderId,
    credential: QuotaCredentialInput,
  ): Promise<QuotaCredentialValidation> {
    const adapter = this.registry.get(provider);
    if (!adapter) {
      return {
        provider,
        valid: false,
        status: { state: 'not_configured', message: 'Unsupported provider' },
      };
    }

    try {
      const snapshot = await withTimeout(
        adapter.fetch({ credential }),
        timeoutForAdapter(adapter, this.fetchTimeoutMs),
        provider,
      );
      const validated = validateQuotaSnapshot(snapshot);
      return { provider, valid: validated.status.state === 'ok', status: validated.status };
    } catch (err) {
      return { provider, valid: false, status: statusForError(err, this.fetchTimeoutMs) };
    }
  }

  private startFetch(adapter: QuotaAdapter, generation: number): Promise<QuotaSnapshot> {
    let promise: Promise<QuotaSnapshot>;
    promise = this.fetchWithTimeout(adapter, generation).finally(() => {
      if (this.inflight.get(adapter.provider) === promise) {
        this.inflight.delete(adapter.provider);
      }
    });
    this.inflight.set(adapter.provider, promise);
    return promise;
  }

  private async fetchWithTimeout(adapter: QuotaAdapter, generation: number): Promise<QuotaSnapshot> {
    try {
      const snapshot = await withTimeout(
        adapter.fetch(),
        timeoutForAdapter(adapter, this.fetchTimeoutMs),
        adapter.provider,
      );
      const validated = validateQuotaSnapshot(snapshot);
      if ((this.fetchGeneration.get(adapter.provider) ?? 0) === generation) {
        this.cache.set(validated);
      }
      return validated;
    } catch (err) {
      return this.handleFailure(adapter, err);
    }
  }

  private handleFailure(adapter: QuotaAdapter, err: unknown): QuotaSnapshot {
    const status = statusForError(err, this.fetchTimeoutMs);

    // Retain the last good snapshot as a normal cached result. Coding-plan
    // cards should degrade like a dashboard, not flash "stale" or an error
    // whenever one upstream request misses.
    const stale = this.cache.getStale(adapter.provider);
    if (stale) {
      return { ...stale, freshness: 'cached', status: { state: 'ok' } };
    }
    // No prior data — surface the structured error so the user can act on it.
    return {
      provider: adapter.provider,
      displayName: adapter.displayName,
      fetchedAt: new Date().toISOString(),
      freshness: 'stale',
      windows: [],
      status,
    };
  }
}

function timeoutForAdapter(adapter: QuotaAdapter, defaultTimeoutMs: number): number {
  return adapter.fetchTimeoutMs && adapter.fetchTimeoutMs > 0
    ? adapter.fetchTimeoutMs
    : defaultTimeoutMs;
}

function statusForError(err: unknown, timeoutMs: number): QuotaProviderStatus {
  if (err instanceof QuotaError) return err.status;
  if (err instanceof TimeoutError) {
    return { state: 'timed_out', message: `upstream did not respond within ${timeoutMs}ms` };
  }
  return { state: 'error', message: redact(err), category: 'unexpected' };
}

class TimeoutError extends Error {
  constructor(provider: string) {
    super(`quota fetch timed out: ${provider}`);
    this.name = 'TimeoutError';
  }
}

function withTimeout<T>(p: Promise<T>, ms: number, provider: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new TimeoutError(provider)), ms);
    p.then(
      (v) => { clearTimeout(timer); resolve(v); },
      (e) => { clearTimeout(timer); reject(e); },
    );
  });
}

async function safeIsConfigured(adapter: QuotaAdapter): Promise<boolean> {
  try {
    return await adapter.isConfigured();
  } catch {
    return false;
  }
}

/** Strip anything that looks like a token/key from an error before it surfaces. */
function redact(err: unknown): string {
  const msg = err instanceof Error ? err.message : String(err);
  return msg.replace(/(sk-[A-Za-z0-9_-]{6,})[A-Za-z0-9_-]*/g, '$1…')
    .replace(/(Bearer\s+)[A-Za-z0-9._-]+/gi, '$1…')
    .slice(0, 200);
}
