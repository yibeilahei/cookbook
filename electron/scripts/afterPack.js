// electron-builder afterPack hook: ad-hoc signs the macOS app bundle.
//
// The app is not signed with a paid Apple Developer ID, so without any
// signature at all, Gatekeeper reports downloaded builds as "damaged".
// Ad-hoc signing (codesign -s -) doesn't require an Apple account.
// Users should install via install.sh (curl does not quarantine); a
// browser-downloaded .app/.command will still be blocked by Gatekeeper.
const { execFileSync } = require("child_process");
const path = require("path");

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
};
