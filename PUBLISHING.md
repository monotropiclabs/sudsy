# Publishing the Sudsy website

The website is static: `docs/index.html` contains the supplied landing page, including its original embedded wordmark.
`docs/install.sh` is the public installer; `docs/.nojekyll` disables Jekyll processing.

After merging this PR:

1. Verify `monotropiclabs.com` in the Monotropic Labs organization settings under **Pages** (if not already verified).
   GitHub gives you a TXT record with a unique verification value; use that exact value.
2. In [Sudsy's Pages settings](https://github.com/monotropiclabs/sudsy/settings/pages),
   choose **Deploy from a branch**, `main`, `/docs`, then Save.
3. Set Custom domain to `sudsy.monotropiclabs.com`. Save it before pointing DNS at Pages.
4. In the DNS zone for `monotropiclabs.com`, add a CNAME with name `sudsy`,
   target `monotropiclabs.github.io`, TTL 300 or Auto. Do not include `/sudsy` or
   change the existing apex or www records. If using Cloudflare, use DNS only.
5. Once the DNS check passes and GitHub provisions the certificate, enable **Enforce HTTPS**.

Check both endpoints after deployment:

```bash
dig +short CNAME sudsy.monotropiclabs.com
curl -fsS https://sudsy.monotropiclabs.com/ >/dev/null
curl -fsS https://sudsy.monotropiclabs.com/install.sh | bash -n
```

The last command checks syntax without running the installer.

See [GitHub's custom domain documentation](https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/managing-a-custom-domain-for-your-github-pages-site).

## Homebrew

The Sudsy repository is itself the tap, using the explicit Git URL:

```bash
brew tap monotropiclabs/sudsy https://github.com/monotropiclabs/sudsy.git
brew install monotropiclabs/sudsy/sudsy
```

There is no separate tap repository or secret token. The release workflow checks the
downloaded release checksum, then updates the version, URL, and SHA-256 in
`Formula/sudsy.rb` on main. It skips older releases and retries concurrent branch changes.
If branch protection is enabled in the future, allow the workflow to update this formula
or change the job to create a separate review PR.
