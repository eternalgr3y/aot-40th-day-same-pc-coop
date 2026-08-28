# B19 same-PC physical-pad acceptance and death/reload validation

Date: 2026-08-26 (America/New_York)

Classification: **backend-assisted retail/native same-PC co-op, working
private-alpha pass for the tested scope**.

Correction: the first version of this report carried the earlier
wrong-possession death failure forward after a later test had already
succeeded. The chronology below is authoritative.

This run used two Xenia instances on one Windows PC, one wired controller and
one Bluetooth controller, the existing middle checkpoint save, the local FESL
shim, and Xenia WebServices. It did not use the old single-player hotjoin,
forced listen, hero-sync, or scripted-input fallback paths.

## Confirmed

- Daddy created the sole advertised session and remained the host.
- CJ joined that session with `HOSTbit=false`.
- Native HELLO/CCON markers completed on the expected sides.
- Bidirectional UDP transport remained error-free through controlled cleanup.
- Both clients rendered the same room from distinct player views.
- Both runtime copies used B19 SHA-256
  `B19F51D4D6C3730C6D7D998B4A0D75C0A5A2D911260829C47C6728E3AD464B06`.

These facts prove a real shared session and shared scene. They do not prove
that every campaign lifecycle transition is correct.

## Death/reload chronology

An earlier level-one session produced `Waiting for other player`, loss of
control, and possession of the wrong character on CJ's rig after a player
death. The recorded death/restart probe rows came from initial checkpoint
startup and did not instrument that event.

The rigs were then restarted and rejoined from the reached checkpoint with the
current B19 profile. In that later session the user performed another co-op
death test, reported that the reload completed correctly, and resumed play.
That successful result supersedes the earlier failure for the tested flow.
Classification is therefore **user-validated PASS for one death/checkpoint
reload cycle**. The exact owner/controller/pawn transition was not captured by
the bounded probe, and repeated-cycle coverage has not been claimed.

A future public-quality repeat can re-arm a one-shot capture immediately
before several controlled deaths and record owner/controller/pawn identity,
wait entry and exit, `RestartPlayer` return, and final possession. The hot
`[AOT-P103-POST]` stream must remain sampled rather than flooding the log.

## Frozen local evidence

The raw evidence is intentionally excluded from Git and remains at:

```text
_runs/b19_physical_play_20260826T174650/
```

Key SHA-256 values:

- Daddy log: `4B33A2BB3D196A1C8D99B2C71876E950EB2C7C0CE4D503E84FF96FA300B88341`
- CJ log: `47B3EBCEEA33229E519D549F22225EEA33FEFAB05161999049B2AA9841F9B684`
- Daddy screenshot: `150EF7CFC3532E843633AEB0386266E2280D0D8ADB277DBF27BDEB6DC59D1D0F`
- CJ screenshot: `C5C4401A4E9C5856F21B1368342154643B9B74CA8853178195F10E93767E6FD8`
- FESL log: `1BAB0A3C5583104A0515EDAE170BB823ED298D1414A417BE08049C0A38E12CFE`
- XWS stdout: `DA14E1015549620946733D232A5BC5CBDCB8CF5A234727165E02EDF9FBBF0375`

Save/profile preservation was verified before and after the run:

- pre-run manifest SHA-256:
  `971E7E93B7EE8F1B66DAFB93993DD4E5B60C70CB0B438AA38D5450D77BCEB8B5`
- post-run manifest SHA-256:
  `FF20B6BB1DB40CF320750E46E89A28399AA6EE51258FA5124A58ECD2BFE54CC7`
- each backup contains and verifies all 14 expected files.

The two Xenia processes exited through normal window close. Only the
pre-existing loopback MongoDB service was preserved after cleanup.
