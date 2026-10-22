# Proposal: encryption for backups and stories on the device

- Status: proposed, for discussion
- Issue: [theachoem/storypad#568](https://github.com/theachoem/storypad/issues/568)
- Builds on: the plan linked from #568, "Serverless Zero-Knowledge Journal Encryption using Passkeys"

## Summary

Encrypt a journal with one random **journal key**, and store that key only in wrapped
form: once per way of unlocking it (a recovery key, a passphrase, a passkey, the
device's keystore). Ship it in two phases:

1. **Encrypted backups.** Backup files and photos, voice notes and videos are encrypted
   before they are uploaded, so Google Drive, Dropbox, iCloud and Nextcloud only ever
   hold ciphertext. This is the part the maintainer called the clearest win in #568.
2. **Encrypted stories on the device.** Story content and media files are encrypted at
   rest, so a rooted phone, an unpatched OS or a forensic copy of the app's storage
   doesn't reveal the journal. This answers the concern raised in #568 about Android
   devices that no longer get security updates.

Both phases are opt-in. With encryption off, StoryPad works as it does now.

## How things work today

Checked against `develop` at a76825e8:

- Stories live in ObjectBox under the app support directory
  (`database/objectbox`, see `lib/core/types/support_directory_path.dart`), opened
  without encryption in `lib/core/databases/adapters/objectbox/base_box.dart`. Photos,
  audio and videos are plain files next to it (`images/`, `audio/`, `videos/`).
- Search runs as an ObjectBox query on `searchMetadata`, a plain-text join of every
  page's title and body (`lib/core/databases/adapters/objectbox/stories_box.dart`).
- Backups are yearly gzip files (`Backup__4__<year>__…`, see
  `lib/core/objects/backup_file_object.dart`) uploaded by
  `lib/core/services/backups/sync_steps/backup_uploader_service.dart`. Media is uploaded
  as-is under `<asset id>.<ext>` by `backup_images_uploader_service.dart`. Google Drive
  uses `appDataFolder`, which is hidden in the Drive UI but stores the files as they
  are: Google, and anything holding a token for that scope, can read them.
- App lock (`lib/core/objects/app_lock_object.dart`) is a gate in the UI: the PIN itself
  and the security-question answers are kept in `flutter_secure_storage`, and the app
  compares what's typed against them. Nothing is encrypted with the PIN.
- The app ships for Android, iOS, macOS and Linux. There is no web or Windows build,
  which matters for passkeys (below).

## Goals

- A cloud provider, or someone with access to the cloud account, can't read stories,
  titles, tags, places or media from StoryPad's backups.
- With phase 2 on, someone who copies the app's storage without the user's unlock
  secret can't read story content or media.
- Several devices can open the same encrypted backups.
- Losing a phone doesn't mean losing the journal, as long as the user kept their
  recovery key.

## Non-goals

- Protecting a journal from someone who has the unlocked device or makes the user
  unlock it. Encryption doesn't help at a border check where the user is told to open
  the app. (A decoy or hidden journal could; that's a separate feature.)
- Protecting against malware running inside the unlocked app.
- Hiding everything about the journal. Some metadata stays visible (see
  [What stays visible](#what-stays-visible)).
- A StoryPad server. Nothing here needs one, and no key ever leaves the user's devices
  unwrapped.

## Keys

```
                    ┌──────────────────────────┐
                    │ journal key (256-bit)    │  encrypts stories, backups, media
                    └────────────▲─────────────┘
          wrapped once per slot  │
   ┌──────────────┬──────────────┼──────────────┬────────────────────┐
   │ recovery key │ passphrase   │ passkey PRF  │ device keystore    │
   │ (mandatory)  │ (optional)   │ (optional,   │ (per device, for   │
   │              │ Argon2id     │  if the OS   │  biometric unlock) │
   │              │              │  supports it)│                    │
   └──────────────┴──────────────┴──────────────┴────────────────────┘
```

**Journal key.** 256 random bits, generated on the first device that turns encryption
on. It is the only key that encrypts data. Because data is never encrypted with a
slot's key, adding or removing a way to unlock is a matter of rewriting a few hundred
bytes, not re-encrypting the journal.

**Slots.** Each slot is the journal key encrypted with a key-encryption key (KEK):

| Slot | KEK comes from | Where the slot is stored | Notes |
|------|----------------|--------------------------|-------|
| Recovery key | 128+ random bits shown once as words or a code to write down | keyring file in the cloud, and on each device | Mandatory. The only way back if every device is lost. |
| Passphrase | Argon2id over the passphrase, with a stored salt and parameters | keyring file | Lets a new device join by typing it. Replaces the security questions for encrypted journals. |
| Passkey | WebAuthn PRF output for a fixed StoryPad salt | keyring file | As in the #568 plan. Optional because support is uneven (below). |
| Device keystore | A key in iOS/macOS Keychain or Android Keystore that never leaves the device, requiring biometrics or the device passcode | that device only | What makes daily unlock a fingerprint instead of a passphrase. |

**Keyring file.** One small JSON file per cloud provider, next to the backups (for
example `StoryPad__keyring.json`), listing the slots that can unlock the journal:

```json
{
  "version": 1,
  "journalKeyId": "9f2c…",
  "slots": [
    { "type": "recovery", "id": "r1", "wrapped": "…", "nonce": "…" },
    { "type": "passphrase", "id": "p1", "kdf": { "alg": "argon2id", "salt": "…", "m": 65536, "t": 3, "p": 1 }, "wrapped": "…", "nonce": "…" },
    { "type": "passkey", "id": "k1", "credentialId": "…", "rpId": "…", "deviceName": "iPhone", "wrapped": "…", "nonce": "…" }
  ]
}
```

The wrapped keys are safe to store in the cloud: without the matching secret they're
random bytes. Each slot is wrapped with authenticated encryption that also covers the
slot's type and id, so a slot can't be swapped or edited without detection. The file
should be readable without a key, so a fresh install can show which ways to unlock are
available.

### Differences from the plan in #568

The plan's key wrapping (one master key, a wrapped copy per passkey, a metadata file in
Google Drive) is what this proposal uses. It differs in three places:

1. **Passkeys aren't the foundation.** The plan assumes a browser with the WebAuthn PRF
   extension. StoryPad is a Flutter app, so it needs PRF from each platform's native
   passkey API. Apple added PRF to its passkey APIs in iOS 18 and macOS 15; on Android it
   depends on Credential Manager and the passkey provider; Linux has no platform passkey
   authenticator at all. None of this has been tried in StoryPad yet and needs a spike
   (see [Phases](#phases)). Until it is proven per platform, the recovery key and
   passphrase are what every device can count on, and passkeys are a convenience slot.
2. **Every cloud provider, not only Google Drive.** StoryPad backs up to Google Drive,
   Dropbox, iCloud and Nextcloud (`lib/core/services/backups/`). The keyring sits next
   to the backups in whichever one the user picked.
3. **Joining a new device needs no other device.** The plan has the new device
   authorised by one already unlocked. Here, the new device downloads the keyring and
   the user types the passphrase or recovery key, then registers its own keystore (and
   optionally passkey) slot. Approving from an unlocked device, for example by QR code,
   can come later.

## Phase 1: encrypted backups

### File format

Each encrypted file (yearly backup or media file) is:

```
"SPE1" | header length (u32) | header (JSON) | ciphertext
```

with the header holding `journalKeyId`, the algorithm and the nonce, and authenticated
as associated data. The ciphertext is the existing payload (the gzip backup, or the
media bytes), so encryption is a layer around what StoryPad already writes, not a new
backup format.

Algorithm: AES-256-GCM or XChaCha20-Poly1305, whichever the chosen Dart library runs
natively on all four platforms. Large videos are encrypted in chunks (each chunk its own
nonce and tag, with the chunk index authenticated) so they don't need to fit in memory.

Library: the [`cryptography`](https://pub.dev/packages/cryptography) package (with
`cryptography_flutter` for native speed) covers AES-GCM, ChaCha20-Poly1305 and
Argon2id. Which of these run natively on Linux, and how fast Argon2id is in pure Dart,
needs checking in the spike.

### File names

Encrypted yearly backups get a new version, `Backup__5__<year>__…`, using the same trick
as v4: apps that don't know v5 don't list those files, so an older app can't mistake an
encrypted file for a broken backup. Media keeps its `<asset id>.<ext>` name; the name
gives away the file type but nothing else.

### Turning it on

1. The user picks encryption in Data & Backup, writes down the recovery key, confirms
   it, and optionally sets a passphrase.
2. StoryPad creates the journal key, saves its keystore slot, and uploads the keyring.
3. It re-uploads every year as `Backup__5` and every media file encrypted.
4. Only after every upload is confirmed does it delete the plain `Backup__4` and
   `Backup__3` files and the plain media. Cloud Optimize's rules for keeping files that
   older apps still list need to treat plain files as deletable once encryption is on.

Turning encryption off is the same in reverse, after asking for an unlock.

### Devices on an older version

A device that only knows v4 keeps writing plain v4 files. Data & Backup already names
devices still writing v3 (#744); the same list should warn that a device is uploading
**unencrypted** backups, and encryption shouldn't finish switching over while one is
active.

## Phase 2: encrypted stories on the device

ObjectBox's Dart package has no encrypted store that I could find; this needs
confirming with ObjectBox before ruling it out. Three ways to get there:

| Option | What it means | Cost |
|--------|---------------|------|
| A. Encrypted fields (recommended) | Encrypt page content, titles, `searchMetadata`, feeling, places and asset metadata with the journal key before they go into ObjectBox. Encrypt media files on disk with the phase 1 format. | Search can't be an ObjectBox `contains` query on ciphertext. It moves to an in-memory index built after unlock. |
| B. Encrypted database | Move stories to SQLCipher or another encrypted store. | A rewrite of the database layer and a migration of every install. |
| C. Rely on the OS | iOS Data Protection and Android file-based encryption, with a stricter iOS protection class. | Free, but it's what #568 says isn't enough on unpatched Android. |

Option A keeps ObjectBox and the existing models. IDs, dates, tag ids and flags stay
plain so lists, calendars and filters keep working before any text is decrypted.

### Unlocking

App lock becomes real: unlocking the app unwraps the journal key, instead of comparing
a PIN.

- Biometric unlock opens the keystore slot (a key that the OS releases only after
  biometrics or the device passcode).
- The PIN, if kept, becomes a passphrase slot with Argon2id. A 4–6 digit PIN on its own
  is weak against someone who has copied the files, so encrypted mode should ask for a
  longer passphrase or rely on the keystore slot, where the OS limits attempts.
- Security questions can't protect encrypted data well (answers are guessable) and
  should be replaced by the recovery key in encrypted mode.
- The journal key stays in memory only while the app is unlocked, and is dropped when
  the app locks.

### Features that run while locked

Anything that reads story text without the user present stops working, or shows less,
while the journal is locked: "On this day" and other notification text, quick actions,
auto-sync started in the background, and exports. Background sync needs the journal
key to build a backup, so it could only run while the key is in memory, that is, after
an unlock. Each of these needs a decision in
the design for phase 2.

## What stays visible

Even with both phases on:

- The number of yearly backup files, their years and sizes, and when they changed.
- The number, types (by extension) and sizes of media files.
- Device names in backup file names (already there today) and in passkey slots.
- On the device (phase 2): story dates, counts, tag ids and flags.

## Recovery and failure modes

- Every slot lost (all devices gone, recovery key and passphrase forgotten): the journal
  can't be read by anyone, including the developer. The setup screens must say so
  plainly, and make the user confirm the recovery key before turning encryption on.
- Keyring file deleted from the cloud: any unlocked device can upload it again from its
  local copy.
- Keyring edited by someone else: slots fail to verify and are ignored; StoryPad shows
  that the keyring was changed.
- Interrupted switch-over: plain files are deleted only after every encrypted upload is
  confirmed, so a crash leaves both, never neither.
- Changing the passphrase rewrites one slot. Rotating the journal key (after a device is
  lost, say) means re-encrypting everything; it's the turning-on flow again, with a new
  `journalKeyId`.

## Phases

0. **Spike (no user-facing change).** Try PRF passkeys from Flutter on iOS, macOS and
   Android; check Argon2id and AES-GCM speed in the chosen library on all four
   platforms; confirm ObjectBox has no encryption option.
1. **Crypto core.** Journal key, slots, keyring and the `SPE1` envelope as a package
   with no Flutter UI, with test vectors and tests for tampering and wrong keys.
2. **Encrypted backups.** `Backup__5`, encrypted media, switch-over, Data & Backup
   screens, recovery key setup, the older-device warning.
3. **Joining devices.** Passphrase and recovery key on a new device; keystore slot;
   passkey slot where the spike shows it works.
4. **Encrypted stories on the device.** Option A, the in-memory search index, real app
   lock, and decisions on features that run while locked.

Each phase can ship by itself; phase 1–2 is useful without phase 4.

## Testing

- Unit tests for the crypto core: known-answer vectors, wrong key, flipped bits in the
  header and ciphertext, swapped slots, truncated chunks.
- Round trips: encrypt a backup, restore it on a clean install with each slot type.
- Mixed fleets: a v4-only device and an encrypted device on the same account.
- Interrupted switch-over: kill the app at each step and check no data is lost.
- Phase 2 migration: an existing plain database converted and searched.

## Open questions

1. Is phase 1 alone worth shipping first, as the maintainer suggested in #568?
2. Should encryption be per cloud provider or one switch for the whole journal?
3. Keep a PIN in encrypted mode, or require a passphrase plus biometrics?
4. What should notifications and other locked-time features show in phase 2?
5. Which passkey relying-party ID to use (it ties passkeys to a domain StoryPad
   controls).
