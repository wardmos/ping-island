#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/dmg-layout.sh"

BUILD_DIR="$PROJECT_DIR/build/unsigned"
DERIVED_DATA_PATH="$BUILD_DIR/DerivedData"
STAGING_DIR="$BUILD_DIR/dmg-staging"
RELEASE_DIR="$PROJECT_DIR/releases/unsigned"
DMG_BACKGROUND_SOURCE="${PING_ISLAND_DMG_BACKGROUND_SOURCE:-$PROJECT_DIR/docs/images/ping-island-dmg-installer-background.png}"
DMG_LOGO_SOURCE="${PING_ISLAND_DMG_LOGO_SOURCE:-$PROJECT_DIR/docs/images/ping-island-icon-transparent.svg}"
PACKAGE_SUFFIX="${PING_ISLAND_PACKAGE_SUFFIX:-}"
DMG_STYLE="${PING_ISLAND_DMG_STYLE:-styled}"
BUNDLED_REMOTE_BRIDGE_DIR="${PING_ISLAND_BUNDLED_REMOTE_BRIDGE_DIR:-$PROJECT_DIR/releases/bridge}"

APP_BUNDLE_NAME="Ping Island.app"
APP_PRODUCT_NAME="PingIsland"
SCHEME="PingIsland"
PROJECT_FILE="$PROJECT_DIR/PingIsland.xcodeproj"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/$APP_BUNDLE_NAME"
BUILD_MODE_LABEL="release"

echo "=== Packaging Unsigned Ping Island ==="
echo ""

resolve_exported_app_icon() {
    local requested_icon_source="${PING_ISLAND_DMG_ICON_SOURCE:-}"
    local bundled_icon_path="$APP_PATH/Contents/Resources/AppIcon.icns"

    if [ -n "$requested_icon_source" ]; then
        echo "$requested_icon_source"
        return 0
    fi

    if [ -f "$bundled_icon_path" ]; then
        echo "$bundled_icon_path"
        return 0
    fi

    echo "$PROJECT_DIR/PingIsland/Assets.xcassets/AppIcon.appiconset/icon_1024x1024.png"
}

resolve_dmg_icon_source() {
    if [ -f "$DMG_LOGO_SOURCE" ]; then
        echo "$DMG_LOGO_SOURCE"
        return 0
    fi

    resolve_exported_app_icon
}

embed_remote_bridge_assets() {
    local source_dir="$1"
    local resources_dir="$APP_PATH/Contents/Resources/RemoteBridge"
    local scratch_dir="$BUILD_DIR/remote-bridge-extract"
    local copied=0

    if [ ! -d "$source_dir" ]; then
        echo "No bundled remote bridge directory found at $source_dir; skipping."
        return 0
    fi

    shopt -s nullglob
    local bridge_sources=(
        "$source_dir"/PingIslandBridge-linux-musl-*
    )
    shopt -u nullglob

    if [ "${#bridge_sources[@]}" -eq 0 ]; then
        echo "No Linux remote bridge assets found in $source_dir; skipping."
        return 0
    fi

    rm -rf "$resources_dir" "$scratch_dir"
    mkdir -p "$resources_dir" "$scratch_dir"

    for bridge_source in "${bridge_sources[@]}"; do
        local base_name
        base_name="$(basename "$bridge_source")"
        local binary_name="${base_name%.zip}"

        if [[ "$bridge_source" == *.zip ]]; then
            local extract_dir="$scratch_dir/$binary_name"
            mkdir -p "$extract_dir"
            ditto -x -k "$bridge_source" "$extract_dir"
            if [ ! -f "$extract_dir/$binary_name" ]; then
                echo "ERROR: Expected $binary_name inside $bridge_source"
                exit 1
            fi
            cp "$extract_dir/$binary_name" "$resources_dir/$binary_name"
        else
            cp "$bridge_source" "$resources_dir/$binary_name"
        fi

        chmod 755 "$resources_dir/$binary_name"
        copied=$((copied + 1))
    done

    rm -rf "$scratch_dir"
    echo "Embedded $copied Linux remote bridge asset(s) into $resources_dir"
}

if [ ! -f "$DMG_BACKGROUND_SOURCE" ]; then
    echo "ERROR: DMG background image not found at $DMG_BACKGROUND_SOURCE"
    exit 1
fi

export PING_ISLAND_DMG_BACKGROUND_SOURCE="$DMG_BACKGROUND_SOURCE"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$RELEASE_DIR"

echo "Building Release app with ad-hoc signing..."
if ! xcodebuild \
    -project "$PROJECT_FILE" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    CODE_SIGN_IDENTITY=- \
    COMPILER_INDEX_STORE_ENABLE="${COMPILER_INDEX_STORE_ENABLE:-YES}" \
    build; then
    echo ""
    echo "Release optimizer crashed. Retrying with stable compiler settings..."
    rm -rf "$DERIVED_DATA_PATH"

    xcodebuild \
        -project "$PROJECT_FILE" \
        -scheme "$SCHEME" \
        -configuration Release \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        CODE_SIGN_IDENTITY=- \
        COMPILER_INDEX_STORE_ENABLE="${COMPILER_INDEX_STORE_ENABLE:-YES}" \
        SWIFT_OPTIMIZATION_LEVEL=-Onone \
        SWIFT_COMPILATION_MODE=singlefile \
        build

    BUILD_MODE_LABEL="release-safe"
fi

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: App bundle not found at $APP_PATH"
    exit 1
fi

embed_remote_bridge_assets "$BUNDLED_REMOTE_BRIDGE_DIR"

DMG_ICON_SOURCE="$(resolve_dmg_icon_source)"
if [ ! -f "$DMG_ICON_SOURCE" ]; then
    echo "ERROR: DMG icon image not found at $DMG_ICON_SOURCE"
    exit 1
fi

export PING_ISLAND_DMG_ICON_SOURCE="$DMG_ICON_SOURCE"

echo ""
echo "Re-signing app bundle with a consistent ad-hoc signature..."
# Do not preserve the original signing flags here. Keeping the release build's
# hardened runtime flags on an ad-hoc unsigned app has produced Sparkle load
# failures on downloaded DMGs.
codesign \
    --force \
    --deep \
    --sign - \
    --preserve-metadata=identifier,entitlements \
    "$APP_PATH"

echo "Verifying app bundle signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")

DMG_PATH="$RELEASE_DIR/$APP_PRODUCT_NAME-$VERSION-$BUILD_MODE_LABEL-unsigned$PACKAGE_SUFFIX.dmg"

rm -f "$DMG_PATH"
rm -rf "$STAGING_DIR"

echo "Creating DMG..."
if [ "$DMG_STYLE" = "plain" ]; then
    rm -rf "$STAGING_DIR"
    mkdir -p "$STAGING_DIR"
    cp -R "$APP_PATH" "$STAGING_DIR/"
    ln -s /Applications "$STAGING_DIR/Applications"
    hdiutil create \
        -volname "Ping Island" \
        -srcfolder "$STAGING_DIR" \
        -format UDZO \
        -ov \
        "$DMG_PATH" >/dev/null
    rm -rf "$STAGING_DIR"
else
    create_styled_dmg "$APP_PATH" "$DMG_PATH" "Ping Island" "$STAGING_DIR" "$PROJECT_DIR"
fi

echo ""
echo "=== Unsigned Package Ready ==="
echo "Version: $VERSION ($BUILD)"
echo "Build mode: $BUILD_MODE_LABEL"
echo "DMG style: $DMG_STYLE"
echo "App: $APP_PATH"
echo "DMG: $DMG_PATH"
echo ""
echo "Note: This build is for local testing only."
echo "Note: It is ad-hoc signed and not notarized, so macOS may require right-click Open or quarantine removal on first launch."
