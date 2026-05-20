# One-time: create a stable self-signed code-signing cert

Ad-hoc signing (`codesign --sign -`) produces a new signature on every build,
so macOS keeps treating each rebuild as a brand-new app and revokes TCC
permissions (Screen Recording, Accessibility, etc.). A stable self-signed
cert fixes this for local development.

## Steps

1. Open **Keychain Access** (`/System/Applications/Utilities/Keychain Access.app`).
2. Menu: **Keychain Access → Certificate Assistant → Create a Certificate…**
3. Fill in:
   - **Name:** `ContextSnap Dev`  ← must match exactly; the build script greps for this string
   - **Identity Type:** Self Signed Root
   - **Certificate Type:** **Code Signing**
   - Leave "Let me override defaults" unchecked
4. Click **Create**, then **Done**. The cert lands in the *login* keychain.

## Verify

```sh
security find-identity -v -p codesigning | grep "ContextSnap Dev"
```

Should print one matching identity.

## Use

`Scripts/build-app.sh` auto-detects the cert. Re-run it and you'll see:

```
==> codesign with 'ContextSnap Dev'
```

From now on, granting Screen Recording once will persist across rebuilds.

## Remove (if you ever want to)

Delete the cert from Keychain Access — the build script will silently fall
back to ad-hoc signing.
