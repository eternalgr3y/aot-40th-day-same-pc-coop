# Army of Two: The 40th Day — same-PC co-op

An experimental project for playing native two-player campaign co-op in **two Xenia instances on one Windows PC**, with a separate controller and profile for each player.

It uses a **custom Xenia build** and local companion services. Regular Xenia does not currently include all the emulator changes this project needs.

> **Status: source alpha.** Co-op has worked on the development PC, including a recorded campaign session and a checkpoint reload test. A complete player download and a verified first-time setup on another PC are still being prepared.

## Downloads

[Download the curated source alpha](https://github.com/eternalgr3y/aot-40th-day-same-pc-coop/releases/tag/v0.1.0-source-alpha.2)

The current release is for source review. Download the curated source ZIP from the release page to inspect the launcher, configuration, local services, and tests. It is **not a ready-to-play package**. GitHub's automatic source archives are not player installers.

This source release does not include an emulator executable.

The intended player release will include the custom emulator, launcher, configuration templates, and required companion project files. Players will not need to compile Xenia themselves.

## What works, and what still needs validation

| Area | Current status |
| --- | --- |
| Two instances joining native campaign co-op | Demonstrated on the development PC |
| Two separate physical controllers during gameplay | Demonstrated on the development PC |
| Death and checkpoint reload | One recorded passing test on the development PC |
| Reduced co-op emulator source | Available in the [custom Xenia repository](https://github.com/eternalgr3y/xenia-canary-aot-coop) |
| Release executable built from that exact published source | Pending release validation |
| First-time setup on a different PC | Pending |
| Long-session stability and broad hardware compatibility | Not established |

The working development executable and the newer clean source candidate are different builds. The newer candidate must repeat the gameplay tests before it can inherit the working build's status.

## What you will need

- A Windows PC capable of running two instances of Xenia at once. Minimum hardware requirements have not been established.
- Two supported controllers.
- Your own legally obtained game dump, matching the version supported by the eventual release.
- Local profiles and saves created for your own setup.
- The service prerequisites documented with the release. Current development setup uses Node.js, Python, and MongoDB.

Game files, someone else's profiles or saves, and console or account secrets are not included.

## How it works

Each player runs a separate game instance. The custom emulator changes, launcher, and local service implementations let those instances use the game's native co-op flow on the same computer. The services run locally; this does not restore EA's official servers.

Codex is not a runtime dependency.

## Source code

| Component | Location |
| --- | --- |
| Launcher, setup, FESL companion code, configuration, and project documentation | [This repository](https://github.com/eternalgr3y/aot-40th-day-same-pc-coop) |
| Xenia Web Services companion | [xenia-webservices-aot-coop](https://github.com/eternalgr3y/xenia-webservices-aot-coop) |
| Custom Xenia emulator | [xenia-canary-aot-coop](https://github.com/eternalgr3y/xenia-canary-aot-coop), source candidate `b8c0c4952` |

See [ALPHA_MANIFEST.md](ALPHA_MANIFEST.md) for the exact component commits and build evidence. Curated downloads include a file manifest and checksums.

For the current technical packaging status, see [PACKAGING.md](https://github.com/eternalgr3y/aot-40th-day-same-pc-coop/blob/main/PACKAGING.md). Development instructions may still contain assumptions specific to the reference PC; they are not yet a verified installation guide for other machines.

## Reporting problems

This is experimental software. When a player package becomes available, report the package version, game version, relevant hardware, what you did, and what happened. Share only the smallest useful diagnostic excerpt after checking it for personal information.

## Credits and licenses

This project builds on Xenia, Xenia Canary, AdrianCassar's netplay work, Xenia Web Services, and their contributors. It is an independent project and is not endorsed by EA, Microsoft, or the upstream emulator projects.

Original code in this repository is covered by its [MIT license](https://github.com/eternalgr3y/aot-40th-day-same-pc-coop/blob/main/LICENSE). Xenia and other components retain their own licenses. See [THIRD_PARTY_NOTICES.md](https://github.com/eternalgr3y/aot-40th-day-same-pc-coop/blob/main/THIRD_PARTY_NOTICES.md) and the licenses included with each component.
