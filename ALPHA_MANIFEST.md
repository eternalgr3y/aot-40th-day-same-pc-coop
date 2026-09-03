# Alpha source provenance manifest

Originally prepared on 2026-08-26 and updated for the curated source-alpha
release on 2026-09-02. Release tags and artifact hashes are recorded only
after remote verification.

## Source locations and companion commits

- public orchestration/source alpha:
  <https://github.com/eternalgr3y/aot-40th-day-same-pc-coop>
- public Xenia WebServices source:
  <https://github.com/eternalgr3y/xenia-webservices-aot-coop> at
  `bc2f6e27f40911fca2730ce5ac04ffc64c49351e`
- public Xenia source location:
  <https://github.com/eternalgr3y/xenia-canary-aot-coop>
- clean Xenia runtime-core acceptance candidate:
  commit `b8c0c49520e841a97309e7c742570c0a8769c4f6`, tree
  `1194169c7723b1bbf314105c5255a7ea2e2e7c97` (published source;
  runtime acceptance pending)

The XWS pin keeps the sanitized legacy EA self-test and makes the AoT-only
session reset use XWS's configured Mongo URI/database with a declared direct
driver dependency and offline tests. Its rebuilt `dist/main.js` and reset-
helper hashes match the reference values below. The title-specific runtime
core has now been separated into the clean Xenia candidate named above.
The source-matched executable has only source/build evidence. A controlled
same-PC physical-pad runtime acceptance remains an open gate.

## Pinned runtime inputs

- runtime-proven B19 Xenia SHA-256:
  `B19F51D4D6C3730C6D7D998B4A0D75C0A5A2D911260829C47C6728E3AD464B06`
- clean runtime-core acceptance-candidate Xenia SHA-256 (not runtime-proven):
  `E0AE2C785BC19637E83019FE921E0D3CEE83B229D1CDF9B82F6508A50336C629`
  (`17,942,016` bytes)
- loopback-only XWS `dist/main.js` SHA-256:
  `10D4C6B7C99EC423D875E69195D378EA304077A489001C5F286B797BA00CF63E`
- AoT-only XWS session-reset helper SHA-256:
  `4C96DCE9C8CA0012E7FE17EDD7E522F4448EBC227E45E304CB3AE907117681B1`
- portable FESL service SHA-256:
  `B9711B60EE3B28EE75E0EFBE1DF304EA46087F3ED7AD99DF97AF93C85867747E`
- Daddy launch-line SHA-256:
  `2C604E2C124AE9485E716AC615F64EF6B9760CA52D160FAB15A09D1A09744BC6`
- CJ launch-line SHA-256:
  `72C1B51FBFFACEAFF9940EE24FFECE831DDB1868E10A344584258704E6DC4CFB`

## Portable B19 static profile

- Daddy sanitized template SHA-256:
  `26C44B74511E80238042F61C095976A03089DBCBF65E31A7DCD02CDA78A952DF`
- CJ sanitized template SHA-256:
  `8E9122E972389EAFA0701DA7BFC1C301043FF490049334EC70901B743145CEBC`
- portable bind-6000 patch SHA-256:
  `BCD3F9A62106424908DA3AD8B543D1A482D4C4561DCCBF26D8EBE99A8CFBE295`
  (frozen rig source: `8E4AD2F88B5A8C1545583FA770FDCA2D42F716FD8F5FE7C4691BD3B59276BBE9`)
- portable unaddressed-COd patch SHA-256:
  `F5CC6083791194E48106E4DE7D6D31C061BAFB43FA90EE935A56698398BC5036`
  (frozen rig source: `C6A4A05163B7870D0A0E856D1BE3381B5D27E2D200292A33CC2DAC697E607285`)
- portable hold-CONNECTING-v2 patch SHA-256:
  `F01126934D5CE6E7DBC9D3C51D3F119DA7C50684B83AF838B4C3C8ED22497440`
  (frozen rig source: `27FC975992EC57A3E7022EBBA7FEC73CB9798C0621BF88E1196B430F427F2482`)

The pure plan builder reproduces the two frozen launch hashes above from the
current local config and rejects changed templates, frozen-profile patch
assets, duplicate options, unsafe endpoints, topology drift, unmanaged rig
paths, unsafe CPU-mask overlap, duplicate controller routes, and the
unsupported Daddy checkpoint slot; CJ remains fixed to verified-empty slot 2.
`Start-AOT-Coop.ps1` can now execute only the plan's typed process fields
through explicit `PortablePlan` mode and enforces Daddy occupied slot 1 versus
CJ empty slot 2. The current XWS/FESL tuple and
historical launcher completed a controlled exact-session lobby join and 12/12
settle on 2026-08-27; the direct typed executor still has not completed its own
controlled run, and this tuple has not repeated shared gameplay/death reload.
The frozen upstream visual patch hash remains
recorded in `profiles/b19/profile.psd1`, but that file is not bundled because
its redistribution status and co-op necessity are unresolved.

## Clean runtime-core offline acceptance profile

`profiles/b19-runtime-core-acceptance` is separate from the frozen B19 launch
profile. Its Daddy and CJ templates both have SHA-256
`FCDFFB2CB25300BF32D19AE64DB62A7343FF330EA4FFF9A22390AA8B7738FB2E`
and resolve to 16 arguments/15 options without right-X inversion, or 17/16
with the one requested inversion option. The only permitted `aot_*` switches
are `aot_runtime_peer_ipv4`, `aot_runtime_sa2`,
`aot_runtime_leg_destination_repair`, and
`aot_runtime_xport_control_load_repair`. The profile copies exactly the three
canonical patch files and hashes listed above.

`tools/runtime/New-AotRuntimeCoreLaunchPlan.ps1` is an offline validator, not a
launcher. It verifies the source/build pin, candidate executable, game input,
declared MAC/XUID/loopback relationships, two distinct declared SDL VID/PID
routes, declared CPU-mask disjointness, the minimal argument set, and exact
three-patch closure. It does not enumerate current CPU topology, prove that
either controller is attached, or inspect persisted rig `xconfig.settings`.
It always hashes the complete game image. Its output reports
`LaunchCapable=false` and runtime acceptance pending; it contains no process,
service, network-discovery, rig-write, or save-write path.

Three source/synthetic-only acceptance components sit behind that planner:
`Initialize-AotRuntimeCoreRigs.ps1` verifies an exact 12-file inert seed and
adversarial no-overwrite contract, `AotOwnedProcess.psm1` models exact retained
process/window ownership and no-focus cleanup, and
`AotRuntimeCoreLogWatch.psm1` performs bounded, generation-preserving log
observation before the offline reducer. The seeder rejects every production
invocation with `PRODUCTION_RIG_SEEDING_CLOSURE_DEFERRED`. The process layer
rejects production launch with `PRODUCTION_LAUNCH_CLOSURE_DEFERRED` and keeps
service authority behind `PRODUCTION_SERVICE_AUTHORITY_DEFERRED`. These modules
do not establish a player-ready launch path: `PlayerKitReady`, `RuntimeTested`,
and `LaunchCapable` remain false.

The pending runtime contract requires exactly one current-run stage-2 manager
arm marker from Daddy and exactly one from CJ. At least one side must also
contain this complete same-side SA2 evidence chain with strictly increasing
`seq` values and one matching nonzero `generation`:

```text
[AOT-RUNTIME-SA2][ACCEPT] seq=<seq> generation=<generation> stage=1 event=PRECONNECT_XSA1_PREPARED_FOR_GUEST
[AOT-RUNTIME-SA2][ACCEPT] seq=<seq> generation=<generation> stage=2 event=XNETCONNECT_MANAGER_ARMED
[AOT-RUNTIME-SA2][ACCEPT] seq=<seq> generation=<generation> stage=3 event=POSTCONNECT_XSA1_RETRANSMIT_CONSUMED_ACK_SENT
```

Stage 1 is deliberately limited to proving that the exact valid pre-connect
XSA1 reached the preserved guest-completion path; it does not claim that the
guest consumed the datagram. Stage 1 and stage 3 may each occur at most once
per side. The other side may legitimately contain only stage 2 or a matching,
increasing stage-1-to-stage-2 or stage-2-to-stage-3 pair. Events from different
processes are never stitched into a chain, and generic join or session success
cannot replace this ordered evidence. The contract also requires an external timeout with
verified cleanup. Zero live Xenia processes and isolated no-overwrite roots
gate inert first-time rig seeding. After profiles and saves are created locally,
a verified save backup is mandatory before mutable acceptance-run preparation
or launch. Daddy occupied slot 1 versus CJ verified-empty slot 2, nonzero XWS
`whoami`/backend health, live topology, persisted identity, physical-pad
isolation, shared-session gameplay, and death/checkpoint reload are also
explicit gates. A custom profile root is accepted only in synthetic
temp-fixture mode and is labeled untrusted; production planning pins the
reviewed normalized profile bytes.

The canonical patch files retain historical comments mentioning
`--aot_register_peer`. That legacy private-runtime flag is not accepted by this
profile; the reviewed `aot_runtime_sa2` path and explicit peer IPv4 replace it.

On the reference i7-14700K, the read-only Windows CPU-set allocator reproduces
the accepted full-performance masks exactly: Daddy `001F00FF`, CJ `07C0FF00`,
XWS `08200000`, and FESL `00200000`. This is source/read-only validation, not
fresh-machine runtime proof.

The working B19 reference executable came from an incompletely recorded dirty
source tree. Later reconstructions and the reduced public runtime candidate
are distinct builds; none inherit B19's gameplay acceptance. This release pins
the public runtime candidate above and does not require a private source
repository.

## Evidence grade

The combined current-profile evidence is a working private-alpha pass: the
frozen physical-pad run proves the shared session, native peer transport, and
shared rendered scene, and a later user-driven B19 checkpoint-resume test
proves one successful co-op death/reload cycle. The earlier wrong-possession
failure is retained as historical evidence but was superseded for the tested
flow. See
`docs/b19_same_pc_physical_acceptance_20260826.md`.

## Release boundary

- Runtime rigs, game content, saves, profiles, logs, screenshots, databases,
  generated traces, build outputs, and machine-local configuration are ignored.
- The repository boundary guard rejects forced-staged binaries, save containers,
  evidence formats, disallowed tool trees, and indexed blobs of 50 MiB or more.
- `THIRD_PARTY_NOTICES.md` carries the BSD notice for the retained Xenia source.
- Project-authored orchestration, tests, documentation, and co-op patch
  definitions are MIT licensed. Retained Xenia source remains BSD licensed.
- The allowlisted public snapshot excludes personal paths, profile/session
  identifiers, and private history. The full research archive remains private.
- This source snapshot is publication-safe but still not a player kit; the
  source-built Xenia and clean-machine runtime gates above remain open.
