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

# alice and bob can both read dev; alice revokes bob.
two_readers() { as alice init >/dev/null; as bob init >/dev/null; write_vault alice dev $'A=1\nB=two\n'; }

fresh "revoke removes the key, so it can no longer decrypt"
two_readers
before_a="$(grep '^A=' dev.enc.env)"
out="$(as alice revoke --yes "$(as bob key)" 2>&1)"
check sh -c "! HOME='$TMP/home/bob' '$SUDSY' cat dev >/dev/null 2>&1"
current="revoke leaves .sops.yaml as init would have written it for alice alone"
eq "$(cat .sops.yaml)" "$(printf 'creation_rules:\n  - path_regex: \\.enc\\.\n    age: >-\n      %s' "$(as alice key)")"
current="revoke gives the vault a new data key"
check test "$(grep '^A=' dev.enc.env)" != "$before_a"
current="revoke lists the secret names to rotate, never the values"
check sh -c "printf '%s' \"\$1\" | grep -qF 'dev.enc.env: A B' && ! printf '%s' \"\$1\" | grep -q 'two'" _ "$out"
current="alice still reads dev after revoke"
eq "$(as alice cat dev)" $'A=1\nB=two'

fresh "revoke refuses without a terminal unless --yes, and changes nothing"
two_readers
before="$(cat .sops.yaml)"
check sh -c "! HOME='$TMP/home/alice' '$SUDSY' revoke '$(as bob key)' </dev/null 2>/dev/null"
current="the refused revoke leaves .sops.yaml alone"
eq "$(cat .sops.yaml)" "$before"

fresh "revoke refuses your own key, and a key that is not there"
two_readers
check sh -c "HOME='$TMP/home/alice' '$SUDSY' revoke --yes '$(as alice key)' 2>&1 | grep -q 'your own key'"
current="revoke of an unknown key fails"
check sh -c "HOME='$TMP/home/alice' '$SUDSY' revoke --yes '$(age-keygen 2>/dev/null | age-keygen -y)' 2>&1 | grep -q 'is not in'"

fresh "revoke will not leave a rule with no readers"
as alice init >/dev/null; write_vault alice dev $'A=1\n'
as bob init >/dev/null; printf 'creation_rules:\n  - path_regex: \\.enc\\.\n    age: >-\n      %s\n' "$(as bob key)" > .sops.yaml
before="$(cat .sops.yaml)"
check sh -c "HOME='$TMP/home/alice' '$SUDSY' revoke --yes '$(as bob key)' 2>&1 | grep -q 'no readers'"
current="the refused revoke leaves .sops.yaml alone"
eq "$(cat .sops.yaml)" "$before"

fresh "revoke declined at a terminal says the vault is still readable"
two_readers
out="$(at_tty n alice revoke "$(as bob key)" 2>&1)"
check sh -c "printf '%s' \"\$1\" | grep -q 'still readable'" _ "$out"
current="bob can still read the declined vault"
eq "$(as bob cat dev)" $'A=1\nB=two'
current="the declined revoke says to rerun revoke, not sync"
check sh -c "printf '%s' \"\$1\" | grep -qF 'run: sudsy revoke'" _ "$out"
current="rerunning revoke finishes it: bob is out and the vault has a new data key"
before_a="$(grep '^A=' dev.enc.env)"
out="$(as alice revoke --yes "$(as bob key)" 2>&1)"
check sh -c "! HOME='$TMP/home/bob' '$SUDSY' cat dev >/dev/null 2>&1 && test \"\$(grep '^A=' dev.enc.env)\" != '$before_a'"
current="the finished revoke lists the secrets to rotate"
check sh -c "printf '%s' \"\$1\" | grep -qF 'dev.enc.env: A B'" _ "$out"

fresh "revoke refuses your own key when it comes from SOPS_AGE_KEY, and changes nothing"
two_readers
mv "$TMP/home/alice/.config/sops/age/keys.txt" "$TMP/alice.key"
before="$(cat .sops.yaml)"
check sh -c "SOPS_AGE_KEY=\"\$(cat '$TMP/alice.key')\" HOME='$TMP/home/alice' '$SUDSY' revoke --yes \"\$(age-keygen -y '$TMP/alice.key')\" 2>&1 | grep -q 'your own key'"
current="the refused revoke leaves .sops.yaml alone"
eq "$(cat .sops.yaml)" "$before"

fresh "revoke does not count a commented-out key as a reader"
as alice init >/dev/null; write_vault alice dev $'A=1\n'
as bob init >/dev/null
printf 'creation_rules:\n  - path_regex: \\.enc\\.\n    # age: %s\n    age: >-\n      %s\n' "$(as alice key)" "$(as bob key)" > .sops.yaml
before="$(cat .sops.yaml)"
check sh -c "HOME='$TMP/home/alice' '$SUDSY' revoke --yes '$(as bob key)' 2>&1 | grep -q 'no readers'"
current="the refused revoke leaves .sops.yaml alone"
eq "$(cat .sops.yaml)" "$before"

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

fresh "no key at all is a friendly error"
as alice init >/dev/null
write_vault alice dev $'A=1\n'
check sh -c "HOME='$TMP/home/nobody' '$SUDSY' cat dev 2>&1 | grep -q 'no age key found'"

echo
if [ "$fail" -eq 0 ]; then echo "🫧 $pass passed. Squeaky clean."; else echo "$fail failed, $pass passed."; exit 1; fi
