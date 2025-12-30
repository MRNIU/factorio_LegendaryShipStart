-- This file is a part of MRNIU/factorio_LegendaryShipStart
-- (https://github.com/MRNIU/factorio_LegendaryShipStart).
--
-- control.lua for MRNIU/factorio_LegendaryShipStart.

local ships_blueprint = require("ships_blueprint")

--------------------------------------------------------------------------------------
-- Apply blueprint to the given surface
local function ApplyBlueprint(surface, blueprint_string)
    -- 仅在有玩家的势力执行，通常是 "player"
    local force = game.forces["player"]

    -- 如果提供了蓝图字符串，则应用蓝图
    if blueprint_string and blueprint_string ~= "" then
        -- 创建一个临时库存来处理蓝图
        local inventory = game.create_inventory(1)
        local stack = inventory[1]

        -- 导入蓝图字符串
        -- import_stack 返回 0 表示成功 (在某些版本中)，或者我们需要检查 stack 是否有效
        local import_result = stack.import_stack(blueprint_string)

        if stack.valid_for_read and stack.is_blueprint then
            -- 0. 预先生成区块，防止蓝图过大超出范围
            local blueprint_entities = stack.get_blueprint_entities()
            local blueprint_tiles = stack.get_blueprint_tiles()
            
            local min_x, min_y, max_x, max_y = 0, 0, 0, 0
            local initialized = false

            local function update_bounds(pos)
                if not initialized then
                    min_x, min_y = pos.x, pos.y
                    max_x, max_y = pos.x, pos.y
                    initialized = true
                else
                    if pos.x < min_x then min_x = pos.x end
                    if pos.x > max_x then max_x = pos.x end
                    if pos.y < min_y then min_y = pos.y end
                    if pos.y > max_y then max_y = pos.y end
                end
            end

            if blueprint_entities then
                for _, entity in pairs(blueprint_entities) do
                    update_bounds(entity.position)
                end
            end

            if blueprint_tiles then
                for _, tile in pairs(blueprint_tiles) do
                    update_bounds(tile.position)
                end
            end

            if initialized then
                local chunk_min_x = math.floor(min_x / 32)
                local chunk_max_x = math.floor(max_x / 32)
                local chunk_min_y = math.floor(min_y / 32)
                local chunk_max_y = math.floor(max_y / 32)

                for x = chunk_min_x, chunk_max_x do
                    for y = chunk_min_y, chunk_max_y do
                        surface.request_to_generate_chunks({x * 32, y * 32}, 0)
                    end
                end
                surface.force_generate_chunk_requests()
            end

            -- 清理表面上的所有实体，防止与蓝图冲突
            local entities = surface.find_entities()
            for _, entity in pairs(entities) do
                if entity.valid then
                    entity.destroy()
                end
            end

            if not surface.valid then
                game.print("LegendaryShipStart: Surface invalid after clearing entities.")
                return
            end

            -- 1. 强制铺设地板 (绕过太空平台连接性检查)
            if blueprint_tiles then
                local tiles_to_set = {}
                for _, t in pairs(blueprint_tiles) do
                    table.insert(tiles_to_set, { name = t.name, position = t.position })
                end
                surface.set_tiles(tiles_to_set)
            end

            -- 2. 在平台中心 (0,0) 放置蓝图 (主要是实体)
            local ghosts = stack.build_blueprint {
                surface = surface,
                force = force,
                position = { 0, 0 },
                build_mode = defines.build_mode.forced,
                skip_fog_of_war = false
            }

            -- 3. 立即复活所有虚影为实体
            if ghosts then
                for _, ghost in pairs(ghosts) do
                    ghost.revive({ raise_revive = true })
                end
            end

            game.print("Legendary Ship blueprint applied!")
        else
            game.print("LegendaryShipStart: Invalid blueprint string or import failed. Result: " ..
                tostring(import_result))
        end

        inventory.destroy()
    else
        game.print("Legendary Ship created! (No blueprint provided)")
    end
end

local function CreateSingleShip(ship)
    local name = ship.name
    local bp_string = ship.data

    if not name then return end

    local force = game.forces["player"]

    -- Check if already exists to prevent duplicates
    if force.platforms then
        for _, p in pairs(force.platforms) do
            if p.name == name then
                return
            end
        end
    end

    -- 在 Nauvis 上空创建平台
    local platform = force.create_space_platform {
        name = name,
        planet = "nauvis",
        starter_pack = "space-platform-starter-pack"
    }

    if not platform then
        game.print("LegendaryShipStart: Failed to create space platform " .. name)
        return
    end

    platform.apply_starter_pack()

    local platform_surface = platform.surface
    if not platform_surface then
        -- Surface not ready yet, store index to handle in on_surface_created
        if not storage.pending_platforms then storage.pending_platforms = {} end
        storage.pending_platforms[platform.index] = bp_string
        game.print("LegendaryShipStart: Platform " .. name .. " created, waiting for surface...")
        return
    end

    ApplyBlueprint(platform_surface, bp_string)
end

-- Create the platform
local function CreateLegendaryShips()
    if not ships_blueprint then return end

    for _, ship in pairs(ships_blueprint) do
        CreateSingleShip(ship)
    end
end

--------------------------------------------------------------------------------------
-- 事件注册
script.on_init(CreateLegendaryShips)
