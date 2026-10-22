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

## Next steps
1. Read the bracelet's firmware version over BLE (Backstage) to confirm SoC.
2. If 52840: load the plain .bin into Ghidra (ARM Cortex-M, base 0xC200) to map
   the GATT/audio/control handlers; cross-reference BeeProtocol command ids.
3. Custom firmware = NCS/Zephyr app for the board + SWD reflash of MCUboot key.
   Requires physical debug access to your own device.
