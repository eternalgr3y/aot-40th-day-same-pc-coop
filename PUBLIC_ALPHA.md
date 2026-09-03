# Public source alpha status

This repository publishes the reproducible source, configuration templates,
tests, and evidence boundary for running the Xbox 360 version of
**Army of Two: The 40th Day** as native two-player online campaign co-op in two
Xenia instances on one Windows PC.

## What is proven

On the reference PC, the frozen B19 runtime completed the retail online path:
one Xenia instance hosted, the second joined with `HOSTbit=false`, both players
used separate physical controllers, both rendered and played the same campaign
session, and a later user-driven co-op death/checkpoint reload succeeded.

The join route is role-asymmetric. The host selects its occupied middle
`SAVE_SLOT_1` checkpoint. The guest selects a verified-empty right
`SAVE_SLOT_2`. Selecting an occupied guest `CONTINUE` slot invokes the game's
host action and creates a second lobby; the launcher now detects and rejects
that path.

## What this release is

This is an experimental **source alpha for technical testers**, not yet a
one-click player kit. It contains no game image, Xbox system content, profiles,
saves, account data, keys, or private EA service. Players must provide a
legally obtained dump and create two independent local Xenia profiles.

The public source snapshot carries the three project-authored co-op patch
definitions and provides a read-only setup check plus the guarded launcher.
The sanitized Xenia WebServices commit is public. The reduced Xenia AoT
runtime-core source candidate is published in
[xenia-canary-aot-coop](https://github.com/eternalgr3y/xenia-canary-aot-coop) at commit
`b8c0c49520e841a97309e7c742570c0a8769c4f6` (tree
`1194169c7723b1bbf314105c5255a7ea2e2e7c97`) with a source-matched build and
an isolated offline acceptance profile. It has not yet been runtime-accepted,
so this snapshot is not yet a
self-contained player reproduction. The full private research archive, raw
captures, runtime rigs, and reverse-engineering databases are intentionally
not published.

## Remaining portability boundary

The clean source-built Xenia runtime core is pinned to executable SHA-256
`E0AE2C785BC19637E83019FE921E0D3CEE83B229D1CDF9B82F6508A50336C629`
and size `17,942,016` bytes.
`New-AotRuntimeCoreLaunchPlan.ps1` can validate a plan with two distinct
declared SDL VID/PID routes using only the four reviewed runtime-core switches
and the three known guest patches. It checks declared identity and CPU-mask
relationships and always verifies the full game-image hash, but it does not
enumerate current topology, prove that the pads are attached, or inspect each
rig's persisted identity settings. It carries explicit pending gates for
zero-live, no-overwrite first-time rig seeding and, after local profile/save
creation, a verified backup before mutable acceptance-run preparation or
launch. Daddy occupied slot 1 versus CJ verified-empty slot 2 and backend
identity/health remain required. The SA2 runtime gate requires exactly one
current-run `XNETCONNECT_MANAGER_ARMED` marker from each rig. At least one side
must then prove one matching generation with increasing `seq` across
`PRECONNECT_XSA1_PREPARED_FOR_GUEST`, `XNETCONNECT_MANAGER_ARMED`, and
`POSTCONNECT_XSA1_RETRANSMIT_CONSUMED_ACK_SENT`. The other side may contain
only its arm marker, a matching prepare-to-arm pair, or a matching
arm-to-consume/ACK pair; markers are never stitched across processes. Generic
join/session success cannot replace those exact markers. An external timeout
is also required.
The accompanying initializer, owned-process layer, and bounded log watcher have
only source/synthetic validation. The initializer refuses real path access with
`PRODUCTION_RIG_SEEDING_CLOSURE_DEFERRED`; the process layer refuses real launch
with `PRODUCTION_LAUNCH_CLOSURE_DEFERRED` and keeps local-service authority
deferred. They do not make the artifact launch-capable. `PlayerKitReady`,
`RuntimeTested`, and `LaunchCapable` remain false. The new executable has not
yet repeated the complete physical-controller gameplay/death-reload
acceptance. Until that run and a clean-machine trial are complete, do not
describe this source alpha as a portable player release.

See `PACKAGING.md`, `PROFILE_BOOTSTRAP.md`, and `ALPHA_MANIFEST.md` for the
exact prerequisites and evidence grades.

## Legal and affiliation notice

This is an independent interoperability and preservation project. It is not
affiliated with or endorsed by Electronic Arts, Microsoft, the Xenia project,
or the Xenia Canary maintainers. **Army of Two** and related marks and game
content belong to their respective owners. The project-authored source is MIT
licensed; third-party components retain their own licenses as recorded in
`THIRD_PARTY_NOTICES.md`.
