-- 基础信息
local base_info = {
	group_id = 100000000
}

--================================================================
--
-- 配置
--
--================================================================

-- 怪物
monsters = {
    { config_id = 67311, monster_id = 24810801, pos = { x = 2322, y = 276.36, z = -747 }, rot = { x = 0.000, y = 0.000, z = 0.000 }, level = 1 }
}

-- NPC
npcs = {
}

-- 装置
gadgets = {
    -- 开始压力板
	{ config_id = 666, gadget_id = 70360005, pos = { x = 1932, y = 196.4, z = -1265 }, rot = { x = 0, y = 0, z = 0 }, level = 1 },
    -- 压力板附属莫娜星空水池
    { config_id = 6661, gadget_id = 70220113, pos = { x = 1932, y = 196.6, z = -1265 }, rot = { x = 0, y = 0, z = 0 }, level = 1 },
    -- 第一阶段建筑风场
    { config_id = 667, gadget_id = 70690029, pos = { x = 1932, y = 196, z = -1265 }, rot = { x = 0.000, y = 0.000, z = 0.000 }, level = 1 },
    { config_id = 668, gadget_id = 70690001, pos = { x = 1942, y = 215, z = -1264 }, rot = { x = 0.000, y = 91.000, z = 0.000 }, level = 1 },
    { config_id = 669, gadget_id = 70690001, pos = { x = 1958, y = 215, z = -1264 }, rot = { x = 0.000, y = 91.000, z = 0.000 }, level = 1 },
    { config_id = 670, gadget_id = 70690001, pos = { x = 1967, y = 216, z = -1264 }, rot = { x = 120.000, y = 91.000, z = 0.000 }, level = 1 },
    { config_id = 671, gadget_id = 70690001, pos = { x = 1984, y = 230, z = -1264 }, rot = { x = 120.000, y = 91.000, z = 0.000 }, level = 1 },
    -- 平台 原id70290234
    { config_id = 672, gadget_id = 70310399, pos = { x = 2000, y = 245, z = -1264 }, rot = { x = 0.000, y = 91.000, z = 0.000 }, level = 1 },
    -- 过渡风方碑
    { config_id = 673, gadget_id = 70900039, pos = { x = 2001.024, y = 246.6, z = -1262.464 }, rot = { x = 0.000, y = 91.000, z = 0.000 }, level = 1 },
    -- 风蛋 过渡风方碑的附属
    { config_id = 6731, gadget_id = 70220011, pos = { x = 2001.024, y = 247.5, z = -1262.464 }, rot = { x = 0.000, y = 0.000, z = 0.000 }, level = 1 },
    { config_id = 6732, gadget_id = 70220011, pos = { x = 2001.024, y = 252.5, z = -1262.464 }, rot = { x = 0.000, y = 0.000, z = 0.000 }, level = 1 },
    { config_id = 6733, gadget_id = 70220011, pos = { x = 2001.024, y = 256.1, z = -1262.464 }, rot = { x = 0.000, y = 0.000, z = 0.000 }, level = 1 },
    -- 干扰机器 过渡风方碑的附属
    { config_id = 6734, gadget_id = 70950038, pos = { x = 2001.184, y = 244.5, z = -1265.808 }, rot = { x = 0.000, y = 0.000, z = 0.000 }, level = 1 },
    -- 第二阶段建筑风场
    { config_id = 674, gadget_id = 70690029, pos = { x = 2000, y = 245, z = -1264 }, rot = { x = 0.000, y = 0.000, z = 0.000 }, level = 1 },
    { config_id = 675, gadget_id = 70690001, pos = { x = 2006, y = 264, z = -1259 }, rot = { x = 0.000, y = 65.000, z = 0.000 }, level = 1 },
    { config_id = 676, gadget_id = 70690001, pos = { x = 2033, y = 262, z = -1247 }, rot = { x = 0.000, y = 65.000, z = 0.000 }, level = 1 },
    { config_id = 677, gadget_id = 70690001, pos = { x = 2033, y = 262, z = -1247 }, rot = { x = 0.000, y = 65.000, z = 0.000 }, level = 1 },
    { config_id = 678, gadget_id = 70690002, pos = { x = 2051, y = 262, z = -1238 }, rot = { x = 0.000, y = 65.000, z = 0.000 }, level = 1 },
    { config_id = 679, gadget_id = 70690001, pos = { x = 2096, y = 260, z = -1215 }, rot = { x = 0.000, y = 38.000, z = 0.000 }, level = 1 },
    { config_id = 680, gadget_id = 70690001, pos = { x = 2108, y = 260, z = -1199 }, rot = { x = 0.000, y = 38.000, z = 0.000 }, level = 1 },
    { config_id = 681, gadget_id = 70690001, pos = { x = 2108, y = 260, z = -1199 }, rot = { x = 0.000, y = 38.000, z = 0.000 }, level = 1 },
    { config_id = 682, gadget_id = 70690001, pos = { x = 2115, y = 260, z = -1184 }, rot = { x = 0.000, y = 32.000, z = 0.000 }, level = 1 },
    { config_id = 683, gadget_id = 70690001, pos = { x = 2121, y = 260, z = -1172 }, rot = { x = 0.000, y = 32.000, z = 0.000 }, level = 1 },
    { config_id = 684, gadget_id = 71700118, pos = { x = 2139, y = 255, z = -1137 }, rot = { x = 0.000, y = 28.000, z = 0.000 }, level = 1 },
    -- 左侧建筑风场
    { config_id = 685, gadget_id = 70690029, pos = { x = 2132, y = 253, z = -1133 }, rot = { x = 0.000, y = 0.000, z = 0.000 }, level = 1 },
    { config_id = 686, gadget_id = 71700119, pos = { x = 2114, y = 268, z = -1125 }, rot = { x = 0.000, y = 0.000, z = 0.000 }, level = 1 },
    -- 2-3左侧过渡方碑 火雷 687冰方碑 688草方碑
    { config_id = 687, gadget_id = 70900009, pos = { x = 2113.873, y = 268.006, z = -1116.5247 }, rot = { x = 0.000, y = 78.000, z = 0.000 }, level = 1 },
    { config_id = 688, gadget_id = 70900050, pos = { x = 2123.811, y = 268.08, z = -1125.2351 }, rot = { x = 0.000, y = 78.000, z = 0.000 }, level = 1 },
    -- 右侧建筑风场
    { config_id = 689, gadget_id = 70690029, pos = { x = 2145, y = 253, z = -1140 }, rot = { x = 0.000, y = 0.000, z = 0.000 }, level = 1 },
    { config_id = 690, gadget_id = 71700119, pos = { x = 2159, y = 268, z = -1146 }, rot = { x = 0.000, y = 0.000, z = 0.000 }, level = 1 },
    -- 2-3右侧过渡方碑 火雷 70330441海市蜃楼火方碑 70900402鹤观雷方碑
    { config_id = 691, gadget_id = 70330441, pos = { x = 2168.8853, y = 268.08, z = -1146.3499 }, rot = { x = 0.000, y = 78.000, z = 0.000 }, level = 1 },
    { config_id = 692, gadget_id = 70900402, pos = { x = 2159.017, y = 268.066, z = -1136.473 }, rot = { x = 0.000, y = 78.000, z = 0.000 }, level = 1 },
    -- 第三阶段 最后的风场
    { config_id = 693, gadget_id = 70220103, pos = { x = 2143, y = 274, z = -1128 }, rot = { x = 0.000, y = 0.000, z = 0.000 }, level = 1 },
    { config_id = 694, gadget_id = 70690001, pos = { x = 2148, y = 271, z = -1118 }, rot = { x = 0.000, y = 25, z = 0.000 }, level = 1 },
    { config_id = 695, gadget_id = 70690001, pos = { x = 2155, y = 271, z = -1102 }, rot = { x = 0.000, y = 25, z = 0.000 }, level = 1 },
    { config_id = 696, gadget_id = 70690001, pos = { x = 2162, y = 271, z = -1087 }, rot = { x = 0.000, y = 25, z = 0.000 }, level = 1 },
    { config_id = 697, gadget_id = 70690001, pos = { x = 2169, y = 271, z = -1070 }, rot = { x = 0.000, y = 25, z = 0.000 }, level = 1 },
    { config_id = 698, gadget_id = 70690001, pos = { x = 2176, y = 271, z = -1053 }, rot = { x = 0.000, y = 25, z = 0.000 }, level = 1 },
    { config_id = 699, gadget_id = 70690029, pos = { x = 2187, y = 269, z = -1029 }, rot = { x = 0.000, y = 25, z = 0.000 }, level = 1 },
    { config_id = 700, gadget_id = 70690001, pos = { x = 2193, y = 287, z = -1015 }, rot = { x = 0.000, y = 25, z = 0.000 }, level = 1 },
    { config_id = 701, gadget_id = 70690029, pos = { x = 2201, y = 285, z = -997 }, rot = { x = 0.000, y = 25, z = 0.000 }, level = 1 },
    { config_id = 702, gadget_id = 70690001, pos = { x = 2210, y = 291, z = -977 }, rot = { x = 0.000, y = 25, z = 0.000 }, level = 1 },
    { config_id = 703, gadget_id = 70690001, pos = { x = 2216, y = 291, z = -963 }, rot = { x = 0.000, y = 25, z = 0.000 }, level = 1 },
    { config_id = 704, gadget_id = 70690001, pos = { x = 2221, y = 291, z = -951 }, rot = { x = 0.000, y = 25, z = 0.000 }, level = 1 },
    { config_id = 705, gadget_id = 70690001, pos = { x = 2226, y = 291, z = -938 }, rot = { x = 0.000, y = 25, z = 0.000 }, level = 1 },
    { config_id = 706, gadget_id = 70690001, pos = { x = 2235, y = 291, z = -918 }, rot = { x = 0.000, y = 25, z = 0.000 }, level = 1 },
    { config_id = 707, gadget_id = 70690001, pos = { x = 2240, y = 291, z = -906 }, rot = { x = 0.000, y = 25, z = 0.000 }, level = 1 },
    { config_id = 708, gadget_id = 70690011, pos = { x = 2318, y = 250, z = -757 }, rot = { x = 0.000, y = 25, z = 0.000 }, level = 1 },
    { config_id = 709, gadget_id = 70220103, pos = { x = 2260, y = 291, z = -860 }, rot = { x = 0.000, y = 0, z = 0.000 }, level = 1 },
    { config_id = 710, gadget_id = 70220103, pos = { x = 2282, y = 273, z = -817 }, rot = { x = 0.000, y = 0, z = 0.000 }, level = 1 },
    { config_id = 711, gadget_id = 70220103, pos = { x = 2293, y = 257, z = -786 }, rot = { x = 0.000, y = 0, z = 0.000 }, level = 1 },
    -- 终点机关
    { config_id = 712, gadget_id = 70360348, pos = { x = 2322, y = 276.36, z = -747 }, rot = { x = 0.000, y = 0, z = 0.000 }, level = 1 }

}

-- 区域
regions = {
    -- 区域测试
    { config_id = 18001, shape = RegionShape.SPHERE, radius = 30, pos = { x = 2322, y = 276.36, z = -747 } }
}

-- 触发器
triggers = {
    -- 压力板 有交互的要用GADGET_STATE_CHANGE
	{ config_id = 1310005, name = "GADGET_STATE_CHANGE_310005", event = EventType.EVENT_GADGET_STATE_CHANGE, source = "", condition = "condition_EVENT_GADGET_STATE_CHANGE_310005", action = "action_EVENT_GADGET_STATE_CHANGE_310005", trigger_count = 0 },
	-- 1-2阶段过渡方碑 以及二阶段的内容
	{ config_id = 1310006, name = "GADGET_STATE_CHANGE_310006", event = EventType.EVENT_GADGET_STATE_CHANGE, source = "", condition = "condition_EVENT_GADGET_STATE_CHANGE_310006", action = "action_EVENT_GADGET_STATE_CHANGE_310006" },
    -- 2-3阶段过渡方碑
	{ config_id = 1310007, name = "GADGET_STATE_CHANGE_310007", event = EventType.EVENT_GADGET_STATE_CHANGE, source = "", condition = "condition_EVENT_GADGET_STATE_CHANGE_310007", action = "action_EVENT_GADGET_STATE_CHANGE_310007" },
	{ config_id = 1310008, name = "GADGET_STATE_CHANGE_310008", event = EventType.EVENT_GADGET_STATE_CHANGE, source = "", condition = "condition_EVENT_GADGET_STATE_CHANGE_310008", action = "action_EVENT_GADGET_STATE_CHANGE_310008" },
	{ config_id = 1310009, name = "GADGET_STATE_CHANGE_310009", event = EventType.EVENT_GADGET_STATE_CHANGE, source = "", condition = "condition_EVENT_GADGET_STATE_CHANGE_310009", action = "action_EVENT_GADGET_STATE_CHANGE_310009" },
	{ config_id = 1310010, name = "GADGET_STATE_CHANGE_310010", event = EventType.EVENT_GADGET_STATE_CHANGE, source = "", condition = "condition_EVENT_GADGET_STATE_CHANGE_310010", action = "action_EVENT_GADGET_STATE_CHANGE_310010" },
    -- 终点区域
	{ config_id = 310011, name = "ENTER_REGION_310011", event = EventType.EVENT_ENTER_REGION, source = "", condition = "condition_EVENT_ENTER_REGION_310011", action = "action_EVENT_ENTER_REGION_310011" },
}

-- 变量
variables = {
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
		-- suite_id = 1,
		-- description = ,
		monsters = { },
		gadgets = { 666, 673 },
		regions = { },
		triggers = { "GADGET_STATE_CHANGE_310005", "GADGET_STATE_CHANGE_310006", "GADGET_STATE_CHANGE_310007", "GADGET_STATE_CHANGE_310008", "GADGET_STATE_CHANGE_310009", "GADGET_STATE_CHANGE_310010", "VARIABLE_CHANGE_310011" },
		rand_weight = 100
	}
}

--================================================================
--
-- 触发器
--
--================================================================

-- 触发条件 第一个压力板
function condition_EVENT_GADGET_STATE_CHANGE_310005(context, evt)
	if 666 ~= evt.param2 or GadgetState.GearStart ~= evt.param1 then
		return false
	end

	return true
end
-- 触发操作
function action_EVENT_GADGET_STATE_CHANGE_310005(context, evt)
	-- play_type含义：1·代表开始播放； 2·代表停止播放
	-- 在指定位置播放或停止音效资源
    -- Sfx_Quest_underConstruction修理零件 Audio_Lua_kanun_melody_2难听的肝痛琴声 Audio_Lua_kanun_melody_6好听的肝痛琴声 LevelHornSound001号角 YinLvDao_Tone_04_True琴声 sfx_quest_WQ_ChuanLingShuShi_xylophone一串琴声
    local pos = {x=1932, y=196.4, z=-1265}
    if 0 ~= ScriptLib.ScenePlaySound(context, {play_pos = pos, sound_name = "Audio_Lua_kanun_melody_6", play_type= 1, is_broadcast = true }) then
      ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : active_soundplay")
                return -1
    end
    -- 调用提示id为 20010102 的提示UI，会显示在屏幕中央偏下位置，id索引自 ReminderData表格
    if 0 ~= ScriptLib.ShowReminder(context, 20010101) then
      ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : active_reminder_ui")
        return -1
    end
	-- 创建gadget
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 6661 }) then
      ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
      return -1
    end
	if 0 ~= ScriptLib.CreateGadget(context, { config_id = 667 }) then
	  ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
	  return -1
	end
	if 0 ~= ScriptLib.CreateGadget(context, { config_id = 668 }) then
      ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
      return -1
    end
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 669 }) then
      ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
      return -1
    end
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 670 }) then
      ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
      return -1
    end
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 671 }) then
      ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
      return -1
    end
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 672 }) then
      ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
      return -1
    end
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 673 }) then
      ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
      return -1
    end
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 6731 }) then
      ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
      return -1
    end
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 6732 }) then
      ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
      return -1
    end
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 6733 }) then
      ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
      return -1
    end
    --[[
    怪物使用方法
	if 0 ~= ScriptLib.CreateMonster(context, { config_id = 6734 }) then
      ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_monster")
      return -1
    end
    --]]
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 6734 }) then
      ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
      return -1
    end
	return 0
end

-- 触发条件 第一个风方碑
function condition_EVENT_GADGET_STATE_CHANGE_310006(context, evt)
	if 673 ~= evt.param2 or GadgetState.GearStart ~= evt.param1 then
		return false
	end

	return true
end
-- 触发操作
function action_EVENT_GADGET_STATE_CHANGE_310006(context, evt)
    --[[ 创建风场 已被风蛋代替
	if 0 ~= ScriptLib.CreateGadget(context, { config_id = 674 }) then
	    ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
	    return -1
	end
    --]]
	if 0 ~= ScriptLib.CreateGadget(context, { config_id = 675 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
        return -1
    end
	if 0 ~= ScriptLib.CreateGadget(context, { config_id = 676 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
        return -1
    end
	if 0 ~= ScriptLib.CreateGadget(context, { config_id = 677 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
        return -1
    end
	if 0 ~= ScriptLib.CreateGadget(context, { config_id = 678 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
        return -1
    end
	if 0 ~= ScriptLib.CreateGadget(context, { config_id = 679 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
        return -1
    end
	if 0 ~= ScriptLib.CreateGadget(context, { config_id = 680 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
        return -1
    end
	if 0 ~= ScriptLib.CreateGadget(context, { config_id = 681 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
        return -1
    end
	if 0 ~= ScriptLib.CreateGadget(context, { config_id = 682 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
        return -1
    end
	if 0 ~= ScriptLib.CreateGadget(context, { config_id = 683 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
        return -1
    end
	if 0 ~= ScriptLib.CreateGadget(context, { config_id = 684 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
        return -1
    end
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 685 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
        return -1
    end
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 686 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
        return -1
    end
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 687 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
        return -1
    end
	return 0
end

--================================================================
--
-- 最后的方碑和风场
--
--================================================================

-- 触发条件 如果左火方碑被点亮
function condition_EVENT_GADGET_STATE_CHANGE_310007(context, evt)
	if 687 ~= evt.param2 or GadgetState.GearStart ~= evt.param1 then
		return false
	end

	return true
end
-- 触发操作 创建左雷方碑
function action_EVENT_GADGET_STATE_CHANGE_310007(context, evt)
	-- 创建gadget
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 688 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
        return -1
    end
	return 0
end

-- 触发条件如果左雷方碑被点亮
function condition_EVENT_GADGET_STATE_CHANGE_310008(context, evt)
	if 688 ~= evt.param2 or GadgetState.GearStart ~= evt.param1 then
		return false
	end

	return true
end
-- 触发操作
function action_EVENT_GADGET_STATE_CHANGE_310008(context, evt)
	-- 创建右建筑
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 689 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
        return -1
    end
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 690 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
        return -1
    end
    -- 创建右火方碑
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 691 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
        return -1
    end
	return 0
end

-- 触发条件 如果右火方碑被点亮
function condition_EVENT_GADGET_STATE_CHANGE_310009(context, evt)
	if 691 ~= evt.param2 or GadgetState.GearStart ~= evt.param1 then
		return false
	end

	return true
end
-- 触发操作 创建右雷方碑
function action_EVENT_GADGET_STATE_CHANGE_310009(context, evt)
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 692 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
        return -1
    end
	return 0
end

-- 触发条件 如果右雷方碑被点亮
function condition_EVENT_GADGET_STATE_CHANGE_310010(context, evt)
	if 692 ~= evt.param2 or GadgetState.GearStart ~= evt.param1 then
		return false
	end

	return true
end
-- 触发操作 创建最后的风场
function action_EVENT_GADGET_STATE_CHANGE_310010(context, evt)
    -- play_type含义：1·代表开始播放； 2·代表停止播放
	-- 在指定位置播放或停止音效资源
    -- Sfx_Quest_underConstruction修理零件 Audio_Lua_kanun_melody_2难听的肝痛琴声 Audio_Lua_kanun_melody_6好听的肝痛琴声 LevelHornSound001号角 YinLvDao_Tone_04_True琴声 sfx_quest_WQ_ChuanLingShuShi_xylophone一串琴声
    local pos = {x=2159.017, y=268.066, z=-1136.473}
    if 0 ~= ScriptLib.ScenePlaySound(context, {play_pos = pos, sound_name = "LevelHornSound001", play_type= 1, is_broadcast = true }) then
      ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : active_soundplay")
                return -1
    end
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 693 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
        return -1
    end
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 694 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
        return -1
    end
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 695 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
        return -1
    end
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 696 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
        return -1
    end
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 697 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
        return -1
    end
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 698 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
        return -1
    end
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 699 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
        return -1
    end
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 700 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
        return -1
    end
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 701 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
        return -1
    end
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 702 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
        return -1
    end
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 703 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
        return -1
    end
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 704 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
        return -1
    end
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 705 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
        return -1
    end
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 706 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
        return -1
    end
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 707 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
        return -1
    end
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 708 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
        return -1
    end
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 709 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
        return -1
    end
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 710 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
        return -1
    end
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 711 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
        return -1
    end
    if 0 ~= ScriptLib.CreateGadget(context, { config_id = 712 }) then
        ScriptLib.PrintContextLog(context, "@@ LUA_WARNING : create_gadget")
        return -1
    end
	return 0
end
