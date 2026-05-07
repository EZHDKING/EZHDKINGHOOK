# EZHDKINGHOOK

[![Watch the showcase](https://img.youtube.com/vi/YJizq8c0m5w/maxresdefault.jpg)](https://www.youtube.com/watch?v=YJizq8c0m5w)

DISCORD FOR SUPPORT:
https://discord.gg/YcjNabYgTW



A no-LLDB Frida launcher for locally testing osu! lazer difficulty values on Linux.

> **Platform status:** this project has **only been tested on Ubuntu 24.04 x86_64 with the osu! lazer AppImage**. Other platforms are not currently supported by this launcher, although ports may be possible.

The script starts from a live osu! process, resolves current JIT method addresses from `.NET` perf maps, generates a temporary Frida agent, and exposes runtime commands such as `setdiff()`, `getdiff()`, `selftest()`, and `getlayout()`.

> **Intended use:** local development, debugging, research, replay/sandbox testing, or offline experimentation.
>
> **Do not use this to misrepresent gameplay state, bypass score validation, or submit scores under conditions that do not match what was actually played.**
>
> **Independence notice:** this project is **not associated with, based on, affiliated with, endorsed by, or compatible with the “Freedom” cheat/difficulty changer** or any other osu! cheat project. It is a separate local-development Frida experiment.

---

## Table of contents

- [What this does](#what-this-does)
- [What this does not do](#what-this-does-not-do)
- [How it works](#how-it-works)
- [Platform support](#platform-support)
- [Project independence](#project-independence)
- [Requirements](#requirements)
- [Installation](#installation)
- [Starting osu with the required environment](#starting-osu-with-the-required-environment)
- [Running the script](#running-the-script)
- [Basic usage](#basic-usage)
- [Commands](#commands)
- [Environment variables](#environment-variables)
- [Expected output](#expected-output)
- [Troubleshooting](#troubleshooting)
- [Update resilience](#update-resilience)
- [Porting guide](#porting-guide)
- [Safety model](#safety-model)
- [Project layout](#project-layout)
- [Development notes](#development-notes)
- [FAQ](#faq)

---

## What this does

`run3_autoupdate.sh` attaches Frida to a running osu! lazer process and patches the live `BeatmapDifficulty` object used during beatmap preprocessing.

It can force:

- `OD` / Overall Difficulty
- `HP` / Drain Rate
- `AR` / Approach Rate
- `CS` / Circle Size

The exposed Frida command is:

```js
setdiff(od, hp, ar, cs)
```

Example:

```js
setdiff(8, 5, 9.5, 4)
```

This sets:

```text
OD = 8
HP = 5
AR = 9.5
CS = 4
```

---

## What this does not do

This script does **not**:

- modify the osu! executable on disk
- require LLDB
- require SOS
- persist changes after osu! exits
- patch score submission logic
- force hidden/mirror/classic mods
- make online/ranked play safe or supported
- guarantee compatibility with every future osu! update

It is a runtime Frida patcher for local testing.

---

## How it works

The launcher does four main things.

### 1. Finds the real osu! CoreCLR process

AppImage launches can create wrapper processes, so the script does not simply attach to the newest `osu.AppImage` process.

Instead, it searches for a process named `osu!` that has `libcoreclr.so` mapped:

```bash
pgrep -x 'osu!'
grep -qi 'libcoreclr.so' /proc/<pid>/maps
```

If no CoreCLR process is found, the script exits with:

```text
[error] Could not find osu! CoreCLR process.
```

### 2. Reads the .NET perf map

When osu! is started with perf-map emission enabled, .NET writes JIT symbols to:

```text
/tmp/perf-<pid>.map
```

The script reads that file and searches for JITted `BeatmapProcessor::PreProcess(...)` entries.

This avoids LLDB entirely.

### 3. Generates a Frida agent

The script writes a generated JavaScript agent to:

```text
force-difficulty-autoupdate.generated.js
```

That generated agent contains the fresh JIT addresses resolved from the current osu! process.

### 4. Attaches Frida

Finally, the script runs:

```bash
frida -p "$PID" -l "$OUT_JS"
```

Inside the Frida prompt, you can call runtime commands such as:

```js
setdiff(8, 5, 9.5, 4)
getdiff()
selftest()
```

---

## Platform support

### Current status

This project is currently **Linux-only as implemented** and has **only been tested on Ubuntu 24.04 x86_64 with the osu! lazer AppImage**.

| Platform | Status | Notes |
| --- | --- | --- |
| Ubuntu 24.04 x86_64 | Tested | Primary and only confirmed environment. |
| Other desktop Linux distributions | Untested / possible | May work if AppImage, Frida, `/proc`, and .NET perf maps behave similarly. |
| Steam Deck / SteamOS | Untested / likely portable | SteamOS is Linux-based, so this is the most realistic non-Ubuntu target, but paths, permissions, Flatpak/AppImage behavior, and read-only filesystem details may need changes. |
| Windows | Not supported by this script | Requires a different process/module/JIT-symbol resolver. |
| macOS | Not supported by this script | Requires a different process/module/JIT-symbol resolver. |
| Android | Not supported by this script / theoretical | Would require a mobile-specific Frida Gadget or frida-server workflow and a compatible osu! build/runtime target. |
| iOS | Not supported by this script / theoretical | Would require a mobile-specific Frida Gadget workflow, app repackaging or jailbreak-style instrumentation, and a compatible osu! build/runtime target. |

### Why the current script is Linux-only

The current launcher depends on Linux-specific behavior:

- `/proc/<pid>/maps` for process/module inspection
- `libcoreclr.so` to identify the actual .NET/CoreCLR osu! process
- `/tmp/perf-<pid>.map` for JIT method address discovery
- Bash, `awk`, `grep`, `sed`, `pgrep`, and other Unix command-line tools
- the osu! lazer AppImage launch model

The Frida JavaScript agent is more portable than the shell launcher, but the **resolver layer** is not portable yet.

---

## Project independence

This project is **not associated with the Freedom cheat/difficulty changer**.

It is also not:

- a fork of Freedom
- based on Freedom source code
- compatible with Freedom configs/modules
- affiliated with any Freedom developers
- endorsed by osu!, ppy, Freedom, or any other cheat/tool project

This repository should be described as an independent local-development Frida experiment for studying osu! lazer runtime difficulty objects.

If you publish this project, avoid names, descriptions, screenshots, or tags that imply it is part of Freedom or any other existing cheat/difficulty changer.


## Requirements

### Operating system

Tested target environment:

```text
Ubuntu 24.04
x86_64
osu! lazer AppImage
```

Other Linux distributions may work if they run the AppImage and support Frida.

### Packages

You need:

- `bash`
- `awk`
- `grep`
- `pgrep`
- `sed`
- `frida-tools`
- a running osu! lazer AppImage
- .NET runtime used by osu! lazer

Install Frida tools:

```bash
python3 -m pip install --user frida-tools
```

Check Frida:

```bash
frida --version
frida-ps
```

If `frida` is not found, add your local Python scripts path:

```bash
export PATH="$PATH:$HOME/.local/bin"
```

---

## Installation

Put the script somewhere convenient, for example:

```bash
mkdir -p ~/Downloads/fridalazer
cd ~/Downloads/fridalazer
```

Copy the file:

```bash
cp /path/to/run3_autoupdate.sh ./run3_autoupdate.sh
chmod +x ./run3_autoupdate.sh
```

Recommended directory:

```text
~/Downloads/fridalazer/
├── run3_autoupdate.sh
└── force-difficulty-autoupdate.generated.js   # generated at runtime
```

---

## Starting osu with the required environment

The script requires .NET perf maps. Start osu! with these variables:

```bash
cd ~/Downloads/cosu

export DOTNET_PerfMapEnabled=3
export COMPlus_PerfMapEnabled=3

export DOTNET_TieredCompilation=0
export COMPlus_TieredCompilation=0

export DOTNET_ReadyToRun=0
export COMPlus_ReadyToRun=0

export COMPlus_TC_QuickJitForLoops=0

./osu.AppImage
```

Wait until osu! reaches the main menu or song select.

Then switch/load a beatmap once so the preprocessing method gets JITted.

---

## Running the script

In another terminal:

```bash
cd ~/Downloads/fridalazer
./run3_autoupdate.sh
```

Expected startup flow:

```text
[info] osu CoreCLR PID: 123456
[info] Runtime module:
...
[info] Using perf map: /tmp/perf-123456.map
[info] Waiting up to 30s for BeatmapProcessor::PreProcess JIT symbols...
[fresh] PreProcess candidates:
[fresh]   0x...|instance void [osu.Game] osu.Game.Beatmaps.BeatmapProcessor::PreProcess()
[info] Generated force-difficulty-autoupdate.generated.js
[info] Starting Frida...
```

When Frida attaches, you should see:

```text
[loaded] Auto-updating no-LLDB perf-map PreProcess difficulty agent
[hooks] count=...
[default target] OD=8 HP=5 AR=9.5 CS=4
[usage] setdiff(8, 5, 9.5, 4)
```

---

## Basic usage

At the Frida prompt:

```js
setdiff(8, 5, 9.5, 4)
```

Check current target values:

```js
getdiff()
```

Run a self-test:

```js
selftest()
```

Switch or load a map. When preprocessing runs, you should see logs like:

```text
[layout] discovered source=known-current confidence=...
[debug] ... processorOffset=0x... beatmapDifficultyOffset=0x...
[BeatmapProcessor.PreProcess] #1 obj=0x... before OD=... HP=... AR=... CS=... => target OD=8 HP=5 AR=9.5 CS=4
```

---

## Commands

### `setdiff(od, hp, ar, cs)`

Sets the target difficulty values.

```js
setdiff(8, 5, 9.5, 4)
```

Parameter order:

```text
OD, HP, AR, CS
```

Values are clamped according to the active bounds.

Default bounds:

```text
OD: 0.0 - 10.0
HP: 0.0 - 10.0
AR: 0.0 - 10.0
CS: 0.1 - 10.0
```

CS defaults to a minimum of `0.1` to avoid zero-size edge cases.

---

### `getdiff()`

Prints:

- current target values
- patch statistics
- learned object offsets
- current layout
- current bounds

```js
getdiff()
```

Example output:

```text
[current target] OD=8 HP=5 AR=9.5 CS=4
[stats] patches=3 skipped=10 scanFails=0 discoveryFails=0 cached=3 version=2
[learned] processorOffset=24 beatmapOffset=40
[layout] source=known-current confidence=...
```

---

### `selftest()`

Prints hook and patch status.

```js
selftest()
```

Possible outcomes:

```text
[selftest] OK: patching has succeeded at least once.
```

or:

```text
[selftest] Waiting: no PreProcess call observed yet. Switch/load a beatmap.
```

or:

```text
[selftest] WARNING: hooks are firing but no patches succeeded. Likely outdated object path/layout.
```

---

### `getlayout()`

Prints the currently discovered `BeatmapDifficulty` field layout.

```js
getlayout()
```

Example:

```text
[layout] source=known-current confidence=45 SM=0x18 STR=0x20 HP=0x28 CS=0x2c OD=0x30 AR=0x34
```

Fields:

| Field | Meaning |
| --- | --- |
| `SM` | Slider multiplier |
| `STR` | Slider tick rate |
| `HP` | Drain rate |
| `CS` | Circle size |
| `OD` | Overall difficulty |
| `AR` | Approach rate |

---

### `resetPatchCache()`

Clears runtime patch caches and counters.

```js
resetPatchCache()
```

Use this after switching between many maps or after changing settings manually.

---

### `resetAutoDiscovery()`

Clears the discovered layout and forces the agent to rediscover the object layout on the next preprocessing call.

```js
resetAutoDiscovery()
```

Use this after an osu! update or if `getlayout()` looks suspicious.

---

### `setautodiscovery(true | false)`

Enables or disables automatic layout discovery.

```js
setautodiscovery(true)
```

Disable discovery and use fallback offsets:

```js
setautodiscovery(false)
```

Fallback offsets are:

```text
SliderMultiplier: 0x18
SliderTickRate:  0x20
HP:              0x28
CS:              0x2c
OD:              0x30
AR:              0x34
```

---

### `allowZeroCS(true | false)`

By default, CS is clamped to at least `0.1`.

Allow literal `CS = 0`:

```js
allowZeroCS(true)
setdiff(0, 0, 0, 0)
```

Return to safer behavior:

```js
allowZeroCS(false)
```

Recommended default:

```js
allowZeroCS(false)
```

---

### `setbounds(odMin, odMax, hpMin, hpMax, arMin, arMax, csMin, csMax)`

Overrides numeric bounds.

Example:

```js
setbounds(0, 12, 0, 12, 0, 12, 0.1, 12)
```

Parameter order:

```text
OD min, OD max,
HP min, HP max,
AR min, AR max,
CS min, CS max
```

Use carefully. Wider ranges may increase crash risk.

---

### `enableDiffPatch()`

Enables patching.

```js
enableDiffPatch()
```

---

### `disableDiffPatch()`

Disables patching without detaching Frida.

```js
disableDiffPatch()
```

Useful when switching maps or debugging.

---

## Environment variables

### Script variables

Set these before running `run3_autoupdate.sh`.

#### `OUT_JS`

Generated Frida agent path.

Default:

```bash
force-difficulty-autoupdate.generated.js
```

Example:

```bash
OUT_JS=/tmp/osu-agent.js ./run3_autoupdate.sh
```

#### `WAIT_SECONDS`

How long to wait for `BeatmapProcessor::PreProcess` to appear in the perf map.

Default:

```bash
30
```

Example:

```bash
WAIT_SECONDS=60 ./run3_autoupdate.sh
```

#### `OSU_FORCE_OD`

Default target OD.

```bash
OSU_FORCE_OD=8 ./run3_autoupdate.sh
```

#### `OSU_FORCE_HP`

Default target HP.

```bash
OSU_FORCE_HP=5 ./run3_autoupdate.sh
```

#### `OSU_FORCE_AR`

Default target AR.

```bash
OSU_FORCE_AR=9.5 ./run3_autoupdate.sh
```

#### `OSU_FORCE_CS`

Default target CS.

```bash
OSU_FORCE_CS=4 ./run3_autoupdate.sh
```

Full example:

```bash
OSU_FORCE_OD=8 \
OSU_FORCE_HP=5 \
OSU_FORCE_AR=9.5 \
OSU_FORCE_CS=4 \
WAIT_SECONDS=60 \
./run3_autoupdate.sh
```

---

## Expected output

### Successful startup

```text
[info] osu CoreCLR PID: 123456
[info] Runtime module:
7f... /tmp/.mount_osu.../usr/bin/libcoreclr.so
[info] Using perf map: /tmp/perf-123456.map
[info] Waiting up to 30s for BeatmapProcessor::PreProcess JIT symbols...
[fresh] PreProcess candidates:
[fresh]   0x7f...|instance void [osu.Game] osu.Game.Beatmaps.BeatmapProcessor::PreProcess()
[info] Generated force-difficulty-autoupdate.generated.js
[info] Starting Frida...
```

### Successful Frida load

```text
[loaded] Auto-updating no-LLDB perf-map PreProcess difficulty agent
[hooks] count=1
[default target] OD=8 HP=5 AR=9.5 CS=4
```

### Successful patch

```text
[layout] discovered source=known-current confidence=45 ...
[BeatmapProcessor.PreProcess] #1 obj=0x... before OD=9.00 HP=4.00 AR=9.60 CS=4.20 => target OD=8 HP=5 AR=9.5 CS=4
```

---

## Troubleshooting

### `Could not find osu! CoreCLR process`

Error:

```text
[error] Could not find osu! CoreCLR process.
```

Fix:

1. Start osu!.
2. Wait until it is fully loaded.
3. Check process list:

```bash
pgrep -a 'osu!'
```

The script needs the process that maps `libcoreclr.so`.

---

### `/tmp/perf-<pid>.map does not exist`

Error:

```text
[error] /tmp/perf-123456.map does not exist.
```

Cause:

osu! was not started with perf-map emission enabled.

Fix: restart osu! with:

```bash
export DOTNET_PerfMapEnabled=3
export COMPlus_PerfMapEnabled=3
```

Full startup command:

```bash
cd ~/Downloads/cosu

export DOTNET_PerfMapEnabled=3
export COMPlus_PerfMapEnabled=3
export DOTNET_TieredCompilation=0
export COMPlus_TieredCompilation=0
export DOTNET_ReadyToRun=0
export COMPlus_ReadyToRun=0
export COMPlus_TC_QuickJitForLoops=0

./osu.AppImage
```

---

### `No BeatmapProcessor::PreProcess JIT symbol found`

Error:

```text
[error] No BeatmapProcessor::PreProcess JIT symbol found in /tmp/perf-123456.map.
```

Cause:

The method has not been JITted yet.

Fix:

1. Go to song select.
2. Switch maps or open a beatmap once.
3. Rerun the script.

Debug command:

```bash
grep -i 'PreProcess' /tmp/perf-$(pgrep -n -x 'osu!').map | tail -30
```

You want to see something like:

```text
0x... instance void [osu.Game] osu.Game.Beatmaps.BeatmapProcessor::PreProcess()[Optimized]
```

---

### Frida cannot attach

Check Frida:

```bash
frida --version
frida-ps
```

If permission is denied, check ptrace scope:

```bash
cat /proc/sys/kernel/yama/ptrace_scope
```

Temporary fix:

```bash
sudo sysctl kernel.yama.ptrace_scope=0
```

Permanent configuration depends on your Linux distribution and security requirements.

---

### `layout not discovered yet`

Run:

```js
selftest()
```

Then switch/load a beatmap. The layout is only discovered after the hook sees a live preprocessing call.

If it still fails:

```js
resetAutoDiscovery()
selftest()
```

---

### `[outdated?] Could not find BeatmapDifficulty`

This means the hook fired, but the agent could not find a plausible difficulty object.

Try:

```js
selftest()
getlayout()
resetAutoDiscovery()
```

If it continues after an osu! update, the internal object path probably changed.

---

### Crash after setting extreme values

Start with sane values:

```js
setdiff(8, 5, 9.5, 4)
```

Avoid extreme testing until the hook is confirmed stable.

Especially avoid literal `CS = 0` until you know the current build tolerates it. The script clamps CS to `0.1` by default for that reason.

---

## Update resilience

The script is designed to survive common update changes:

### Address changes

Handled automatically.

Every process launch has different JIT addresses. The script reads fresh addresses from the current process perf map.

### PreProcess symbol formatting changes

Partially handled.

The script broadly matches:

```text
BeatmapProcessor::PreProcess(
```

instead of relying on a single exact namespace string.

### BeatmapDifficulty offset shifts

Partially handled.

The generated Frida agent tries to discover the current field layout by scoring plausible layouts from live object data.

### Major pipeline changes

Not fully handled.

If osu! renames or removes the preprocessing path, or changes the difficulty representation significantly, the agent may fail closed and print diagnostics.

Failing closed is intentional: it is safer to do nothing than to write to the wrong object.

---

## Porting guide

The current implementation has two layers:

1. **Launcher/resolver layer**: finds the process, finds JIT addresses, generates the Frida agent, and attaches Frida.
2. **Frida agent layer**: hooks resolved methods and patches validated runtime objects.

Most porting work is in the launcher/resolver layer.

### Porting to Steam Deck / SteamOS

Steam Deck is the most realistic first port because SteamOS is Linux-based.

Likely required changes:

- confirm whether osu! runs as AppImage, Flatpak, native build, or through another wrapper
- adjust process discovery if the process name is not exactly `osu!`
- verify `/proc/<pid>/maps` is readable
- verify `/tmp/perf-<pid>.map` is generated
- check whether `ptrace_scope` or sandboxing blocks Frida attach
- install Frida tools in the correct Python/user environment
- if running through Flatpak/sandboxing, grant the needed debugging/process permissions or run an unsandboxed build

Suggested checks:

```bash
pgrep -a 'osu'
ls -l /tmp/perf-*.map
grep -i 'libcoreclr.so' /proc/<pid>/maps
grep -i 'BeatmapProcessor::PreProcess' /tmp/perf-<pid>.map | tail
```

If those checks work, the existing Linux script may only need small path/process-name changes.

---

### Porting to Windows

Windows does not have `/proc/<pid>/maps` or Linux perf maps, so the current resolver cannot work directly.

A Windows port would need to replace:

```text
/proc/<pid>/maps
/tmp/perf-<pid>.map
libcoreclr.so detection
Bash process discovery
```

Possible Windows resolver approaches:

1. **SOS/WinDbg or LLDB/SOS resolver**
   - Use SOS to resolve `name2ee` / method descriptors / JIT addresses.
   - Slower, but closest to the earlier LLDB workflow.

2. **CLRMD-based resolver**
   - Write a small .NET helper using Microsoft.Diagnostics.Runtime (CLRMD).
   - Attach to the osu! process, enumerate CLR modules/types/methods, resolve JIT code addresses, then write a JSON file consumed by the Frida launcher.
   - This is probably the cleanest Windows-native approach.

3. **Frida-only CLR metadata resolver**
   - Implement a Frida agent that walks CoreCLR structures directly.
   - Fast once built, but significantly more complex and runtime-version-sensitive.

4. **Source-patched development build**
   - Avoid JIT address discovery entirely by applying a local source patch.
   - Most stable for development, but no longer a pure runtime-instrumentation route.

A Windows port would probably use PowerShell instead of Bash and attach to the process by name or PID:

```powershell
Get-Process osu*
```

Then a resolver would output something like:

```json
{
  "BeatmapProcessor.PreProcess": "0x...",
  "OsuBeatmapProcessor.PreProcess": "0x..."
}
```

The Frida JS could stay mostly similar once those addresses are available.

---

### Porting to macOS

macOS also lacks `/proc/<pid>/maps` and Linux perf maps.

Likely required changes:

- process discovery via `ps`, `pgrep`, `launchctl`, or Frida device APIs
- module discovery via Frida APIs or macOS-specific tooling
- JIT symbol discovery through a non-perf-map mechanism
- handling Hardened Runtime, SIP, code signing, and entitlements
- using a macOS-compatible osu! build/runtime target

Possible resolver approaches are similar to Windows:

- LLDB/SOS
- CLRMD-style helper if viable for the runtime/process
- Frida-only CoreCLR metadata resolver
- source-patched development build

macOS may require additional signing/entitlement work before injection is allowed.

---

### Porting to Android

Android is theoretically possible because Frida supports Android and Frida Gadget can be embedded into apps, but this repository does not currently target Android.

A real Android port would need to answer several questions first:

- Is the target osu! build actually running on Android?
- Is it CoreCLR, Mono, Unity, Xamarin, NativeAOT, or something else?
- Are JIT symbols available in any usable form?
- Can Frida attach through `frida-server`, or must Frida Gadget be embedded?
- Is the device rooted, debug-enabled, or using a repackaged APK?
- Are there anti-tamper, SELinux, linker namespace, or sandbox restrictions?

Possible Android approaches:

1. **Rooted/debuggable device + frida-server**
   - Use `frida-ps -U` and attach normally.
   - Replace the Linux desktop resolver with Android process/module discovery.

2. **Frida Gadget embedded into the APK**
   - Repackage the APK with Gadget.
   - Load the Gadget library at app startup.
   - Connect from desktop Frida tools.
   - This may allow instrumentation when normal attach is not practical.

3. **Static/source-level Android build**
   - If you control the app build, add a local debug/testing switch instead of runtime patching.

The current Bash script will not run as-is on Android because it assumes a desktop Linux AppImage and `/tmp/perf-<pid>.map`.

---

### Porting to iOS

iOS is theoretical and significantly more restricted.

A port would likely require one of:

- a jailbroken device with Frida support
- a debug/development-signed app build
- Frida Gadget embedded in a repackaged app
- appropriate code signing and entitlements
- a compatible osu! runtime target

Major blockers:

- iOS code signing
- sandboxing
- JIT restrictions
- app re-signing/repackaging
- device trust/provisioning
- runtime differences if the app is not CoreCLR-based

The Frida Gadget idea is plausible at a high level because Gadget is designed for embedded instrumentation, including cases where normal injection is unavailable. However, this repository does not include any iOS build, signing, packaging, or runtime resolver work.

---

### Shared porting checklist

For any new platform, implement these pieces:

1. **Process discovery**
   - Find the real game process, not a wrapper/launcher.

2. **Runtime detection**
   - Determine whether the process uses CoreCLR, Mono, NativeAOT, Unity, or another runtime.

3. **JIT/method address resolver**
   - Replace Linux perf-map parsing with a platform-specific resolver.

4. **Object layout verification**
   - Confirm or rediscover the `BeatmapDifficulty` field layout.
   - Prefer real runtime type metadata where available.

5. **Frida attach or Gadget loading**
   - Desktop: attach by PID.
   - Mobile/sandboxed platforms: consider Gadget.

6. **Fail-closed safety**
   - If method addresses or object layouts cannot be verified, do not write memory.

7. **Local-only testing**
   - Validate in offline/dev builds first.
   - Avoid score submission or any environment where gameplay state could be misreported.


## Safety model

The script includes several safety mechanisms:

- no LLDB attachment
- no SOS dependency
- no hard-coded process address
- fresh perf-map address resolution every launch
- broad PreProcess discovery
- readable-memory checks before pointer reads
- automatic layout scoring
- patch cache to avoid repeated writes
- CS minimum clamp of `0.1` by default
- fail-closed behavior when confidence is low
- diagnostic commands for update checks

The most important rule:

```text
If the script is uncertain, it should not write.
```

---

## Project layout

Recommended GitHub repository layout:

```text
osu-difficulty-frida-agent/
├── README.md
├── run3_autoupdate.sh
├── .gitignore
└── docs/
    ├── troubleshooting.md
    └── development.md
```

Recommended `.gitignore`:

```gitignore
# generated agent
force-difficulty-autoupdate.generated.js
force-difficulty-preprocess.generated.js
*.generated.js

# logs
*.log

# local notes
.env
local.sh
```

---

## Development notes

### Adding a new command

Commands are exposed through `globalThis`.

Minimal example:

```js
let featureEnabled = false;

globalThis.setfeature = function (enabled) {
  featureEnabled = !!enabled;
  targetVersion++;
  patchedObjects.clear();
  console.log('[feature] ' + (featureEnabled ? 'enabled' : 'disabled'));
};
```

Add command state near:

```js
let enabled = true;
let targetVersion = 1;
let patchCount = 0;
```

Then use the state in the hook.

### Adding a new hook

1. Find the JIT symbol in the perf map:

```bash
grep -i 'MethodName' /tmp/perf-<pid>.map
```

2. Add a collector/matcher in the shell script.
3. Add the address to the generated JavaScript.
4. Attach with `Interceptor.attach(...)`.
5. Validate all pointers before reading or writing.
6. Wrap hook logic in `try/catch`.

### Safer workflow for new features

Use this loop:

```js
disableDiffPatch()
resetAutoDiscovery()
enableDiffPatch()
selftest()
```

Then switch/load a map and verify output.

---

## FAQ

### Does this need LLDB?

No. This script uses `/tmp/perf-<pid>.map` instead of LLDB/SOS.

### Why do I need perf maps?

Because the method addresses are JIT-generated and change every process launch. The perf map gives the live JIT code addresses.

### Why disable tiered compilation?

Tiered compilation can replace JITted code while the process is running. Disabling it makes JIT addresses more stable during the session.

### Why disable ReadyToRun?

ReadyToRun may reduce or change what gets JITted. Disabling it makes method resolution through perf maps more predictable.

### Why is CS clamped to 0.1?

`CS = 0` can trigger edge cases in gameplay or rendering code. The script defaults to `0.1` as a safer minimum.

Use this only if you explicitly want literal zero:

```js
allowZeroCS(true)
```

### Why does song select not always display the forced values?

This hook targets preprocessing/runtime difficulty objects. Some UI values may come from cached display calculations. The gameplay path is the primary target.

### Does it survive updates?

It survives address changes and some simple layout shifts. It may not survive major internal refactors. Use:

```js
selftest()
getlayout()
```

after every update.

### How do I stop patching without closing osu?

At the Frida prompt:

```js
disableDiffPatch()
```

To enable again:

```js
enableDiffPatch()
```

### How do I detach Frida?

At the Frida prompt:

```js
exit
```

or press:

```text
Ctrl+D
```

---

## Example full session

Terminal 1:

```bash
cd ~/Downloads/cosu

export DOTNET_PerfMapEnabled=3
export COMPlus_PerfMapEnabled=3
export DOTNET_TieredCompilation=0
export COMPlus_TieredCompilation=0
export DOTNET_ReadyToRun=0
export COMPlus_ReadyToRun=0
export COMPlus_TC_QuickJitForLoops=0

./osu.AppImage
```

Open song select and switch/load a map.

Terminal 2:

```bash
cd ~/Downloads/fridalazer
./run3_autoupdate.sh
```

Frida prompt:

```js
selftest()
setdiff(8, 5, 9.5, 4)
getdiff()
```

Test another target:

```js
setdiff(10, 10, 10, 4)
```

Disable:

```js
disableDiffPatch()
```

Exit:

```js
exit
```

---

### Is this cross-platform?

No. The current launcher is Linux-only and has only been tested on Ubuntu 24.04 x86_64 with osu! lazer AppImage.

The Frida agent logic may be portable, but the resolver is Linux-specific.

### Is this related to Freedom?

No. This project is not associated with the Freedom cheat/difficulty changer and should not be presented as such.

### Could this use Frida Gadget?

Possibly, but not in the current implementation.

Frida Gadget is relevant when normal injection/attach is not available, especially on mobile or sandboxed platforms. A Gadget-based port would still need platform-specific packaging, loading, method resolution, and object-layout verification.


## Disclaimer

This project is for local development and testing only. Do not use it to misrepresent gameplay conditions, bypass validation, or submit scores under conditions that do not match what was actually played.

Runtime instrumentation can crash the target process. Use at your own risk.
