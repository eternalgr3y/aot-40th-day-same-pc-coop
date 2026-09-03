# Packaging the same-PC co-op alpha

## Current answer

The frozen B19 setup is a working **machine-bound alpha**, not yet a portable
player package. The Codex-independent runtime candidate is
`Start-AOT-Coop.ps1`; `PLAY-AOT-COOP.cmd` is its double-click wrapper. Both
have static/read-only validation but not yet a recorded full launch. The
separate clean runtime-core candidate currently stops one step earlier:
`New-AotRuntimeCoreLaunchPlan.ps1` produces and validates an offline plan but
has no production process-launch capability. Its first-run seeder,
owned-process layer, and log watcher are source/synthetic acceptance
scaffolding: production seeding and launch are deliberately hard-blocked until
their native identity/authority closure is complete. The
historical protected pairer produced the current gameplay proof, and the later
protected driver/runtime acceptance proved the role-asymmetric Daddy-slot-1/
CJ-slot-2 join on the original PC.
Copying or zipping this workspace for another person will not reproduce the
run.

Two different artifacts should be released:

1. A source/research release containing sanitized orchestration, tests,
   documentation, and the two companion source forks.
2. A later player kit created from clean, pinned source commits after the
   portability work and a fresh-machine runtime acceptance.

## Never distribute

- The Army of Two ISO/XEX, title updates, DLC, Xbox system files, or keys.
- Either live rig directory, profiles, GPDs, saves, headers, caches, logs,
  screenshots, dumps, MongoDB data, or Ghidra databases.
- `aot-coop.local.psd1`, personal paths, current XUIDs/MACs, or last-run state.
- Historical ferry/pass launchers that embed machine paths and identities.
- A release described as reproducible when its executable was not built from
  the source commit named in the release manifest.

Players must supply their own legally obtained game dump and create their own
local profiles and saves.

## Why the current tree is not portable

- The accepted Schema 1 fallback is tied to this PC's folders, masks,
  controllers, display placement, and role-asymmetric save layout. Schema 2
  removes the hardcoded folder/mask/controller inputs, but setup still does not
  create the rigs, profiles, saves, or dynamic display placement needed by a
  player kit.
- Schema 1 defaults to the historical `_play_hero.ps1` chain for comparison.
  `-LaunchEngine PortablePlan` and every Schema 2 run execute only typed fields
  from the sanitized B19 plan. That direct executor is wired in but has not
  yet been live-accepted.
- The three co-op patch TOMLs enabled by the frozen profile are now tracked and
  hash/semantic-asserted by the portable plan builder. Their individual
  necessity has not been ablated. `Start-AOT-Coop.ps1` still relies on the
  proven rigs' patch state, so this is static portability evidence rather than
  a new run.
- There is no production-safe first-run creator for the required rigs, two
  profiles, and 14 save/profile files. The synthetic initializer proves the
  exact 12-file inert seed layout and adversarial no-overwrite contract, but
  exits with `PRODUCTION_RIG_SEEDING_CLOSURE_DEFERRED` before real path access;
  retained native directory/file identity is still required. The proven flow
  requires Daddy's occupied middle slot and CJ's verified-empty right slot; it
  rejects an empty host slot and an occupied joiner slot.
- Runtime-proven B19 was produced from an incompletely recorded dirty tree.
  A clean runtime-core candidate is now pinned to source commit
  `b8c0c49520e841a97309e7c742570c0a8769c4f6`, tree
  `1194169c7723b1bbf314105c5255a7ea2e2e7c97`, and a `17,942,016`-byte
  executable with SHA-256
  `E0AE2C785BC19637E83019FE921E0D3CEE83B229D1CDF9B82F6508A50336C629`.
  Its isolated profile accepts only the four runtime-core switches and the
  three canonical guest patches. The offline planner cannot start a process,
  and the executable has not repeated gameplay/death-reload acceptance.
- The project-authored orchestration source and co-op patch definitions are
  MIT licensed; Xenia and XWS retain their BSD-3-Clause and MIT notices.

## Target player-kit layout

```text
AoT-Coop-Alpha/
  PLAY-AOT-COOP.cmd
  Setup-AOT-Coop.ps1
  Start-AOT-Coop.ps1
  README.md
  LICENSE
  THIRD_PARTY_NOTICES.md
  release-manifest.json
  SHA256SUMS
  config/aot-coop.example.psd1
  emulator/xenia_canary_aot.exe
  emulator/SOURCE_COMMIT.txt
  services/fesl/fesl_server.py
  services/xws/                    # pinned source/build
  rigs/daddy/                      # generated locally
  rigs/cj/                         # generated locally
```

Node, Python, and MongoDB should initially be installed as prerequisites rather
than copied from this development machine.

The orchestration source snapshot deliberately excludes XWS `node_modules` and
ignored `dist/`. For a source-candidate checkout, use public XWS commit
`bc2f6e27f40911fca2730ce5ac04ffc64c49351e`, install exactly from its lockfile
with `npm ci`, and run `npm run build`. Before launch, verify `dist/main.js` and
`clear_aot_sessions.js` against the hashes in `ALPHA_MANIFEST.md`; a clean XWS
clone without that dependency/build step is not a runnable backend. Keep it on
loopback: its inherited dependency audit still contains high-severity findings
and it is not hardened for internet deployment.

## Portability work, in order

1. **Frozen runtime integration statically complete; controlled acceptance pending:**
   a config-driven builder reproduces both frozen B19 launch hashes, validates
   229 options/230 arguments, and Schema 2 launches from typed plan fields
   without reading historical BAT/PowerShell launchers.
2. **Clean runtime-core isolation and synthetic acceptance scaffolding
   complete; production closure pending:** the offline-only acceptance planner
   validates a source-matched
   Xenia build, declared identity relationships, two distinct declared SDL
   VID/PID routes, declared CPU-mask disjointness, 16/17 minimal arguments,
   exactly four reviewed `aot_runtime_*` switches, and exactly three canonical
   guest patches. It always verifies the full game-image hash. Current topology,
   persisted rig identities, and attached-controller presence remain runtime
   gates. Zero live Xenia and isolated no-overwrite roots gate inert first-time
   seeding. Once each rig has created its own local profile and saves, a verified
   backup is mandatory before acceptance-run preparation or launch. Daddy
   occupied slot 1 versus CJ verified-empty slot 2 and nonzero XWS
   identity/backend health remain required. SA2 acceptance requires exactly
   one current-run `stage=2 event=XNETCONNECT_MANAGER_ARMED` marker from each
   rig and at least one same-side, generation-bound, increasing-sequence chain
   `stage=1
   event=PRECONNECT_XSA1_PREPARED_FOR_GUEST`, `stage=2
   event=XNETCONNECT_MANAGER_ARMED`, then `stage=3
   event=POSTCONNECT_XSA1_RETRANSMIT_CONSUMED_ACK_SENT`. The other side may
   contain stage 2 only, a valid stage-1-to-stage-2 pair, or a valid
   stage-2-to-stage-3 pair; cross-process markers are never stitched into a
   chain. Generic join success is not a substitute. The bounded log watcher
   preserves per-process generation/sequence provenance and refuses aliased
   process, executable, or log identities. The owned-process layer models
   suspended creation, exact ownership, no-focus placement, and retryable
   cleanup, but real launch is hard-blocked by
   `PRODUCTION_LAUNCH_CLOSURE_DEFERRED` and service authority remains blocked by
   `PRODUCTION_SERVICE_AUTHORITY_DEFERRED`. The synthetic seeder likewise
   hard-blocks real path access. External-timeout cleanup remains mandatory.
   None of these source/synthetic results set `PlayerKitReady`, `RuntimeTested`,
   or `LaunchCapable` true.
3. **Frozen-profile assets complete:** sanitized copies of the three custom
   co-op patch definitions are tracked and hash/semantic-asserted, with the
   exact frozen-rig hashes retained in the manifest. The upstream visual patch
   is not bundled; its license and co-op necessity require resolution/ablation.
4. **Read-only hardware planning complete, creation phase pending:**
   `Setup-AOT-Coop.ps1` obtains Windows CPU-set topology, keeps SMT siblings
   together, derives disjoint full-machine masks, and recognizes strict USB and
   BTHLE/XINPUT controller routes. It still must stage fresh rig roots and
   require explicit controller-role selection.
5. Design and test a first-run profile/save path. Do not solve this by shipping
   the existing profiles or checkpoint saves. The source-confirmed manual
   profile flow is documented in `PROFILE_BOOTSTRAP.md`; clean-machine runtime
   acceptance of the role-asymmetric save flow remains pending even though the
   protected driver proved it on the original PC.
6. Complete retained native directory/file identity for seeding, retain the
   executable/game/three-patch launch closure, pin the authoritative local
   service manifest, and wrap the reviewed components with a bounded external
   timeout. Only then enable a production launcher and repeat native join,
   physical-pad gameplay, and death/checkpoint reload acceptance with the
   pinned source-matched executable.
7. Test on at least one clean Windows PC with different CPU/controller/monitor
   hardware before describing the package as portable.
8. **Licensing boundary complete:** project-authored material uses MIT; Xenia's
   BSD and XWS's MIT notices are retained, with explicit experimental and
   non-affiliation language in `PUBLIC_ALPHA.md`.
9. Build releases only from committed trees into a temporary staging folder.
   Generate a manifest and checksums, scan the staged tree for forbidden
   artifacts and personal identifiers, verify it from a fresh extraction, then
   create the ZIP.

## GitHub recommendation

Keep three versioned components:

- orchestration/player setup;
- the Xenia AoT fork;
- the Xenia WebServices AoT fork.

Pin the two companion commit IDs in every orchestration release. Publish source
first as a clearly labeled research/private alpha. Publish a player ZIP only
after the source-matched build and fresh-machine acceptance above. Never build
the public ZIP from the 37+ GB working folder or from uncommitted files.
