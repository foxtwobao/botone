const { build } = require("../../apps/desktop/package.json");
const productName = "BotONE Preview";

// An explicit null prevents electron-builder from inferring an upstream update feed.
module.exports = {
  ...build,
  productName,
  appId: "dev.botone.preview.desktop",
  extraMetadata: {
    ...build.extraMetadata,
    name: "botone-preview",
    productName,
  },
  publish: null,
  forceCodeSigning: false,
  mac: {
    ...build.mac,
    identity: "-",
    notarize: false,
    extraResources: build.mac.extraResources.filter(
      (resource) => resource.to !== "server-bundle.json",
    ),
  },
};
