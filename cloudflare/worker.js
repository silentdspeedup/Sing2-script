// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sing2 分发网关。R2 桶本身**不开公开访问**（r2.dev 保持关闭），唯一出口是这个
// Worker —— 它跑在 Cloudflare 免费分配的 *.workers.dev 子域上，通过 R2 binding
// 读桶，并校验共享密钥。方案与理由见 Sing2 仓库 doc/16。
//
// 为什么不是 r2.dev 直接开公开访问：那是个不带任何策略层的裸公开读端点，
// Cloudflare 文档明写「要启用访问管理，必须设置自定义域名」。本方案不使用自有
// 域名，所以校验只能落在 Worker 里。同一份文档还提示：若日后改用自定义域名 +
// WAF/Access，**必须同时关闭 r2.dev**，否则那个子域仍然直通。
//
// 部署（一次性，控制台即可，不进 CI —— 这段代码几乎不会再变，接进流水线只会多
// 一处需要维护的凭据）：
//   1. Workers & Pages → 新建 Worker，粘贴本文件
//   2. Settings → Bindings → R2 bucket，变量名 BUCKET，指向 sing2-dist
//   3. Settings → Variables and Secrets → Secret DIST_KEY = openssl rand -hex 32
//   4. 确认 R2 桶的 Public access（r2.dev）保持关闭
//
// 轮换密钥时加一个 DIST_KEY_NEXT，两把同时受理，节点换完再把 DIST_KEY 改成新值
// 并删掉 DIST_KEY_NEXT —— 无停机。

// 路径白名单。桶里日后放了别的东西，这个 Worker 也不会变成一个通用的桶代理。
const ALLOW = /^(latest|v\d+\.\d+\.\d+\/Sing2-[A-Za-z0-9._-]+\.zip(\.dgst)?)$/;

export default {
  async fetch(request, env) {
    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response(null, { status: 405 });
    }

    const key = new URL(request.url).pathname.slice(1);

    // 路径不合法、密钥不对、对象不存在——**一律 404**，不作区分。端点地址会出现
    // 在公开的 install.sh 里，返回 401/403 等于向探测者确认「这里确实有东西」。
    if (!ALLOW.test(key)) return new Response(null, { status: 404 });
    if (!authorized(request, env)) return new Response(null, { status: 404 });

    const object = await env.BUCKET.get(key);
    if (object === null) return new Response(null, { status: 404 });

    const headers = new Headers();
    object.writeHttpMetadata(headers);
    headers.set("etag", object.httpEtag);

    // 刻意不做 Range 与条件请求：install.sh 用的是 `curl --retry 3`，本来就是整包
    // 重试而非续传，加 Range 只增加出错面。
    return new Response(request.method === "HEAD" ? null : object.body, { headers });
  },
};

function authorized(request, env) {
  // 头部值由 HTTP 层保证不带首尾空白；secret 侧则**必须** trim ——在控制台粘贴
  // 密钥时很容易带进一个尾换行，那会让长度从 64 变成 65、下面的长度比较直接不等，
  // 于是一切请求都返回 404。而 secret 的值不回显，这个错在控制台里完全看不出来，
  // 排查时的表现和"密钥打错了"一模一样。
  const got = request.headers.get("x-sing2-key") || "";
  for (const raw of [env.DIST_KEY, env.DIST_KEY_NEXT]) {
    const expected = (raw || "").trim();
    if (!expected) continue;
    // timingSafeEqual 对长度不等会抛异常，所以先比长度。密钥长度是固定且公开的
    // （openssl rand -hex 32 → 64 字符），泄露它不构成信息增益。
    if (got.length !== expected.length) continue;
    const enc = new TextEncoder();
    if (crypto.subtle.timingSafeEqual(enc.encode(got), enc.encode(expected))) {
      return true;
    }
  }
  return false;
}
