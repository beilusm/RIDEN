# Release process

`VERSION` is the single source of truth for the release number.

- Current release: `2.0.0` (Git tag `v2.0.0`).
- Next release: increment the last component, `2.0.1`, then `2.0.2`.
- A patch of a release appends a revision: `2.0.0-1`, then `2.0.0-2`.
- After `2.0.0-2`, the next new release is `2.0.1`, without the suffix.
- Revision suffixes denote stable patches, not prereleases. Do not reuse published tags.

Change `VERSION`, add `docs/releases/<version>.md` if custom notes are needed, commit, then push a matching `v<version>` tag. The Compose Build workflow checks the version, tests and builds all three platforms, verifies the APK signature, and publishes only after all build jobs pass. All five packages and `SHA256SUMS.txt` are attached to the release. Manual workflow dispatch on a release tag can retry a failed build.

Windows portable ZIP and MSI include the Java runtime. Extract the ZIP and run `RIDEN/RIDEN.exe`, or install the MSI. Windows builds run on GitHub Actions Windows Server 2022; this does not replace testing the serial connection on a physical Windows PC.

## Internal version numbers

MSI requires a numeric version, so its internal version is `major.minor.(patch * 100 + revision)`: `2.0.0` -> `2.0.0`, `2.0.0-1` -> `2.0.1`, `2.0.1` -> `2.0.100`. The user-facing release, tag, Android version name and download filenames always use `VERSION` unchanged. The MSI upgrade UUID is stable across releases.

Android `versionCode` is `major * 10000000 + minor * 100000 + patch * 100 + revision`, so revisions and following releases increase monotonically. Supported components: major 1-99, minor 0-99, patch 0-655, revision 1-99; the MSI build component must not exceed 65535. Building validates these bounds.

## Android signing

Release builds require a persistent signing key. Debug keys are not used for published APKs. Configure repository secrets:

- `RIDEN_KEYSTORE_BASE64`: base64-encoded release keystore.
- `RIDEN_KEYSTORE_PASSWORD`
- `RIDEN_KEY_ALIAS`
- `RIDEN_KEY_PASSWORD`

Local builds accept the corresponding environment variables; use `RIDEN_KEYSTORE_FILE` for the keystore path. Alternatively, `~/.android/riden-release-signing.json` can contain `storeFile`, `storePassword`, `keyAlias`, `keyPassword`. Keep that file and the keystore private and backed up outside the repository. Signing credentials must never be committed or included in artifacts.

```bash
./gradlew :composeApp:assembleRelease
```

The 2.0 Android application ID is `io.github.beilusm.ridenps`. The Flutter 1.x ID was `com.ridenps.riden_power_supply`, so 2.0 installs separately. An earlier 2.0 Debug install uses a different signature and must be uninstalled before installing the release APK; export recordings first.
