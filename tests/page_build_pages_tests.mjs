import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const testDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(testDir, "..");
const builder = path.join(repoRoot, "page", "build-pages.mjs");

function buildPages(readme) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "rs-ci-pages-"));
  const projectRoot = path.join(tmp, "project");
  const outputDir = path.join(tmp, "public");
  fs.mkdirSync(projectRoot, { recursive: true });
  fs.writeFileSync(
    path.join(projectRoot, "Cargo.toml"),
    [
      "[package]",
      'name = "qubit-test"',
      'version = "0.1.0"',
      'description = "Test crate"',
      "",
    ].join("\n"),
  );
  fs.writeFileSync(path.join(projectRoot, "README.md"), readme);
  fs.writeFileSync(
    path.join(tmp, "coverage.json"),
    JSON.stringify({
      data: [
        {
          totals: {
            functions: { covered: 1, count: 1 },
            lines: { covered: 1, count: 1 },
            regions: { covered: 1, count: 1 },
          },
        },
      ],
    }),
  );

  execFileSync("node", [builder], {
    cwd: tmp,
    env: {
      ...process.env,
      RS_CI_PROJECT_ROOT: projectRoot,
      RS_CI_PAGES_OUTPUT: outputDir,
      COVERAGE_JSON: path.join(tmp, "coverage.json"),
    },
    stdio: "pipe",
  });

  return fs.readFileSync(path.join(outputDir, "index.html"), "utf8");
}

test("renders Markdown soft line breaks without preserving source wrapping", () => {
  const html = buildPages(`# Qubit Test

English text wraps in the source
but stays in one paragraph.

中文段落在源码中换行
渲染后不应插入空格。
`);

  assert.match(html, /<p>English text wraps in the source but stays in one paragraph\.<\/p>/);
  assert.match(html, /<p>中文段落在源码中换行渲染后不应插入空格。<\/p>/);
  assert.doesNotMatch(html, /中文段落在源码中换行 渲染后/);
});

test("keeps indented list continuation text in the same list item", () => {
  const html = buildPages(`# Qubit Test

- **Flexibility**: Exposes helpers and
  \`inner()\` for advanced users
- **Simplicity**: Keeps common cases free of explicit ordering
  parameters
`);

  assert.match(
    html,
    /<li><strong>Flexibility<\/strong>: Exposes helpers and <code>inner\(\)<\/code> for advanced users<\/li>/,
  );
  assert.match(
    html,
    /<li><strong>Simplicity<\/strong>: Keeps common cases free of explicit ordering parameters<\/li>/,
  );
  assert.doesNotMatch(html, /<ul>\s*<li>[\s\S]*<\/li>\s*<p>/);
});
