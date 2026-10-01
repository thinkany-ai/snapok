// Upload endpoint for the snapok R2 bucket (served publicly at https://cdn.snapok.app).
// CI holds no Cloudflare credentials: it PUTs build output here with a bearer token,
// and this Worker writes it through its R2 binding. Reads go through the public CDN, not here.
//
//   PUT /<key>   Authorization: Bearer <UPLOAD_TOKEN>
//                Content-Type: <type>    X-Cache-Control: <cache-control>
const KEY = /^(dev\/)?[A-Za-z0-9][A-Za-z0-9._-]*$/;

export default {
  async fetch(request, env) {
    if (request.method !== "PUT") return new Response("Method Not Allowed", { status: 405 });
    if (!env.UPLOAD_TOKEN || !(await sameToken(request.headers.get("Authorization") ?? "", `Bearer ${env.UPLOAD_TOKEN}`))) {
      return new Response("Unauthorized", { status: 401 });
    }
    const key = decodeURIComponent(new URL(request.url).pathname.slice(1));
    if (!KEY.test(key)) return new Response("Invalid key", { status: 400 });
    if (!request.body) return new Response("Empty body", { status: 400 });

    const object = await env.BUCKET.put(key, request.body, {
      httpMetadata: {
        contentType: request.headers.get("Content-Type") ?? "application/octet-stream",
        cacheControl: request.headers.get("X-Cache-Control") ?? undefined,
      },
    });
    return Response.json({ key, size: object.size, etag: object.etag });
  },
};

async function sameToken(a, b) {
  const [x, y] = await Promise.all([a, b].map((s) => crypto.subtle.digest("SHA-256", new TextEncoder().encode(s))));
  return crypto.subtle.timingSafeEqual(x, y);
}
