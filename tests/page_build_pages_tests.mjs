import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const testDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(testDir, "..");
const builder = path.join(repoRoot, "page", "build-pages.mjs");

function buildPagesResult(readme, infraConfig, legacyConfig) {
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
  if (infraConfig) {
    fs.mkdirSync(path.join(projectRoot, ".infra", "ci"), { recursive: true });
    fs.writeFileSync(path.join(projectRoot, ".infra", "ci", "pages.json"), JSON.stringify(infraConfig));
  }
  if (legacyConfig) {
    fs.writeFileSync(path.join(projectRoot, ".rs-ci-page.json"), JSON.stringify(legacyConfig));
  }
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

  const result = spawnSync("node", [builder], {
    cwd: tmp,
    env: {
      ...process.env,
      RS_CI_PROJECT_ROOT: projectRoot,
      RS_CI_PAGES_OUTPUT: outputDir,
      COVERAGE_JSON: path.join(tmp, "coverage.json"),
    },
    stdio: "pipe",
  });

  assert.equal(result.status, 0, result.stderr?.toString());
  return {
    html: fs.readFileSync(path.join(outputDir, "index.html"), "utf8"),
    stderr: result.stderr.toString(),
  };
}

function buildPages(readme) {
  return buildPagesResult(readme).html;
}

test("prefers .infra/ci/pages.json over legacy page settings", () => {
  const result = buildPagesResult("# Demo", { siteTitle: "Infra title" }, { siteTitle: "Legacy title" });
  assert.match(result.html, /Infra title/);
  assert.doesNotMatch(result.html, /Legacy title/);
});

test("warns when legacy page settings are used", () => {
  const result = buildPagesResult("# Demo", undefined, { siteTitle: "Legacy title" });
  assert.match(result.html, /Legacy title/);
  assert.match(result.stderr, /\.infra\/ci\/pages\.json/);
});

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
