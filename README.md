<p align="center">
  <img src="assets/logo.svg" alt="sudsy logo: a bar of soap with a keyhole, blowing bubbles" width="200">
</p>

<h1 align="center">sudsy</h1>

<p align="center">
  <b>Squeaky-clean secrets for any project.</b><br>
  Super simple and minimalist per-environment secrets management, built on top of <a href="https://github.com/getsops/sops">sops</a> + <a href="https://github.com/FiloSottile/age">age</a>.<br>
  <i>Lather, rinse, repeat.</i>
</p>

---

sudsy lets you create a locally encrypted vault for each environment that's committed next to your code, directly in git. Each teammate has their own private key to read the vaults.

sops is fantastic, but every project ends up with the same pile of little wrapper scripts:
make a key, add it to `.sops.yaml`, edit `dev.enc.env`, run something with `prod`'s secrets,
re-encrypt everything when a teammate joins. **sudsy is that pile of scripts, scrubbed and
packaged once.** It's a single bash script with no dependencies beyond sops and age, and it
never touches crypto itself. sops and age do all the real work.

## Install

You need [sops](https://github.com/getsops/sops) and [age](https://github.com/FiloSottile/age):

```bash
brew install sops age          # macOS / Linuxbrew
```

Then sudsy itself, whichever way suits the project:

```bash
npm install --save-dev @monotropiclabs/sudsy   # per project: npm scripts find it automatically
npm install --global @monotropiclabs/sudsy     # or everywhere
```

Either way, the command is just `sudsy`.

Not a Node project? It's one file, so just put it on your `PATH`:

```bash
curl -fsSL https://raw.githubusercontent.com/monotropiclabs/sudsy/main/bin/sudsy -o ~/.local/bin/sudsy
chmod +x ~/.local/bin/sudsy
```

## Quick start

```bash
sudsy init                      # make (or find) your key, create .sops.yaml
sudsy edit dev                  # opens dev.enc.env in your editor
git add .sops.yaml dev.enc.env  # yes, commit the vault. It's encrypted.
sudsy run dev -- npm start      # your app sees the secrets as env vars
```

## Demo

This repo has a real example. Here's how it was made:

```bash
sudsy init
```

Creates [`.sops.yaml`](.sops.yaml), which lists the public keys allowed to read the vaults.
Your private key stays on your machine.

```bash
sudsy edit demo
```

Opens an editor for your secrets. Change a value, save, and exit: sudsy writes
[`demo.enc.env`](demo.enc.env) with the values encrypted. Both files can go in git.

That's it! 🫧

```bash
sudsy cat demo
```

Prints the decrypted file back, only if you have my private key:

```
# This is an example file.
example_key=example_value
example_multiline=foo\nbar\nbaz
```

## Commands

| Command | What it does |
| --- | --- |
| `sudsy init` | Finds or creates your age key and adds your public key to `.sops.yaml` (creating it if needed). Safe to run again. |
| `sudsy key` | Prints your public key, for when someone else is onboarding you. |
| `sudsy edit <env>` | Edits `<env>.enc.env` in `$SOPS_EDITOR`, then `$EDITOR`, then `nano`. Creates the file if it doesn't exist. |
| `sudsy run <env> -- cmd…` | Runs `cmd` with that environment's secrets exported. Arguments, stdin and the exit code pass straight through. |
| `sudsy cat <env>` | Prints the decrypted dotenv. |
| `sudsy json <env>` | Prints the secrets as one JSON object, handy from scripts. |
| `sudsy get <env> <KEY>` | Prints a single value. |
| `sudsy grant <env> <pubkey>` | Lets one more key read just `<env>`'s vault, by giving that environment its own rule in `.sops.yaml`. Then run `sudsy sync`. |
| `sudsy sync [--yes]` | Re-encrypts every vault for whoever is listed in `.sops.yaml` now. Shows which keys each vault gains or loses and asks first; `--yes` skips the question, for scripts. |
| `sudsy revoke [--yes] <pubkey>` | Removes a key from `.sops.yaml`, re-encrypts every vault it could read with a new data key, and lists the secret names it could see so you can rotate them. Reviews like `sync`. |
| `sudsy ls` | Lists the environments in this project. |
| `sudsy check` | Fails if a vault isn't encrypted, or git is about to commit a plaintext `.env` or an age private key. Needs no key, so it fits a pre-commit hook or CI. |

`<env>` is just a name: `sudsy edit staging` means `./staging.enc.env`.

## How it works

sudsy is a handful of conventions on top of sops:

- **One vault per environment**, `<env>.enc.env`, committed to the repo. Keys stay readable
  in diffs and only the values are encrypted.
- **`.sops.yaml` lists who can read them**: one age public key per person (or machine).
- **Your private key lives in one place for all your projects**:
  `~/.config/sops/age/keys.txt`. sudsy looks for it in this order:
  1. `$SOPS_AGE_KEY_FILE`, if you set it
  2. the output of `$SOPS_AGE_KEY_CMD`, if you set it (see [Recipes](#recipes): keep the key in
     a password manager)
  3. `./secret.txt` in the project (handy for older setups, and `init` gitignores it)
  4. `~/.config/sops/age/keys.txt`

  In CI, put the key's contents in `SOPS_AGE_KEY` instead. No file needed.

## Teammates

**Joining a project** (the lather):

```bash
sudsy init          # adds your public key to .sops.yaml
git commit -am "Add my sudsy key" && git push
```

**Letting them in** (the rinse). Anyone who can already decrypt runs:

```bash
git pull && sudsy sync && git commit -am "Re-encrypt vaults" && git push
```

`sync` shows the keys each vault is about to gain and asks before re-encrypting. Read that
list: anyone who can push to the repo can add a key to `.sops.yaml`, and saying yes lets that
key read everything. Check each new key with its owner before you agree. Outside a terminal,
`sync` refuses unless you pass `--yes`, so a script can't widen access without someone deciding to.

**Just one environment** (a CI key, a contractor, a staging box). Rather than adding the key
for everything, give it one vault:

```bash
sudsy grant dev age1ci...   # dev gets its own rule: everyone who reads it now, plus this key
sudsy sync                  # re-encrypts dev for that key; prod is untouched
```

sops uses the first rule in `.sops.yaml` that matches a vault, so `grant` puts the
environment's rule before the catch-all one `init` writes. A teammate who joins later with
`sudsy init` goes into the catch-all only, and `init` tells them which environments have their
own rule; someone runs `sudsy grant <env> <their key>` for each.

**Removing someone**:

```bash
sudsy revoke age1their...   # then commit .sops.yaml and the vaults
```

`revoke` takes their key out of every rule, re-encrypts each vault they could read (reviewed
like `sync`), and gives those vaults a new data key with `sops rotate`, so a data key they kept
no longer opens them. It won't revoke your own key, or leave a rule with nobody able to read it.
If you decline a vault, run the same `revoke` again later to finish it: the key is already out
of `.sops.yaml`, and the rerun updates and rotates the vaults that still list it.

It ends with the names of every secret they could read. They can still read old versions from
git history, so **rotate each of those at its source**: a new API key, a new password. No
amount of soap washes that off.

## Recipes

**npm scripts**

```json
{
  "scripts": {
    "secrets": "sudsy",
    "dev": "sudsy run dev -- node server.js",
    "test": "sudsy run test -- node --test"
  }
}
```

Then `npm run secrets edit prod`, `npm run secrets ls`, and so on.

**Reading secrets from a Node script** (a deploy script, say):

```js
import {execFileSync} from 'node:child_process';
const secrets = JSON.parse(execFileSync('sudsy', ['json', 'prod'], {encoding: 'utf8'}));
```

**One value in a shell**

```bash
export DATABASE_URL="$(sudsy get prod DATABASE_URL)"
```

**GitHub Actions**

```yaml
- run: sudsy run test -- npm test
  env:
    SOPS_AGE_KEY: ${{ secrets.SOPS_AGE_KEY }}
```

Generate a key just for CI (`age-keygen`), add its public key to `.sops.yaml`, run `sudsy sync`,
and store the private half as a repository secret.

**Catch a plaintext secret before it's committed**

`sudsy check` looks at what the next commit holds (staged changes included) and fails if:

- a `*.enc.*` vault isn't actually encrypted (say, someone saved plaintext over it)
- a plaintext dotenv (`.env`, `.env.*`, `*.env`) is in git; names ending `.example`,
  `.sample`, `.template` or `.dist` are allowed
- any file contains an age private key

It needs no key, so run it as a pre-commit hook and again in CI, which catches commits made
with `--no-verify`:

```bash
printf '#!/bin/sh\nexec sudsy check\n' > .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit
```

```yaml
- run: npx --no sudsy check   # with sudsy in devDependencies; --no stops npx downloading anything
```

**Keep your key in a password manager**

A key file on disk can be read by anything running as you. Instead, store the key in your
password manager and let sudsy (and sops) ask for it each time:

```bash
# 1Password: save the contents of keys.txt as a password item named "age key"
export SOPS_AGE_KEY_CMD='op read "op://Private/age key/password"'
# pass
export SOPS_AGE_KEY_CMD='pass show age-key'
```

Put the export in your shell profile, check that `sudsy key` still prints your public key, then
delete `~/.config/sops/age/keys.txt`. Every command works the same; `init` and `key` read the
key from the command too. This needs sops 3.10 or newer. sops runs the command directly rather than through a shell, so it can
take quoted arguments but not pipes; wrap anything fancier in a small script.

## FAQ

**Is this secure?** sudsy doesn't do any cryptography. It calls sops, which encrypts with
age. Your security is exactly sops + age, plus not committing your private key (sudsy
keeps it outside the repo by default).

**Why bash?** So it runs anywhere sops does, with nothing to install. It's written for bash
3.2, so the stock macOS bash is fine.

**Can I use YAML or JSON vaults?** sops can, and `sudsy sync` re-encrypts any `*.enc.*`
file, but the other commands assume `<env>.enc.env` dotenv files. Keeping it simple is
the whole point.

**Does `.sops.yaml` need to look a certain way?** `sudsy init` writes a minimal one. If you
already have one, `init` appends your key after the last `age1…` recipient it finds. With
several creation rules, check that it landed where you wanted. `grant` only edits the shape
sudsy writes: rules of `path_regex` plus an `age: >-` list, one key per line, with the
`\.enc\.` catch-all last.

## Development

```bash
npm test   # needs sops + age on PATH
```

To release: bump `version` in both `package.json` and `bin/sudsy` (a test keeps them in
sync), commit, then `npm publish`.

## License

[MIT](LICENSE). Go get sudsy. 🧼
