#!/usr/bin/env bash
# sudsy's test suite. Needs sops and age on PATH; everything else runs in throwaway dirs.
#   bash test/test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUDSY="$ROOT/bin/sudsy"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset SOPS_AGE_KEY SOPS_AGE_KEY_FILE SOPS_AGE_KEY_CMD XDG_CONFIG_HOME

pass=0 fail=0 current=""
ok() { pass=$((pass + 1)); echo "  ✓ $current"; }
bad() { fail=$((fail + 1)); echo "  ✗ $current: $*"; }
check() { if "$@"; then ok; else bad "failed: $*"; fi; }
eq() { if [ "$1" = "$2" ]; then ok; else bad "expected [$2], got [$1]"; fi; }

# A fresh project dir + fresh $HOME per test; `user` names the person running sudsy.
fresh() { current="$1"; rm -rf "$TMP/p" "$TMP/home"; mkdir -p "$TMP/p" "$TMP/home"; cd "$TMP/p"; }
as() { local who="$1"; shift; HOME="$TMP/home/$who" "$SUDSY" "$@"; }
# Non-interactive "editor": sops calls it with the temp file path, we overwrite it.
write_vault() { local who="$1" env="$2" body="$3"; BODY="$body" SOPS_EDITOR='sh -c "printf %s \"\$BODY\" > \"\$0\""' as "$who" edit "$env" >/dev/null; }

echo "sudsy tests"

fresh "version matches package.json"
pkg="$(grep '"version"' "$ROOT/package.json" | sed 's/.*"\([0-9][^"]*\)".*/\1/')"
eq "$("$SUDSY" version)" "sudsy $pkg"

fresh "help works with no args"
check sh -c "'$SUDSY' | grep -q 'squeaky-clean'"

fresh "unknown command fails"
check sh -c "! '$SUDSY' scrub 2>/dev/null"

fresh "init creates a global key and .sops.yaml"
as alice init >/dev/null
check test -f "$TMP/home/alice/.config/sops/age/keys.txt"
current="init writes alice's public key to .sops.yaml"
check grep -qF "$(as alice key)" .sops.yaml

fresh "init twice is a no-op"
as alice init >/dev/null; before="$(cat .sops.yaml)"
as alice init >/dev/null
eq "$(cat .sops.yaml)" "$before"

fresh "init appends to an existing recipient list, keeping indent"
as alice init >/dev/null
as bob init >/dev/null
expected="$(printf 'creation_rules:\n  - path_regex: \\.enc\\.\n    age: >-\n      %s,\n      %s' "$(as alice key)" "$(as bob key)")"
eq "$(cat .sops.yaml)" "$expected"

fresh "key file is private"
as alice init >/dev/null
perms="$(ls -l "$TMP/home/alice/.config/sops/age/keys.txt" | cut -c1-10)"
eq "$perms" "-rw-------"

fresh "edit creates an encrypted vault, cat decrypts it"
as alice init >/dev/null
write_vault alice dev $'# hi\nAPI_KEY=sekrit\n'
check sh -c "! grep -q sekrit dev.enc.env"
current="cat decrypts it"
eq "$(as alice cat dev)" $'# hi\nAPI_KEY=sekrit'

fresh "edit without .sops.yaml explains what to do"
check sh -c "HOME='$TMP/home/alice' '$SUDSY' edit dev 2>&1 | grep -q 'sudsy init'"

fresh "edit with no changes is not an error"
as alice init >/dev/null
write_vault alice dev $'A=1\n'
check sh -c "SOPS_EDITOR=true HOME='$TMP/home/alice' '$SUDSY' edit dev >/dev/null"

fresh "env names accept <env>.enc.env and paths"
as alice init >/dev/null
write_vault alice dev $'A=1\n'
eq "$(as alice cat ./dev.enc.env)" "A=1"

fresh "run exports secrets and keeps args intact"
as alice init >/dev/null
write_vault alice dev $'GREETING=hello world\nQUOTE=it\'s\n'
out="$(as alice run dev -- sh -c 'printf "%s|%s|%s|%s" "$GREETING" "$QUOTE" "$1" "$2"' _ "two words" "it's \$HOME")"
eq "$out" "hello world|it's|two words|it's \$HOME"

fresh "run works without the -- separator"
as alice init >/dev/null
write_vault alice dev $'A=1\n'
eq "$(as alice run dev printenv A)" "1"

fresh "run passes through the exit code"
as alice init >/dev/null
write_vault alice dev $'A=1\n'
as alice run dev -- sh -c 'exit 7' 2>/dev/null
eq "$?" "7"

fresh "run passes stdin through"
as alice init >/dev/null
write_vault alice dev $'A=1\n'
eq "$(echo bubbles | as alice run dev -- cat)" "bubbles"

fresh "json prints an object without comments"
as alice init >/dev/null
write_vault alice dev $'# note\nA=1\nB=two\n'
eq "$(as alice json dev | tr -d ' \t\n')" '{"A":"1","B":"two"}'

fresh "get prints one value"
as alice init >/dev/null
write_vault alice dev $'A=1\nB=two words\n'
eq "$(as alice get dev B)" "two words"

fresh "get fails on a missing key"
as alice init >/dev/null
write_vault alice dev $'A=1\n'
check sh -c "! HOME='$TMP/home/alice' '$SUDSY' get dev NOPE 2>/dev/null"

fresh "missing vault is a friendly error"
as alice init >/dev/null
check sh -c "HOME='$TMP/home/alice' '$SUDSY' cat prod 2>&1 | grep -q 'no prod.enc.env here'"

fresh "ls lists environments"
as alice init >/dev/null
write_vault alice dev $'A=1\n'; write_vault alice prod $'A=2\n'
eq "$(as alice ls | tr '\n' ' ')" "dev prod "

fresh "a new teammate can decrypt after sync"
as alice init >/dev/null
write_vault alice dev $'A=1\n'
as bob init >/dev/null
check sh -c "! HOME='$TMP/home/bob' '$SUDSY' cat dev >/dev/null 2>&1"
current="sync --yes re-encrypts for bob"
as alice sync --yes >/dev/null 2>&1
eq "$(as bob cat dev)" "A=1"

fresh "sync without a terminal refuses unless --yes"
as alice init >/dev/null
write_vault alice dev $'A=1\n'
as bob init >/dev/null
before="$(cat dev.enc.env)"
check sh -c "HOME='$TMP/home/alice' '$SUDSY' sync </dev/null 2>&1 | grep -q 'pass --yes'"
current="the refused sync leaves the vault alone"
eq "$(cat dev.enc.env)" "$before"

fresh "sync rejects unknown options"
as alice init >/dev/null
write_vault alice dev $'A=1\n'
check sh -c "! HOME='$TMP/home/alice' '$SUDSY' sync --force 2>/dev/null"

# Run sudsy as <who> with a pseudo-terminal on stdin, answering sops's prompt with <answer>.
# The answer waits a moment: BSD script passes input on at once, and typing that arrives
# before sops asks is lost. util-linux and BSD script take their arguments differently.
at_tty() {
  local answer="$1" who="$2"; shift 2
  local cmd="HOME='$TMP/home/$who' '$SUDSY' $*"
  if script --version >/dev/null 2>&1; then
    { sleep 1; printf '%s\n' "$answer"; } | script -qec "$cmd" /dev/null
  else
    { sleep 1; printf '%s\n' "$answer"; } | script -q /dev/null sh -c "$cmd"
  fi
}

fresh "sync at a terminal shows the new key and re-encrypts on yes"
as alice init >/dev/null
write_vault alice dev $'A=1\n'
as bob init >/dev/null
out="$(at_tty y alice sync 2>&1)"
check sh -c "printf '%s' \"\$1\" | grep -qF \"+++ \$2\"" _ "$out" "$(as bob key)"
current="bob can decrypt after yes"
eq "$(as bob cat dev)" "A=1"

fresh "sync at a terminal leaves the vault alone on no"
as alice init >/dev/null
write_vault alice dev $'A=1\n'
as bob init >/dev/null
before="$(cat dev.enc.env)"
out="$(at_tty n alice sync 2>&1)"
check sh -c "printf '%s' \"\$1\" | grep -q 'left unchanged'" _ "$out"
current="the declined vault is untouched"
eq "$(cat dev.enc.env)" "$before"

fresh "./secret.txt wins over the global key"
as alice init >/dev/null
cp "$TMP/home/alice/.config/sops/age/keys.txt" secret.txt
rm "$TMP/home/alice/.config/sops/age/keys.txt"
write_vault alice dev $'A=1\n'
eq "$(as alice cat dev)" "A=1"

fresh "init with ./secret.txt adds it to .gitignore"
mkdir .git; (umask 077; age-keygen -o secret.txt 2>/dev/null)
as alice init >/dev/null
eq "$(cat .gitignore)" "secret.txt"

fresh "SOPS_AGE_KEY_FILE overrides everything"
as alice init >/dev/null
write_vault alice dev $'A=1\n'
mv "$TMP/home/alice/.config/sops/age/keys.txt" "$TMP/elsewhere.txt"
eq "$(SOPS_AGE_KEY_FILE="$TMP/elsewhere.txt" as alice cat dev)" "A=1"

fresh "SOPS_AGE_KEY works with no key file (CI)"
as alice init >/dev/null
write_vault alice dev $'A=1\n'
secret="$(grep AGE-SECRET "$TMP/home/alice/.config/sops/age/keys.txt")"
eq "$(SOPS_AGE_KEY="$secret" as ci cat dev)" "A=1"

# A stand-in password manager: the key lives outside every place sudsy looks for a file.
fresh "SOPS_AGE_KEY_CMD: init uses the command's key and writes no key file"
(umask 077; age-keygen -o "$TMP/manager key.txt" 2>/dev/null)
export SOPS_AGE_KEY_CMD="cat '$TMP/manager key.txt'"
as alice init >/dev/null
check test ! -e "$TMP/home/alice/.config/sops/age/keys.txt"
current="SOPS_AGE_KEY_CMD: .sops.yaml gets the command's public key"
check grep -qF "$(age-keygen -y "$TMP/manager key.txt")" .sops.yaml
current="SOPS_AGE_KEY_CMD: key prints the same public key"
eq "$(as alice key)" "$(age-keygen -y "$TMP/manager key.txt")"
current="SOPS_AGE_KEY_CMD: edit and cat work with no key file"
write_vault alice dev $'A=1\n'
eq "$(as alice cat dev)" "A=1"

fresh "SOPS_AGE_KEY_CMD: a command that prints no key is a clear error"
export SOPS_AGE_KEY_CMD="echo nope"
check sh -c "HOME='$TMP/home/alice' '$SUDSY' key 2>&1 | grep -q 'SOPS_AGE_KEY_CMD did not print'"
current="SOPS_AGE_KEY_CMD: the failed init writes no .sops.yaml"
as alice init >/dev/null 2>&1
check test ! -e .sops.yaml

# sudsy splits the command the way sops does, so quoting that works for one works for both.
fresh "SOPS_AGE_KEY_CMD: escaped quotes inside double quotes"
(umask 077; age-keygen -o "$TMP/age \"key\".txt" 2>/dev/null)
export SOPS_AGE_KEY_CMD="cat \"$TMP/age \\\"key\\\".txt\""
as alice init >/dev/null
eq "$(as alice key)" "$(age-keygen -y "$TMP/age \"key\".txt")"
current="SOPS_AGE_KEY_CMD: sops reads the same escaped command"
write_vault alice dev $'A=1\n'
eq "$(as alice cat dev)" "A=1"

fresh "SOPS_AGE_KEY_CMD: single quotes, with an apostrophe spliced in"
(umask 077; age-keygen -o "$TMP/it's key.txt" 2>/dev/null)
export SOPS_AGE_KEY_CMD="cat '$TMP/it'\"'\"'s key.txt'"
as alice init >/dev/null
eq "$(as alice key)" "$(age-keygen -y "$TMP/it's key.txt")"
current="SOPS_AGE_KEY_CMD: sops reads the same single-quoted command"
write_vault alice dev $'A=1\n'
eq "$(as alice cat dev)" "A=1"

fresh "SOPS_AGE_KEY_CMD: an unterminated quote is a clear error"
export SOPS_AGE_KEY_CMD="cat \"$TMP/manager key.txt"
check sh -c "HOME='$TMP/home/alice' '$SUDSY' key 2>&1 | grep -q 'check its quotes'"

fresh "SOPS_AGE_KEY_FILE wins over SOPS_AGE_KEY_CMD"
export SOPS_AGE_KEY_CMD="echo nope"
(umask 077; age-keygen -o "$TMP/file.txt" 2>/dev/null)
eq "$(SOPS_AGE_KEY_FILE="$TMP/file.txt" as alice key)" "$(age-keygen -y "$TMP/file.txt")"
unset SOPS_AGE_KEY_CMD

fresh "no key at all is a friendly error"
as alice init >/dev/null
write_vault alice dev $'A=1\n'
check sh -c "HOME='$TMP/home/nobody' '$SUDSY' cat dev 2>&1 | grep -q 'no age key found'"

echo
if [ "$fail" -eq 0 ]; then echo "🫧 $pass passed. Squeaky clean."; else echo "$fail failed, $pass passed."; exit 1; fi
