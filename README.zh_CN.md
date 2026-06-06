# Rust CI 脚本

[English](README.md)

用于在 CI 中检查 Rust 代码的共享脚本和 CircleCI/GitHub Actions 配置。

## 文件

- `align-ci.sh`：本地自动修复脚本，用于格式化代码并运行 clippy。
- `ci-check.sh`：本地完整 CI 等价检查脚本。
- `cargo-env.sh`：本地入口脚本共用的 Cargo 环境设置。
- `update-submodule.sh`：本地 submodule 同步脚本，默认从远程跟踪分支更新 submodule。
- `cargo-feature-check.sh`：可选的项目声明式 Cargo feature matrix 运行器。
- `cargo-package-check.sh`：运行 `cargo package --allow-dirty` 的本地打包验证脚本。
- `readme-version-check.py`：README 依赖片段检查脚本，要求当前 crate 使用 `major.minor` 版本。
- `style-check.sh`：检查 rustfmt 和 clippy 不覆盖的 Rust 源码布局约束。
- `coverage.sh`：本地覆盖率报告生成和阈值检查脚本。
- `page/`：可复用的 GitHub Pages 构建器、模板、样式和默认配置。
- `rustfmt.toml`：本地脚本和 CI 使用的共享 rustfmt 配置。
- `.circleci/config.yml`：优化后的 CircleCI 模板。
- `.github/workflows/rust-ci.yml`：可复用的 GitHub Actions workflow。

## 推荐接入方式

把这些文件复制到 Rust 项目根目录：

```bash
command cp align-ci.sh ci-check.sh cargo-env.sh update-submodule.sh cargo-feature-check.sh cargo-package-check.sh readme-version-check.py style-check.sh coverage.sh rustfmt.toml <project-root>/
command cp .circleci/config.yml <project-root>/.circleci/config.yml
```

然后执行：

```bash
cd <project-root>
chmod +x align-ci.sh ci-check.sh update-submodule.sh cargo-feature-check.sh cargo-package-check.sh readme-version-check.py style-check.sh coverage.sh
./style-check.sh
./ci-check.sh
```

如果使用 GitHub Actions，保留本仓库作为 `.rs-ci` submodule，并在 Rust
项目中添加这个 workflow：

```bash
mkdir -p .github/workflows
cat > .github/workflows/ci.yml <<'YAML'
name: Rust CI

on:
  push:
  pull_request:
  workflow_dispatch:
  schedule:
    - cron: "0 0 * * *"

permissions:
  contents: read
  pull-requests: write
  pages: write
  id-token: write

jobs:
  rust-ci:
    uses: qubit-ltd/rs-ci/.github/workflows/rust-ci.yml@main
YAML
```

在 Rust 项目的 README 中加入 CI 和 coverage badge：

```markdown
[![Rust CI](https://github.com/<owner>/<repo>/actions/workflows/ci.yml/badge.svg)](https://github.com/<owner>/<repo>/actions/workflows/ci.yml)
![Coverage](https://img.shields.io/endpoint?url=https://<owner>.github.io/<repo>/coverage-badge.json)
```

## GitHub Actions 覆盖率输出

可复用 workflow 保留现有格式化、clippy、debug build、doc test、README 依赖版本、
test、release build、文档、打包验证、审计和 Windows 检查。覆盖率通过 `coverage.sh all` 生成，工具是
`cargo-llvm-cov`，由 `taiki-e/install-action` 安装。CI 中设置
`COVERAGE_ENFORCE_THRESHOLDS=0`，初始接入阶段只报告覆盖率，不因阈值失败。
覆盖率发布只使用 GitHub Actions summary、comment 和 artifact，不需要 Codecov 或
Coveralls token。

调用方 workflow 使用 `push`、`pull_request` 或 `workflow_dispatch` 触发时，
coverage job 会写出 `lcov.info`、`target/llvm-cov/html` 下的 HTML 报告、
`coverage-badge.json` 和 Markdown summary。这些文件会上传到
`coverage-reports` artifact，同一份摘要也会写入 GitHub Actions job summary。

同仓库 pull request 在 `GITHUB_TOKEN` 具备 `pull-requests: write` 权限时会收到
可更新的 coverage comment。来自 fork 的 PR 或受限 token 仍保留 job summary 和
artifact，comment 步骤不会阻塞 CI。

workflow 不会自动提交生成的覆盖率文件。默认分支 `push` 会构建 Pages 站点，并通过
GitHub Pages Actions 部署。pull request 和非默认分支只上传 `pages-preview`
artifact。

## Cargo Feature Matrix

默认情况下，CI 保持历史行为：Clippy 和测试使用 `--all-features`，文档构建使用
Cargo 默认 feature 选择，不额外检查其他 feature 组合。

如果项目需要额外 feature 组合，可以在项目根目录添加
`.rs-ci-cargo-matrix.json`。可复用 workflow、CircleCI 模板和本地 `ci-check.sh`
会自动检测这个文件，并在默认 CI 路径之外追加这些检查。

```json
{
  "version": 1,
  "checks": [
    {
      "name": "minimal",
      "commands": ["check", "test", "doc"],
      "defaultFeatures": false,
      "features": []
    },
    {
      "name": "source-toml",
      "commands": ["test", "doc"],
      "defaultFeatures": false,
      "features": ["source-toml"]
    }
  ]
}
```

支持的命令包括 `check`、`build`、`test`、`doc`、`doc-test` 和 `clippy`。
`defaultFeatures` 默认是 `true`，`features` 默认是空列表，也可以把
`allFeatures` 设为 `true` 来显式声明 all-features 检查。matrix 由项目声明，
`rs-ci` 不会尝试从 `Cargo.toml` 自动推断所有有效 feature 组合。

## GitHub Pages 站点

把仓库 Pages source 设为 **GitHub Actions**。默认分支 `push` 部署会发布：

- `index.html`：由 `README.md` 渲染。
- `zh_CN/index.html`：存在 `README.zh_CN.md` 时由它渲染。
- `coverage/index.html`：由 `cargo-llvm-cov` 生成的 HTML 报告。
- `coverage-badge.json`：Shields.io endpoint 数据。
- `ci-summary.json`：生成站点使用的 CI 元数据。

站点构建器位于 `page/build-pages.mjs`，并读取 `page/default-config.json`。
项目可以在根目录放置 `.rs-ci-page.json` 覆盖默认配置。构建器只使用 Node.js
内置模块，项目不需要 npm 包管理器或前端依赖安装。

## 可调环境变量

- `RS_CI_BUILD_TOOLCHAIN`：build、test、docs、package、coverage 和 audit 检查使用的工具链；默认是 `1.94.0`。
- `RS_CI_FMT_TOOLCHAIN`：`rustfmt` 使用的工具链；默认是 `nightly-2026-06-05`。
- `RS_CI_CLIPPY_TOOLCHAIN`：`clippy` 使用的工具链；默认是 `nightly-2026-06-05`。
- `RUST_TOOLCHAIN`：兼容旧配置的 fallback；当 `RS_CI_FMT_TOOLCHAIN` 和 `RS_CI_CLIPPY_TOOLCHAIN` 未设置时使用。
- `RS_CI_UPDATE_TOOLCHAINS`：设为 `1` 时运行 `rustup toolchain update`；默认只安装缺失的工具链，不更新已安装工具链。
- `RS_CI_PROJECT_ROOT`：当这些脚本从其他目录运行时，用它指定 Rust 项目根目录。
- `RS_CI_RUSTFMT_CONFIG`：rustfmt 配置路径；默认是运行中的 CI 脚本所在目录旁的 `rustfmt.toml`。
- `RS_CI_CARGO_MATRIX_CONFIG`：可选 Cargo feature matrix 配置文件的项目相对路径；默认是 `.rs-ci-cargo-matrix.json`。
- `RS_CI_CARGO_HOME_MODE`：本地脚本使用的 Cargo 缓存模式，可选 `shared` 或 `project`；默认是 `shared`。当需要并行运行多个 `rs-*` 仓库时，设为 `project` 可以避免共享 Cargo package cache 和 index 锁。
- `RS_CI_CARGO_HOME_ROOT`：当 `RS_CI_CARGO_HOME_MODE=project` 时，per-project Cargo home 的根目录；默认是 `$XDG_CACHE_HOME/rs-ci/cargo-home` 或 `$HOME/.cache/rs-ci/cargo-home`。
- `RUN_COVERAGE_CFG_CLIPPY`：设为 `1` 时，使用 `RUSTFLAGS="--cfg coverage"` 运行 clippy。
- `RUN_COVERAGE_IN_ALIGN`：设为 `1` 时，从 `align-ci.sh` 运行 `coverage.sh json`；默认是 `0`。
- `STYLE_SOURCE_DIR`：`style-check.sh` 检查的源码目录；默认是 `src`。
- `STYLE_TEST_DIR`：`style-check.sh` 检查的测试目录；默认是 `tests`。
- `STYLE_ENFORCE_INLINE_TESTS`：设为 `0` 时允许在源码文件中使用 `#[cfg(test)]` 或 `#[test]`；默认是 `1`。
- `STYLE_ENFORCE_TEST_FILE_NAMES`：设为 `0` 时关闭测试文件命名检查；默认是 `1`。
- `STYLE_ENFORCE_SOURCE_TEST_PAIRS`：设为 `1` 时要求每个具体源码文件都有对应的 `*_tests.rs` 文件；默认是 `0`，因为覆盖率阈值才是测试行为的主要约束。
- `STYLE_ENFORCE_PUBLIC_TYPE_FILES`：设为 `0` 时关闭公开类型文件布局检查；默认是 `1`。
- `STYLE_ENFORCE_EXPLICIT_IMPORTS`：设为 `0` 时允许通配导入和纯聚合型 `mod.rs` 中的私有导入；默认是 `1`。
- `STYLE_ENFORCE_AGGREGATION_FILES`：设为 `0` 时允许 `lib.rs` 和 `mod.rs` 定义结构体、trait、函数、impl 或宏等具体条目；默认是 `1`。
- `STYLE_TYPE_VISIBILITY`：文件布局规则检查的类型声明范围，可选 `public` 或 `all`；默认是 `public`。
- `STYLE_INCLUDE_TYPE_ALIASES`：设为 `1` 时把公开 `type` 别名也纳入文件布局检查；默认是 `0`。
- `STYLE_EXTRA_EXCLUDE_REGEX`：追加给 `style-check.sh` 的文件排除正则。
- `STYLE_ALLOWLIST_FILE`：项目级已审核风格例外白名单；默认是 `<project-root>/.qubit-style-allowlist`。
- `COVERAGE_ENFORCE_THRESHOLDS`：设为 `0` 时禁用单源码文件覆盖率阈值检查；默认是 `1`。
- `COVERAGE_ALL_FEATURES`：设为 `0` 时，coverage 使用 Cargo 默认 feature 选择；默认是 `1`。
- `COVERAGE_NO_DEFAULT_FEATURES`：与 `COVERAGE_ALL_FEATURES=0` 配合使用，设为 `1` 时 coverage 禁用默认 feature。
- `COVERAGE_FEATURES`：当 `COVERAGE_ALL_FEATURES=0` 时传给 coverage 的逗号分隔 feature 列表。
- `MIN_FUNCTION_COVERAGE`：单个源码文件的函数覆盖率阈值；默认是 `100`。
- `MIN_LINE_COVERAGE`：单个源码文件的行覆盖率阈值；默认是 `95`，含义是 `> 95`。
- `MIN_REGION_COVERAGE`：单个源码文件的 region 覆盖率阈值；默认是 `95`，含义是 `> 95`。
- `COVERAGE_SOURCE_DIR`：参与单文件覆盖率阈值检查的源码目录；默认是 `src`。
- `COVERAGE_EXTRA_EXCLUDE_REGEX`：追加到覆盖率排除规则中的额外正则片段。
- `COVERAGE_OPEN_HTML`：设为 `0` 时，阻止 `coverage.sh html` 自动打开浏览器。

## 说明

这些脚本刻意保持自包含，这样 Rust 项目可以保留熟悉的根目录命令名。
项目特有行为应该通过环境变量配置，而不是只为某一个项目直接修改脚本。

文件级 `qubit-style: allow ...` 注释只应用于明确的例外情况，例如必须和主体类型放在一起的轻量公开辅助类型。
其中 `multiple-public-types` 例外还必须在项目级 `STYLE_ALLOWLIST_FILE` 中存在对应的已审核记录；仅有源码内联注释不会被这条规则接受。
当 `.rs-ci` 是共享脚本仓库 checkout 时，应把该文件放在项目根目录，而不是 `.rs-ci` 内。

`lib.rs` 和 `mod.rs` 会被视为聚合文件，只应声明模块并重导出条目；结构体、trait、函数、impl、宏等具体定义应放到专门的源码文件中。
