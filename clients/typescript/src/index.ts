/**
 * @thedoxaway/mcp-client
 *
 * Tiny TypeScript client for Doxa MCP. Free hosted, BYOL for unlimited.
 * Zero runtime dependencies. Node 18+ (native fetch).
 *
 * Usage:
 *
 *   import { DoxaClient } from '@thedoxaway/mcp-client';
 *
 *   const doxa = new DoxaClient();  // free anon, 50 calls/day per IP
 *   const reply = await doxa.encourage('I am exhausted and tempted to give up.');
 *   console.log(reply.text);
 *   console.log(reply.quota);  // { tier: 'free', used: 1, limit: 50, window_seconds: 86400 }
 *
 *   // BYOL (unlimited):
 *   const doxa = new DoxaClient({ anthropicKey: process.env.ANTHROPIC_API_KEY });
 *   const reply = await doxa.encourage('...');
 *
 *   // Scripture lookup:
 *   const verse = await doxa.scripture('John 14:6');
 *   console.log(verse.text, verse.link);
 *
 *   // The 9-movement Doxa Way framework:
 *   const all = await doxa.wayMovement();           // all 9
 *   const one = await doxa.wayMovement('endure');   // one
 */

const DEFAULT_ENDPOINT = 'https://doxa.app/mcp/v1';
const DEFAULT_USER_AGENT = '@thedoxaway/mcp-client';

/** Configuration for a DoxaClient instance. */
export interface DoxaClientOptions {
  /** MCP endpoint URL. Defaults to https://doxa.app/mcp/v1. Override only for testing. */
  endpoint?: string;
  /**
   * Anthropic API key. Pass to opt into BYOL mode (unlimited calls, 1500-token cap,
   * you pay Anthropic). Without it, falls back to free anon (10 calls/day per
   * individual caller, 250-token cap, we pay).
   */
  anthropicKey?: string;
  /**
   * Identifies the individual end-user behind a request so the free tier counts
   * fairly per-person instead of per-IP. Format: `<surface>:<id>`, lowercase
   * surface (e.g. `discord`, `slack`, `tg`, `web`), alphanumeric id. Bots
   * serving many users should use {@link DoxaClient.withCaller} to set this
   * per-call rather than at client construction.
   */
  callerId?: string;
  /** Override the user-agent header sent on requests. */
  userAgent?: string;
  /** Custom fetch implementation. Defaults to global fetch (Node 18+). */
  fetch?: typeof fetch;
}

/** The 9 movements of The Doxa Way. */
export type DoxaWayMovementId =
  | 'hear'
  | 'discern'
  | 'test'
  | 'record'
  | 'remember'
  | 'engage'
  | 'trust'
  | 'fight'
  | 'endure';

/** Quota metadata returned with every successful response. */
export interface DoxaQuota {
  /** 'free' = anon free tier; 'byol' = your own Anthropic key (unlimited). */
  tier: 'free' | 'byol';
  /** Calls used in the current 24h rolling window. 0 for BYOL. */
  used: number;
  /** Daily limit. -1 means unlimited (BYOL). */
  limit: number;
  /** Window length in seconds. 86400 (24h rolling) for free tier. */
  window_seconds: number;
}

/** A Scripture reference extracted from the response, with a Doxa deep-link. */
export interface DoxaScriptureRef {
  /** Standard reference, e.g. "John 14:6". */
  ref: string;
  /** Deep link into the Doxa Bible reader. */
  link: string;
}

/** Result of doxa.encourage(). */
export interface DoxaEncourageResult {
  /** The encouragement text in Doxa's voice. Always ends with the attribution footer. */
  text: string;
  /** Scripture references found in the response. */
  scriptures: DoxaScriptureRef[];
  /** Which movement of The Doxa Way this response embodies. */
  movement: string;
  /** The brand north star. Constant string. */
  doxaWay: string;
  /** Current quota status (use to render rate-limit UIs). */
  quota: DoxaQuota;
}

/** Result of doxa.scripture(). */
export interface DoxaScriptureResult {
  /** The reference you asked for, e.g. "John 14:6". */
  reference: string;
  /** The verse text (Berean Standard Bible). */
  text: string;
  /** Translation abbreviation. */
  translation: string;
  /** Deep link into the Doxa Bible reader. */
  link: string;
  /** Related verses (currently always empty; populated in a future version). */
  related: DoxaScriptureRef[];
  /** Current quota status. */
  quota: DoxaQuota;
}

/** A single movement of The Doxa Way. */
export interface DoxaMovement {
  id: DoxaWayMovementId;
  name: string;
  short: string;
  prompt_for: string;
}

/** Result of doxa.wayMovement() (single movement). */
export interface DoxaWayMovementResult {
  movement: DoxaMovement;
  northStar: string;
  fiveVerbDailyPractice: string[];
  doxaWayCanonicalUrl: string;
  quota: DoxaQuota;
}

/** Result of doxa.wayMovement() (all 9 movements). */
export interface DoxaWayMovementsResult {
  movements: DoxaMovement[];
  northStar: string;
  fiveVerbDailyPractice: string[];
  doxaWayCanonicalUrl: string;
  quota: DoxaQuota;
}

/** Generic Doxa MCP error. */
export class DoxaError extends Error {
  readonly code: number;
  constructor(message: string, code: number) {
    super(message);
    this.name = 'DoxaError';
    this.code = code;
  }
}

/** Thrown when the free-tier rate limit is exceeded. Includes upgrade URL. */
export class DoxaRateLimitError extends DoxaError {
  readonly byolUrl: string;
  readonly quota: DoxaQuota;
  constructor(message: string, byolUrl: string, quota: DoxaQuota) {
    super(message, 429);
    this.name = 'DoxaRateLimitError';
    this.byolUrl = byolUrl;
    this.quota = quota;
  }
}

interface JsonRpcResponse {
  jsonrpc: '2.0';
  id: number;
  result?: {
    content?: Array<{ type: string; text: string }>;
    structuredContent?: Record<string, unknown>;
    isError?: boolean;
  };
  error?: { code: number; message: string };
}

interface ToolCallRaw {
  text?: string;
  reference?: string;
  translation?: string;
  link?: string;
  related?: DoxaScriptureRef[];
  scriptures?: DoxaScriptureRef[];
  movement?: string | DoxaMovement;
  movements?: DoxaMovement[];
  north_star?: string;
  _doxa_way?: string;
  five_verb_daily_practice?: string[];
  _doxa_way_canonical_url?: string;
  _quota?: DoxaQuota;
  error?: string;
  reason?: string;
  message?: string;
  _byol_url?: string;
}

/**
 * Doxa MCP client. One instance can make any number of calls.
 *
 * Defaults to the free anon tier (50 calls/day per source IP, 250-token output cap).
 * Pass `anthropicKey` to switch to BYOL: unlimited calls, 1500-token cap, your
 * Anthropic billing.
 */
export class DoxaClient {
  private readonly endpoint: string;
  private readonly anthropicKey: string | undefined;
  private readonly callerId: string | undefined;
  private readonly userAgent: string;
  private readonly fetchImpl: typeof fetch;
  private callId: number = 0;

  constructor(options: DoxaClientOptions = {}) {
    this.endpoint = options.endpoint ?? DEFAULT_ENDPOINT;
    this.anthropicKey = options.anthropicKey;
    this.callerId = options.callerId;
    this.userAgent = options.userAgent ?? DEFAULT_USER_AGENT;
    this.fetchImpl = options.fetch ?? globalThis.fetch;
  }

  /**
   * Returns a cloned client that identifies the given individual end-user on
   * every call. Use this in bots that serve many users behind one shared
   * Anthropic key so each user gets their own daily quota.
   *
   * @example
   * ```ts
   * const doxa = new DoxaClient();
   * // In a Discord interaction handler:
   * const reply = await doxa.withCaller(`discord:${interaction.user.id}`).encourage(situation);
   * ```
   */
  withCaller(callerId: string): DoxaClient {
    return new DoxaClient({
      endpoint: this.endpoint,
      anthropicKey: this.anthropicKey,
      callerId,
      userAgent: this.userAgent,
      fetch: this.fetchImpl,
    });
  }

  /**
   * Generate Doxa-voice encouragement for a user's situation.
   *
   * @param situation Describe what the user is facing in 1-3 sentences. Max 2000 chars.
   * @param movement Optional. Hint which movement of The Doxa Way fits. If absent, the server infers.
   */
  async encourage(situation: string, movement?: DoxaWayMovementId): Promise<DoxaEncourageResult> {
    const payload = await this.callTool('doxa_encourage', { situation, ...(movement ? { movement } : {}) });
    return {
      text: payload.text ?? '',
      scriptures: payload.scriptures ?? [],
      movement: typeof payload.movement === 'string' ? payload.movement : payload.movement?.name ?? '',
      doxaWay: payload._doxa_way ?? '',
      quota: this.requireQuota(payload),
    };
  }

  /**
   * Look up a Bible verse with a Doxa deep-link.
   *
   * @param reference Standard human-form reference (e.g. "John 14:6", "Psalm 23:1-3"). Max 100 chars.
   */
  async scripture(reference: string): Promise<DoxaScriptureResult> {
    const payload = await this.callTool('doxa_scripture', { reference });
    return {
      reference: payload.reference ?? '',
      text: payload.text ?? '',
      translation: payload.translation ?? 'BSB',
      link: payload.link ?? '',
      related: payload.related ?? [],
      quota: this.requireQuota(payload),
    };
  }

  /**
   * Get The Doxa Way framework. All 9 movements, or one by id.
   *
   * Server-side only static data — does not consume LLM budget.
   */
  async wayMovement(): Promise<DoxaWayMovementsResult>;
  async wayMovement(movement: DoxaWayMovementId): Promise<DoxaWayMovementResult>;
  async wayMovement(movement?: DoxaWayMovementId): Promise<DoxaWayMovementResult | DoxaWayMovementsResult> {
    const payload = await this.callTool('doxa_way_movement', movement ? { movement } : {});
    const shared = {
      northStar: payload.north_star ?? '',
      fiveVerbDailyPractice: payload.five_verb_daily_practice ?? [],
      doxaWayCanonicalUrl: payload._doxa_way_canonical_url ?? '',
      quota: this.requireQuota(payload),
    };
    if (movement) {
      const m = payload.movement;
      if (!m || typeof m === 'string') {
        throw new DoxaError(`expected movement object, got ${JSON.stringify(m)}`, -32000);
      }
      return { ...shared, movement: m };
    }
    return { ...shared, movements: payload.movements ?? [] };
  }

  private async callTool(name: string, args: Record<string, unknown>): Promise<ToolCallRaw> {
    this.callId += 1;
    const headers: Record<string, string> = {
      'content-type': 'application/json',
      'user-agent': this.userAgent,
    };
    if (this.anthropicKey) headers['x-anthropic-key'] = this.anthropicKey;
    if (this.callerId) headers['x-doxa-caller-id'] = this.callerId;

    const res = await this.fetchImpl(this.endpoint, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        jsonrpc: '2.0',
        id: this.callId,
        method: 'tools/call',
        params: { name, arguments: args },
      }),
    });

    if (!res.ok) {
      const body = await res.text();
      throw new DoxaError(`HTTP ${res.status}: ${body.slice(0, 200)}`, res.status);
    }

    const json = (await res.json()) as JsonRpcResponse;
    if (json.error) {
      throw new DoxaError(json.error.message, json.error.code);
    }

    const inner = json.result?.structuredContent ?? this.parseInnerFromContent(json.result?.content);
    if (!inner) {
      throw new DoxaError('Empty MCP response', -32000);
    }

    const payload = inner as ToolCallRaw;

    // Rate-limit error comes back wrapped as a successful JSON-RPC result with `isError: true`.
    if (json.result?.isError && payload.error === 'rate_limit') {
      throw new DoxaRateLimitError(
        payload.message ?? 'Doxa MCP free-tier rate limit exceeded.',
        payload._byol_url ?? 'https://doxa.app/mcp#byol',
        payload._quota ?? { tier: 'free', used: 0, limit: 50, window_seconds: 86400 },
      );
    }
    if (json.result?.isError) {
      throw new DoxaError(payload.message ?? payload.error ?? 'Tool error', -32000);
    }

    return payload;
  }

  private parseInnerFromContent(content?: Array<{ type: string; text: string }>): Record<string, unknown> | undefined {
    const first = content?.[0];
    if (!first || first.type !== 'text') return undefined;
    try {
      return JSON.parse(first.text) as Record<string, unknown>;
    } catch {
      return undefined;
    }
  }

  private requireQuota(payload: ToolCallRaw): DoxaQuota {
    if (payload._quota) return payload._quota;
    // Older server versions or unexpected payloads: return a sentinel so caller
    // code doesn't crash. Devs should treat missing quota as "unknown headroom".
    return { tier: 'free', used: 0, limit: 0, window_seconds: 86400 };
  }
}

export default DoxaClient;
