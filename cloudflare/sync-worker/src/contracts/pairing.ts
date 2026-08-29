import { validationFailed } from "./error";
import { requireBinary32, requireExactKeys, requireRecord, requireV1Envelope } from "./onboarding";
import { requireSpaceId, requireUuid, type SpaceId } from "./identity";
import { bytesToHex } from "./onboarding";

const HASH = /^[0-9a-f]{64}$/;
const PLATFORM_BY_SPACE: Record<SpaceId,string> = { MAC_SPACE:"macos", PHONE_SPACE:"android_phone", TABLET_SPACE:"android_tablet" };

async function body(request: Request): Promise<Record<string,unknown>> {
  try {
    const bytes=new Uint8Array(await request.arrayBuffer());
    if(bytes.length===0||bytes.length>65_536) throw validationFailed();
    return requireRecord(JSON.parse(new TextDecoder("utf-8",{fatal:true,ignoreBOM:true}).decode(bytes)));
  } catch(error) {
    if(error instanceof Error&&error.message==="VALIDATION_FAILED") throw error;
    throw validationFailed();
  }
}
function protocol(value:Record<string,unknown>):void { if(value.protocol_version!==1) throw validationFailed(); }
export async function sha256Hex(value:Uint8Array):Promise<string>{ return bytesToHex(new Uint8Array(await crypto.subtle.digest("SHA-256",value))); }

export async function parsePairingSession(request:Request){ const x=await body(request); requireExactKeys(x,["protocol_version","session_id","pairing_session_lookup"]); protocol(x); const lookup=requireBinary32(x.pairing_session_lookup); return {sessionId:requireUuid(x.session_id),lookupHash:await sha256Hex(lookup.bytes)}; }
export async function parsePairingClaim(request:Request){ const x=await body(request); requireExactKeys(x,["protocol_version","pairing_session_lookup","claim_id","claim_lookup","claim_envelope","claim_redeem_verifier"]); protocol(x); const session=requireBinary32(x.pairing_session_lookup); const lookup=requireBinary32(x.claim_lookup); if(typeof x.claim_redeem_verifier!=="string"||!HASH.test(x.claim_redeem_verifier))throw validationFailed(); return {sessionLookupHash:await sha256Hex(session.bytes),claimId:requireUuid(x.claim_id),claimLookup:lookup.encoded,claimEnvelope:requireV1Envelope(x.claim_envelope).encoded,claimRedeemVerifier:x.claim_redeem_verifier}; }
export async function parsePairingApprove(request:Request){ const x=await body(request); requireExactKeys(x,["protocol_version","claim_lookup","delivery_envelope","device"]); protocol(x); const lookup=requireBinary32(x.claim_lookup); const d=requireRecord(x.device); requireExactKeys(d,["device_id","space_id","platform","display_name","device_token_hash"]); const spaceId=requireSpaceId(d.space_id); if(d.platform!==PLATFORM_BY_SPACE[spaceId]||typeof d.device_token_hash!=="string"||!HASH.test(d.device_token_hash))throw validationFailed(); return {claimLookup:lookup.encoded,deliveryEnvelope:requireV1Envelope(x.delivery_envelope).encoded,device:{deviceId:requireUuid(d.device_id),spaceId,platform:d.platform as string,displayName:d.display_name===null?null:requireV1Envelope(d.display_name).encoded,tokenHash:d.device_token_hash}}; }
export async function parsePairingRedeem(request:Request){ const x=await body(request); requireExactKeys(x,["protocol_version","claim_lookup","claim_redeem_auth"]); protocol(x); return {claimLookup:requireBinary32(x.claim_lookup),claimRedeemAuth:requireBinary32(x.claim_redeem_auth).bytes}; }

function lp(fields:Array<[number,Uint8Array]>):Uint8Array{ const size=6+fields.reduce((n,[,v])=>n+7+v.length,0); const out=new Uint8Array(size);const view=new DataView(out.buffer);out.set([71,68,75,49]);view.setUint16(4,fields.length,false);let o=6;for(const[id,v]of fields){view.setUint16(o,id,false);o+=2;out[o++]=1;view.setUint32(o,v.length,false);o+=4;out.set(v,o);o+=v.length;}return out;}
export async function claimRedeemVerifier(sessionId:string,claimId:string,claimLookup:Uint8Array,auth:Uint8Array):Promise<string>{ const payload=lp([[1,new TextEncoder().encode(sessionId)],[2,new TextEncoder().encode(claimId)],[3,claimLookup],[4,auth]]); const labeled=lp([[1,new TextEncoder().encode("gagaodok/e2ee/v1/claim-redeem-verifier")],[2,payload]]);return sha256Hex(labeled); }
