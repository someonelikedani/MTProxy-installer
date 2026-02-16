# Contributing

Thanks for considering contributing!

## Basic Rules

- Keep changes minimal and focused.
- Prefer explicit, readable Bash over clever tricks.
- Do **not** add hidden firewall modifications. Any firewall-related behavior must remain **opt-in** and documented.
- Never commit secrets (tokens, proxy secrets, `.env` files, etc.).

## Linting / Checks (required)

Run these before opening a PR:

```bash
bash -n install.sh
bash -n uninstall.sh

shellcheck -x install.sh uninstall.sh
```

### Formatting (recommended)

If you use `shfmt`:

```bash
shfmt -i 2 -ci -bn -w install.sh uninstall.sh
```

## Smoke tests (recommended)

On a test VPS/VM (Ubuntu/Debian):

```bash
sudo ./install.sh --help
sudo ./install.sh status
```

If you test installation, also test uninstall:

```bash
sudo ./uninstall.sh
```

## Commit / PR Guidelines

- Use clear commit messages (e.g., `fix: handle missing deps`, `docs: clarify anti-abuse behavior`).
- Update README / docs if behavior changes.
- If you change flags/options, update the CLI flags table in both README languages.
