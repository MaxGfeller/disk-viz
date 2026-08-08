#!/usr/bin/env bash
set -euo pipefail

umask 022

APP_NAME="DiskViz"
BUNDLE_ID="com.disk-viz.app"
TEAM_ID="22YY6H28G3"
SIGNING_IDENTITY="Developer ID Application: Valentina Halasi (22YY6H28G3)"
SIGNING_SHA1="223553E4C90FBC6F5637E52AA804B85C664F81FC"
SIGNING_SHA256="F8:DF:AB:B5:22:8C:CC:DA:8E:25:F7:60:DC:2E:58:D0:CE:06:5C:35:30:67:0F:63:E5:44:6B:1F:19:B5:60:4D"
NOTARY_PROFILE="${DISKVIZ_NOTARY_PROFILE:-DiskViz-notary-22YY6H28G3}"
GITHUB_REPOSITORY="MaxGfeller/disk-viz"
GITHUB_API_VERSION="2026-03-10"
MINIMUM_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_ROOT="$ROOT_DIR/release-artifacts"
INFO_PLIST_TEMPLATE="$ROOT_DIR/release/Info.plist"
APP_ICON="$ROOT_DIR/assets/icon.icns"
WORK_DIR=""
WORK_DIR_OWNED="no"

note() {
  printf '%s\n' "$*"
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage:
  ./script/release.sh doctor
  ./script/release.sh setup-notary
  ./script/release.sh enable-immutable-releases
  ./script/release.sh prepare X.Y.Z
  ./script/release.sh publish X.Y.Z
  ./script/release.sh verify X.Y.Z

Commands:
  doctor                     Validate tools, GitHub, signing, notarization, and
                             immutable-release configuration without changing them.
  setup-notary               Store Team 22YY6H28G3 credentials interactively in
                             Keychain. The app-specific password is never passed as
                             a command-line argument.
  enable-immutable-releases  Enable GitHub's repository release immutability after
                             an explicit confirmation.
  prepare X.Y.Z              Test, build universal binaries locally, sign, notarize,
                             staple, verify, and create canonical release artifacts.
  publish X.Y.Z              Reverify prepared artifacts, create and push a local
                             annotated tag, upload a draft, verify digests, and
                             publish after a second explicit confirmation.
  verify X.Y.Z               Reverify a published immutable release, its tag,
                             attestation, assets, and matching local artifacts.

Environment:
  DISKVIZ_NOTARY_PROFILE     Override the Keychain profile name. Defaults to
                             DiskViz-notary-22YY6H28G3.
USAGE
}

cleanup() {
  if [[ "$WORK_DIR_OWNED" == "yes" && -n "$WORK_DIR" && -d "$WORK_DIR" && \
    "$(basename "$WORK_DIR")" == diskviz-release.* ]]; then
    /bin/rm -rf -- "$WORK_DIR"
  fi
}

trap cleanup EXIT

make_work_dir() {
  local temporary_base
  temporary_base="${TMPDIR:-/tmp}"
  temporary_base="${temporary_base%/}"
  WORK_DIR="$(mktemp -d "$temporary_base/diskviz-release.XXXXXX")"
  WORK_DIR_OWNED="yes"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_tools() {
  local command_name
  for command_name in git gh swift xcrun security openssl codesign syspolicy_check \
    spctl lipo ditto plutil shasum xattr otool sort; do
    require_command "$command_name"
  done
  [[ -x /usr/libexec/PlistBuddy ]] || die "required command not found: /usr/libexec/PlistBuddy"
}

require_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || die "DiskViz releases must be prepared on macOS"
}

require_repository() {
  local remote_url github_name
  [[ -d "$ROOT_DIR/.git" ]] || die "run this command from the DiskViz Git repository"

  remote_url="$(git -C "$ROOT_DIR" remote get-url origin)"
  case "$remote_url" in
    git@github.com:MaxGfeller/disk-viz.git|https://github.com/MaxGfeller/disk-viz.git|ssh://git@github.com/MaxGfeller/disk-viz.git)
      ;;
    *)
      die "origin is not the expected repository: $remote_url"
      ;;
  esac

  gh auth status --hostname github.com >/dev/null
  github_name="$(gh repo view "$GITHUB_REPOSITORY" --json nameWithOwner --jq .nameWithOwner)"
  [[ "$github_name" == "$GITHUB_REPOSITORY" ]] || die "GitHub CLI resolved the wrong repository: $github_name"
  gh release verify --help >/dev/null
  gh release verify-asset --help >/dev/null
  gh release view --help | grep -Fq isImmutable || die "GitHub CLI is too old for immutable release verification"
}

require_signing_identity() {
  local identities certificate fingerprint
  identities="$(security find-identity -v -p codesigning)"
  printf '%s\n' "$identities" | grep -Fq "$SIGNING_SHA1 \"$SIGNING_IDENTITY\"" || \
    die "the exact Valentina Developer ID identity is unavailable in Keychain"

  certificate="$(security find-certificate -c "$SIGNING_IDENTITY" -p)"
  [[ -n "$certificate" ]] || die "the Valentina Developer ID certificate could not be read"
  fingerprint="$(printf '%s\n' "$certificate" | openssl x509 -noout -fingerprint -sha256 | sed 's/^.*=//')"
  [[ "$fingerprint" == "$SIGNING_SHA256" ]] || \
    die "the signing certificate fingerprint changed; expected $SIGNING_SHA256, got $fingerprint"

  printf '%s\n' "$certificate" | openssl x509 -checkend 0 -noout >/dev/null || \
    die "the Valentina Developer ID certificate has expired"
  if ! printf '%s\n' "$certificate" | openssl x509 -checkend 2592000 -noout >/dev/null; then
    warn "the Valentina Developer ID certificate expires within 30 days"
  fi
}

notary_credentials_work() {
  xcrun notarytool history \
    --keychain-profile "$NOTARY_PROFILE" \
    --output-format json >/dev/null 2>&1
}

immutable_releases_enabled() {
  [[ "$(gh api \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: $GITHUB_API_VERSION" \
    "repos/$GITHUB_REPOSITORY/immutable-releases" \
    --jq .enabled 2>/dev/null || true)" == "true" ]]
}

doctor() {
  require_macos
  require_tools
  require_repository
  require_signing_identity
  [[ -f "$INFO_PLIST_TEMPLATE" ]] || die "missing release Info.plist template"
  [[ -f "$APP_ICON" ]] || die "missing app icon: $APP_ICON"

  notary_credentials_work || die "notary profile '$NOTARY_PROFILE' is missing or invalid; run ./script/release.sh setup-notary"
  immutable_releases_enabled || die "GitHub immutable releases are disabled; run ./script/release.sh enable-immutable-releases"

  note "Release prerequisites are ready."
  note "  GitHub:  $GITHUB_REPOSITORY"
  note "  Signer:  $SIGNING_IDENTITY"
  note "  Team:    $TEAM_ID"
  note "  Notary:  $NOTARY_PROFILE"
}

setup_notary() {
  local apple_id
  require_macos
  require_command xcrun
  require_command security
  require_signing_identity

  if notary_credentials_work; then
    note "Notary profile '$NOTARY_PROFILE' is already valid."
    return
  fi

  [[ -t 0 ]] || die "setup-notary requires an interactive terminal"
  printf 'Apple ID for Team %s: ' "$TEAM_ID"
  IFS= read -r apple_id
  [[ -n "$apple_id" ]] || die "Apple ID cannot be empty"

  note "notarytool will securely prompt for the app-specific password."
  xcrun notarytool store-credentials "$NOTARY_PROFILE" \
    --apple-id "$apple_id" \
    --team-id "$TEAM_ID"

  notary_credentials_work || die "the stored profile could not access Team $TEAM_ID"
  note "Stored and validated Keychain profile '$NOTARY_PROFILE'."
}

enable_immutable_releases() {
  local response
  require_tools
  require_repository

  if immutable_releases_enabled; then
    note "GitHub immutable releases are already enabled."
    return
  fi

  [[ -t 0 ]] || die "enabling immutable releases requires an interactive terminal"
  note "Published releases, their tags, and assets will become immutable."
  note "Corrections will require a new version."
  printf 'Type ENABLE to continue: '
  IFS= read -r response
  [[ "$response" == "ENABLE" ]] || die "immutable releases were not enabled"

  gh api --method PUT \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: $GITHUB_API_VERSION" \
    "repos/$GITHUB_REPOSITORY/immutable-releases" >/dev/null
  immutable_releases_enabled || die "GitHub did not report immutable releases as enabled"
  note "GitHub immutable releases are enabled for $GITHUB_REPOSITORY."
}

normalize_version() {
  local version="${1:-}"
  [[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || \
    die "version must be stable semantic version X.Y.Z without leading zeros"
  printf '%s\n' "$version"
}

version_is_greater() {
  local candidate="$1" previous="$2"
  local candidate_major candidate_minor candidate_patch
  local previous_major previous_minor previous_patch
  IFS=. read -r candidate_major candidate_minor candidate_patch <<<"$candidate"
  IFS=. read -r previous_major previous_minor previous_patch <<<"$previous"

  if [[ "$candidate_major" != "$previous_major" ]]; then
    numeric_component_is_greater "$candidate_major" "$previous_major"
  elif [[ "$candidate_minor" != "$previous_minor" ]]; then
    numeric_component_is_greater "$candidate_minor" "$previous_minor"
  elif [[ "$candidate_patch" != "$previous_patch" ]]; then
    numeric_component_is_greater "$candidate_patch" "$previous_patch"
  else
    return 1
  fi
}

numeric_component_is_greater() {
  local candidate="$1" previous="$2"
  if (( ${#candidate} != ${#previous} )); then
    (( ${#candidate} > ${#previous} ))
  else
    [[ "$candidate" > "$previous" ]]
  fi
}

latest_stable_version() {
  local candidate
  while IFS= read -r candidate; do
    if [[ "$candidate" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
      printf '%s\n' "${candidate#v}"
      return
    fi
  done < <(git -C "$ROOT_DIR" tag --list 'v*' --sort=-version:refname)
}

require_clean_pushed_main() {
  local branch head remote_head
  [[ -z "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=normal)" ]] || \
    die "the worktree must be clean before preparing or publishing a release"
  branch="$(git -C "$ROOT_DIR" branch --show-current)"
  [[ "$branch" == "main" ]] || die "releases must be prepared from main, not '$branch'"

  git -C "$ROOT_DIR" fetch --quiet origin main --tags
  head="$(git -C "$ROOT_DIR" rev-parse HEAD)"
  remote_head="$(git -C "$ROOT_DIR" rev-parse origin/main)"
  [[ "$head" == "$remote_head" ]] || die "HEAD must exactly match origin/main"
}

remote_tag_commit() {
  local tag="$1" tag_ref peeled_ref
  tag_ref="$(git -C "$ROOT_DIR" ls-remote --tags origin "refs/tags/$tag" | awk 'NR == 1 {print $1}')"
  peeled_ref="$(git -C "$ROOT_DIR" ls-remote --tags origin "refs/tags/$tag^{}" | awk 'NR == 1 {print $1}')"
  if [[ -n "$peeled_ref" ]]; then
    printf '%s\n' "$peeled_ref"
  elif [[ -n "$tag_ref" ]]; then
    die "remote tag $tag is lightweight; releases require an annotated tag"
  fi
}

prepare_version_available() {
  local version="$1" tag="v$1" latest remote_tag
  [[ ! -e "$RELEASE_ROOT/$tag" ]] || die "release output already exists: $RELEASE_ROOT/$tag"
  ! git -C "$ROOT_DIR" rev-parse -q --verify "refs/tags/$tag" >/dev/null || die "local tag already exists: $tag"

  remote_tag="$(remote_tag_commit "$tag")"
  [[ -z "$remote_tag" ]] || die "remote tag already exists: $tag"
  ! gh release view "$tag" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1 || die "GitHub release already exists: $tag"

  latest="$(latest_stable_version)"
  if [[ -n "$latest" ]]; then
    version_is_greater "$version" "$latest" || die "version $version must be greater than existing version $latest"
  fi
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1"
}

manifest_value() {
  plutil -extract "$2" raw -o - "$1"
}

validate_signed_app() {
  local app_bundle="$1" expect_staple="$2"
  local details entitlements info_plist executable version bundle_version

  info_plist="$app_bundle/Contents/Info.plist"
  executable="$app_bundle/Contents/MacOS/$APP_NAME"
  [[ -f "$info_plist" && -x "$executable" ]] || die "invalid app bundle layout: $app_bundle"
  plutil -lint "$info_plist" >/dev/null

  codesign --verify --deep --strict --verbose=2 "$app_bundle"
  details="$(codesign --display --verbose=4 "$app_bundle" 2>&1)"
  printf '%s\n' "$details" | grep -Fq "Authority=$SIGNING_IDENTITY" || die "unexpected signing authority"
  printf '%s\n' "$details" | grep -Fq "TeamIdentifier=$TEAM_ID" || die "unexpected signing team"
  printf '%s\n' "$details" | grep -Fq "Identifier=$BUNDLE_ID" || die "unexpected bundle identifier in signature"
  printf '%s\n' "$details" | grep -Eq 'flags=.*runtime' || die "hardened runtime is not enabled"
  printf '%s\n' "$details" | grep -Eq '^Timestamp=.+' || die "secure timestamp is missing"
  ! printf '%s\n' "$details" | grep -Fq 'Timestamp=none' || die "secure timestamp is missing"

  entitlements="$(codesign --display --entitlements :- "$app_bundle" 2>&1 || true)"
  if printf '%s\n' "$entitlements" | grep -Eq \
    'com\.apple\.security\.get-task-allow|com\.apple\.security\.cs\.allow-jit|com\.apple\.security\.cs\.allow-unsigned-executable-memory|com\.apple\.security\.cs\.disable-library-validation|com\.apple\.security\.cs\.allow-dyld-environment-variables'; then
    die "release signature contains a forbidden entitlement"
  fi

  lipo "$executable" -verify_arch arm64 x86_64
  version="$(plist_value "$info_plist" CFBundleShortVersionString)"
  bundle_version="$(plist_value "$info_plist" CFBundleVersion)"
  normalize_version "$version" >/dev/null
  [[ "$bundle_version" =~ ^[1-9][0-9]*$ ]] || die "CFBundleVersion is not a positive integer"

  if [[ "$expect_staple" == "yes" ]]; then
    xcrun stapler validate -v "$app_bundle"
    syspolicy_check distribution "$app_bundle" --verbose
    spctl --assess --type execute --verbose=4 "$app_bundle"
  else
    validate_notary_readiness "$app_bundle"
  fi
}

validate_notary_readiness() {
  local app_bundle="$1" policy_output assessment_output
  local error_count short_error long_error advice
  if policy_output="$(syspolicy_check notary-submission "$app_bundle" --json 2>/dev/null)"; then
    return
  fi

  assessment_output="$(spctl --assess --type execute --verbose=4 "$app_bundle" 2>&1 || true)"
  error_count="$(printf '%s' "$policy_output" | plutil -extract output raw -o - - 2>/dev/null || true)"
  short_error="$(printf '%s' "$policy_output" | plutil -extract output.0.SyspolicyCheckShortError raw -o - - 2>/dev/null || true)"
  long_error="$(printf '%s' "$policy_output" | plutil -extract output.0.SyspolicyCheckLongError raw -o - - 2>/dev/null || true)"
  advice="$(printf '%s' "$policy_output" | plutil -extract output.0.SyspolicyCheckAdvice raw -o - - 2>/dev/null || true)"

  if [[ "$error_count" == "1" && "$short_error" == "Codesign Error" && -z "$advice" ]] && \
    [[ "$long_error" == Gatekeeper\ rejected\ this\ file.* ]] && \
    printf '%s\n' "$assessment_output" | grep -Fq 'source=Unnotarized Developer ID'; then
    warn "syspolicy_check returned the generic unnotarized Gatekeeper result on this macOS version"
    warn "continuing because strict Developer ID checks passed and notarytool preflight remains mandatory"
    return
  fi

  printf '%s\n' "$policy_output" >&2
  printf '%s\n' "$assessment_output" >&2
  die "the app failed notarization readiness checks"
}

preserve_notary_failure() {
  local tag="$1" result_file="$2" submission_id="${3:-}"
  local failure_dir
  mkdir -p "$RELEASE_ROOT"
  failure_dir="$(mktemp -d "$RELEASE_ROOT/${tag}.failed.XXXXXX")"
  cp "$result_file" "$failure_dir/notary-submission.json"
  if [[ -n "$submission_id" ]]; then
    xcrun notarytool log "$submission_id" \
      --keychain-profile "$NOTARY_PROFILE" \
      "$failure_dir/notary-log.json" >/dev/null 2>&1 || true
  fi
  warn "notarization diagnostics were preserved at $failure_dir"
}

write_manifest() {
  local output="$1" version="$2" tag="$3" commit="$4" build_number="$5"
  local artifact_name="$6" artifact_sha="$7" submission_id="$8"
  local plist_file="$WORK_DIR/release-manifest.plist"

  plutil -create xml1 "$plist_file"
  plutil -insert schemaVersion -integer 1 "$plist_file"
  plutil -insert version -string "$version" "$plist_file"
  plutil -insert tag -string "$tag" "$plist_file"
  plutil -insert commit -string "$commit" "$plist_file"
  plutil -insert bundleIdentifier -string "$BUNDLE_ID" "$plist_file"
  plutil -insert bundleVersion -string "$build_number" "$plist_file"
  plutil -insert minimumSystemVersion -string "$MINIMUM_SYSTEM_VERSION" "$plist_file"
  plutil -insert teamIdentifier -string "$TEAM_ID" "$plist_file"
  plutil -insert signingIdentity -string "$SIGNING_IDENTITY" "$plist_file"
  plutil -insert signingCertificateSHA1 -string "$SIGNING_SHA1" "$plist_file"
  plutil -insert signingCertificateSHA256 -string "$SIGNING_SHA256" "$plist_file"
  plutil -insert architectures -json '["arm64","x86_64"]' "$plist_file"
  plutil -insert notarySubmissionId -string "$submission_id" "$plist_file"
  plutil -insert artifact -string "$artifact_name" "$plist_file"
  plutil -insert artifactSHA256 -string "$artifact_sha" "$plist_file"
  plutil -insert preparedAt -string "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$plist_file"
  plutil -convert json -o "$output" "$plist_file"
}

prepare_release() {
  local version tag commit build_number release_dir app_bundle app_contents app_binary
  local arm_scratch x86_scratch sdk_path arm_bin_path x86_bin_path notary_zip
  local notary_result notary_status submission_id artifact_name artifact_path artifact_sha

  version="$(normalize_version "${1:-}")"
  tag="v$version"
  doctor
  require_clean_pushed_main
  prepare_version_available "$version"
  make_work_dir

  commit="$(git -C "$ROOT_DIR" rev-parse HEAD)"
  build_number="$(git -C "$ROOT_DIR" rev-list --count HEAD)"
  [[ "$build_number" =~ ^[1-9][0-9]*$ ]] || die "could not derive a numeric build number"

  note "Running tests..."
  swift test --package-path "$ROOT_DIR"

  sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
  arm_scratch="$WORK_DIR/build-arm64"
  x86_scratch="$WORK_DIR/build-x86_64"

  note "Building arm64 release binary..."
  swift build --package-path "$ROOT_DIR" --configuration release \
    --scratch-path "$arm_scratch" --triple arm64-apple-macosx14.0 --sdk "$sdk_path"
  arm_bin_path="$(swift build --package-path "$ROOT_DIR" --configuration release \
    --scratch-path "$arm_scratch" --triple arm64-apple-macosx14.0 --sdk "$sdk_path" \
    --show-bin-path)/$APP_NAME"

  note "Building x86_64 release binary..."
  swift build --package-path "$ROOT_DIR" --configuration release \
    --scratch-path "$x86_scratch" --triple x86_64-apple-macosx14.0 --sdk "$sdk_path"
  x86_bin_path="$(swift build --package-path "$ROOT_DIR" --configuration release \
    --scratch-path "$x86_scratch" --triple x86_64-apple-macosx14.0 --sdk "$sdk_path" \
    --show-bin-path)/$APP_NAME"

  [[ -x "$arm_bin_path" && -x "$x86_bin_path" ]] || die "release binaries were not produced"

  app_bundle="$WORK_DIR/$APP_NAME.app"
  app_contents="$app_bundle/Contents"
  app_binary="$app_contents/MacOS/$APP_NAME"
  mkdir -p "$app_contents/MacOS" "$app_contents/Resources"
  lipo -create "$arm_bin_path" "$x86_bin_path" -output "$app_binary"
  chmod 755 "$app_binary"
  cp "$INFO_PLIST_TEMPLATE" "$app_contents/Info.plist"
  cp "$APP_ICON" "$app_contents/Resources/icon.icns"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app_contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app_contents/Info.plist"
  plutil -lint "$app_contents/Info.plist" >/dev/null
  xattr -cr "$app_bundle"

  note "Signing with $SIGNING_IDENTITY..."
  codesign --force --sign "$SIGNING_SHA1" --timestamp --options runtime "$app_bundle"
  validate_signed_app "$app_bundle" no

  notary_zip="$WORK_DIR/$APP_NAME-notarization.zip"
  ditto -c -k --keepParent "$app_bundle" "$notary_zip"
  notary_result="$WORK_DIR/notary-submission.json"

  note "Submitting to Apple's notary service..."
  if ! xcrun notarytool submit "$notary_zip" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait --timeout 30m --output-format json >"$notary_result"; then
    submission_id="$(plutil -extract id raw -o - "$notary_result" 2>/dev/null || true)"
    preserve_notary_failure "$tag" "$notary_result" "$submission_id"
    die "notarization did not complete successfully"
  fi

  notary_status="$(plutil -extract status raw -o - "$notary_result" 2>/dev/null || true)"
  submission_id="$(plutil -extract id raw -o - "$notary_result" 2>/dev/null || true)"
  if [[ "$notary_status" != "Accepted" || -z "$submission_id" ]]; then
    preserve_notary_failure "$tag" "$notary_result" "$submission_id"
    die "notarization status was '${notary_status:-unknown}', not Accepted"
  fi

  xcrun stapler staple -v "$app_bundle"
  validate_signed_app "$app_bundle" yes

  release_dir="$RELEASE_ROOT/$tag"
  [[ ! -e "$release_dir" ]] || die "release output appeared during preparation: $release_dir"
  mkdir -p "$release_dir"
  artifact_name="$APP_NAME-$tag-macOS-universal.zip"
  artifact_path="$release_dir/$artifact_name"
  ditto -c -k --keepParent "$app_bundle" "$artifact_path"
  cp "$notary_result" "$release_dir/notary-submission.json"

  mkdir -p "$WORK_DIR/extracted"
  ditto -x -k "$artifact_path" "$WORK_DIR/extracted"
  validate_signed_app "$WORK_DIR/extracted/$APP_NAME.app" yes
  [[ "$(plist_value "$WORK_DIR/extracted/$APP_NAME.app/Contents/Info.plist" CFBundleShortVersionString)" == "$version" ]] || \
    die "version changed during packaging"

  artifact_sha="$(sha256_file "$artifact_path")"
  (
    cd "$release_dir"
    printf '%s  %s\n' "$artifact_sha" "$artifact_name" >SHA256SUMS
  )
  write_manifest "$release_dir/release-manifest.json" "$version" "$tag" "$commit" \
    "$build_number" "$artifact_name" "$artifact_sha" "$submission_id"

  note "Prepared signed and notarized release locally:"
  note "  Directory: $release_dir"
  note "  Commit:    $commit"
  note "  Artifact:  $artifact_name"
  note "  SHA-256:   $artifact_sha"
  note "  Notary ID: $submission_id"
  note "No Git tag or GitHub Release was created."
}

verify_prepared_release() {
  local version="$1" tag="$2" release_dir="$3" manifest="$4"
  local artifact_name artifact_path expected_sha actual_sha manifest_version manifest_tag
  local manifest_commit manifest_team manifest_signer manifest_signer_sha256
  local manifest_bundle manifest_submission_id expected_artifact extracted_app

  [[ -f "$manifest" ]] || die "missing release manifest: $manifest"
  manifest_version="$(manifest_value "$manifest" version)"
  manifest_tag="$(manifest_value "$manifest" tag)"
  manifest_commit="$(manifest_value "$manifest" commit)"
  manifest_team="$(manifest_value "$manifest" teamIdentifier)"
  manifest_signer="$(manifest_value "$manifest" signingCertificateSHA1)"
  manifest_signer_sha256="$(manifest_value "$manifest" signingCertificateSHA256)"
  manifest_bundle="$(manifest_value "$manifest" bundleIdentifier)"
  manifest_submission_id="$(manifest_value "$manifest" notarySubmissionId)"
  artifact_name="$(manifest_value "$manifest" artifact)"
  expected_sha="$(manifest_value "$manifest" artifactSHA256)"
  artifact_path="$release_dir/$artifact_name"
  expected_artifact="$APP_NAME-$tag-macOS-universal.zip"

  [[ "$manifest_version" == "$version" && "$manifest_tag" == "$tag" ]] || die "manifest version does not match $tag"
  [[ "$manifest_commit" =~ ^[0-9a-f]{40}$ ]] || die "manifest commit is not a full Git commit SHA"
  git -C "$ROOT_DIR" cat-file -e "$manifest_commit^{commit}" 2>/dev/null || die "manifest commit is unavailable in the local repository"
  [[ "$manifest_team" == "$TEAM_ID" && "$manifest_signer" == "$SIGNING_SHA1" ]] || die "manifest signer does not match the pinned identity"
  [[ "$manifest_signer_sha256" == "$SIGNING_SHA256" ]] || die "manifest signing fingerprint does not match"
  [[ "$manifest_bundle" == "$BUNDLE_ID" ]] || die "manifest bundle identifier does not match"
  [[ -n "$manifest_submission_id" ]] || die "manifest is missing the notary submission ID"
  [[ "$artifact_name" == "$expected_artifact" ]] || die "manifest contains an unexpected artifact name"
  [[ -f "$artifact_path" && -f "$release_dir/SHA256SUMS" ]] || die "prepared release assets are incomplete"

  actual_sha="$(sha256_file "$artifact_path")"
  [[ "$actual_sha" == "$expected_sha" ]] || die "prepared ZIP checksum does not match its manifest"
  (cd "$release_dir" && shasum -a 256 -c SHA256SUMS)

  make_work_dir
  mkdir -p "$WORK_DIR/extracted"
  ditto -x -k "$artifact_path" "$WORK_DIR/extracted"
  extracted_app="$WORK_DIR/extracted/$APP_NAME.app"
  validate_signed_app "$extracted_app" yes
  [[ "$(plist_value "$extracted_app/Contents/Info.plist" CFBundleShortVersionString)" == "$version" ]] || \
    die "prepared app version does not match $version"
}

local_tag_commit() {
  local tag="$1"
  if git -C "$ROOT_DIR" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    [[ "$(git -C "$ROOT_DIR" cat-file -t "$tag")" == "tag" ]] || \
      die "local tag $tag is lightweight; releases require an annotated tag"
    git -C "$ROOT_DIR" rev-list -n 1 "$tag"
  fi
}

ensure_asset_uploaded() {
  local tag="$1" asset_path="$2" asset_name local_digest remote_digest
  asset_name="$(basename "$asset_path")"
  local_digest="sha256:$(sha256_file "$asset_path")"
  remote_digest="$(gh api "repos/$GITHUB_REPOSITORY/releases/tags/$tag" \
    --jq ".assets[] | select(.name == \"$asset_name\") | .digest" 2>/dev/null || true)"

  if [[ -z "$remote_digest" ]]; then
    gh release upload "$tag" "$asset_path" --repo "$GITHUB_REPOSITORY"
    remote_digest="$(gh api "repos/$GITHUB_REPOSITORY/releases/tags/$tag" \
      --jq ".assets[] | select(.name == \"$asset_name\") | .digest")"
  fi

  [[ "$remote_digest" == "$local_digest" ]] || \
    die "GitHub asset digest mismatch for $asset_name: expected $local_digest, got ${remote_digest:-missing}"
}

require_exact_remote_assets() {
  local tag="$1" release_dir="$2" manifest="$3"
  local artifact_name expected_names actual_names
  artifact_name="$(manifest_value "$manifest" artifact)"
  expected_names="$(printf '%s\n' "$artifact_name" SHA256SUMS release-manifest.json | LC_ALL=C sort)"
  actual_names="$(gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json assets \
    --jq '.assets[].name' | LC_ALL=C sort)"
  [[ "$actual_names" == "$expected_names" ]] || die "GitHub release assets are not the exact expected set"

  verify_remote_asset_digest "$tag" "$release_dir/$artifact_name"
  verify_remote_asset_digest "$tag" "$release_dir/SHA256SUMS"
  verify_remote_asset_digest "$tag" "$manifest"
}

verify_remote_asset_digest() {
  local tag="$1" asset_path="$2" asset_name local_digest remote_digest
  asset_name="$(basename "$asset_path")"
  local_digest="sha256:$(sha256_file "$asset_path")"
  remote_digest="$(gh api "repos/$GITHUB_REPOSITORY/releases/tags/$tag" \
    --jq ".assets[] | select(.name == \"$asset_name\") | .digest")"
  [[ "$remote_digest" == "$local_digest" ]] || \
    die "GitHub asset digest mismatch for $asset_name: expected $local_digest, got ${remote_digest:-missing}"
}

require_release_metadata() {
  local tag="$1" expected_draft="$2"
  local release_name release_tag draft_state prerelease_state
  release_name="$(gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json name --jq .name)"
  release_tag="$(gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json tagName --jq .tagName)"
  draft_state="$(gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json isDraft --jq .isDraft)"
  prerelease_state="$(gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json isPrerelease --jq .isPrerelease)"
  [[ "$release_name" == "$APP_NAME $tag" ]] || die "GitHub release title does not match '$APP_NAME $tag'"
  [[ "$release_tag" == "$tag" ]] || die "GitHub release tag metadata does not match $tag"
  [[ "$draft_state" == "$expected_draft" ]] || die "GitHub release draft state changed unexpectedly"
  [[ "$prerelease_state" == "false" ]] || die "stable release is unexpectedly marked as a prerelease"
}

verify_published_github_release() {
  local tag="$1" release_dir="$2" manifest="$3"
  local artifact_name artifact_path commit remote_commit immutable_state release_url
  artifact_name="$(manifest_value "$manifest" artifact)"
  artifact_path="$release_dir/$artifact_name"
  commit="$(manifest_value "$manifest" commit)"
  remote_commit="$(remote_tag_commit "$tag")"
  [[ "$remote_commit" == "$commit" ]] || die "remote tag $tag points to a different commit"

  require_release_metadata "$tag" false
  immutable_state="$(gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json isImmutable --jq .isImmutable)"
  [[ "$immutable_state" == "true" ]] || die "published GitHub release is not immutable"
  require_exact_remote_assets "$tag" "$release_dir" "$manifest"

  gh release verify "$tag" --repo "$GITHUB_REPOSITORY" >/dev/null
  gh release verify-asset "$tag" "$artifact_path" --repo "$GITHUB_REPOSITORY" >/dev/null
  gh release verify-asset "$tag" "$release_dir/SHA256SUMS" --repo "$GITHUB_REPOSITORY" >/dev/null
  gh release verify-asset "$tag" "$manifest" --repo "$GITHUB_REPOSITORY" >/dev/null

  release_url="$(gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json url --jq .url)"
  note "Verified immutable release: $release_url"
}

publish_release() {
  local version tag release_dir manifest artifact_name artifact_path commit
  local response local_commit remote_commit release_state immutable_state

  version="$(normalize_version "${1:-}")"
  tag="v$version"
  release_dir="$RELEASE_ROOT/$tag"
  manifest="$release_dir/release-manifest.json"
  doctor
  require_clean_pushed_main
  verify_prepared_release "$version" "$tag" "$release_dir" "$manifest"

  artifact_name="$(manifest_value "$manifest" artifact)"
  artifact_path="$release_dir/$artifact_name"
  commit="$(manifest_value "$manifest" commit)"

  if gh release view "$tag" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
    release_state="$(gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json isDraft --jq .isDraft)"
    if [[ "$release_state" == "false" ]]; then
      note "Release $tag is already published; resuming post-publication verification."
      verify_published_github_release "$tag" "$release_dir" "$manifest"
      return
    fi
  fi

  [[ -t 0 ]] || die "publish requires an interactive terminal"
  note "Ready to publish an immutable GitHub Release:"
  note "  Version:  $tag"
  note "  Commit:   $commit"
  note "  Signer:   $SIGNING_IDENTITY"
  note "  Artifact: $artifact_name"
  note "  SHA-256:  $(manifest_value "$manifest" artifactSHA256)"
  printf 'Type %s to create/push the tag and draft: ' "$tag"
  IFS= read -r response
  [[ "$response" == "$tag" ]] || die "publication was cancelled"

  local_commit="$(local_tag_commit "$tag")"
  if [[ -z "$local_commit" ]]; then
    git -C "$ROOT_DIR" tag -a "$tag" "$commit" -m "$APP_NAME $tag"
    local_commit="$commit"
  fi
  [[ "$local_commit" == "$commit" ]] || die "local tag $tag points to a different commit"

  remote_commit="$(remote_tag_commit "$tag")"
  if [[ -z "$remote_commit" ]]; then
    git -C "$ROOT_DIR" push origin "refs/tags/$tag"
    remote_commit="$(remote_tag_commit "$tag")"
  fi
  [[ "$remote_commit" == "$commit" ]] || die "remote tag $tag points to a different commit"

  if gh release view "$tag" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
    release_state="$(gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json isDraft --jq .isDraft)"
    [[ "$release_state" == "true" ]] || die "GitHub release $tag is already published"
  else
    gh release create "$tag" --repo "$GITHUB_REPOSITORY" \
      --draft --verify-tag --fail-on-no-commits --generate-notes --title "$APP_NAME $tag"
  fi

  ensure_asset_uploaded "$tag" "$artifact_path"
  ensure_asset_uploaded "$tag" "$release_dir/SHA256SUMS"
  ensure_asset_uploaded "$tag" "$manifest"
  require_release_metadata "$tag" true
  require_exact_remote_assets "$tag" "$release_dir" "$manifest"

  note "Draft tag and all asset digests are verified."
  gh release view "$tag" --repo "$GITHUB_REPOSITORY"
  note "Publishing now makes this release, its tag, and its assets immutable."
  printf 'Type PUBLISH to publish %s: ' "$tag"
  IFS= read -r response
  [[ "$response" == "PUBLISH" ]] || die "draft retained; release was not published"

  remote_commit="$(remote_tag_commit "$tag")"
  [[ "$remote_commit" == "$commit" ]] || die "remote tag changed while awaiting confirmation"
  require_release_metadata "$tag" true
  require_exact_remote_assets "$tag" "$release_dir" "$manifest"

  gh release edit "$tag" --repo "$GITHUB_REPOSITORY" --draft=false --latest

  immutable_state=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    immutable_state="$(gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json isImmutable --jq .isImmutable)"
    [[ "$immutable_state" == "true" ]] && break
    sleep 2
  done
  [[ "$immutable_state" == "true" ]] || die "GitHub published the release but did not report it as immutable"

  verify_published_github_release "$tag" "$release_dir" "$manifest"
}

verify_release() {
  local version tag release_dir manifest
  version="$(normalize_version "${1:-}")"
  tag="v$version"
  release_dir="$RELEASE_ROOT/$tag"
  manifest="$release_dir/release-manifest.json"
  doctor
  require_clean_pushed_main
  verify_prepared_release "$version" "$tag" "$release_dir" "$manifest"
  gh release view "$tag" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1 || die "GitHub release does not exist: $tag"
  verify_published_github_release "$tag" "$release_dir" "$manifest"
}

main() {
  local command_name="${1:-}"
  case "$command_name" in
    doctor)
      [[ "$#" -eq 1 ]] || die "doctor takes no arguments"
      doctor
      ;;
    setup-notary)
      [[ "$#" -eq 1 ]] || die "setup-notary takes no arguments"
      setup_notary
      ;;
    enable-immutable-releases)
      [[ "$#" -eq 1 ]] || die "enable-immutable-releases takes no arguments"
      enable_immutable_releases
      ;;
    prepare)
      [[ "$#" -eq 2 ]] || die "prepare requires exactly one X.Y.Z version"
      prepare_release "$2"
      ;;
    publish)
      [[ "$#" -eq 2 ]] || die "publish requires exactly one X.Y.Z version"
      publish_release "$2"
      ;;
    verify)
      [[ "$#" -eq 2 ]] || die "verify requires exactly one X.Y.Z version"
      verify_release "$2"
      ;;
    -h|--help|help)
      [[ "$#" -eq 1 ]] || die "help takes no arguments"
      usage
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
