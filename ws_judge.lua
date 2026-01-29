------------------------------------------------------------
-- ws_judge.lua（WS成否判定＋タイムアウト＋監視キュー）
------------------------------------------------------------
local ws_judge = {}

------------------------------------------------------------
-- 成功 / 失敗メッセージ分類テーブル
------------------------------------------------------------
local SUCCESS_WS = {
    [185] = true,
}

FAIL_WS = {
    [89]=true,   -- Unable to use weapon skill.
    [90]=true,   -- Unable to use weapon skill.
    [188]=true,  -- WS miss
    [189]=true,  -- WS no effect
    [190]=true,  -- Cannot use that weapon ability.
    [191]=true,  -- Is unable to use weapon skills.
    [192]=true,  -- Does not have enough TP.
    [193]=true,  -- Cannot be used against that target.
    [198]=true,  -- Target is too far away.
    [203]=true,  -- Target is ${status}.
    [217]=true,  -- You cannot see ${target}.
    [218]=true,  -- You move and interrupt your aim.
    [219]=true,  -- You cannot see ${target}.
    [220]=true,  -- You move and interrupt your aim.
    [328]=true,  -- Target is too far away. (別ID)
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
-- chat/message パケット監視（WS実行不可：サーバ側）
------------------------------------------------------------
--local packets = require('packets')

--windower.register_event('incoming chunk', function(id, data)
    --if not state.active then return end

    -- 0x29 = Action Message, 0x0A = Chat Message
    --if id ~= 0x29 and id ~= 0x0A then
        --return
    --end

    --local pkt = packets.parse('incoming', data)
    --if not pkt then return end

    --local msg_id = pkt['Message ID']
    --if not msg_id then return end

    -- サーバ側の WS 実行不可
    --if FAIL_WS[msg_id] then
        --state.active = false
        --state.last_result     = "fail"
        --state.last_result_src = state.source_set
        --start_next()
    --end
--end)

------------------------------------------------------------
-- incoming text（クライアント側の WS 不発）
------------------------------------------------------------
--windower.register_event('incoming text', function(original, modified, mode, blocked)
    --if not state.active then return end

    --------------------------------------------------------
    -- WS がクライアント側で弾かれたときのカテゴリ
    -- ※文字列判定は不要。カテゴリだけで一括検出できる。
    --------------------------------------------------------
    --local ws_fail_categories = {
        --[6]  = true,  -- 行動不可（詠唱中・モーション中）
        --[31] = true,  -- 行動不可（ターゲット関連）
        --[32] = true,  -- 行動不可（TP不足など）
        --[33] = true,  -- 行動不可（視界など）
        --[63] = true,  -- 行動不可（その他）
    --}

	--if ws_fail_categories[mode] then
		--state.active = false
		--state.last_result     = "fail"
		--state.last_result_src = state.source_set
		--start_next()
	--end
--end)

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