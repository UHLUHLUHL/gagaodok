import { applyD1Migrations, env } from "cloudflare:test";
import type { D1Migration } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import { assertRateLimit } from "../src/security/rateLimit";
declare global { namespace Cloudflare { interface Env { DB:D1Database;ATTACHMENTS:R2Bucket;CURSOR_MAC_KEY:string;RATE_LIMIT_MAC_KEY:string;TEST_MIGRATIONS:D1Migration[]; } } }
beforeAll(async()=>{await applyD1Migrations(env.DB,env.TEST_MIGRATIONS);});
beforeEach(async()=>{await env.DB.prepare("DELETE FROM rate_limit_bucket").run();});
function request(ip:string){return new Request("https://example.test",{headers:{"CF-Connecting-IP":ip}});}
describe("D1 rate limit",()=>{
  it("allows exactly the recovery budget and atomically rejects the rest",async()=>{const outcomes=await Promise.all(Array.from({length:8},async()=>{try{await assertRateLimit(request("192.0.2.1"),env.DB,env.RATE_LIMIT_MAC_KEY,"recovery",1_700_000_000_000);return"ok";}catch(error){return(error as{code?:string}).code;}}));expect(outcomes.filter(x=>x==="ok")).toHaveLength(5);expect(outcomes.filter(x=>x==="RATE_LIMITED")).toHaveLength(3);});
  it("separates scope, subject and fixed windows",async()=>{for(let i=0;i<5;i++)await assertRateLimit(request("192.0.2.1"),env.DB,env.RATE_LIMIT_MAC_KEY,"recovery",1_700_000_000_000);await expect(assertRateLimit(request("192.0.2.1"),env.DB,env.RATE_LIMIT_MAC_KEY,"recovery",1_700_003_600_000)).resolves.toBeUndefined();await expect(assertRateLimit(request("192.0.2.2"),env.DB,env.RATE_LIMIT_MAC_KEY,"recovery",1_700_000_000_000)).resolves.toBeUndefined();await expect(assertRateLimit(request("192.0.2.1"),env.DB,env.RATE_LIMIT_MAC_KEY,"enrollment",1_700_000_000_000)).resolves.toBeUndefined();});
  it("stores no raw address",async()=>{await assertRateLimit(request("192.0.2.99"),env.DB,env.RATE_LIMIT_MAC_KEY,"recovery",1_700_000_000_000);const row=await env.DB.prepare("SELECT subject_hash FROM rate_limit_bucket").first<{subject_hash:string}>();expect(row?.subject_hash).toMatch(/^[0-9a-f]{64}$/);expect(JSON.stringify(row)).not.toContain("192.0.2.99");});
});
