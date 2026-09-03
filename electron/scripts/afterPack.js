// electron-builder afterPack hook for unsigned macOS builds.
//
// 1. Ad-hoc sign the .app (codesign -s -). Without any signature, Gatekeeper
//    reports a downloaded build as "damaged" and refuses to open it.
// 2. Drop Open Cookbook.command next to the .app and add it to the DMG.
//    That script strips the quarantine xattr so the first launch works
//    without a paid Developer ID. After that, Cookbook.app opens normally.
const { execFileSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const OPEN_COMMAND = "Open Cookbook.command";

module.exports = async function afterPack(context) {
  if (context.electronPlatformName !== "darwin") {
    return;
  }

  const appName = context.packager.appInfo.productFilename;
  const appPath = path.join(context.appOutDir, `${appName}.app`);

  console.log(`Ad-hoc signing ${appPath}`);
  execFileSync("codesign", ["--deep", "--force", "--sign", "-", appPath], {
    stdio: "inherit",
  });

  const launcherSrc = path.join(__dirname, "..", "..", "packaging", "launchers", OPEN_COMMAND);
  const launcherDest = path.join(context.appOutDir, OPEN_COMMAND);
  fs.copyFileSync(launcherSrc, launcherDest);
  fs.chmodSync(launcherDest, 0o755);

  // DmgTarget keeps a reference to config.dmg from startup, so mutating
  // contents here still applies when the DMG is assembled after afterPack.
  const dmg = context.packager.config.dmg;
  dmg.contents = [
    { x: 140, y: 150, path: appPath, type: "file", name: `${appName}.app` },
    { x: 400, y: 150, type: "link", path: "/Applications" },
    { x: 270, y: 340, path: launcherDest, type: "file", name: OPEN_COMMAND },
  ];
};
