import { readFileSync } from "node:fs";
import { connect, type OutgoingHttpHeaders } from "node:http2";
import { SignJWT, importPKCS8 } from "jose";
import type { ApnsConfig } from "../config.js";
import type { PushOptions, PushPayload, PushProvider, PushResult, PushTarget } from "./push-provider.js";

export type ApnsTransport = (origin: string, headers: OutgoingHttpHeaders, body: string) => Promise<{ status: number; body: string }>;

/** APNs requires HTTP/2; Node's fetch currently only supports HTTP/1.1. */
const post: ApnsTransport = (origin, headers, body) => new Promise((resolve, reject) => {
  const session = connect(origin);
  const timer = setTimeout(() => { session.destroy(); reject(new Error("APNs request timed out")); }, 10_000);
  session.on("error", (error) => { clearTimeout(timer); session.destroy(); reject(error); });
  const request = session.request(headers);
  let status = 0;
  let response = "";
  request.setEncoding("utf8");
  request.on("response", (headers) => { status = Number(headers[":status"]); });
  request.on("data", (chunk: string) => { response += chunk; });
  request.on("error", (error) => { clearTimeout(timer); session.destroy(); reject(error); });
  request.on("end", () => { clearTimeout(timer); session.close(); resolve({ status, body: response }); });
  request.end(body);
});

/** Apple token authentication uses the existing jose dependency; no APNs SDK needed. */
export class ApnsProvider implements PushProvider {
  readonly name = "apns";
  private readonly key: ReturnType<typeof importPKCS8>;
  private cached?: { value: string; expires: number };

  constructor(private readonly config: ApnsConfig, private readonly transport: ApnsTransport = post) {
    this.key = importPKCS8(readFileSync(config.keyFile, "utf8"), "ES256");
  }

  private async token(): Promise<string> {
    if (this.cached && this.cached.expires > Date.now()) return this.cached.value;
    const value = await new SignJWT({}).setProtectedHeader({ alg: "ES256", kid: this.config.keyId })
      .setIssuer(this.config.teamId).setIssuedAt().sign(await this.key);
    this.cached = { value, expires: Date.now() + 50 * 60_000 };
    return value;
  }

  async send(target: PushTarget, payload: PushPayload, opts: PushOptions): Promise<PushResult> {
    try {
      const event = JSON.parse(payload.event!) as { type: string; direction?: string; agent_name?: string; text?: string; msg_id?: string };
      const voip = event.type === "call.invite" && event.direction === "agent_to_user";
      const alert = event.type === "msg.new";
      // PushKit is exclusively for new calls: cancellation/acceptance use regular APNs.
      const aps = voip ? {} : alert ? {
        alert: { title: "agentring", body: event.text ? Array.from(event.text).slice(0, 120).join("") : "New message" },
        sound: "default", category: "MESSAGE", "mutable-content": 0,
      } : { "content-available": 1 };
      const body = JSON.stringify({ aps, ...payload });
      if (Buffer.byteLength(body) > (voip ? 5120 : 4096)) {
        return { ok: false, unregistered: false, error: "APNs payload too large" };
      }
      const headers: OutgoingHttpHeaders = {
        ":method": "POST", ":path": `/3/device/${target.token}`,
        authorization: `bearer ${await this.token()}`,
        "apns-topic": this.config.bundleId + (voip ? ".voip" : ""),
        "apns-push-type": voip ? "voip" : alert ? "alert" : "background",
        "apns-priority": voip || alert ? "10" : "5",
        // Never queue call invitations for an offline phone.
        "apns-expiration": voip ? "0" : String(Math.floor(Date.now() / 1000) + opts.ttlSeconds),
      };
      const origin = target.environment === "sandbox" ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com";
      const result = await this.transport(origin, headers, body);
      if (result.status === 200) return { ok: true };
      if (result.body.includes("ExpiredProviderToken")) this.cached = undefined;
      return { ok: false, unregistered: result.status === 410 || result.body.includes('"BadDeviceToken"'), error: `${result.status} ${result.body.slice(0, 300)}` };
    } catch (error) {
      return { ok: false, unregistered: false, error: String(error) };
    }
  }
}
