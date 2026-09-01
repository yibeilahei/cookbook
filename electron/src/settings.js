"use strict";

const fs = require("fs");
const path = require("path");

/** Tiny persisted key/value store for UI preferences (e.g. "last folder used
 * in the Add files dialog"). Just a JSON file in Electron's userData dir --
 * this app has too few settings to justify a real settings library. */
class Settings {
  constructor(userDataDir) {
    this.filePath = path.join(userDataDir, "settings.json");
    this.data = this._load();
  }

  _load() {
    try {
      return JSON.parse(fs.readFileSync(this.filePath, "utf8"));
    } catch (e) {
      return {};
    }
  }

  get(key, fallback) {
    return Object.prototype.hasOwnProperty.call(this.data, key) ? this.data[key] : fallback;
  }

  set(key, value) {
    this.data[key] = value;
    try {
      fs.mkdirSync(path.dirname(this.filePath), { recursive: true });
      fs.writeFileSync(this.filePath, JSON.stringify(this.data, null, 2));
    } catch (e) {
      console.error("Failed to persist settings:", e);
    }
  }
}

module.exports = { Settings };
