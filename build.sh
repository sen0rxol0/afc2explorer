#!/usr/bin/env bash
# =============================================================================
# build.sh – Bootstrap dependencies and build AFC2Explorer.app
#
# Run from the project root (same directory as AFC2Explorer.xcodeproj).
#
# Usage:
#   ./build.sh                  # Debug build
#   ./build.sh --release        # Release build
#   ./build.sh --clean          # Clean, then Debug build
#   ./build.sh --clean --release
#   ./build.sh --help
#
# Output: build/Debug/AFC2Explorer.app  (or build/Release/)
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
BLU='\033[0;34m'; CYN='\033[0;36m'; RST='\033[0m'

info()    { echo -e "${BLU}[INFO]${RST}  $*"; }
success() { echo -e "${GRN}[OK]${RST}    $*"; }
warn()    { echo -e "${YLW}[WARN]${RST}  $*"; }
error()   { echo -e "${RED}[ERROR]${RST} $*" >&2; }
step()    { echo -e "\n${CYN}━━━  $*  ━━━${RST}"; }

# ── Defaults ──────────────────────────────────────────────────────────────────
CONFIGURATION="Debug"
DO_CLEAN=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$ROOT/AFC2Explorer.xcodeproj"
SCHEME="AFC2Explorer"
BUILD_DIR="$ROOT/build"
FRAMEWORKS_DIR="$ROOT/Frameworks"

for arg in "$@"; do
    case "$arg" in
        --release) CONFIGURATION="Release" ;;
        --clean)   DO_CLEAN=1 ;;
        --help)
            echo "Usage: $0 [--release] [--clean] [--help]"
            exit 0 ;;
        *) error "Unknown argument: $arg"; exit 1 ;;
    esac
done

APP_OUT="$BUILD_DIR/$CONFIGURATION/AFC2Explorer.app"

# =============================================================================
# 1. SYSTEM CHECKS
# =============================================================================
step "System checks"

OS_VER=$(sw_vers -productVersion)
info "macOS $OS_VER"

if ! command -v xcodebuild &>/dev/null; then
    error "xcodebuild not found. Install Xcode from the App Store."
    exit 1
fi
info "$(xcodebuild -version 2>/dev/null | head -1)"

DEVDIR=$(xcode-select -p 2>/dev/null || true)
[[ -z "$DEVDIR" ]] && { error "No active Xcode developer dir. Run: sudo xcode-select --switch /Applications/Xcode.app"; exit 1; }
info "Developer dir: $DEVDIR"

[[ ! -d "$PROJECT" ]] && { error "Project not found: $PROJECT"; exit 1; }

success "System checks passed"

# =============================================================================
# 2. HOMEBREW
# =============================================================================
step "Homebrew"

if ! command -v brew &>/dev/null; then
    error "Homebrew not found. Install from https://brew.sh then re-run."
    exit 1
fi
BREW_PREFIX=$(brew --prefix)
info "$(brew --version | head -1) at $BREW_PREFIX"
success "Homebrew OK"

# =============================================================================
# 3. DEPENDENCIES
# =============================================================================
step "Dependencies"

REQUIRED_FORMULAE=(libplist libusbmuxd libimobiledevice usbmuxd pkg-config)
MISSING_FORMULAE=()

for formula in "${REQUIRED_FORMULAE[@]}"; do
    if brew list --formula "$formula" &>/dev/null; then
        VER=$(brew list --versions "$formula" | awk '{print $2}')
        info "$formula $VER"
    else
        MISSING_FORMULAE+=("$formula")
        warn "$formula – not installed"
    fi
done

if [[ ${#MISSING_FORMULAE[@]} -gt 0 ]]; then
    info "Installing: ${MISSING_FORMULAE[*]}"
    brew install "${MISSING_FORMULAE[@]}"
fi

OUTDATED=$(brew outdated --formula "${REQUIRED_FORMULAE[@]}" 2>/dev/null || true)
if [[ -n "$OUTDATED" ]]; then
    warn "Outdated formulae (run 'brew upgrade' to update):"
    while IFS= read -r line; do warn "  $line"; done <<< "$OUTDATED"
fi

success "Dependencies OK"

# =============================================================================
# 4. STAGE DYLIBS → Frameworks/
# =============================================================================
step "Staging dylibs"

mkdir -p "$FRAMEWORKS_DIR"

declare -A DYLIB_MAP=(
    [libplist-2.0]="libplist-2.0.dylib"
    [libusbmuxd-2.0]="libusbmuxd-2.0.dylib"
    [libimobiledevice-1.0]="libimobiledevice-1.0.dylib"
)

MISSING_DYLIBS=()
STAGED=0

for base in "${!DYLIB_MAP[@]}"; do
    NAME="${DYLIB_MAP[$base]}"
    SRC="$BREW_PREFIX/lib/$NAME"
    DST="$FRAMEWORKS_DIR/$NAME"

    if [[ ! -f "$SRC" ]]; then
        PKG_LIBDIR=$(pkg-config --variable=libdir "$base" 2>/dev/null || true)
        SRC="${PKG_LIBDIR}/${NAME}"
    fi

    if [[ -f "$SRC" ]]; then
        if [[ ! -f "$DST" ]] || ! cmp -s "$SRC" "$DST"; then
            cp -f "$SRC" "$DST"
            info "Staged: $NAME"
            ((STAGED++)) || true
        else
            info "Up-to-date: $NAME"
        fi
    else
        MISSING_DYLIBS+=("$NAME")
    fi
done

[[ ${#MISSING_DYLIBS[@]} -gt 0 ]] && {
    error "Could not locate: ${MISSING_DYLIBS[*]}"
    error "Try: brew reinstall libplist libusbmuxd libimobiledevice"
    exit 1
}

info "Fixing dylib install names..."
for base in "${!DYLIB_MAP[@]}"; do
    NAME="${DYLIB_MAP[$base]}"
    DST="$FRAMEWORKS_DIR/$NAME"
    [[ -f "$DST" ]] || continue

    install_name_tool -id "@executable_path/../Frameworks/$NAME" "$DST" 2>/dev/null \
        || warn "install_name_tool -id failed for $NAME (non-fatal)"

    for other_base in "${!DYLIB_MAP[@]}"; do
        [[ "$other_base" == "$base" ]] && continue
        OTHER="${DYLIB_MAP[$other_base]}"
        OLD="$BREW_PREFIX/lib/$OTHER"
        NEW="@executable_path/../Frameworks/$OTHER"
        if otool -L "$DST" 2>/dev/null | grep -q "$OLD"; then
            install_name_tool -change "$OLD" "$NEW" "$DST" 2>/dev/null || true
            info "  Rewrote $OTHER ref in $NAME"
        fi
    done
done

success "Dylibs staged ($STAGED updated)"

# =============================================================================
# 5. HEADER VERIFICATION
# =============================================================================
step "Header verification"

HDR_ERRORS=0
for hdr in \
    "libimobiledevice/libimobiledevice.h" \
    "libimobiledevice/lockdown.h" \
    "libimobiledevice/afc.h" \
    "plist/plist.h"; do
    if [[ -f "$BREW_PREFIX/include/$hdr" ]] || [[ -f "/usr/local/include/$hdr" ]]; then
        info "Found: $hdr"
    else
        error "Missing: $hdr"
        ((HDR_ERRORS++)) || true
    fi
done

[[ $HDR_ERRORS -gt 0 ]] && {
    error "$HDR_ERRORS header(s) missing. Try: brew reinstall libimobiledevice libplist"
    exit 1
}
success "All headers found"

# =============================================================================
# 6. USBMUXD CHECK  (non-blocking)
# =============================================================================
step "usbmuxd"
if pgrep -x usbmuxd &>/dev/null; then
    info "usbmuxd is running"
else
    warn "usbmuxd is NOT running – start before connecting a device: sudo usbmuxd -f"
fi

# =============================================================================
# 7. CLEAN  (optional)
# =============================================================================
if [[ $DO_CLEAN -eq 1 ]]; then
    step "Clean"
    [[ -d "$BUILD_DIR" ]] && { info "Removing $BUILD_DIR"; rm -rf "$BUILD_DIR"; }
    xcodebuild clean \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        CODE_SIGNING_ALLOWED=NO \
        2>&1 | grep -E "^(Build|error:|warning:)" | head -20 || true
    success "Clean complete"
fi

# =============================================================================
# 8. BUILD
# =============================================================================
step "Build ($CONFIGURATION)"

mkdir -p "$BUILD_DIR"

BUILD_LOG="$BUILD_DIR/build.log"
info "Output:    $APP_OUT"
info "Build log: $BUILD_LOG"

if command -v xcpretty &>/dev/null; then
    FORMATTER="xcpretty"
else
    warn "xcpretty not found – using raw output. Install: gem install xcpretty"
    FORMATTER="cat"
fi

set +e
xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    CONFIGURATION_BUILD_DIR="$BUILD_DIR/$CONFIGURATION" \
    MACOSX_DEPLOYMENT_TARGET=10.15 \
    HEADER_SEARCH_PATHS="\"$ROOT\" \"$BREW_PREFIX/include\" /usr/local/include" \
    OTHER_LDFLAGS="-L$FRAMEWORKS_DIR -limobiledevice-1.0 -lusbmuxd-2.0 -lplist-2.0" \
    LD_RUNPATH_SEARCH_PATHS="@executable_path/../Frameworks" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGN_IDENTITY="" \
    2>&1 | tee "$BUILD_LOG" | $FORMATTER

BUILD_EXIT=${PIPESTATUS[0]}
set -e

# =============================================================================
# 9. RESULT
# =============================================================================
step "Result"

if [[ $BUILD_EXIT -ne 0 ]]; then
    error "Build FAILED (exit $BUILD_EXIT)"
    echo ""
    error "Last 50 lines of build log:"
    echo "──────────────────────────────────────────────────"
    tail -50 "$BUILD_LOG"
    echo "──────────────────────────────────────────────────"
    error "Full log: $BUILD_LOG"
    exit $BUILD_EXIT
fi

[[ ! -d "$APP_OUT" ]] && {
    error "Build succeeded but .app not found at $APP_OUT"
    exit 1
}

APP_SIZE=$(du -sh "$APP_OUT" | cut -f1)
echo ""
echo -e "${GRN}┌─────────────────────────────────────────────────┐${RST}"
echo -e "${GRN}│  BUILD SUCCEEDED                                │${RST}"
printf  "${GRN}│${RST}  App    : %-37s ${GRN}│${RST}\n" "$(basename "$APP_OUT")"
printf  "${GRN}│${RST}  Config : %-37s ${GRN}│${RST}\n" "$CONFIGURATION"
printf  "${GRN}│${RST}  Size   : %-37s ${GRN}│${RST}\n" "$APP_SIZE"
echo -e "${GRN}└─────────────────────────────────────────────────┘${RST}"
echo ""
info "Run: open \"$APP_OUT\""
info "To sign and notarize, see README.md § Notarization Checklist."
