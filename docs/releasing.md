# Releasing

Push a version tag; `.github/workflows/release.yml` does the rest:

```bash
git tag v0.2.0 && git push origin v0.2.0
```

The workflow runs the tests, builds a universal app stamped with the tag's version, and signs it with the best identity it has: Developer ID Application, then Apple Development, then ad hoc. A Developer ID build also gets a signed, notarized, and stapled DMG. It then publishes a GitHub release with notes from `git log` and the DMG's SHA-256.

For stable versions, it updates `Casks/arin.rb` in [`sozercan/homebrew-repo`](https://github.com/sozercan/homebrew-repo), which installs the app and links the `arin` CLI. Tags with `-alpha`, `-beta`, `-rc`, or `-dev` become prereleases and leave the cask alone. Running the workflow by hand builds and notarizes without publishing anything.

| Secret | Used for |
|---|---|
| `MACOS_CERTIFICATE`, `MACOS_CERTIFICATE_PWD`, `MACOS_KEYCHAIN_PWD` | Base64 `.p12` signing identity, its password, and a password for the temporary keychain |
| `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID` | Notarization (required once a Developer ID certificate is configured) |
| `HOMEBREW_REPO_TOKEN` | Pushing the cask to the tap |

Without a Developer ID certificate, releases aren't notarized and Gatekeeper blocks the first launch; the cask clears the quarantine flag. Privacy permissions such as Full Disk Access are tied to the signature, so an ad-hoc build loses them on every update. Homebrew can only download releases from a public repository, so the workflow skips the cask update if the repository is private.
