# Face Bang v2.2.0 — grip & crash build

A single-file Roblox client script: an on-the-face bang panel, plus server-wide
freeze ("grip") and server overload ("crash") rows.

```
loadstring(game:HttpGet("https://raw.githubusercontent.com/dantesingh2001-boop/facebang-v3/main/facebang.lua"))()
```

`getgenv().FaceBang.Unload()` tears everything down, including any grip or crash
load currently running.

## What's in it

Everything from v2.1.4 — the zero-delay bang shuttle, the nova/shockwave/glitch/
flame burst, ghost, god mode, fly, noclip, teleport, spectate, follow — plus two
new modules.

### Grip — server-wide freeze (`lib` section of the file)

`Targets.freeze` was a local-view freeze that expired after 8 seconds and gave
up the moment the target moved. The grip is the classic version: it writes the
victim's `HumanoidRootPart.CFrame` back onto a captured spot on every frame
pass, and zeroes their assembly velocity, so they are held for the whole
server instead of just your screen.

| API | Does |
| --- | --- |
| `Grip.hold(plr)` | freeze one player where they stand |
| `Grip.release(plr)` / `Grip.stop()` | let go |
| `Grip.holdAll(radius)` | freeze everyone alive, optionally within a radius |
| `Grip.count()` | how many are held |

Config: `GripRate` (1 = every pass, 3 = every third pass), `GripRadius`,
`GripMaxPlayers` (default 15).

**Honest limits.** Their own client keeps simulating, so on *their* screen they
still walk; what is held is what they replicate and what you render. It is a
position hold, not invincibility and not a humanoid lock. Cost is one CFrame
write per gripped player per pass, which is why the cap exists — a 40-player
grip at every pass is where a normal client starts to stutter.

### Crash — overload a server

A client cannot restart a server. What it can do is hand the server more to
replicate than it can drain: invisible, anchored, `CanQuery`/`CanTouch` off
parts batched into one `FB_Load` folder in Workspace, per frame.

| Level | Parts/s | Effect |
| --- | --- | --- |
| `light` | ~240 | ping spikes, recovers when you stop |
| `heavy` | ~2000 | everything in the server is late |
| `meltdown` | ~72k | the version that actually takes a server down |

Modes: `hold` piles up, `sputter` creates and destroys in the same pass (more
work for the queue, less memory). `stop()` always deletes the folder in both
modes.

**Honest limits.** Memory climbs on every client, yours included — if it runs
long enough your client runs out first and you get kicked. `meltdown` + `hold`
is the combination that takes the server down *and* the one most likely to take
you with it. Unbounded part spawning is also the fastest way to trip a game's
anti-cheat if it watches part creation.

## UI

Two new sections at the top of the **Server** tab (`grip`, `crash`), plus
`GRIP selected` / `release selected grip` on the **Players** tab.

Keys are unchanged: `[B]` bang nearest, `[L]` loop, `[X]` stop,
`[RightShift]` show/hide.

## Notes

This repo is a single-file release. It is not the source split of
[facebang-v2](https://github.com/dantesingh2001-boop/facebang-v2) — that tree
builds its deliverable from `src/` + `lib/` via `build.sh`, and these modules
were added against the built artifact.
