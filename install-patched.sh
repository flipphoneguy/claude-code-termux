#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

BINARY=~/.local/share/claude-code/claude
WRAPPER=~/.local/bin/claude
BASE_URL=https://downloads.claude.ai/claude-code-releases
GLIBC_LD=/data/data/com.termux/files/usr/glibc/lib/ld-linux-aarch64.so.1
PATCHELF=/data/data/com.termux/files/usr/glibc/bin/patchelf
SETTINGS=~/.claude/settings.json
LD_PRELOAD_VAL=/data/data/com.termux/files/usr/lib/libtermux-exec-ld-preload.so

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------

DEPS=(curl jq clang glibc-runner patchelf-glibc)
MISSING=()

for dep in "${DEPS[@]}"; do
  if ! dpkg -s "$dep" &>/dev/null; then
    MISSING+=("$dep")
  fi
done

# glibc-runner and patchelf-glibc come from the glibc-packages repo,
# which the glibc-repo package enables. Only needed if either is missing.
if ! dpkg -s glibc-repo &>/dev/null; then
  need_repo=false
  for dep in "${MISSING[@]}"; do
    if [[ "$dep" == "glibc-runner" || "$dep" == "patchelf-glibc" ]]; then
      need_repo=true
      break
    fi
  done
  if $need_repo; then
    MISSING=(glibc-repo "${MISSING[@]}")
  fi
fi

if [ ${#MISSING[@]} -gt 0 ]; then
  echo "The following packages are required but not installed:"
  echo ""
  for dep in "${MISSING[@]}"; do
    echo "  - $dep"
  done
  echo ""
  read -rp "Install them now? [Y/n] " ans
  if [[ "$ans" =~ ^[Nn] ]]; then
    echo "Cannot continue without dependencies." >&2
    exit 1
  fi

  # If glibc-repo is in the list, install it first
  if [[ " ${MISSING[*]} " =~ " glibc-repo " ]]; then
    apt install -y glibc-repo
    remaining=()
    for dep in "${MISSING[@]}"; do
      [ "$dep" != "glibc-repo" ] && remaining+=("$dep")
    done
    MISSING=("${remaining[@]}")
  fi

  if [ ${#MISSING[@]} -gt 0 ]; then
    apt install -y "${MISSING[@]}"
  fi

  echo ""
  echo "Dependencies installed."
fi

# python3 preferred for the binary patch; fall back to perl.
if command -v python3 &>/dev/null; then
  PATCHER=python3
else
  if ! dpkg -s perl &>/dev/null; then
    echo "python3 not found; installing perl for binary patching..."
    apt install -y perl
  fi
  PATCHER=perl
fi

# ---------------------------------------------------------------------------
# Version check
# ---------------------------------------------------------------------------

LATEST=$(curl -fsSL "$BASE_URL/latest")
if ! [[ "$LATEST" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Failed to fetch latest version (got: $LATEST)" >&2
  exit 1
fi
CURRENT=$("$WRAPPER" --version 2>/dev/null | awk '{print $1}' || echo "none")

if [ "$CURRENT" = "$LATEST" ] && [ $# -eq 0 ]; then
  echo "Already on latest: $CURRENT"
  exit 0
fi

VERSION="${1:-$LATEST}"
DL="$BASE_URL/$VERSION"

if [ "$CURRENT" = "none" ]; then
  echo "Installing Claude Code $VERSION ..."
else
  echo "Updating: $CURRENT -> $VERSION"
fi

# ---------------------------------------------------------------------------
# Download & verify
# ---------------------------------------------------------------------------

mkdir -p "$(dirname "$BINARY")" "$(dirname "$WRAPPER")"

tmp=$(mktemp)
patched=$tmp.patched
trap 'rm -f "$tmp" "$patched"' EXIT INT TERM

curl -fSL "$DL/linux-arm64/claude" -o "$tmp"

expected=$(curl -fsSL "$DL/manifest.json" | jq -er '.platforms["linux-arm64"].checksum')
actual=$(sha256sum "$tmp" | cut -d' ' -f1)
if [ "$actual" != "$expected" ]; then
  echo "Checksum mismatch: $actual != $expected" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Patchelf
# ---------------------------------------------------------------------------

# Set the ELF interpreter to glibc-runner's ld.so so the kernel can exec
# the binary directly — needed because Claude's bundled grep/find/rg
# re-exec it with argv[0]=ugrep/bfs/rg, and argv[0] only survives a
# kernel-direct exec (grun chains via ld.so and breaks it).
# LD_PRELOAD= stops termux-exec from crashing patchelf.
LD_PRELOAD= "$PATCHELF" --output "$patched" --set-interpreter "$GLIBC_LD" "$tmp"

# ---------------------------------------------------------------------------
# Binary patch: blank process.execPath
# ---------------------------------------------------------------------------

# Claude's grep/find/rg code reads process.execPath to know what binary to
# re-exec. With LD_PRELOAD re-injected (for shebang support), that re-exec
# would inherit the bionic preload and crash the glibc binary. Blanking the
# value makes them fall back to resolving "claude" from PATH, which finds
# the compiled wrapper below — a bionic ELF that clears LD_PRELOAD before
# exec'ing the real binary.
#
# The regex anchors on nearby code (TMUX assignment) to ensure exactly one
# match. The replacement is the same byte length to keep the file intact.
if [ "$PATCHER" = "python3" ]; then
  python3 - "$patched" <<'PY'
import sys, re
p = sys.argv[1]
data = open(p, "rb").read()
ident = rb"[A-Za-z_$][A-Za-z0-9_$]*"
anchor = re.compile(rb"((" + ident + rb")\[" + ident + rb"\]=)process\.execPath(,(" + ident + rb")\)\2\.TMUX=\4)")
matches = anchor.findall(data)
if len(matches) != 1:
    sys.exit(f"execPath patch: expected 1 match, got {len(matches)} (Bun output changed?)")
replacement = b'""' + b" " * 14
open(p, "wb").write(anchor.sub(lambda m: m.group(1) + replacement + m.group(3), data))
PY
else
  perl -0777 -pi -e '
    my $i = qr/[A-Za-z_\$][A-Za-z0-9_\$]*/;
    my $re = qr/(($i)\[$i\]=)process\.execPath(,($i)\)\2\.TMUX=\4\))/s;
    my @m = m/$re/g;
    die "execPath patch: expected 1 match, got " . (scalar(@m)/4) . " (Bun output changed?)\n"
      unless @m == 4;
    s/$re/$1""              $3/;
  ' "$patched"
fi

chmod +x "$patched"
mv "$patched" "$BINARY"
trap - EXIT INT TERM

# ---------------------------------------------------------------------------
# Compiled wrapper
# ---------------------------------------------------------------------------

# The wrapper must be a real ELF, not a #! script: when grep/find falls
# back to it (because process.execPath is blanked), a script wrapper would
# let the kernel discard argv[0]=ugrep, whereas execv() preserves it.
# Being a bionic binary, termux-exec loads into it naturally for shebang
# rewriting. It clears LD_PRELOAD before exec'ing the glibc claude binary.
cc -O2 -DBINARY="\"$BINARY\"" -o "$WRAPPER" -xc - <<'EOF'
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
  (void)argc;
  (void)unsetenv("LD_PRELOAD");
  execv(BINARY, argv);
  fprintf(stderr, "claude wrapper: execv %s failed: %s\n", BINARY, strerror(errno));
  return 127;
}
EOF

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------

mkdir -p "$(dirname "$SETTINGS")"

if [ ! -f "$SETTINGS" ]; then
  jq -n --arg val "$LD_PRELOAD_VAL" \
    '{ autoUpdates: false, env: { LD_PRELOAD: $val } }' > "$SETTINGS"
  echo "Created $SETTINGS"
elif ! jq empty "$SETTINGS" 2>/dev/null; then
  echo "Warning: $SETTINGS contains invalid JSON — skipping settings update."
  echo "Add these fields manually:"
  echo "  \"autoUpdates\": false"
  echo "  \"env\": { \"LD_PRELOAD\": \"$LD_PRELOAD_VAL\" }"
else
  changed=false
  tmp=$(mktemp)
  cp "$SETTINGS" "$tmp"

  if [ "$(jq '.autoUpdates' "$tmp")" != "false" ]; then
    jq '.autoUpdates = false' "$tmp" > "${tmp}.2" && mv "${tmp}.2" "$tmp"
    changed=true
  fi

  if [ "$(jq -r '.env.LD_PRELOAD // empty' "$tmp")" != "$LD_PRELOAD_VAL" ]; then
    jq --arg val "$LD_PRELOAD_VAL" '.env.LD_PRELOAD = $val' "$tmp" > "${tmp}.2" && mv "${tmp}.2" "$tmp"
    changed=true
  fi

  if [ "$changed" = true ]; then
    mv "$tmp" "$SETTINGS"
    echo "Updated $SETTINGS"
  else
    rm -f "$tmp"
    echo "Settings already configured."
  fi
fi

# ---------------------------------------------------------------------------
# Shell RC — ensure ~/.local/bin is on PATH
# ---------------------------------------------------------------------------

WRAPPER_DIR="$(dirname "$WRAPPER")"
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'

add_to_rc() {
  local rc="$1"
  if [ -f "$rc" ] && grep -qF '/.local/bin' "$rc"; then
    echo "PATH already configured in $rc"
  else
    echo "" >> "$rc"
    echo "$PATH_LINE" >> "$rc"
    echo "Added ~/.local/bin to PATH in $rc"
    echo "Run 'source $rc' or restart your shell to apply."
  fi
}

case "$(basename "$SHELL")" in
  zsh)  add_to_rc ~/.zshrc ;;
  bash) add_to_rc ~/.bashrc ;;
  *)
    if [ -f ~/.profile ]; then
      add_to_rc ~/.profile
    else
      echo ""
      echo "Could not detect your shell RC file."
      echo "Add this line manually:"
      echo ""
      echo "  $PATH_LINE"
    fi
    ;;
esac

# Ensure the wrapper is findable for the npm-detection step below.
case ":$PATH:" in
  *:"$WRAPPER_DIR":*) ;;
  *) export PATH="$WRAPPER_DIR:$PATH" ;;
esac

# ---------------------------------------------------------------------------
# Check for old npm-installed Claude Code
# ---------------------------------------------------------------------------

NPM_CLAUDE=""
while IFS= read -r p; do
  real="$(readlink -f "$p" 2>/dev/null || echo "$p")"
  if [ "$real" != "$(readlink -f "$WRAPPER" 2>/dev/null)" ] && \
     [ "$real" != "$(readlink -f "$BINARY" 2>/dev/null)" ]; then
    NPM_CLAUDE="$p"
    break
  fi
done < <(which -a claude 2>/dev/null || true)

if [ -n "$NPM_CLAUDE" ]; then
  NPM_DIR="$(dirname "$NPM_CLAUDE")"
  echo ""
  echo "=========================================="
  echo "  Old Claude Code installation detected"
  echo "=========================================="
  echo ""
  echo "  Location: $NPM_CLAUDE"
  echo ""
  echo "  The native binary has been installed, but the old"
  echo "  version is still on your PATH and may take priority"
  echo "  or cause confusion."
  echo ""
  echo "  What would you like to do?"
  echo ""
  echo "  1) Rename it  — keep the old binary under a different name"
  echo "  2) Uninstall  — remove the npm package entirely"
  echo "  3) Do nothing — leave it as-is"
  echo ""
  read -rp "  Choose [1/2/3]: " choice

  case "$choice" in
    1)
      read -rp "  Enter new name for the old binary (e.g. claudo): " newname
      if [ -z "$newname" ]; then
        echo "  No name entered, skipping."
      elif [ -e "$NPM_DIR/$newname" ]; then
        echo "  $NPM_DIR/$newname already exists, skipping."
      else
        mv "$NPM_CLAUDE" "$NPM_DIR/$newname"
        echo ""
        echo "  Renamed: $NPM_CLAUDE -> $NPM_DIR/$newname"
        echo "  You can still use the old version as '$newname'."
      fi
      ;;
    2)
      echo ""
      echo "  Uninstalling npm Claude Code ..."
      npm uninstall -g @anthropic-ai/claude-code
      echo "  Done."
      ;;
    3)
      echo ""
      echo "  Leaving old installation in place."
      echo ""
      echo "  Note: both versions respond to the 'claude' command."
      echo "  Which one runs depends on PATH order. Currently:"
      echo "    $(which claude 2>/dev/null || echo '(not found)')"
      echo "  If that's not the native version, reorder your PATH"
      echo "  so that ~/.local/bin comes before $NPM_DIR."
      ;;
    *)
      echo "  Invalid choice, skipping."
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

echo ""
echo "Claude Code $VERSION is ready. Run 'claude' to start."
