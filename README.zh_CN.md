# Rust CI 脚本

[English](README.md)

用于在 CI 中检查 Rust 代码的共享脚本和 CircleCI 配置。

## 文件

- `align-ci.sh`：本地自动修复脚本，用于格式化代码并运行 clippy。
- `ci-check.sh`：本地完整 CI 等价检查脚本。
- `style-check.sh`：检查 rustfmt 和 clippy 不覆盖的 Rust 源码布局约束。
- `coverage.sh`：本地覆盖率报告生成和阈值检查脚本。
- `.circleci/config.yml`：优化后的 CircleCI 模板。

## 推荐接入方式

把这些文件复制到 Rust 项目根目录：

```bash
command cp align-ci.sh ci-check.sh style-check.sh coverage.sh <project-root>/
command cp .circleci/config.yml <project-root>/.circleci/config.yml
```

然后执行：

```bash
cd <project-root>
chmod +x align-ci.sh ci-check.sh style-check.sh coverage.sh
./style-check.sh
./ci-check.sh
```

## 可调环境变量

- `RUST_TOOLCHAIN`：`fmt` 和 `clippy` 使用的工具链；默认是 `nightly`。
- `RS_CI_PROJECT_ROOT`：当这些脚本从其他目录运行时，用它指定 Rust 项目根目录。
- `RUN_COVERAGE_CFG_CLIPPY`：设为 `1` 时，使用 `RUSTFLAGS="--cfg coverage"` 运行 clippy。
- `RUN_COVERAGE_IN_ALIGN`：设为 `1` 时，从 `align-ci.sh` 运行 `coverage.sh json`；默认是 `0`。
- `STYLE_SOURCE_DIR`：`style-check.sh` 检查的源码目录；默认是 `src`。
- `STYLE_TEST_DIR`：`style-check.sh` 检查的测试目录；默认是 `tests`。
- `STYLE_ENFORCE_INLINE_TESTS`：设为 `0` 时允许在源码文件中使用 `#[cfg(test)]` 或 `#[test]`；默认是 `1`。
- `STYLE_ENFORCE_TEST_FILE_NAMES`：设为 `0` 时关闭测试文件命名检查；默认是 `1`。
- `STYLE_ENFORCE_PUBLIC_TYPE_FILES`：设为 `0` 时关闭公开类型文件布局检查；默认是 `1`。
- `STYLE_TYPE_VISIBILITY`：文件布局规则检查的类型声明范围，可选 `public` 或 `all`；默认是 `public`。
- `STYLE_INCLUDE_TYPE_ALIASES`：设为 `1` 时把公开 `type` 别名也纳入文件布局检查；默认是 `0`。
- `STYLE_EXTRA_EXCLUDE_REGEX`：追加给 `style-check.sh` 的文件排除正则。
- `COVERAGE_ENFORCE_THRESHOLDS`：设为 `0` 时禁用单源码文件覆盖率阈值检查；默认是 `1`。
- `COVERAGE_ALL_FEATURES`：设为 `0` 时，coverage 使用 Cargo 默认 feature 选择；默认是 `1`。
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
