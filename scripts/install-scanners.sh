#!/usr/bin/env bash
# Install the open-source scanners vettalon uses in quick mode: semgrep and
# gitleaks. Every failure here is a warning, not an error: vettalon still
# runs and records a missing scanner in its report.
#
# Inputs (environment):
#   SEMGREP_VERSION   semgrep version from PyPI (default below)
#   GITLEAKS_VERSION  gitleaks release version without "v" (default below)
#   GITHUB_PATH       file the runner reads to extend PATH
#   RUNNER_TEMP       scratch directory (falls back to mktemp)
set -euo pipefail

# Both versions were checked to exist on 2026-10-15
# (PyPI semgrep 1.181.0; github.com/gitleaks/gitleaks release v8.30.1).
readonly DEFAULT_SEMGREP_VERSION="1.181.0"
readonly DEFAULT_GITLEAKS_VERSION="8.30.1"

semgrep_version="${SEMGREP_VERSION:-$DEFAULT_SEMGREP_VERSION}"
gitleaks_version="${GITLEAKS_VERSION:-$DEFAULT_GITLEAKS_VERSION}"
gitleaks_version="${gitleaks_version#v}"

log() { printf '[vettalon-action] %s\n' "$*" >&2; }
warn() { printf '::warning::%s\n' "$*" >&2; }

add_to_path() {
  local dir="$1"
  export PATH="$dir:$PATH"
  if [[ -n "${GITHUB_PATH:-}" ]]; then
    printf '%s\n' "$dir" >>"$GITHUB_PATH"
  fi
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    return 1
  fi
}

make_workdir() {
  local parent="${RUNNER_TEMP:-}"
  if [[ -n "$parent" && -d "$parent" ]]; then
    mktemp -d "${parent%/}/vettalon-scanners.XXXXXX"
  else
    mktemp -d "${TMPDIR:-/tmp}/vettalon-scanners.XXXXXX"
  fi
}

# The installers below are called as `fn || warn ...`, which turns errexit
# off inside them, so each step checks its own status with `|| return 1`.

install_semgrep() {
  if command -v semgrep >/dev/null 2>&1; then
    log "semgrep already installed: $(semgrep --version 2>/dev/null || echo unknown)"
    return 0
  fi
  if [[ ! "$semgrep_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    warn "SEMGREP_VERSION '$semgrep_version' is not a plain x.y.z version"
    return 1
  fi
  local spec="semgrep==${semgrep_version}"

  if command -v pipx >/dev/null 2>&1; then
    log "installing $spec with pipx"
    if pipx install --quiet "$spec" >&2; then
      local pipx_bin
      pipx_bin="$(pipx environment --value PIPX_BIN_DIR 2>/dev/null)" || pipx_bin="$HOME/.local/bin"
      add_to_path "$pipx_bin"
      if command -v semgrep >/dev/null 2>&1; then
        log "semgrep installed: $(semgrep --version 2>/dev/null || echo unknown)"
        return 0
      fi
    fi
    warn "pipx could not install $spec; trying pip --user"
  fi

  local py=""
  if command -v python3 >/dev/null 2>&1; then
    py="python3"
  elif command -v python >/dev/null 2>&1; then
    py="python"
  else
    warn "no python3 found"
    return 1
  fi
  log "installing $spec with $py -m pip install --user"
  "$py" -m pip install --quiet --user "$spec" >&2 || return 1
  local user_base
  user_base="$("$py" -m site --user-base)" || return 1
  add_to_path "$user_base/bin"
  command -v semgrep >/dev/null 2>&1 || return 1
  log "semgrep installed: $(semgrep --version 2>/dev/null || echo unknown)"
}

install_gitleaks() {
  if command -v gitleaks >/dev/null 2>&1; then
    log "gitleaks already installed: $(gitleaks version 2>/dev/null || echo unknown)"
    return 0
  fi
  if [[ ! "$gitleaks_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    warn "GITLEAKS_VERSION '$gitleaks_version' is not a plain x.y.z version"
    return 1
  fi

  local os arch
  case "${RUNNER_OS:-$(uname -s)}" in
    Linux) os="linux" ;;
    macOS | Darwin) os="darwin" ;;
    *)
      warn "gitleaks: unsupported OS"
      return 1
      ;;
  esac
  case "${RUNNER_ARCH:-$(uname -m)}" in
    X64 | x86_64 | amd64) arch="x64" ;;
    ARM64 | arm64 | aarch64) arch="arm64" ;;
    *)
      warn "gitleaks: unsupported architecture"
      return 1
      ;;
  esac

  local base="https://github.com/gitleaks/gitleaks/releases/download/v${gitleaks_version}"
  local asset="gitleaks_${gitleaks_version}_${os}_${arch}.tar.gz"
  local sums="gitleaks_${gitleaks_version}_checksums.txt"
  local work
  work="$(make_workdir)" || return 1

  log "downloading $base/$asset"
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --retry 3 --retry-delay 2 --connect-timeout 20 \
    --output "$work/$asset" "$base/$asset" || return 1
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --retry 3 --retry-delay 2 --connect-timeout 20 \
    --output "$work/$sums" "$base/$sums" || return 1

  local expected actual
  expected="$(awk -v f="$asset" '$2 == f {print tolower($1)}' "$work/$sums")"
  if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
    warn "gitleaks: $asset is not listed in $sums; not installing"
    return 1
  fi
  actual="$(sha256_of "$work/$asset")" || return 1
  if [[ "$actual" != "$expected" ]]; then
    warn "gitleaks: sha256 mismatch for $asset (expected $expected, got $actual); not installing"
    return 1
  fi
  log "gitleaks sha256 verified: $actual"

  mkdir -p "$work/extract" "$work/bin" || return 1
  tar -xzf "$work/$asset" -C "$work/extract" gitleaks || return 1
  if [[ ! -f "$work/extract/gitleaks" || -L "$work/extract/gitleaks" ]]; then
    warn "gitleaks: archive has no regular 'gitleaks' file"
    return 1
  fi
  install -m 0755 "$work/extract/gitleaks" "$work/bin/gitleaks" || return 1
  add_to_path "$work/bin"
  log "gitleaks installed: $("$work/bin/gitleaks" version 2>/dev/null || echo unknown)"
}

main() {
  install_semgrep || warn "semgrep was not installed; vettalon will run without it and list it as missing"
  install_gitleaks || warn "gitleaks was not installed; vettalon will run without it and list it as missing"
}

main "$@"
