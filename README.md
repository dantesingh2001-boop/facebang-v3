# Face Bang v3.0.0

A single-file Roblox client script: an on-the-face bang panel, a working
server-wide freeze, a remote flood, ten attach poses, ESP, and flight that goes
where you point it.

```
loadstring(game:HttpGet("https://raw.githubusercontent.com/dantesingh2001-boop/facebang-v3/main/facebang.lua"))()
```

`getgenv().FaceBang.Unload()` tears everything down.

## Tabs

| Tab | What is in it |
| --- | --- |
| **Aim** | bang, lock, pulse, and the (off by default) effects |
| **Poses** | the ten attach poses, plus a live offset editor |
| **Self** | ghost, fly, speed, jump, ESP, fullbright, click-teleport, music |
| **Players** | per-player actions, freeze, grip |
| **Server** | grip-all, crash (remote flood), status |

---

# Poses — ten features, one core

The reference tool had ten pose/attach features as ten near-identical copies.
Here they share a single movement core, so a fix or a new pose is one place.

`Facebang · Hipbang · Pat · Headsit · Backhug · Fronthug · Propose · Bagpack ·
Goon · Custom`

**How it attaches.** Your rig is **not** welded to them. A weld inherits *their*
network ownership, which is exactly why "I can't move anymore" happens in tools
that do it that way. Instead your own root is driven to a target CFrame every
pass: your body stays yours, theirs is untouched, and releasing is instant.

**Where the frame comes from.** A pose is a facing + distance + height, composed
against their root:

```
behind = theirCFrame * CFrame.new(0, height, +distance)
front  = theirCFrame * CFrame.new(0, height, -distance)
```

so a pose means the same thing whichever way they turn. Distance, height and
facing are **live-steppable in the UI while the pose is active** — you tune it
while watching it, which the original could not do.

**Why PostSimulation.** Same measured reason as the grip below: the client frame
order is `Stepped → PreSimulation → PostSimulation → Heartbeat → RenderStepped`.
A `RenderStepped`-only write lands before the next physics step and loses.

**Honest limit:** nothing is written to the target. Your position is what
replicates, so others see the pose and the target is not moved or frozen.

---

# Grip — the freeze, and why it holds

The victim's `HumanoidRootPart` CFrame is written back to a captured spot every
frame. The first version pinned only on `RenderStepped` and drifted.

| Pinned on | max drift (root pushed at 60 studs/s) |
| --- | --- |
| `RenderStepped` only | **2.51** studs, climbing |
| `PostSimulation` + `Heartbeat` + `RenderStepped` | **0.000** |

An anchored root is unanchored first; a seated target reports "weld wins over
the pin" instead of silently doing nothing.

**Limit:** their own client keeps simulating, so on *their* screen they still
walk. Cost is three writes per held player per frame.

---

# Crash — flooding remotes

The v2.2.0 version spawned thousands of invisible parts. Measured: **client-created
instances do not replicate.**

```
client: FB_ReplProbe exists → true
server: FB_ReplProbe exists → false
```

It loaded your own client and nothing else. Remote calls are the one channel the
server must receive:

| Test | Result |
| --- | --- |
| 231 `FireServer` calls | **231 received** on the server |
| 620 calls × 8 KB, 0.5 s | **all 620 received** (~5 MB/s) |

**Limit:** the server decides what its handlers do — a game that rate limits its
remotes barely notices. No client can force a shutdown.

---

# Fly

| Was | Now |
| --- | --- |
| forward = full camera look vector (Y = **−0.71** looking down) | forward flattened (Y = **0.00**) |
| looking down drove you into the floor | W is horizontal; altitude is Space/Ctrl |
| humanoid fought our velocity | `MoveDirection` zeroed |
| fps-dependent lerp | exponential time-constant easing |

`BodyVelocity`/`BodyGyro`/`BodyPosition` were tested as a physical hold and
drifted **5.07** studs — worse than the CFrame pin, so they are not used.

---

# ESP, fullbright, click-teleport

- **ESP** keeps a reusable pool of `BillboardGui`s, so N players means N labels
  and nothing is created while it is off. Name / distance / box toggles.
- **Fullbright** saves the original `Lighting` properties and restores them
  exactly on off. A utility that leaks state is worse than none.
- **Click-teleport** raycasts from the camera through the cursor and moves you
  above the hit surface.

---

# No VFX by default

`FXStyle = "none"` and `burst()` returns immediately — no parts, sound, label,
shake or highlight. Every effect still works if you switch it on. Fly trail,
superman pose, camera roll and FOV pump are off too.

---

# Backdrop and music

**What Roblox can and cannot do** (measured, not assumed):

| | Supported |
| --- | --- |
| `ImageLabel` with an `rbxassetid` | **yes** |
| `VideoFrame` with an `rbxassetid` | **yes** — only video *you* uploaded and that passed moderation |
| A YouTube URL or embed | **no** — there is no web player in Roblox, and no executor API adds one |
| Streaming that YouTube video's song | **no**, and it is another creator's copyrighted audio |

So the panel **draws its own backdrop**: layered gradients, a drifting violet/cyan
bloom, a fine HUD grid, edge vignette and a sliding accent border. No upload, no
moderation risk, instant load.

Three optional hooks let you use your own uploads:

```lua
Config.BG_ImageId = "rbxassetid://0000000000"  -- still image, blurred + dimmed
Config.BG_VideoId = "rbxassetid://0000000000"  -- your video, looped, muted
Config.MusicId    = "rbxassetid://0000000000"  -- a sound you may use
```

Controls in **Self → music / backdrop**: **mute music**, **pause backdrop video**,
**music volume**. These are real switches over a real `Sound`/`VideoFrame`.

**About "blur":** Roblox has no gaussian blur on plain GuiObjects. What reads as
blurred is three stacked `ImageLabel`s at increasing size and decreasing opacity,
which smears the edges — that is what `Bg` builds, and why the image is scaled
past the panel bounds so no hard clipped edge shows.

Two backgrounds were generated into `assets/`:

```
assets/bg-anime.jpg   anime character, dark left third for text
assets/bg-ground.jpg  abstract dark HUD texture
```

They are **not** usable until you upload them to Roblox (Creator Dashboard →
Create → Decal, or Studio's Asset Manager) and paste the resulting asset id into
`Config.BG_ImageId`. A local file path cannot be displayed by any Roblox UI.

---

# Credits / studied

A 76k-line deobfuscated "Eternity" script was read for techniques. Its real
content is `BodyVelocity`/`BodyGyro`/`BodyPosition` flings and
`FallenPartsDestroyHeight = NaN`; both were measured here and rejected. The rest
is obfuscator debris (~435 dead branches behind random 9-digit constants).
