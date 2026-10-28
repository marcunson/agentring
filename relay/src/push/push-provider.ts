/**
 * Transport-agnostic push interface, implemented by FCM (Android) and APNs (iOS).
 */
export interface PushTarget {
  deviceId: string;
  token: string;
  environment?: "sandbox" | "production";
}

/** Signed string map delivered as FCM data or APNs custom fields. See `PushData`. */
export type PushPayload = Record<string, string>;

export interface PushOptions {
  ttlSeconds: number;
  highPriority: boolean;
  collapseKey?: string;
}

export type PushResult = { ok: true } | { ok: false; unregistered: boolean; error: string };

export interface PushProvider {
  readonly name: string;
  send(target: PushTarget, payload: PushPayload, opts: PushOptions): Promise<PushResult>;
  /** Optional warm-up (e.g. fetch credentials) so the first real push is fast. */
  prepare?(): Promise<void>;
}
