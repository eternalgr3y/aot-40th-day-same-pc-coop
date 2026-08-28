# Army of Two: The 40th Day same-PC co-op

This project preserves and publishes the reproducible tooling, tests, and
evidence boundaries for same-PC native campaign co-op in two Xenia Canary
instances. It is an experimental source alpha; it contains no game image,
Xbox system content, profiles, saves, or keys.

The working path uses local loopback XWS and FESL-compatible services. It does
not restore, contact, or depend on the discontinued official EA servers.

## Experimental alpha quick start

The supported Codex-independent candidate entry point is `Start-AOT-Coop.ps1`.
The proven save flow is role-asymmetric: Daddy uses the occupied middle
`SAVE_SLOT_1` checkpoint whose action reads `CONTINUE`, while CJ uses the
verified-empty right `SAVE_SLOT_2` so the title browses and joins Daddy instead
of creating a second host session. The protected state-aware driver has now
completed a controlled runtime acceptance of that slot-asymmetric join. The
`Start-AOT-Coop.ps1` front door now enforces the same flow with an empty-slot
storage check, a two-sample live slot gate, stable guest-UI evidence, retryable
`HOLD`, and continuous exact-session monitoring while WHITE presses A. Its
direct full-launch path remains a candidate until it completes its own recorded
controlled run.

### Run it on the proven PC without Codex

1. Connect/wake both the wired black and Bluetooth white controllers.
2. Use `PLAY-AOT-COOP.cmd check` for the read-only readiness check, then
   double-click `PLAY-AOT-COOP.cmd` for the candidate full launch. A public
   install with only `aot-coop.portable.psd1` automatically selects the direct
   portable plan; the proven PC keeps its legacy local-config route.
3. Follow only a slot-asymmetric BLACK/WHITE flow: BLACK/Daddy uses the occupied
   middle slot 1 whose action reads `CONTINUE`; WHITE/CJ uses the
   verified-empty right slot 2. WHITE must not use an occupied `CONTINUE` slot,
   and neither side may accept an overwrite warning.
4. When the launcher reports `CONNECTED`, press A on WHITE, A on BLACK, then A
   on BLACK again to start.

The launcher starts the local XWS and FESL services and both Xenia instances.
MongoDB is expected to be the already-installed loopback-only Windows service.
The terminal pauses only for the in-game actions that cannot be safely inferred
or automated. Codex is not part of the runtime. The protected driver/runtime
acceptance now proves the Daddy-slot-1/CJ-slot-2 join on the original PC. The
CMD wrapper and direct PowerShell path have passed parser/static/read-only
checks and now enforce the asymmetric slot contract. Do not call either front
door runtime-proven until its direct flow completes a recorded controlled run,
and never follow a WHITE middle-`CONTINUE` route.

For a read-only check from a terminal, run `PLAY-AOT-COOP.cmd check`.

```powershell
# Read-only: verifies hashes, paths, Mongo, ports, CPU masks, controller routes,
# inert inject files, and both exact B19 launch-line fingerprints.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-AOT-Coop.ps1 -InspectOnly

# Candidate full cold launch. Its prompts require BLACK occupied slot 1 and
# WHITE verified-empty slot 2; direct runtime acceptance is pending.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-AOT-Coop.ps1

# Direct immutable-plan candidate using the current machine config. This
# bypasses _play_hero.ps1 at process creation and is not yet runtime-accepted.
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Start-AOT-Coop.ps1 -LaunchEngine PortablePlan
```

The original proven PC retains Schema 1 in ignored `aot-coop.local.psd1`.
For a portable install, copy `aot-coop.portable.example.psd1` to ignored
`aot-coop.portable.psd1` and fill only values generated on that PC. Local
configs, rigs, saves, backups, executables, game images, logs, screenshots,
and databases are ignored by Git.

The current evidence grade is a **working private alpha**: a real two-player
native session, bidirectional transport, a shared rendered scene, physical-pad
play, and one user-driven co-op death/checkpoint reload are proven. The later
successful reload supersedes the earlier wrong-possession failure for the
current B19 profile. See `PUBLIC_ALPHA.md` for the exact one-cycle scope and
the remaining backend/long-soak caveats before treating this as a general
release.

## Portable player-kit work

The historical launcher remains the runtime-evidence authority. The portable
foundation now includes a direct plan executor behind `-LaunchEngine
PortablePlan`; its setup and preview modes do not launch Xenia or claim
fresh-machine success:

```powershell
# Zero-write, zero-launch readiness inventory.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup-AOT-Coop.ps1

# Pure launch-plan preview. Requires a local SchemaVersion 2 config copied
# from aot-coop.portable.example.psd1; does not start either rig.
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\tools\runtime\New-AotPortableLaunchPlan.ps1 `
  -Side Daddy -ConfigPath .\aot-coop.portable.psd1 -SkipFileChecks
```

The immutable B19 templates reproduce both frozen command hashes on the proven
PC and carry sanitized copies of the three co-op patches enabled by that frozen
profile; their individual necessity has not been ablated. Setup now derives
whole-core P/E-aware masks and detects both USB and BTHLE/XINPUT controllers
without writing configuration. Fresh Xenia profile creation, the required
role-asymmetric save layout (Daddy's occupied middle `SAVE_SLOT_1` and CJ's
verified-empty right `SAVE_SLOT_2`), dynamic display placement, a
source-matched emulator build, and a clean-PC join/gameplay/death-reload
acceptance remain blocking gates. Do not copy the
current profiles or saves to bypass them. See `PACKAGING.md`.
The source-confirmed manual creation flow for two fresh local Xenia identities
is in `PROFILE_BOOTSTRAP.md`; it does not replace runtime validation of the
slot-asymmetric flow on a new install.

In the full private research repository, start with `MODEL_HANDOFF.md`, then
consult `PROPER_COOP_ATLAS.md` for the proper FESL/Theater retail path. Those
deep-research notes are intentionally outside the portable runtime-source
snapshot. Historical SP-listen hotjoin experiments are diagnostic fallback
material and are not proof of the desired online path.

The companion source locations are
[xenia-webservices-aot-coop](https://github.com/eternalgr3y/xenia-webservices-aot-coop)
and
[xenia-canary-aot-coop](https://github.com/eternalgr3y/xenia-canary-aot-coop).
The clean XWS source is validated, while the public Xenia fork remains blocked
until the title-specific secure-association/native post-join layer is reduced
without the private diagnostic history. Consequently this repository is not
yet a self-contained player kit. Runtime rigs, game content, reverse-
engineering databases, bulk logs, and machine-local state are intentionally
not stored in public Git. See `PACKAGING.md` for the remaining boundary.

Build success, static guards, backend self-tests, emulator connection, guest
world entry, and playable/rendered two-player co-op are separate proof levels.
Do not infer a later level from an earlier one.
