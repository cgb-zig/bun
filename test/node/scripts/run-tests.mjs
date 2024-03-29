import { spawnSync } from "node:child_process";
import { appendFileSync, readFileSync, readdirSync, writeFileSync } from "node:fs";

const testPath = new URL("../", import.meta.url);
const runtime = process.isBun ? process.execPath : "bun";
const bail = process.argv.includes("--bail");
const [skip] = process.argv.filter(arg => arg.startsWith("--skip=")).map(arg => arg.slice("--skip=".length));

function runTests() {
  let total = 0;
  let pass = 0;
  let fail = 0;

  const tests = JSON.parse(readFileSync(new URL("tests.json", testPath), "utf8"));
  for (const { group: path, skippedTests = [] } of tests) {
    for (const file of readdirSync(new URL(path, testPath)).sort()) {
      total++;
      if (skippedTests.some(({ test }) => file.endsWith(test)) || (skip && total <= parseInt(skip))) {
        continue;
      }

      console.log();
      const { pathname: argPath } = new URL(`${path}/${file}`, testPath);
      const { status, error } = spawnSync(runtime, ["test", argPath], {
        cwd: testPath,
        stdio: "inherit",
      });

      if (error || status !== 0) {
        fail++;
        if (bail) {
          return;
        }
      } else {
        pass++;
      }
    }
  }

  const summaryPath = new URL("summary.json", testPath);
  const summaryOld = JSON.parse(readFileSync(summaryPath, "utf8"));
  const summary = {
    ...summaryOld,
    pass,
    fail,
    percent: +((pass / summaryOld.total) * 100).toFixed(2),
  };
  writeFileSync(summaryPath, JSON.stringify(summary, null, 2));

  console.log();
  console.log("======= Summary =======");
  console.log("Node.js tests:", summary.total);
  console.log("Passed:", summary.pass);
  console.log("Failed:", summary.fail);
  console.log("Percent:", summary.percent, "%");
  console.log("=======================");

  const markdownPath = process.env["GITHUB_STEP_SUMMARY"];
  if (markdownPath) {
    const markdown = `## Node.js Tests

| Total tests | Passed tests | Failed tests | Percentage |
|-------|--------|--------|---------|
| ${summary.total} | ${summary.pass} | ${summary.fail} | ${summary.percent}% |
    `;
    appendFileSync(markdownPath, markdown);
  }
}

runTests();
