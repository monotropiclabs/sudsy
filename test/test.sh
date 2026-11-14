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

fresh "init ignores a commented-out key after the recipient list"
as alice init >/dev/null
old="$(age-keygen 2>/dev/null | age-keygen -y)"
printf '    # revoked: %s\n' "$old" >> .sops.yaml
as bob init >/dev/null
expected="$(printf 'creation_rules:\n  - path_regex: \\.enc\\.\n    age: >-\n      %s,\n      %s\n    # revoked: %s' "$(as alice key)" "$(as bob key)" "$old")"
eq "$(cat .sops.yaml)" "$expected"
current="a vault made after that init opens for the new reader"
write_vault alice dev $'A=1\n'
eq "$(as bob cat dev)" "A=1"

fresh "init does not count a commented-out copy of your key as access"
as alice init >/dev/null
mkdir -p "$TMP/home/bob/.config/sops/age" && age-keygen -o "$TMP/home/bob/.config/sops/age/keys.txt" 2>/dev/null
printf '# was: %s\n' "$(as bob key)" >> .sops.yaml
out="$(as bob init 2>&1)"
check sh -c "! printf '%s' \"\$1\" | grep -q 'already in'" _ "$out"
current="the key is added to the real list"
check sh -c "sed -n 5p .sops.yaml | grep -qxF '      $(as bob key)'"

fresh "init extends an inline age: list, keeping its comment"
as alice init >/dev/null
printf 'creation_rules:\n  - path_regex: \\.enc\\.\n    age: %s # alice\n' "$(as alice key)" > .sops.yaml
as bob init >/dev/null
expected="$(printf 'creation_rules:\n  - path_regex: \\.enc\\.\n    age: %s,%s # alice' "$(as alice key)" "$(as bob key)")"
eq "$(cat .sops.yaml)" "$expected"
current="a vault made after the inline init opens for the new reader"
write_vault alice dev $'A=1\n'
eq "$(as bob cat dev)" "A=1"

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

fresh "grant lets a key read one environment only"
as alice init >/dev/null
write_vault alice dev $'A=1\n'; write_vault alice prod $'A=2\n'
as ci init >/dev/null; rm .sops.yaml; as alice init >/dev/null
as alice grant dev "$(as ci key)" >/dev/null
as alice sync --yes >/dev/null 2>&1
eq "$(as ci cat dev)" "A=1"
current="the granted key still cannot read prod"
check sh -c "! HOME='$TMP/home/ci' '$SUDSY' cat prod >/dev/null 2>&1"
current="everyone who could read dev still can"
eq "$(as alice cat dev)" "A=1"

fresh "grant puts the env's rule before the catch-all"
as alice init >/dev/null
as ci init >/dev/null; rm .sops.yaml; as alice init >/dev/null
as alice grant dev "$(as ci key)" >/dev/null
expected="$(printf 'creation_rules:\n  - path_regex: (^|/)dev\\.enc\\.env$\n    age: >-\n      %s,\n      %s\n  - path_regex: \\.enc\\.\n    age: >-\n      %s' "$(as alice key)" "$(as ci key)" "$(as alice key)")"
eq "$(cat .sops.yaml)" "$expected"

fresh "grant twice is a no-op, and a second key joins the same rule"
as alice init >/dev/null
as ci init >/dev/null; as bob init >/dev/null; rm .sops.yaml; as alice init >/dev/null
as alice grant dev "$(as ci key)" >/dev/null; before="$(cat .sops.yaml)"
as alice grant dev.enc.env "$(as ci key)" >/dev/null
eq "$(cat .sops.yaml)" "$before"
current="a second grant appends to dev's rule"
as alice grant dev "$(as bob key)" >/dev/null
write_vault alice dev $'A=1\n'
eq "$(as bob cat dev)$(as ci cat dev)" "A=1A=1"

fresh "a new teammate is told which rules they are not in"
as alice init >/dev/null
as ci init >/dev/null; rm .sops.yaml; as alice init >/dev/null
as alice grant dev "$(as ci key)" >/dev/null
check sh -c "HOME='$TMP/home/bob' '$SUDSY' init | grep -q 'sudsy grant <env>'"

fresh "grant rejects bad input"
as alice init >/dev/null
check sh -c "! HOME='$TMP/home/alice' '$SUDSY' grant dev age1NOPE 2>/dev/null"
current="grant rejects an env name that is not a plain word"
check sh -c "! HOME='$TMP/home/alice' '$SUDSY' grant 'a.b' '$(as alice key)' 2>/dev/null"
current="grant needs the catch-all rule"
printf 'creation_rules:\n  - path_regex: dev\n    age: %s\n' "$(as alice key)" > .sops.yaml
check sh -c "HOME='$TMP/home/alice' '$SUDSY' grant dev '$(as alice key)' 2>&1 | grep -q 'by hand'"

fresh "grant to dev does not reach an env whose name starts with dev.enc."
as alice init >/dev/null
write_vault alice dev $'A=1\n'; write_vault alice dev.enc.prod $'A=2\n'
as ci init >/dev/null; rm .sops.yaml; as alice init >/dev/null
as alice grant dev "$(as ci key)" >/dev/null
as alice sync --yes >/dev/null 2>&1
eq "$(as ci cat dev)" "A=1"
current="the granted key cannot read dev.enc.prod"
check sh -c "! HOME='$TMP/home/ci' '$SUDSY' cat dev.enc.prod >/dev/null 2>&1"

fresh "grant ignores a commented-out key in the catch-all rule"
as alice init >/dev/null
as ci init >/dev/null; as bob init >/dev/null
printf 'creation_rules:\n  - path_regex: \\.enc\\.\n    age: >-\n      %s\n    # revoked: %s\n' "$(as alice key)" "$(as bob key)" > .sops.yaml
as alice grant dev "$(as ci key)" >/dev/null
expected="$(printf '  - path_regex: (^|/)dev\\.enc\\.env$\n    age: >-\n      %s,\n      %s' "$(as alice key)" "$(as ci key)")"
eq "$(sed -n '2,5p' .sops.yaml)" "$expected"

fresh "grant refuses to append to a rule it can't safely edit"
as alice init >/dev/null
as ci init >/dev/null; rm .sops.yaml
printf 'creation_rules:\n  - path_regex: (^|/)dev\\.enc\\.env$\n    age: %s\n  - path_regex: \\.enc\\.\n    age: >-\n      %s\n' "$(as alice key)" "$(as alice key)" > .sops.yaml
before="$(cat .sops.yaml)"
check sh -c "HOME='$TMP/home/alice' '$SUDSY' grant dev '$(as ci key)' 2>&1 | grep -q 'by hand'"
current="the inline rule is left untouched"
eq "$(cat .sops.yaml)" "$before"

# Run sudsy as <who> with a pseudo-terminal on stdin, answering sops's prompt with <answer>.
# BSD script passes input on at once, typing that arrives before sops asks is lost, and it
# sends ^D as soon as its input ends. So no fixed sleep: watch the output for the prompt,
# type the answer then, and keep stdin open until the command exits.
# util-linux and BSD script take their arguments differently.
at_tty() {
  local answer="$1" who="$2"; shift 2
  local cmd="HOME='$TMP/home/$who' '$SUDSY' $*" log="$TMP/tty.log" done="$TMP/tty.done"
  rm -f "$done"; : > "$log"
  {
    local i=0
    while ! grep -q '(y/n)' "$log" && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
    printf '%s\n' "$answer"
    while [ ! -e "$done" ]; do sleep 0.1; done
  } | {
    if script --version >/dev/null 2>&1; then script -qec "$cmd" /dev/null
    else script -q /dev/null sh -c "$cmd"; fi
    touch "$done"
  } | tee "$log"
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

fresh "revoke refuses your own key from SOPS_AGE_KEY_CMD, split the way sops splits it"
two_readers
# Unquoted $NOPE: sops passes it through literally, a shell would expand it to nothing.
mv "$TMP/home/alice/.config/sops/age/keys.txt" "$TMP/\$NOPE.key"
before="$(cat .sops.yaml)"
check sh -c "SOPS_AGE_KEY_CMD='cat $TMP/\$NOPE.key' HOME='$TMP/home/alice' '$SUDSY' revoke --yes \"\$(age-keygen -y '$TMP/\$NOPE.key')\" 2>&1 | grep -q 'your own key'"
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

fresh "revoke removes a key that grant gave one environment"
as alice init >/dev/null; write_vault alice dev $'A=1\n'; write_vault alice prod $'P=1\n'
mkdir -p "$TMP/home/ci/.config/sops/age" && age-keygen -o "$TMP/home/ci/.config/sops/age/keys.txt" 2>/dev/null
as alice grant dev "$(as ci key)" >/dev/null; as alice sync --yes >/dev/null 2>&1
before_a="$(grep '^A=' dev.enc.env)"
as alice revoke --yes "$(as ci key)" >/dev/null 2>&1
check sh -c "! HOME='$TMP/home/ci' '$SUDSY' cat dev >/dev/null 2>&1 && test \"\$(grep '^A=' dev.enc.env)\" != '$before_a'"
current="after revoking a granted key, both rules hold only alice"
eq "$(grep -c "$(as alice key)" .sops.yaml) $(grep -c age1 .sops.yaml)" "2 2"

# check looks at what git would commit, so these tests stage files and use no key at all.
repo_with_vault() { git init -q; as alice init >/dev/null; write_vault alice dev $'A=1\n'; git add .sops.yaml dev.enc.env; }
check_fails_with() {
  local err; err="$(HOME="$TMP/home/nobody" "$SUDSY" check 2>&1 >/dev/null)" && return 1
  printf '%s' "$err" | grep -qF "$1"
}

fresh "check passes on an encrypted vault, with no key"
repo_with_vault
check env HOME="$TMP/home/nobody" "$SUDSY" check

fresh "check fails on a plaintext file named like a vault"
repo_with_vault
printf 'A=1\n' > prod.enc.env; git add prod.enc.env
check check_fails_with "prod.enc.env: not encrypted"

fresh "check fails on a staged plaintext .env, even once deleted from disk"
repo_with_vault
printf 'A=1\n' > .env; git add .env; rm .env
check check_fails_with ".env: looks like a plaintext dotenv"

fresh "check allows .env.example"
repo_with_vault
printf 'A=\n' > .env.example; git add .env.example
check env HOME="$TMP/home/nobody" "$SUDSY" check

fresh "check fails on a staged age private key, without printing it"
repo_with_vault
mkdir -p config; cp "$TMP/home/alice/.config/sops/age/keys.txt" config/key.txt; git add config/key.txt
out="$(HOME="$TMP/home/nobody" "$SUDSY" check 2>&1)"
check sh -c "printf '%s' \"\$1\" | grep -qF 'config/key.txt: contains an age private key'" _ "$out"
current="check does not print the private key"
check sh -c "! printf '%s' \"\$1\" | grep -q AGE-SECRET-KEY" _ "$out"

fresh "check ignores unstaged changes"
repo_with_vault
printf 'A=1\n' > dev.enc.env
check env HOME="$TMP/home/nobody" "$SUDSY" check

fresh "check still finds a private key when a vault lives under keys/"
repo_with_vault
mkdir -p keys; cp dev.enc.env keys/dev.enc.env; git add keys/dev.enc.env
cp "$TMP/home/alice/.config/sops/age/keys.txt" leaked.txt; git add leaked.txt
check check_fails_with "leaked.txt: contains an age private key"

fresh "check from a subdirectory reads the nested vault, not the root one"
repo_with_vault
mkdir -p apps/service; printf 'A=1\n' > apps/service/dev.enc.env; git add apps/service/dev.enc.env
check sh -c "cd apps/service && HOME='$TMP/home/nobody' '$SUDSY' check 2>&1 | grep -qF 'apps/service/dev.enc.env: not encrypted'"

fresh "check from a subdirectory still scans the whole repo for keys"
repo_with_vault
mkdir -p sub; cp "$TMP/home/alice/.config/sops/age/keys.txt" leaked.txt; git add leaked.txt
check sh -c "cd sub && HOME='$TMP/home/nobody' '$SUDSY' check 2>&1 | grep -qF 'leaked.txt: contains an age private key'"

fresh "check finds a private key in a file git treats as binary"
repo_with_vault
{ printf 'bin\0'; cat "$TMP/home/alice/.config/sops/age/keys.txt"; } > blob.dat
cp "$TMP/home/alice/.config/sops/age/keys.txt" secret-copy.txt
git add blob.dat secret-copy.txt
printf 'secret-copy.txt -diff\n' > .gitattributes
out="$(HOME="$TMP/home/nobody" "$SUDSY" check 2>&1)"
check sh -c "printf '%s' \"\$1\" | grep -qF 'blob.dat: contains an age private key'" _ "$out"
current="check finds a key in a file marked -diff by an unstaged .gitattributes"
check sh -c "printf '%s' \"\$1\" | grep -qF 'secret-copy.txt: contains an age private key'" _ "$out"

fresh "check outside git still checks the vaults on disk"
as alice init >/dev/null; write_vault alice dev $'A=1\n'; printf 'A=1\n' > prod.enc.env
check sh -c "! GIT_CEILING_DIRECTORIES='$TMP' HOME='$TMP/home/nobody' '$SUDSY' check 2>/dev/null"

fresh "./secret.txt wins over the global key"
as alice init >/dev/null
cp "$TMP/home/alice/.config/sops/age/keys.txt" secret.txt
rm "$TMP/home/alice/.config/sops/age/keys.txt"
write_vault alice dev $'A=1\n'
eq "$(as alice cat dev)" "A=1"

fresh "init with ./secret.txt adds it to .gitignore"
git init -q; (umask 077; age-keygen -o secret.txt 2>/dev/null)
as alice init >/dev/null
eq "$(cat .gitignore)" "secret.txt"

fresh "init gitignores ./secret.txt in a git worktree"
git init -q main
git -C main -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
git -C main worktree add -q ../wt 2>/dev/null
cd wt; (umask 077; age-keygen -o secret.txt 2>/dev/null)
as alice init >/dev/null
check git check-ignore -q secret.txt

fresh "init leaves .gitignore alone when a pattern already covers ./secret.txt"
git init -q; printf '*.txt\n' > .gitignore; (umask 077; age-keygen -o secret.txt 2>/dev/null)
as alice init >/dev/null
eq "$(cat .gitignore)" "*.txt"

fresh "init outside git writes no .gitignore"
(umask 077; age-keygen -o secret.txt 2>/dev/null)
GIT_CEILING_DIRECTORIES="$TMP" as alice init >/dev/null
check test ! -e .gitignore

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
