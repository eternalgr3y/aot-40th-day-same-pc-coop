# Fresh portable rig and profile bootstrap

Status: **source-confirmed workflow; clean-machine runtime acceptance pending**.
This procedure creates identities locally on the player's PC. Never copy the
current Daddy/CJ rigs, `xconfig.settings`, Account files, GPDs, or saves.

## Seed two independent rigs

The steps below describe the intended manual/source-confirmed layout. The
current `Initialize-AotRuntimeCoreRigs.ps1` is not a production installer: it
exits with `PRODUCTION_RIG_SEEDING_CLOSURE_DEFERRED` before real filesystem or
process access. Its exact-tree, no-overwrite, ownership, and adversarial cases
are synthetic validation only while retained native directory/file identity is
unfinished.

Create `rigs\daddy` and `rigs\cj` independently. Into each fresh directory,
copy only:

```text
xenia_canary_netplay.exe   # exact source-matched release build
portable.txt               # empty marker file
inject.txt                 # UTF-8/ASCII text containing exactly: NONE
patches\                   # three allowlisted frozen-profile co-op patches
```

This inert first-time seed necessarily happens before either fresh rig has
profiles or saves to back up. It is allowed only with zero live Xenia
processes, absent direct-child rig targets, and no-overwrite creation. It does
not satisfy the later save-preservation gate.

`inject.txt` is an inert fail-safe input, not an automation channel. Its
trimmed content must be exactly `NONE`; the launcher verifies it and never
writes it.

The fork's generated configuration filename is
`xenia-canary-netplay.config.toml`. Do not seed or validate the older
`xenia-canary.config.toml` name; existing development rigs may contain both
and can conceal this fresh-install difference.

After each rig has generated that file and exited cleanly, set this exact TOML
option in it before the co-op preflight:

```toml
apply_patches = true
```

The launcher refuses a missing setting, an inert `inject.txt` that is not
exactly `NONE`, or any enabled patch set outside the pinned B19 manifest.

Do not copy one initialized rig to make the second. Xenia generates a persistent
console MAC when `xconfig.settings` is absent, so cloning after first boot would
duplicate network identity.

## Create one persisted Live-enabled profile per rig

Run one rig at a time with no game path:

```powershell
& '.\xenia_canary_netplay.exe' `
  '--portable=true' `
  '--network_mode=0' `
  '--upnp=false' `
  '--aot_auto_signin=false' `
  '--auto_check_updates=false' `
  '--discord=false'
```

In Xenia:

1. Open **Profile > Show Profile Menu**.
2. Choose **Create Profile** and enter a local name.
3. Leave **Xbox Live Enabled** checked, then create it.
4. Right-click the profile and copy **XUID**.
5. Right-click it again and copy **XUID Online**.
6. Exit through **File > Exit** so persistent settings are saved.
7. Repeat from the other independently seeded rig.

If Live was unchecked, use **Convert to Xbox Live-Enabled Profile** before
recording the values. Do not rely on `--aot_auto_signin=true` to convert it: a
missing online XUID may then exist only in memory and change on the next boot.

## Derive and validate local identity

For a fresh profile made by this pinned Xenia fork:

```text
MacAddress   = "7C1E" + last 8 hex digits of ProfileXuid
HostAddress  = "127." + decimal values of the last 3 MAC bytes
PlayerPort   = 36001 + (MacAddress & 0x3FF)
```

The portable config must satisfy all of these:

- `ProfileXuid`: `E000` plus 12 uppercase hex digits.
- `OnlineXuid`: `0009` plus 12 uppercase hex digits and persisted after reopen.
- `MacAddress`: `7C1E52` plus 6 uppercase hex digits.
- Offline-XUID low 8 hex digits equal MAC low 8 hex digits.
- Daddy and CJ have different offline XUIDs, online XUIDs, MACs, and derived
  `127.x.y.z` addresses and synthetic player ports. Distinct MACs alone are
  insufficient because two MACs can share the same low ten bits.
- Each rig reopens with the same values while `aot_auto_signin=false`.

`New-AotPortableLaunchPlan.ps1` validates these relationships without launching
the emulator. The values stay in ignored local config and never enter a source
or player ZIP.

## Remaining save gate

A fresh profile is not enough to claim portable co-op. The save layout is
role-asymmetric: Daddy must create and live-validate a nonempty middle
`SAVE_SLOT_1` whose action is `CONTINUE`, while CJ must keep the right
`SAVE_SLOT_2` absent on disk and visibly selected as the empty join route.
An occupied CJ slot dispatches the reproduced self-host path and must fail
closed. After that, the clean setup must repeat native join, physical-pad
gameplay, death/checkpoint reload, and a longer soak before the artifact can be
called a player kit.

After those files have been created locally, the guarded acceptance runner
must refuse every mutable run-preparation or launch step until it can make a
verified backup of 14 files: for each profile, one leaf and one header for
`default_checkpoint_0.sav`, `default_checkpoint_1.sav`, and `game_data.sav`,
plus that profile's `454108D8.gpd`. All three save containers on one side must
use the same single leaf name. This protects the player's data; it is not a
license to copy the reference PC's files.

A qualifying runtime-core run must record exactly one current-run stage-2
manager-arm marker from Daddy and exactly one from CJ. At least one side must
also record this complete same-side SA2 chain with strictly increasing `seq`
values and one matching nonzero `generation`:

```text
stage=1 event=PRECONNECT_XSA1_PREPARED_FOR_GUEST
stage=2 event=XNETCONNECT_MANAGER_ARMED
stage=3 event=POSTCONNECT_XSA1_RETRANSMIT_CONSUMED_ACK_SENT
```

Stage 1 proves only that the exact valid pre-connect frame was prepared for
the preserved guest completion path. Stage 1 and stage 3 may each occur at
most once per side. The other side may legitimately show only stage 2 or a
matching, increasing stage-1-to-stage-2 or stage-2-to-stage-3 pair. Evidence
from separate processes is never combined into a chain. Generic lobby, join,
or session success does not close this evidence gate.

`AotRuntimeCoreLogWatch.psm1` and `AotRuntimeCoreEvidence.psm1` implement this
bounded observation/reduction contract with source/synthetic coverage. They
have not yet observed a controlled run from the clean candidate and do not set
`RuntimeTested` or `PlayerKitReady` true.

For a new test install, create these files through the retail title on each rig
independently. Initialize slots 0 and 1 and exit through the title normally so
the game-data and profile records persist. On Daddy, slot 1 must be the
checkpoint to host. On CJ, leave slot 2 untouched and empty. Before attempting
co-op, close both Xenia instances and run `PLAY-AOT-COOP.cmd portable-check`;
its exact error identifies any missing container/header/profile file. This
procedure is source-confirmed but still awaits clean-machine runtime acceptance.
