# RepRapFirmwareDebug

A self-contained workspace for building [RepRapFirmware](https://github.com/Duet3D/RepRapFirmware)
(the Duet 3D-printer firmware) from a fork, together with all of its sibling
dependencies and a pinned toolchain. Everything is driven by a single script,
[`rrf.sh`](./rrf.sh) — from first-time setup to incremental builds.

## Layout

```
RepRapFirmwareDebug/
├── rrf.sh          # workspace manager — the only entry point needed
├── README.md
├── .gitignore
├── completion/     # shell completion for rrf.sh
├── tools/          # auto-downloaded ARM + Xtensa toolchains         (git-ignored)
└── repos/          # the cloned source repos + Eclipse workspace     (git-ignored)
    ├── .metadata/                # Eclipse workspace state
    ├── RepRapFirmware/           # the firmware (a fork, see below)
    ├── CoreN2G/  FreeRTOS/  RRFLibraries/  CANlib/
    └── DuetWiFiSocketServer/  WiFiSocketServerRTOS/
```

Only `rrf.sh`, this README, `.gitignore`, and `completion/` are tracked in
**this** repo. Each project under `repos/` is its own independent git checkout
with its own remote, and `tools/`/`repos/` are downloaded/cloned on demand — so
they are ignored here.

### The RepRapFirmware fork

`repos/RepRapFirmware` tracks a fork rather than Duet3D directly, so changes can
be committed and pushed while still pulling upstream updates:

| Remote     | URL                                            | Purpose                     |
|------------|------------------------------------------------|-----------------------------|
| `origin`   | `git@github.com:Remenod/RepRapFirmware.git`    | the fork — commits/pushes go here |
| `upstream` | `https://github.com/Duet3D/RepRapFirmware.git` | pull upstream changes       |

Development happens on branch **`visionminer-3.5.4-debug`** (branched off tag
`3.5.4`). The other six repos are plain Duet3D checkouts pinned to matching refs
(`3.5.4` for CoreN2G / FreeRTOS / RRFLibraries / CANlib, `dev` for
DuetWiFiSocketServer, `main` for WiFiSocketServerRTOS).

## Prerequisites

The following must be present (they are not fetched automatically):

- **Eclipse CDT** — the headless build engine; `eclipse` must be on `PATH`.
- **.NET 6 runtime** — required *exactly* (not 7/8) by `CrcAppender`.
- Base CLI tools: `git`, `wget`, `tar`, `xz`.
- Linux **x86_64** (the pinned toolchains are prebuilt for that platform).

The **ARM GCC 12.2** and **Xtensa lx106 GCC** toolchains are downloaded into
`tools/` automatically by `bootstrap`.

Running `./rrf.sh doctor` reports exactly what is present or missing.

## Quick start

```bash
./rrf.sh doctor        # check the environment first
./rrf.sh bootstrap     # one-time: fetch toolchains, clone repos, install CrcAppender
./rrf.sh build         # build the default target (Duet3_MB6HC)
```

A fresh `bootstrap` on a new machine reproduces the workspace exactly — the
fork, the branch, and every pinned dependency.

## Commands

| Command                  | What it does                                                        |
|--------------------------|---------------------------------------------------------------------|
| `doctor` (`check`)       | Diagnose the whole environment at once and report what's wrong      |
| `bootstrap [--sync]`     | One-time setup: toolchains + clone repos + CrcAppender. `--sync` fast-forwards *clean* repos onto their pinned ref |
| `build [target]`         | Incremental build (default target `Duet3_MB6HC`)                    |
| `rebuild [target]`       | Clean build — wipes Eclipse `.metadata`, re-imports, then builds    |
| `clean`                  | Remove build outputs and Eclipse metadata                           |
| `help`                   | Show usage                                                          |

Any Eclipse build configuration is a valid `target`, e.g.:

```bash
./rrf.sh build Duet3Mini5plus
./rrf.sh rebuild Duet3_MB6XD
```

The full list comes from `repos/RepRapFirmware/.cproject`; common ones are
`Duet3_MB6HC`, `Duet3_MB6XD`, `Duet3Mini5plus`, `Duet2`, `Duet2_SBC`,
`DuetMaestro`. Built firmware lands in a target-named folder inside
`repos/RepRapFirmware/` and its path is printed at the end of a successful build.

### Safety

`bootstrap` never overwrites local work: for a repo that already exists it only
fetches and reports state, and it refuses to touch a checkout with uncommitted
changes. Branch switching happens only on a fresh clone or with an explicit
`--sync` on a clean repo.

## Shell completion (zsh)

A zsh completion for `rrf.sh` is provided in
[`completion/_rrf`](./completion/_rrf). It completes subcommands, `--sync`, and —
for `build`/`rebuild` — the build-target names read live from
`repos/RepRapFirmware/.cproject`.

Install it by putting the `completion/` directory on `fpath` before `compinit`
runs — e.g. in `.zshrc`:

```zsh
fpath=(/path/to/RepRapFirmwareDebug/completion $fpath)
autoload -Uz compinit && compinit
```

New completion files take effect in a new shell.
