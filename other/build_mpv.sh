#!/usr/bin/env bash
#
# build_mpv.sh — build a custom libmpv with PR #16818 (vo_libmpv 'gpu-next')
# cherry-picked, plus libplacebo statically linked with HDR / DV / HDR10+ support.
#
# Output: deps/lib/libmpv.X.dylib + transitive deps, deps/include/mpv/*.h.
# Uses other/change_lib_dependencies.rb to fix install_names for bundling.
#
# Phase 1a deliverable. See docs/phase1a/architecture.md for context.
#
# Usage:
#   ./other/build_mpv.sh
#   ./other/build_mpv.sh --clean
#   ./other/build_mpv.sh --use-libplacebo-metal   # opt-in native Metal backend
#   ./other/build_mpv.sh --jobs N
#
# Idempotent: skips if .build-stamp matches pinned SHAs unless --clean is given.

set -euo pipefail

# --------------------------------------------------------------------------
# Configuration — pinned versions
# --------------------------------------------------------------------------

# Pin upstream mpv. The cherry-pick base is computed at build time as
# git merge-base(MPV_UPSTREAM_REF, MPV_PR_HEAD_SHA), so we only need to pin
# the upstream tip we want to build against and the PR head.
MPV_UPSTREAM_REPO="https://github.com/mpv-player/mpv.git"
MPV_UPSTREAM_REF="a42b1b9103b2a5ab60817dfe858bf92ec0abc8e0"  # mpv-player/mpv@master 2026-04-27

# PR #16818 head (sparky3387/mpv@master 2026-04-27).
MPV_PR_REPO="https://github.com/sparky3387/mpv.git"
MPV_PR_BRANCH="master"
MPV_PR_HEAD_SHA="80351bb32492402c894bb4291acdd44594db8450"

# libplacebo
LIBPLACEBO_REPO="https://github.com/haasn/libplacebo.git"
LIBPLACEBO_SHA="5f919b4188fb205d7b03769d6fd6ea9d0a430353"  # haasn/libplacebo@master 2026-04-27

# libdovi (Rust) — for DV RPU reshaping
LIBDOVI_REPO="https://github.com/quietvoid/dovi_tool.git"
LIBDOVI_SHA="e7bef8d979a3a975a5eb6930c25e07e554cecee9"  # quietvoid/dovi_tool@main 2026-04-27

# Homebrew tools we require (build-time only, not bundled).
# If you don't use Homebrew, install equivalents via your package manager.
REQUIRED_TOOLS=(
  meson
  ninja
  pkg-config
  cmake
  cargo                # for libdovi
  rustc
  python3
)

# Homebrew libraries we link against. Will be statically linked into libplacebo
# where possible, dynamically for libavformat/libavcodec/etc which mpv links.
REQUIRED_LIBS=(
  ffmpeg               # mpv needs libav*
  lcms2                # color management
  shaderc              # SPIR-V compilation for libplacebo
  libavif              # HDR10+ AVIF support (optional but recommended)
  glslang              # alt shader compiler
  spirv-cross          # SPIR-V → Metal/MSL when using MoltenVK
  molten-vk            # MoltenVK for libplacebo Vulkan→Metal
  vulkan-loader        # Vulkan API headers/loader
  vulkan-headers
)

# --------------------------------------------------------------------------
# Paths
# --------------------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." &> /dev/null && pwd)"
BUILD_DIR="$ROOT_DIR/_build/mpv"
SRC_DIR="$BUILD_DIR/src"
INSTALL_DIR="$BUILD_DIR/install"
DEPS_LIB="$ROOT_DIR/deps/lib"
DEPS_INCLUDE="$ROOT_DIR/deps/include"
STAMP_FILE="$BUILD_DIR/.build-stamp"
CHANGE_LIB="$SCRIPT_DIR/change_lib_dependencies.rb"

# --------------------------------------------------------------------------
# Args
# --------------------------------------------------------------------------

CLEAN=false
USE_LIBPLACEBO_METAL=false
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean) CLEAN=true; shift ;;
    --use-libplacebo-metal) USE_LIBPLACEBO_METAL=true; shift ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --jobs=*) JOBS="${1#*=}"; shift ;;
    -h|--help)
      sed -n '2,16p' "$0" | sed 's/^# //;s/^#//'
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# --------------------------------------------------------------------------
# Logging
# --------------------------------------------------------------------------

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
log()   { printf "${BLUE}[build_mpv]${NC} %s\n" "$*"; }
ok()    { printf "${GREEN}[ok]${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}[warn]${NC} %s\n" "$*"; }
die()   { printf "${RED}[fail]${NC} %s\n" "$*" >&2; exit 1; }

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------

preflight() {
  log "Preflight checks"

  [[ "$(uname)" == "Darwin" ]] || die "This script is macOS-only."
  [[ "$(uname -m)" == "arm64" ]] || die "This script targets arm64 (Apple Silicon) only."

  command -v brew >/dev/null || die "Homebrew is required. Install from https://brew.sh"

  local missing=()
  for tool in "${REQUIRED_TOOLS[@]}"; do
    command -v "$tool" >/dev/null || missing+=("$tool")
  done
  for pkg in "${REQUIRED_LIBS[@]}"; do
    brew --prefix "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    warn "Missing build dependencies: ${missing[*]}"
    log "Run: brew install ${missing[*]}"
    die "Install missing dependencies and rerun."
  fi

  command -v cargo-cinstall >/dev/null 2>&1 || command -v cargo >/dev/null && cargo install --list 2>/dev/null | grep -q '^cargo-c' \
    || die "cargo-c is required for libdovi. Run: cargo install cargo-c"

  ok "Preflight passed (jobs=$JOBS, libplacebo-metal=$USE_LIBPLACEBO_METAL)"
}

# --------------------------------------------------------------------------
# Idempotency check
# --------------------------------------------------------------------------

current_stamp() {
  printf "%s|%s|%s|%s|%s\n" \
    "$MPV_UPSTREAM_REF" "$MPV_PR_HEAD_SHA" "$LIBPLACEBO_SHA" "$LIBDOVI_SHA" "$USE_LIBPLACEBO_METAL"
}

stamp_matches() {
  [[ -f "$STAMP_FILE" ]] && [[ "$(cat "$STAMP_FILE")" == "$(current_stamp)" ]]
}

write_stamp() {
  current_stamp > "$STAMP_FILE"
}

# --------------------------------------------------------------------------
# Build steps
# --------------------------------------------------------------------------

step_clean() {
  if $CLEAN; then
    log "--clean: removing $BUILD_DIR"
    rm -rf "$BUILD_DIR"
  fi
}

step_libdovi() {
  local dst="$INSTALL_DIR"
  if [[ -f "$dst/lib/libdovi.a" ]]; then
    ok "libdovi already built"
    return
  fi
  log "Building libdovi"
  rm -rf "$SRC_DIR/dovi_tool"
  git clone "$LIBDOVI_REPO" "$SRC_DIR/dovi_tool"
  ( cd "$SRC_DIR/dovi_tool" && git checkout "$LIBDOVI_SHA" )
  ( cd "$SRC_DIR/dovi_tool/dolby_vision" && cargo cinstall --release \
      --prefix="$INSTALL_DIR" --library-type=staticlib --target aarch64-apple-darwin )
  ok "libdovi built"
}

step_libplacebo() {
  if [[ -f "$INSTALL_DIR/lib/libplacebo.a" ]]; then
    ok "libplacebo already built"
    return
  fi
  log "Building libplacebo (HDR / DV / HDR10+)"
  rm -rf "$SRC_DIR/libplacebo"
  git clone --recursive "$LIBPLACEBO_REPO" "$SRC_DIR/libplacebo"
  ( cd "$SRC_DIR/libplacebo" && git checkout "$LIBPLACEBO_SHA" && git submodule update --init --recursive )

  if $USE_LIBPLACEBO_METAL; then
    warn "libplacebo $LIBPLACEBO_SHA has no native Metal backend option."
    warn "--use-libplacebo-metal is ignored; using MoltenVK Vulkan path."
  fi

  meson setup "$SRC_DIR/libplacebo/build" "$SRC_DIR/libplacebo" \
    --prefix="$INSTALL_DIR" \
    --buildtype=release \
    --default-library=static \
    -Dvulkan=enabled \
    -Dvk-proc-addr=enabled \
    -Dopengl=enabled \
    -Dgl-proc-addr=enabled \
    -Dshaderc=enabled \
    -Dglslang=disabled \
    -Dlcms=enabled \
    -Ddovi=enabled \
    -Dlibdovi=enabled \
    -Dxxhash=disabled \
    -Ddemos=false \
    -Dtests=false \
    --pkg-config-path "$INSTALL_DIR/lib/pkgconfig:$(brew --prefix)/lib/pkgconfig"

  meson compile -C "$SRC_DIR/libplacebo/build" -j "$JOBS"
  meson install -C "$SRC_DIR/libplacebo/build"

  ok "libplacebo built"
}

step_mpv_clone_and_cherrypick() {
  if [[ -f "$SRC_DIR/mpv/.cherrypick-done" ]]; then
    ok "mpv source already prepared"
    return
  fi
  log "Cloning upstream mpv@${MPV_UPSTREAM_REF:0:10}"
  rm -rf "$SRC_DIR/mpv"
  git clone "$MPV_UPSTREAM_REPO" "$SRC_DIR/mpv"
  ( cd "$SRC_DIR/mpv" && git checkout "$MPV_UPSTREAM_REF" )

  log "Fetching PR #16818 head from sparky3387/mpv"
  ( cd "$SRC_DIR/mpv"
    git remote add pr "$MPV_PR_REPO"
    git fetch pr "$MPV_PR_BRANCH"

    # Verify pinned PR head matches what we fetched.
    local fetched_head
    fetched_head="$(git rev-parse pr/$MPV_PR_BRANCH)"
    if [[ "$fetched_head" != "$MPV_PR_HEAD_SHA" ]]; then
      warn "PR head moved: pinned=$MPV_PR_HEAD_SHA, fetched=$fetched_head"
      warn "Using pinned SHA. Update MPV_PR_HEAD_SHA if intended."
    fi

    # Compute merge-base so cherry-pick range covers exactly the PR's commits.
    local merge_base
    merge_base="$(git merge-base "$MPV_UPSTREAM_REF" "$MPV_PR_HEAD_SHA" 2>/dev/null || true)"
    if [[ -z "$merge_base" ]]; then
      die "Could not compute merge-base. Branches may not share history."
    fi
    log "Merge-base: ${merge_base:0:10}; cherry-picking ${merge_base:0:10}..${MPV_PR_HEAD_SHA:0:10}"

    # Cherry-pick. --keep-redundant-commits skips commits already present
    # (e.g. if PR included upstream commits via merge).
    if ! git cherry-pick --strategy=recursive --strategy-option=patience \
         --keep-redundant-commits --allow-empty \
         "$merge_base..$MPV_PR_HEAD_SHA" 2>&1 | tee "$BUILD_DIR/cherrypick.log"; then
      git cherry-pick --abort 2>/dev/null || true
      die "Cherry-pick conflict. See $BUILD_DIR/cherrypick.log. Resolve in $SRC_DIR/mpv and rerun."
    fi

    touch .cherrypick-done
  )
  ok "mpv prepared with PR #16818"
}

step_mpv_build() {
  if [[ -f "$INSTALL_DIR/lib/libmpv.dylib" ]] || [[ -f "$INSTALL_DIR/lib/libmpv.2.dylib" ]]; then
    ok "mpv already built"
    return
  fi
  log "Configuring mpv build"
  ( cd "$SRC_DIR/mpv"
    meson setup build \
      --prefix="$INSTALL_DIR" \
      --buildtype=release \
      --default-library=shared \
      -Dlibmpv=true \
      -Dcplayer=false \
      -Dgpl=true \
      -Dlua=disabled \
      -Djavascript=disabled \
      -Dswift-build=enabled \
      -Dmacos-cocoa-cb=disabled \
      -Dvideotoolbox-gl=enabled \
      -Dvideotoolbox-pl=enabled \
      --pkg-config-path "$INSTALL_DIR/lib/pkgconfig:$(brew --prefix)/lib/pkgconfig"

    log "Building mpv"
    meson compile -C build -j "$JOBS"

    log "Installing mpv to $INSTALL_DIR"
    meson install -C build
  )
  ok "mpv built"
}

step_install_to_deps() {
  log "Installing libmpv to deps/lib via change_lib_dependencies.rb"

  local libmpv
  libmpv="$(ls "$INSTALL_DIR"/lib/libmpv*.dylib 2>/dev/null | grep -v 'symbolic' | head -1 || true)"
  [[ -n "$libmpv" ]] || die "No libmpv dylib produced in $INSTALL_DIR/lib"

  # Resolve the canonical (non-symlink) path.
  libmpv="$(readlink -f "$libmpv" 2>/dev/null || python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$libmpv")"

  log "Real libmpv: $libmpv"

  # change_lib_dependencies.rb wipes deps/lib at start and walks transitive
  # deps under the given prefix, copying them into deps/lib and rewriting
  # install names to @rpath/. libplacebo + libdovi are statically linked into
  # libmpv (no separate dylib to bundle); the only dynamic deps are Homebrew
  # libraries (ffmpeg/libass/lcms/etc), so we walk under brew --prefix.
  local brew_prefix
  brew_prefix="$(brew --prefix)"
  ruby "$CHANGE_LIB" "$brew_prefix" "$libmpv"

  ok "libmpv installed to $DEPS_LIB"
}

step_install_headers() {
  log "Installing mpv headers to $DEPS_INCLUDE/mpv"
  mkdir -p "$DEPS_INCLUDE/mpv"
  cp -p "$INSTALL_DIR/include/mpv/"*.h "$DEPS_INCLUDE/mpv/"
  ok "Headers installed"
}

step_verify() {
  log "Verification: otool -L on bundled libmpv"
  local libmpv_in_deps
  libmpv_in_deps="$(ls "$DEPS_LIB"/libmpv*.dylib 2>/dev/null | head -1 || true)"
  [[ -n "$libmpv_in_deps" ]] || die "No bundled libmpv found"

  otool -L "$libmpv_in_deps"

  # Sanity: every dependency should be either a system framework (/usr/lib,
  # /System/Library) or @rpath-prefixed (i.e., bundled).
  local bad
  bad="$(otool -L "$libmpv_in_deps" \
    | tail -n +2 \
    | awk '{print $1}' \
    | grep -vE '^(/usr/lib/|/System/|@rpath/)' \
    | grep -v "^${libmpv_in_deps}:$" || true)"

  if [[ -n "$bad" ]]; then
    warn "These dependencies are not bundled and not system libraries:"
    echo "$bad"
    die "Cannot ship: external dependencies not under @rpath. Re-run change_lib_dependencies.rb manually."
  fi

  ok "All dependencies are either system libraries or bundled @rpath/"
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

main() {
  preflight
  step_clean

  if stamp_matches; then
    ok "Build stamp matches pinned SHAs — nothing to do. Use --clean to force rebuild."
    exit 0
  fi

  mkdir -p "$BUILD_DIR" "$SRC_DIR" "$INSTALL_DIR" "$DEPS_LIB" "$DEPS_INCLUDE"

  step_libdovi
  step_libplacebo
  step_mpv_clone_and_cherrypick
  step_mpv_build
  step_install_to_deps
  step_install_headers
  step_verify

  write_stamp
  ok "Build complete. libmpv is in $DEPS_LIB. Headers in $DEPS_INCLUDE/mpv."
  log "Next: rebuild IINA from Xcode. Phase 1b begins after Phase 1a review."
}

main "$@"
