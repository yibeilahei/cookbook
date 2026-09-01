"use strict";

// Lists installed font family names so the renderer can offer them as a
// dropdown (instead of the user needing to know/type an exact family name).
//
// Deliberately shells out to tools that already ship with the OS rather than
// pulling in a native npm module (e.g. electron-font-manager): those need
// prebuilt binaries per Electron/Node ABI and platform, which is exactly the
// packaging complexity this app avoids elsewhere (see the pure-Python
// backend). Both commands below run in well under a second.

const { execFile } = require("child_process");

const TIMEOUT_MS = 5000;

// Small built-in fallback so the dropdown is never left with zero usable
// entries if the OS command fails/times out on some unusual system.
const FALLBACK_FONTS = [
  "Arial", "Helvetica", "Times New Roman", "Courier New",
  "Hiragino Mincho ProN", "Hiragino Sans", "Menlo",
  "Yu Mincho", "Yu Gothic", "Consolas",
];

function execFileP(cmd, args) {
  return new Promise((resolve, reject) => {
    execFile(cmd, args, { timeout: TIMEOUT_MS, maxBuffer: 10 * 1024 * 1024 }, (err, stdout) => {
      if (err) reject(err);
      else resolve(stdout);
    });
  });
}

// Uses JXA (JavaScript for Automation, built into macOS) to call
// NSFontManager directly - near-instant, unlike `system_profiler
// SPFontsDataType` which can take 10+ seconds since it parses every font
// file's full metadata. Also grabs each family's localized display name
// (localizedNameForFamily:face:) so the dropdown can show e.g. "ヒラギノ明朝
// ProN" instead of "Hiragino Mincho ProN" on a Japanese system, while the
// underlying value stays the actual family name Calibre expects.
async function listMacFonts() {
  const script = `
ObjC.import("AppKit");
const mgr = $.NSFontManager.sharedFontManager;
const families = ObjC.deepUnwrap(mgr.availableFontFamilies);
const out = families.map((f) => {
  let display = f;
  try {
    const localized = ObjC.unwrap(mgr.localizedNameForFamilyFace(f, $()));
    if (localized) display = localized;
  } catch (e) {}
  return { family: f, display };
});
JSON.stringify(out);
`;
  const stdout = await execFileP("osascript", ["-l", "JavaScript", "-e", script]);
  return JSON.parse(stdout);
}

// Uses the built-in .NET GDI+ font collection via PowerShell - no extra
// installs, near-instant (in-memory, no disk scanning). FontFamily.GetName
// accepts an LCID and returns that font's localized display name, falling
// back to the invariant name when the font has no translation for it.
async function listWindowsFonts() {
  const script =
    "Add-Type -AssemblyName System.Drawing; " +
    "$lcid = [System.Globalization.CultureInfo]::CurrentUICulture.LCID; " +
    "(New-Object System.Drawing.Text.InstalledFontCollection).Families | " +
    "ForEach-Object { $_.Name + \"`t\" + $_.GetName($lcid) }";
  const stdout = await execFileP(
    "powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", script]);
  return stdout.split(/\r?\n/).map((s) => s.trim()).filter(Boolean).map((line) => {
    const [family, display] = line.split("\t");
    return { family, display: display || family };
  });
}

let cached = null; // memoized Promise<{family, display}[]>, populated on first call

async function listFontsUncached() {
  try {
    const entries = process.platform === "win32" ? await listWindowsFonts() : await listMacFonts();
    const seen = new Set();
    const unique = [];
    for (const entry of entries) {
      if (!entry.family || seen.has(entry.family)) continue;
      seen.add(entry.family);
      unique.push(entry);
    }
    unique.sort((a, b) => a.display.localeCompare(b.display));
    return unique.length > 0
      ? unique
      : FALLBACK_FONTS.map((family) => ({ family, display: family }));
  } catch (err) {
    console.error("[fonts] Failed to list system fonts, using fallback list:", err.message);
    return FALLBACK_FONTS.map((family) => ({ family, display: family }));
  }
}

function listFonts() {
  if (!cached) cached = listFontsUncached();
  return cached;
}

module.exports = { listFonts };
