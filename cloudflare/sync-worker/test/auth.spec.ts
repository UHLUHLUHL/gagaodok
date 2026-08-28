import { applyD1Migrations, env } from "cloudflare:test";
import type { D1Migration } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import {
  assertAuthenticatedDeviceId,
  assertAuthenticatedWriteSpace,
  authenticateDevice,
  hashDeviceToken,
  parseDeviceAuthorization,
} from "../src/auth/deviceToken";

declare global {
  namespace Cloudflare {
    interface Env {
      DB: D1Database;
      ATTACHMENTS: R2Bucket;
      CURSOR_MAC_KEY: string;
      TEST_MIGRATIONS: D1Migration[];
    }
  }
}

const ACCOUNT_A = "A0000000-0000-4000-8000-00000000000A";
const ACCOUNT_B = "A0000000-0000-4000-8000-00000000000B";
const DEVICE_1 = "B0000000-0000-4000-8000-000000000001";
const DEVICE_2 = "B0000000-0000-4000-8000-000000000002";
const TIMESTAMP = "2026-08-28T00:00:00Z";
const REVOKED_AT = "2026-08-28T12:00:00Z";

const db = env.DB;

/**
 * A synthetic 32-byte token payload. The bytes are a fixed pattern, never
 * CSPRNG output and never a real token; only the shape matters here. Nothing
 * in this file prints a whole token or a whole hash.
 */
function syntheticTokenBytes(seed: number): Uint8Array {
  const bytes = new Uint8Array(32);
  for (let index = 0; index < bytes.length; index += 1) {
    bytes[index] = (seed + index) & 0xff;
  }
  return bytes;
}

function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

function wireToken(bytes: Uint8Array): string {
  return `gdt1_${base64Url(bytes)}`;
}

function requestWith(headerValue: string | null): Request {
  const headers = new Headers();
  if (headerValue !== null) {
    headers.set("Authorization", headerValue);
  }
  return new Request("https://example.test/v1/anything", { headers });
}

async function expectApiError(run: () => Promise<unknown>, code: string): Promise<void> {
  let caught: unknown;
  try {
    await run();
  } catch (error) {
    caught = error;
  }
  expect(caught).toBeDefined();
  expect((caught as { code?: string }).code).toBe(code);
  // The error must carry the bare code and no identifier of any kind.
  const serialised = JSON.stringify({
    code: (caught as { code?: string }).code,
    detail: (caught as { detail?: unknown }).detail,
    message: (caught as Error).message,
  });
  for (const secret of [ACCOUNT_A, DEVICE_1, "gdt1_", "PHONE_SPACE", "MAC_SPACE"]) {
    expect(serialised).not.toContain(secret);
  }
}

async function insertAccount(accountId: string): Promise<void> {
  await db
    .prepare("INSERT INTO account (account_id, created_at) VALUES (?, ?)")
    .bind(accountId, TIMESTAMP)
    .run();
}

async function insertDevice(
  accountId: string,
  deviceId: string,
  options: { tokenHash?: string | null; spaceId?: string; revokedAt?: string | null } = {},
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO device
         (account_id, device_id, space_id, platform, display_name_enc,
          linked_at, revoked_at, key_generation, token_hash)
       VALUES (?, ?, ?, 'android_phone', NULL, ?, ?, 1, ?)`,
    )
    .bind(
      accountId,
      deviceId,
      options.spaceId ?? "PHONE_SPACE",
      TIMESTAMP,
      options.revokedAt ?? null,
      options.tokenHash ?? null,
    )
    .run();
}

beforeAll(async () => {
  await applyD1Migrations(db, env.TEST_MIGRATIONS);
});

beforeEach(async () => {
  await db.prepare("DELETE FROM device").run();
  await db.prepare("DELETE FROM account").run();
});

describe("parseDeviceAuthorization", () => {
  const bytes = syntheticTokenBytes(1);
  const token = wireToken(bytes);

  it("returns the decoded 32 bytes of a well-formed header", () => {
    const parsed = parseDeviceAuthorization(requestWith(`Device ${token}`));
    expect(parsed.length).toBe(32);
    expect([...parsed]).toEqual([...bytes]);
  });

  it("refuses a missing header", async () => {
    await expectApiError(async () => parseDeviceAuthorization(requestWith(null)), "AUTH_INVALID");
  });

  it("refuses a scheme that is not exactly `Device`", async () => {
    for (const scheme of ["device", "DEVICE", "Bearer", "Devicee"]) {
      await expectApiError(
        async () => parseDeviceAuthorization(requestWith(`${scheme} ${token}`)),
        "AUTH_INVALID",
      );
    }
  });

  it("normalises surrounding whitespace before the parser sees it", () => {
    // `Headers` trims a value's leading and trailing whitespace, so those two
    // spellings never reach this code and are accepted as the same header.
    // Interior whitespace is not trimmed and is refused below.
    expect(parseDeviceAuthorization(requestWith(` Device ${token} `)).length).toBe(32);
  });

  it("refuses interior whitespace, a comma-joined credential and a bare token", async () => {
    for (const value of [
      `Device  ${token}`,
      `Device ${token}, Device ${token}`,
      token,
      "Device",
      "Device ",
    ]) {
      await expectApiError(
        async () => parseDeviceAuthorization(requestWith(value)),
        "AUTH_INVALID",
      );
    }
  });

  it("refuses a wrong prefix or version", async () => {
    const payload = base64Url(bytes);
    for (const bad of [payload, `gdt_${payload}`, `gdt2_${payload}`, `GDT1_${payload}`]) {
      await expectApiError(
        async () => parseDeviceAuthorization(requestWith(`Device ${bad}`)),
        "AUTH_INVALID",
      );
    }
  });

  it("refuses padding, a wrong payload length and a non-Base64URL character", async () => {
    const payload = base64Url(bytes);
    expect(payload.length).toBe(43);
    for (const bad of [
      `${payload}=`,
      payload.slice(0, 42),
      `${payload}A`,
      `${payload.slice(0, 42)}+`,
      `${payload.slice(0, 42)}/`,
      `${payload.slice(0, 42)} `,
    ]) {
      await expectApiError(
        async () => parseDeviceAuthorization(requestWith(`Device gdt1_${bad}`)),
        "AUTH_INVALID",
      );
    }
  });

  it("refuses a 43-character payload whose last quantum carries stray bits", async () => {
    // 43 Base64URL characters encode 32 bytes plus 2 leftover bits. A spelling
    // that sets those bits decodes to the same 32 bytes, so two different
    // strings would authenticate one device unless it is refused.
    const payload = base64Url(bytes);
    const last = payload[42] as string;
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    const index = alphabet.indexOf(last);
    const stray = alphabet[(index + 1) % alphabet.length] as string;
    if (stray !== last) {
      await expectApiError(
        async () =>
          parseDeviceAuthorization(requestWith(`Device gdt1_${payload.slice(0, 42)}${stray}`)),
        "AUTH_INVALID",
      );
    }
  });
});

describe("hashDeviceToken", () => {
  it("returns a deterministic lowercase 64-character hex digest", async () => {
    const first = await hashDeviceToken(syntheticTokenBytes(2));
    const second = await hashDeviceToken(syntheticTokenBytes(2));
    expect(first).toBe(second);
    expect(first).toMatch(/^[0-9a-f]{64}$/);
  });

  it("gives different tokens different digests", async () => {
    const a = await hashDeviceToken(syntheticTokenBytes(3));
    const b = await hashDeviceToken(syntheticTokenBytes(4));
    expect(a).not.toBe(b);
  });
});

describe("authenticateDevice", () => {
  const bytes = syntheticTokenBytes(5);
  const token = wireToken(bytes);

  it("resolves an active device to its AuthContext", async () => {
    const hash = await hashDeviceToken(bytes);
    await insertAccount(ACCOUNT_A);
    await insertDevice(ACCOUNT_A, DEVICE_1, { tokenHash: hash, spaceId: "PHONE_SPACE" });

    const auth = await authenticateDevice(requestWith(`Device ${token}`), db);
    expect(auth).toEqual({
      account_id: ACCOUNT_A,
      device_id: DEVICE_1,
      registered_space_id: "PHONE_SPACE",
      key_generation: 1,
      revoked_at: null,
    });
  });

  it("refuses a token no device holds", async () => {
    await insertAccount(ACCOUNT_A);
    await insertDevice(ACCOUNT_A, DEVICE_1, { tokenHash: await hashDeviceToken(syntheticTokenBytes(6)) });
    await expectApiError(
      () => authenticateDevice(requestWith(`Device ${token}`), db),
      "AUTH_INVALID",
    );
  });

  it("cannot authenticate a device whose token_hash is null", async () => {
    await insertAccount(ACCOUNT_A);
    await insertDevice(ACCOUNT_A, DEVICE_1, { tokenHash: null });
    await expectApiError(
      () => authenticateDevice(requestWith(`Device ${token}`), db),
      "AUTH_INVALID",
    );
  });

  it("refuses a revoked device with DEVICE_REVOKED, not AUTH_INVALID", async () => {
    const hash = await hashDeviceToken(bytes);
    await insertAccount(ACCOUNT_A);
    await insertDevice(ACCOUNT_A, DEVICE_1, { tokenHash: hash, revokedAt: REVOKED_AT });
    await expectApiError(
      () => authenticateDevice(requestWith(`Device ${token}`), db),
      "DEVICE_REVOKED",
    );
  });

  it("takes the account from the hash alone, never from a same-named device elsewhere", async () => {
    // The same device UUID exists under two accounts; only the row the hash
    // points at may be used, and no request field names an account at all.
    const hash = await hashDeviceToken(bytes);
    await insertAccount(ACCOUNT_A);
    await insertAccount(ACCOUNT_B);
    await insertDevice(ACCOUNT_A, DEVICE_1, { tokenHash: null });
    await insertDevice(ACCOUNT_B, DEVICE_1, { tokenHash: hash, spaceId: "MAC_SPACE" });

    const auth = await authenticateDevice(requestWith(`Device ${token}`), db);
    expect(auth.account_id).toBe(ACCOUNT_B);
    expect(auth.registered_space_id).toBe("MAC_SPACE");
  });

  it("refuses a malformed header before touching the database", async () => {
    await expectApiError(() => authenticateDevice(requestWith("Bearer x"), db), "AUTH_INVALID");
  });
});

describe("assertAuthenticatedDeviceId", () => {
  const auth = {
    account_id: ACCOUNT_A,
    device_id: DEVICE_1,
    registered_space_id: "PHONE_SPACE" as const,
    key_generation: 1,
    revoked_at: null,
  };

  it("accepts the authenticated device id", () => {
    expect(() => assertAuthenticatedDeviceId(auth, DEVICE_1)).not.toThrow();
  });

  it("refuses any other device id", async () => {
    await expectApiError(async () => assertAuthenticatedDeviceId(auth, DEVICE_2), "AUTH_INVALID");
  });
});

describe("assertAuthenticatedWriteSpace", () => {
  // API draft §3 and the bdccd5c contract: a v1 device writes canonical rows
  // for the space it is registered in and no other. A valid token for the
  // same account is not authority over another space's rows.
  function contextFor(spaceId: string) {
    return {
      account_id: ACCOUNT_A,
      device_id: DEVICE_1,
      registered_space_id: spaceId as never,
      key_generation: 1,
      revoked_at: null,
    };
  }

  it("allows a device to write its own space", () => {
    expect(() => assertAuthenticatedWriteSpace(contextFor("PHONE_SPACE"), "PHONE_SPACE")).not.toThrow();
  });

  it.each(["MAC_SPACE", "TABLET_SPACE"] as const)(
    "refuses a PHONE_SPACE device writing %s",
    (target) => {
      expect(() => assertAuthenticatedWriteSpace(contextFor("PHONE_SPACE"), target)).toThrowError(
        "AUTH_INVALID",
      );
    },
  );

  it.each(["PHONE_SPACE", "TABLET_SPACE"] as const)(
    "refuses a MAC_SPACE device writing %s",
    (target) => {
      expect(() => assertAuthenticatedWriteSpace(contextFor("MAC_SPACE"), target)).toThrowError(
        "AUTH_INVALID",
      );
    },
  );

  it("names neither space, nor the account, nor the device in the error", async () => {
    await expectApiError(
      async () => assertAuthenticatedWriteSpace(contextFor("PHONE_SPACE"), "MAC_SPACE"),
      "AUTH_INVALID",
    );
  });
});
