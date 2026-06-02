# Releasing Pyre

This document covers the **one-time setup** of release signing and the
**per-version** process for shipping a build.

> ⚠ **The signing keystore is forever.** Once you publish an APK to a
> store or to users, every future update has to be signed by the same
> key. If you lose it, you lose the install base. Back it up to two
> places before pushing the first release.

---

## One-time: generate the upload keystore

Run this once, on the machine that will produce release builds. The
generated `.jks` file is the *only* copy — guard it like a password
manager export.

```bash
keytool -genkey -v \
  -keystore upload-keystore.jks \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias pyre-upload
```

It will prompt for:

- A keystore password (used to open the file)
- A key password (often the same)
- Your name, org, locality — used for the certificate

Pick strong, distinct passwords and write them down somewhere
non-digital (passport, safe deposit). Losing the password is equivalent
to losing the keystore.

### Where to put the keystore

```text
flutter_app/android/app/upload-keystore.jks   ← the .jks itself
```

This path is gitignored (`*.jks` in `.gitignore`).

### Create `android/key.properties`

This file points the Gradle build at the keystore. It is also
gitignored. Create it manually:

```properties
storePassword=YOUR_STORE_PASSWORD
keyPassword=YOUR_KEY_PASSWORD
keyAlias=pyre-upload
storeFile=upload-keystore.jks
```

If `key.properties` is missing, the build silently falls back to debug
signing so contributors can still `flutter run --release` without
needing the secret. Production builds require it.

### Back it up

Make at least two off-site copies of:

1. `upload-keystore.jks`
2. The keystore password
3. The key password
4. The key alias

E.g.: encrypted USB stick in a drawer, plus an encrypted archive in
cloud storage. Don't keep them in the same place.

---

## Per-version: cut a release build

1. **Bump the version** in `pubspec.yaml`:

   ```yaml
   version: 1.1.0+5
   ```

   Format is `MAJOR.MINOR.PATCH+BUILD_NUMBER`. Play Store / Android
   uses `BUILD_NUMBER` (versionCode) for "is this newer?" comparisons,
   so it MUST increase every release even if the MAJOR.MINOR.PATCH
   doesn't.

2. **Run the smoke test** in `docs/SMOKE_TEST.md`. All boxes ticked.

3. **Clean + build:**

   ```bash
   flutter clean
   flutter pub get
   flutter build apk --release
   # for Play Store, prefer App Bundle:
   flutter build appbundle --release
   ```

   Outputs:
   - APK: `build/app/outputs/flutter-apk/app-release.apk`
   - AAB: `build/app/outputs/bundle/release/app-release.aab`

4. **Verify the APK is signed with the upload key:**

   ```bash
   keytool -printcert -jarfile build/app/outputs/flutter-apk/app-release.apk
   # MD5 / SHA1 should match what you got out of upload-keystore.jks.
   ```

   If it says "debug", `key.properties` wasn't picked up — check the
   file is at `android/key.properties` (not `android/app/`), and that
   each line matches the keys the gradle script looks for.

5. **Tag the release** in git:

   ```bash
   git tag -a v1.1.0 -m "Pyre 1.1.0"
   git push origin v1.1.0
   ```

6. **Upload.** Play Store → Internal testing → promote when ready.
   Sideload distribution → host the APK on botbooru.com.

---

## Play Store specifics

Pyre positions itself as a **chat client** ("AI Roleplay Frontend",
following Tavo / SillyTavern positioning). Tavo is on the Play Store
with the same posture, so we can be too.

The honest framing for the store listing:

- "An interface for chatting with AI providers you configure"
- "Brings character cards from SillyTavern / botbooru / Chub"
- "No content hosted, generated, or moderated by us"
- "Bring your own API key"

The Data Safety section answers:

- **Data collected:** None.
- **Data shared:** None.
- **Data stored locally:** Chat history, character cards, settings (the
  user can export and wipe at any time via in-app Backup & Restore).
- **Encryption in transit:** Yes (HTTPS to user-chosen provider).
- **Encryption at rest:** API keys yes (OS keystore); content no (app
  sandbox file).

Content rating: select "Mature 17+" or equivalent — characters /
prompts can produce adult themes via the user's chosen provider.

---

## Sideload distribution

For users who want the APK directly:

1. Host `app-release.apk` at a stable URL — GitHub Releases is the
   simplest option (one tag, attach the APK, done).
2. Publish a SHA256 alongside it so users can verify.
3. Document the install for sideloaders (Settings → Unknown sources).
   Or link to the Play Store version if available.

Sideloaded APKs don't auto-update. Consider adding an in-app version
check that polls a JSON manifest at the release host for a newer
`versionCode` and surfaces a banner. (Not implemented yet.)

---

## Rotating a leaked key (worst-case)

If the upload key is ever compromised, on Play Store you can request
**Play App Signing key reset** — Google then re-signs new uploads with
a different upload key while keeping the user-facing app signing key
the same. This is the main reason to opt into Play App Signing.

For sideload distribution there is no recovery. A leaked key means
attackers can sign malicious updates and trick users into installing
them. Treat the keystore accordingly.
