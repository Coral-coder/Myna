# Bee bracelet firmware — analysis notes

Source: firmware images bundled in the Bee Android app's DFU assets.

## Hardware generations
| Version | SoC | Load addr | Image | Signature | Notes |
|---|---|---|---|---|---|
| 0.5.1  | nRF52840     | 0xC200 (49664) | plain      | ECDSA P-256 | readable |
| 0.6.1  | nRF52840_QIAA| 0xC200 (49664) | plain      | ECDSA P-256 | readable; manifest names Zephyr+nRF SDK revisions |
| 0.6.19 | nRF54L15     | 0x14800 (83968)| AES-128 enc| Ed25519     | ENC_X25519 key-wrap; contents opaque |

Build stack (from strings): Zephyr OS v4.0.99, nRF Connect SDK v3.0.1, MCUboot,
T5838 PDM mic driver. Confirms a standard west/Zephyr project — your own
firmware would be an NCS app for the same board.

## MCUboot
- Header 0x200 (52840) / 0x800 (54L15). Image signed; public-key hash in KEYHASH TLV.
- Same signing key across the 52840 builds (keyhash 32cebff9...).
- Bootloader verifies signature before boot. Flashing custom firmware therefore
  requires SWD access to the device to replace the bootloader key / bootloader,
  not a DFU push. Needs a J-Link or nRF debug probe wired to the bracelet's SWD
  pads. This is destructive and device-specific; confirm the SoC first.

## DFU transport
- Nordic mcumgr / SMP over BLE (SMP service 8D53DC1D-1DB7-4CD3-868B-8A527460AA84).
- Firmware delivered as a zip: manifest.json + Firmware.signed(.encrypted).bin.
- Mode TEST_AND_CONFIRM.

## Audio protocol (matches Myna's BeeProtocol)
- Packet crypto: AES-128-CTR, 16-byte key, 12-byte session nonce, per-packet seq.
- Validates Myna's direct-Bluetooth decrypt path against real firmware.

## SetEncryptionKey (0xC018) handler — full teardown (v0.6.1, nRF52840)

Disassembled from `fw/v061/app_update.bin`. MCUboot image, link base 0xC000
(vector table 0xC200, matches manifest `load_address`). The provisioning
routine is at **0x20604** (file 0x14604). Behaviour:

1. Requires the written value to be **exactly 108 bytes** (`cmp r1,#0x6c`);
   rejects otherwise. Rejects if a key is already set (returns the
   "already set" error) — matches the 0x8004 reply.
2. Copies the 108-byte token to a stack buffer and checks:
   - bytes **[0:4]** == a fixed magic/version word;
   - bytes **[4:12]** == this chip's **FICR DEVICEID** (read from
     0x10000060/0x64). **The token is cryptographically bound to the
     individual device.**
3. Derives a 32-byte digest = KDF/MAC keyed by the literal label
   **"AAC-CTR-KEY-V1"** over token bytes **[0:44]** (label fed first, then
   the 44-byte header+key region).
4. **ECDSA-P256 verifies** that digest against a signature in token bytes
   **[44:108]** (64 bytes) using a **baked-in Bee public key** (64-byte
   constant at 0xA3D78 / file 0x99d78). Non-Bee tokens fail here.
5. On success, stores token bytes **[12:28]** (16 bytes) as the AES-128-CTR
   audio key — to the `app/keys` settings record and to RAM for the session.

### Token layout (108 bytes)
`[0:4] magic · [4:12] device id · [12:28] AES-128 CTR key · [28:44] aux ·
[44:108] ECDSA-P256 signature`

### Consequences (definitive)
- The audio key **is** `token[12:28]` — exactly what `BeeCloudAPI.ctrKey` and
  `ConnectionGuard.extractCtrKeyFromSealedToken` use. There is **no extra KDF
  or per-session derivation** Myna is missing; "AAC-CTR-KEY-V1" is the
  device/backend's provisioning derivation, not a per-packet step (the label
  appears only in firmware, never in the Bee app's Kotlin or native code).
- The sealed-key wall is a real **ECDSA check against a baked-in key**, so we
  cannot forge or set our own key, and the token is **device-bound** — a token
  from another bracelet/pairing can't work here.
- Therefore a garbage (`✗ not ADTS`) decrypt means the pasted token is simply
  **not this device's real token**. The only fix is capturing the correct
  108-byte token for this bracelet (its `[12:28]` is the key).

## Next steps
1. Read the bracelet's firmware version over BLE (Backstage) to confirm SoC.
2. If 52840: load the plain .bin into Ghidra (ARM Cortex-M, base 0xC200) to map
   the GATT/audio/control handlers; cross-reference BeeProtocol command ids.
3. Custom firmware = NCS/Zephyr app for the board + SWD reflash of MCUboot key.
   Requires physical debug access to your own device.
