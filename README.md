# Claude Code for Termux

Install or update [Claude Code](https://docs.anthropic.com/en/docs/claude-code) on Termux (Android, aarch64).

Claude Code ships as a glibc linux-arm64 binary, but Termux uses bionic (Android's libc). These scripts handle the glibc-runner setup, ELF patching, and environment wiring needed to make it work.

## Scripts

Two install scripts. Both auto-detect the latest version, install dependencies, download and verify the binary, and configure your shell and settings. Run either one any time to check for updates.

### `install.sh` — Safe install

```sh
bash install.sh
```

Patchelf's the binary to use glibc-runner's dynamic linker and wraps it in a bash script that clears `LD_PRELOAD` before launch. Simple, reliable, nothing fragile.

**Tradeoff:** Shebangs like `#!/usr/bin/env bash` don't work inside Claude's Bash tool. Normally in Termux, `termux-exec` (an `LD_PRELOAD` library) intercepts `execve()` to rewrite paths like `/usr/bin/env` to `$PREFIX/bin/env`. But `termux-exec` is a bionic library — loading it into the glibc claude process causes the glibc linker to error out with "invalid ELF header". So the wrapper has to clear `LD_PRELOAD` entirely, which means no shebang rewriting. Scripts can still be run with `bash script.sh` instead of `./script.sh`. Grep, find, and all other Claude tools work fine.

### `install-patched.sh` — Full fix (binary patch)

```sh
bash install-patched.sh
```

Does everything `install.sh` does, plus two additional steps that make shebangs work too:

1. **Binary patches** `process.execPath` out of Claude's bundled JS. Claude's grep/find/rg tools normally re-exec the claude binary directly using this value. With `LD_PRELOAD` set (for shebang support), that re-exec would inherit the bionic `termux-exec` library into the glibc binary and crash it. Blanking `process.execPath` makes them fall back to resolving `claude` from `PATH`, which finds the compiled wrapper instead.

2. **Compiles a C wrapper** (bionic ELF) instead of a bash script wrapper. This matters for two reasons:
   - As a bionic binary, `termux-exec` loads into it naturally. It then clears `LD_PRELOAD` before exec'ing the glibc claude binary, keeping the two libc worlds separate.
   - A real ELF preserves `argv[0]` through exec. When grep/find falls back to this wrapper with `argv[0]` set to `ugrep`/`bfs`/`rg`, that name survives into the claude binary so it knows which tool to run. A `#!/bin/bash` script wrapper would lose `argv[0]` because the kernel replaces it when processing the shebang.

This also sets `env.LD_PRELOAD` in `~/.claude/settings.json` so Claude's Bash tool children inherit `termux-exec` for shebang resolution.

**Tradeoff:** The binary patch uses a regex anchored on specific JS variable names in Bun's compiled output. If Anthropic changes their bundler or code structure in a future release, the patch may stop matching. The script will error out ("expected 1 match, got 0") rather than silently corrupt anything. When that happens, fall back to `install.sh` until the regex is updated. Also requires `clang` and either `python3` or `perl`.

## How it works

The core problem: Termux uses **bionic** (Android's libc), Claude Code is a **glibc** binary. The two can't coexist in the same process.

- **termux-exec** (`libtermux-exec-ld-preload.so`) is a bionic `LD_PRELOAD` library that intercepts `execve()` to rewrite FHS paths (`/usr/bin/env` -> `$PREFIX/bin/env`). This is how shebangs work in Termux.
- Loading this bionic library into a glibc process makes the glibc dynamic linker try to resolve the library's `DT_NEEDED` dependency on unversioned `libc.so`. Under glibc-runner's lib dir, `libc.so` is an ASCII linker script (for static linking), not an ELF. The glibc linker can't parse it: "invalid ELF header".
- Claude's grep/find/rg tools re-exec the claude binary with a different `argv[0]` (e.g. `ugrep`). If `LD_PRELOAD` is set, that re-exec inherits the bionic preload into the glibc binary, triggering the same "invalid ELF header" crash.

So you need `LD_PRELOAD` active for bionic children (bash, scripts with shebangs) but cleared for glibc processes (the claude binary itself). `install.sh` solves this by never setting `LD_PRELOAD` — sacrificing shebangs. `install-patched.sh` solves it by redirecting the grep/find re-exec through a bionic wrapper that strips `LD_PRELOAD` before calling the glibc binary.

## Dependencies

Installed automatically if missing:

- `curl`, `jq` — download and checksum verification
- `glibc-repo`, `glibc-runner` — glibc runtime environment
- `patchelf-glibc` — rewrite ELF interpreter

`install-patched.sh` additionally needs:

- `clang` — compile the C wrapper
- `python3` or `perl` — binary patch (uses python3 if available, installs perl otherwise)

## Credits

All credit for the core workarounds goes to **[@gtbuchanan](https://github.com/gtbuchanan)** — the patchelf approach, the `process.execPath` binary patch, and the compiled C wrapper are all his work. Original writeup and code: [anthropics/claude-code#50270 (comment)](https://github.com/anthropics/claude-code/issues/50270#issuecomment-4467292215).

These scripts just package that logic into a single command that handles dependency installation, version checking, settings configuration, and shell setup.
