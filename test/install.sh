#!/usr/bin/env bash
# Offline tests: mock GitHub's responses, use real checksums and filesystem writes.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/mock" "$tmp/fixture" "$tmp/bin"
cp "$root/bin/sudsy" "$tmp/fixture/sudsy"
version="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$root/bin/sudsy")"
(cd "$tmp/fixture"; if command -v sha256sum >/dev/null; then sha256sum sudsy; else shasum -a 256 sudsy; fi > sudsy.sha256)
export FIXTURE="$tmp/fixture" TEST_TAG="v$version" TEST_LOG="$tmp/requests"
# Ensure tests do not reach the network. Accept the exact URLs the installer uses.
cat > "$tmp/mock/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""; url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w|--proto|--proto-redir|--retry|--connect-timeout) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\n' "$url" >> "$TEST_LOG"
base=https://github.com/monotropiclabs/sudsy/releases
case "$url" in
  "$base/latest") printf '%s/tag/%s' "$base" "$TEST_TAG" ;;
  "$base/download/$TEST_TAG/sudsy") cp "$FIXTURE/sudsy" "$out" ;;
  "$base/download/$TEST_TAG/sudsy.sha256") cp "$FIXTURE/sudsy.sha256" "$out" ;;
  *) echo "unexpected URL: $url" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/mock/curl"
# CI installs the real dependencies before this test.
export PATH="$tmp/mock:$PATH"
install_sudsy() { bash "$root/docs/install.sh" --bin-dir "$tmp/bin" "$@"; }
install_sudsy
cmp "$tmp/fixture/sudsy" "$tmp/bin/sudsy"
test -x "$tmp/bin/sudsy"
grep -Fx "https://github.com/monotropiclabs/sudsy/releases/latest" "$TEST_LOG"
: > "$TEST_LOG"
install_sudsy --version "$version"
if grep -q '/latest$' "$TEST_LOG"; then echo 'pinned install queried latest' >&2; exit 1; fi
cp "$tmp/bin/sudsy" "$tmp/original"
printf '\n# corrupted\n' >> "$FIXTURE/sudsy"
if install_sudsy --version "$TEST_TAG"; then echo 'accepted corrupt artifact' >&2; exit 1; fi
cmp "$tmp/original" "$tmp/bin/sudsy"
: > "$TEST_LOG"
if install_sudsy --version 'oops/evil'; then echo 'accepted bad version' >&2; exit 1; fi
test ! -s "$TEST_LOG"
bash "$root/docs/install.sh" --help >/dev/null
echo "installer tests passed"
