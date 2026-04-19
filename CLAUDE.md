# CLAUDE.md

本文档为 Claude Code（claude.ai/code）在本仓库中工作时提供指引。

## 项目定位

Factorio 2.0 Mod（`LegendaryShipStart`），用 Lua 编写。仓库本身即是部署的 Mod——以 `%APPDATA%/Factorio/mods/LegendaryShipStart/` 的形式被游戏直接加载。没有构建步骤、没有包管理器、没有测试。改代码后重启 Factorio（或重载存档）即生效。

`info.json` 声明的依赖：`base >= 2.0.76`、`space-age`、`quality`。本 Mod 仅运行时（没有 `data.lua`），依赖 Space Age 的太空平台 API。

## 兄弟 Mod

本 Mod 是 NZH 维护的开局 Mod 家族的一员：

- [`LegendaryMechStart`](https://github.com/MRNIU/factorio_LegendaryMechStart) — 传奇机甲 + 装备网格 + 初始物品
- **`LegendaryShipStart`（本仓库）** — 预置传奇太空飞船
- [`BestLanding`](https://github.com/MRNIU/factorio_BestLanding) — 着陆区清理 + 行星资源 + 传奇蜘蛛
- [`nzh_factorio_mod`](https://github.com/MRNIU/nzh_factorio_mod) — 整合包，一键启用上面三个

**如果发现本 Mod 要做的事和兄弟 Mod 重叠了**（比如"玩家背包发放物品" vs `LegendaryMechStart`、"清理行星地表" vs `BestLanding`），先停下问用户，不要在本仓库重复实现。`BestLanding` 有几乎同样的蓝图应用流水线，涉及蓝图处理时可以参考它——但别跨仓库 require。

## 常用命令

- **运行 / 迭代**：启动 Factorio，启用本 Mod，开新游戏。（注：Claude Code 跑在 WSL、Mod 文件通过 Windows 挂载访问，Claude 无法直接启动 Factorio 或 FactorioModDebug；运行验证需要你在 Windows 侧手工操作。）
- **语法检查 / 预提交**：改完任何 `.lua` 后跑一次 `for f in *.lua; do luac5.4 -p "$f" || break; done`（全 Mod 扫一遍 < 100ms），能抓 `end` 缺失 / 括号不匹配 / 字符串没闭合等语法问题；**不查语义**（undefined global、类型错误等）。提交前养成这个习惯可以避免把纯语法错推到 Mod portal。
- **调试**：`.vscode/launch.json` 里配好了 [FactorioModDebug](https://marketplace.visualstudio.com/items?itemName=justarandomgeek.factoriomod-debug) 的启动项，追控制流时优先用它，别靠 `game.print`。
- **打包发布**：打包为 `LegendaryShipStart_<version>.zip`，压缩包最外层是文件夹本身。版本号必须和 `info.json`、`changelog.txt` 顶条一致。
- **Changelog 格式**：Factorio 严格格式（99 个 `-`、`Version:`、`Date:`、缩进 `Changes:`），英文。

## 架构

两个 Lua 文件，都是运行时代码：

- **`control.lua`** — 事件注册 + 蓝图应用逻辑。`script.on_init(CreateLegendaryShips)` 在新游戏时跑一次，遍历 `ships_blueprint`，对每条都调一次 `CreateSingleShip(ship)`。每条流程：
  1. 如果 player force 已经有同名平台就跳过（幂等）。
  2. `force.create_space_platform{ planet = "nauvis", starter_pack = "space-platform-starter-pack" }` 拿到一个 `LuaSpacePlatform`。
  3. `platform.apply_starter_pack()` 生成默认枢纽实体。
  4. 把平台的 `surface` 扔给 `ApplyBlueprint`。

- **`ships_blueprint.lua`** — 纯数据。导出 `ships_blueprint`，一个 `{ name, data }` 列表，`data` 是序列化的 Factorio 蓝图字符串（base64+zlib 编码、以 `0e` 开头）。多条可以复用同一个蓝图变量（比如 `startship1/2/3` 都指向 `startship`），这样批量生成多艘相同的船。

### 蓝图应用流水线（`ApplyBlueprint`）

蓝图字符串不能直接贴到平台 surface 上——必须经过一个 `BlueprintItem` stack 中转。流程：

1. 用 `game.create_inventory(1)` 建一个临时库存。
2. `stack.import_stack(blueprint_string)`——成功返回 0，带错误返回 -1，失败返回 1。真正有效的蓝图同时满足 `stack.valid_for_read and stack.is_blueprint`，以这个判断为准，别只看数字返回值。
3. 读出 `get_blueprint_entities()` 和 `get_blueprint_tiles()`，算出 AABB 包围盒，然后对每个覆盖到的 32×32 chunk 调 `request_to_generate_chunks` + `force_generate_chunk_requests`。必须预生成，否则 `find_entities` / `set_tiles` 在未生成区块上会静默 no-op。
4. `surface.find_entities()` → 全部 destroy（清掉 starter pack 的枢纽和其他种子实体，避免和蓝图冲突）。
5. `surface.set_tiles(...)` 先铺蓝图里的 tile。太空平台 tile 在正式 build 时会做连通性检查，用原始 `set_tiles` 先铺可以绕过，给蓝图的实体留个落脚的地板。
6. `stack.build_blueprint{ build_mode = defines.build_mode.forced, skip_fog_of_war = false }` → 返回 ghost 列表。
7. 对每个 ghost 调 `ghost.revive({ raise_revive = true })`。如果 revive 顺带返回了 `item_request_proxy`，把它的 `item_requests` 灌进刚复活的实体——蓝图里序列化的模块 / 过滤器 / 燃料就是这样落到实体里的。
8. 销毁临时库存。

### 状态模型（Factorio 2.0）

本 Mod 目前不维护任何持久状态，`storage` 是空的。如果以后需要，记得在 `on_init` 里初始化，并在事件处理器里防御性判空。

## 常见坑

- **清实体会把 starter pack 枢纽也抹掉。** 这是有意的——我们期望蓝图里自带枢纽。如果某个蓝图没枢纽，那艘船就是空的。
- **`build_mode.forced`** 绕过了 build 检查（包括太空平台 tile 连通性）。不懂它的含义就别去动。
- **按 player force 去重。** `CreateSingleShip` 如果在 `force.platforms` 里看到同名平台就跳过，所以 `on_init` 被重跑时（比如 `/c game.reset_game_state`）按名字来说是幂等的。

## 本地化

`locale/zh-CN/zh-CN.cfg` 提供中文翻译。locale 里的 key 是 `factorio_LegendaryShipStart`，但 `info.json` 的 `name` 是 `LegendaryShipStart`——两边必须完全一致 Factorio 才会匹配。已知不一致，动本地化时顺手改掉。

## 语言约定

- Lua 代码注释、`CLAUDE.md`：**中文**。改到已有文件时，双语注释只保留中文那一半；新注释只写中文。
- `README.md`、`changelog.txt`、`info.json` 的 `description` / `title`、Mod portal 上对外展示的内容：**英文**。已有双语条目下次改到时切换成纯英文。
- `locale/*.cfg` 按对应语言写。
- 版权头 `-- Copyright The MRNIU/factorio_LegendaryShipStart Contributors` 必须保留。
- 技术标识符不翻译，用反引号保留原样。

## Factorio API 参考

- Wiki：<https://wiki.factorio.com/>
- Mod 站：<https://mods.factorio.com/>
- Mod settings 教程：<https://wiki.factorio.com/Tutorial:Mod_settings>
- Prototype API（data 阶段）：<https://lua-api.factorio.com/latest/index-prototype.html>
- Runtime API（control 阶段）：<https://lua-api.factorio.com/latest/index-runtime.html>

本 Mod 常用的运行时 API：
- `LuaForce::create_space_platform`、`LuaSpacePlatform::apply_starter_pack`、`LuaSpacePlatform::surface`
- `LuaItemStack::import_stack`、`get_blueprint_entities`、`get_blueprint_tiles`、`build_blueprint`
- `LuaSurface::request_to_generate_chunks`、`force_generate_chunk_requests`、`set_tiles`、`find_entities`
- `LuaEntity::revive{ raise_revive = true }` 以及返回的 `item_request_proxy`
- `defines.build_mode`、`defines.events.on_init`、`defines.events.on_surface_created`
