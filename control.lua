-- Copyright The MRNIU/factorio_LegendaryShipStart Contributors

local ships_blueprint = require("ships_blueprint")
local apply_blueprint = require("apply_blueprint")

-- 平台 name 前缀：避免和其他 Mod / 玩家自己命名的飞船撞名。
-- 从 1.2.3 起使用；老存档用 `migrate_platform_names` 迁移。
local NAME_PREFIX = "LSS "

local function platform_name_for(ship) return NAME_PREFIX .. ship.name end

--------------------------------------------------------------------------------------
-- 按 force.platforms 查重。
-- 注：force.platforms 是 array[LuaSpacePlatform]，没有按 name 索引的 O(1) 接口，
--     所以这里 O(N)——N 永远很小（单个玩家的飞船数），不值得缓存。

local function find_platform_by_name(force, name)
    if not force.platforms then return nil end
    for _, p in ipairs(force.platforms) do
        if p.valid and p.name == name then return p end
    end
    return nil
end

--------------------------------------------------------------------------------------
-- 1.2.3 迁移：把带旧 name（无前缀）的平台重命名为新 name（带 LSS 前缀）。
-- 只在 on_configuration_changed 时跑一次。LuaSpacePlatform.name 是可写的。

local function migrate_platform_names()
    local force = game.forces.player
    if not force or not force.platforms then return end

    for _, ship in ipairs(ships_blueprint) do
        local old_name = ship.name
        local new_name = platform_name_for(ship)
        local old = find_platform_by_name(force, old_name)
        local new = find_platform_by_name(force, new_name)
        if old and not new then
            local ok, err = pcall(function() old.name = new_name end)
            if ok then
                log(("[LegendaryShipStart] migrated platform %q -> %q"):format(old_name, new_name))
            else
                log(("[LegendaryShipStart] failed to rename %q -> %q: %s")
                    :format(old_name, new_name, tostring(err)))
            end
        end
    end
end

--------------------------------------------------------------------------------------
-- 创建单艘飞船，并应用蓝图。
-- 返回 (ok, err_or_nil)；err 为 "already exists" 时 caller 静默处理。

local function create_single_ship(ship)
    if not ship.name then return false, "missing ship.name" end

    local force = game.forces.player
    local name  = platform_name_for(ship)

    if find_platform_by_name(force, name) then
        return false, "already exists"
    end

    local platform = force.create_space_platform {
        name         = name,
        planet       = "nauvis",
        starter_pack = "space-platform-starter-pack",
    }
    if not platform then
        return false, "create_space_platform failed"
    end

    platform.apply_starter_pack()

    local surface = platform.surface
    if not surface then
        return false, "platform has no surface"
    end

    return apply_blueprint.apply(surface, ship.data, name)
end

--------------------------------------------------------------------------------------
-- 遍历 ships_blueprint 创建全部飞船，末尾汇总一次。

local function create_all_ships()
    if not ships_blueprint then return end

    local ok_count, fail_count = 0, 0
    for _, ship in ipairs(ships_blueprint) do
        local ok, err = create_single_ship(ship)
        if ok then
            ok_count = ok_count + 1
        elseif err == "already exists" then
            -- 幂等：on_init 被重跑（比如 /c game.reset_game_state）时平台已存在，静默跳过
        else
            fail_count = fail_count + 1
            game.print(("LegendaryShipStart: %q failed — %s"):format(ship.name or "?", tostring(err)))
        end
    end

    if ok_count > 0 or fail_count > 0 then
        game.print(("LegendaryShipStart: created %d ship%s%s")
            :format(ok_count, ok_count == 1 and "" or "s",
                    fail_count > 0 and (" (" .. fail_count .. " failed)") or ""))
    end
end

--------------------------------------------------------------------------------------
-- 事件注册
script.on_init(create_all_ships)

-- 版本升级时的迁移钩子
script.on_configuration_changed(function(data)
    local change = data.mod_changes and data.mod_changes["LegendaryShipStart"]
    if change and change.old_version then
        migrate_platform_names()
    end
end)
