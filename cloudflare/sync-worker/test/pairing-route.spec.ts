import { applyD1Migrations, env } from "cloudflare:test";
import { exports } from "cloudflare:workers";
import type { D1Migration } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import vectors from "../../../tools/fixtures/e2ee_contract_vectors.json";

declare global { namespace Cloudflare { interface Env { DB: D1Database; ATTACHMENTS: R2Bucket; CURSOR_MAC_KEY: string; TEST_MIGRATIONS: D1Migration[]; } } }
const worker = (exports as { default: ExportedHandler }).default;
type WorkerRequest = Parameters<NonNullable<ExportedHandler["fetch"]>>[0];
const ACCOUNT = "A0000000-0000-4000-8000-00000000000A";
const OLD_DEVICE = "B0000000-0000-4000-8000-000000000001";
const NEW_DEVICE = "B0000000-0000-4000-8000-000000000002";
const NOW = "2026-08-29T00:00:00Z";
const TOKEN_BYTES = Uint8Array.from({ length: 32 }, (_, i) => i + 1);
const TOKEN = `gdt1_${btoa(String.fromCharCode(...TOKEN_BYTES)).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "")}`;
const pairing = vectors.pairing;
function b64(hex: string): string { return btoa(String.fromCharCode(...Uint8Array.from(hex.match(/../g) ?? [], x => parseInt(x, 16)))); }
function envelope(seed: number): string { const x=Uint8Array.from({length:34},(_,i)=>(seed+i)&255); x.set([1,1,0,0,0,1]); return b64([...x].map(v=>v.toString(16).padStart(2,"0")).join("")); }
async function tokenHash(): Promise<string> { return [...new Uint8Array(await crypto.subtle.digest("SHA-256", TOKEN_BYTES))].map(x=>x.toString(16).padStart(2,"0")).join(""); }

async function call(path: string, method: string, body?: unknown, auth = true): Promise<Response> {
  const headers = new Headers(); if (auth) headers.set("Authorization", `Device ${TOKEN}`);
  const request = new Request(`https://example.test${path}`, { method, headers, body: body === undefined ? null : JSON.stringify(body) }) as unknown as WorkerRequest;
  const response = await worker.fetch?.(request, env as never, {} as never); if (!response) throw new Error("no response"); return response;
}
const sessionBody = () => ({ protocol_version:1, session_id:pairing.session_id, pairing_session_lookup:b64(pairing.pairing_session_lookup_hex) });
const claimBody = () => ({ protocol_version:1, pairing_session_lookup:b64(pairing.pairing_session_lookup_hex), claim_id:pairing.claim_id, claim_lookup:b64(pairing.claim_lookup_hex), claim_envelope:envelope(7), claim_redeem_verifier:pairing.claim_redeem_verifier_hex });
const approveBody = async () => ({ protocol_version:1, claim_lookup:b64(pairing.claim_lookup_hex), delivery_envelope:envelope(40), device:{ device_id:NEW_DEVICE, space_id:"PHONE_SPACE", platform:"android_phone", display_name:null, device_token_hash:"c".repeat(64) } });
const redeemBody = () => ({ protocol_version:1, claim_lookup:b64(pairing.claim_lookup_hex), claim_redeem_auth:b64(pairing.claim_redeem_auth_hex) });

beforeAll(async()=>{ await applyD1Migrations(env.DB, env.TEST_MIGRATIONS); });
beforeEach(async()=>{
  for(const table of ["pairing_claim","pairing_session","device","recovery_record","enrollment_log","account"]) await env.DB.prepare(`DELETE FROM ${table}`).run();
  await env.DB.prepare("INSERT INTO account (account_id, created_at) VALUES (?,?)").bind(ACCOUNT,NOW).run();
  await env.DB.prepare(`INSERT INTO device (account_id,device_id,space_id,platform,linked_at,key_generation,token_hash) VALUES (?,?, 'MAC_SPACE','macos',?,1,?)`).bind(ACCOUNT,OLD_DEVICE,NOW,await tokenHash()).run();
});

describe("pairing route family",()=>{
  it("creates a five-minute session for an authenticated device",async()=>{
    const r=await call("/v1/pairing/sessions","POST",sessionBody()); expect(r.status).toBe(201);
    const row=await env.DB.prepare("SELECT created_by_device_id, expires_at, session_lookup_hash FROM pairing_session").first<Record<string,unknown>>();
    expect(row?.created_by_device_id).toBe(OLD_DEVICE); expect(Date.parse(row?.expires_at as string)-Date.now()).toBeGreaterThan(4*60_000);
    expect(JSON.stringify(await r.json())).not.toContain(pairing.pairing_session_lookup_hex);
  });

  it("runs submit, authenticated list, approve and one-time redeem",async()=>{
    await call("/v1/pairing/sessions","POST",sessionBody());
    expect((await call(`/v1/pairing/sessions/${pairing.session_id}/claims`,"POST",claimBody(),false)).status).toBe(201);
    const listed=await call(`/v1/pairing/sessions/${pairing.session_id}/claims`,"GET"); expect(listed.status).toBe(200);
    expect((await listed.json() as {result:{claims:unknown[]}}).result.claims).toHaveLength(1);
    expect((await call(`/v1/pairing/sessions/${pairing.session_id}/claims/${pairing.claim_id}/approve`,"POST",await approveBody())).status).toBe(200);
    const redeemed=await call(`/v1/pairing/sessions/${pairing.session_id}/claims/${pairing.claim_id}/redeem`,"POST",redeemBody(),false);
    expect(redeemed.status).toBe(200);
    expect((await redeemed.json() as {result:{delivery_envelope:string}}).result.delivery_envelope).toBe(envelope(40));
    expect((await env.DB.prepare("SELECT count(*) AS n FROM device").first<{n:number}>())?.n).toBe(2);
    expect((await call(`/v1/pairing/sessions/${pairing.session_id}/claims/${pairing.claim_id}/redeem`,"POST",redeemBody(),false)).status).toBe(409);
  });

  it("does not let a QR bearer list or approve claims",async()=>{
    await call("/v1/pairing/sessions","POST",sessionBody());
    expect((await call(`/v1/pairing/sessions/${pairing.session_id}/claims`,"GET",undefined,false)).status).toBe(401);
    expect((await call(`/v1/pairing/sessions/${pairing.session_id}/claims/${pairing.claim_id}/approve`,"POST",await approveBody(),false)).status).toBe(401);
  });

  it("rejects a wrong session lookup without revealing existence",async()=>{
    await call("/v1/pairing/sessions","POST",sessionBody()); const wrong=claimBody(); wrong.pairing_session_lookup=b64("00".repeat(32));
    const r=await call(`/v1/pairing/sessions/${pairing.session_id}/claims`,"POST",wrong,false); expect(r.status).toBe(401);
    expect(await r.json()).toEqual({protocol_version:1,error:{code:"PAIRING_INVALID",retryable:false}});
  });

  it("rejects redeem auth from another claim and leaves state approved",async()=>{
    await call("/v1/pairing/sessions","POST",sessionBody()); await call(`/v1/pairing/sessions/${pairing.session_id}/claims`,"POST",claimBody(),false);
    await call(`/v1/pairing/sessions/${pairing.session_id}/claims/${pairing.claim_id}/approve`,"POST",await approveBody());
    const wrong={...redeemBody(),claim_redeem_auth:b64("00".repeat(32))};
    expect((await call(`/v1/pairing/sessions/${pairing.session_id}/claims/${pairing.claim_id}/redeem`,"POST",wrong,false)).status).toBe(401);
    expect((await env.DB.prepare("SELECT state FROM pairing_claim").first<{state:string}>())?.state).toBe("approved");
  });
});
