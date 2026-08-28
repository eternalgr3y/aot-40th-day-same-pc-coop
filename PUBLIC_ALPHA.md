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
The sanitized Xenia WebServices commit is public-ready. The matching public
Xenia AoT commit is still blocked on separating the required title-specific
native layer from private diagnostic history, so this snapshot is not yet a
self-contained reproduction. The full private research archive, raw captures,
runtime rigs, and reverse-engineering databases are intentionally not
published.

## Remaining portability boundary

The clean source-built Xenia candidate passes its application, CPU, and HID
test suites, but its newly built executable has not yet repeated the complete
physical-controller gameplay/death-reload acceptance. Until that run and a
clean-machine trial are complete, do not describe this source alpha as a
portable player release.

See `PACKAGING.md`, `PROFILE_BOOTSTRAP.md`, and `ALPHA_MANIFEST.md` for the
exact prerequisites and evidence grades.

## Novelty statement

As of 2026-08-28, searches of public GitHub code/repositories found no other
published reproducible implementation of this same-PC dual-Xenia retail path.
Community posts do contain anecdotal claims that Xenia co-op is possible, so
this project does **not** claim a definitive world first. Its narrower claim is
that it publishes a documented, tested implementation and its failure
boundaries rather than an unsupported anecdote.

## Legal and affiliation notice

This is an independent interoperability and preservation project. It is not
affiliated with or endorsed by Electronic Arts, Microsoft, the Xenia project,
or the Xenia Canary maintainers. **Army of Two** and related marks and game
content belong to their respective owners. The project-authored source is MIT
licensed; third-party components retain their own licenses as recorded in
`THIRD_PARTY_NOTICES.md`.
