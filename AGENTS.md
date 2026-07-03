# AGENTS.md

本文档为 Claude Code（claude.ai/code）在本仓库中工作时提供指引。

## 项目定位

Factorio 2.1 Mod（`LegendaryShipStart`），用 Lua 编写。仓库本身即是部署的 Mod——以 `%APPDATA%/Factorio/mods/LegendaryShipStart/` 的形式被游戏直接加载。没有构建步骤、没有包管理器、没有测试。改代码后重启 Factorio（或重载存档）即生效。

`info.json` 声明的依赖：`base >= 2.1.9`、`space-age`、`quality`。本 Mod 仅运行时（没有 `data.lua`），依赖 Space Age 的太空平台 API。

## 兄弟 Mod

本 Mod 是 NZH 维护的开局 Mod 家族的一员：

- [`LegendaryMechStart`](https://github.com/MRNIU/factorio_LegendaryMechStart) — 传奇机甲 + 装备网格 + 初始物品
- **`LegendaryShipStart`（本仓库）** — 预置传奇太空飞船
- [`BestLanding`](https://github.com/MRNIU/factorio_BestLanding) — 着陆区清理 + 行星资源 + 传奇蜘蛛
- [`nzh_factorio_mod`](https://github.com/MRNIU/nzh_factorio_mod) — 整合包，一键启用上面三个

**如果发现本 Mod 要做的事和兄弟 Mod 重叠了**（比如"玩家背包发放物品" vs `LegendaryMechStart`、"清理行星地表" vs `BestLanding`），先停下问用户，不要在本仓库重复实现。`BestLanding` 有几乎同样的蓝图应用流水线，涉及蓝图处理时可以参考它——但别跨仓库 require。

## 常用命令

- **运行 / 迭代**：启动 Factorio，启用本 Mod，开新游戏。（注：Claude Code 跑在 WSL、Mod 文件通过 Windows 挂载访问，Claude 无法直接启动 Factorio 或 Factorio Modding Tool Kit；运行验证需要你在 Windows 侧手工操作。）
- **语法检查 / 预提交**：改完任何 `.lua` 后跑一次 `for f in *.lua; do luac5.4 -p "$f" || break; done`（全 Mod 扫一遍 < 100ms），能抓 `end` 缺失 / 括号不匹配 / 字符串没闭合等语法问题；**不查语义**（undefined global、类型错误等）。提交前养成这个习惯可以避免把纯语法错推到 Mod portal。
- **调试**：`.vscode/launch.json` 使用 Factorio Modding Tool Kit 2.1+ 的原生 `factorio` 调试适配器（Factorio 2.1 的 `--dap`），追控制流时优先用它，别靠 `game.print`。
- **打包发布**：打包为 `LegendaryShipStart_<version>.zip`，压缩包最外层是文件夹本身。版本号必须和 `info.json`、`changelog.txt` 顶条一致。
- **Changelog 格式**：Factorio 严格格式（99 个 `-`、`Version:`、`Date:`、缩进 `Changes:`），英文。

## 架构

三个 Lua 文件，都是运行时代码：

- **`control.lua`** — 事件注册 + 平台创建。`script.on_init(create_all_ships)` 在新游戏时跑一次，遍历 `ships_blueprint`，对每条都调一次 `create_single_ship(ship)`。每条流程：
  1. 平台 name 拼 `NAME_PREFIX` (`"LSS "`) + `ship.name`——所有生成的平台都带这个前缀，方便和其他 Mod / 玩家命名的飞船区分。
  2. 如果 player force 已经有同名平台就跳过（幂等）。
  3. `force.create_space_platform{ planet = "nauvis", starter_pack = "space-platform-starter-pack" }` 拿到一个 `LuaSpacePlatform`。
  4. `platform.apply_starter_pack()` 生成默认枢纽实体（马上会被 `apply_blueprint` 清掉，但平台初始化流程需要它）。
  5. 把平台的 `surface` 扔给 `apply_blueprint.apply(surface, ship.data, name)`。
  6. 返回 `(ok, err)`；caller 累计成功 / 失败数，末尾只打一条总结 `game.print`，不刷屏。
  7. `script.on_configuration_changed` 挂了个 `migrate_platform_names`——1.2.3 加了 `"LSS "` 前缀，老存档里没前缀的平台会被重命名为新 name（`LuaSpacePlatform.name` 可写）。

- **`apply_blueprint.lua`** — 蓝图应用流水线。对外只暴露 `M.apply(surface, blueprint_string, label) -> ok, err`。`label` 仅用于日志。**破坏性**：会清掉 `surface` 上所有实体，只给太空平台开局这个场景用。

- **`ships_blueprint.lua`** — 纯数据。导出 `ships_blueprint`，一个 `{ name, data }` 列表，`data` 是序列化的 Factorio 蓝图字符串（base64+zlib 编码、以 `0e` 开头）。`data` 也可以是 blueprint book（流水线会展开所有页）。多条可以复用同一个蓝图变量（比如 `startship1/2/3` 都指向 `startship`），这样批量生成多艘相同的船。注意：`name` 在数据里是裸名（`"startship1"`），实际平台 name 是 `"LSS startship1"`，前缀在 `control.lua` 运行时拼。

### 蓝图应用流水线（`apply_blueprint.apply`）

蓝图字符串不能直接贴到平台 surface 上——必须经过一个 `BlueprintItem` stack 中转。整段用 `pcall` 包住，保证中途抛错也能 `inventory.destroy()` 不泄漏临时库存。流程：

1. 用 `game.create_inventory(1)` 建一个临时库存。
2. `stack.import_stack(blueprint_string)`——成功返回 0，带错误返回 -1，失败返回 1。返回值只打日志，不拿来决定成败；以 `stack.valid_for_read` 为准。
3. `collect_pages(stack)`：如果 `stack.is_blueprint` 就直接是一页；如果 `stack.is_blueprint_book` 就用 `stack.get_inventory(defines.inventory.item_main)` 展开里面每一张合法蓝图。都不是就报错。
4. 跨所有页算 AABB，对每个覆盖到的 32×32 chunk 调 `request_to_generate_chunks` + `force_generate_chunk_requests`。必须预生成，否则 `find_entities` / `set_tiles` 在未生成区块上会静默 no-op。
5. `surface.find_entities()` → 全部 destroy（清掉 starter pack 的枢纽和其他种子实体，避免和蓝图冲突）。**只清一次**——多页蓝图共用这个空 surface，第 2 页不会把第 1 页的实体抹掉。
6. 对每一页按顺序：
   1. `surface.set_tiles(page.get_blueprint_tiles())`——`BlueprintTile` 的 `{name, position}` 结构和 `Tile` 一致，直接传，不需要重建 table。太空平台 tile 在正式 build 时会做连通性检查，用原始 `set_tiles` 先铺可以绕过。
   2. `page.build_blueprint{ build_mode = defines.build_mode.forced, skip_fog_of_war = false }` → 返回 ghost 列表。
   3. 对每个 ghost 调 `ghost.revive{ raise_revive = false, return_item_request_proxy = true }`。第三个返回值 `item_request_proxy` **必须显式传 `return_item_request_proxy = true` 才会有**，否则是 nil，蓝图里的模块 / 弹药 / 燃料 / 过滤器全都落不进实体。`raise_revive = false` 省掉 `script_raised_revive` 广播——`on_init` 里别的 Mod 可能还没初始化完自己的状态。
   4. `fulfill_item_requests(entity, proxy)` 兑现物品请求。**关键坑**：`proxy.item_requests` 和 `proxy.insert_plan` 是两个**格式不同**的字段：
      - `item_requests`：扁平 `array[ItemWithQualityCount] = { name, quality, count }`，**没有 slot 信息**。
      - `insert_plan`：per-slot `array[BlueprintInsertPlan] = { id = {name, quality}, items = { in_inventory = array[InventoryPosition] } }`，精确到"哪个 inventory 的哪个 slot"。

      **必须读 `insert_plan`**，按 `slot.inventory` 调 `entity.get_inventory(slot.inventory):insert{...}`。否则对多 inventory 实体（装配机、回收机、熔炉）模块会进默认 inventory（input 队列）被当成原料消耗掉。
7. 销毁临时库存。

### 状态模型（Factorio 2.1）

本 Mod 目前不维护任何持久状态，`storage` 是空的。如果以后需要，记得在 `on_init` 里初始化，并在事件处理器里防御性判空。

## 常见坑

- **清实体会把 starter pack 枢纽也抹掉。** 这是有意的——我们期望蓝图里自带枢纽。如果某个蓝图没枢纽，那艘船就是空的。
- **`build_mode.forced`** 绕过了 build 检查（包括太空平台 tile 连通性）。不懂它的含义就别去动。
- **按 force.platforms 去重。** `create_single_ship` 如果在 `force.platforms` 里看到同名平台就返回 `"already exists"`，caller 静默跳过，所以 `on_init` 被重跑时（比如 `/c game.reset_game_state`）按名字来说是幂等的。
- **平台 name 前缀迁移。** 1.2.3 起加了 `"LSS "` 前缀。`migrate_platform_names` 只在 `on_configuration_changed` 里跑一次——有老名字 + 没新名字才改；有冲突则保留两者，记日志。`LuaSpacePlatform.name` 可写但赋值用了 `pcall` 兜底，防 API 行为变更。
- **Blueprint book 的多页会叠在同一 surface 上。** 不同页的实体和 tile 会被 forced-build 往同一坐标系上堆——玩家自己塞的 book 多半不是为这场景设计的，预期是单页蓝图。

## 本地化

`locale/zh-CN/zh-CN.cfg` 提供中文翻译。locale 里的 key 是 `factorio_LegendaryShipStart`，但 `info.json` 的 `name` 是 `LegendaryShipStart`——两边必须完全一致 Factorio 才会匹配。已知不一致，动本地化时顺手改掉。

## 语言约定

- Lua 代码注释、`AGENTS.md`：**中文**。改到已有文件时，双语注释只保留中文那一半；新注释只写中文。
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
- `LuaEntity::revive{ raise_revive = false, return_item_request_proxy = true }` 以及第三返回值 `item_request_proxy`，用 `proxy.insert_plan`（不是 `proxy.item_requests`）兑现到 `entity.get_inventory(slot.inventory)`
- `defines.build_mode`、`defines.events.on_init`、`defines.events.on_surface_created`
- `defines.inventory.item_main`（blueprint book 展开）、`script.on_configuration_changed`（平台 name 迁移）
