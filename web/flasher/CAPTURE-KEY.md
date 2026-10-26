# Capturing the bracelet's key (no custom firmware needed)

The Bee bracelet accepts only an encryption key **signed by Bee** — a 108-byte
token tied to your bracelet's device ID. The bracelet verifies the signature but
doesn't care who sends it, and the token is static per device. So you don't need
to defeat Bee's servers: capture the token **once** as the Bee app installs it
over Bluetooth, then paste it into Myna (Backstage → Bee Bracelet → *Advanced:
paste captured key*). Myna stores it on-device and uses it to decrypt audio with
no Bee server involved.

The AES-CTR key Myna actually uses is bytes **12–27** of that token; Myna
extracts it automatically.

## Easiest: Android HCI snoop log (no extra hardware)

1. On an Android phone with the **Bee app**: Settings → **Developer options** →
   enable **Enable Bluetooth HCI snoop log**. (Toggle Bluetooth off/on after.)
2. In the Bee app, **pair/connect the bracelet** so it provisions the key.
3. Pull the log: `adb bugreport` (the snoop log is inside, usually
   `FS/data/misc/bluetooth/logs/btsnoop_hci.log`), or the path shown under the
   developer setting.
4. Open `btsnoop_hci.log` in **Wireshark**. Filter: `btatt`.
5. Find the **Write** to the control characteristic
   (UUID `05E1F93C-D8D0-5ED8-DD88-379E4C1A3E3E`) whose value begins `18 C0`.
   The bytes **after `18 C0`** are the token (108 bytes).
6. Copy those bytes as hex and paste into Myna. (Pasting the whole value
   including the leading `18 C0` is fine — Myna strips it.)

The snoop log is captured on the phone's own host stack in the clear, so BLE
link encryption doesn't get in the way.

## Alternatives

- **BLE sniffer** — an nRF52840 dongle running nRF Sniffer + Wireshark, capturing
  the same `18 C0` write live. Works only if the link isn't bonded/encrypted.
- **Active MITM** — GATTacker or Mirage clone the bracelet so the Bee app connects
  to a proxy that logs everything. Most involved; only needed if the two methods
  above don't yield the write in the clear.

## Notes

- It's your bracelet, your Bee account, your data — this is interoperability with
  hardware you own.
- If Bee ever rotates the device's key server-side, re-capture and paste again.
- This path needs **no probe and no custom firmware**. The SWD flasher in this
  folder is only for the separate goal of replacing the firmware entirely.
