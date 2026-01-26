------------------------------------------------------------
-- magic_judge.lua（成否判定＋MP減少＋タイムアウト＋監視キュー）
------------------------------------------------------------
local magic_judge = {}

------------------------------------------------------------
-- 成功 / 失敗メッセージ分類テーブル
------------------------------------------------------------

-- ③ 詠唱完了（成功扱い）
local SUCCESS_CAST = {
    [2]=true, [7]=true, [24]=true, [25]=true, [26]=true,
    [82]=true, [83]=true, [93]=true, [113]=true,
    [230]=true, [236]=true, [237]=true,
    [263]=true, [264]=true, [265]=true, [276]=true,
    [357]=true, [358]=true, [367]=true, [587]=true, [588]=true,

    [266]=true, [267]=true, [268]=true, [269]=true, [270]=true,
    [271]=true, [272]=true, [280]=true,

    [341]=true, [342]=true, [343]=true, [344]=true,
    [350]=true, [378]=true, [400]=true, [401]=true,

    [570]=true, [571]=true, [572]=true,

    [281]=true, [366]=true, [430]=true, [431]=true,
    [454]=true, [736]=true,

    [252]=true, [274]=true, [275]=true,
    [379]=true, [747]=true, [748]=true, [749]=true,
    [750]=true, [751]=true, [752]=true, [753]=true,
    [754]=true, [755]=true,

    [284]=true, [653]=true, [654]=true,
    [655]=true, [656]=true,

    [156]=true, [283]=true, [336]=true, [423]=true, [659]=true,

    [309]=true, [329]=true, [330]=true, [331]=true,
    [332]=true, [333]=true, [334]=true, [335]=true,

    [382]=true, [383]=true, [384]=true,
    [385]=true, [386]=true, [387]=true, [388]=true,
    [389]=true, [390]=true, [391]=true, [392]=true,
    [393]=true, [394]=true, [395]=true, [396]=true,
    [397]=true, [398]=true,

    [533]=true, [534]=true,

    [642]=true, [648]=true, [650]=true, [651]=true,

    [652]=true,

    [792]=true,

    [800]=true,

    [802]=true, [803]=true, [804]=true,

    [805]=true, [806]=true,

    [1023]=true,
}

-- ① 詠唱不可 / ② 詠唱中断
local FAIL_CAST = {
    [16]=true, [68]=true, [313]=true,

    [34]=true, [35]=true, [49]=true,
    [4]=true, [78]=true, [154]=true, [198]=true, [328]=true,
    [5]=true, [36]=true, [217]=true, [219]=true,
    [48]=true, [155]=true, [517]=true,
    [128]=true, [130]=true,
    [40]=true, [47]=true, [71]=true, [72]=true, [86]=true,
    [316]=true, [338]=true, [348]=true, [349]=true, [700]=true, [717]=true,
    [337]=true, [345]=true, [346]=true, [347]=true,
    [569]=true, [574]=true, [575]=true,
    [581]=true, [660]=true, [661]=true, [662]=true,
    [665]=true, [666]=true,
    [649]=true,
    [410]=true, [412]=true, [518]=true, [742]=true,
    [745]=true, [773]=true, [777]=true,
}

------------------------------------------------------------
-- 状態
------------------------------------------------------------
local state = {
    active      = false,
    spell_name  = nil,
    source_set  = nil,
    start_time  = 0,

    last_result         = nil,
    last_result_src     = nil,

    mp_before = 0,
    mp_after  = 0,
    mp_decreased = false,
}

magic_judge.state = state

------------------------------------------------------------
-- 監視開始
------------------------------------------------------------
function magic_judge.start(spell_name, source_set)
    state.active      = true
    state.spell_name  = spell_name
    state.source_set  = source_set
    state.start_time  = os.clock()

    state.last_result         = nil
    state.last_result_src     = nil

    local p = windower.ffxi.get_player()
    state.mp_before = p and p.vitals.mp or 0
    state.mp_after  = state.mp_before
    state.mp_decreased = false
end

------------------------------------------------------------
-- MP減少チェック
------------------------------------------------------------
function magic_judge.check_mp()
    if not state.active then return end

    local p = windower.ffxi.get_player()
    if not p then return end

    state.mp_after = p.vitals.mp or 0

    if state.mp_after < state.mp_before then
        state.mp_decreased = true
    end
end

------------------------------------------------------------
-- タイムアウトチェック
------------------------------------------------------------
function magic_judge.check_timeout()
    if not state.active then return end

    local now = os.clock()
    local elapsed = now - state.start_time

    if elapsed >= 1.5 then
        state.active = false
        state.last_result     = "fail"
        state.last_result_src = state.source_set
    end
end

------------------------------------------------------------
-- 成功判定
------------------------------------------------------------
local function is_success(hit, act)
    if act.category == 4 then
        return true
    end

    if not hit then
        return false
    end

    local msg   = hit.message or 0
    local param = hit.param   or 0

    if SUCCESS_CAST[msg] then return true end
    if param > 0 then return true end
    if state.mp_decreased then return true end

    return false
end

------------------------------------------------------------
-- 失敗判定
------------------------------------------------------------
local function is_fail(hit, act)
    if not hit then return false end

    local msg = hit.message or 0

    if FAIL_CAST[msg] then return true end

    if act.category ~= 4 and not is_success(hit, act) then
        return true
    end

    return false
end

------------------------------------------------------------
-- action イベント
------------------------------------------------------------
function magic_judge.on_action(act)
    if not state.active then return end

    local p = windower.ffxi.get_player()
    if not p or act.actor_id ~= p.id then return end

    local tgt = act.targets and act.targets[1]
    local hit = tgt and tgt.actions and tgt.actions[1]

    if not hit and act.category ~= 4 then
        return
    end

    --------------------------------------------------------
    -- 成功判定
    --------------------------------------------------------
    if is_success(hit, act) then
        state.active = false
        state.last_result     = "success"
        state.last_result_src = state.source_set
        return
    end

    --------------------------------------------------------
    -- 失敗判定
    --------------------------------------------------------
    if is_fail(hit, act) then
        state.active = false
        state.last_result     = "fail"
        state.last_result_src = state.source_set
        return
    end
end

------------------------------------------------------------
-- chat/message パケット監視（詠唱不可系の fail 判定）
------------------------------------------------------------
local packets = require('packets')

windower.register_event('incoming chunk', function(id, data)
    -- 監視中でなければ無視
    if not state.active then return end

    -- 0x29 = Action Message, 0x0A = Chat Message
    if id ~= 0x29 and id ~= 0x0A then
        return
    end

    local pkt = packets.parse('incoming', data)
    if not pkt then return end

    -- メッセージID取得
    local msg_id = pkt['Message ID']
    if not msg_id then return end

    -- FAIL_CAST に該当する詠唱不可メッセージ
    if FAIL_CAST[msg_id] then
        state.active = false
        state.last_result     = "fail"
        state.last_result_src = state.source_set
    end
end)

------------------------------------------------------------
-- 結果取得
------------------------------------------------------------
function magic_judge.consume_result_for(source_set)
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

return magic_judge