#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";

const scriptDir = path.dirname(new URL(import.meta.url).pathname);
const projectRoot = process.env.RS_CI_PROJECT_ROOT
  ? path.resolve(process.env.RS_CI_PROJECT_ROOT)
  : process.cwd();
const outputDir = path.resolve(process.env.RS_CI_PAGES_OUTPUT || "public");
const defaultConfigPath = path.join(scriptDir, "default-config.json");
const projectConfigPath = path.join(projectRoot, ".rs-ci-page.json");
const layoutPath = path.join(scriptDir, "template", "layout.html");
const assetsDir = path.join(scriptDir, "template", "assets");

function readJson(filePath, fallback = {}) {
  if (!fs.existsSync(filePath)) {
    return fallback;
  }
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function mergeConfig(base, override) {
  if (Array.isArray(base) || Array.isArray(override)) {
    return override ?? base;
  }
  if (typeof base !== "object" || base === null || typeof override !== "object" || override === null) {
    return override ?? base;
  }
  const result = { ...base };
  for (const [key, value] of Object.entries(override)) {
    result[key] = mergeConfig(base[key], value);
  }
  return result;
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function escapeAttribute(value) {
  return escapeHtml(value).replaceAll("'", "&#39;");
}

function slugify(value) {
  return value
    .toLowerCase()
    .trim()
    .replace(/[^\p{L}\p{N}\s-]/gu, "")
    .replace(/\s+/g, "-")
    .replace(/-+/g, "-");
}

function renderInline(value) {
  let html = escapeHtml(value);
  html = html.replace(/!\[([^\]]*)\]\(([^)]+)\)/g, (_, alt, href) => {
    return `<img src="${escapeAttribute(href)}" alt="${escapeAttribute(alt)}">`;
  });
  html = html.replace(/\[([^\]]+)\]\(([^)]+)\)/g, (_, text, href) => {
    return `<a href="${escapeAttribute(href)}">${text}</a>`;
  });
  html = html.replace(/`([^`]+)`/g, "<code>$1</code>");
  html = html.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
  html = html.replace(/\*([^*]+)\*/g, "<em>$1</em>");
  return html;
}

function parseTable(lines, startIndex) {
  const headerLine = lines[startIndex];
  const separatorLine = lines[startIndex + 1] || "";
  if (!headerLine.trim().startsWith("|") || !/^\s*\|?[\s:-]+\|[\s|:-]*$/.test(separatorLine)) {
    return null;
  }

  const rows = [];
  let index = startIndex;
  while (index < lines.length && lines[index].trim().startsWith("|")) {
    rows.push(lines[index]);
    index += 1;
  }

  const split = (line) => line.trim().replace(/^\|/, "").replace(/\|$/, "").split("|").map((cell) => cell.trim());
  const headers = split(rows[0]);
  const bodyRows = rows.slice(2).map(split);
  const html = [
    "<table>",
    "<thead><tr>",
    ...headers.map((cell) => `<th>${renderInline(cell)}</th>`),
    "</tr></thead>",
    "<tbody>",
    ...bodyRows.map((row) => `<tr>${row.map((cell) => `<td>${renderInline(cell)}</td>`).join("")}</tr>`),
    "</tbody>",
    "</table>",
  ].join("");
  return { html, nextIndex: index };
}

function renderMarkdown(markdown) {
  const lines = markdown.replace(/\r\n/g, "\n").split("\n");
  const html = [];
  let paragraph = [];
  let listType = null;
  let inCode = false;
  let codeLanguage = "";
  let codeLines = [];

  const flushParagraph = () => {
    if (paragraph.length > 0) {
      html.push(`<p>${renderInline(paragraph.join(" "))}</p>`);
      paragraph = [];
    }
  };

  const closeList = () => {
    if (listType) {
      html.push(`</${listType}>`);
      listType = null;
    }
  };

  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    const trimmed = line.trim();

    if (trimmed.startsWith("```")) {
      if (inCode) {
        html.push(`<pre><code class="language-${escapeAttribute(codeLanguage)}">${escapeHtml(codeLines.join("\n"))}</code></pre>`);
        inCode = false;
        codeLanguage = "";
        codeLines = [];
      } else {
        flushParagraph();
        closeList();
        inCode = true;
        codeLanguage = trimmed.slice(3).trim();
      }
      continue;
    }

    if (inCode) {
      codeLines.push(line);
      continue;
    }

    if (trimmed === "") {
      flushParagraph();
      closeList();
      continue;
    }

    const table = parseTable(lines, index);
    if (table) {
      flushParagraph();
      closeList();
      html.push(table.html);
      index = table.nextIndex - 1;
      continue;
    }

    const heading = /^(#{1,6})\s+(.+)$/.exec(trimmed);
    if (heading) {
      flushParagraph();
      closeList();
      const level = heading[1].length;
      const text = heading[2].replace(/\s+#+$/, "");
      const id = slugify(text);
      html.push(`<h${level} id="${escapeAttribute(id)}">${renderInline(text)}</h${level}>`);
      continue;
    }

    const unordered = /^[-*]\s+(.+)$/.exec(trimmed);
    if (unordered) {
      flushParagraph();
      if (listType !== "ul") {
        closeList();
        listType = "ul";
        html.push("<ul>");
      }
      html.push(`<li>${renderInline(unordered[1])}</li>`);
      continue;
    }

    const ordered = /^\d+[.)]\s+(.+)$/.exec(trimmed);
    if (ordered) {
      flushParagraph();
      if (listType !== "ol") {
        closeList();
        listType = "ol";
        html.push("<ol>");
      }
      html.push(`<li>${renderInline(ordered[1])}</li>`);
      continue;
    }

    const quote = /^>\s*(.+)$/.exec(trimmed);
    if (quote) {
      flushParagraph();
      closeList();
      html.push(`<blockquote>${renderInline(quote[1])}</blockquote>`);
      continue;
    }

    paragraph.push(trimmed);
  }

  flushParagraph();
  closeList();
  if (inCode) {
    html.push(`<pre><code class="language-${escapeAttribute(codeLanguage)}">${escapeHtml(codeLines.join("\n"))}</code></pre>`);
  }
  return html.join("\n");
}

function parseCargoMetadata() {
  const cargoToml = path.join(projectRoot, "Cargo.toml");
  if (!fs.existsSync(cargoToml)) {
    return {};
  }
  const content = fs.readFileSync(cargoToml, "utf8");
  const packageSection = content.split(/\n\[/)[0];
  const pick = (key) => {
    const match = new RegExp(`^${key}\\s*=\\s*"([^"]+)"`, "m").exec(packageSection);
    return match?.[1] || null;
  };
  return {
    name: pick("name"),
    version: pick("version"),
    description: pick("description"),
  };
}

function computeCoverage() {
  const coverageJsonPath = process.env.COVERAGE_JSON || "coverage.json";
  if (!fs.existsSync(coverageJsonPath)) {
    return {
      functionsPercent: "n/a",
      linePercent: "n/a",
      regionsPercent: "n/a",
      linePercentNumber: 0,
      reportUrl: "coverage/",
    };
  }

  const coverage = readJson(coverageJsonPath, { data: [] });
  const totals = coverage.data.reduce(
    (acc, item) => {
      acc.functions.covered += item.totals?.functions?.covered || 0;
      acc.functions.count += item.totals?.functions?.count || 0;
      acc.lines.covered += item.totals?.lines?.covered || 0;
      acc.lines.count += item.totals?.lines?.count || 0;
      acc.regions.covered += item.totals?.regions?.covered || 0;
      acc.regions.count += item.totals?.regions?.count || 0;
      return acc;
    },
    {
      functions: { covered: 0, count: 0 },
      lines: { covered: 0, count: 0 },
      regions: { covered: 0, count: 0 },
    },
  );

  const format = (metric) => {
    if (metric.count === 0) {
      return "n/a";
    }
    return `${((metric.covered * 100) / metric.count).toFixed(2)}%`;
  };

  return {
    functionsPercent: format(totals.functions),
    linePercent: format(totals.lines),
    regionsPercent: format(totals.regions),
    linePercentNumber: totals.lines.count === 0 ? 0 : (totals.lines.covered * 100) / totals.lines.count,
    reportUrl: "coverage/",
  };
}

function badgeColor(percent) {
  if (percent >= 90) return "brightgreen";
  if (percent >= 80) return "green";
  if (percent >= 70) return "yellowgreen";
  if (percent >= 60) return "orange";
  return "red";
}

function replaceTemplate(template, values) {
  return template.replace(/\{\{\{([^}]+)}}}|\{\{([^}]+)}}/g, (match, rawKey, escapedKey) => {
    const key = rawKey || escapedKey;
    const raw = Boolean(rawKey);
    const value = key.trim().split(".").reduce((current, part) => current?.[part], values) ?? "";
    return raw ? String(value) : escapeHtml(value);
  });
}

function relativePrefix(outputPath) {
  const depth = outputPath.split("/").length - 1;
  return depth === 0 ? "" : "../".repeat(depth);
}

function buildLanguageLinks(languages, currentCode, prefix) {
  return Object.entries(languages)
    .map(([code, language]) => {
      const href = language.output.endsWith("index.html")
        ? language.output.replace(/index\.html$/, "")
        : language.output;
      const label = language.label || code;
      const aria = code === currentCode ? ' aria-current="page"' : "";
      return `<a href="${escapeAttribute(`${prefix}${href || "index.html"}`)}"${aria}>${escapeHtml(label)}</a>`;
    })
    .join("");
}

function copyIfExists(source, destination) {
  if (fs.existsSync(source)) {
    fs.cpSync(source, destination, { recursive: true });
  }
}

const defaultConfig = readJson(defaultConfigPath);
const projectConfig = readJson(projectConfigPath);
const config = mergeConfig(defaultConfig, projectConfig);
const cargo = parseCargoMetadata();
const repository = process.env.GITHUB_REPOSITORY || "";
const [owner, repo] = repository.split("/");
const siteTitle = config.siteTitle || cargo.name || repo || path.basename(projectRoot);
const siteDescription = cargo.description || `Documentation and CI reports for ${siteTitle}.`;
const githubUrl = repository ? `https://github.com/${repository}` : "";
const runUrl = repository && process.env.GITHUB_RUN_ID
  ? `${githubUrl}/actions/runs/${process.env.GITHUB_RUN_ID}`
  : githubUrl;
const sha = process.env.GITHUB_SHA || "";
const shortSha = sha ? sha.slice(0, 8) : "local";
const coverage = computeCoverage();

fs.rmSync(outputDir, { recursive: true, force: true });
fs.mkdirSync(outputDir, { recursive: true });
fs.mkdirSync(path.join(outputDir, "assets"), { recursive: true });
copyIfExists(assetsDir, path.join(outputDir, "assets"));

const coverageHtmlDir = process.env.COVERAGE_HTML_DIR || "target/llvm-cov/html";
copyIfExists(coverageHtmlDir, path.join(outputDir, "coverage"));

const coverageBadge = {
  schemaVersion: 1,
  label: "coverage",
  message: coverage.linePercent,
  color: badgeColor(coverage.linePercentNumber),
};
fs.writeFileSync(path.join(outputDir, "coverage-badge.json"), `${JSON.stringify(coverageBadge, null, 2)}\n`);

const ciSummary = {
  repository,
  runUrl,
  commit: sha,
  branch: process.env.GITHUB_REF_NAME || "",
  coverage,
  generatedAt: new Date().toISOString(),
};
fs.writeFileSync(path.join(outputDir, "ci-summary.json"), `${JSON.stringify(ciSummary, null, 2)}\n`);

const layout = fs.readFileSync(layoutPath, "utf8");
const languages = config.languages || {};
for (const [code, language] of Object.entries(languages)) {
  const readmePath = path.join(projectRoot, language.readme);
  if (!fs.existsSync(readmePath)) {
    continue;
  }

  const outputPath = language.output || `${code}/index.html`;
  const outputFile = path.join(outputDir, outputPath);
  const prefix = relativePrefix(outputPath);
  const readmeHtml = renderMarkdown(fs.readFileSync(readmePath, "utf8"));
  const coveragePanel = config.sections?.coverage === false
    ? ""
    : `<section class="coverage-panel">
        <div>
          <h2>Coverage report</h2>
          <p>Line coverage ${escapeHtml(coverage.linePercent)}, functions ${escapeHtml(coverage.functionsPercent)}, regions ${escapeHtml(coverage.regionsPercent)}.</p>
        </div>
        <div class="coverage-actions">
          <a class="button" href="${prefix}coverage/">Open coverage</a>
          <a class="button secondary" href="${prefix}coverage-badge.json">Badge JSON</a>
        </div>
      </section>`;
  const values = {
    site: {
      title: siteTitle,
      description: siteDescription,
      githubUrl,
    },
    page: {
      title: `${siteTitle} - ${language.label || code}`,
    },
    language: {
      code,
      links: buildLanguageLinks(languages, code, prefix),
    },
    readme: {
      html: readmeHtml,
    },
    coverage: {
      linePercent: coverage.linePercent,
      navLink: config.sections?.coverage === false ? "" : `<a href="${prefix}coverage/">Coverage</a>`,
      panel: coveragePanel,
    },
    ci: {
      runUrl,
      runLabel: process.env.GITHUB_RUN_ID ? `#${process.env.GITHUB_RUN_ID}` : "local",
      commitUrl: sha && githubUrl ? `${githubUrl}/commit/${sha}` : githubUrl,
      shortSha,
      updatedAt: new Date().toISOString(),
    },
    basePrefix: prefix,
    assetPrefix: prefix,
  };

  fs.mkdirSync(path.dirname(outputFile), { recursive: true });
  fs.writeFileSync(outputFile, replaceTemplate(layout, values));
}

console.log(`Pages site generated at ${outputDir}`);
