import { parseArgs } from "node:util";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync, appendFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import readline from "node:readline/promises";

const testPath = new URL("./", import.meta.url);
const nodePath = new URL("node/", testPath);
const nodeTestPath = new URL("test/", nodePath);
const metadataScriptPath = new URL("metadata.mjs", testPath);
const testJsonPath = new URL("tests.json", testPath);
const summariesPath = new URL("summary/", testPath);
const summaryMdPath = new URL("summary.md", testPath);
const cwd = new URL("../../", testPath);

async function main() {
  const { values, positionals } = parseArgs({
    options: {
      help: {
        type: "boolean",
        short: "h",
      },
      baseline: {
        type: "boolean",
      },
      interactive: {
        type: "boolean",
        short: "i",
      },
      jobs: {
        type: "string",
        short: "j",
      },
      "exec-path": {
        type: "string",
      },
      pull: {
        type: "boolean",
      },
      summary: {
        type: "boolean",
      },
    },
  });

  if (values.help) {
    printHelp();
    return;
  }

  if (values.summary) {
    printSummary();
    return;
  }

  pullTests(values.pull);
  const summary = await runTests(values);
  appendSummary(summary);
}

function printHelp() {
  console.log(`Usage: ${process.argv0} ${basename(import.meta.filename)} [options]`);
  console.log();
  console.log("Options:");
  console.log("  -h, --help      Show this help message");
  console.log("  -v, --verbose   Show verbose output");
  console.log("  -e, --exec-path Path to the executable to run");
}

function pullTests(force) {
  if (!force && existsSync(nodeTestPath)) {
    return;
  }

  const { status, error, stderr } = spawnSync(
    "git",
    ["submodule", "update", "--init", "--recursive", "--progress", "--depth=1", "--checkout", "test/node/node"],
    {
      cwd,
      stdio: "inherit",
    },
  );

  if (error || status !== 0) {
    throw error || new Error(stderr);
  }

  for (const { filename, status } of getTests(nodeTestPath)) {
    if (status === "TODO") {
      continue;
    }

    const src = new URL(filename, nodeTestPath);
    const dst = new URL(filename, testPath);

    try {
      writeFileSync(dst, readFileSync(src));
    } catch (error) {
      if (error.code === "ENOENT") {
        mkdirSync(new URL(".", dst), { recursive: true });
        writeFileSync(dst, readFileSync(src));
      } else {
        throw error;
      }
    }
  }
}

async function runTests(options) {
  const { interactive } = options;
  const bunPath = process.isBun ? process.execPath : "bun";
  const execPath = options["exec-path"] || bunPath;

  let reader;
  if (interactive) {
    reader = readline.createInterface({
      input: process.stdin,
      output: process.stdout,
    });
  }

  const results = [];
  const tests = getTests(testPath);
  for (const { filename, status: filter } of tests) {
    if (filter !== "OK") {
      results.push({ filename, status: filter });
      continue;
    }

    const { pathname: filePath } = new URL(filename, testPath);
    const tmp = mkdtempSync(join(tmpdir(), "bun-"));
    const timestamp = performance.now();
    const {
      status: exitCode,
      signal: signalCode,
      error: spawnError,
    } = spawnSync(execPath, ["test", filePath], {
      cwd: testPath,
      stdio: "inherit",
      env: {
        PATH: process.env.PATH,
        HOME: tmp,
        TMPDIR: tmp,
        TZ: "Etc/UTC",
        FORCE_COLOR: "1",
        BUN_DEBUG_QUIET_LOGS: "1",
        BUN_GARBAGE_COLLECTOR_LEVEL: "1",
        BUN_RUNTIME_TRANSPILER_CACHE_PATH: "0",
        GITHUB_ACTIONS: "false", // disable for now
      },
      timeout: 15_000,
    });

    const duration = performance.now() - timestamp;
    const status = exitCode === 0 ? "PASS" : "FAIL";
    let error;
    if (signalCode) {
      error = signalCode;
    } else if (spawnError) {
      const { message } = spawnError;
      if (message.includes("timed out") || message.includes("timeout")) {
        error = "TIMEOUT";
      } else {
        error = message;
      }
    } else if (exitCode !== 0) {
      error = `code ${exitCode}`;
    }
    results.push({ filename, status, error, duration });

    if (reader && status === "FAIL") {
      const answer = await reader.question("Continue? [Y/n] ");
      if (answer.toUpperCase() !== "Y") {
        break;
      }
    }
  }

  reader?.close();
  return {
    v: 1,
    metadata: getMetadata(execPath),
    tests: results,
  };
}

function getTests(filePath) {
  const tests = [];
  const testData = JSON.parse(readFileSync(testJsonPath, "utf8"));

  for (const filename of readdirSync(filePath, { recursive: true })) {
    if (!isJavaScript(filename) || !isTest(filename)) {
      continue;
    }

    let match;
    for (const { pattern, skip: skipList = [], todo: todoList = [] } of testData) {
      if (!filename.startsWith(pattern)) {
        continue;
      }

      if (skipList.some(({ file }) => filename.endsWith(file))) {
        tests.push({ filename, status: "SKIP" });
      } else if (todoList.some(({ file }) => filename.endsWith(file))) {
        tests.push({ filename, status: "TODO" });
      } else {
        tests.push({ filename, status: "OK" });
      }

      match = true;
      break;
    }

    if (!match) {
      tests.push({ filename, status: "TODO" });
    }
  }

  return tests;
}

function appendSummary(summary) {
  const { metadata } = summary;
  const { name } = metadata;
  const summaryPath = new URL(`${name}.json`, summariesPath);
  const summaryData = JSON.stringify(summary, null, 2);

  try {
    writeFileSync(summaryPath, summaryData);
  } catch (error) {
    if (error.code === "ENOENT") {
      mkdirSync(summariesPath, { recursive: true });
      writeFileSync(summaryPath, summaryData);
    } else {
      throw error;
    }
  }
}

function printSummary() {
  let info = {};
  let counts = {};
  let errors = {};

  for (const filename of readdirSync(summariesPath)) {
    if (!filename.endsWith(".json")) {
      continue;
    }

    const summaryPath = new URL(filename, summariesPath);
    const summaryData = JSON.parse(readFileSync(summaryPath, "utf8"));
    const { v, metadata, tests } = summaryData;
    if (v !== 1) {
      continue;
    }

    const { name, version, revision } = metadata;
    info[name] = `${version} [\`${revision?.slice(0, 7)}\`](https://github.com/oven-sh/bun/commit/${revision})`;

    for (const test of tests) {
      const { filename, status, error } = test;
      counts[name] ||= { pass: 0, fail: 0, skip: 0, todo: 0, total: 0 };
      counts[name][status.toLowerCase()] += 1;
      counts[name].total += 1;
      if (status === "FAIL") {
        errors[filename] ||= {};
        errors[filename][name] = error;
      }
    }
  }

  let markdown = `## Node.js tests

| Platform | Coverage | Passed | Failed | Skipped | Total |
| - | - | - | - | - | - |
`;

  for (const [name, { pass, fail, skip, total }] of Object.entries(counts)) {
    const conformance = ((pass / total) * 100).toFixed(2);
    const coverage = (((pass + fail + skip) / total) * 100).toFixed(2);
    markdown += `| \`${name}\` ${info[name]} | ${coverage} % | ${pass} | ${fail} | ${skip} | ${total} |\n`;
  }

  writeFileSync(summaryMdPath, markdown);
  const githubSummaryPath = process.env.GITHUB_STEP_SUMMARY;
  if (githubSummaryPath) {
    appendFileSync(githubSummaryPath, markdown);
  }
}

function isJavaScript(filename) {
  return /\.(m|c)?js$/.test(filename);
}

function isTest(filename) {
  return /^test-/.test(basename(filename));
}

function getMetadata(execPath) {
  const { pathname: filePath } = metadataScriptPath;
  const { status: exitCode, stdout } = spawnSync(execPath, [filePath], {
    cwd,
    stdio: ["ignore", "pipe", "ignore"],
    env: {
      PATH: process.env.PATH,
      BUN_DEBUG_QUIET_LOGS: "1",
    },
  });

  if (exitCode === 0) {
    try {
      return JSON.parse(stdout);
    } catch {
      // Ignore
    }
  }

  return {
    os: process.platform,
    arch: process.arch,
  };
}

main().catch(error => {
  console.error(error);
  process.exit(1);
});
