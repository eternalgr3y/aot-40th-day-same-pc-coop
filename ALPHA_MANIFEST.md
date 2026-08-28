# Alpha source provenance manifest

Originally prepared on 2026-08-26 and updated for the public source-alpha
boundary on 2026-08-28. Release tags and artifact hashes are recorded only
after remote verification.

## Source locations and companion commits

- public orchestration/source alpha:
  <https://github.com/eternalgr3y/aot-40th-day-same-pc-coop>
- public-ready Xenia WebServices source:
  <https://github.com/eternalgr3y/xenia-webservices-aot-coop> at
  `bc2f6e27f40911fca2730ce5ac04ffc64c49351e`
- reserved Xenia source location:
  <https://github.com/eternalgr3y/xenia-canary-aot-coop>
- private reference reconstruction: `codex/github-alpha-b19` at
  `afcb6e4ca683c3d14f6de7397f8b8818d8ae1550`

The XWS pin keeps the sanitized legacy EA self-test and makes the AoT-only
session reset use XWS's configured Mongo URI/database with a declared direct
driver dependency and offline tests. Its rebuilt `dist/main.js` and reset-
helper hashes match the reference values below. The reserved Xenia repository
does not yet contain a publishable AoT commit: the small portable foundation
builds, but the required title-specific secure-association/native post-join
layer remains in private research history. That is a release blocker, not an
implied public dependency.

## Pinned runtime inputs

- runtime-proven B19 Xenia SHA-256:
  `B19F51D4D6C3730C6D7D998B4A0D75C0A5A2D911260829C47C6728E3AD464B06`
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

On the reference i7-14700K, the read-only Windows CPU-set allocator reproduces
the accepted full-performance masks exactly: Daddy `001F00FF`, CJ `07C0FF00`,
XWS `08200000`, and FESL `00200000`. This is source/read-only validation, not
fresh-machine runtime proof.

The private Xenia source commit is the best reconstruction of the dirty source
tree that likely produced B19, with private-alpha diagnostic hygiene added. The
original binary recorded only base HEAD `d8205479e61dd331f01f7c110064ffe8b162d27d`,
not a dirty-tree hash. On 2026-08-27, build metadata was regenerated from clean
commit `afcb6e4ca683c3d14f6de7397f8b8818d8ae1550`, the 1,273-file build output
was cleaned, and the application, CPU tests, and HID tests were rebuilt. The
resulting local executable has SHA-256
`9A02C2C9DD63FAB9C9BB9AFF193D60C389F52606EBA1B8EB54963D15F11007ED`, embeds
`codex/github-alpha-b19@afcb6e4ca`, and omits the stale `d8205479e` identity.
CPU execution passed 9,046 assertions in 247 cases; HID execution passed 21,216
assertions in 42 cases. It remains the pending source-built candidate and is
not in `AcceptedRuntimeXeniaSha256`; promotion requires its own controlled run.
It is retained for provenance but is not presented as a publicly reproducible
source dependency.

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
