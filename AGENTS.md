# Project Overview
**Fish Game Tycoon** is a Roblox aquarium-building tycoon written in Luau. Each player is assigned a plot and builds an aquarium on a grid — placing content assets, walls, stairs, ceilings, and flooring — collects fish, and grows their tycoon.

- **Single place.** Every player builds on their own plot in the shared world; there is no matchmaking teleport.
- **Grid building system** is the current major system. Everything is built on a 4×4×4-stud grid; the design principle is *data is authoritative, Instances are just a render of it*.

Development is done against the **filesystem** (per the global Roblox rule — use filesystem tools, not an MCP, for reading/writing Luau). Code lives at the repo root in folders mirroring the Roblox DataModel.

# Communication
- **Ask questions. Never guess.** Whenever something is ambiguous, contradictory, underspecified, or you're filling a gap with an assumption — stop and ask. The outcome is always better when we confirm we're on the same page first.
- **Pitch better ideas as questions.** If you think there's a stronger approach than what was asked, raise it: *"How about we do X instead, because Y?"* Don't silently substitute your own plan, and don't silently follow a worse one.
- **Surface conflicts early.** If a request contradicts an existing system or a previous decision, flag it rather than papering over it.
- **Report honestly.** If something is untested, skipped, or failing, say so plainly with the details. Don't claim done what isn't verified. (Roblox code generally can't be run from the agent side — say when something needs a Studio playtest.)

# Architecture

## File structure
Code lives at the repo root, mirroring the Roblox hierarchy:
- `ReplicatedStorage/` — shared client+server code (`Classes/`, `Config/`, `Services/`, `Frameworks/`, `Modules/`)
- `ServerStorage/` — server-only code (`Services/`, `Classes/`)
- `ServerScriptService/Init.legacy.luau` — server bootstrapper
- `StarterPlayer/StarterPlayerScripts/Init.local.luau` — client bootstrapper

Note: config is `ReplicatedStorage/Config/` (singular), e.g. `Config/ProfileTemplate.luau`, `Config/Building.luau`, `Config/Materials.luau`, `Config/Items/`.

## Service discovery (folder-based auto-require)
Services are auto-required by **placement**, not by tags. The Init scripts do the requiring:
- **Server-only service** → `ServerStorage/Services/` (server bootstrap requires all of them).
- **Shared service** → `ReplicatedStorage/Services/` with **`Shared` in the name** (e.g. `SharedFishInventoryService`) — required by *both* sides. When a shared service exists, have the Client and Server versions inherit from it (`setmetatable({}, {__index = Shared})`) to minimize cross-requiring.
- **Client-only service** → `ReplicatedStorage/Services/` **without** `Shared` in the name (the client bootstrap requires *all* of `ReplicatedStorage/Services/`; the server bootstrap only requires the `Shared`-named ones). Guard the top of a client-only service with `if not RunService:IsClient() then return end`.

Put a new service in the right folder and it loads automatically. **Do not edit the Init files** to force code to run.

## Client / server model
Standard Roblox client-server — there is **no** server-authority movement/prediction system, no `InputAction`/`BindToSimulation`, and `StreamingEnabled` is not mandated. Clients read input normally and send **requests** over remotes; the **server owns and validates** everything persistent: currency, purchases, inventory, and all build placements. Never trust a client-reported price, purchase, or placement — validate on the server (e.g. `ServerBuildingService` re-runs the same `SharedBuildingService` validation the client predicted with).

## Data & replication
- `DataSaveService` (`ReplicatedStorage/Services`, wraps `ProfileStore`) owns persistent player profiles. Extend the profile via its schema in `Config/ProfileTemplate.luau` — don't invent parallel save systems.
- Persistent data is a reactive `Table`; mutating it auto-replicates to the client via `ReplicationService`. **Do not fire your own "here's the player's data" remotes** — read the replicated profile on the client (`DataSaveService:GetProfile()` / `WaitForProfile`).

## Remotes
All `RemoteEvent`s and `RemoteFunction`s live under **`ReplicatedStorage/Communication/<System>/`**, where `<System>` names what they're for (e.g. `Communication/Building`). Reference them via `WaitForChild`; **never create them programmatically** and never scatter them next to a script. (Exception: preset data/replication services that encapsulate their own remotes internally.)

## Studio-authored instances
Instances that live in the Studio hierarchy — GUIs, map/plot parts, spawn locations, `CollectionService` tags, and remotes — are **authored by the user in Studio, not created at runtime.** These instance-only objects are **not visible on the filesystem**. When a change needs one, tell the user the exact **path, instance type, and name** to create (for remotes, the `Communication/<System>` path above), and which **tag** to apply. The user handles it. (Example: plots live at `workspace.Plots`, numbered `1..x`, each with a `Plot` part and a `SpawnLocation`.)

# Naming & Casing
- **Instances** (ModuleScripts, files, GUIs, parts, folders) and **classes** → `PascalCase`.
- **Global / module-level variables** (outside any function) → `PascalCase`.
- **Local / scoped variables** (inside functions) → `camelCase`.
- **Constants** (fixed values) → `LOUD_SNAKE_CASE`.
- **Table entries / keys** → `PascalCase`.
- **Functions:** public API and service/module methods → `PascalCase`; local/helper functions → `camelCase`.
- **Private/internal class fields** → leading underscore + `camelCase` (e.g. `self._grid`).
- **Acronyms** are treated as a normal word (Roblox-style): `UserId`, `ObjectId`, `maxHp`, `PlotUi` — not `objectID` / `maxHP`.

```lua
local MAX_HEIGHT_LEVEL = 4              -- constant
local Building = require(...)           -- module-level → PascalCase

local function computeCellCoords(entry) -- local helper → camelCase
    local footprint = entry.Footprint   -- scoped var → camelCase; table key → PascalCase
    return footprint
end

function ServerPlotService:AssignPlot(player, plot)  -- public method → PascalCase
    self._plots[plot] = player                        -- private field → _camelCase
end
```

# Code Patterns

**OOP classes** use `.new()` constructors with `__index` metamethods.

**Classes are typically tied to `Instances`** and have an associated **Service** that creates/manages them (e.g. a `Plot` class + `ServerPlotService`, or a `Grid` class owned by a `Plot`). `TagService` is available for binding behavior to tagged Instances. Classes can also be used without Instances; use judgment on when a class is warranted.

**Services** expose their external API with **colon methods** (`Service:DoThing()`). When client and server both need a service, follow the `ClientSomethingService` / `ServerSomethingService` / `SharedSomethingService` naming, and have Client/Server inherit from Shared.

**Server-validated logic.** All currency, purchases, inventory changes, and build placements are validated on the server — never trust a client-reported price, purchase, or action. Prefer sharing the validation *rules* in a `Shared` service so the client can predict and the server can enforce with identical code.

**Configuration is data-driven.** Add fish, materials, placeables, or tuning by editing config (`ReplicatedStorage/Config/`), not logic files. No balance numbers hardcoded in systems (e.g. grid/height constants live in `Config/Building.luau`).

**Signal class** (`ReplicatedStorage/Classes/Signal.luau`) wraps `BindableEvent` — use it for typed cross-system events instead of raw BindableEvents.

**Reuse the preset modules** rather than reinventing them: `TagService` (behavior binding), `Zone` (region detection), `xenterface` / `xenimation` (UI), `FormatNumber` (number display), `extend` and the reactive `Table` class. Check `ReplicatedStorage/Classes`, `Frameworks`, and `Modules` before writing something new.

**Treat user-stated hierarchy facts as contracts.** If the user says an Instance, service, child, remote, GUI element, tag, or config value exists, write code as though it exists unless they phrase it as uncertain. Avoid over-defensive `FindFirstChild`/`IsA`/nil-check branches, warning spam, and runtime-created stand-ins for Studio-authored instances. Use `WaitForChild` only for expected replication boundaries, then access the stated children directly.

**Keep code short and concise.** Fewest lines that maintain quality. Files should rarely exceed a few hundred lines and must stay organized internally so functions are easy to find. If a file is getting long, split it logically.

**Place code in logical places.** Put code where it belongs; if no existing file fits, make a new one.

**Client and Server scripts are only for initializing services.** Don't use them for game logic unless the user explicitly asks.
