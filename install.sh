#!/bin/sh
set -eu

fail() { printf 'SuperShell: %s\n' "$*" >&2; exit 1; }
for tool in curl tar awk grep mktemp; do
  command -v "$tool" >/dev/null 2>&1 || fail "Required command missing: $tool"
done
case "$(uname -s)" in
  Darwin) os=darwin ;;
  Linux) os=linux ;;
  *) fail 'Supported systems: macOS and Linux.' ;;
esac
case "$(uname -m)" in
  arm64|aarch64) arch=arm64 ;;
  x86_64|amd64) arch=x64 ;;
  *) fail 'Supported processors: arm64 and x64.' ;;
esac
if command -v sha256sum >/dev/null 2>&1; then
  hash() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
  hash() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  fail 'SHA256 verification needs sha256sum or shasum.'
fi
repo=${SUPERSHELL_RELEASES_REPO:-kodenark/supershell-releases}
base=${SUPERSHELL_RELEASES_URL:-https://github.com/$repo/releases}
case "$base" in
  https://*|http://127.0.0.1:*|http://localhost:*) ;;
  *) fail 'The releases URL must use HTTPS (or localhost for tests).' ;;
esac
version=${SUPERSHELL_VERSION:-}
if [ -z "$version" ]; then
  latest=$(curl -fsSL --connect-timeout 10 --max-time 30 -o /dev/null -w '%{url_effective}' "$base/latest") || fail 'Cannot find the latest release.'
  version=${latest##*/}
fi
printf '%s\n' "$version" | grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[A-Za-z0-9.-]+)?$' || fail 'SUPERSHELL_VERSION must be a version such as v1.2.3.'
root=${SUPERSHELL_INSTALL_DIR:-$HOME/.supershell}
mkdir -p "$root/versions" "$root/bin"
mkdir "$root/.install-lock" 2>/dev/null || fail "Another install is running, or remove stale $root/.install-lock."
work=
cleanup() {
  [ -z "$work" ] || rm -rf "$work"
  rm -f "$root/.current-$$" "$root/bin/.supershell-$$"
  rmdir "$root/.install-lock"
}
trap cleanup 0
trap 'exit 1' 1 2 15
work=$(mktemp -d "$root/versions/.install-XXXXXXXX")
asset=supershell-$version-$os-$arch.tar.gz
download() {
  if [ "${SUPERSHELL_UPDATE:-0}" = 1 ] && [ -n "${SUPERSHELL_UPDATE_DOWNLOAD_DIR:-}" ]; then
    cp "$SUPERSHELL_UPDATE_DOWNLOAD_DIR/$1" "$work/$1" || fail "Cannot read downloaded $1."
  else
    curl -fsSL --connect-timeout 10 --max-time 300 "$base/download/$version/$1" -o "$work/$1" || fail "Cannot download $1 from $repo."
  fi
}
download SHA256SUMS
download "$asset"
expected=$(awk -v name="$asset" '$2 == name { print $1; count++ } END { if (count != 1) exit 1 }' "$work/SHA256SUMS") || fail "Missing or duplicate checksum for $asset."
printf '%s\n' "$expected" | grep -Eq '^[a-fA-F0-9]{64}$' || fail 'Invalid SHA256 checksum.'
actual=$(hash "$work/$asset")
[ "$actual" = "$expected" ] || fail 'SHA256 mismatch; the current installation was kept.'
tar -tzf "$work/$asset" > "$work/entries" || fail 'Invalid release archive.'
while IFS= read -r entry; do
  entry=${entry#./}
  case "$entry" in
    ''|.) continue ;;
    /*|..|../*|*/../*|*/..|*/./*) fail 'Unsafe release archive path.' ;;
    bin|bin/|bin/supershell|chrome|chrome/*|native|native/*|LICENSES.txt) ;;
    *) fail "Unexpected release archive path: $entry" ;;
  esac
done < "$work/entries"
tar -tvzf "$work/$asset" | awk 'substr($0,1,1) != "-" && substr($0,1,1) != "d" { exit 1 }' || fail 'Release archives cannot contain links or special files.'
mkdir "$work/unpacked"
tar -xzf "$work/$asset" -C "$work/unpacked"
binary=$work/unpacked/bin/supershell
[ -x "$binary" ] || fail 'The release has no executable bin/supershell.'
reported=$(SUPERSHELL_MEASUREMENTS=0 "$binary" --version) || fail 'The downloaded binary cannot run on this system.'
[ "$reported" = "${version#v}" ] || fail 'The binary version does not match the release.'
[ "${SUPERSHELL_UPDATE:-0}" != 1 ] || printf 'SUPERSHELL_UPDATE:installing\n'
destination=$root/versions/$version
if [ -e "$destination" ]; then
  if [ ! -f "$destination/.archive.sha256" ] || [ "$(cat "$destination/.archive.sha256")" != "$actual" ]; then
    fail "Version $version already exists with different contents."
  fi
else
  printf '%s\n' "$actual" > "$work/unpacked/.archive.sha256"
  mv "$work/unpacked" "$destination"
fi

# These OS-specific mv flags replace a symlink to a directory instead of following it.
replace_link() {
  ln -s "$1" "$2"
  case "$os" in
    darwin) mv -fh "$2" "$3" ;;
    linux) mv -fT "$2" "$3" ;;
  esac
}
replace_link "versions/$version" "$root/.current-$$" "$root/current"
replace_link '../current/bin/supershell' "$root/bin/.supershell-$$" "$root/bin/supershell"

if [ "${SUPERSHELL_UPDATE:-0}" != 1 ]; then
  case "${SHELL:-/bin/sh}" in
    */zsh) rc=${ZDOTDIR:-$HOME}/.zshrc; path_line="export PATH=\"\$HOME/.supershell/bin:\$PATH\"" ;;
    */bash)
      if [ "$os" = darwin ]; then rc=$HOME/.bash_profile; else rc=$HOME/.bashrc; fi
      path_line="export PATH=\"\$HOME/.supershell/bin:\$PATH\"" ;;
    */fish) rc=$HOME/.config/fish/config.fish; path_line="fish_add_path \"\$HOME/.supershell/bin\"" ;;
    *) rc=$HOME/.profile; path_line="export PATH=\"\$HOME/.supershell/bin:\$PATH\"" ;;
  esac
  mkdir -p "$(dirname "$rc")"
  if ! grep -Fqx "$path_line" "$rc" 2>/dev/null; then printf '\n%s\n' "$path_line" >> "$rc"; fi
  printf 'PATH is configured in %s. Open a new terminal to use supershell.\n' "$rc"
fi
SUPERSHELL_MEASUREMENTS=0 "$root/bin/supershell" --version
printf 'Installed %s. Update: supershell update\n' "$version"
printf 'Uninstall: remove ~/.supershell/bin, versions and current; remove the PATH line from your shell config.\n'
