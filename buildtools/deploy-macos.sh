#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

# Release configuration. Values may be overridden in .env or the environment.
APP_NAME="${APP_NAME:-MaidKit}"
CASK_NAME="${CASK_NAME:-maidkit}"
RCLONE_REMOTE="${RCLONE_REMOTE:-r2}"
S3_BUCKET="${S3_BUCKET:-solsynth-files}"
S3_PREFIX="${S3_PREFIX:-maidkit}"
DOWNLOAD_BASE_URL="${DOWNLOAD_BASE_URL:-https://raw.solsynth.dev/maidkit}"
TAP_DIR="${TAP_DIR:-../homebrew-tap}"
PUBSPEC_FILE="$PROJECT_ROOT/pubspec.yaml"

if [[ -f "$PROJECT_ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$PROJECT_ROOT/.env"
  set +a

  # Re-read configurable values after loading .env.
  APP_NAME="${APP_NAME:-MaidKit}"
  CASK_NAME="${CASK_NAME:-maidkit}"
  RCLONE_REMOTE="${RCLONE_REMOTE:-r2}"
  S3_BUCKET="${S3_BUCKET:-solsynth-files}"
  S3_PREFIX="${S3_PREFIX:-maidkit}"
  DOWNLOAD_BASE_URL="${DOWNLOAD_BASE_URL:-https://raw.solsynth.dev/maidkit}"
  TAP_DIR="${TAP_DIR:-../homebrew-tap}"
fi

case "$TAP_DIR" in
  /*) ;;
  *) TAP_DIR="$PROJECT_ROOT/$TAP_DIR" ;;
esac

CASK_RELATIVE_PATH="Casks/$CASK_NAME.rb"
CASK_FILE="$TAP_DIR/$CASK_RELATIVE_PATH"
BUILD_DIR="$PROJECT_ROOT/build/macos/Build/Products/Release"
APP_PATH="$BUILD_DIR/$APP_NAME.app"
ARCHIVE_NAME="${CASK_NAME}-macos.tar.gz"
ARCHIVE_PATH="$PROJECT_ROOT/$ARCHIVE_NAME"
DOWNLOAD_URL="${DOWNLOAD_BASE_URL%/}/$ARCHIVE_NAME"
TEMP_ZIP=""

cleanup() {
  if [[ -n "$TEMP_ZIP" ]]; then
    rm -f "$TEMP_ZIP"
  fi
  rm -f "$ARCHIVE_PATH"
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage: ./buildtools/deploy-macos.sh [--no-build]

Builds, signs, notarizes, packages, uploads, and publishes the MaidKit
Homebrew cask. Use --no-build only when the release app already exists.

Configuration is read from the environment or the project .env file:
  DEVELOPER_ID, APPLE_ID, TEAM_ID, APP_PASSWORD
  TAP_DIR, RCLONE_REMOTE, S3_BUCKET, S3_PREFIX, DOWNLOAD_BASE_URL
EOF
}

SKIP_BUILD=false
for arg in "$@"; do
  case "$arg" in
    --no-build) SKIP_BUILD=true ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown argument: $arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done
if [[ ! -d "$TAP_DIR" ]]; then
  echo "Error: Homebrew tap checkout not found at $TAP_DIR" >&2
  echo "Clone Solsynth/homebrew-tap there or set TAP_DIR." >&2
  exit 1
fi
if ! git -C "$TAP_DIR" rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "Error: $TAP_DIR is not a Git repository." >&2
  exit 1
fi
if [[ ! -f "$CASK_FILE" ]]; then
  echo "Error: cask file not found at $CASK_FILE" >&2
  echo "Create Casks/$CASK_NAME.rb in Solsynth/homebrew-tap first." >&2
  exit 1
fi

if [[ ! -f "$PUBSPEC_FILE" ]]; then
  echo "Error: pubspec.yaml not found at $PUBSPEC_FILE" >&2
  exit 1
fi

FLUTTER_VERSION="$(awk '$1 == "version:" { print $2; exit }' "$PUBSPEC_FILE")"
if [[ -z "$FLUTTER_VERSION" ]]; then
  echo "Error: could not parse version from $PUBSPEC_FILE" >&2
  exit 1
fi
if [[ ! "$FLUTTER_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\+[0-9]+)?$ ]]; then
  echo "Error: unsupported Flutter version: $FLUTTER_VERSION" >&2
  exit 1
fi

HOMEBREW_VERSION="$(printf '%s' "$FLUTTER_VERSION" | tr '+' ',')"
echo "Found Flutter version: $FLUTTER_VERSION"
echo "Homebrew version: $HOMEBREW_VERSION"

if [[ -z "${DEVELOPER_ID:-}" || -z "${APPLE_ID:-}" || -z "${TEAM_ID:-}" || -z "${APP_PASSWORD:-}" ]]; then
  echo "Error: signing and notarization credentials are required." >&2
  echo "Required: DEVELOPER_ID, APPLE_ID, TEAM_ID, APP_PASSWORD" >&2
  exit 1
fi

for command_name in awk codesign ditto rclone shasum spctl tar xcrun; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Error: required command not found: $command_name" >&2
    exit 1
  fi
done

if [[ "$SKIP_BUILD" == false ]]; then
  echo "Building Flutter macOS app..."
  flutter pub get
  dart run build_runner build --delete-conflicting-outputs
  ./buildtools/flutter.sh build macos --release
else
  echo "Skipping build (--no-build flag detected)..."
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "Error: release app not found at $APP_PATH" >&2
  exit 1
fi

echo "Signing macOS app with Developer ID..."
codesign --deep --force --verbose \
  --sign "$DEVELOPER_ID" \
  --options runtime \
  --timestamp \
  "$APP_PATH"

echo "Verifying code signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

TEMP_ZIP="$PROJECT_ROOT/.${CASK_NAME}-notarization.zip"
rm -f "$TEMP_ZIP"
echo "Submitting app for notarization..."
ditto -c -k --keepParent "$APP_PATH" "$TEMP_ZIP"
xcrun notarytool submit "$TEMP_ZIP" \
  --apple-id "$APPLE_ID" \
  --team-id "$TEAM_ID" \
  --password "$APP_PASSWORD" \
  --wait

echo "Stapling notarization ticket..."
xcrun stapler staple "$APP_PATH"

echo "Running Gatekeeper verification..."
spctl -a -vvv "$APP_PATH"

echo "Packaging .app bundle into $ARCHIVE_NAME..."
tar -czf "$ARCHIVE_PATH" -C "$BUILD_DIR" "$APP_NAME.app"

SHA256="$(shasum -a 256 "$ARCHIVE_PATH" | awk '{ print $1 }')"
echo "SHA-256: $SHA256"

echo "Uploading archive to ${S3_BUCKET}/${S3_PREFIX}/ via rclone..."
rclone copyto "$ARCHIVE_PATH" "${RCLONE_REMOTE}:${S3_BUCKET}/${S3_PREFIX%/}/$ARCHIVE_NAME" --progress


echo "Updating $CASK_RELATIVE_PATH..."
sed -i '' -E "s|^([[:space:]]*)version \".*\"|\1version \"$HOMEBREW_VERSION\"|" "$CASK_FILE"
sed -i '' -E "s|^([[:space:]]*)sha256 .*|\1sha256 \"$SHA256\"|" "$CASK_FILE"
sed -i '' -E "s|^([[:space:]]*)url \".*\"|\1url \"$DOWNLOAD_URL\"|" "$CASK_FILE"

git -C "$TAP_DIR" add "$CASK_RELATIVE_PATH"
if git -C "$TAP_DIR" diff --cached --quiet -- "$CASK_RELATIVE_PATH"; then
  echo "Homebrew cask already points to $HOMEBREW_VERSION; nothing to commit."
else
  echo "Committing and pushing Homebrew tap update..."
  git -C "$TAP_DIR" commit -m "maidkit: release $FLUTTER_VERSION"
  git -C "$TAP_DIR" push
fi

echo "Done! brew upgrade --cask $CASK_NAME will fetch $HOMEBREW_VERSION."
