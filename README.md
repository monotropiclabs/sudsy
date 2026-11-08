<p align="center">
  <img src="assets/logo.svg" alt="sudsy logo: a bar of soap with a keyhole, blowing bubbles" width="200">
</p>

<h1 align="center">sudsy</h1>

<p align="center">
  <b>Squeaky-clean secrets for any project.</b><br>
  Per-environment <code>.env</code> vaults, encrypted with <a href="https://github.com/getsops/sops">sops</a> + <a href="https://github.com/FiloSottile/age">age</a>, committed right next to your code.<br>
  <i>Lather, rinse, repeat.</i>
</p>

---

sops is fantastic, but every project ends up with the same pile of little wrapper scripts:
make a key, add it to `.sops.yaml`, edit `dev.enc.env`, run something with `prod`'s secrets,
re-encrypt everything when a teammate joins. **sudsy is that pile of scripts, scrubbed and
packaged once.** It's a single bash script with no dependencies beyond sops and age, and it
never touches crypto itself. sops and age do all the real work.

```console
$ sudsy run prod -- node server.js
```

That's the whole pitch. 🫧

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
| `sudsy sync` | Re-encrypts every vault for whoever is listed in `.sops.yaml` now. |
| `sudsy ls` | Lists the environments in this project. |

`<env>` is just a name: `sudsy edit staging` means `./staging.enc.env`.

## How it works

sudsy is a handful of conventions on top of sops:

- **One vault per environment**, `<env>.enc.env`, committed to the repo. Keys stay readable
  in diffs and only the values are encrypted.
- **`.sops.yaml` lists who can read them**: one age public key per person (or machine).
- **Your private key lives in one place for all your projects**:
  `~/.config/sops/age/keys.txt`. sudsy looks for it in this order:
  1. `$SOPS_AGE_KEY_FILE`, if you set it
  2. `./secret.txt` in the project (handy for older setups, and `init` gitignores it)
  3. `~/.config/sops/age/keys.txt`

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

**Removing someone**: delete their line from `.sops.yaml`, run `sudsy sync`, and commit.
They can still read old versions from git history, so **rotate anything they had access
to**. No amount of soap washes that off.

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

Generate a key just for CI (`age-keygen`), add its public key to `.sops.yaml`, `sudsy sync`,
and store the private half as a repository secret.

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
several creation rules, check that it landed where you wanted.

## Development

```bash
npm test   # needs sops + age on PATH
```

To release: bump `version` in both `package.json` and `bin/sudsy` (a test keeps them in
sync), commit, then `npm publish`.

## License

[MIT](LICENSE). Go get sudsy. 🧼
