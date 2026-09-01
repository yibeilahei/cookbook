"use strict";

const { spawn } = require("child_process");
const readline = require("readline");

/**
 * Owns the Python backend child process and speaks its JSON-lines protocol
 * (see backend/server.py's module docstring). One BackendClient per running
 * app instance; started at app launch, stopped at quit (Model A: the
 * backend's lifecycle is tied to the Electron app's lifecycle).
 */
class BackendClient {
  constructor(command, args, cwd) {
    this.command = command;
    this.args = args;
    this.cwd = cwd;
    this.proc = null;
    this.nextId = 1;
    this.pending = new Map(); // id -> {resolve, reject}
    this.progressListeners = [];
  }

  start() {
    this.proc = spawn(this.command, this.args, {
      cwd: this.cwd,
      stdio: ["pipe", "pipe", "pipe"],
    });

    this.proc.on("error", (err) => {
      console.error("Backend failed to start:", err);
    });

    this.proc.on("exit", (code, signal) => {
      if (code !== 0) {
        console.error(`Backend exited unexpectedly (code=${code}, signal=${signal})`);
      }
      for (const { reject } of this.pending.values()) {
        reject(new Error("Backend process exited before responding"));
      }
      this.pending.clear();
    });

    const rl = readline.createInterface({ input: this.proc.stdout });
    rl.on("line", (line) => this._handleLine(line));

    // lib/common.py + lib/pdf2xtch.py print human-readable progress/log
    // lines; backend/server.py redirects those to stderr on purpose so they
    // never corrupt the stdout JSON protocol. Surface them for debugging.
    this.proc.stderr.on("data", (chunk) => {
      process.stderr.write(`[backend] ${chunk}`);
    });
  }

  _handleLine(line) {
    if (!line.trim()) return;
    let msg;
    try {
      msg = JSON.parse(line);
    } catch (e) {
      console.error("Backend sent a non-JSON line on stdout:", line);
      return;
    }
    if (msg.type === "progress" || msg.type === "batch") {
      for (const listener of this.progressListeners) listener(msg);
      return;
    }
    const pending = this.pending.get(msg.id);
    if (!pending) return;
    this.pending.delete(msg.id);
    if (msg.ok) pending.resolve(msg.result);
    else pending.reject(new Error(msg.error));
  }

  onProgress(listener) {
    this.progressListeners.push(listener);
  }

  call(cmd, params = {}) {
    if (!this.proc) return Promise.reject(new Error("Backend not started"));
    const id = this.nextId++;
    const request = { id, cmd, ...params };
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.proc.stdin.write(JSON.stringify(request) + "\n");
    });
  }

  /** Ask the backend to shut down gracefully, then force-kill if it doesn't. */
  stop() {
    if (!this.proc) return;
    this.call("shutdown").catch(() => {});
    const proc = this.proc;
    setTimeout(() => {
      if (proc && !proc.killed) proc.kill();
    }, 1000);
  }
}

module.exports = { BackendClient };
