// Apple Push Notifications over HTTP/2, signed with a .p8 key (ES256 JWT).
// APNs refuses a new provider token more often than every 20 minutes, so the token
// is shared across isolates for 50 minutes. D1 stores only an encrypted copy.

import type { Environment } from "./types.ts";
import type { Push } from "./push.ts";

export interface ApnsEnv {
  DB: D1Database;
  APNS_KEY?: string;
  APNS_KEY_ID?: string;
  /** Your Apple team ID, and the app's bundle ID: vars in wrangler.local.jsonc, or secrets. */
  APNS_TEAM_ID?: string;
  APNS_TOPIC?: string;
}

/** Everything a push needs: the .p8 key, its ID, the team and the app. */
export const canPush = (env: ApnsEnv) => Boolean(env.APNS_KEY && env.APNS_KEY_ID && env.APNS_TEAM_ID && env.APNS_TOPIC);

export interface Sent {
  status: number;
  reason?: string;
  /** The token is dead (app deleted, notifications reset): forget the phone. */
  gone: boolean;
  /** With `gone`: when Apple last found it so (ms), if it says. A phone registered after that
   * has a token Apple hadn't yet looked at again. */
  goneSince?: number;
}

const HOSTS: Record<Environment, string> = {
  sandbox: "https://api.sandbox.push.apple.com",
  production: "https://api.push.apple.com",
};

async function collapseHeader(id: string): Promise<string> {
  const bytes = new TextEncoder().encode(id);
  if (bytes.length <= 64) return id;
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

/** One run's provider token, so a run of many pushes reads D1 for it once. */
export interface TokenMemo { token?: { jwt: string; sealed: string } }

/** The push key, its ID, the team or the topic can't make a provider token: the server's own
 * setup, not Apple or the network, so nothing that waits on it is given up on. */
export class PushSetupError extends Error {}

export async function send(env: ApnsEnv, token: string, environment: Environment, push: Push, now = Date.now(), memo?: TokenMemo): Promise<Sent> {
  const { jwt, sealed } = memo?.token ?? await providerToken(env, now).catch((error) => { throw new PushSetupError(String(error)); });
  if (memo) memo.token = { jwt, sealed };
  const response = await fetch(`${HOSTS[environment]}/3/device/${token}`, {
    method: "POST",
    redirect: "manual",
    // One stuck connection must not hold up every other phone's alerts.
    signal: AbortSignal.timeout(10_000),
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": String(env.APNS_TOPIC),
      "apns-push-type": push.type ?? "alert",
      "apns-priority": String(push.priority),
      "apns-collapse-id": await collapseHeader(push.collapseId),
      "apns-expiration": String(push.expiration),
      "content-type": "application/json",
    },
    body: JSON.stringify(push.payload),
  });
  if (response.ok) return { status: response.status, gone: false };
  const answer = (await response.json().catch(() => ({}))) as { reason?: string; timestamp?: unknown };
  const reason = typeof answer.reason === "string" ? answer.reason : undefined;
  if (reason === "ExpiredProviderToken" || reason === "InvalidProviderToken") {
    if (memo) memo.token = undefined;
    await env.DB.prepare("DELETE FROM meta WHERE key = 'apns_jwt' AND value = ?1").bind(sealed).run();
  }
  // 410 is Apple saying the token is no longer one to send to, whichever reason it gives
  // ("Unregistered", "ExpiredToken"): not one to tell again, or to keep a place for.
  const gone = response.status === 410;
  const goneSince = gone && typeof answer.timestamp === "number" && Number.isFinite(answer.timestamp) ? answer.timestamp : undefined;
  return { status: response.status, reason, gone, goneSince };
}

async function providerToken(env: ApnsEnv, now: number): Promise<{ jwt: string; sealed: string }> {
  if (!env.APNS_KEY || !env.APNS_KEY_ID || !env.APNS_TEAM_ID || !env.APNS_TOPIC) throw new Error("APNs key, key ID, team or topic not set");
  const privateKey = decodePEM(env.APNS_KEY);
  const material = await crypto.subtle.importKey("raw", privateKey, "HKDF", false, ["deriveKey"]);
  const encoder = new TextEncoder();
  const key = await crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: encoder.encode("Beeline APNs token cache v1"),
      info: encoder.encode(JSON.stringify([String(env.APNS_TEAM_ID), String(env.APNS_KEY_ID), String(env.APNS_TOPIC)])) },
    material, { name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"],
  );
  const cached = await env.DB.prepare("SELECT value, updated_at FROM meta WHERE key = 'apns_jwt'").first<{ value: string; updated_at: number }>();
  type Cached = { value: string; updated_at: number } | null;
  const open = async (entry: Cached) => {
    // A run that began before another sender published its token still uses that one.
    if (!entry?.value.startsWith("v1:") || entry.updated_at > now + 10 * 60_000 || now - entry.updated_at >= 50 * 60_000) return undefined;
    try {
      const bytes = fromBase64(entry.value.slice(3));
      const plaintext = await crypto.subtle.decrypt({ name: "AES-GCM", iv: bytes.subarray(0, 12),
        additionalData: encoder.encode(String(entry.updated_at)) }, key, bytes.subarray(12));
      return { jwt: new TextDecoder().decode(plaintext), sealed: entry.value };
    } catch {
      // A rotated signing key or an unreadable entry requires a new provider token.
      return undefined;
    }
  };
  const reused = await open(cached);
  if (reused) return reused;
  // An all-digit team ID or key ID written unquoted in wrangler's vars arrives as a number.
  const jwt = await sign(String(env.APNS_KEY), String(env.APNS_KEY_ID), String(env.APNS_TEAM_ID), now);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = await crypto.subtle.encrypt({ name: "AES-GCM", iv, additionalData: encoder.encode(String(now)) },
    key, encoder.encode(jwt));
  const sealed = "v1:" + btoa(String.fromCharCode(...iv, ...new Uint8Array(ciphertext)));
  // Only over the entry this was decided from: two senders finding it stale at once must end up
  // with one token between them, since APNs refuses provider tokens that change too often.
  const written = await env.DB.prepare("INSERT INTO meta (key, value, updated_at) VALUES ('apns_jwt', ?1, ?2) ON CONFLICT(key) DO UPDATE SET value = ?1, updated_at = ?2 WHERE meta.value = ?3")
    .bind(sealed, now, cached?.value ?? "").run();
  if (!written.meta?.changes) {
    const winner = await open(await env.DB.prepare("SELECT value, updated_at FROM meta WHERE key = 'apns_jwt'").first<{ value: string; updated_at: number }>());
    if (winner) return winner;
  }
  return { jwt, sealed };
}

function fromBase64(value: string) {
  return Uint8Array.from(atob(value), (character) => character.charCodeAt(0));
}

function decodePEM(key: string) {
  return fromBase64(key.replace(/-----[^-]+-----|\s/g, ""));
}

export async function sign(p8: string, keyId: string, teamId: string, now: number): Promise<string> {
  const der = decodePEM(p8);
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const encode = (value: object) => base64url(new TextEncoder().encode(JSON.stringify(value)));
  const unsigned = `${encode({ alg: "ES256", kid: keyId })}.${encode({ iss: teamId, iat: Math.floor(now / 1000) })}`;
  // WebCrypto gives ECDSA signatures as r||s, which is what JWS wants.
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(unsigned));
  return `${unsigned}.${base64url(new Uint8Array(signature))}`;
}

function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
