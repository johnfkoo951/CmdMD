# Signing & Notarizing CmdMD releases

CmdMD currently ships **ad-hoc signed** — Gatekeeper shows an "unidentified
developer / cannot be checked" warning on first launch (workaround: right-click →
Open, or `xattr -dr com.apple.quarantine`). To remove that warning entirely, the
app must be **Developer ID signed + notarized by Apple**.

The release pipeline is already wired for this: `scripts/sign_and_notarize.sh`
runs automatically on a tag **only when the signing secrets below exist**. Until
then, releases stay ad-hoc and nothing changes.

---

## 1. Enroll in the Apple Developer Program (Individual)

1. Go to https://developer.apple.com/programs/enroll/ and sign in with the Apple
   ID you want to own the developer account. It must have **two-factor auth** on.
2. Choose **Individual / Sole Proprietor** (no D-U-N-S number needed).
3. Confirm your legal name + address, agree to the license, pay **$99/year**.
4. Approval is usually within 24–48h (email confirmation). You can verify at
   https://developer.apple.com/account — the membership shows your **Team ID**
   (10 chars, e.g. `A1B2C3D4E5`). Note it.

## 2. Create the "Developer ID Application" certificate

Easiest via Xcode:

1. Xcode → Settings → **Accounts** → add your Apple ID → select the team →
   **Manage Certificates…** → **+** → **Developer ID Application**.
2. It lands in your login keychain. Export it for CI: **Keychain Access** →
   *My Certificates* → right-click the "Developer ID Application: …" entry →
   **Export** → save as `cert.p12`, set a strong password (this becomes
   `MACOS_CERTIFICATE_PWD`).

The certificate's full name is your `MACOS_SIGN_IDENTITY`, e.g.
`Developer ID Application: Yohan Koo (A1B2C3D4E5)`. Find it with:

```bash
security find-identity -v -p codesigning
```

## 3. Create an app-specific password (for notarytool)

1. https://account.apple.com → **Sign-In and Security** → **App-Specific Passwords**
   → generate one (label it "CmdMD notarytool"). This is `MACOS_NOTARY_PASSWORD`.

## 4. Add the secrets to GitHub

Repo → **Settings → Secrets and variables → Actions → New repository secret**.
Add all six:

| Secret | Value |
|---|---|
| `MACOS_CERTIFICATE` | base64 of `cert.p12` → `base64 -i cert.p12 \| pbcopy` |
| `MACOS_CERTIFICATE_PWD` | the `.p12` export password |
| `MACOS_SIGN_IDENTITY` | `Developer ID Application: <Name> (<TEAMID>)` |
| `MACOS_NOTARY_APPLE_ID` | your Apple ID email |
| `MACOS_NOTARY_PASSWORD` | the app-specific password from step 3 |
| `MACOS_NOTARY_TEAM_ID` | your 10-char Team ID |

Once `MACOS_CERTIFICATE` and `MACOS_NOTARY_APPLE_ID` are set, the next `v*` tag
automatically signs, notarizes, and staples — no warning for end users.

## 5. (Optional) sign + notarize locally

```bash
bash scripts/package_app.sh          # builds dist/CmdMD.app (ad-hoc)
export MACOS_CERTIFICATE_PWD=… MACOS_SIGN_IDENTITY=… \
       MACOS_NOTARY_APPLE_ID=… MACOS_NOTARY_PASSWORD=… MACOS_NOTARY_TEAM_ID=…
export MACOS_CERTIFICATE="$(base64 -i cert.p12)"
bash scripts/sign_and_notarize.sh    # → notarized, stapled dmg + zip
```

Verify the result:

```bash
spctl -a -vvv -t install dist/CmdMD-*.dmg     # should say "accepted / Notarized Developer ID"
xcrun stapler validate dist/CmdMD-*.dmg
```

---

### Notes
- Hardened Runtime is enabled at sign time (`--options runtime`), required for
  notarization. CmdMD needs no special entitlements — WKWebView runs JS in its
  own Apple-signed process, so no JIT entitlement on the main app.
- The cert expires (~5 years) but notarized builds keep working; re-export only
  when you rotate it.
- Keep `cert.p12` and its password out of the repo — they live only in GitHub
  Secrets / your keychain.
