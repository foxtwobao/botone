import { hostDisabledFeatures } from "./host-policy.js";

export function safeHostConfiguration() {
  return {
    features: Object.fromEntries(hostDisabledFeatures.map((name) => [name, false])),
    notify: [],
    allow_login_shell: false,
    web_search: "disabled",
    mcp_servers: {},
  };
}
