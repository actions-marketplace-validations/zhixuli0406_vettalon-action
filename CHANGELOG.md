# Changelog

All notable changes to this action are documented here. The format follows
[Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0] - 2026-10-15

### Added

- Composite action `Vettalon security scan`: installs the Vettalon CLI, runs
  `vettalon scan`, uploads SARIF to GitHub code scanning with
  `github/codeql-action/upload-sarif@v4`, then fails the job if the scan's
  exit code is not 0.
- Inputs `version`, `path`, `profile`, `fail-on`, `gates`, `config`,
  `sarif-file`, `upload-sarif`, `category`, `install-scanners`,
  `install-method`;
  outputs `sarif-file` and `exit-code`.
- CLI install from GitHub release assets with SHA-256 verification (fails
  closed on a missing or wrong checksum), falling back to
  `cargo install --locked --git` only when the release asset returns 404.
- Optional install of semgrep 1.181.0 (pipx or `pip --user`) and gitleaks
  8.30.1 (official release, checked against its checksums file).
- SARIF paths are prefixed with `path` when a sub-directory is scanned, so
  alerts point at the right files.
- Self-test workflow on ubuntu-latest and macos-latest against a deliberately
  vulnerable fixture, plus a check that Windows runners are refused.
