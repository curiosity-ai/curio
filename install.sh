#!/bin/sh
# Install curio, the Curiosity Studio shell, from the latest GitHub release.
#
#   curl -fsSL https://curiosity.sh/install.sh | bash
#
# Puts the self-contained binary at ~/.curiosity/bin/curio (curio.exe under Git Bash on Windows),
# next to curio's own config and credentials in ~/.curiosity/curio, and adds the folder to PATH.
#
# Settings, all optional:
#   CURIO_VERSION=v26.9.6085   a release tag instead of the latest release
#   CURIO_INSTALL=~/.curiosity where to install; the binary goes in its bin/ folder
#   CURIO_NO_MODIFY_PATH=1     leave the shell profile alone
#
# Plain POSIX sh, so `| sh` works as well as `| bash`. Everything is inside main(), which runs on
# the last line: a download cut off halfway runs nothing.

set -eu

REPO="curiosity-ai/curio"

say()  { printf '%s\n' "$*"; }
warn() { printf 'curio: %s\n' "$*" >&2; }
die()  { printf 'curio: %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "this installer needs '$1'"; }

# GET a URL to stdout (fetch) or to a file (download), with curl or wget.
fetch() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -H 'Accept: application/vnd.github+json' "$1"
  else
    wget -qO- --header='Accept: application/vnd.github+json' "$1"
  fi
}
download() {
  if command -v curl >/dev/null 2>&1; then
    if [ -t 2 ]; then curl -fL --progress-bar -o "$2" "$1"; else curl -fsSL -o "$2" "$1"; fi
  else
    wget -q -O "$2" "$1"
  fi
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else return 1
  fi
}

detect_os() {
  case "$(uname -s)" in
    Linux)                           echo linux ;;
    Darwin)                          echo osx ;;
    MINGW* | MSYS* | CYGWIN*)        echo win ;;
    *) die "unsupported operating system: $(uname -s). Install with: dotnet tool install --global Curiosity.Shell" ;;
  esac
}

detect_arch() {
  arch="$(uname -m)"
  # A shell running under Rosetta reports x86_64 on an Apple silicon Mac; install the native binary.
  if [ "$1" = osx ] && [ "$arch" = x86_64 ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 1 ]; then
    arch=arm64
  fi
  case "$arch" in
    x86_64 | amd64 | x64)  echo x64 ;;
    arm64 | aarch64)       echo arm64 ;;
    *) die "unsupported CPU architecture: $arch. Install with: dotnet tool install --global Curiosity.Shell" ;;
  esac
}

# Reads the release JSON on stdin and prints "<download url> <sha256 or ->" for one asset. No jq: the
# JSON is split at every comma and brace so each "key": value lands on a line of its own, and an asset's
# fields are read after its "name", which the GitHub API writes before its digest and download URL.
asset_from_release() {
  tr ',{}' '\n\n\n' | awk -v want="$1" '
    function val(line) { sub(/^[^:]*:[ \t]*"/, "", line); sub(/".*$/, "", line); return line }
    /^[ \t]*"name"[ \t]*:/                                 { cur = val($0) }
    cur == want && /^[ \t]*"digest"[ \t]*:[ \t]*"sha256:/  { d = val($0); sub(/^sha256:/, "", d) }
    cur == want && /^[ \t]*"browser_download_url"[ \t]*:/  { u = val($0) }
    END { if (u != "") print u, (d == "" ? "-" : d) }'
}

# Appends a line to a profile once; the comment above it marks it as ours.
add_line() {
  file="$1"; line="$2"
  [ -f "$file" ] && grep -Fq "$line" "$file" && return 0
  mkdir -p "$(dirname "$file")"
  printf '\n# curio\n%s\n' "$line" >> "$file"
  say "  added $BIN_DIR to PATH in $file"
}

add_to_path() {
  case ":$PATH:" in *":$BIN_DIR:"*) return 0 ;; esac

  if [ "${CURIO_NO_MODIFY_PATH:-}" = 1 ]; then
    NEW_PATH_HINT=1
    return 0
  fi

  # Written with $HOME rather than the expanded path when it lives under it, so a profile synced
  # between machines keeps working.
  case "$BIN_DIR" in
    "$HOME"/*) shown="\$HOME${BIN_DIR#"$HOME"}" ;;
    *)         shown="$BIN_DIR" ;;
  esac

  case "$(basename "${SHELL:-sh}")" in
    zsh)  add_line "${ZDOTDIR:-$HOME}/.zshrc" "export PATH=\"$shown:\$PATH\"" ;;
    bash)
      add_line "$HOME/.bashrc" "export PATH=\"$shown:\$PATH\""
      # A login shell (every new Terminal window on macOS) reads the first of these and not .bashrc.
      # Creating .bash_profile when .profile exists would hide .profile, so the existing one is used.
      login="$HOME/.bash_profile"
      for f in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
        if [ -f "$f" ]; then login="$f"; break; fi
      done
      add_line "$login" "export PATH=\"$shown:\$PATH\""
      ;;
    fish) add_line "${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/curio.fish" "fish_add_path \"$BIN_DIR\"" ;;
    *)    add_line "$HOME/.profile" "export PATH=\"$shown:\$PATH\"" ;;
  esac

  # Git Bash and MSYS read the profile, but cmd and PowerShell read the user's Windows PATH.
  if [ "$OS" = win ] && command -v cygpath >/dev/null 2>&1 && command -v powershell.exe >/dev/null 2>&1; then
    win_dir="$(cygpath -w "$BIN_DIR")"
    powershell.exe -NoProfile -NonInteractive -Command "
      \$k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', \$true)
      \$p = \$k.GetValue('Path', '', 'DoNotExpandEnvironmentNames')
      if ((\$p -split ';') -notcontains '$win_dir') {
        \$k.SetValue('Path', ((@(\$p -split ';' | Where-Object { \$_ }) + '$win_dir') -join ';'), 'ExpandString')
        [Environment]::SetEnvironmentVariable('CURIO_INSTALLER', '1', 'User')
        [Environment]::SetEnvironmentVariable('CURIO_INSTALLER', \$null, 'User')
      }" >/dev/null 2>&1 && say "  added $win_dir to your Windows user PATH" \
      || warn "could not add $win_dir to the Windows user PATH; add it by hand"
  fi

  NEW_PATH_HINT=1
}

main() {
  OS="$(detect_os)"
  ARCH="$(detect_arch "$OS")"
  INSTALL_ROOT="${CURIO_INSTALL:-$HOME/.curiosity}"
  BIN_DIR="$INSTALL_ROOT/bin"
  NEW_PATH_HINT=0

  command -v curl >/dev/null 2>&1 || need wget
  need awk

  EXE=curio
  [ "$OS" = win ] && EXE=curio.exe
  ASSET="curio-$OS-$ARCH"
  [ "$OS" = win ] && ASSET="$ASSET.exe"

  if [ -n "${CURIO_VERSION:-}" ]; then
    case "$CURIO_VERSION" in v*) tag="$CURIO_VERSION" ;; *) tag="v$CURIO_VERSION" ;; esac
    api="https://api.github.com/repos/$REPO/releases/tags/$tag"
    direct="https://github.com/$REPO/releases/download/$tag"
  else
    api="https://api.github.com/repos/$REPO/releases/latest"
    direct="https://github.com/$REPO/releases/latest/download"
  fi

  say "Installing curio ($OS-$ARCH)"

  json="$(fetch "$api" 2>/dev/null || true)"
  version="$(printf '%s' "$json" | tr ',' '\n' | awk -F'"' '/"tag_name"/ { print $4; exit }')"
  found="$(printf '%s' "$json" | asset_from_release "$ASSET")"

  if [ -n "$found" ]; then
    url="${found% *}"
    digest="${found##* }"
  elif [ -n "$version" ]; then
    # The release is there and has no binary for this platform.
    assets="$(printf '%s' "$json" | tr ',' '\n' | awk -F'"' '/"browser_download_url"/ { n = split($4, p, "/"); printf "%s%s", sep, p[n]; sep = ", " }')"
    if [ "$OS" = win ] && [ "$ARCH" = arm64 ] && printf '%s' "$assets" | grep -q 'curio-win-x64.exe'; then
      # Windows on Arm runs x64 programs through its emulator.
      warn "no Windows Arm64 build in $version yet; installing the x64 one, which Windows runs emulated"
      ASSET="curio-win-x64.exe"
      found="$(printf '%s' "$json" | asset_from_release "$ASSET")"
      url="${found% *}"; digest="${found##* }"
    else
      die "release $version has no build for $OS-$ARCH (it has: ${assets:-nothing}).
Install with the .NET SDK instead: dotnet tool install --global Curiosity.Shell"
    fi
  else
    # The API refused (rate limit, proxy) or the tag does not exist: the release download URL redirects
    # to the asset by name, so try it without a checksum.
    warn "could not read the release from the GitHub API; downloading $ASSET directly"
    url="$direct/$ASSET"
    digest="-"
    version="${tag:-(latest)}"
  fi

  mkdir -p "$BIN_DIR"
  # Downloaded into the destination folder, so the final rename is atomic and a running curio keeps
  # its old file until it exits.
  tmp="$(mktemp "$BIN_DIR/.curio-download.XXXXXX")"
  trap 'rm -f "$tmp"' EXIT
  trap 'rm -f "$tmp"; exit 130' INT TERM

  say "  downloading $version: $url"
  download "$url" "$tmp" || die "download failed: $url
Releases: https://github.com/$REPO/releases"

  if [ "$digest" != "-" ]; then
    if actual="$(sha256 "$tmp")"; then
      [ "$actual" = "$digest" ] || die "checksum mismatch for $ASSET: expected $digest, got $actual"
      say "  sha256 verified"
    else
      warn "no sha256sum or shasum; skipping the checksum"
    fi
  fi

  chmod 755 "$tmp"
  if [ "$OS" = osx ]; then
    xattr -d com.apple.quarantine "$tmp" 2>/dev/null || true
  fi

  if [ "$OS" = win ] && [ -f "$BIN_DIR/$EXE" ]; then
    # Windows cannot replace a running .exe, but it can rename one.
    rm -f "$BIN_DIR/$EXE.old" 2>/dev/null || true
    mv -f "$BIN_DIR/$EXE" "$BIN_DIR/$EXE.old" 2>/dev/null || true
  fi
  mv -f "$tmp" "$BIN_DIR/$EXE"
  trap - EXIT INT TERM

  if [ "$OS" = linux ] && ldd --version 2>&1 | grep -qi musl; then
    warn "this looks like a musl system (Alpine); the release binary needs glibc. If it does not start, use: dotnet tool install --global Curiosity.Shell"
  fi

  say "  installed $BIN_DIR/$EXE"
  add_to_path

  other="$(command -v curio 2>/dev/null || true)"
  if [ -n "$other" ] && [ "$other" != "$BIN_DIR/$EXE" ] && [ "$other" != "$BIN_DIR/curio" ]; then
    warn "another curio comes first on your PATH: $other"
    warn "remove it (a .NET tool install: dotnet tool uninstall --global Curiosity.Shell) or put $BIN_DIR before it"
  fi

  say ""
  say "curio $version is installed."
  if [ "$NEW_PATH_HINT" = 1 ]; then
    say "Open a new terminal, or run this one first:"
    if [ "$(basename "${SHELL:-sh}")" = fish ]; then
      say "  fish_add_path \"$BIN_DIR\""
    else
      say "  export PATH=\"$BIN_DIR:\$PATH\""
    fi
  fi
  say "Then start it with: curio"
}

main "$@"
