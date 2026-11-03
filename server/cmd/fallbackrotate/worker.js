// A fallback address for the Relay API. Passes every request (and the
// WebSocket upgrade) through to the relay unchanged. Messages are end-to-end
// encrypted and requests carry their own signatures, so this sees nothing that
// Cloudflare doesn't already see for api.relaymsg.app.
const RELAY = "api.relaymsg.app";

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    url.protocol = "https:";
    url.hostname = RELAY;
    url.port = "";

    const headers = new Headers(request.headers);
    // Who the request is really from, vouched for by the shared secret, so
    // the relay's per-address limits don't lump everyone here together.
    headers.set("X-Relay-Client-IP", request.headers.get("CF-Connecting-IP") || "");
    headers.set("X-Relay-Fallback-Key", env.FALLBACK_KEY || "");

    return fetch(new Request(url.toString(), {
      method: request.method,
      headers,
      body: request.body,
      redirect: "manual",
    }));
  },
};
