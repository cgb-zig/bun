import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { basename, extname } from "node:path";

const testPath = new URL("../", import.meta.url);
const nodePath = new URL("node/", testPath);
const nodeTestPath = new URL("test/", nodePath);

function addTests() {
  if (!existsSync(nodePath)) {
    spawnSync(
      "git",
      ["submodule", "update", "--init", "--recursive", "--progress", "--depth=1", "--checkout", "test/node/node"],
      {
        cwd: new URL("../../", testPath),
        stdio: "inherit",
      },
    );
  }

  const tests = JSON.parse(readFileSync(new URL("tests.json", testPath)));

  let total = 0;
  let ignored = 0;
  let added = 0;
  for (const entry of readdirSync(nodeTestPath, { recursive: true, withFileTypes: true })) {
    const { name } = entry;
    let filename = basename(name);

    if (!entry.isFile() || !isJavaScript(filename)) {
      continue;
    }

    let groupMatch;
    let groupPrefix;
    for (const { group, prefix, ignoredTests = [] } of tests) {
      if (name.startsWith(prefix) && !ignoredTests.some(test => filename === test)) {
        groupMatch = group;
        groupPrefix = prefix;
        break;
      }
    }

    total++;
    if (!groupMatch) {
      ignored++;
      continue;
    }
    added++;

    const srcPath = new URL(name, nodeTestPath);
    const ext = extname(filename);
    if (groupPrefix === basename(filename, ext)) {
      filename = `${group}.${ext}`;
    } else {
      filename = filename.slice(basename(groupPrefix).length + 1);
    }

    const dst = `${groupMatch}/${filename}`;
    const dstPath = new URL(dst, testPath);

    const { status, error, stderr, stdout } = spawnSync("bunx", ["prettier", "--stdin", "--parser=babel"], {
      // HACK: Replace `assert` with `assert.ok` because `mock.module`
      //       does not preserve the default `assert` function.
      input: readFileSync(srcPath, "utf8").replace(/assert\(/g, "assert.ok("),
      encoding: "utf8",
    });

    if (error || status !== 0) {
      throw error || new Error(stderr);
    }

    try {
      writeFileSync(dstPath, stdout);
    } catch (error) {
      if (error.code === "ENOENT") {
        mkdirSync(new URL(".", dstPath), { recursive: true });
        writeFileSync(dstPath, stdout);
      } else {
        throw error;
      }
    }

    console.log("+", dst);
  }

  console.log();
  console.log("======= Summary =======");
  console.log("Total tests:", total);
  console.log("Ignored tests:", ignored);
  console.log("Added tests:", added);
  console.log("Added percentage:", +((added / total) * 100).toFixed(2), "%");
  console.log("=======================");

  const summary = {
    total,
  };
  writeFileSync(new URL("summary.json", testPath), JSON.stringify(summary, null, 2));
}

function isJavaScript(filename) {
  return /\.(m|c)?js$/.test(filename);
}

addTests();
