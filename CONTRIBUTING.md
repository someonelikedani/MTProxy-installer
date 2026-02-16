# Contributing

Thanks for considering contributing to **MTProxy-installer**.

------------------------------------------------------------------------

## Principles

-   Keep changes minimal and focused.
-   Prefer explicit, readable Bash over clever tricks.
-   **No hidden firewall modifications.** Any firewall changes must
    remain **opt-in** and documented.
-   Never commit secrets (tokens, proxy secrets,
    `/etc/mtproxy-installer.env`, `.env` files, etc.).
-   Do not introduce external runtime dependencies without discussion.

------------------------------------------------------------------------

## Required checks

Run before opening a PR:

``` bash
bash -n install.sh
shellcheck -x install.sh
```

If you add new scripts, include them too.

------------------------------------------------------------------------

## Formatting (recommended)

``` bash
shfmt -i 2 -ci -bn -w install.sh
```

------------------------------------------------------------------------

## Smoke tests (recommended)

On a test Ubuntu/Debian VPS/VM:

``` bash
sudo ./install.sh --help
sudo ./install.sh check
sudo ./install.sh status
```

If you test installation, also test uninstall:

``` bash
sudo ./install.sh uninstall --yes
```

------------------------------------------------------------------------

## Documentation

-   Update **both** `README_EN.md` and `README_RU.md` when
    behavior/flags change.
-   Any firewall/anti-abuse behavior must be clearly described (what
    changes, where injected, how removed).

------------------------------------------------------------------------

## Security related changes

Any changes that affect:

-   firewall
-   systemd sandboxing
-   secrets handling
-   privilege model

must include explanation of:

-   threat model
-   risk tradeoffs
-   rollback behavior

Security-impacting changes should be explicit, documented, and
reviewable.

------------------------------------------------------------------------

## Commits / PRs

-   Use clear commit messages: `fix: ...`, `docs: ...`, `feat: ...`
-   Keep PRs small and reviewable.
-   Explain rationale for security and firewall related changes.
