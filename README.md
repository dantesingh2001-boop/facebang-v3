# Face Bang v2.3.0 — grip, crash, cleaner flight

A single-file Roblox client script: an on-the-face bang panel, a working
server-wide freeze, a server flood, and flight that goes where you point it.

```
loadstring(game:HttpGet("https://raw.githubusercontent.com/dantesingh2001-boop/facebang-v3/main/facebang.lua"))()
```

`getgenv().FaceBang.Unload()` tears everything down.

## No VFX by default

`FXStyle` defaults to `"none"` and `burst()` returns immediately, so a bang is a
position change and nothing else — no parts, no sound, no label, no camera kick,
no highlight. Every effect still exists and still works: switch one on in the
Aim tab if you want it. The fly trail/thrusters/aura and the superman pose are
off by default too, along with the camera roll and FOV pump.

## Grip — the freeze, and why it now holds

The victim's `HumanoidRootPart` CFrame is written back onto a captured spot
every frame. The first version only pinned on `RenderStepped` and drifted —
measured at 2.5 studs and climbing against a root pushed at 60 studs/s.

The cause is frame order, measured in Studio:

```
Stepped -> PreSimulation -> PostSimulation -> Heartbeat -> RenderStepped
```

`RenderStepped` is **last**, so its write lands *before* the next frame's
physics step and loses. Pinning on **PostSimulation + Heartbeat +
RenderStepped** means our value is the last one the frame sees: the same test
then measured **maxDrift 0.000**.

| API | Does |
| --- | --- |
| `Grip.hold(plr)` | freeze one player where they stand |
| `Grip.release(plr)` / `Grip.stop()` | let go |
| `Grip.holdAll(radius)` | freeze everyone alive, optionally within a radius |
| `Grip.count()` | how many are held |

Config: `GripRate` (writes every Nth pass), `GripRadius`, `GripMaxPlayers`.

**Limits.** Their own client keeps simulating, so on *their* screen they still
walk. An anchored root is unanchored first; a seated target reports
"weld wins over the pin" rather than pretending to work. Cost is three writes
per held player per frame, which is what the player cap is for.

## Crash — flooding remotes, which is the only thing that reaches the server

The v2.2.0 version spawned thousands of invisible parts in Workspace. That was
measured to be **useless**: client-created instances **do not replicate**.

```
client: FB_ReplProbe exists  ->  true
server: FB_ReplProbe exists  ->  false
```

It loaded your own client and nothing else.

Remote calls are the one channel the server is forced to receive:

| Test | Result |
| --- | --- |
| 231 `FireServer` calls | **231 received** on the server |
| 620 calls × 8 KB payload, 0.5 s | **all 620 received** (~5 MB/s of handler work) |

So `Crash` now floods every `RemoteEvent` / `UnreliableRemoteEvent` it can find
in `ReplicatedStorage`, `ReplicatedFirst` and `Workspace`, with a configurable
rate and payload size. Status reports fires/s.

**Limits.** The server decides what its handlers do — a game that rate limits or
debounces its remotes barely notices. No client can force a shutdown; it can
only saturate the receive queue. Your own client pays the serialisation cost
first, which is what the rate steps are for.

## Fly

| Was | Now |
| --- | --- |
| forward = full camera look vector (Y = **-0.71** looking down) | forward flattened (Y = **0.00**) |
| looking down drove you into the floor on W | W is always horizontal; altitude is Space/Ctrl/E/Q |
| humanoid still applied its own controller forces | `MoveDirection` zeroed so only our velocity acts |
| fixed per-frame lerp, fps-dependent | exponential time-constant easing |

`bodyVelocity`, `bodyGyro`, `BodyPosition` were also tested as a physical hold:
they drifted **5.07 studs**, worse than the CFrame pin, so they are not used.

## Credits / studied

A 76k-line deobfuscated "Eternity" script was read for techniques. Its real
content is `BodyVelocity`/`BodyGyro`/`BodyPosition` flings and
`FallenPartsDestroyHeight = NaN`; both were measured here and rejected — the
constraint hold is weaker than the pin, and the NaN write stays client-local
(the server still read `-500`). The rest of that file is obfuscator debris
(~435 dead branches guarded by random 9-digit constants).
