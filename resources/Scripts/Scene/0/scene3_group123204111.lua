-- =========================================================================================================== 
--  ||  ____                                 _                        _       _      _       _     _       ||
--  || |  _ \ _ __ ___  __ _ _ __ ___  _ __ | | __ _  ___ ___        / \   __| | ___| | __ _(_) __| | ___  ||
--  || | | | | '__/ _ \/ _` | '_ ` _ \| '_ \| |/ _` |/ __/ _ \_____ / _ \ / _` |/ _ \ |/ _` | |/ _` |/ _ \ ||
--  || | |_| | | |  __/ (_| | | | | | | |_) | | (_| | (_|  __/_____/ ___ \ (_| |  __/ | (_| | | (_| |  __/ ||
--  || |____/|_|  \___|\__,_|_| |_| |_| .__/|_|\__,_|\___\___|    /_/   \_\__,_|\___|_|\__,_|_|\__,_|\___| ||
--  ||                                |_|                                                                  ||
-- =========================================================================================================== 
local base_info = {
    group_id = 123204111
}

--================================================================
-- 
-- 配置
-- 
--================================================================

-- 怪物
monsters = {
    { config_id = 1, monster_id = 20070101, pos = { x = 2733.0645, y = 195.61084, z = -1689.1125 }, rot = { x = 0.0, y = 314.45477, z = 0.0 }, level = 20, area_id = 1 },
    { config_id = 2, monster_id = 22060101, pos = { x = 2732.8687, y = 195.59076, z = -1689.0647 }, rot = { x = 0.0, y = 314.4438, z = 0.0 }, level = 10, area_id = 1 }
}

npcs = {
}

-- 装置
gadgets = {
    { config_id = 4, gadget_id = 70900039, pos = { x = 2720.0647, y = 195.04295, z = -1681.0793 }, rot = { x = 0.0, y = 352.161, z = 0.0 }, level = 1, persistent = true, area_id = 1 },
    { config_id = 5, gadget_id = 70900007, pos = { x = 2724.964, y = 195.8028, z = -1677.8025 }, rot = { x = 0.0, y = 7.2457056, z = 0.0 }, level = 1, persistent = true, area_id = 1 },
    { config_id = 6, gadget_id = 70900008, pos = { x = 2726.301, y = 195.21451, z = -1685.0089 }, rot = { x = 0.0, y = 137.36626, z = 0.0 }, level = 1, persistent = true, area_id = 1 },
    { config_id = 14, gadget_id = 70211002, pos = { x = 2723.4087, y = 195.24835, z = -1681.6371 }, rot = { x = 0.0, y = 271.5409, z = 0.0 }, level = 1, drop_tag = "战斗低级蒙德", state = GadgetState.ChestLocked, isOneoff = false, persistent = false, explore = { name = "chest", exp = 1 }, area_id = 1 },
    { config_id = 15, gadget_id = 70211012, pos = { x = 2723.3916, y = 196.20367, z = -1681.6367 }, rot = { x = 0.0, y = 271.5409, z = 0.0 }, level = 1, drop_tag = "战斗低级蒙德", state = GadgetState.ChestLocked, isOneoff = false, persistent = false, explore = { name = "chest", exp = 1 }, area_id = 1 },
    { config_id = 16, gadget_id = 70211022, pos = { x = 2723.4424, y = 197.24252, z = -1681.638 }, rot = { x = 0.0, y = 271.5409, z = 0.0 }, level = 1, drop_tag = "战斗中级蒙德", state = GadgetState.ChestLocked, isOneoff = false, persistent = false, explore = { name = "chest", exp = 1 }, area_id = 1 },
    { config_id = 17, gadget_id = 70211032, pos = { x = 2723.4414, y = 198.60762, z = -1681.638 }, rot = { x = 0.0, y = 271.5409, z = 0.0 }, level = 1, drop_tag = "战斗高级蒙德", state = GadgetState.ChestLocked, isOneoff = false, persistent = false, explore = { name = "chest", exp = 1 }, area_id = 1 }
}

-- 区域
regions = {
}

-- 触发器
triggers = {
    { config_id = 3, name = "ANY_MONSTER_DIE_3", event = EventType.EVENT_ANY_MONSTER_DIE, source = "", condition = "condition_EVENT_ANY_MONSTER_DIE_3", action = "action_EVENT_ANY_MONSTER_DIE_3" },
    { config_id = 7, name = "GADGET_STATE_CHANGE_7", event = EventType.EVENT_GADGET_STATE_CHANGE, source = "", condition = "condition_EVENT_GADGET_STATE_CHANGE_7", action = "action_EVENT_GADGET_STATE_CHANGE_7" },
    { config_id = 8, name = "GADGET_STATE_CHANGE_8", event = EventType.EVENT_GADGET_STATE_CHANGE, source = "", condition = "condition_EVENT_GADGET_STATE_CHANGE_8", action = "action_EVENT_GADGET_STATE_CHANGE_8" },
    { config_id = 9, name = "GADGET_STATE_CHANGE_9", event = EventType.EVENT_GADGET_STATE_CHANGE, source = "", condition = "condition_EVENT_GADGET_STATE_CHANGE_9", action = "action_EVENT_GADGET_STATE_CHANGE_9" },
    { config_id = 13, name = "VARIABLE_CHANGE_13", event = EventType.EVENT_VARIABLE_CHANGE, source = "", condition = "condition_EVENT_VARIABLE_CHANGE_13", action = "action_EVENT_VARIABLE_CHANGE_13" }
}

-- 变量
variables = {
    { config_id = 0, name = "Key", value = 0, no_refresh = false } 
}

--================================================================
-- 
-- 初始化配置
-- 
--================================================================

-- 初始化时创建
init_config = {
    suite = 1,
    end_suite = 0,
    rand_suite = false
}

--================================================================
-- 
-- 小组配置
-- 
--================================================================

suites = {
    {
        monsters = { 1, 2 },
        gadgets = {  },
        regions = { },
        triggers = { "ANY_MONSTER_DIE_3" },
        rand_weight = 100
    },
    {
        monsters = {  },
        gadgets = { 4, 5, 6 },
        regions = { },
        triggers = { "GADGET_STATE_CHANGE_7", "GADGET_STATE_CHANGE_8", "GADGET_STATE_CHANGE_9" },
        rand_weight = 100
    },
    {
        monsters = {  },
        gadgets = { 14, 15, 16, 17 },
        regions = { },
        triggers = { "VARIABLE_CHANGE_13" },
        rand_weight = 100
    }
}

--================================================================
-- 
-- 触发器
-- 
--================================================================

-- 触发条件
function condition_EVENT_ANY_MONSTER_DIE_3(context, evt)
    -- 判断怪物死亡
    if ScriptLib.GetGroupMonsterCount(context) ~= 0 then
        return false
    end

    return true
end

-- 触发操作
function action_EVENT_ANY_MONSTER_DIE_3(context, evt)
    -- 创建装置
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 4 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget_4_failed")
        return -1
    end
    -- 创建装置
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 5 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget_5_failed")
        return -1
    end
    -- 创建装置
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 6 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget_6_failed")
        return -1
    end

    return 0
end

-- 触发条件
function condition_EVENT_GADGET_STATE_CHANGE_7(context, evt)
    -- 判断物件是否解锁
    if 4 ~= evt.param2 or GadgetState.GearStart ~= evt.param1 then
        return false
    end

    return true
end

-- 触发操作
function action_EVENT_GADGET_STATE_CHANGE_7(context, evt)
    -- 变量"Key" + 1
    if 0 ~= ScriptLib.ChangeGroupVariableValue(context, "Key", 1) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : change_group_variable_key_failed_7")
        return -1
    end

    return 0
end

-- 触发条件
function condition_EVENT_GADGET_STATE_CHANGE_8(context, evt)
    -- 判断物件是否解锁
    if 5 ~= evt.param2 or GadgetState.GearStart ~= evt.param1 then
        return false
    end

    return true
end

-- 触发操作
function action_EVENT_GADGET_STATE_CHANGE_8(context, evt)
    -- 变量"Key" + 1
    if 0 ~= ScriptLib.ChangeGroupVariableValue(context, "Key", 1) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : change_group_variable_key_failed_8")
        return -1
    end

    return 0
end

-- 触发条件
function condition_EVENT_GADGET_STATE_CHANGE_9(context, evt)
    -- 判断物件是否解锁
    if 6 ~= evt.param2 or GadgetState.GearStart ~= evt.param1 then
        return false
    end

    return true
end

-- 触发操作
function action_EVENT_GADGET_STATE_CHANGE_9(context, evt)
    -- 变量"Key" + 1
    if 0 ~= ScriptLib.ChangeGroupVariableValue(context, "Key", 1) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : change_group_variable_key_failed_9")
        return -1
    end

    return 0
end

-- 触发条件
function condition_EVENT_VARIABLE_CHANGE_13(context, evt)
    if evt.param1 == evt.param2 then return false end
    -- 判断key是否等于3
    if ScriptLib.GetGroupVariableValue(context, "Key") ~= 3 then
        return false
    end

    return true
end

-- 触发操作
function action_EVENT_VARIABLE_CHANGE_13(context, evt)
    -- 创建物件
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 14 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget_14_failed")
        return -1
    end
    -- 解锁物件
    if 0 ~= ScriptLib.ChangeGroupGadget(context, { config_id = 14, state = GadgetState.Default }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : unlock_gadget_14_failed")
        return -1
    end
    -- 创建物件
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 15 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget_15_failed")
        return -1
    end
    -- 解锁物件
    if 0 ~= ScriptLib.ChangeGroupGadget(context, { config_id = 15, state = GadgetState.Default }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : unlock_gadget_15_failed")
        return -1
    end
    -- 创建物件
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 16 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget_16_failed")
        return -1
    end
    -- 解锁物件
    if 0 ~= ScriptLib.ChangeGroupGadget(context, { config_id = 16, state = GadgetState.Default }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : unlock_gadget_16_failed")
        return -1
    end
    -- 创建物件
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 17 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget_17_failed")
        return -1
    end
    -- 解锁物件
    if 0 ~= ScriptLib.ChangeGroupGadget(context, { config_id = 17, state = GadgetState.Default }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : unlock_gadget_17_failed")
        return -1
    end

    return 0
end
