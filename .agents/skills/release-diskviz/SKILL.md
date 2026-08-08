---
name: release-diskviz
description: Prepare, sign, notarize, validate, tag, publish, resume, or verify a DiskViz macOS release. Use when cutting a DiskViz version, checking release prerequisites, configuring local notarization, creating release artifacts, or publishing a GitHub Release.
---

# Release DiskViz

Use the repository's `script/release.sh` as the only release implementation. Keep signing and notarization local; never recreate its fragile commands ad hoc.

## Workflow

1. Work from the DiskViz repository on a clean `main` that exactly matches `origin/main`.
2. Run `./script/release.sh doctor`.
3. If the notary profile is missing, stop and ask the user to run `./script/release.sh setup-notary` in an interactive terminal. Never request or place an app-specific password in chat, an environment file, a command argument, or the repository.
4. If GitHub release immutability is disabled, explain its consequence and run `./script/release.sh enable-immutable-releases` only with the user's approval.
5. Review commits since the latest stable tag and select the next stable `X.Y.Z` version. Do not reuse or decrease a version.
6. Run `./script/release.sh prepare X.Y.Z`. This may submit to Apple's notary service, but it must not create a Git tag or GitHub Release.
7. Inspect `release-artifacts/vX.Y.Z/release-manifest.json`, `SHA256SUMS`, the app signature, and the notary result. Report the version, commit, team, architectures, notary ID, and checksum.
8. Obtain explicit user confirmation before any public mutation.
9. Run `./script/release.sh publish X.Y.Z` in an interactive terminal. Honor both confirmations; do not script around them.
10. If publication is interrupted after the release becomes public, rerun `./script/release.sh publish X.Y.Z` or `./script/release.sh verify X.Y.Z`; both resume post-publication verification without rewriting the release.
11. Report the immutable GitHub Release URL only after the script verifies the GitHub attestation, exact asset set, and every local asset.

## Non-negotiable safety rules

- Require `Developer ID Application: Valentina Halasi (22YY6H28G3)` with the pinned certificate fingerprint. Never fall back to an Apple Development, Apple Distribution, ad-hoc, or Max Gfeller identity.
- Require a universal `arm64` and `x86_64` build, hardened runtime, secure timestamp, accepted notarization, stapled ticket, Gatekeeper checks, and exact checksum match.
- Never add a skip-signing, skip-notarization, allow-dirty, overwrite, clobber, or tag-deletion path.
- Never publish from `dist/` or from `script/build_and_run.sh`; those are development artifacts.
- Never delete or rewrite a tag, release, asset, prepared archive, or notarization diagnostic. If a published immutable release is wrong, prepare a new version.
- If tag push or draft upload partially succeeds, rerun `publish` only after verifying the existing tag commit and draft asset digests. The script resumes compatible state and fails closed on mismatches.
- Treat the Developer ID certificate expiry on February 1, 2027 as an operational deadline; renew and deliberately update the pinned fingerprints before then.
