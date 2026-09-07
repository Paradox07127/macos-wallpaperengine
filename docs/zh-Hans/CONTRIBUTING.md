# 贡献指南

[English](../CONTRIBUTING.md) · **简体中文**

欢迎 issue 和 pull request。先看[构建说明](building.md)配置 Xcode 27.0 与 Metal Toolchain，
再看[架构说明](architecture.md)了解模块职责。

## 验证改动

1. 通过 `scripts/app_tests.sh suites <Suite>` 跑相关行为测试。
2. 跑仓库串行门禁：

   ```bash
   make verify
   ```

   覆盖结构、本地化、工具契约、改动行 lint、包测试与应用契约分片，不等于完整应用套件。
3. 影响较广应用行为时运行 `scripts/app_tests.sh full`；发版前运行
   `scripts/release_candidate_check.sh`，覆盖完整签名 Pro 套件、Pro/Lite 链接与 archive 矩阵、发布检查。

Pro/Lite 操作不要同时使用同一个 DerivedData。应用测试保留签名，核对实际 passed/failed/skipped。
需要改变运行时不变量时在 PR 中给出理由，不要悄悄放松测试。

## 格式与本地化

CI 通过 `make lint` 检查改动行的格式和 lint，使用 `.swiftformat`、`.swiftlint.yml`
与质量门禁，不要求无关的全库格式化。

```bash
make lint BASE=main
scripts/format-changed.sh
```

格式化辅助脚本作用于改动文件，运行后应检查 diff，剔除无关格式变化。
`scripts/check_quality_exclusions.py` 按 owner 和预算跟踪排除项；规模 advisory 即使不阻断退出码，也仍是技术债。

用户文本写入 String Catalog，覆盖英语、简体中文、繁体中文、日语、西班牙语五种语言。
UI 复用 [Core 设计系统](../../Packages/LiveWallpaperCore/DESIGN.md)。英文与简体中文文档同步更新。

## 代码与审查边界

- 修改 SKU 条件后，两个应用版本都要构建。`LITE_BUILD` 是应用 target 标志，不传入 Swift 包。
- 工程/workspace 文件由维护者修改。源文件先写到磁盘，在 PR 中说明需要的 target 注册。
- entitlement 或 Info.plist 权限改动须明确审查功能与签名运行时边界，新增依赖先讨论。
- 渲染改动需要定点测试与相应抓帧/trace，单元测试不能证明 Windows parity。RNG、字体和浮点输出不以像素完全相同为验收标准。
- 审查笔记和实验计划不进入公开用户文档。PR 说明最终行为、验证和剩余限制。

## 报告 bug

可使用**设置 → 关于 → 报告问题…**生成预填报告，检查所含诊断后补充复现步骤；
也可以直接提 [GitHub issue](https://github.com/Paradox07127/macos-wallpaperengine/issues)，
附 macOS 版本与 Mac 机型。安全问题走[安全策略](SECURITY.md)，不走公开 issue。
