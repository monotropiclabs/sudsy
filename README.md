<h1 align="center">
  <img src="assets/logo.svg" alt="sudsy" width="240">
</h1>

<p align="center">
  <strong>Keep your secrets in git.</strong><br>
  <em>Encrypted, obviously.</em>
</p>

Sudsy keeps encrypted `.env` files next to your code. Give each teammate their own key,
run your app with the right secrets, and skip writing the same SOPS scripts for every project.

It's one Bash script built on [SOPS](https://github.com/getsops/sops) and
[age](https://github.com/FiloSottile/age). They handle the encryption. Sudsy handles the rest.

[Visit the website](https://sudsy.monotropiclabs.com).

## Install

**Direct install (macOS or Linux)**

Install [SOPS](https://github.com/getsops/sops) and [age](https://github.com/FiloSottile/age) first.
With Homebrew: `brew install sops age`. On other Linux distributions, use their installation guides.

```bash
curl -fsSL https://sudsy.monotropiclabs.com/install.sh | bash
```

No Node.js or sudo required. The installer downloads the latest stable GitHub release,
checks its SHA-256, and installs Sudsy into `~/.local/bin`. Add that directory to your
`PATH` if needed. See [other installation options](#other-installation-options) for
version pinning and inspecting the installer before running it.

**Homebrew**

```bash
brew tap monotropiclabs/sudsy https://github.com/monotropiclabs/sudsy.git
brew install monotropiclabs/sudsy/sudsy
```

Homebrew installs SOPS and age for you. Update with `brew update` followed by
`brew upgrade monotropiclabs/sudsy/sudsy`.

**npm**

If you want Sudsy pinned to a project, add it as a dev dependency:

```bash
npm install --save-dev @monotropiclabs/sudsy
```

You still need SOPS and age. The examples below use `sudsy` directly. With a
project-local npm installation, use `npx --no sudsy` or run it through an npm script.
For a global installation, use `npm install --global @monotropiclabs/sudsy`.

## Four steps. That's it.

**1. Initialize your project.**

```bash
sudsy init
```

Creates or finds your age key and adds your public key to `.sops.yaml`.

**2. Add your secrets.**

```bash
sudsy edit dev
```

Opens `dev.enc.env` in your editor. When you save, Sudsy encrypts the values.

**3. Commit them.**

```bash
git add .sops.yaml dev.enc.env
git commit -m "Add encrypted secrets"
```

Yes, commit the file. That's the point.

**4. Run your app.**

```bash
sudsy run dev -- npm start
```

Your app gets the decrypted values as environment variables. Nothing to export manually.

## Share with your team.

Everyone gets their own key. No shared passwords.

**A new teammate joins:**

```bash
sudsy init
git add .sops.yaml
git commit -m "Add my Sudsy key"
git push
```

This adds their public key to the project's access rules.

**Someone with existing access lets them in:**

```bash
git pull
sudsy sync
git commit -am "Update vault access"
git push
```

`sudsy sync` shows which keys are gaining or losing access and asks for confirmation
before re-encrypting the vaults. Verify new keys with their owners before approving access:
anyone who can edit `.sops.yaml` can propose a new recipient. Outside a terminal,
`sync` refuses to run unless you explicitly pass `--yes`.

Need to give someone access to just one environment, or remove someone?
See [managing access](#managing-access).

## A little extra protection.

```bash
sudsy check
```

Catches common mistakes before they make it into git:

- Plaintext dotenv files (`.env`, `.env.*`, `*.env`) in the proposed commit.
- Vaults (`*.enc.*`) that aren't actually encrypted.
- Age private keys in files in the proposed commit.

Dotenv templates ending in `.example`, `.sample`, `.template` or `.dist` are allowed.
The check includes staged changes and doesn't need a private key. Run it in a pre-commit
hook and in CI, which can catch commits made with `--no-verify`.

If you don't already have a pre-commit hook:

```bash
printf '#!/bin/sh\nexec sudsy check\n' > .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
```

For a project-local npm installation, use `npx --no sudsy check` in your hook.
If you already have a hook, add the check to it instead of overwriting it.

In CI (with Sudsy installed as a dev dependency):

```yaml
- run: npx --no sudsy check
```

It's an extra safeguard, not a replacement for reviewing what you commit.

## Other installation options

**Inspect the installer and pin a version.** Download it first, read it, then run it:

```bash
curl -fsSLO https://sudsy.monotropiclabs.com/install.sh
less install.sh
bash install.sh --version v0.2.0
```

The default is the latest stable release. To choose a different installation directory,
pass `--bin-dir /absolute/path`. To upgrade, run the installer again. To uninstall a
direct installation, remove `~/.local/bin/sudsy` (or the executable at your chosen path).
The installer does not change your shell configuration, private keys, or project files.

The [installer source](docs/install.sh) is in this repository. The release checksum
detects corruption; it is not an independent signature of the publisher.

**Manual installation.** Sudsy is one Bash file. Pin a version from the
[releases page](https://github.com/monotropiclabs/sudsy/releases) and verify its checksum:

```bash
v=0.2.0   # the version you want
mkdir -p ~/.local/bin
curl -fsSLO "https://github.com/monotropiclabs/sudsy/releases/download/v$v/sudsy"
curl -fsSLO "https://github.com/monotropiclabs/sudsy/releases/download/v$v/sudsy.sha256"
shasum -a 256 -c sudsy.sha256 && install -m 755 sudsy ~/.local/bin/sudsy
```

Ensure `~/.local/bin` is on your `PATH`. Linux users can also verify with
`sha256sum -c sudsy.sha256`. For an npm installation, every version carries a
[provenance attestation](https://docs.npmjs.com/generating-provenance-statements)
linking it to the release workflow; verify with `npm audit signatures`.

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

Sudsy is a handful of conventions on top of SOPS:

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

## Example vault

This repository contains a real encrypted vault: [demo.enc.env](demo.enc.env).
Its [.sops.yaml](.sops.yaml) lists the public keys allowed to read it. The private
key stays outside the repository.

With an authorized private key, `sudsy cat demo` prints the decrypted contents:

```dotenv
# This is an example file.
example_key=example_value
example_multiline=foo\nbar\nbaz
```

The example vault is encrypted for its existing recipient; you don't need access
to it to try Sudsy with your own project.

## Managing access

**Grant access to one environment.** For a CI key, contractor, or staging machine,
give the key access to just the vault it needs:

```bash
sudsy grant dev age1ci...   # dev gets its own rule: everyone who reads it now, plus this key
sudsy sync                  # re-encrypts dev for that key; prod is untouched
```

sops uses the first rule in `.sops.yaml` that matches a vault, so `grant` puts the
environment's rule before the catch-all one `init` writes. A teammate who joins later with
`sudsy init` goes into the catch-all only, and `init` tells them which environments have their
own rule; someone runs `sudsy grant <env> <their key>` for each.

**Remove someone.**

```bash
sudsy revoke age1their...   # then commit .sops.yaml and the vaults
```

`revoke` takes their key out of every rule, re-encrypts each vault they could read (reviewed
like `sync`), and gives those vaults a new data key with `sops rotate`, so a data key they kept
no longer opens them. It won't revoke your own key, or leave a rule with nobody able to read it.
If you decline a vault, run the same `revoke` again later to finish it: the key is already out
of `.sops.yaml`, and the rerun updates and rotates the vaults that still list it.

It ends with the names of every secret they could read. They can still read old versions from
git history, so **rotate each of those at its source**: a new API key, a new password.

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

**Is this secure?** Sudsy doesn't do any cryptography. SOPS and age handle the encryption.
Keep your private key outside the repository and review changes to access rules before
approving them.

**Why Bash?** So it runs anywhere SOPS does, without another runtime to install. It's written for bash
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
sync), commit, then tag and push:

```bash
git tag vX.Y.Z && git push origin vX.Y.Z
```

[`release.yml`](.github/workflows/release.yml) checks the tag matches both versions, runs the
tests on Linux and macOS, publishes to npm with provenance, and creates a GitHub release with
`sudsy`, `sudsy.sha256`, `install.sh`, and `install.sh.sha256`. It then updates the
[Homebrew formula](Formula/sudsy.rb) on `main` to the latest stable release. The formula uses
that same release artifact and checksum. It publishes through npm trusted publishing, so there is no npm token
to store or leak. One-time setup: on npmjs.com, under the package's settings, add a trusted
publisher for GitHub Actions with repository `monotropiclabs/sudsy` and workflow `release.yml`.

## License

[MIT](LICENSE).
