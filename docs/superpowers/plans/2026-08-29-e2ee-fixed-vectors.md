# Gagaodok E2EE Fixed Vectors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement one byte-exact AES-256-GCM/HKDF/AAD contract in Python, Swift, and Kotlin, with both apps consuming the same committed synthetic vector artifact.

**Architecture:** `tools/e2ee_contract_vectors.py` remains the independent contract generator and gains a dependency-free AES-256-GCM reference path verified against a NIST vector. Swift and Kotlin each implement LP v1, HKDF-SHA256, canonical AAD, and the v1 envelope with platform crypto, then load the single root JSON artifact in tests. Runtime code never reads the test artifact.

**Tech Stack:** Python 3 standard library, Swift 5.9 with CryptoKit on macOS 14, Kotlin/JVM 17 with `javax.crypto`, JUnit 4.

**Spec:** `docs/2026-08-27-sync-encryption-proposal.md` §§3.2–3.3, 7.1–7.2, 12–14 and `docs/PHASE2_SYNTHETIC_SYNC_TEST_PLAN.md` P2-08.

## Global Constraints

- AES-256-GCM only: envelope `version = 1`, `alg = 1`, `key_generation = 1`, 12-byte nonce, 16-byte tag.
- AAD uses LP v1 with fields 1–12 in ascending order; UUID text is uppercase hyphenated ASCII.
- Standard padded Base64 is used for text envelopes; URL-safe Base64 is rejected.
- No new dependency or lockfile change.
- Test data is synthetic; keys, nonce, plaintext, and identifiers are fixed test-only values.
- No Cloudflare login/resource/deploy, real data, APK installation, app-data mutation, push, or merge.
- Production crypto fails closed and never logs plaintext, keys, nonce, AAD, or full envelopes.

---

### Task 1: Canonical Python AEAD Vector and Artifact

**Files:**
- Modify: `tools/e2ee_contract_vectors.py`
- Modify: `tools/tests/test_e2ee_contract_vectors.py`
- Create: `tools/fixtures/e2ee_contract_vectors.json`

**Interfaces:**
- Consumes: existing `encode_lp`, `hkdf_*`, `canonical_scope_context`, and `derive_scope_keys`.
- Produces: `field_aad(...) -> bytes`, `seal_v1_envelope(...) -> bytes`, `contract_vectors() -> dict[str, object]`, and one canonical JSON artifact.

- [ ] **Step 1: Write failing tests for the NIST AES-256-GCM vector and Gagaodok artifact fields**

```python
def test_aes256_gcm_reference_matches_nist_vector():
    sealed = aes256_gcm_seal(bytes(32), bytes(12), bytes(16), b"")
    assert sealed.hex() == "cea7403d4d606b6e074ec5d3baf39d18d0d1c8a799996bf0265b98b5d48ab919"

def test_contract_artifact_is_canonical_and_reproducible():
    assert json.loads(ARTIFACT.read_text()) == contract_vectors()
```

- [ ] **Step 2: Run `python3 -m unittest tools.tests.test_e2ee_contract_vectors` and confirm RED because the AEAD/vector APIs do not exist**

- [ ] **Step 3: Implement dependency-free AES-256 block encryption, GCM GHASH/counter mode, field AAD, v1 envelope assembly, and canonical JSON output**

```python
def seal_v1_envelope(key: bytes, nonce: bytes, plaintext: bytes, aad: bytes) -> bytes:
    ciphertext_and_tag = aes256_gcm_seal(key, nonce, plaintext, aad)
    return b"\x01\x01" + (1).to_bytes(4, "big") + nonce + ciphertext_and_tag
```

- [ ] **Step 4: Generate the artifact with an explicit `--output` path, rerun the Python tests, and confirm GREEN**

- [ ] **Step 5: Commit only the generator, tests, and JSON artifact**

---

### Task 2: Swift Contract Crypto and Executable Test Harness

**Files:**
- Create: `Sources/KakaoSapiens/Services/SyncE2EE.swift`
- Create: `Tests/KakaoSapiensE2EEContractTests/E2EEContractVectorTests.swift`
- Create: `tools/test_swift_e2ee_contract.sh`

**Interfaces:**
- Consumes: root `tools/fixtures/e2ee_contract_vectors.json` and CryptoKit.
- Produces: `SyncE2EE.Scope`, `SyncE2EE.AAD`, `deriveScopeKeys`, `encodeAAD`, `seal`, and `open`.

- [x] **Step 1: Add an isolated test harness that loads the root artifact and references missing `SyncE2EE` APIs**

```swift
let envelope = try SyncE2EE.seal(
    plaintext: vector.plaintext,
    key: vector.fieldKey,
    nonce: vector.nonce,
    aad: vector.aad
)
try require(envelope == vector.envelope, "envelope mismatch")
```

- [x] **Step 2: Confirm RED because `SyncE2EE.swift` is absent**

The selected Apple Command Line Tools contain neither `XCTest` nor `Testing`, so
the executable harness compiles the production source and contract test in one
module without adding a dependency. The initial run failed because the production
source did not exist.

- [x] **Step 3: Implement LP v1/HKDF/AAD/envelope using CryptoKit AES.GCM and strict pre-decrypt header validation**

- [x] **Step 4: Add negative tests for changed identity/field/order/generation/algorithm and malformed Base64; run the focused Swift test until GREEN**

- [x] **Step 5: Commit the Swift implementation and executable contract harness**

---

### Task 3: Kotlin Contract Crypto Shared by Phone and Tablet

**Files:**
- Create: `android/app/src/main/java/com/sapiens/gagaodok/sync/SyncE2EE.kt`
- Create: `android/app/src/test/java/com/sapiens/gagaodok/sync/E2EEContractVectorTest.kt`

**Interfaces:**
- Consumes: the same root JSON artifact and Java `Cipher("AES/GCM/NoPadding")`.
- Produces: Kotlin equivalents of the Swift `Scope`, `AAD`, `deriveScopeKeys`, `encodeAAD`, `seal`, and `open` APIs in shared `src/main`.

- [x] **Step 1: Write a JVM test that loads the root artifact and references missing `SyncE2EE` APIs**

```kotlin
val envelope = SyncE2EE.seal(vector.plaintext, vector.fieldKey, vector.nonce, vector.aad)
assertArrayEquals(vector.envelope, envelope)
```

- [x] **Step 2: Run `./gradlew :app:testPhoneDebugUnitTest --tests '*E2EEContractVectorTest*'` with JDK 17 and confirm RED because the implementation is absent**

- [x] **Step 3: Implement LP v1/HKDF/AAD/envelope with strict validation before `Cipher.doFinal`**

- [x] **Step 4: Add the same negative mutations as Swift and run both phone and tablet-mentor focused JVM variants until GREEN**

- [ ] **Step 5: Commit the shared Kotlin implementation and tests**

---

### Task 4: Cross-Platform Gate and Canonical Documentation

**Files:**
- Modify: `docs/2026-08-27-sync-encryption-proposal.md`
- Modify: `docs/PHASE2_SYNTHETIC_SYNC_TEST_PLAN.md`
- Modify: `docs/PHASE1_INTEGRATION_ACCEPTANCE_MATRIX.md`

**Interfaces:**
- Consumes: the three verified commits and their exact commands/results.
- Produces: a checked P2-08 gate with the artifact hash and platform evidence.

- [ ] **Step 1: Run Python vector tests and regenerate to a temporary file; compare it byte-for-byte with the committed artifact**

- [ ] **Step 2: Run focused Swift, phone, and tablet tests plus `swift build` and the affected Android unit variants**

- [ ] **Step 3: Record only actual evidence and remaining pairing/recovery or device-key-storage gaps in canonical docs**

- [ ] **Step 4: Run `git diff --check`, review the scoped diff, and commit the documentation gate**
