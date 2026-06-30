# Signing & notarizing VectorLabel

This project ships a **Developer ID**-signed, **notarized** macOS app (distributed
outside the App Store). CI builds and tests every push; pushing a version tag
(`vX.Y.Z`) runs `.github/workflows/release.yml`, which signs, notarizes, staples,
and attaches a guided **`.pkg` installer** plus a `.zip` + `.dmg` to a GitHub
Release.

You only need to do the one-time setup below. **None of these secrets are ever
shared with anyone — you add them directly in GitHub.**

---

## One-time setup

### 1. Apple Developer account
You need a paid **Apple Developer Program** membership ($99/yr). Your **Team ID** is
in <https://developer.apple.com/account> → Membership.

### 2. Create the signing certificates
You need **two** Developer ID certs for distribution outside the App Store:
- **Developer ID Application** — signs the four `.app` bundles.
- **Developer ID Installer** — signs the `.pkg` installer.

1. In **Xcode → Settings → Accounts**, add your Apple ID, select your team, click
   **Manage Certificates → +**, and create **both**: *Developer ID Application*
   **and** *Developer ID Installer*. (Or create them at
   <https://developer.apple.com/account/resources/certificates>.)
2. In **Keychain Access** (login keychain → *My Certificates*), ⌘-click to select
   **both** *Developer ID Application: …* and *Developer ID Installer: …*,
   right-click → **Export 2 items…**, save as one `.p12`, set a password.
   (Both certs in a single `.p12` means CI imports them in one step.)
3. Base64-encode it for GitHub:
   ```sh
   base64 -i Certificates.p12 | pbcopy
   ```
4. Note the exact identity strings:
   ```sh
   security find-identity -v
   # → "Developer ID Application: Your Name (TEAMID)"   → DEVELOPER_ID_IDENTITY
   # → "Developer ID Installer: Your Name (TEAMID)"     → DEVELOPER_ID_INSTALLER_IDENTITY
   ```

### 3. Create an App Store Connect API key (for notarization)
1. <https://appstoreconnect.apple.com/access/integrations/api> → **Keys** → **+**.
   Give it the **Developer** role (sufficient for notarization). Download the
   `AuthKey_XXXXXXXXXX.p8` (you can only download it once).
2. Note the **Key ID** (e.g. `ABC123DE45`) and the **Issuer ID** (a UUID at the top
   of the Keys page).
3. Base64-encode the key:
   ```sh
   base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy
   ```

### 4. Add the GitHub repo Secrets
Repo → **Settings → Secrets and variables → Actions → New repository secret**:

| Secret | Value |
|---|---|
| `DEVELOPER_ID_CERT_P12_BASE64` | base64 of the `.p12` holding both certs (step 2.3) |
| `DEVELOPER_ID_CERT_PASSWORD` | the `.p12` export password (step 2.2) |
| `DEVELOPER_ID_IDENTITY` | `Developer ID Application: Your Name (TEAMID)` (step 2.4) |
| `DEVELOPER_ID_INSTALLER_IDENTITY` | `Developer ID Installer: Your Name (TEAMID)` (step 2.4) |
| `KEYCHAIN_PASSWORD` | any random string (CI's temporary keychain password) |
| `NOTARY_API_KEY_P8_BASE64` | base64 of the `.p8` key (step 3.3) |
| `NOTARY_API_KEY_ID` | the Key ID (step 3.2) |
| `NOTARY_API_ISSUER_ID` | the Issuer ID (step 3.2) |

---

## Cutting a release
```sh
# bump the version, update CHANGELOG.md "Unreleased" → the new version
vim VERSION            # e.g. 1.2.0
git commit -am "Release 1.2.0"
git tag -a v1.2.0 -m "v1.2.0"
git push origin main --tags
```
The tag push triggers the release workflow. When it finishes, the signed/notarized
`.zip` and `.dmg` are on the repo's **Releases** page. Verify on a Mac:
```sh
spctl --assess --type execute -vv /Applications/VectorLabel.app   # → "accepted, source=Notarized Developer ID"
```

## Building a signed app locally (optional)
With the certificate installed in your login keychain:
```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/package-suite.sh
# then notarize:
ditto -c -k --keepParent dist/VectorLabel.app dist/VectorLabel.zip
xcrun notarytool submit dist/VectorLabel.zip --key AuthKey_XXXX.p8 \
  --key-id ABC123DE45 --issuer <ISSUER-UUID> --wait
xcrun stapler staple dist/VectorLabel.app
```
A plain `scripts/package-suite.sh` (no `SIGN_IDENTITY`) produces an **ad-hoc** signed
bundle that runs on your machine but is **not distributable**.

## Building the installer locally (optional)
After packaging the suite, build the guided `.pkg` wizard:
```sh
scripts/package-suite.sh                       # → dist/VectorLabel/ (the 4 apps)
scripts/build-installer.sh                     # → dist/VectorLabel-Installer-<ver>.pkg (unsigned)
# signed installer (needs the Developer ID Installer cert in your keychain):
DEVELOPER_ID_INSTALLER_IDENTITY="Developer ID Installer: Your Name (TEAMID)" \
  scripts/build-installer.sh
```
The installer UI lives in `installer/` (`distribution.xml` + the `resources/*.html`
panes). An **unsigned** `.pkg` installs fine after a right-click → **Open**; signed
+ notarized installers come from the release workflow. Verify a signed one with:
```sh
spctl --assess --type install -vv dist/VectorLabel-Installer-*.pkg   # → "accepted, source=Notarized Developer ID"
```

## Notes
- **libusb is bundled** inside the app (`Contents/Frameworks`) and signed with your
  Developer ID, so the app runs on machines without Homebrew. `package-suite.sh`
  rewrites its load path and re-signs (Apple Silicon refuses an unsigned binary).
- **Hardened runtime** is required for notarization and is enabled at signing time;
  the app is not sandboxed (it needs raw USB + `~/Documents` access).
- If notarization is rejected, fetch the log:
  `xcrun notarytool log <submission-id> --key … --key-id … --issuer …`.
