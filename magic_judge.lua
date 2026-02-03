------------------------------------------------------------
-- magic_judge.lua（成否判定＋MP減少＋タイムアウト＋監視キュー）
------------------------------------------------------------
local magic_judge = {}

------------------------------------------------------------
-- 成功 / 失敗メッセージ分類テーブル
------------------------------------------------------------

-- ③ 詠唱完了（成功扱い）
-- 詠唱が完了した = 魔法が発動した
-- レジスト、無効、範囲外なども詠唱完了なので成功扱い
local SUCCESS_CAST = {
    -- "casts ${spell}" メッセージ - 魔法詠唱完了を示す
    [2]=true,   -- casts spell, damage
    [7]=true,   -- casts spell, HP recovery
    [42]=true,  -- casts spell on target
    [82]=true,  -- casts spell, target is status
    [83]=true,  -- casts spell, removes status
    [85]=true,  -- casts spell, resisted (詠唱は完了)
    [86]=true,  -- casts spell, outside area of effect (詠唱は完了)
    [93]=true,  -- casts spell, target vanishes
    [113]=true, -- casts spell, target falls
    [114]=true, -- casts spell, fails to take effect (詠唱は完了)
    [227]=true, -- casts spell, HP drained
    [228]=true, -- casts spell, MP drained
    [230]=true, -- casts spell, gains status
    [236]=true, -- casts spell, is status
    [237]=true, -- casts spell, receives status
    [252]=true, -- casts spell, Magic Burst damage
    [268]=true, -- casts spell, Magic Burst status
    [271]=true, -- casts spell, Magic Burst status
    [274]=true, -- casts spell, Magic Burst HP drain
    [275]=true, -- casts spell, Magic Burst MP drain
    [309]=true, -- casts spell on target
    [329]=true, -- casts spell, STR drain
    [330]=true, -- casts spell, DEX drain
    [331]=true, -- casts spell, VIT drain
    [332]=true, -- casts spell, AGI drain
    [333]=true, -- casts spell, INT drain
    [334]=true, -- casts spell, MND drain
    [335]=true, -- casts spell, CHR drain
    [341]=true, -- casts spell, status disappears
    [342]=true, -- casts spell, status disappears
    [430]=true, -- casts spell, magic effects drained
    [431]=true, -- casts spell, TP reduced
    [432]=true, -- casts spell, Accuracy/Evasion boost
    [433]=true, -- casts spell, MAB/MDB boost
    [454]=true, -- casts spell, TP drained
    [533]=true, -- casts spell, Accuracy drained
    [534]=true, -- casts spell, Attack drained
    [570]=true, -- casts spell, status ailments disappear
    [572]=true, -- casts spell, absorbs status ailments
    [642]=true, -- casts spell, absorbs status benefits
    [648]=true, -- leads casting, damage
    [650]=true, -- leads casting, Magic Burst damage
    [651]=true, -- leads casting, HP recovery
    [653]=true, -- casts spell, resisted, Immunobreak (詠唱は完了)
    [655]=true, -- casts spell, completely resisted (詠唱は完了)
    
    -- その他のレジスト・無効メッセージ (詠唱完了だが効果なし)
    [75]=true,  -- spell has no effect (詠唱は完了)
    [283]=true, -- No effect on target (詠唱は完了)
    [284]=true, -- resists the effects (詠唱は完了)
    [654]=true, -- resists, Immunobreak (詠唱は完了)
    [656]=true, -- completely resists (詠唱は完了)
}

-- ① 詠唱不可 / ② 詠唱中断
-- 詠唱が開始できなかった、または詠唱が中断された
local FAIL_CAST = {
    -- 詠唱中断
    [16]=true,  -- casting is interrupted
    [68]=true,  -- Debug: Casting interrupted
    
    -- 詠唱不可 (一般)
    [17]=true,  -- Unable to cast spells at this time
    [18]=true,  -- Unable to cast spells at this time
    [47]=true,  -- cannot cast spell
    [48]=true,  -- cannot be cast on target
    [49]=true,  -- unable to cast spells
    
    -- MP・ツール不足
    [34]=true,  -- not enough MP
    [35]=true,  -- lacks ninja tools
    
    -- 範囲・エリア制限
    [40]=true,  -- cannot use spell in this area
    [313]=true, -- out of range, unable to cast
    
    -- 召喚・ペット関連
    [338]=true, -- cannot summon avatars
    [345]=true, -- cannot heal while avatar summoned
    [348]=true, -- cannot call wyverns
    [349]=true, -- cannot call beasts
    [717]=true, -- cannot call alter egos
    
    -- 特殊条件
    [581]=true, -- Unable to cast, Astral Flow required
    [649]=true, -- cannot cast same spell (party member casting)
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
    
    -- ③: 詠唱不可後コールバック（遅延設定のため）
    on_cast_fail_callback = nil,
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
        
        -- ③: 詠唱不可後コールバック実行
        if state.on_cast_fail_callback then
            -- タイムアウト時のコールバックは必ず実行（pcall でエラーハンドリング）
            local success, err = pcall(state.on_cast_fail_callback, state.spell_name, state.source_set, "timeout")
            if not success then
                -- エラーが発生してもログに記録
                windower.add_to_chat(123, '[magic_judge] Callback error (timeout): ' .. tostring(err))
            end
        end
    end
end

------------------------------------------------------------
-- 成功判定
------------------------------------------------------------
local function is_success(hit, act)
    -- Category 4 = spell casting action
    -- However, category 4 alone doesn't guarantee success - the spell could be interrupted
    -- We need to check for actual success indicators
    
    if not hit then
        -- No hit data means no spell effect, so not a success
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
        
        -- ③: 詠唱不可後コールバック実行
        -- 注: これは魔法が発動したが失敗した場合（レジスト、中断等）
        -- 魔法が発動しない「詠唱不可」の場合はincoming chunkで検出される
        if state.on_cast_fail_callback then
            local success, err = pcall(state.on_cast_fail_callback, state.spell_name, state.source_set, "action_fail")
            if not success then
                windower.add_to_chat(123, '[magic_judge] Callback error (action_fail): ' .. tostring(err))
            end
        end
        
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
        
        -- ③: 詠唱不可後コールバック実行
        if state.on_cast_fail_callback then
            local success, err = pcall(state.on_cast_fail_callback, state.spell_name, state.source_set, "incoming_chunk")
            if not success then
                windower.add_to_chat(123, '[magic_judge] Callback error (incoming_chunk): ' .. tostring(err))
            end
        end
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

------------------------------------------------------------
-- 安全なリセット（コールバック実行後にクリア）
------------------------------------------------------------
function magic_judge.safe_reset(reason)
    if state.active then
        -- アクティブな監視がある場合はコールバックを呼ぶ
        if state.on_cast_fail_callback then
            local success, err = pcall(state.on_cast_fail_callback, state.spell_name, state.source_set, reason or "forced_reset")
            if not success then
                windower.add_to_chat(123, '[magic_judge] Callback error (safe_reset): ' .. tostring(err))
            end
        end
        
        state.active = false
    end
    
    -- 結果をクリア
    state.last_result = nil
    state.last_result_src = nil
end

return magic_judge