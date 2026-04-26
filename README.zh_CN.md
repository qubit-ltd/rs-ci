# Rust CI 脚本

[English](README.md)

用于在 CI 中检查 Rust 代码的共享脚本和 CircleCI 配置。

## 文件

- `align-ci.sh`：本地自动修复脚本，用于格式化代码并运行 clippy。
- `ci-check.sh`：本地完整 CI 等价检查脚本。
- `coverage.sh`：本地覆盖率报告生成和阈值检查脚本。
- `.circleci/config.yml`：优化后的 CircleCI 模板。

## 推荐接入方式

把这些文件复制到 Rust 项目根目录：

```bash
command cp align-ci.sh ci-check.sh coverage.sh <project-root>/
command cp .circleci/config.yml <project-root>/.circleci/config.yml
```

然后执行：

```bash
cd <project-root>
chmod +x align-ci.sh ci-check.sh coverage.sh
./ci-check.sh
```

## 可调环境变量

- `RUST_TOOLCHAIN`：`fmt` 和 `clippy` 使用的工具链；默认是 `nightly`。
- `RS_CI_PROJECT_ROOT`：当这些脚本从其他目录运行时，用它指定 Rust 项目根目录。
- `RUN_COVERAGE_CFG_CLIPPY`：设为 `1` 时，使用 `RUSTFLAGS="--cfg coverage"` 运行 clippy。
- `MIN_FUNCTION_COVERAGE`：单个源码文件的函数覆盖率阈值；默认是 `100`。
- `MIN_LINE_COVERAGE`：单个源码文件的行覆盖率阈值；默认是 `98`，含义是 `> 98`。
- `MIN_REGION_COVERAGE`：单个源码文件的 region 覆盖率阈值；默认是 `98`，含义是 `> 98`。
- `COVERAGE_SOURCE_DIR`：参与单文件覆盖率阈值检查的源码目录；默认是 `src`。
- `COVERAGE_EXTRA_EXCLUDE_REGEX`：追加到覆盖率排除规则中的额外正则片段。
- `COVERAGE_OPEN_HTML`：设为 `0` 时，阻止 `coverage.sh html` 自动打开浏览器。

## 说明

这些脚本刻意保持自包含，这样 Rust 项目可以保留熟悉的根目录命令名。
项目特有行为应该通过环境变量配置，而不是只为某一个项目直接修改脚本。
