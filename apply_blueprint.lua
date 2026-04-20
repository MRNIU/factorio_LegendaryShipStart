-- Copyright The MRNIU/factorio_LegendaryShipStart Contributors
-- 蓝图应用流水线：import_stack -> 预生成区块 -> 清实体 -> set_tiles -> build_blueprint -> revive + fulfill
--
-- 对外只暴露 M.apply(surface, blueprint_string, label) -> ok, err
-- label 只用于日志定位（通常传平台 name）；blueprint_string 可以是单张蓝图也可以是 blueprint book。
--
-- 注意：这个函数是**破坏性**的——它会清掉 surface 上的所有实体，然后铺蓝图里的 tile。
-- 这是太空平台开局场景专用的行为（starter pack 生成的枢纽需要被蓝图自带的枢纽替换）。
-- 其他场景别直接用。

local M = {}

--------------------------------------------------------------------------------------
-- item_request_proxy 兑现：把模块 / 弹药 / 过滤器等插回复活实体
--
-- LuaEntity 上和蓝图物品请求相关的有两个**格式不同**的字段（Factorio 2.0）：
--
--   item_requests :: Read  ItemWithQualityCounts = array[ItemWithQualityCount]
--                    扁平格式 { name, quality, count }，没有 slot 信息
--   insert_plan   :: R/W   array[BlueprintInsertPlan]
--                    per-slot 格式 { id = {name, quality},
--                                     items = { in_inventory :: array[InventoryPosition],
--                                               grid_count   :: uint? } }
--                    其中 InventoryPosition = { inventory :: defines.inventory.*,
--                                                stack :: ItemStackIndex (0-based),
--                                                count :: uint? }  -- 省略默认 1
--
-- 我们要的是 insert_plan：它精确指定每件物品要进哪个 inventory 的哪个 slot。
-- 对装配机 / 回收机这种多 inventory 的实体，BlueprintInsertPlan 会把模块的 inventory
-- 标成模块槽而不是 input 队列——所以模块进模块槽、不会被当作原料消耗。
local function fulfill_item_requests(entity, proxy)
    if not (proxy and proxy.valid) then return end

    for _, plan in pairs(proxy.insert_plan) do
        local name    = plan.id and plan.id.name
        local quality = (plan.id and plan.id.quality) or "normal"

        if name and plan.items and plan.items.in_inventory then
            for _, slot in pairs(plan.items.in_inventory) do
                local inv = entity.get_inventory(slot.inventory)
                if inv then
                    local want = slot.count or 1
                    local inserted = inv.insert { name = name, count = want, quality = quality }
                    if inserted < want then
                        log(("[LegendaryShipStart] fulfill_item_requests: inserted %d/%d of %s (q=%s) into %s inv=%s")
                            :format(inserted, want, name, quality, entity.name, tostring(slot.inventory)))
                    end
                end
            end
        end
        -- plan.items.grid_count（装甲网格里的装备请求）暂不处理：
        -- 目前所有蓝图里都没有带装备网格的实体
    end

    proxy.destroy()
end

--------------------------------------------------------------------------------------
-- 从 import_stack 之后的顶层 stack 展开出所有可应用的蓝图页。
-- 输入可能是单张 BlueprintItem，也可能是 BlueprintBook；不是这两种就返回空表。

local function collect_pages(stack)
    local pages = {}
    if stack.is_blueprint then
        pages[1] = stack
    elseif stack.is_blueprint_book then
        local book_inv = stack.get_inventory(defines.inventory.item_main)
        if book_inv then
            for i = 1, #book_inv do
                local page = book_inv[i]
                if page.valid_for_read and page.is_blueprint then
                    pages[#pages + 1] = page
                end
            end
        end
    end
    return pages
end

--------------------------------------------------------------------------------------
-- 跨所有页算 AABB，按 32 对齐预生成区块。必须在 find_entities / set_tiles 之前做，
-- 否则未生成区块上这两个 API 会静默 no-op。

local function pregenerate_chunks(surface, pages)
    local min_x, min_y =  math.huge,  math.huge
    local max_x, max_y = -math.huge, -math.huge

    local function extend(pos)
        if pos.x < min_x then min_x = pos.x end
        if pos.x > max_x then max_x = pos.x end
        if pos.y < min_y then min_y = pos.y end
        if pos.y > max_y then max_y = pos.y end
    end

    for _, page in ipairs(pages) do
        local ents = page.get_blueprint_entities()
        if ents  then for _, e in ipairs(ents)  do extend(e.position) end end
        local tls = page.get_blueprint_tiles()
        if tls   then for _, t in ipairs(tls)   do extend(t.position) end end
    end

    if min_x == math.huge then return end  -- 空蓝图

    local cmin_x = math.floor(min_x / 32)
    local cmax_x = math.floor(max_x / 32)
    local cmin_y = math.floor(min_y / 32)
    local cmax_y = math.floor(max_y / 32)
    for x = cmin_x, cmax_x do
        for y = cmin_y, cmax_y do
            surface.request_to_generate_chunks({ x * 32, y * 32 }, 0)
        end
    end
    surface.force_generate_chunk_requests()
end

--------------------------------------------------------------------------------------
-- 应用单张蓝图页到 surface（已经清过实体）：set_tiles -> build_blueprint -> revive。

local function apply_one_page(surface, page, force)
    -- 1. 强制铺设地板。太空平台 tile 在正式 build 时会做连通性检查，
    --    用原始 set_tiles 先铺可以绕过，给蓝图的实体留个落脚的地板。
    --    BlueprintTile 的 {name, position} 结构和 set_tiles 要的 Tile 一致，直接传。
    local tiles = page.get_blueprint_tiles()
    if tiles then
        surface.set_tiles(tiles)
    end

    -- 2. 在平台中心 (0, 0) 放置蓝图实体（ghost 形态）
    local ghosts = page.build_blueprint {
        surface         = surface,
        force           = force,
        position        = { 0, 0 },
        build_mode      = defines.build_mode.forced,
        skip_fog_of_war = false,
    } or {}

    -- 3. 复活所有虚影为实体
    --   raise_revive = false              省掉 script_raised_revive 事件广播
    --   return_item_request_proxy = true  确保第三个返回值给到 item_request_proxy
    for _, ghost in ipairs(ghosts) do
        if ghost.valid then
            local _, entity, proxy = ghost.revive {
                raise_revive              = false,
                return_item_request_proxy = true,
            }
            if entity then
                fulfill_item_requests(entity, proxy)
            end
        end
    end
end

--------------------------------------------------------------------------------------
-- 主入口

function M.apply(surface, blueprint_string, label)
    label = label or "(unnamed)"

    if not (surface and surface.valid) then
        return false, "surface invalid"
    end
    if not blueprint_string or blueprint_string == "" then
        return false, "empty blueprint string"
    end

    -- 临时库存承载 BlueprintItem；pcall 保证即便中途抛错也 destroy，不泄漏
    local inventory = game.create_inventory(1)
    local ok, err = pcall(function()
        local stack = inventory[1]

        local import_result = stack.import_stack(blueprint_string)
        if import_result ~= 0 then
            log(("[LegendaryShipStart] import_stack returned %d for %s")
                :format(import_result, label))
        end
        if not stack.valid_for_read then
            error("stack empty after import_stack")
        end

        local pages = collect_pages(stack)
        if #pages == 0 then
            error("stack is neither blueprint nor blueprint-book (or book is empty)")
        end

        pregenerate_chunks(surface, pages)

        -- 清掉 surface 上所有实体（包括 starter pack 枢纽），防止与蓝图冲突；
        -- 蓝图期望自带枢纽。只清一次——后面多页蓝图共用这个空 surface。
        for _, entity in pairs(surface.find_entities()) do
            if entity.valid then entity.destroy() end
        end
        if not surface.valid then
            error("surface invalid after clearing entities")
        end

        local force = game.forces.player
        for _, page in ipairs(pages) do
            apply_one_page(surface, page, force)
        end
    end)

    inventory.destroy()

    if not ok then
        log(("[LegendaryShipStart] apply error for %s: %s"):format(label, tostring(err)))
        return false, err
    end
    return true
end

return M
