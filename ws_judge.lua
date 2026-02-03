------------------------------------------------------------
-- ws_judge.lua（WS成否判定＋タイムアウト＋監視キュー）
------------------------------------------------------------
local ws_judge = {}

------------------------------------------------------------
-- 成功 / 失敗メッセージ分類テーブル
------------------------------------------------------------

-- 成功扱い（ダメージを与えた = 連携可能）
-- ダメージを与えたWSのみ連携につながる
local SUCCESS_WS = {
    -- 通常ダメージ
    [185]=true, -- uses WS, damage
    
    -- レジストしてもダメージあり
    [197]=true, -- uses WS, resists but damage
    
    -- ドレインWS（ダメージ + ドレイン効果）
    [187]=true, -- uses WS, HP drained
    [225]=true, -- uses WS, MP drained
    [226]=true, -- uses WS, TP drained
    
    -- Magic Burst
    [747]=true, -- uses WS, Magic Burst damage
    [748]=true, -- uses WS, Magic Burst HP drain
    [750]=true, -- uses WS, Magic Burst MP drain
    [752]=true, -- uses WS, Magic Burst TP drain
}

-- 失敗扱い（ミス・ダメージ0・実行できない）
FAIL_WS = {
    -- WS実行不可
    [89]=true,  -- Unable to use weapon skill
    [90]=true,  -- Unable to use weapon skill
    [190]=true, -- cannot use that weapon ability
    [191]=true, -- unable to use weapon skills
    [192]=true, -- not enough TP
    
    -- ミス・無効
    [188]=true, -- uses WS, misses
    [189]=true, -- uses WS, no effect
    [193]=true, -- WS cannot be used against target
    
    -- 距離・視線
    [198]=true, -- target is too far away
    [328]=true, -- target is too far away
    [217]=true, -- cannot see target
    [219]=true, -- cannot see target
    
    -- 照準中断（遠隔・射撃WS用）
    [218]=true, -- move and interrupt aim
    [220]=true, -- move and interrupt aim
    
    -- ターゲット状態
    [203]=true, -- target is status
}

------------------------------------------------------------
-- 状態
------------------------------------------------------------
local state = {
    active      = false,
    ws_name     = nil,
    source_set  = nil,
    start_time  = 0,

    last_result     = nil,
    last_result_src = nil,

    queue = {},
}

ws_judge.state = state

------------------------------------------------------------
-- 内部：次の監視要求を開始
------------------------------------------------------------
local function start_next()
    if state.active then return end
    if #state.queue == 0 then return end

    local req = table.remove(state.queue, 1)
    ws_judge.start(req.ws_name, req.source_set)
end

------------------------------------------------------------
-- 監視開始
------------------------------------------------------------
function ws_judge.start(ws_name, source_set)
    if state.active then
        table.insert(state.queue, { ws_name = ws_name, source_set = source_set })
        return
    end

    state.active      = true
    state.ws_name     = ws_name
    state.source_set  = source_set
    state.start_time  = os.clock()

    state.last_result     = nil
    state.last_result_src = nil
end

------------------------------------------------------------
-- タイムアウトチェック（1.5秒）
------------------------------------------------------------
function ws_judge.check_timeout()
    if not state.active then return end

    local now = os.clock()
    if now - state.start_time >= 1.5 then
        state.active = false
        state.last_result     = "fail"
        state.last_result_src = state.source_set
        start_next()
    end
end

------------------------------------------------------------
-- 成功判定
------------------------------------------------------------
local function is_success(hit, act)
    if act.category ~= 3 then
        return false
    end
	
	local p = windower.ffxi.get_player()
    if not p or act.actor_id ~= p.id then
        return false
    end


    local msg   = hit.message or 0
    local param = hit.param   or 0

    if SUCCESS_WS[msg] then return true end
    if param > 0 then return true end

    return false
end

------------------------------------------------------------
-- 失敗判定（ミス・ダメージ0）
------------------------------------------------------------
local function is_fail(hit, act)
    if act.category ~= 3 then
        return false
    end

    local p = windower.ffxi.get_player()
    if not p or act.actor_id ~= p.id then
        return false
    end

    local msg   = hit.message or 0
    local param = hit.param   or 0

    if FAIL_WS[msg] then return true end
    if param == 0 then return true end

    return false
end

------------------------------------------------------------
-- action イベント
------------------------------------------------------------
function ws_judge.on_action(act)
    if not state.active then return end

    local p = windower.ffxi.get_player()
    if not p or act.actor_id ~= p.id then return end

    local tgt = act.targets and act.targets[1]
    local hit = tgt and tgt.actions and tgt.actions[1]

    if not hit then
        return
    end

    --------------------------------------------------------
    -- 成功判定
    --------------------------------------------------------
    if is_success(hit, act) then
        state.active = false
        state.last_result     = "success"
        state.last_result_src = state.source_set
        start_next()
        return
    end

    --------------------------------------------------------
    -- 失敗判定
    --------------------------------------------------------
    if is_fail(hit, act) then
        state.active = false
        state.last_result     = "fail"
        state.last_result_src = state.source_set
        start_next()
        return
    end
end

------------------------------------------------------------
-- 結果取得
------------------------------------------------------------
function ws_judge.consume_result_for(source_set)
    if state.last_result
    and state.last_result_src == source_set
    then
        local r = state.last_result

        state.last_result     = nil
        state.last_result_src = nil

        return r
    end
    return nil
end

return ws_judge