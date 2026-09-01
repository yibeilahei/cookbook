"use strict";

const state = {
  mode: "xtch",
  config: {}, // mode -> full config object (cached, refetched on demand)
  inputs: [], // resolved file paths (strings)
  outputDir: null,
  converting: false,
  detectedLanguages: {}, // file path -> detected FONT_LANGUAGES bucket | null, cached from detect_language
  selectedFile: null, // path currently selected in the file list, for the Settings-panel preview below
};

const el = (id) => document.getElementById(id);

// ---------------------------------------------------------------- devices --

async function refreshDeviceSelect() {
  const { devices, default: def } = await window.backend.call("list_devices", { kind: state.mode });
  const select = el("device-select");
  select.innerHTML = "";
  for (const [key, dev] of Object.entries(devices)) {
    const opt = document.createElement("option");
    opt.value = key;
    opt.textContent = `${dev.label || key} (${dev.width}x${dev.height})`;
    select.appendChild(opt);
  }
  if (def && devices[def]) select.value = def;
}

async function openDeviceModal() {
  el("device-modal-error").textContent = "";
  el("device-modal-mode").textContent = state.mode === "xtch" ? t("modeLabelXtch") : t("modeLabelPdf");
  const config = await window.backend.call("get_config", { kind: state.mode });
  state.config[state.mode] = config;
  renderDeviceTable(config);
  el("device-modal").classList.remove("hidden");
}

function renderDeviceTable(config) {
  const body = el("device-table-body");
  body.innerHTML = "";
  const devices = config.devices || {};
  const showSupersample = state.mode === "xtch";
  el("device-table").querySelectorAll(".supersample-col").forEach((c) => {
    c.style.display = showSupersample ? "" : "none";
  });
  for (const [key, dev] of Object.entries(devices)) {
    body.appendChild(deviceRow(key, dev, config.default === key, showSupersample));
  }
}

function deviceRow(key, dev, isDefault, showSupersample) {
  const tr = document.createElement("tr");
  tr.innerHTML = `
    <td><input type="text" class="f-key" value="${key}"></td>
    <td><input type="text" class="f-label" value="${dev.label || ""}"></td>
    <td><input type="number" class="f-width" value="${dev.width || ""}"></td>
    <td><input type="number" class="f-height" value="${dev.height || ""}"></td>
    <td class="supersample-col" style="display:${showSupersample ? "" : "none"}">
      <input type="number" class="f-supersample" value="${dev.supersample || 3}"></td>
    <td>
      <select class="f-orientation">
        <option value="portrait" ${dev.orientation !== "landscape" ? "selected" : ""}>${t("orientationPortrait")}</option>
        <option value="landscape" ${dev.orientation === "landscape" ? "selected" : ""}>${t("orientationLandscape")}</option>
      </select>
    </td>
    <td><input type="radio" name="default-device" class="f-default" ${isDefault ? "checked" : ""}></td>
    <td><button class="f-delete">${t("delete")}</button></td>
  `;
  tr.querySelector(".f-delete").addEventListener("click", () => tr.remove());
  return tr;
}

function addDeviceRow() {
  const showSupersample = state.mode === "xtch";
  const body = el("device-table-body");
  const n = body.children.length + 1;
  body.appendChild(deviceRow(`device${n}`, { width: 480, height: 800, supersample: 3 }, false, showSupersample));
}

function collectConfigFromTable(baseConfig) {
  const rows = [...el("device-table-body").querySelectorAll("tr")];
  if (rows.length === 0) throw new Error(t("errAtLeastOneDevice"));
  const devices = {};
  let defaultKey = null;
  for (const row of rows) {
    const key = row.querySelector(".f-key").value.trim();
    if (!key) throw new Error(t("errEmptyKey"));
    if (devices[key]) throw new Error(t("errDuplicateKey", { key }));
    const dev = {
      label: row.querySelector(".f-label").value.trim(),
      width: parseInt(row.querySelector(".f-width").value, 10),
      height: parseInt(row.querySelector(".f-height").value, 10),
      orientation: row.querySelector(".f-orientation").value,
    };
    const supersampleInput = row.querySelector(".f-supersample");
    if (supersampleInput) dev.supersample = parseInt(supersampleInput.value, 10);
    if (row.querySelector(".f-default").checked) defaultKey = key;
    devices[key] = dev;
  }
  return { ...baseConfig, devices, default: defaultKey || Object.keys(devices)[0] };
}

async function saveDeviceModal() {
  el("device-modal-error").textContent = "";
  try {
    const updated = collectConfigFromTable(state.config[state.mode] || {});
    await window.backend.call("save_config", { kind: state.mode, config: updated });
    state.config[state.mode] = updated;
    el("device-modal").classList.add("hidden");
    await refreshDeviceSelect();
  } catch (err) {
    el("device-modal-error").textContent = err.message;
  }
}

// ------------------------------------------------------------------ settings --

const DEFAULT_FONT_SIZE = 60;

// Recommended serif/sans/mono presets per language bucket, per OS. Purely a
// UI convenience for pre-filling the font dropdowns below -- users can
// always override any individual font before saving. Buckets are script
// families (not individual languages): e.g. French/German/Spanish all use
// the "latin" preset, since font choice only really needs to vary by
// writing system. Fonts listed here are ones that ship by default on each
// OS; if one happens to be missing on a given machine it's simply added as
// a manually-set option (see populateFontSelect) rather than breaking.
const RECOMMENDED_FONTS = {
  latin: {
    macos: { serif: "Times New Roman", sans: "Helvetica", mono: "Menlo" },
    windows: { serif: "Times New Roman", sans: "Arial", mono: "Consolas" },
  },
  japanese: {
    macos: { serif: "Hiragino Mincho ProN", sans: "Hiragino Sans", mono: "Menlo" },
    windows: { serif: "Yu Mincho", sans: "Yu Gothic", mono: "Consolas" },
  },
  chinese_simplified: {
    macos: { serif: "Songti SC", sans: "PingFang SC", mono: "Menlo" },
    windows: { serif: "SimSun", sans: "Microsoft YaHei", mono: "Consolas" },
  },
  chinese_traditional: {
    macos: { serif: "Songti TC", sans: "PingFang TC", mono: "Menlo" },
    windows: { serif: "PMingLiU", sans: "Microsoft JhengHei", mono: "Consolas" },
  },
  korean: {
    macos: { serif: "AppleMyungjo", sans: "Apple SD Gothic Neo", mono: "Menlo" },
    windows: { serif: "Batang", sans: "Malgun Gothic", mono: "Consolas" },
  },
  cyrillic: {
    macos: { serif: "Times New Roman", sans: "Helvetica", mono: "Menlo" },
    windows: { serif: "Times New Roman", sans: "Arial", mono: "Consolas" },
  },
  greek: {
    macos: { serif: "Times New Roman", sans: "Helvetica", mono: "Menlo" },
    windows: { serif: "Times New Roman", sans: "Arial", mono: "Consolas" },
  },
  arabic: {
    macos: { serif: "Al Bayan", sans: "Geeza Pro", mono: "Geeza Pro" },
    windows: { serif: "Tahoma", sans: "Tahoma", mono: "Consolas" },
  },
  hebrew: {
    macos: { serif: "New Peninim MT", sans: "Arial Hebrew", mono: "Arial Hebrew" },
    windows: { serif: "David", sans: "Arial", mono: "Consolas" },
  },
  devanagari: {
    macos: { serif: "Devanagari Sangam MN", sans: "Devanagari Sangam MN", mono: "Devanagari Sangam MN" },
    windows: { serif: "Mangal", sans: "Mangal", mono: "Mangal" },
  },
  thai: {
    macos: { serif: "Ayuthaya", sans: "Thonburi", mono: "Thonburi" },
    windows: { serif: "Leelawadee UI", sans: "Leelawadee UI", mono: "Leelawadee UI" },
  },
};

// Only Japanese/Chinese/Korean have a specialized ASCII-romanization pass
// (Hepburn romaji, pinyin, Hangul romanization) layered on top of the
// universal Unidecode fallback that all .xtch filenames/chapter names
// always get regardless of language -- so the "Romanize" toggle is only
// meaningful (and only shown enabled) for these buckets. Simplified and
// Traditional Chinese are separate font buckets (see RECOMMENDED_FONTS) but
// share the same Pinyin romanization pass, since pinyin doesn't depend on
// script.
const ASCII_ROMANIZATION_LANGUAGES = ["japanese", "chinese_simplified", "chinese_traditional", "korean"];

/** The backend's ascii_romanization config field only ever accepts
 *  "japanese", "chinese", "korean", or "none" (see lib/common.py
 *  ASCII_ROMANIZATION_LANGUAGES) -- Simplified and Traditional Chinese both
 *  map to the plain "chinese" romanization pass. */
function asciiRomanizationFor(language) {
  if (language === "chinese_simplified" || language === "chinese_traditional") return "chinese";
  return language;
}

/** Map the browser/OS locale (e.g. "ja-JP", "zh-Hant", "ru-RU", "ar-EG") to
 *  one of the language buckets above, defaulting to "latin". */
function detectSystemLanguage() {
  const locale = (navigator.language || "en").toLowerCase();
  if (locale.startsWith("ja")) return "japanese";
  if (locale.startsWith("zh")) {
    // Traditional: zh-Hant*, zh-TW, zh-HK, zh-MO. Everything else
    // (zh-Hans*, zh-CN, zh-SG, bare "zh") defaults to Simplified.
    if (locale.includes("hant") || locale.includes("-tw") || locale.includes("-hk") || locale.includes("-mo")) {
      return "chinese_traditional";
    }
    return "chinese_simplified";
  }
  if (locale.startsWith("yue")) return "chinese_traditional"; // Cantonese: commonly HK/Traditional
  if (locale.startsWith("ko")) return "korean";
  if (["ru", "uk", "bg", "sr", "mk", "be", "mn", "kk"].some((p) => locale.startsWith(p))) return "cyrillic";
  if (locale.startsWith("el")) return "greek";
  if (["ar", "fa", "ur", "ps", "ku", "ug"].some((p) => locale.startsWith(p))) return "arabic";
  if (locale.startsWith("he") || locale.startsWith("iw") || locale.startsWith("yi")) return "hebrew";
  if (["hi", "mr", "ne", "sa"].some((p) => locale.startsWith(p))) return "devanagari";
  if (locale.startsWith("th")) return "thai";
  return "latin";
}

let systemFontsCache = null; // {family, display}[], memoized after first successful fetch

async function getSystemFonts() {
  if (!systemFontsCache) {
    try {
      systemFontsCache = await window.fontsApi.list();
    } catch (err) {
      systemFontsCache = [];
    }
  }
  return systemFontsCache;
}

function escapeHtml(s) {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

/** Populate a <select> with `fonts` ({family, display}[]) as options --
 *  option value is the actual family name Calibre needs, label is the
 *  locale-appropriate display name (e.g. "ヒラギノ明朝 ProN" instead of
 *  "Hiragino Mincho ProN" on a Japanese system). Always includes `current`
 *  (even if it's not in the detected list, e.g. a manually-set config value
 *  from before this machine's fonts were queried) so saving never silently
 *  changes the user's existing choice. */
function populateFontSelect(selectEl, fonts, current) {
  const hasCurrent = current && fonts.some((f) => f.family === current);
  const options = current && !hasCurrent ? [{ family: current, display: current }, ...fonts] : fonts;
  selectEl.innerHTML = options.map((f) => {
    const value = escapeHtml(f.family);
    const label = escapeHtml(f.display || f.family);
    return `<option value="${value}">${label}</option>`;
  }).join("");
  if (current) selectEl.value = current;
}

async function refreshSettingsView() {
  el("settings-modal-error").textContent = "";
  el("settings-modal-status").textContent = "";
  el("settings-modal-mode").textContent = state.mode === "xtch" ? t("modeLabelXtch") : t("modeLabelPdf");
  const config = await window.backend.call("get_config", { kind: state.mode });
  state.config[state.mode] = config;

  const language = config.language || detectSystemLanguage();
  el("settings-language").value = language;

  el("settings-romanize-row").classList.toggle("hidden", state.mode !== "xtch");
  el("settings-romanize-hint").classList.toggle("hidden", state.mode !== "xtch");
  const romanize = config.ascii_romanization != null
    ? config.ascii_romanization !== "none"
    : ASCII_ROMANIZATION_LANGUAGES.includes(language); // default: on for Japanese/Chinese/Korean
  setRomanizeToggle(language, romanize);

  const fontsKey = window.platform.fontsKey; // "macos" | "windows", from preload.js
  el("settings-fonts-os").textContent = fontsKey === "windows" ? t("fontsOsWindows") : t("fontsOsMacos");
  const fonts = (config.fonts && config.fonts[fontsKey]) || {};
  const systemFonts = await getSystemFonts();
  populateFontSelect(el("settings-font-serif"), systemFonts, fonts.serif);
  populateFontSelect(el("settings-font-sans"), systemFonts, fonts.sans);
  populateFontSelect(el("settings-font-mono"), systemFonts, fonts.mono);

  el("settings-font-size").value = config.font_size || DEFAULT_FONT_SIZE;
}

/** Only Japanese/Chinese/Korean have a specialized romanization pass, so
 *  the toggle is forced off & disabled for every other language; otherwise
 *  it reflects `romanize`. */
function setRomanizeToggle(language, romanize) {
  const checkbox = el("settings-romanize-toggle");
  const isRomanizable = ASCII_ROMANIZATION_LANGUAGES.includes(language);
  checkbox.disabled = !isRomanizable;
  checkbox.checked = isRomanizable && romanize;
}

/** Fill the serif/sans/mono selects with this language's recommended fonts
 *  for the current OS, then auto-save (the language select itself already
 *  triggers a save on change, so keep the resulting font values in sync). */
function applyRecommendedFonts(language) {
  const fontsKey = window.platform.fontsKey;
  const preset = RECOMMENDED_FONTS[language] || RECOMMENDED_FONTS.latin;
  const recommended = preset[fontsKey] || preset.macos;
  const systemFonts = systemFontsCache || [];
  populateFontSelect(el("settings-font-serif"), systemFonts, recommended.serif);
  populateFontSelect(el("settings-font-sans"), systemFonts, recommended.sans);
  populateFontSelect(el("settings-font-mono"), systemFonts, recommended.mono);
}

/** Auto-saves the current settings-panel field values. Called on every
 *  change event so there's no explicit Save button. */
async function saveSettingsModal() {
  el("settings-modal-error").textContent = "";
  el("settings-modal-status").textContent = "";
  try {
    const serif = el("settings-font-serif").value.trim();
    const sans = el("settings-font-sans").value.trim();
    const mono = el("settings-font-mono").value.trim();
    if (!serif || !sans || !mono) {
      throw new Error(t("errFontsRequired"));
    }
    const fontSize = parseInt(el("settings-font-size").value, 10);
    if (!Number.isInteger(fontSize) || fontSize <= 0) {
      throw new Error(t("errFontSize"));
    }

    const baseConfig = state.config[state.mode] || {};
    const fontsKey = window.platform.fontsKey;
    const updated = {
      ...baseConfig,
      fonts: { ...(baseConfig.fonts || {}), [fontsKey]: { serif, sans, mono } },
      font_size: fontSize,
    };
    const language = el("settings-language").value;
    if (state.mode === "xtch") {
      const romanize = el("settings-romanize-toggle").checked;
      updated.ascii_romanization = (ASCII_ROMANIZATION_LANGUAGES.includes(language) && romanize) ? asciiRomanizationFor(language) : "none";
    }
    updated.language = language;

    await window.backend.call("save_config", { kind: state.mode, config: updated });
    state.config[state.mode] = updated;
  } catch (err) {
    el("settings-modal-error").textContent = err.message;
  }
}

// ------------------------------------------------------------------ files --

async function addPaths(paths) {
  if (!paths || paths.length === 0) return;
  const { files } = await window.backend.call("expand_inputs", { paths });
  const newFiles = files.filter((f) => !state.inputs.includes(f));
  const set = new Set(state.inputs);
  for (const f of files) set.add(f);
  state.inputs = [...set];
  renderFileList();

  if (newFiles.length > 0) detectAndApplyLanguage(newFiles);
}

// Cap how many newly-added files get probed for language metadata, so
// adding a big directory doesn't stall on dozens of ebook-meta calls.
const LANGUAGE_DETECT_MAX_FILES = 20;

/** e.g. "chinese_simplified" -> "langNameChineseSimplified" */
function langNameKey(language) {
  return "langName" + language
    .split("_")
    .map((part) => part[0].toUpperCase() + part.slice(1))
    .join("");
}

/** Best-effort: detect the language of newly-added books from their own
 *  metadata and, if there's a clear majority, apply it to the current
 *  mode's Language setting (updating fonts/romanization + auto-saving),
 *  the same as if the user had picked it from the dropdown themselves.
 *  Also caches each file's own detected language (state.detectedLanguages)
 *  so selecting an individual book in the list can preview its own
 *  settings even when it differs from the applied majority. */
async function detectAndApplyLanguage(newFiles) {
  const sample = newFiles.slice(0, LANGUAGE_DETECT_MAX_FILES);
  let languages;
  try {
    ({ languages } = await window.backend.call("detect_language", { paths: sample }));
  } catch (err) {
    return; // best-effort -- ebook-meta missing/failed is not an error for the user
  }
  Object.assign(state.detectedLanguages, languages);

  const counts = {};
  for (const lang of Object.values(languages)) {
    if (lang) counts[lang] = (counts[lang] || 0) + 1;
  }
  const detected = Object.keys(counts).sort((a, b) => counts[b] - counts[a])[0];
  if (!detected) return;

  const current = el("settings-language").value;
  if (detected === current) return; // already matches -- nothing to change

  el("settings-language").value = detected;
  applyRecommendedFonts(detected);
  setRomanizeToggle(detected, true);
  await saveSettingsModal();
  el("settings-modal-status").textContent = t("detectedApplied", { lang: t(langNameKey(detected)) });
  setTimeout(() => { el("settings-modal-status").textContent = ""; }, 4000);
}

/** Select a file in the list and preview its own detected language in the
 *  Settings panel (dropdown + recommended fonts + romanize toggle), without
 *  saving -- this is just a look at what that specific book's settings
 *  would be, since conversion still applies one shared config to every
 *  book in the batch. Clicking the already-selected file deselects it and
 *  reverts the panel to the actually-saved config. */
async function selectFile(path) {
  if (state.selectedFile === path) {
    state.selectedFile = null;
    renderFileList();
    await refreshSettingsView();
    return;
  }
  state.selectedFile = path;
  renderFileList();

  el("settings-modal-status").textContent = "";
  let language = state.detectedLanguages[path];
  if (language === undefined) {
    try {
      ({ languages: { [path]: language } } = await window.backend.call("detect_language", { paths: [path] }));
    } catch (err) {
      language = null;
    }
    state.detectedLanguages[path] = language ?? null;
  }
  if (state.selectedFile !== path) return; // a newer selection/render happened meanwhile

  const name = path.split(/[\\/]/).pop();
  if (language) {
    el("settings-language").value = language;
    applyRecommendedFonts(language);
    setRomanizeToggle(language, true);
    el("settings-modal-status").textContent =
      t("previewingFile", { file: name, lang: t(langNameKey(language)) });
  } else {
    el("settings-modal-status").textContent = t("previewingFileUnknown", { file: name });
  }
}

function renderFileList() {
  const listEl = el("file-list");
  listEl.innerHTML = "";
  for (const path of state.inputs) {
    const li = document.createElement("li");
    li.dataset.file = path;
    if (path === state.selectedFile) li.classList.add("selected");
    const name = path.split(/[\\/]/).pop();
    li.innerHTML =
      `<span class="progress-row-name" title="${path}">${name}</span>` +
      `<span class="status-badge"></span>` +
      `<div class="file-progress-track"><div class="file-progress-fill"></div></div>`;
    li.addEventListener("click", () => selectFile(path));
    const previewBtn = document.createElement("button");
    previewBtn.textContent = t("previewBtn");
    previewBtn.addEventListener("click", (e) => { e.stopPropagation(); openPreview(path); });
    li.appendChild(previewBtn);
    const btn = document.createElement("button");
    btn.textContent = "✕";
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      state.inputs = state.inputs.filter((p) => p !== path);
      if (state.selectedFile === path) state.selectedFile = null;
      delete state.detectedLanguages[path];
      renderFileList();
    });
    li.appendChild(btn);
    listEl.appendChild(li);
  }
}

// ---------------------------------------------------------------- preview --

const PREVIEW_MAX_PAGES = 15;

async function openPreview(path) {
  const device = el("device-select").value;
  if (!device) {
    el("convert-status").textContent = t("selectDeviceFirst");
    return;
  }
  const name = path.split(/[\\/]/).pop();
  el("preview-modal-title").textContent = t("previewTitleFor", { name });
  el("preview-grid").innerHTML = "";
  el("preview-modal-status").textContent = t("renderingPages", { n: PREVIEW_MAX_PAGES });
  el("preview-modal").classList.remove("hidden");

  try {
    const result = await window.backend.call("preview", {
      kind: state.mode,
      device,
      path,
      max_pages: PREVIEW_MAX_PAGES,
    });
    el("preview-modal-status").textContent = t("showingPages", {
      shown: result.previewed,
      total: result.page_count,
      s: result.page_count === 1 ? "" : "s",
    });
    for (const dataUrl of result.pages) {
      const img = document.createElement("img");
      img.className = "preview-page";
      img.src = dataUrl;
      el("preview-grid").appendChild(img);
    }
  } catch (err) {
    el("preview-modal-status").textContent = t("errorMsg", { msg: err.message });
  }
}

function closePreview() {
  el("preview-modal").classList.add("hidden");
  el("preview-grid").innerHTML = "";
}

// -------------------------------------------------------------- conversion --

function addProgressRow(msg) {
  if (msg.type === "batch") {
    updateBatchProgress(msg);
    return;
  }
  const listEl = el("file-list");
  let li = listEl.querySelector(`li[data-file="${CSS.escape(msg.file)}"]`);
  if (!li) return; // file not in the current list (shouldn't normally happen)

  const badge = li.querySelector(".status-badge");
  const stageKey = `stage${msg.stage[0].toUpperCase()}${msg.stage.slice(1)}`;
  const translatedStage = t(stageKey);
  badge.textContent = translatedStage !== stageKey ? translatedStage : msg.stage;
  badge.className = `status-badge status-${msg.stage}`;
  badge.title = msg.message || "";

  const fill = li.querySelector(".file-progress-fill");
  if (msg.stage === "done") {
    fill.style.width = "100%";
  } else if (msg.stage === "error") {
    fill.style.width = "0%";
  } else if (typeof msg.percent === "number") {
    fill.style.width = `${Math.max(0, Math.min(100, msg.percent))}%`;
  }
}

function formatEta(seconds) {
  if (seconds == null || !isFinite(seconds)) return "";
  const s = Math.round(seconds);
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  const rem = s % 60;
  return `${m}m ${rem}s`;
}

function updateBatchProgress(msg) {
  const wrap = el("batch-progress");
  wrap.classList.remove("hidden");
  const percent = msg.total > 0 ? Math.round((msg.completed / msg.total) * 100) : 0;
  el("batch-progress-bar").style.width = `${percent}%`;
  const etaText = msg.eta_seconds != null ? t("etaSuffix", { eta: formatEta(msg.eta_seconds) }) : "";
  el("batch-progress-text").textContent =
    t("batchProgress", { completed: msg.completed, total: msg.total, percent, eta: etaText });
}

async function runConvert() {
  if (state.inputs.length === 0) {
    el("convert-status").textContent = t("addFileFirst");
    return;
  }
  const device = el("device-select").value;
  if (!device) {
    el("convert-status").textContent = t("selectDeviceFirst");
    return;
  }

  state.converting = true;
  el("convert-btn").disabled = true;
  el("cancel-btn").classList.remove("hidden");
  el("cancel-btn").disabled = false;
  el("convert-status").textContent = t("converting");
  document.querySelectorAll("#file-list .status-badge").forEach((b) => { b.textContent = ""; b.className = "status-badge"; b.title = ""; });
  document.querySelectorAll("#file-list .file-progress-fill").forEach((f) => { f.style.width = "0%"; });
  el("batch-progress").classList.add("hidden");
  el("batch-progress-bar").style.width = "0%";
  el("batch-progress-text").textContent = "";

  const unsubscribe = window.backend.onProgress(addProgressRow);
  try {
    const result = await window.backend.call("convert", {
      kind: state.mode,
      device,
      paths: state.inputs,
      output_dir: state.outputDir || undefined,
    });
    const parts = [];
    if (result.done.length) parts.push(t("nDone", { n: result.done.length }));
    if (result.skipped.length) parts.push(t("nSkipped", { n: result.skipped.length }));
    if (result.errors.length) parts.push(t("nFailed", { n: result.errors.length }));
    el("convert-status").textContent = result.cancelled
      ? t("cancelledWith", { parts: parts.join(", ") || t("nothingFinished") })
      : parts.join(", ") || t("nothingToDo");
  } catch (err) {
    el("convert-status").textContent = t("errorMsg", { msg: err.message });
  } finally {
    unsubscribe();
    state.converting = false;
    el("convert-btn").disabled = false;
    el("cancel-btn").classList.add("hidden");
  }
}

async function cancelConvert() {
  el("cancel-btn").disabled = true;
  el("convert-status").textContent = t("cancelling");
  try {
    await window.backend.call("cancel");
  } catch (err) {
    console.error("Failed to cancel:", err);
  }
}

// ------------------------------------------------------------------ calibre --

async function checkCalibre() {
  const banner = el("calibre-banner");
  const result = await window.backend.call("find_calibre");
  if (result.found) {
    banner.classList.add("hidden");
  } else {
    el("calibre-banner-text").textContent = result.hint || t("calibreNotFound");
    banner.classList.remove("hidden");
  }
}

// ---------------------------------------------------------------- wiring --

function setMode(mode) {
  state.mode = mode;
  state.selectedFile = null;
  document.querySelectorAll(".mode-btn").forEach((b) => b.classList.toggle("active", b.dataset.mode === mode));
  renderFileList();
  refreshDeviceSelect();
  refreshSettingsView();
}

function wireDropZone() {
  const zone = el("drop-zone");
  zone.addEventListener("dragover", (e) => {
    e.preventDefault();
    zone.classList.add("dragover");
  });
  zone.addEventListener("dragleave", () => zone.classList.remove("dragover"));
  zone.addEventListener("drop", (e) => {
    e.preventDefault();
    zone.classList.remove("dragover");
    const paths = [...e.dataTransfer.files].map((f) => f.path).filter(Boolean);
    addPaths(paths);
  });
}

function init() {
  applyStaticI18n();

  document.querySelectorAll(".mode-btn").forEach((btn) => {
    btn.addEventListener("click", () => setMode(btn.dataset.mode));
  });

  el("add-files-btn").addEventListener("click", async () => {
    const paths = await window.dialogs.pickInputs();
    addPaths(paths);
  });

  el("pick-output-btn").addEventListener("click", async () => {
    const dir = await window.dialogs.pickOutputDir(state.inputs[0]);
    if (dir) {
      state.outputDir = dir;
      el("output-dir").value = dir;
    }
  });
  el("clear-output-btn").addEventListener("click", () => {
    state.outputDir = null;
    el("output-dir").value = "";
  });

  el("edit-devices-btn").addEventListener("click", openDeviceModal);
  el("add-device-row-btn").addEventListener("click", addDeviceRow);
  el("device-modal-save").addEventListener("click", saveDeviceModal);
  el("device-modal-cancel").addEventListener("click", () => el("device-modal").classList.add("hidden"));

  // Settings auto-save on every change -- no explicit Save button.
  el("settings-romanize-toggle").addEventListener("change", saveSettingsModal);
  el("settings-font-serif").addEventListener("change", saveSettingsModal);
  el("settings-font-sans").addEventListener("change", saveSettingsModal);
  el("settings-font-mono").addEventListener("change", saveSettingsModal);
  el("settings-font-size").addEventListener("change", saveSettingsModal);
  el("settings-language").addEventListener("change", (e) => {
    const language = e.target.value;
    applyRecommendedFonts(language);
    setRomanizeToggle(language, true); // default: on when switching to a CJK language
    saveSettingsModal();
  });

  el("convert-btn").addEventListener("click", runConvert);
  el("cancel-btn").addEventListener("click", cancelConvert);
  el("preview-modal-close").addEventListener("click", closePreview);
  el("preview-modal").addEventListener("click", (e) => {
    if (e.target === e.currentTarget) closePreview();
  });
  el("calibre-recheck").addEventListener("click", checkCalibre);

  wireDropZone();
  refreshDeviceSelect();
  refreshSettingsView();
  checkCalibre();
}

document.addEventListener("DOMContentLoaded", init);
