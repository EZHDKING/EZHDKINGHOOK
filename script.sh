#!/usr/bin/env bash
set -euo pipefail

# EZHDKINGHOOK
# No-LLDB, auto-refreshing Frida route for osu! lazer difficulty hooks.
#
#
# - Resolves live JIT addresses from /tmp/perf-<pid>.map every run.
# - Uses broad method discovery for BeatmapProcessor::PreProcess so minor
#   namespace/assembly formatting changes are less likely to break it.
# - Does not hard-require fixed BeatmapDifficulty offsets. The generated agent
#   tries to auto-discover the current difficulty field layout from the live
#   object shape, then fails closed if confidence is too low.
# - Adds selftest(), getlayout(), resetAutoDiscovery(), and setautodiscovery().
#
# Required osu launch environment:
#
#   export DOTNET_PerfMapEnabled=3
#   export COMPlus_PerfMapEnabled=3
#   export DOTNET_TieredCompilation=0
#   export COMPlus_TieredCompilation=0
#   export DOTNET_ReadyToRun=0
#   export COMPlus_ReadyToRun=0
#   export COMPlus_TC_QuickJitForLoops=0
#   ./osu.AppImage
#
# Important limitation:
# - This can auto-refresh addresses and discover simple offset shifts.
# - It cannot magically know renamed gameplay pipelines or fully reordered fields.
#   If confidence is low, it refuses to patch and prints diagnostics.

OUT_JS="${OUT_JS:-force-difficulty-autoupdate.generated.js}"
WAIT_SECONDS="${WAIT_SECONDS:-30}"

DEFAULT_OD="${OSU_FORCE_OD:-8}"
DEFAULT_HP="${OSU_FORCE_HP:-5}"
DEFAULT_AR="${OSU_FORCE_AR:-9.5}"
DEFAULT_CS="${OSU_FORCE_CS:-4}"

find_coreclr_pid() {
  local p
  for p in $(pgrep -x 'osu!' || true); do
    if [[ -r "/proc/${p}/maps" ]] && grep -qi 'libcoreclr.so' "/proc/${p}/maps" 2>/dev/null; then
      echo "${p}"
      return 0
    fi
  done
  return 1
}

normalize_addr() {
  local addr="$1"
  addr="${addr#0x}"
  printf "0x%s" "${addr}"
}

PID="$(find_coreclr_pid || true)"

if [[ -z "${PID}" ]]; then
  echo "[error] Could not find osu! CoreCLR process."
  echo "[hint] Start osu fully first."
  exit 1
fi

PERF_MAP="/tmp/perf-${PID}.map"

echo "[info] osu CoreCLR PID: ${PID}"
echo "[info] Runtime module:"
grep -i 'libcoreclr.so' "/proc/${PID}/maps" | head -1 || true

if [[ ! -f "${PERF_MAP}" ]]; then
  echo "[error] ${PERF_MAP} does not exist."
  echo "[fix] Restart osu with:"
  echo "       export DOTNET_PerfMapEnabled=3"
  echo "       export COMPlus_PerfMapEnabled=3"
  echo "       export DOTNET_TieredCompilation=0"
  echo "       export COMPlus_TieredCompilation=0"
  echo "       export DOTNET_ReadyToRun=0"
  echo "       export COMPlus_ReadyToRun=0"
  echo "       export COMPlus_TC_QuickJitForLoops=0"
  echo "       ./osu.AppImage"
  exit 1
fi

echo "[info] Using perf map: ${PERF_MAP}"
echo "[info] Waiting up to ${WAIT_SECONDS}s for BeatmapProcessor::PreProcess JIT symbols..."

PREPROCESS_ITEMS=""

collect_preprocess_items() {
  local map_file="$1"

  awk '
    function norm(addr) {
      sub(/^0x/, "", addr)
      return "0x" addr
    }

    # Match base and ruleset-specific processors:
    #   [osu.Game] osu.Game.Beatmaps.BeatmapProcessor::PreProcess()
    #   [osu.Game.Rulesets.X] osu.Game.Rulesets.X.Beatmaps.XBeatmapProcessor::PreProcess()
    #
    # This intentionally matches broadly on BeatmapProcessor::PreProcess because
    # perf-map formatting can change between runtimes.
    /BeatmapProcessor::PreProcess\(/ {
      addr = norm($1)
      label = $0
      sub(/^[^ ]+[[:space:]]+[^ ]+[[:space:]]+/, "", label)
      gsub(/\\/, "\\\\", label)
      gsub(/'\''/, "\\'\''", label)
      print addr "|" label
    }
  ' "${map_file}" | awk -F'|' '!seen[$1]++'
}

for ((i=0; i<WAIT_SECONDS; i++)); do
  PREPROCESS_ITEMS="$(collect_preprocess_items "${PERF_MAP}" || true)"

  if [[ -n "${PREPROCESS_ITEMS}" ]]; then
    break
  fi

  sleep 1
done

if [[ -z "${PREPROCESS_ITEMS}" ]]; then
  echo "[error] No BeatmapProcessor::PreProcess JIT symbol found in ${PERF_MAP}."
  echo "[hint] Enter song select or switch/load a beatmap once, then rerun."
  echo "[debug] Current PreProcess matches:"
  grep -i 'PreProcess' "${PERF_MAP}" | tail -30 || true
  exit 1
fi

echo "[fresh] PreProcess candidates:"
echo "${PREPROCESS_ITEMS}" | sed 's/^/[fresh]   /'

HOOK_ARRAY=""
while IFS='|' read -r addr label; do
  [[ -z "${addr}" ]] && continue
  # Keep labels short enough for readable logging.
  short_label="${label}"
  short_label="${short_label%%\[Optimized\]*}"
  HOOK_ARRAY="${HOOK_ARRAY}  ['${short_label}', ptr('${addr}')],
"
done <<< "${PREPROCESS_ITEMS}"

cat > "${OUT_JS}" <<EOFJS
'use strict';

const PREPROCESS_HOOKS = [
${HOOK_ARRAY}];

const FALLBACK_LAYOUT = {
  sliderMultiplier: 0x18,
  sliderTickRate: 0x20,
  hp: 0x28,
  cs: 0x2c,
  od: 0x30,
  ar: 0x34,
  confidence: 0,
  source: 'fallback'
};

let layout = null;
let autoDiscoveryEnabled = true;

// Safe defaults. CS is clamped to 0.1 by default to avoid zero-scale edge cases.
// Use allowZeroCS(true) if you explicitly want CS=0.
let bounds = {
  od: [0.0, 10.0],
  hp: [0.0, 10.0],
  ar: [0.0, 10.0],
  cs: [0.1, 10.0]
};

let enabled = true;
let targetVersion = 1;
let patchCount = 0;
let skipCount = 0;
let scanFailCount = 0;
let discoveryFailCount = 0;
let loggedLayout = false;
let warnedOutdated = false;

let target = sanitizeTarget({
  od: Number('${DEFAULT_OD}'),
  hp: Number('${DEFAULT_HP}'),
  ar: Number('${DEFAULT_AR}'),
  cs: Number('${DEFAULT_CS}')
});

const patchedObjects = new Map();

let learned = {
  processorOffset: -1,
  beatmapOffset: -1
};

function isReadableAddress(p) {
  try {
    if (p === null || p.isNull()) return false;
    const r = Process.findRangeByAddress(p);
    return r !== null && r.protection.indexOf('r') !== -1;
  } catch (_) {
    return false;
  }
}

function safeReadPointer(address) {
  try {
    if (!isReadableAddress(address)) return NULL;
    const p = address.readPointer();
    if (p === null || p.isNull()) return NULL;
    if (!isReadableAddress(p)) return NULL;
    return p;
  } catch (_) {
    return NULL;
  }
}

function readDoubleSafe(obj, off) {
  try {
    return obj.add(off).readDouble();
  } catch (_) {
    return Number.NaN;
  }
}

function readFloatSafe(obj, off) {
  try {
    return obj.add(off).readFloat();
  } catch (_) {
    return Number.NaN;
  }
}

function finite(x) {
  return Number.isFinite(x);
}

function plausibleFloatDifficulty(x) {
  return finite(x) && x >= 0.0 && x <= 10.5;
}

function plausibleLooseFloat(x) {
  return finite(x) && x > -1.0 && x < 20.0;
}

function plausibleSliderDouble(x) {
  return finite(x) && x > 0.0 && x < 20.0;
}

function scoreCandidateLayout(obj, candidate) {
  const sm = readDoubleSafe(obj, candidate.sliderMultiplier);
  const st = readDoubleSafe(obj, candidate.sliderTickRate);
  const hp = readFloatSafe(obj, candidate.hp);
  const cs = readFloatSafe(obj, candidate.cs);
  const od = readFloatSafe(obj, candidate.od);
  const ar = readFloatSafe(obj, candidate.ar);

  let score = 0;

  if (plausibleSliderDouble(sm)) score += 5;
  if (plausibleSliderDouble(st)) score += 5;

  for (const x of [hp, cs, od, ar]) {
    if (finite(x)) score += 1;
    if (plausibleLooseFloat(x)) score += 2;
    if (plausibleFloatDifficulty(x)) score += 4;
  }

  // Normal BeatmapDifficulty field ordering is two doubles followed by four
  // floats. Reward compact contiguous layout.
  if (candidate.sliderTickRate === candidate.sliderMultiplier + 0x8) score += 2;
  if (candidate.hp === candidate.sliderTickRate + 0x8) score += 2;
  if (candidate.cs === candidate.hp + 0x4) score += 1;
  if (candidate.od === candidate.cs + 0x4) score += 1;
  if (candidate.ar === candidate.od + 0x4) score += 1;

  return {
    score,
    values: { sm, st, hp, cs, od, ar }
  };
}

function discoverLayoutForObject(obj) {
  if (!isReadableAddress(obj)) return null;

  // Object MethodTable pointer should itself be readable. This filters many
  // bogus pointers while staying no-SOS/no-LLDB.
  const mt = safeReadPointer(obj);
  if (!isReadableAddress(mt)) return null;

  const candidates = [];

  // Known current layout first.
  candidates.push(Object.assign({}, FALLBACK_LAYOUT, { source: 'known-current' }));

  // Auto-discover shifted versions of the same field order:
  // double, double, float, float, float, float
  for (let smOff = 0x10; smOff <= 0x50; smOff += 0x8) {
    const stOff = smOff + 0x8;
    const hpOff = stOff + 0x8;
    candidates.push({
      sliderMultiplier: smOff,
      sliderTickRate: stOff,
      hp: hpOff,
      cs: hpOff + 0x4,
      od: hpOff + 0x8,
      ar: hpOff + 0xc,
      source: 'auto-shifted'
    });
  }

  let best = null;
  for (const c of candidates) {
    const result = scoreCandidateLayout(obj, c);
    if (best === null || result.score > best.confidence) {
      best = Object.assign({}, c, { confidence: result.score, values: result.values });
    }
  }

  // Confidence threshold:
  //   10 from two plausible doubles
  //   up to 28 from four plausible floats
  //   7 compact-layout bonus
  // 38+ means very likely; 32+ is acceptable in weird maps.
  if (best !== null && best.confidence >= 32) {
    return best;
  }

  return null;
}

function ensureLayout(obj) {
  if (layout !== null) return true;
  if (!autoDiscoveryEnabled) {
    layout = Object.assign({}, FALLBACK_LAYOUT);
    return true;
  }

  const discovered = discoverLayoutForObject(obj);
  if (discovered === null) {
    discoveryFailCount++;
    return false;
  }

  layout = discovered;
  console.log(
    '[layout] discovered source=' + layout.source +
    ' confidence=' + layout.confidence +
    ' SM=0x' + layout.sliderMultiplier.toString(16) +
    ' STR=0x' + layout.sliderTickRate.toString(16) +
    ' HP=0x' + layout.hp.toString(16) +
    ' CS=0x' + layout.cs.toString(16) +
    ' OD=0x' + layout.od.toString(16) +
    ' AR=0x' + layout.ar.toString(16)
  );
  return true;
}

function readDifficultyWithLayout(d, l) {
  return {
    sliderMultiplier: d.add(l.sliderMultiplier).readDouble(),
    sliderTickRate: d.add(l.sliderTickRate).readDouble(),
    hp: d.add(l.hp).readFloat(),
    cs: d.add(l.cs).readFloat(),
    od: d.add(l.od).readFloat(),
    ar: d.add(l.ar).readFloat()
  };
}

function readDifficulty(d) {
  if (!ensureLayout(d)) throw new Error('layout not discovered');
  return readDifficultyWithLayout(d, layout);
}

function scoreDifficultyValues(v) {
  let score = 0;

  if (plausibleSliderDouble(v.sliderMultiplier)) score += 5;
  if (plausibleSliderDouble(v.sliderTickRate)) score += 5;

  for (const x of [v.hp, v.cs, v.od, v.ar]) {
    if (finite(x)) score += 1;
    if (plausibleLooseFloat(x)) score += 2;
    if (plausibleFloatDifficulty(x)) score += 4;
  }

  return score;
}

function isBeatmapDifficultyShape(obj) {
  try {
    if (!isReadableAddress(obj)) return false;
    const mt = safeReadPointer(obj);
    if (!isReadableAddress(mt)) return false;

    const l = layout || discoverLayoutForObject(obj);
    if (l === null) return false;

    const v = readDifficultyWithLayout(obj, l);
    return scoreDifficultyValues(v) >= 28;
  } catch (_) {
    return false;
  }
}

function clamp(k, v) {
  v = Number(v);
  if (!Number.isFinite(v)) throw new Error(k + ' must be a finite number');
  const b = bounds[k];
  return Math.min(b[1], Math.max(b[0], v));
}

function sanitizeTarget(next) {
  return {
    od: clamp('od', next.od),
    hp: clamp('hp', next.hp),
    ar: clamp('ar', next.ar),
    cs: clamp('cs', next.cs)
  };
}

function objectKey(d) {
  return d.toString() + ':v' + targetVersion;
}

function closeEnough(a, b) {
  return Math.abs(a - b) < 0.0001;
}

function alreadyTarget(v) {
  return closeEnough(v.hp, target.hp) &&
         closeEnough(v.cs, target.cs) &&
         closeEnough(v.od, target.od) &&
         closeEnough(v.ar, target.ar);
}

function findDifficultyInsideObject(obj, maxOffset) {
  let best = null;
  let bestScore = -1;

  for (let off = 0x8; off <= maxOffset; off += 0x8) {
    const candidate = safeReadPointer(obj.add(off));
    if (!isReadableAddress(candidate)) continue;

    const candidateLayout = layout || discoverLayoutForObject(candidate);
    if (candidateLayout === null) continue;

    try {
      const values = readDifficultyWithLayout(candidate, candidateLayout);
      const score = scoreDifficultyValues(values) + (candidateLayout.confidence || 0);

      if (score > bestScore && score >= 60) {
        bestScore = score;
        best = { difficulty: candidate, offset: off, score, layout: candidateLayout };
      }
    } catch (_) {
    }
  }

  return best;
}

function tryLearnedOffsets(processor) {
  if (learned.processorOffset < 0 || learned.beatmapOffset < 0) return null;

  const beatmap = safeReadPointer(processor.add(learned.processorOffset));
  if (!isReadableAddress(beatmap)) return null;

  const difficulty = safeReadPointer(beatmap.add(learned.beatmapOffset));
  if (!isBeatmapDifficultyShape(difficulty)) return null;

  return {
    difficulty,
    beatmap,
    processorOffset: learned.processorOffset,
    beatmapOffset: learned.beatmapOffset,
    score: 999
  };
}

function findDifficultyFromProcessor(processor) {
  const fast = tryLearnedOffsets(processor);
  if (fast !== null) return fast;

  for (let processorOff = 0x8; processorOff <= 0x100; processorOff += 0x8) {
    const maybeBeatmap = safeReadPointer(processor.add(processorOff));
    if (!isReadableAddress(maybeBeatmap)) continue;

    const nested = findDifficultyInsideObject(maybeBeatmap, 0x180);
    if (nested !== null) {
      learned.processorOffset = processorOff;
      learned.beatmapOffset = nested.offset;
      if (layout === null && nested.layout) layout = nested.layout;

      return {
        difficulty: nested.difficulty,
        beatmap: maybeBeatmap,
        processorOffset: processorOff,
        beatmapOffset: nested.offset,
        score: nested.score
      };
    }
  }

  const direct = findDifficultyInsideObject(processor, 0x180);
  if (direct !== null) {
    if (layout === null && direct.layout) layout = direct.layout;
    return {
      difficulty: direct.difficulty,
      beatmap: NULL,
      processorOffset: -1,
      beatmapOffset: direct.offset,
      score: direct.score
    };
  }

  return null;
}

function printOutdatedWarningOnce(reason) {
  if (warnedOutdated) return;
  warnedOutdated = true;
  console.log('[outdated?] ' + reason);
  console.log('[outdated?] Run getlayout() / selftest(). If scanFails keep increasing, osu likely changed the pipeline or object layout.');
  console.log('[outdated?] This agent is failing closed instead of writing unsafe offsets.');
}

function patchDifficulty(d, reason) {
  if (!enabled) return false;
  if (!isBeatmapDifficultyShape(d)) return false;
  if (!ensureLayout(d)) {
    printOutdatedWarningOnce('Could not discover BeatmapDifficulty layout.');
    return false;
  }

  let before;
  try {
    before = readDifficulty(d);
  } catch (_) {
    return false;
  }

  const key = objectKey(d);
  if (patchedObjects.has(key) && alreadyTarget(before)) {
    skipCount++;
    return true;
  }

  try {
    d.add(layout.hp).writeFloat(target.hp);
    d.add(layout.cs).writeFloat(target.cs);
    d.add(layout.od).writeFloat(target.od);
    d.add(layout.ar).writeFloat(target.ar);
  } catch (e) {
    console.log('[write failed] ' + e);
    return false;
  }

  patchedObjects.set(key, true);
  patchCount++;

  if (patchCount <= 20 || patchCount % 50 === 0) {
    console.log(
      '[' + reason + '] #' + patchCount + ' obj=' + d +
      ' before OD=' + before.od.toFixed(2) +
      ' HP=' + before.hp.toFixed(2) +
      ' AR=' + before.ar.toFixed(2) +
      ' CS=' + before.cs.toFixed(2) +
      ' SM=' + before.sliderMultiplier.toFixed(2) +
      ' STR=' + before.sliderTickRate.toFixed(2) +
      ' => target OD=' + target.od +
      ' HP=' + target.hp +
      ' AR=' + target.ar +
      ' CS=' + target.cs
    );
  }

  return true;
}

function hookPreProcess(name, address) {
  const range = Process.findRangeByAddress(address);
  if (range === null || range.protection.indexOf('x') === -1) {
    console.log('[skip] ' + name + ' @ ' + address + ' is not executable/mapped');
    return;
  }

  Interceptor.attach(address, {
    onEnter(args) {
      try {
        const processor = args[0];
        const found = findDifficultyFromProcessor(processor);
        if (found === null) {
          scanFailCount++;
          if (scanFailCount === 25 || scanFailCount === 100 || scanFailCount === 500) {
            printOutdatedWarningOnce('Could not find BeatmapDifficulty from PreProcess processor.');
          }
          return;
        }

        if (!loggedLayout) {
          loggedLayout = true;
          console.log('[debug] ' + name + ' processor=' + processor +
            ' beatmap=' + found.beatmap +
            ' processorOffset=0x' + found.processorOffset.toString(16) +
            ' beatmapDifficultyOffset=0x' + found.beatmapOffset.toString(16) +
            ' score=' + found.score);
        }

        patchDifficulty(found.difficulty, name);
      } catch (e) {
        console.log('[hook exception] ' + name + ': ' + e);
      }
    }
  });

  console.log('[hooked] ' + name + ' @ ' + address + ' perms=' + range.protection);
}

for (const h of PREPROCESS_HOOKS) {
  hookPreProcess(h[0], h[1]);
}

globalThis.setdiff = function (od, hp, ar, cs) {
  try {
    target = sanitizeTarget({ od, hp, ar, cs });
  } catch (e) {
    console.log('[error] ' + e.message);
    return;
  }

  targetVersion++;
  patchedObjects.clear();
  patchCount = 0;
  skipCount = 0;
  scanFailCount = 0;
  discoveryFailCount = 0;

  console.log('[set target] OD=' + target.od + ' HP=' + target.hp + ' AR=' + target.ar + ' CS=' + target.cs);
};

globalThis.getdiff = function () {
  console.log('[current target] OD=' + target.od + ' HP=' + target.hp + ' AR=' + target.ar + ' CS=' + target.cs);
  console.log('[stats] patches=' + patchCount + ' skipped=' + skipCount + ' scanFails=' + scanFailCount + ' discoveryFails=' + discoveryFailCount + ' cached=' + patchedObjects.size + ' version=' + targetVersion);
  console.log('[learned] processorOffset=' + learned.processorOffset + ' beatmapOffset=' + learned.beatmapOffset);
  getlayout();
};

globalThis.getlayout = function () {
  if (layout === null) {
    console.log('[layout] not discovered yet');
    return;
  }

  console.log(
    '[layout] source=' + layout.source +
    ' confidence=' + layout.confidence +
    ' SM=0x' + layout.sliderMultiplier.toString(16) +
    ' STR=0x' + layout.sliderTickRate.toString(16) +
    ' HP=0x' + layout.hp.toString(16) +
    ' CS=0x' + layout.cs.toString(16) +
    ' OD=0x' + layout.od.toString(16) +
    ' AR=0x' + layout.ar.toString(16)
  );
  console.log('[bounds] OD=' + bounds.od + ' HP=' + bounds.hp + ' AR=' + bounds.ar + ' CS=' + bounds.cs);
};

globalThis.selftest = function () {
  console.log('[selftest] hooks=' + PREPROCESS_HOOKS.length);
  for (const h of PREPROCESS_HOOKS) console.log('[selftest] hook=' + h[0] + ' @ ' + h[1]);
  getdiff();

  if (scanFailCount > 0 && patchCount === 0) {
    console.log('[selftest] WARNING: hooks are firing but no patches succeeded. Likely outdated object path/layout.');
  } else if (patchCount > 0) {
    console.log('[selftest] OK: patching has succeeded at least once.');
  } else {
    console.log('[selftest] Waiting: no PreProcess call observed yet. Switch/load a beatmap.');
  }
};

globalThis.enableDiffPatch = function () {
  enabled = true;
  console.log('[enabled]');
};

globalThis.disableDiffPatch = function () {
  enabled = false;
  console.log('[disabled]');
};

globalThis.resetPatchCache = function () {
  patchedObjects.clear();
  patchCount = 0;
  skipCount = 0;
  scanFailCount = 0;
  discoveryFailCount = 0;
  loggedLayout = false;
  warnedOutdated = false;
  learned.processorOffset = -1;
  learned.beatmapOffset = -1;
  console.log('[reset]');
};

globalThis.resetAutoDiscovery = function () {
  layout = null;
  resetPatchCache();
  console.log('[autodiscovery] layout cleared; will rediscover on next PreProcess');
};

globalThis.setautodiscovery = function (enabled) {
  autoDiscoveryEnabled = !!enabled;
  layout = autoDiscoveryEnabled ? null : Object.assign({}, FALLBACK_LAYOUT);
  resetPatchCache();
  console.log('[autodiscovery] ' + (autoDiscoveryEnabled ? 'enabled' : 'disabled/fallback'));
};

globalThis.allowZeroCS = function (enabled) {
  bounds.cs[0] = enabled ? 0.0 : 0.1;
  target = sanitizeTarget(target);
  targetVersion++;
  patchedObjects.clear();
  console.log('[bounds] CS min=' + bounds.cs[0] + '; current CS=' + target.cs);
};

globalThis.setbounds = function (odMin, odMax, hpMin, hpMax, arMin, arMax, csMin, csMax) {
  const next = {
    od: [Number(odMin), Number(odMax)],
    hp: [Number(hpMin), Number(hpMax)],
    ar: [Number(arMin), Number(arMax)],
    cs: [Number(csMin), Number(csMax)]
  };

  for (const k of Object.keys(next)) {
    if (!Number.isFinite(next[k][0]) || !Number.isFinite(next[k][1]) || next[k][0] > next[k][1]) {
      console.log('[error] invalid bounds for ' + k);
      return;
    }
  }

  bounds = next;
  target = sanitizeTarget(target);
  targetVersion++;
  patchedObjects.clear();
  console.log('[bounds updated]');
  getdiff();
};

console.log('****EZHD KING HOOK*****');
console.log('[hooks] count=' + PREPROCESS_HOOKS.length);
console.log('[default target] OD=' + target.od + ' HP=' + target.hp + ' AR=' + target.ar + ' CS=' + target.cs);
console.log('[usage] setdiff(8, 5, 9.5, 4)');
console.log('[usage] selftest() / getlayout() / resetAutoDiscovery() / setautodiscovery(true)');
console.log('[note] This agent auto-refreshes JIT addresses and auto-discovers simple layout shifts. It fails closed if confidence is low.');
console.log('[note] CS is clamped to >= 0.1 by default. Use allowZeroCS(true) to permit CS=0.');
EOFJS

echo "[info] Generated ${OUT_JS}"
echo "[info] Starting Frida..."
frida -p "${PID}" -l "${OUT_JS}"
