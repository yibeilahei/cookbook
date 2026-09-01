"use strict";

const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("backend", {
  call: (cmd, params) => ipcRenderer.invoke("backend:call", { cmd, params }),
  onProgress: (callback) => {
    const listener = (_event, msg) => callback(msg);
    ipcRenderer.on("backend:progress", listener);
    return () => ipcRenderer.removeListener("backend:progress", listener);
  },
});

contextBridge.exposeInMainWorld("dialogs", {
  pickInputs: () => ipcRenderer.invoke("dialog:pick-inputs"),
  pickOutputDir: (inputHintPath) => ipcRenderer.invoke("dialog:pick-output-dir", inputHintPath),
});

contextBridge.exposeInMainWorld("fontsApi", {
  list: () => ipcRenderer.invoke("fonts:list"),
});

// So the renderer can show/edit the right fonts.<os> table without needing
// its own OS-sniffing (and without Node access, since nodeIntegration is off).
contextBridge.exposeInMainWorld("platform", {
  fontsKey: process.platform === "win32" ? "windows" : "macos",
});
