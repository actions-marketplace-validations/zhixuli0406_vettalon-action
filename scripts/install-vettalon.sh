#!/usr/bin/env bash
# Install the vettalon CLI for a GitHub Actions job.
#
# Inputs (environment):
#   VETTALON_VERSION         "latest" (default) or a release tag such as v0.1.0
#   VETTALON_INSTALL_METHOD  "release" (default) or "source"
#   VETTALON_DOWNLOAD_BASE   optional: directory URL that holds the release
#                            assets (overrides the GitHub release URL; used
#                            for testing against a local server)
#   VETTALON_REPO            optional: owner/name of the CLI repo
#                            (default zhixuli0406/vettalon)
#   GITHUB_PATH              file the runner reads to extend PATH
#   RUNNER_TEMP              scratch directory (falls back to mktemp)
#
# "release" downloads the prebuilt tarball and verifies its .sha256 file.
# A checksum mismatch or a missing checksum file is fatal. If the tarball
# itself cannot be downloaded (for example, no release has been published
# yet) the script falls back to building from source with cargo.
set -euo pipefail

readonly DEFAULT_REPO="zhixuli0406/vettalon"

log() { printf '[vettalon-action] %s\n' "$*" >&2; }
warn() { printf '::warning::%s\n' "$*" >&2; }
die() {
  printf '::error::%s\n' "$*" >&2
  exit 1
}

version="${VETTALON_VERSION:-latest}"
method="${VETTALON_INSTALL_METHOD:-release}"
repo="${VETTALON_REPO:-$DEFAULT_REPO}"
base_override="${VETTALON_DOWNLOAD_BASE:-}"

validate_inputs() {
  case "$method" in
    release | source) ;;
    *) die "install-method must be 'release' or 'source' (got '$method')" ;;
  esac
  if [[ "$version" != "latest" ]]; then
    if [[ ! "$version" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
      die "version must be 'latest' or a tag like v0.1.0 (got '$version')"
    fi
    # Release tags in the CLI repo always carry a leading "v".
    [[ "$version" == v* ]] || version="v${version}"
  fi
  if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    die "VETTALON_REPO must look like owner/name (got '$repo')"
  fi
}

detect_os() {
  local os="${RUNNER_OS:-}"
  if [[ -z "$os" ]]; then
    case "$(uname -s)" in
      Linux) os="Linux" ;;
      Darwin) os="macOS" ;;
      *) os="$(uname -s)" ;;
    esac
  fi
  case "$os" in
    Linux) printf 'linux' ;;
    macOS) printf 'darwin' ;;
    *) die "unsupported runner OS '$os': vettalon supports Linux and macOS runners only" ;;
  esac
}

detect_arch() {
  local arch="${RUNNER_ARCH:-}"
  if [[ -z "$arch" ]]; then
    arch="$(uname -m)"
  fi
  case "$arch" in
    X64 | x86_64 | amd64) printf 'x64' ;;
    ARM64 | arm64 | aarch64) printf 'arm64' ;;
    *) die "unsupported CPU architecture '$arch' (supported: x64, arm64)" ;;
  esac
}

make_workdir() {
  local parent="${RUNNER_TEMP:-}"
  if [[ -n "$parent" && -d "$parent" ]]; then
    mktemp -d "${parent%/}/vettalon-install.XXXXXX"
  else
    mktemp -d "${TMPDIR:-/tmp}/vettalon-install.XXXXXX"
  fi
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    die "neither sha256sum nor shasum is available to verify the download"
  fi
}

download_base() {
  if [[ -n "$base_override" ]]; then
    printf '%s' "${base_override%/}"
  elif [[ "$version" == "latest" ]]; then
    printf 'https://github.com/%s/releases/latest/download' "$repo"
  else
    printf 'https://github.com/%s/releases/download/%s' "$repo" "$version"
  fi
}

# Only https is allowed, except plain http on loopback for local testing.
check_url_scheme() {
  local url="$1"
  if [[ "$url" =~ ^https:// ]]; then
    return 0
  fi
  if [[ "$url" =~ ^http://(127\.0\.0\.1|localhost)(:[0-9]+)?/ ]]; then
    return 0
  fi
  die "refusing download URL '$url': only https (or http on localhost) is allowed"
}

# Downloads $1 to $2 and prints the final HTTP status code ("000" when no
# HTTP response arrived). Returns curl's exit status.
fetch() {
  local url="$1" dest="$2"
  local protos="=https"
  [[ "$url" == http://* ]] && protos="=http,https"
  curl --fail --silent --show-error --location \
    --proto "$protos" --proto-redir "=https" \
    --retry 3 --retry-delay 2 --connect-timeout 20 \
    --write-out '%{http_code}' \
    --output "$dest" "$url"
}

add_to_path() {
  local dir="$1"
  if [[ -n "${GITHUB_PATH:-}" ]]; then
    printf '%s\n' "$dir" >>"$GITHUB_PATH"
  else
    log "GITHUB_PATH is not set; add $dir to PATH yourself"
  fi
}

# Returns 0 and leaves the binary in $bin_dir on success.
# Returns 3 only when the server answers 404 for the tarball, meaning there
# is no such release asset (caller may fall back to a source build).
# Any other download error, and any integrity problem, exits the script.
install_from_release() {
  local os="$1" arch="$2" work="$3" bin_dir="$4"
  local asset="vettalon-${os}-${arch}.tar.gz"
  local base
  base="$(download_base)"
  check_url_scheme "$base/$asset"

  log "downloading $base/$asset"
  local status
  if ! status="$(fetch "$base/$asset" "$work/$asset")"; then
    if [[ "$status" == "404" ]]; then
      warn "$asset was not found at $base (HTTP 404)"
      return 3
    fi
    die "downloading $asset from $base failed (HTTP status ${status:-none}); not falling back to a source build"
  fi

  log "downloading $base/$asset.sha256"
  if ! fetch "$base/$asset.sha256" "$work/$asset.sha256" >/dev/null; then
    die "checksum file $asset.sha256 could not be downloaded; refusing to install an unverified binary"
  fi

  local expected actual
  expected="$(awk 'NR==1 {print tolower($1)}' "$work/$asset.sha256")"
  if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
    die "checksum file $asset.sha256 is malformed; refusing to install"
  fi
  actual="$(sha256_of "$work/$asset")" || die "cannot compute sha256 of $asset"
  if [[ "$actual" != "$expected" ]]; then
    die "sha256 mismatch for $asset (expected $expected, got $actual); refusing to install"
  fi
  log "sha256 verified: $actual"

  # This function runs in a `||` context where errexit is off, so every
  # step below checks its own status.
  local extract="$work/extract"
  mkdir -p "$extract" || die "cannot create $extract"
  tar -xzf "$work/$asset" -C "$extract" || die "cannot extract $asset"
  if [[ ! -f "$extract/vettalon" || -L "$extract/vettalon" ]]; then
    die "$asset does not contain a regular 'vettalon' file at its root"
  fi
  install -m 0755 "$extract/vettalon" "$bin_dir/vettalon" || die "cannot install vettalon into $bin_dir"
}

install_from_source() {
  local bin_dir="$1"
  if ! command -v cargo >/dev/null 2>&1; then
    die "cargo is not available. Install a Rust toolchain (1.88+) before this step, for example with dtolnay/rust-toolchain, or use a published release."
  fi
  local root
  root="$(dirname "$bin_dir")"
  local args=(install --locked --git "https://github.com/${repo}" --root "$root")
  if [[ "$version" != "latest" ]]; then
    args+=(--tag "$version")
  else
    warn "version is 'latest': building the default branch of ${repo} (not a tagged release). Pin 'version' to a tag for reproducible builds."
  fi
  args+=(vettalon)
  log "building from source: cargo ${args[*]}"
  cargo "${args[@]}"
  [[ -x "$bin_dir/vettalon" ]] || die "cargo install finished but $bin_dir/vettalon is missing"
}

main() {
  validate_inputs
  local os arch work bin_dir
  os="$(detect_os)"
  arch="$(detect_arch)"
  work="$(make_workdir)"
  # cargo install --root R puts binaries in R/bin, so use the same layout.
  bin_dir="$work/root/bin"
  mkdir -p "$bin_dir"

  if [[ "$method" == "release" ]]; then
    local rc=0
    install_from_release "$os" "$arch" "$work" "$bin_dir" || rc=$?
    if [[ "$rc" -eq 3 ]]; then
      warn "no prebuilt vettalon release asset found; falling back to building from source"
      install_from_source "$bin_dir"
    elif [[ "$rc" -ne 0 ]]; then
      die "release install failed (code $rc)"
    fi
  else
    install_from_source "$bin_dir"
  fi

  local reported
  reported="$("$bin_dir/vettalon" --version)" || die "installed vettalon binary does not run"
  log "installed: $reported ($bin_dir/vettalon)"
  if [[ "$version" != "latest" && "$reported" != *"${version#v}"* ]]; then
    warn "requested $version but the binary reports '$reported'"
  fi
  add_to_path "$bin_dir"
}

main "$@"
