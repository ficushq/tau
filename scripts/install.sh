#!/usr/bin/env sh
set -eu

REPO="${FICUS_INSTALL_REPO:-ficushq/tau}"
INSTALL_DIR="${FICUS_INSTALL_DIR:-$HOME/.tau/bin}"
SHARE_DIR="${FICUS_SHARE_DIR:-$HOME/.tau/share}"
BIN_NAME="tau"
API_URL="${GITHUB_API_URL:-https://api.github.com}"
DOWNLOAD_BASE_URL="${FICUS_DOWNLOAD_BASE_URL:-https://ficus.sh/cli}"

if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
  ESC=$(printf '\033')
  BOLD="${ESC}[1m"
  DIM="${ESC}[2m"
  GREEN="${ESC}[32m"
  BLUE="${ESC}[34m"
  YELLOW="${ESC}[33m"
  RED="${ESC}[31m"
  RESET="${ESC}[0m"
else
  BOLD=''
  DIM=''
  GREEN=''
  BLUE=''
  YELLOW=''
  RED=''
  RESET=''
fi

say() {
  printf '%s\n' "$*"
}

section() {
  printf '\n%s==> %s%s\n' "$BOLD$BLUE" "$*" "$RESET"
}

step() {
  printf '%s→%s %s\n' "$BLUE" "$RESET" "$*"
}

success() {
  printf '%s✓%s %s\n' "$GREEN" "$RESET" "$*"
}

warn() {
  printf '%s!%s %s\n' "$YELLOW" "$RESET" "$*"
}

err() {
  printf '\n%s✗ error:%s %s\n' "$RED" "$RESET" "$*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || err "required command not found: $1"
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

is_interactive() {
  [ -t 0 ] && [ -t 1 ]
}

prompt() {
  printf '%s' "$1" >&2
  IFS= read -r REPLY_VALUE
}

prompt_hidden() {
  printf '%s' "$1" >&2
  old_tty=$(stty -g)
  stty -echo
  IFS= read -r REPLY_VALUE
  stty "$old_tty"
  printf '\n' >&2
}

section "Tau CLI installer"
if [ -n "$DOWNLOAD_BASE_URL" ]; then
  say "${DIM}Download:${RESET}   $DOWNLOAD_BASE_URL"
else
  say "${DIM}Repository:${RESET} $REPO"
fi
say "${DIM}Install dir:${RESET} $INSTALL_DIR"
say "${DIM}Share dir:${RESET}   $SHARE_DIR"

need curl
need tar
need mktemp
need uname

if [ -t 1 ]; then
  CURL_PROGRESS="-fL --progress-bar"
else
  CURL_PROGRESS="-fsSL"
fi

OS="$(uname -s)"
ARCH="$(uname -m)"

case "$(lower "$OS")" in
  darwin*) PLATFORM="macos" ;;
  linux*) PLATFORM="linux" ;;
  msys*|mingw*|cygwin*) PLATFORM="windows" ;;
  *) err "unsupported operating system: $OS" ;;
esac

case "$(lower "$ARCH")" in
  arm64|aarch64) CPU="arm64" ;;
  x86_64|amd64) CPU="x64" ;;
  *) err "unsupported architecture: $ARCH" ;;
esac

if [ "$PLATFORM" = "windows" ]; then
  [ "$CPU" = "x64" ] || err "unsupported Windows architecture: $ARCH"
  need unzip
  ASSET="tau-windows-x64.zip"
  BIN_NAME="tau.exe"
else
  ASSET="tau-$PLATFORM-$CPU.tar.gz"
fi

AUTH_HEADER=""
if [ -z "$DOWNLOAD_BASE_URL" ]; then
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    AUTH_HEADER="Authorization: Bearer $GITHUB_TOKEN"
  elif command -v gh >/dev/null 2>&1 && gh auth token >/dev/null 2>&1; then
    AUTH_HEADER="Authorization: Bearer $(gh auth token)"
  fi
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}

on_interrupt() {
  printf '\n' >&2
  warn "Install cancelled."
  exit 130
}

trap cleanup EXIT
trap on_interrupt INT TERM

LATEST_JSON="$TMP_DIR/latest.json"
ARCHIVE="$TMP_DIR/$ASSET"

section "Download"
step "Detected platform: $PLATFORM/$CPU"
step "Asset:   $ASSET"

if [ -n "$DOWNLOAD_BASE_URL" ]; then
  step "Downloading from $DOWNLOAD_BASE_URL..."
  # shellcheck disable=SC2086 # CURL_PROGRESS intentionally expands to curl flags.
  curl $CURL_PROGRESS "$DOWNLOAD_BASE_URL/$ASSET" -o "$ARCHIVE"
else
  step "Fetching latest release metadata..."
  if [ -n "$AUTH_HEADER" ]; then
    curl -fsSL \
      -H "$AUTH_HEADER" \
      -H "Accept: application/vnd.github+json" \
      "$API_URL/repos/$REPO/releases/latest" \
      -o "$LATEST_JSON"
  else
    curl -fsSL \
      -H "Accept: application/vnd.github+json" \
      "$API_URL/repos/$REPO/releases/latest" \
      -o "$LATEST_JSON"
  fi

  TAG="$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$LATEST_JSON" | head -n 1)"
  [ -n "$TAG" ] || err "could not determine latest release tag for $REPO"

  step "Release: $TAG"

  if [ -n "$AUTH_HEADER" ]; then
    ASSET_ID="$(awk -v asset="$ASSET" '
      BEGIN { id=""; in_asset=0 }
      /"id"[[:space:]]*:/ && id == "" { line=$0; sub(/^.*"id"[[:space:]]*:[[:space:]]*/, "", line); sub(/[, ].*$/, "", line); candidate=line }
      /"name"[[:space:]]*:/ {
        line=$0
        if (line ~ "\"name\"[[:space:]]*:[[:space:]]*\"" asset "\"") { id=candidate; print id; exit }
      }
    ' "$LATEST_JSON")"
    [ -n "$ASSET_ID" ] || err "release $TAG does not include asset $ASSET"

    # shellcheck disable=SC2086 # CURL_PROGRESS intentionally expands to curl flags.
    curl $CURL_PROGRESS \
      -H "$AUTH_HEADER" \
      -H "Accept: application/octet-stream" \
      "$API_URL/repos/$REPO/releases/assets/$ASSET_ID" \
      -o "$ARCHIVE"
  else
    # shellcheck disable=SC2086 # CURL_PROGRESS intentionally expands to curl flags.
    curl $CURL_PROGRESS \
      "https://github.com/$REPO/releases/download/$TAG/$ASSET" \
      -o "$ARCHIVE"
  fi
fi
success "Downloaded $ASSET"

section "Install"
mkdir -p "$INSTALL_DIR"

if [ "$PLATFORM" = "windows" ]; then
  unzip -q -o "$ARCHIVE" -d "$TMP_DIR/unpacked"
else
  tar -xzf "$ARCHIVE" -C "$TMP_DIR"
fi

[ -f "$TMP_DIR/$BIN_NAME" ] || [ -f "$TMP_DIR/unpacked/$BIN_NAME" ] || err "archive did not contain $BIN_NAME"

if [ -f "$TMP_DIR/unpacked/$BIN_NAME" ]; then
  cp "$TMP_DIR/unpacked/$BIN_NAME" "$INSTALL_DIR/$BIN_NAME"
  if [ -d "$TMP_DIR/unpacked/skills" ]; then
    rm -rf "$SHARE_DIR/skills"
    mkdir -p "$SHARE_DIR"
    cp -R "$TMP_DIR/unpacked/skills" "$SHARE_DIR/skills"
  fi
else
  cp "$TMP_DIR/$BIN_NAME" "$INSTALL_DIR/$BIN_NAME"
  if [ -d "$TMP_DIR/skills" ]; then
    rm -rf "$SHARE_DIR/skills"
    mkdir -p "$SHARE_DIR"
    cp -R "$TMP_DIR/skills" "$SHARE_DIR/skills"
  fi
fi

chmod +x "$INSTALL_DIR/$BIN_NAME" 2>/dev/null || true

success "Installed Tau CLI: $INSTALL_DIR/$BIN_NAME"
if [ -d "$SHARE_DIR/skills" ]; then
  success "Installed bundled skills: $SHARE_DIR/skills"
fi

configure_auth() {
  AUTH_MODE="${FICUS_INSTALL_AUTH:-prompt}"
  if [ "$AUTH_MODE" = "0" ] || [ "$AUTH_MODE" = "false" ]; then
    warn "Skipping Tau auth setup because FICUS_INSTALL_AUTH=$AUTH_MODE."
    return 0
  fi

  section "Authentication"

  if [ "$AUTH_MODE" != "1" ] && [ "$AUTH_MODE" != "true" ]; then
    if ! is_interactive; then
      warn "Skipping Tau auth setup because install is non-interactive."
      say "Run later: ${BOLD}$INSTALL_DIR/$BIN_NAME auth login <label> --api-url <url>${RESET}"
      return 0
    fi
    prompt "Configure Tau authentication now? [Y/n] "
    case "$REPLY_VALUE" in
      n|N|no|NO)
        warn "Skipping Tau auth setup."
        return 0
        ;;
    esac
  fi

  LABEL="${FICUS_AUTH_LABEL:-}"
  if [ -z "$LABEL" ]; then
    if ! is_interactive; then
      err "FICUS_AUTH_LABEL is required when FICUS_INSTALL_AUTH=1 in non-interactive mode"
    fi
    prompt "Backend label [default]: "
    LABEL="$REPLY_VALUE"
    [ -n "$LABEL" ] || LABEL="default"
  fi

  API_URL_VALUE="${FICUS_API_URL:-}"
  if [ -z "$API_URL_VALUE" ]; then
    if ! is_interactive; then
      err "FICUS_API_URL is required when FICUS_INSTALL_AUTH=1 in non-interactive mode"
    fi
    while [ -z "$API_URL_VALUE" ]; do
      prompt "Tau Core API URL: "
      API_URL_VALUE="$REPLY_VALUE"
    done
  fi

  PASSWORD_VALUE="${FICUS_PASSWORD:-}"
  if [ -z "$PASSWORD_VALUE" ]; then
    if ! is_interactive; then
      err "FICUS_PASSWORD is required when FICUS_INSTALL_AUTH=1 in non-interactive mode"
    fi
    while [ -z "$PASSWORD_VALUE" ]; do
      prompt_hidden "Tau password/token: "
      PASSWORD_VALUE="$REPLY_VALUE"
    done
  fi

  step "Saving backend '$LABEL'..."
  FICUS_PASSWORD="$PASSWORD_VALUE" "$INSTALL_DIR/$BIN_NAME" auth login "$LABEL" --api-url "$API_URL_VALUE"

  if [ "${FICUS_INSTALL_VERIFY:-1}" = "0" ] || [ "${FICUS_INSTALL_VERIFY:-1}" = "false" ]; then
    warn "Skipping auth verification because FICUS_INSTALL_VERIFY=${FICUS_INSTALL_VERIFY:-1}."
    return 0
  fi

  step "Verifying credentials with 'squad list'..."
  if "$INSTALL_DIR/$BIN_NAME" squad list >/dev/null; then
    success "Tau auth verified."
  else
    err "Tau auth verification failed. Check API URL, credentials, and backend availability."
  fi
}

configure_auth

section "Next steps"
case ":$PATH:" in
  *":$INSTALL_DIR:"*)
    success "Tau is already on PATH."
    ;;
  *)
    warn "Tau is not on PATH yet. Add it with:"
    say "  export PATH=\"$INSTALL_DIR:\$PATH\""
    say ""
    say "For zsh:  echo 'export PATH=\"$INSTALL_DIR:\$PATH\"' >> ~/.zshrc"
    say "For bash: echo 'export PATH=\"$INSTALL_DIR:\$PATH\"' >> ~/.bashrc"
    ;;
esac

say ""
say "Run: ${BOLD}tau --help${RESET}"
say "Project memory skill: ${BOLD}tau skill install tau-memory --agent pi${RESET}"
