# Proposal: encryption for backups and stories on the device

- Status: proposed, for discussion
- Issue: [theachoem/storypad#568](https://github.com/theachoem/storypad/issues/568)
- Builds on: the plan linked from #568, "Serverless Zero-Knowledge Journal Encryption using Passkeys"

## Summary

Encrypt a journal to one **journal identity**, an [age](https://age-encryption.org)
key pair, and store its secret key only in wrapped form: once per way of unlocking it
(a recovery key, a passphrase, a passkey, the device's keystore). Files use the age
format and its modern primitives (X25519, ChaCha20-Poly1305, HKDF, scrypt); there is no
RSA anywhere. Ship it in two phases:

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

## Ciphers: age, not a home-grown format

StoryPad's encrypted files use the [age](https://age-encryption.org/v1) v1 format, and
its building blocks everywhere else. No RSA, no AES-CBC, no hand-rolled envelope:

| Job | Primitive | As in age |
|-----|-----------|-----------|
| Key agreement for a recipient | X25519 (optionally the ML-KEM-768 + X25519 post-quantum hybrid) | yes |
| Key derivation | HKDF-SHA-256 | yes |
| Payload encryption | ChaCha20-Poly1305 in the STREAM construction, 64 KiB chunks | yes |
| Header authentication | HMAC-SHA-256 | yes |
| Passphrase to key | scrypt (age's passphrase recipient) | yes |
| Field encryption on the device (phase 2) | XChaCha20-Poly1305, key from HKDF-SHA-256 | same primitives |

Using age's format rather than designing one gives three things:

- **A reviewed design.** age is small, specified and widely used; StoryPad doesn't have
  to invent nonce handling, chunking or header authentication.
- **A way out without StoryPad.** The recovery key *is* an age identity
  (`AGE-SECRET-KEY-1…`). With it, `age -d -i recovery.txt Backup__5__2025__… | gunzip`
  reads a backup on any computer, even if StoryPad disappears.
- **Encrypting without unlocking.** age encrypts to a *public* recipient, so a device
  can write an encrypted backup without holding the secret key. Only reading needs an
  unlock.

Dart implementations: [`dartage`](https://pub.dev/packages/dartage) (0.3.0, September
2026; recipients, passphrases, post-quantum hybrids, streaming) and the older
[`dage`](https://pub.dev/packages/dage) (last release February 2024). `dartage` is new
and unaudited; the spike checks that it interoperates with the reference `age` and
`rage` tools in both directions, and how fast it runs. If it isn't good enough, the
same format can be built on [`cryptography`](https://pub.dev/packages/cryptography)
(X25519, ChaCha20-Poly1305, HKDF, HMAC) plus scrypt from `pointycastle`.

**Post-quantum.** Cloud backups sit for years, so "record now, decrypt later" is a fair
worry. If the hybrid recipient interoperates with the reference age, use it from the
start; otherwise start with X25519 and add a hybrid recipient later. age files can have
several recipients, so files can carry both during the change.

## Keys

```
                ┌───────────────────────────────────────────┐
                │ journal identity (age X25519 key pair)    │
                │  public:  age1…        → encrypts files   │
                │  secret:  AGE-SECRET-KEY-1… → decrypts    │
                └───────────────────▲───────────────────────┘
     secret key wrapped once per slot│
   ┌──────────────┬──────────────────┼──────────────┬────────────────────┐
   │ recovery key │ passphrase       │ passkey PRF  │ device keystore    │
   │ (mandatory;  │ (optional;       │ (optional,   │ (per device, for   │
   │ the identity │  age scrypt      │  if the OS   │  biometric unlock) │
   │ itself)      │  recipient)      │  supports it)│                    │
   └──────────────┴──────────────────┴──────────────┴────────────────────┘
```

**Journal identity.** An age X25519 key pair generated on the first device that turns
encryption on. Every backup and media file is an age file whose recipient is the
journal's public key; age gives each file its own random file key, so one file's key
says nothing about another's. Data is never encrypted with a slot's key, so adding or
removing a way to unlock rewrites a few hundred bytes, not the journal.

**Slots.** Each slot holds the identity's secret key, encrypted:

| Slot | How the secret is protected | Where the slot is stored | Notes |
|------|-----------------------------|--------------------------|-------|
| Recovery key | It is the secret: the `AGE-SECRET-KEY-1…` string, shown once to write down or save | nowhere online; on paper or in a password manager | Mandatory. The only way back if every device is lost. Works with the `age` CLI. |
| Passphrase | An age file encrypted to an scrypt recipient (age's passphrase mode) | keyring file | Lets a new device join by typing it. Replaces the security questions for encrypted journals. |
| Passkey | ChaCha20-Poly1305 under a key derived with HKDF-SHA-256 from the WebAuthn PRF output | keyring file | As in the #568 plan. Optional because support is uneven (below). |
| Device keystore | Encrypted with a key that the iOS/macOS Keychain or Android Keystore holds and releases only after biometrics or the device passcode | that device only | What makes daily unlock a fingerprint. Hardware keystores only offer what the hardware has (AES-GCM, P-256), and this wrapping never leaves the device; the Secure Enclave approach of `age-plugin-se` is worth a look here. |

**Keyring file.** One small JSON file per cloud provider, next to the backups (for
example `StoryPad__keyring.json`):

```json
{
  "version": 1,
  "recipient": "age1…",
  "slots": [
    { "type": "passphrase", "id": "p1", "age": "-----BEGIN AGE ENCRYPTED FILE-----…" },
    { "type": "passkey", "id": "k1", "credentialId": "…", "rpId": "…", "deviceName": "iPhone", "salt": "…", "nonce": "…", "wrapped": "…" }
  ],
  "mac": "…"
}
```

The slots are safe in the cloud: without the matching secret they're random bytes. The
public recipient is what lets a fresh install, or a locked device, encrypt. `mac` is an
HMAC-SHA-256 over the rest, keyed from the journal identity, so an unlocked device can
tell if someone replaced the recipient with their own (which would make new backups
readable to them). A device trusts a recipient only once it has been unlocked with it,
and keeps its own copy.

### Differences from the plan in #568

The plan's key wrapping (one master key, a wrapped copy per passkey, a metadata file in
Google Drive) is what this proposal uses. It differs in four places:

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
4. **The format is age's.** The plan leaves the ciphers and file format open. Here they
   are age's, so the master key is an age identity and the "safes" hold its secret key.

## Phase 1: encrypted backups

### File format

Each encrypted yearly backup and media file is a plain age v1 file (binary, not
armored) with the journal's public key as its recipient. Its payload is what StoryPad
writes today, the gzip backup or the media bytes, so encryption is a layer around the
existing format, not a new backup format. age's 64 KiB chunks mean large videos are
encrypted and decrypted as a stream, never whole in memory.

### File names

Encrypted yearly backups get a new version, `Backup__5__<year>__…`, using the same trick
as v4: apps that don't know v5 don't list those files, so an older app can't mistake an
encrypted file for a broken backup. Media keeps its `<asset id>.<ext>` name; the name
gives away the file type but nothing else.

### Turning it on

1. The user picks encryption in Data & Backup, writes down the recovery key, confirms
   it, and optionally sets a passphrase.
2. StoryPad creates the journal identity, saves its keystore slot, and uploads the
   keyring.
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
| A. Encrypted fields (recommended) | Encrypt page content, titles, `searchMetadata`, feeling, places and asset metadata with XChaCha20-Poly1305 before they go into ObjectBox, under a key derived with HKDF-SHA-256 from the journal identity. Media files on disk become age files, like in phase 1. | Search can't be an ObjectBox `contains` query on ciphertext. It moves to an in-memory index built after unlock. |
| B. Encrypted database | Move stories to SQLCipher or another encrypted store. | A rewrite of the database layer and a migration of every install. |
| C. Rely on the OS | iOS Data Protection and Android file-based encryption, with a stricter iOS protection class. | Free, but it's what #568 says isn't enough on unpatched Android. |

Option A keeps ObjectBox and the existing models. IDs, dates, tag ids and flags stay
plain so lists, calendars and filters keep working before any text is decrypted.

### Unlocking

App lock becomes real: unlocking the app unwraps the journal identity, instead of
comparing a PIN.

- Biometric unlock opens the keystore slot (a key that the OS releases only after
  biometrics or the device passcode).
- The PIN, if kept, becomes a passphrase slot (scrypt, as above). A 4–6 digit PIN on its own
  is weak against someone who has copied the files, so encrypted mode should ask for a
  longer passphrase or rely on the keystore slot, where the OS limits attempts.
- Security questions can't protect encrypted data well (answers are guessable) and
  should be replaced by the recovery key in encrypted mode.
- The secret key, and the field key derived from it, stay in memory only while the app
  is unlocked, and are dropped when the app locks.

### Features that run while locked

Anything that reads story text without the user present stops working, or shows less,
while the journal is locked: "On this day" and other notification text, quick actions,
auto-sync started in the background, and exports. Each of these needs a decision in
the design for phase 2.

Because age encrypts to the public recipient, some things keep working while locked: in
phase 1 a background sync can still encrypt and upload backups, and in phase 2 a photo
or voice note added from a share sheet can be saved encrypted. What can't run locked is
anything that has to *read* encrypted stories, including building a backup from an
encrypted database in phase 2.

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
- Changing the passphrase rewrites one slot. Rotating the journal identity (after a
  device or the recovery key is lost, say) means re-encrypting everything to a new
  recipient; it's the turning-on flow again, with a new recovery key.

## Phases

0. **Spike (no user-facing change).** Try PRF passkeys from Flutter on iOS, macOS and
   Android; check that `dartage` reads and writes files the reference `age`/`rage`
   tools accept (X25519, scrypt, the post-quantum hybrid), and its speed on all four
   platforms; confirm ObjectBox has no encryption option.
1. **Crypto core.** Journal identity, slots and keyring on top of age, as a package
   with no Flutter UI, with age's test vectors and tests for tampering and wrong keys.
2. **Encrypted backups.** `Backup__5`, encrypted media, switch-over, Data & Backup
   screens, recovery key setup, the older-device warning.
3. **Joining devices.** Passphrase and recovery key on a new device; keystore slot;
   passkey slot where the spike shows it works.
4. **Encrypted stories on the device.** Option A, the in-memory search index, real app
   lock, and decisions on features that run while locked.

Each phase can ship by itself; phase 1–2 is useful without phase 4.

## Testing

- Unit tests for the crypto core: age's published test vectors (the
  [CCTV](https://github.com/C2SP/CCTV/tree/main/age) suite), wrong key, flipped bits in
  the header and ciphertext, swapped slots, truncated chunks, a replaced recipient.
- Interoperability: files StoryPad writes decrypt with the `age` CLI and the recovery
  key, and files `age` writes to the journal recipient import into StoryPad.
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
6. Post-quantum hybrid recipients from the start, or X25519 first?
