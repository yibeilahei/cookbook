"use strict";

const { app, BrowserWindow, ipcMain, dialog } = require("electron");
const path = require("path");
const fs = require("fs");
const { BackendClient } = require("./backend-client");
const { Settings } = require("./settings");
const { listFonts } = require("./fonts");

const EBOOK_EXTS = [
  "epub", "mobi", "azw", "azw3", "fb2", "lit", "lrf", "pdb", "rtf", "txt",
  "htmlz", "html", "cbz", "cbr", "cbc", "chm", "djvu", "docx", "odt", "prc",
  "pml", "rb", "snb", "tcr", "pdf",
];

let mainWindow = null;
let backend = null;
let settings = null;

/** Directory to seed a dialog with: the folder itself if `p` is one, else its parent. */
function dirOf(p) {
  try {
    return fs.statSync(p).isDirectory() ? p : path.dirname(p);
  } catch (e) {
    return path.dirname(p);
  }
}

/** Where to find/run the Python backend, differing between dev and a packaged build. */
function resolveBackendCommand() {
  if (app.isPackaged) {
    const binName = process.platform === "win32" ? "backend-server.exe" : "backend-server";
    return { command: path.join(process.resourcesPath, "backend", binName), args: [], cwd: undefined };
  }
  // Dev mode: run backend/server.py straight from the repo. Prefer the
  // project's venv Python so pymupdf/pillow/etc. resolve without the
  // developer having to activate it manually.
  const repoRoot = path.resolve(__dirname, "..", "..");
  const venvPython = path.join(
    repoRoot, ".venv", "bin", process.platform === "win32" ? "python.exe" : "python3");
  const python = fs.existsSync(venvPython) ? venvPython : "python3";
  return { command: python, args: ["-m", "backend.server"], cwd: repoRoot };
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 960,
    height: 720,
    show: false, // avoid a visible resize flash: show already-maximized
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });
  // Start filling the screen (maximized, with title bar/traffic-lights and
  // window controls still present) rather than OS fullscreen (which hides
  // those and takes over the whole display exclusively).
  mainWindow.once("ready-to-show", () => {
    mainWindow.maximize();
    mainWindow.show();
  });
  mainWindow.loadFile(path.join(__dirname, "..", "renderer", "index.html"));
}

function registerIpcHandlers() {
  ipcMain.handle("backend:call", (_event, { cmd, params }) => backend.call(cmd, params));

  ipcMain.handle("dialog:pick-inputs", async () => {
    const result = await dialog.showOpenDialog(mainWindow, {
      properties: ["openFile", "openDirectory", "multiSelections"],
      filters: [{ name: "Ebooks/PDF", extensions: EBOOK_EXTS }],
      defaultPath: settings.get("lastInputDir"),
    });
    if (result.canceled || result.filePaths.length === 0) return [];
    settings.set("lastInputDir", dirOf(result.filePaths[0]));
    return result.filePaths;
  });

  ipcMain.handle("dialog:pick-output-dir", async (_event, inputHintPath) => {
    // Prefer starting the browser at the current inputs' own folder (matches
    // the app's own "output/ next to each input" default) over a separately
    // remembered location, so the dialog reflects what's actually loaded.
    const defaultPath = (inputHintPath && dirOf(inputHintPath)) || settings.get("lastOutputDir");
    const result = await dialog.showOpenDialog(mainWindow, {
      properties: ["openDirectory", "createDirectory"],
      defaultPath,
    });
    if (result.canceled) return null;
    settings.set("lastOutputDir", result.filePaths[0]);
    return result.filePaths[0];
  });

  ipcMain.handle("fonts:list", () => listFonts());
}

app.whenReady().then(() => {
  settings = new Settings(app.getPath("userData"));
  const userConfigDir = path.join(app.getPath("userData"), "device-config");
  const { command, args, cwd } = resolveBackendCommand();
  backend = new BackendClient(command, [...args, "--user-config-dir", userConfigDir], cwd);
  backend.onProgress((msg) => {
    if (mainWindow) mainWindow.webContents.send("backend:progress", msg);
  });
  backend.start();

  registerIpcHandlers();
  createWindow();
  listFonts(); // kick off caching now so Settings opens instantly later

  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") app.quit();
});

app.on("before-quit", () => {
  if (backend) backend.stop();
});
