#!/usr/bin/env node
// 미러링 실패 이슈 생성

const TITLE = "미러링 중단: 퍼블릭 노출 검증 실패";

const REQUIRED = ["GITEA_TOKEN", "GITHUB_SERVER_URL", "GITHUB_REPOSITORY", "GITHUB_RUN_NUMBER", "GITHUB_SHA"];
const missing = REQUIRED.filter((k) => !process.env[k]);

if (missing.length) {
  console.error(`ERROR: missing env: ${missing.join(", ")}`);
  process.exit(1);
}

const { GITEA_TOKEN, GITHUB_SERVER_URL, GITHUB_REPOSITORY, GITHUB_RUN_NUMBER, GITHUB_SHA } = process.env;

const server = GITHUB_SERVER_URL.replace(/\/$/, "");
const api = `${server}/api/v1/repos/${GITHUB_REPOSITORY}`;
const headers = { Authorization: `token ${GITEA_TOKEN}` };

const request = async (url, init) => {
  const res = await fetch(url, init);
  if (!res.ok) {
    throw new Error(`${init?.method ?? "GET"} ${url} -> ${res.status} ${res.statusText}`);
  }
  return res;
};

const opened = await (await request(`${api}/issues?state=open&type=issues`, { headers })).json();

if (opened.some((issue) => issue.title === TITLE)) {
  console.log("열린 미러링 실패 이슈가 이미 있다, 생성 생략");
  process.exit(0);
}

const body = `\`mirror-public\` 워크플로우가 노출 검증에서 중단되어 퍼블릭 미러가 갱신되지 않았다.

- 실행: ${server}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_NUMBER}
- main: \`${GITHUB_SHA}\`

\`private\` 마커 누락 여부를 확인하고 수정한 뒤 워크플로우를 다시 실행할 것.
`;

await request(`${api}/issues`, {
  method: "POST",
  headers: { ...headers, "Content-Type": "application/json" },
  body: JSON.stringify({ title: TITLE, body }),
});

console.log("미러링 실패 이슈 생성됨");
