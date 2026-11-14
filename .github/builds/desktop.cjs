const { build } = require("../../apps/desktop/package.json");
const productName = "BotONE Preview";
const defaultServerUrl = process.env.EXPO_PUBLIC_API_URL?.trim();
if (defaultServerUrl) {
  const url = new URL(defaultServerUrl);
  if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash) {
    throw new Error(
      "The desktop default server must be a public HTTPS address without credentials",
    );
  }
}

// An explicit null prevents electron-builder from inferring an upstream update feed.
module.exports = {
  ...build,
  productName,
  appId: "dev.botone.preview.desktop",
  extraMetadata: {
    ...build.extraMetadata,
    name: "botone-preview",
    productName,
    ...(defaultServerUrl ? { defaultServerUrl: new URL(defaultServerUrl).origin } : {}),
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
