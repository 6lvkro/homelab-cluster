#!/usr/bin/env node
// renovate 패키지 매칭 목록에서 private 이미지명을 걷어낸다.
// 사용: sanitize-renovate.mjs <토큰파일> <플레이스홀더>
import { readFileSync, writeFileSync } from "node:fs";

const [tokenFile, placeholder] = process.argv.slice(2);

if (!tokenFile || !placeholder) {
  console.error("usage: sanitize-renovate.mjs <token-file> <placeholder>");
  process.exit(1);
}

const path = "renovate.json";

const tokens = readFileSync(tokenFile, "utf8")
  .split("\n")
  .map((t) => t.trim().toLowerCase())
  .filter(Boolean);

let removed = 0;

const text = readFileSync(path, "utf8").replace(
  /"(matchPackageNames|matchDepNames)":\s*\[([^\]]*)\]/g,
  (whole, key, body) => {
    const names = JSON.parse(`[${body}]`);
    const kept = names.filter((n) => !tokens.some((t) => n.toLowerCase().includes(t)));
    if (kept.length === names.length) return whole;

    removed += names.length - kept.length;
    const out = kept.length ? kept : [placeholder];
    return `"${key}": [${out.map((n) => JSON.stringify(n)).join(", ")}]`;
  },
);

if (!removed) {
  console.error(`ERROR: no private package name found in ${path} -- private markers may be stale`);
  process.exit(1);
}

writeFileSync(path, text);
