import { generateKeyPairSync } from "node:crypto";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { decodeJwt, decodeProtectedHeader } from "jose";
import { afterEach, describe, expect, it } from "vitest";
import { buildApp, type BuiltApp } from "../src/app.js";
import { ApnsProvider, type ApnsTransport } from "../src/push/apns.js";
import { loadConfig } from "../src/config.js";
import { AGENT, FakeLiveKit, FakePush, pairDevice, testConfig } from "./helpers.js";

const cleanup: Array<() => unknown> = [];
afterEach(async () => { for (const fn of cleanup.splice(0)) await fn(); });

function provider(transport: ApnsTransport) {
  const dir = mkdtempSync(join(tmpdir(), "apns-"));
  cleanup.push(() => rmSync(dir, { recursive: true, force: true }));
  const key = generateKeyPairSync("ec", { namedCurve: "P-256" }).privateKey;
  const keyFile = join(dir, "AuthKey.p8");
  writeFileSync(keyFile, key.export({ type: "pkcs8", format: "pem" }));
  return new ApnsProvider({ keyFile, keyId: "KEY", teamId: "TEAM", bundleId: "dev.agentring.ios" }, transport);
}

describe("Apple push", () => {
  it("uses HTTP/2 VoIP headers, sandbox and a signed provider token only for invitations", async () => {
    const sent: Array<{ origin: string; headers: Record<string, unknown>; body: string }> = [];
    const p = provider(async (origin, headers, body) => { sent.push({ origin, headers, body }); return { status: 200, body: "" }; });
    const target = { deviceId: "dev_1", token: "abcd", environment: "sandbox" as const };
    const opts = { ttlSeconds: 30, highPriority: true };
    await p.send(target, { event: JSON.stringify({ type: "call.invite", direction: "agent_to_user" }), sig: "signed" }, opts);
    expect(sent[0]!.origin).toBe("https://api.sandbox.push.apple.com");
    expect(sent[0]!.headers).toMatchObject({ ":method": "POST", ":path": "/3/device/abcd", "apns-topic": "dev.agentring.ios.voip", "apns-push-type": "voip", "apns-priority": "10", "apns-expiration": "0" });
    const jwt = String(sent[0]!.headers.authorization).slice(7);
    expect(decodeJwt(jwt).iss).toBe("TEAM");
    expect(decodeProtectedHeader(jwt)).toMatchObject({ alg: "ES256", kid: "KEY" });
    expect(JSON.parse(sent[0]!.body)).toMatchObject({ aps: {}, sig: "signed" });
    for (const type of ["msg.new", "call.end", "call.accept", "call.missed"]) {
      await p.send({ ...target, environment: "production" }, { event: JSON.stringify({ type, text: "hello" }) }, opts);
    }
    expect(sent[1]!.headers).toMatchObject({ "apns-push-type": "alert", "apns-topic": "dev.agentring.ios" });
    expect(JSON.parse(sent[1]!.body).aps).toMatchObject({ category: "MESSAGE", alert: { body: "hello" } });
    for (const item of sent.slice(2)) {
      expect(item.origin).toBe("https://api.push.apple.com");
      expect(item.headers).toMatchObject({ "apns-push-type": "background", "apns-priority": "5", "apns-topic": "dev.agentring.ios" });
    }
  });

  it("clears stale registrations but keeps tokens on provider authentication or temporary errors", async () => {
    for (const [status, reason, stale] of [[410, "Unregistered", true], [400, "BadDeviceToken", true], [403, "InvalidProviderToken", false], [429, "TooManyRequests", false]] as const) {
      const p = provider(async () => ({ status, body: JSON.stringify({ reason }) }));
      expect(await p.send({ deviceId: "dev", token: "abcd" }, { event: '{"type":"msg.new"}' }, { ttlSeconds: 30, highPriority: true }))
        .toMatchObject({ ok: false, unregistered: stale });
    }
  });

  it("rejects partial configuration", () => {
    const saved = { ...process.env };
    try {
      process.env.AGENTRING_PUBLIC_URL = "https://relay.test";
      for (const key of ["APNS_KEY_FILE", "APNS_KEY_ID", "APNS_TEAM_ID", "APNS_BUNDLE_ID"]) delete process.env[key];
      process.env.APNS_KEY_ID = "KEY";
      expect(() => loadConfig()).toThrow(/Set all of APNS/);
    } finally { process.env = saved; }
  });
});

async function iosDevice(b: BuiltApp) {
  const token = (await b.app.inject({ method: "POST", url: "/v1/pairing-tokens", headers: AGENT })).json().pairing_token;
  const response = await b.app.inject({ method: "POST", url: "/v1/pair", payload: { pairing_token: token, device_name: "iPhone", platform: "ios" } });
  expect(response.statusCode).toBe(201);
  expect(response.json().push_config).toBeNull();
  return { ...response.json(), headers: { authorization: `Bearer ${response.json().device_jwt}` } };
}

describe("iOS registration and routing", () => {
  async function setup() {
    const android = new FakePush();
    const apple = new FakePush();
    const b = await buildApp(testConfig({ fcm: undefined }), { logger: false, pushProvider: android, applePushProvider: apple, livekit: new FakeLiveKit() });
    cleanup.push(() => b.app.close());
    return { ...b, android, apple };
  }

  it("keeps Android pairing working and routes messages and invitations to different Apple tokens", async () => {
    const b = await setup();
    await pairDevice(b);
    const iphone = await iosDevice(b);
    const registration = await b.app.inject({ method: "POST", url: "/v1/device/apns", headers: iphone.headers, payload: { environment: "sandbox", apns_token: "aa".repeat(32), voip_token: "bb".repeat(32) } });
    expect(registration.statusCode).toBe(204);
    const devices = (await b.app.inject({ url: "/v1/devices", headers: AGENT })).json().devices;
    expect(devices.find((d: { platform: string }) => d.platform === "ios")).toMatchObject({ has_push_token: true, name: "iPhone" });
    await b.app.inject({ method: "POST", url: "/v1/messages", headers: AGENT, payload: { text: "hello" } });
    expect(b.apple.sent[0]!.target).toMatchObject({ token: "aa".repeat(32), environment: "sandbox" });
    expect(b.android.sent[0]!.target.token).toBe("fcm-tok-1");
    await b.app.inject({ method: "POST", url: "/v1/calls", headers: AGENT, payload: { reason: "Need a decision", device_ids: [iphone.device_id] } });
    expect(b.apple.sent[1]!.target.token).toBe("bb".repeat(32));
    expect(b.android.sent).toHaveLength(1);
  });

  it("requires device auth, validates tokens, rejects Android, and clears tokens on revoke", async () => {
    const b = await setup();
    const iphone = await iosDevice(b);
    const android = await pairDevice(b);
    const payload = { environment: "production", voip_token: "cc".repeat(32) };
    expect((await b.app.inject({ method: "POST", url: "/v1/device/apns", payload })).statusCode).toBe(401);
    expect((await b.app.inject({ method: "POST", url: "/v1/device/apns", headers: AGENT, payload })).statusCode).toBe(403);
    expect((await b.app.inject({ method: "POST", url: "/v1/device/apns", headers: android.headers, payload })).statusCode).toBe(400);
    expect((await b.app.inject({ method: "POST", url: "/v1/device/apns", headers: iphone.headers, payload: { ...payload, voip_token: "../bad" } })).statusCode).toBe(400);
    await b.app.inject({ method: "POST", url: "/v1/device/apns", headers: iphone.headers, payload });
    await b.app.inject({ method: "DELETE", url: `/v1/devices/${iphone.device_id}`, headers: AGENT });
    expect(b.ctx.db.prepare("SELECT voip_token, apns_token FROM devices WHERE device_id = ?").get(iphone.device_id)).toMatchObject({ voip_token: null, apns_token: null });
    expect((await b.app.inject({ method: "POST", url: "/v1/device/apns", headers: iphone.headers, payload })).statusCode).toBe(401);
  });

  it("preserves omitted tokens, clears explicit nulls and drops the other token when signing environment changes", async () => {
    const b = await setup();
    const iphone = await iosDevice(b);
    const update = (payload: unknown) => b.app.inject({ method: "POST", url: "/v1/device/apns", headers: iphone.headers, payload });
    await update({ environment: "sandbox", apns_token: "aa".repeat(32), voip_token: "bb".repeat(32) });
    await update({ environment: "sandbox", voip_token: null });
    let row = b.ctx.db.prepare("SELECT * FROM devices WHERE device_id = ?").get(iphone.device_id)!;
    expect(row).toMatchObject({ apns_token: "aa".repeat(32), voip_token: null });
    await update({ environment: "production", voip_token: "cc".repeat(32) });
    row = b.ctx.db.prepare("SELECT * FROM devices WHERE device_id = ?").get(iphone.device_id)!;
    expect(row).toMatchObject({ apns_token: null, voip_token: "cc".repeat(32), apns_environment: "production" });
  });

  it("clears only the failed token, preserving message notifications after a stale VoIP token", async () => {
    const b = await setup();
    const iphone = await iosDevice(b);
    await b.app.inject({ method: "POST", url: "/v1/device/apns", headers: iphone.headers, payload: { environment: "sandbox", apns_token: "aa".repeat(32), voip_token: "bb".repeat(32) } });
    b.apple.next = { ok: false, unregistered: true, error: "410 Unregistered" };
    await b.app.inject({ method: "POST", url: "/v1/calls", headers: AGENT, payload: { reason: "test" } });
    expect(b.ctx.db.prepare("SELECT voip_token, apns_token FROM devices WHERE device_id = ?").get(iphone.device_id))
      .toMatchObject({ voip_token: null, apns_token: "aa".repeat(32) });
  });
});
