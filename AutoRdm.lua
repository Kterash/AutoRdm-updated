------------------------------------------------------------
-- AutoRdm（V5 ベース：MB 独立化＆WS_Detector 互換対応版・改定）
-- 作成: Kazuhiro+Copilot
-- 改定:
--  - MB2 正常完了時にタイムアウトログが出ないよう調整
--  - MBセット開始/終了ログ整備（終了は MB2完了 or 異常終了 のみ）
--  - 戦闘終了検出を一元化して、WS/MB/ターゲット終了ログの重複を防止
--  - WS_Detector.parse があれば parse を優先利用、無ければ analyze にフォールバック
--  - ログタグを【WS】【MB】【SP】【auto】【buff】等で分離
--  - 修正:
--    1) SP が MB を割り込んだ場合、MB を完全終了（再開しない）
--    2) MB 検出の時間判定に下限 3 秒を追加。時間外は MB 終了＋当該 WS を 1 回目として扱う
------------------------------------------------------------

_addon.name     = 'AutoRdm'
_addon.author   = 'Kazuhiro+Copilot'
_addon.version  = '5.20-v5-mbind-compat-fix'
_addon.commands = {'ardm'}

------------------------------------------------------------
-- 外部モジュール
------------------------------------------------------------
local res     = require('resources')
local packets = require('packets')
require('luau')

local skills = require('skills')
local magic_judge = require('magic_judge')
local ws_judge = require('ws_judge')
local WS_Detector = require('WS_Detector')
require('actions')
local bit = require('bit')

------------------------------------------------------------
-- 定数（ジョブID 等）
------------------------------------------------------------
local JOB_RDM = 5
local JOB_NIN = 13
local JOB_BLM = 4

------------------------------------------------------------
-- spells（必要最小限の魔法定義）
------------------------------------------------------------
local spells = {
    utsu_ichi = {recast_id = 338, name = '空蝉の術:壱'},
    utsu_ni   = {recast_id = 339, name = '空蝉の術:弐'},
    stoneskin = {recast_id = 54,  name = 'ストンスキン'},
    cure4     = {recast_id = 4,   name = 'ケアルIV'},

    stun      = {recast_id = 252, name = 'スタン'},
    sleepga   = {recast_id = 273, name = 'スリプガ'},
    sleep2    = {recast_id = 259, name = 'スリプルII'},
    silence   = {recast_id = 59,  name = 'サイレス'},
    dispel    = {recast_id = 260, name = 'ディスペル'},
}

------------------------------------------------------------
-- WS セット（WS_Detector と独立）
------------------------------------------------------------
local WS = {
    seta = { ws1 = 'シャンデュシニュ',   ws2 = 'シャンデュシニュ' },
    setb = { ws1 = 'サベッジブレード', ws2 = 'シャンデュシニュ' },
    setc = { ws1 = 'セラフブレード',   ws2 = 'レッドロータス' },
}

------------------------------------------------------------
-- 行動不能デバフ判定（魔法/WS/行動を完全停止）
------------------------------------------------------------
local BUFF_PARALYSIS = 4
local BUFF_SILENCE   = 6
local BUFF_MUTE      = 7
local BUFF_STUN      = 2
local BUFF_TERROR    = 28
local BUFF_DOOM      = 15

local function has_action_blocking_debuff()
    local p = windower.ffxi.get_player()
    local buffs = p and p.buffs or {}
    for _, b in ipairs(buffs) do
        if b == BUFF_PARALYSIS or b == BUFF_SILENCE or b == BUFF_MUTE
        or b == BUFF_STUN or b == BUFF_TERROR or b == BUFF_DOOM then
            return true
        end
    end
    return false
end

------------------------------------------------------------
-- util
------------------------------------------------------------
local function now()
    return os.clock()
end

local function send_cmd(str)
    windower.send_command(windower.to_shift_jis(str))
end

local function log(msg)
    windower.add_to_chat(160, windower.to_shift_jis('[AutoRdm] ' .. msg))
end

local function get_player()
    return windower.ffxi.get_player()
end

local function get_buffs()
    local p = get_player()
    return (p and p.buffs) or {}
end

local function can_cast(id)
    local r = windower.ffxi.get_spell_recasts()
    return r and (r[id] == 0)
end

local function has_buff(id)
    for _, b in ipairs(get_buffs()) do
        if b == id then
            return true
        end
    end
    return false
end

local function is_sub_nin()
    local p = get_player()
    return p and p.sub_job_id == JOB_NIN
end

------------------------------------------------------------
-- monster_abilities の message → id キャッシュ
------------------------------------------------------------
local monster_abilities_by_message = nil

local function build_monster_abilities_by_message()
    monster_abilities_by_message = {}
    for id, ws in pairs(res.monster_abilities) do
        if ws.message and ws.message ~= 0 then
            monster_abilities_by_message[ws.message] = id
        end
    end
end

------------------------------------------------------------
-- ログ色設定（簡易）
------------------------------------------------------------
local log_colors = {
    start  = 219,
    finish = 158,
    abort  = 39,
    notice = 259,
    detect = 4,
    report = 207,
}

local function log_msg(category, text, name, event, extra)
    local color = log_colors[category] or 1
    local parts = {}
    if text then table.insert(parts, text) end
    if name then table.insert(parts, name) end
    if event then table.insert(parts, event) end
    if extra then table.insert(parts, extra) end
    local msg = table.concat(parts, ' ')
    windower.add_to_chat(color, windower.to_shift_jis(msg))
end

------------------------------------------------------------
-- state（全体状態）
------------------------------------------------------------
local state = {
    enabled = true,

    last_prerender_time = 0,
    last_prerender_tick = 0,

    ws = {
        active           = false,
        mode             = nil,
        phase            = 'idle',
        phase_started_at = 0,

        target_id         = nil,
        initial_target_id = nil,
        last_ws_name      = nil,

        ws1_name          = nil,
        ws1_props         = nil,
        ws1_confirmed     = false,

        ws1_retry_count   = 0,
        ws1_retry_next    = 0,

        ws2_name          = nil,
        ws2_props         = nil,

        sc_en             = nil,

        mb1_spell         = nil,
        mb2_reserved      = nil,
        mb2_spell         = nil,
        mb2_time          = 0,
        mb2_release_time  = 0,

        interrupt_mb      = false,
        interrupt_time    = 0,

        queued_mode       = nil,
        logged_reservation = false,
        retry_wait_logged = false,

        last_process_time = 0,
    },

    buffset = {
        active              = false,
        step                = 0,
        next_time           = 0,
        waiting_for_finish  = false,
        next_step_on_finish = 0,
        step_start_time     = 0,
    },

    current_special = {
        name             = nil,
        priority         = nil,
        start_time       = nil,
        pending_start    = nil,
        start_check_time = nil,
        recast_id        = nil,
        target           = nil,
        is_sleep2        = false,
    },

    queued_special = {
        name      = nil,
        recast_id = nil,
        target    = nil,
        is_sleep2 = false,
        priority  = nil,
    },

    casting        = false,
    last_target_id = nil,
    last_spell     = nil,
    cast_fail_time = nil,
    first_hit_done = false,

    combatbuff = {
        casting          = false,
        start_time       = nil,
        last_finish_time = 0,
        suspend_until    = 0,

        pending          = false,
        pending_spell    = nil,
        pending_target   = nil,
    },

    buffset_last_finish_time = 0,

    ws_motion           = false,
    ws_motion_start     = nil,
    ws_delay_until      = 0,
    magic_delay_until   = 0,
    special_delay_until = 0,

    suspend_buffs    = false,
    buff_resume_time = 0,

    retry = {
        active     = false,
        spell_name = nil,
        target     = nil,
        interval   = 0,
        next_time  = 0,
        is_mb      = false,
        pending    = false,
        count      = 0,
        max_count  = 2,
        spell_id   = nil,
        kind       = nil,
        from_queue = false,
    },

    last_detected_tp_move_id = nil,
    sleep2_initial = false,
    sleep2_waiting_for_confirm = false,
    sleep2_name = nil,
    sleep2_recast_id = nil,

    -- 新規: プレイヤーの前回 status（戦闘状態の遷移検出用）
    last_player_status = nil,
    -- 新規: 戦闘終了ログ抑止のための一時フラグ（タイムスタンプ）
    combat_end_suppressed_until = 0,
}

state.mbset = {
    active = false,
    count = 0,
    last_ws_time = 0,
    thresholds = {10,9,8,7},
    pending_mb1 = false,
    mb1_spell = nil,
    mb2_spell = nil,
    mb1_target = nil,
    mb2_target = nil,
    mb1_start_time = nil,
    mb2_time = 0,
    last_detected_sc = nil,
    last_props = nil,
    -- 新規: MB1 -> MB2 を待っているフラグ（タイムアウト挙動分岐用）
    awaiting_mb2 = false,
}

------------------------------------------------------------
-- SPECIAL_PRIORITY
------------------------------------------------------------
local SPECIAL_PRIORITY = {
    ["スタン"]     = 1,
    ["スリプガ"]   = 2,
    ["スリプルII"] = 3,
    ["サイレス"]   = 4,
    ["ディスペル"] = 5,
    ["ケアルIV"]   = 999,
}

------------------------------------------------------------
-- can_start_special（スペシャル実行ロック判定）
------------------------------------------------------------
local function can_start_special()
    if state.ws_motion then
        return false, "WSモーション中"
    end
    if now() < state.ws_delay_until then
        return false, "WS完了後ディレイ中"
    end
    if state.casting then
        return false, "魔法詠唱中"
    end
    if state.combatbuff and state.combatbuff.casting then
        return false, "戦闘バフ詠唱中"
    end
    if magic_judge and magic_judge.state and magic_judge.state.active then
        return false, "魔法判定中"
    end
    if now() < state.magic_delay_until then
        return false, "魔法完了後ディレイ中"
    end
    if now() < state.special_delay_until then
        return false, "SP完了後ディレイ中"
    end
    return true, nil
end

local function can_act()
    return not state.casting
end

local function is_any_spell_casting()
    if state.casting then return true end
    if magic_judge and magic_judge.state and magic_judge.state.active then return true end
    if state.current_special and state.current_special.name then return true end
    if state.combatbuff and state.combatbuff.casting then return true end
    return false
end

------------------------------------------------------------
-- find_lowest_hp_target（パーティ内最低HP%のメンバーを検索）
------------------------------------------------------------
local function find_lowest_hp_target()
    local party = windower.ffxi.get_party()
    if not party then return '<me>' end
    
    local lowest_hpp = 100
    local lowest_target = nil
    
    -- Check all party members (p0-p5)
    for i = 0, 5 do
        local member = party['p' .. i]
        if member and member.mob then
            local status = member.mob.status or 0
            local hpp = member.mob.hpp or 100
            -- Only consider alive party members (status 0=idle, 1=engaged)
            if (status == 0 or status == 1) and hpp < lowest_hpp then
                lowest_hpp = hpp
                lowest_target = '<p' .. i .. '>'
            end
        end
    end
    
    return lowest_target or '<me>'
end

------------------------------------------------------------
-- special 予約（1枠、優先度上書き）
------------------------------------------------------------
local function enqueue_special_spell(name, recast_id, target, is_sleep2, reason)
    if not name then return end
    local new_prio = SPECIAL_PRIORITY[name] or 999
    target = target or '<t>'
    is_sleep2 = not not is_sleep2
    reason = reason or '理由: 不明'

    if not state.queued_special.name then
        state.queued_special.name      = name
        state.queued_special.recast_id = recast_id
        state.queued_special.target    = target
        state.queued_special.is_sleep2 = is_sleep2
        state.queued_special.priority  = new_prio
        log_msg('notice', '【SP】', name, '予約')
    else
        local old_prio = state.queued_special.priority or 999
        if new_prio < old_prio then
            state.queued_special.name      = name
            state.queued_special.recast_id = recast_id
            state.queued_special.target    = target
            state.queued_special.is_sleep2 = is_sleep2
            state.queued_special.priority  = new_prio
            log_msg('report', '【SP】', name, '予約差し替え')
        else
            log_msg('abort', '【SP】', name, '予約無視')
        end
    end
end

------------------------------------------------------------
-- retry 操作（SP 統合）
------------------------------------------------------------
local function reset_retry()
    local r = state.retry
    r.active = false
    r.spell_name = nil
    r.target = nil
    r.interval = 0
    r.next_time = 0
    r.pending = false
    r.count = 0
    r.max_count = 2
    r.spell_id = nil
    r.kind = nil
    r.from_queue = false
    r.is_mb = false
end

local function start_retry(opts)
    if not opts or not opts.spell_name then return end
    local t = now()
    local r = state.retry
    r.active = true
    r.spell_name = opts.spell_name
    r.target = opts.target or '<me>'
    r.pending = true
    r.count = 0
    r.max_count = opts.max_count or 2
    r.spell_id = opts.spell_id or nil
    r.interval = opts.interval or 1.0
    r.next_time = t + r.interval
    r.kind = opts.kind or nil
    r.from_queue = opts.from_queue or false
    r.is_mb = opts.is_mb or false
end

------------------------------------------------------------
-- 味方判定
------------------------------------------------------------
local function is_friendly_actor(id)
    local m = windower.ffxi.get_mob_by_id(id)
    if not m then return false end
    local me = windower.ffxi.get_player()
    if not me then return false end
    if id == me.id then return true end
    if not m.is_npc then return true end
    if m.is_npc and m.in_party == true then return true end
    return false
end

------------------------------------------------------------
-- cast_spell（special / buffset / 他��
------------------------------------------------------------
local function cast_spell(spell, target, opts)
    opts = opts or {}
    local kind   = opts.kind
    local source = opts.source
    local t      = now()

    if kind == 'special' then
        if spell.recast_id and not can_cast(spell.recast_id) then
            reset_retry()
            return false
        end

        state.casting        = true
        state.last_spell     = spell.name
        state.cast_fail_time = t + 2.0

        if not (state.retry.active and source == 'retry') then
            start_retry{
                spell_name = spell.name,
                target     = target or '<me>',
                max_count  = opts.max_count or 2,
                spell_id   = spell.recast_id,
                interval   = opts.interval or 0.5,
                kind       = 'special',
                from_queue = opts.from_queue or false,
            }
        end

        magic_judge.start(spell.name, 'special')
        send_cmd(('input /ma "%s" %s'):format(spell.name, target or '<me>'))
        return true
    end

    if kind == 'buffset' then
        if not can_act() then return false end
        if spell.recast_id and not can_cast(spell.recast_id) then return false end

        send_cmd(('input /ma "%s" %s'):format(spell.name, target or '<me>'))
        return true
    end

    -- その他（MB 等）
    if not can_act() then return false end
    if spell.recast_id and not can_cast(spell.recast_id) then return false end

    if opts.is_mb then
        state.casting = true
        state.last_spell = spell.name
        state.cast_fail_time = t + 2.0
    end

    send_cmd(('input /ma "%s" %s'):format(spell.name, target or '<me>'))
    return true
end

------------------------------------------------------------
-- 戦闘バフ専用 cast_spell（state.casting を使わない）
------------------------------------------------------------
local function cast_spell_combatbuff(spell, target)
    if state.combatbuff.casting then
        return false
    end

    if spell.recast_id and not can_cast(spell.recast_id) then
        return false
    end

    local ok, reason = can_start_special()
    if not ok then
        state.combatbuff.pending = true
        state.combatbuff.pending_spell = spell
        state.combatbuff.pending_target = target or '<me>'
        log_msg('notice', '【auto】', spell.name, '予約')
        return true
    end

    state.combatbuff.casting    = true
    state.combatbuff.start_time = now()
    send_cmd(('input /ma "%s" %s'):format(spell.name, target or '<me>'))
    return true
end

------------------------------------------------------------
-- start_special_spell（特殊魔法開始）
-- ①: SP 発動時に MB セットが進行中なら MB を完全終了するよう変更
------------------------------------------------------------
-- Forward-declare reset_mbset so functions defined earlier can safely call it
local reset_mbset

local function start_special_spell(name, recast_id, target, is_sleep2, is_from_queue)
    local p = get_player()
    if not p then return end

    local ok, reason = can_start_special()
    if not ok then
        enqueue_special_spell(name, recast_id, target, is_sleep2, "理由: " .. reason)
        return
    end

    if name == spells.stun.name and p.sub_job_id ~= JOB_BLM then
        return
    end

    is_from_queue = not not is_from_queue
    is_sleep2 = not not is_sleep2
    target = target or '<t>'

    -- Cure IV target selection logic
    if name == spells.cure4.name then
        if p.vitals.hpp <= 60 then
            target = '<me>'
        else
            target = find_lowest_hp_target()
        end
    end

    if is_sleep2 and target == '<stnpc>' then
        send_cmd(('input /ma "%s" <stnpc>'):format(name))
        state.sleep2_initial = true
        state.sleep2_waiting_for_confirm = true
        state.sleep2_name = name
        state.sleep2_recast_id = recast_id
        return
    end

    if state.retry.active and state.retry.kind == 'special' then
        return
    end

    if is_any_spell_casting() then
        enqueue_special_spell(name, recast_id, target, is_sleep2, '理由: 他魔法詠唱中')
        return
    end

    -- SP 実行時は WS/BUFFSET だけでなく MB も中断（完全終了）して再開しない
    if state.ws.active then
        log_msg('abort', '【WS】', 'WSセット', '中断', 'SP発動のため停止')
        ws_set_off()
    end
    if state.buffset.active then
        log_msg('abort', '【buff】', '強化セット', '中断', 'SP発動のため停止')
        state.buffset.active = false
        state.buffset.step = 0
        state.buffset.waiting_for_finish = false
        state.buffset.next_step_on_finish = 0
        state.buffset.next_time = 0
    end

    -- ここで MB が進行中なら完全終了（再開しない）
    if state.mbset and (state.mbset.active or state.mbset.pending_mb1 or state.mbset.mb1_spell or state.mbset.mb2_spell) then
        reset_mbset('SP発動により中断')
    end

    state.suspend_buffs = true
    state.combatbuff.casting = false

    reset_retry()

    local t = now()
    state.casting = true
    state.last_spell = name
    state.cast_fail_time = t + 2.0

    state.current_special.name = name
    state.current_special.priority = SPECIAL_PRIORITY[name] or 999
    state.current_special.start_time = now()
    state.current_special.recast_id = recast_id
    state.current_special.target = target
    state.current_special.is_sleep2 = is_sleep2

    log_msg('start', '【SP】', name, '詠唱開始')

    start_retry{
        spell_name = name,
        spell_id   = recast_id,
        target     = target,
        max_count  = 2,
        interval   = 0.5,
        kind       = 'special',
        from_queue = is_from_queue,
    }

    state.queued_special.name = nil
    state.queued_special.recast_id = nil
    state.queued_special.target = nil
    state.queued_special.is_sleep2 = false
    state.queued_special.priority = nil

    magic_judge.start(name, "special")

    send_cmd(('input /ma "%s" %s'):format(name, target))
end

------------------------------------------------------------
-- Sleep2 初回用 Enter / Esc 監視
------------------------------------------------------------
windower.register_event('keyboard', function(dik, down)
    if not down then return end
    if not state.sleep2_waiting_for_confirm or not state.sleep2_initial then
        return
    end

    if dik == 0x1C then -- Enter
        state.sleep2_waiting_for_confirm = false
        state.sleep2_initial = false

        local name = state.sleep2_name or spells.sleep2.name
        local recast_id = state.sleep2_recast_id or spells.sleep2.recast_id

        state.sleep2_name = nil
        state.sleep2_recast_id = nil

        start_special_spell(name, recast_id, '<lastst>', true, false)
        return
    end

    if dik == 0x01 then -- Esc
        state.sleep2_waiting_for_confirm = false
        state.sleep2_initial = false
        state.sleep2_name = nil
        state.sleep2_recast_id = nil
        return
    end
end)

------------------------------------------------------------
-- 戦闘バフ処理（process_buffs）
------------------------------------------------------------
local function process_buffs()
    local p = get_player()
    if not p then return end
    if has_action_blocking_debuff() then return end
    if not state.first_hit_done then return end

    if state.current_special.name then return end
    if state.buffset.active then return end
    if state.suspend_buffs then return end

    if state.combatbuff.casting then return end

    if state.combatbuff.last_finish_time > 0 and now() - state.combatbuff.last_finish_time < 6 then
        return
    end

    local ok, reason = can_start_special()
    if not ok then
        return
    end

    local recasts = windower.ffxi.get_spell_recasts()
    if not recasts then return end

    -- 空蝉（サブ忍）
    if is_sub_nin() then
        local has_utsu = has_buff(66) or has_buff(444) or has_buff(445)
        if not has_utsu then
            local ni_rc   = recasts[spells.utsu_ni.recast_id]   or 0
            local ichi_rc = recasts[spells.utsu_ichi.recast_id] or 0

            if ni_rc == 0 then
                state.combatbuff.last_finish_time = now()
                if cast_spell_combatbuff(spells.utsu_ni, '<me>') then
                    log_msg('start', '【auto】', '空蝉:弐', '詠唱開始')
                else
                    log_msg('abort', '【auto】', '空蝉:弐', '詠唱不可')
                end
                return
            elseif ichi_rc == 0 then
                state.combatbuff.last_finish_time = now()
                if cast_spell_combatbuff(spells.utsu_ichi, '<me>') then
                    log_msg('start', '【auto】', '空蝉:壱', '詠唱開始')
                else
                    log_msg('abort', '【auto】', '空蝉:壱', '詠唱不可')
                end
                return
            else
                return
            end
        end
    end

    -- ストンスキン
    if not has_buff(37) and can_cast(spells.stoneskin.recast_id) then
        state.combatbuff.last_finish_time = now()
        if cast_spell_combatbuff(spells.stoneskin, '<me>') then
            log_msg('start', '【auto】', 'ストンスキン', '詠唱開始')
        else
            log_msg('abort', '【auto】', 'ストンスキン', '詠唱不可')
        end
        return
    end

    -- ケアルIV
    if p.vitals.hpp <= 60 and can_cast(spells.cure4.recast_id) then
        state.combatbuff.last_finish_time = now()
        if cast_spell_combatbuff(spells.cure4, '<me>') then
            log_msg('start', '【auto】', 'ケアルIV', '詠唱開始')
        else
            log_msg('abort', '【auto】', 'ケアルIV', '詠唱不可')
        end
        return
    end
end

------------------------------------------------------------
-- buffset（リスト / 開始 / 処理）
------------------------------------------------------------
local BUFFET_LIST_NONCOMBAT = {
    {name="ヘイストII",    next=2},
    {name="リフレシュIII", next=3},
    {name="エンサンダー",  next=4},
    {name="ストライII",    next=5},
    {name="ゲインイン",    next=6},
    {name="ファランクス",  next=7},
    {name="アイススパイク", next=8},
    {name="__CANCEL_STONESKIN__", next=9},
    {name="ストンスキン",  next=0},
}

-- Fixed: define the in-combat BUFFET list under the same naming scheme the code expects.
local BUFFET_LIST_COMBAT = {
    {name="ヘイストII",   next=2},
    {name="エンサンダー", next=3},
    {name="ストライII",   next=0},
}

local BUFFET_TIMEOUT = 3.0

local function buffset_cast_next(list)
    local step  = state.buffset.step
    local entry = list[step]
    if not entry then return end

    if state.current_special.name then return end

    if entry.name == "__CANCEL_STONESKIN__" then
        send_cmd('input /console cancel 37')
        state.buffset.step            = entry.next
        state.buffset.next_time       = now() + 0.2
        state.buffset.step_start_time = now()
        return
    end

    if step == 1 and entry.name == "ヘイス��II" then
        local ok, reason = can_start_special()
        if not ok then
            state.buffset.next_time = now() + 0.5
            return
        end
    end

    if not can_act() then
        state.buffset.next_time = now() + 1.0
        return
    end

    local spell = res.spells:with('ja', entry.name) or res.spells:with('en', entry.name)
    if spell and spell.recast_id and not can_cast(spell.recast_id) then
        state.buffset.next_time = now() + 1.0
        return
    end

    if now() - (state.buffset_last_finish_time or 0) < 3.0 then
        return
    end

    cast_spell(
        { name = entry.name, recast_id = spell and spell.recast_id or nil },
        '<me>',
        { max_count = 1, kind = 'buffset' }
    )

    local t = now()
    state.buffset.step_start_time     = t
    state.buffset.waiting_for_finish  = true
    state.buffset.next_step_on_finish = entry.next
end

local function start_buffset()
    if state.buffset.active then
        log_msg('report', '【buff】', '強化セット', '進行中')
        return
    end

    if has_action_blocking_debuff() then
        log_msg('abort', '【buff】', '強化セット', '中断', '行動不能デバフ中')
        return
    end

    if state.ws.active then
        log_msg('abort', '【buff】', '強化セット', '中断', 'WSセット発動中')
        return
    end

    state.buffset.active = true
    state.buffset.step = 1
    state.buffset.next_time = 0
    state.buffset.waiting_for_finish = false
    state.buffset.next_step_on_finish = 0
    state.buffset.step_start_time = now()
    log_msg('start', '【buff】', '強化セット', '開始')
end

local function process_buffset()
    if not state.buffset.active then return end
    if state.current_special.name then return end

    if has_action_blocking_debuff() then
        log_msg('abort', '【buff】', '強化セット', '中断', '行動不能デバフ')
        state.buffset.active = false
        state.buffset.step = 0
        state.buffset.waiting_for_finish = false
        state.buffset.next_step_on_finish = 0
        state.buffset.next_time = 0
        return
    end

    if state.ws.active then
        log_msg('abort', '【buff】', '強化セット', '中断', 'WSセット発動中')
        ws_set_off()
    end

    local p = get_player()
    if not p then return end

    if state.buffset.waiting_for_finish then
        local t = now()
        if t - (state.buffset.step_start_time or 0) > BUFFET_TIMEOUT then
            state.buffset.waiting_for_finish  = false
            state.buffset.step                = state.buffset.next_step_on_finish
            state.buffset.next_step_on_finish = 0
            state.buffset.next_time           = t + 0.5
            state.buffset_last_finish_time    = t
        end
        return
    end

    if state.buffset.next_time > 0 and now() < state.buffset.next_time then
        return
    end

    if state.buffset.step == 0 then
        log_msg('finish', '【buff】', '強化セット', '完了')
        state.buffset.active = false
        state.suspend_buffs = false
        state.buff_resume_time = now()
        return
    end

    if p.status == 1 then
        buffset_cast_next(BUFFET_LIST_COMBAT)
    else
        buffset_cast_next(BUFFET_LIST_NONCOMBAT or BUFFET_LIST_NONCOMBAT)
    end
end

------------------------------------------------------------
-- WSMB 関連（ws_set_off / reset_ws_for_new_set / toggle_set / process_ws）
-- ログを【WS】へ分離
------------------------------------------------------------
ws_set_off = function(suppress_log)
    local w = state.ws
    w.active = false
    w.mode = nil
    w.phase = 'idle'
    w.phase_started_at = 0

    w.target_id = nil
    w.initial_target_id = nil
    w.last_ws_name = nil

    w.ws1_name = nil
    w.ws1_props = nil
    w.ws2_name = nil
    w.ws2_props = nil
    w.ws1_confirmed = false

    w.ws1_retry_count = 0
    w.ws1_retry_next = 0

    w.sc_en = nil
    w.mb1_spell = nil
    w.mb2_reserved = nil
    w.mb2_spell = nil
    w.mb2_time = 0
    w.mb2_release_time = 0

    w.interrupt_mb = false
    w.interrupt_time = 0

    w.queued_mode = nil
    w.logged_reservation = false
    w.retry_wait_logged = false

    if magic_judge and magic_judge.state then
        magic_judge.state.active = false
        magic_judge.state.last_result = nil
        magic_judge.state.last_result_src = nil
    end
    if ws_judge and ws_judge.state then
        ws_judge.state.active = false
        ws_judge.state.last_result = nil
        ws_judge.state.last_result_src = nil
        ws_judge.state.queue = {}
    end

    state.suspend_buffs = false
    state.buff_resume_time = now()

    if not suppress_log then
        --log_msg('finish', '【WS】', 'WSセット', '完了')
    end
end

local function reset_ws_for_new_set(mode_name)
    local w = state.ws
    w.active = true
    w.mode = mode_name
    w.phase = 'ws1'
    w.phase_started_at = now()

    w.target_id = nil
    w.initial_target_id = nil
    w.last_ws_name = nil

    w.ws1_name = nil
    w.ws1_props = nil
    w.ws2_name = nil
    w.ws2_props = nil
    w.ws1_confirmed = false

    w.ws1_retry_count = 0
    w.ws1_retry_next = 0

    w.sc_en = nil
    w.mb1_spell = nil
    w.mb2_reserved = nil
    w.mb2_spell = nil
    w.mb2_time = 0
    w.mb2_release_time = 0

    w.interrupt_mb = false
    w.interrupt_time = 0

    w.queued_mode = nil
    w.logged_reservation = false
    w.retry_wait_logged = false
end

local function toggle_set(mode_name, label)
    if state.ws.active and state.ws.mode == mode_name then
        ws_set_off()
        return
    end
    state.ws.queued_mode = mode_name
end

local function toggle_seta() toggle_set('seta', 'シャンデュシニュ') end
local function toggle_setb() toggle_set('setb', 'サベッジブレード') end
local function toggle_setc() toggle_set('setc', 'セラフブレード') end

local function process_ws()
    local w = state.ws

    if w.queued_mode and not w.active then
        local ok, reason = can_start_special()
        if ok then
            reset_ws_for_new_set(w.queued_mode)
            log_msg('start', '【WS】', w.queued_mode, 'WSセット', '開始')
            w.logged_reservation = false
            w.queued_mode = nil
            return
        else
            if not w.logged_reservation then
                log_msg('notice', '【WS】', w.queued_mode, 'WS1予約')
                w.logged_reservation = true
            end
            return
        end
    end

    if not w.active then return end
    if state.current_special.name then return end

    local ok, reason = can_start_special()
    if not ok then
        return
    end

    local p = get_player()
    if not p or p.status ~= 1 then return end

    local tp = p.vitals.tp
    local mode = w.mode
    local cfg = WS[mode]
    if not cfg then
        log_msg('abort', '【WS】', 'WSセット', '中断', '設定取得失敗')
        ws_set_off()
        return
    end

    local phase = w.phase
    local elapsed = now() - (w.phase_started_at or 0)

    if phase == 'ws1' then
        if tp < 1000 then return end
        send_cmd(('input /ws "%s" <t>'):format(cfg.ws1))
        if ws_judge then ws_judge.start(cfg.ws1, "WS1") end
        w.phase = 'ws1_wait'
        w.phase_started_at = now()
        return
    end

    if phase == 'ws1_retry' then
        if tp < 1000 then return end
        send_cmd(('input /ws "%s" <t>'):format(cfg.ws1))
        if ws_judge then ws_judge.start(cfg.ws1, "WS1") end
        w.phase = 'ws1_wait'
        w.phase_started_at = now()
        return
    end

    if phase == 'ws2' then
        if elapsed > 10 then
            log_msg('abort', '【WS】', 'WS2', '中断', '猶予切れ')
            ws_set_off()
            return
        end

        if tp < 1000 or elapsed < 4 then
            return
        end

        send_cmd(('input /ws "%s" <t>'):format(cfg.ws2))
        if ws_judge then ws_judge.start(cfg.ws2, "WS2") end
        w.phase = 'ws2_wait'
        w.phase_started_at = now()
        return
    end
end

------------------------------------------------------------
-- 敵TP技検知（軽量版、自動スタン対象）
------------------------------------------------------------
local AUTO_STUN_TP_MOVES = {
    [2199] = true,
}

local last_cat1_tick = 0

local function detect_enemy_tp_move(act)
    local now_t = now()
    if act.category == 1 then
        if now_t - last_cat1_tick < 0.10 then return end
        last_cat1_tick = now_t
    end

    if not monster_abilities_by_message then
        build_monster_abilities_by_message()
    end

    local p = get_player()
    if not p then return end

    if p.sub_job_id ~= JOB_BLM then
        return
    end

    local mob = windower.ffxi.get_mob_by_id(act.actor_id)
    if not mob or mob.in_party then
        return
    end

    local action_id = nil
    local action = nil
    local msg_id = nil

    if act.category == 7 then
        local t = act.targets and act.targets[1]
        local a = t and t.actions and t.actions[1]
        if not a then return end
        action_id = a.param
        msg_id    = a.message
        if res.weapon_skills[action_id] then
            action = res.weapon_skills[action_id]
        elseif res.job_abilities[action_id] then
            action = res.job_abilities[action_id]
        else
            action = res.monster_abilities[action_id]
        end
    elseif act.category == 11 then
        action_id = act.param
        action    = res.monster_abilities[action_id]
    elseif act.category == 3 then
        action_id = act.param
        if res.weapon_skills[action_id] then
            action = res.weapon_skills[action_id]
        else
            action = res.monster_abilities[action_id]
        end
    elseif act.category == 1 then
        local t = act.targets and act.targets[1]
        local a = t and t.actions and t.actions[1]
        if not a then return end
        msg_id = a.add_effect_message
        if msg_id and msg_id ~= 0 then
            local id = monster_abilities_by_message[msg_id]
            if id then
                action_id = id
                action = res.monster_abilities[id]
            end
        end
    elseif act.category == 12 or act.category == 2 then
        action_id = 272
        action = res.monster_abilities[action_id]
    elseif act.category == 13 then
        local t = act.targets and act.targets[1]
        local a = t and t.actions and t.actions[1]
        if not a then return end
        action_id = act.param
        msg_id = a.message
        if res.job_abilities[action_id] then
            action = res.job_abilities[action_id]
        else
            action = res.monster_abilities[action_id]
        end
    else
        return
    end

    if not action or not action_id then return end

    if AUTO_STUN_TP_MOVES[action_id] then
        if state.last_detected_tp_move_id ~= action_id then
            local name = action and action.name or ("ID:" .. action_id)
            log_msg('detect', '【SP】', name, '検知', 'スタン発動')
            state.last_detected_tp_move_id = action_id
        end
        start_special_spell(spells.stun.name, spells.stun.recast_id, "<t>")
    end
end

------------------------------------------------------------
-- MB 関連（reset_mbset(reason) を導入）
-- MB 関連ログはすべて【MB】で出力
------------------------------------------------------------
-- Note: reset_mbset is forward-declared above so functions defined earlier can call it.
reset_mbset = function(reason)
    local m = state.mbset
    local was_active = m.active or m.mb1_spell or m.mb2_spell or m.pending_mb1
    if reason and was_active then
        log_msg('finish', '【MB】', 'MBセット', '完了')
    end

    m.active = false
    m.count = 0
    m.last_ws_time = 0
    m.pending_mb1 = false
    m.mb1_spell = nil
    m.mb2_spell = nil
    m.mb1_target = nil
    m.mb2_target = nil
    m.mb1_start_time = nil
    m.mb2_time = 0
    m.last_detected_sc = nil
    m.last_props = nil
    m.awaiting_mb2 = false

    state.suspend_buffs = false
    state.buff_resume_time = now()
end

local function try_start_mb1(spell_name, target, opts)
    opts = opts or {}
    local force_bypass = opts.force_bypass or false
    target = target or '<t>'

    if state.current_special.name and not force_bypass then
        state.mbset.pending_mb1 = true
        state.mbset.mb1_spell = spell_name
        state.mbset.mb1_target = target
        log_msg('notice', '【MB】', spell_name, '予約')
        return true
    end

    if not force_bypass then
        local ok, reason = can_start_special()
        if not ok then
            state.mbset.pending_mb1 = true
            state.mbset.mb1_spell = spell_name
            state.mbset.mb1_target = target
            log_msg('notice', '【MB】', spell_name, '予約')
            return true
        end
    end

    if state.ws.active then
        --log_msg('report', '【WS】', 'WSセット', '中断', 'MBセット発動')
        ws_set_off()
    end
    if state.buffset.active then
        log_msg('abort', '【buff】', '強化セット', '中断', 'MBセット発動のため停止')
        state.buffset.active = false
        state.buffset.step = 0
        state.buffset.waiting_for_finish = false
        state.buffset.next_step_on_finish = 0
        state.buffset.next_time = 0
    end
    state.suspend_buffs = true

    local t = now()
    state.casting = true
    state.last_spell = spell_name
    state.cast_fail_time = t + 2.0

    state.mbset.mb1_spell = spell_name
    state.mbset.mb1_target = target
    state.mbset.mb1_start_time = now()
    state.mbset.pending_mb1 = false

    send_cmd(('input /ma "%s" %s'):format(spell_name, target))
    log_msg('report', '【MB】', spell_name, 'MB1 詠唱開始')

    state.mbset.mb2_time = state.mbset.mb1_start_time + 4.0

    -- awaiting_mb2 は mb2_spell が決まっているかで判定（MB決定時に設定されることが多い）
    state.mbset.awaiting_mb2 = (state.mbset.mb2_spell ~= nil)

    return true
end

local function try_start_mb2(spell_name, target)
    target = target or '<t>'
    local t = now()

    if not spell_name then
        return false
    end

    state.casting = true
    state.last_spell = spell_name
    state.cast_fail_time = t + 2.0

    state.mbset.mb2_spell = spell_name
    state.mbset.mb2_target = target

    send_cmd(('input /ma "%s" %s'):format(spell_name, target))
    log_msg('report', '【MB】', spell_name, 'MB2 詠唱開始')
    return true
end

------------------------------------------------------------
-- ヘルパ: WS_Detector の parse/analyze 互換呼び出し
------------------------------------------------------------
local function detect_with_wsdetector(act, last_props, mode, cfg, hit_flag)
    if not WS_Detector then return nil end
    if WS_Detector.parse then
        -- parse の引数: act, last_props, mode, cfg, hit_flag
        local ok, res = pcall(WS_Detector.parse, act, last_props, mode, cfg, hit_flag)
        if ok then return res end
        return nil
    elseif WS_Detector.analyze then
        -- analyze の引数: act, last_props (backward-compatible)
        local ok, res = pcall(WS_Detector.analyze, act, last_props)
        if ok then return res end
        return nil
    end
    return nil
end

------------------------------------------------------------
-- MB 検出結果の処理（検出失敗時は仕切り直し、決定時にMBセット開始ログを出す）
-- 変更: 時間判定に下限 3 秒を導入。範囲外は MB セットを終了して当該 WS を 1 回目として扱う
------------------------------------------------------------
local MIN_MB_WINDOW = 3.0

local function process_analyzed_ws(result, act)
    if not result then return end
    local p = get_player()
    if not p then return end

    if p.status ~= 1 then return end
    local my_target = windower.ffxi.get_mob_by_target('t')
    if not my_target then return end

    if not is_friendly_actor(act.actor_id) then
        return
    end

    local hit_my_target = false
    for _, tgt in ipairs(act.targets or {}) do
        if tgt.id == my_target.id then
            hit_my_target = true
            break
        end
    end
    if not hit_my_target then
        return
    end

    local t = now()
    local m = state.mbset

    if m.count == 0 then
        m.count = 1
        m.last_ws_time = t
        m.last_props = result.props
        m.active = true
        return
    end

    -- idx は「次に評価する閾値インデックス（現在の count を基に）」とする
    local idx = math.min(m.count, #m.thresholds)
    local max_allowed = m.thresholds[idx] or 7
    local allowed = math.max(MIN_MB_WINDOW, max_allowed)

    local elapsed = t - (m.last_ws_time or 0)

    -- elapsed が MIN_MB_WINDOW（下限）未満、または上限を超えている場合は「時間外」
    if elapsed < MIN_MB_WINDOW or elapsed > max_allowed then
        -- 時間外：既存の MB セットを終了して、この WS を "1 回目" として扱う
        reset_mbset('時間外のWSを検知')
        -- 新たに 1 回目として開始
        m.count = 1
        m.last_ws_time = t
        m.last_props = result.props
        m.active = true
        log_msg('abort', '【MB】', 'MBセット', '連携検知失敗')
        return
    end

    -- ここまで来たら elapsed が [MIN_MB_WINDOW, max_allowed] の範囲内（許容内）
    if t - (m.last_ws_time or 0) <= max_allowed then
        m.count = math.min(5, m.count + 1)
    else
        m.count = 1
    end

    m.last_ws_time = t
    m.last_props = result.props

    local sc_detected = (result.sc_en ~= nil) or (result.success == true)
    if m.count >= 2 and sc_detected then
        local mb1 = result.mb1 or "サンダーII"
        local mb2 = result.mb2 or "サンダー"

        m.mb1_spell = mb1
        m.mb2_spell = mb2
        m.mb1_target = '<t>'
        m.mb2_target = '<t>'
        m.pending_mb1 = true
        m.last_detected_sc = result.sc_en or nil

        m.mb2_time = 0

        -- MBセット開始ログ（MB決定時）
        log_msg('start', '【MB】', 'MBセット', '開始', string.format('mb1=%s mb2=%s count=%d', tostring(mb1), tostring(mb2), m.count))

        if not state.casting and not state.current_special.name then
            local ok, reason = can_start_special()
            if ok then
                try_start_mb1(m.mb1_spell, m.mb1_target)
            else
                log_msg('notice', '【MB】', m.mb1_spell, '予約')
            end
        else
            log_msg('notice', '【MB】', m.mb1_spell, '予約')
        end
        return
    end

    if m.count >= 2 and not sc_detected then
        m.count = 1
        m.last_ws_time = t
        m.last_props = result.props
        m.active = true
        log_msg('abort', '【MB】', 'MBセット', '連携検知失敗')
        return
    end
end

local function process_mbset_in_prerender(t)
    local m = state.mbset
    if not m.active then return end

    if m.pending_mb1 and m.mb1_spell then
        if not state.casting and not state.current_special.name then
            local ok, reason = can_start_special()
            if ok then
                try_start_mb1(m.mb1_spell, m.mb1_target)
            end
        end
    end

    if m.mb2_time and m.mb2_time > 0 and t >= m.mb2_time then
        if m.mb2_spell then
            try_start_mb2(m.mb2_spell, m.mb2_target)
        end
        m.mb2_time = 0
        m.pending_mb1 = false
        -- mb1/mb2 cleared after MB2 attempt started; do not reset entire mbset here
        -- m.mb1_spell = nil
        -- m.mb2_spell = nil
    end

    -- タイムアウト判定: MB2 を待っている場合は短期タイムアウトを抑制し、長期タイムアウトのみ許容
    if m.count > 0 then
        if m.awaiting_mb2 then
            -- 長い閾値（MB1開始からの長時間遅延を異常とする）
            local LONG_TIMEOUT = 12.0
            if m.mb1_start_time and (t - (m.mb1_start_time or 0) > LONG_TIMEOUT) then
                reset_mbset('タイムアウト')
            end
        else
            local SHORT_WINDOW = (m.thresholds[1] or 10) + 1
            if t - (m.last_ws_time or 0) > SHORT_WINDOW then
                reset_mbset('タイムアウト')
            end
        end
    end
end

------------------------------------------------------------
-- action イベント（成否は magic_judge / ws_judge に委譲）
------------------------------------------------------------
windower.register_event('action', function(act)
    if not state.enabled then return end
    local p = get_player()
    if not p then return end
    if p.main_job_id ~= JOB_RDM then return end

    detect_enemy_tp_move(act)

    if magic_judge and magic_judge.on_action then magic_judge.on_action(act) end
    if ws_judge and ws_judge.on_action then ws_judge.on_action(act) end

    if act.actor_id == p.id and act.category == 1 then
        if not state.first_hit_done then
            state.first_hit_done = true
            --log_msg('report', '【auto】', '戦闘バフ', '開始', '最初の一撃')
        end
        return
    end

    if act.actor_id == p.id and act.category == 6 then
        if state.combatbuff.casting then
            state.combatbuff.casting = false
            state.combatbuff.start_time = nil
            log_msg('abort', '【auto】', '戦闘バフ', '詠唱中断')
        end
        state.magic_delay_until = now() + 2.0
    end

    if act.actor_id == p.id and act.category == 7 then
        state.ws_motion = true
        state.ws_motion_start = now()
    end

    if act.actor_id == p.id and act.category == 3 then
        state.ws_motion = false
        state.ws_delay_until = now() + 3.0
    end

    if not (act.category == 3 or act.category == 7 or act.category == 11 or act.category == 1 or act.category == 12 or act.category == 13) then
        return
    end

    -- MB 検出（戦闘中・自分のターゲットに対する action のみ）
    if p.status == 1 then
        local my_target = windower.ffxi.get_mob_by_target('t')
        if my_target then
            local includes_my_target = false
            for _, tgt in ipairs(act.targets or {}) do
                if tgt.id == my_target.id then
                    includes_my_target = true
                    break
                end
            end
            if includes_my_target then
                -- ignore Mix: Dark Potion (id 4260)
                if not (act.param and act.param == 4260) then
                    if is_friendly_actor(act.actor_id) then
                        local parsed = detect_with_wsdetector(act, state.mbset.last_props, nil, nil, false)
                        if parsed then
                            process_analyzed_ws(parsed, act)
                        end
                    end
                end
            end
        end
    end

    -- 以下、WSセット側処理（WS1 / WS2 / interrupt）
    if not state.ws.active then
        return
    end

    local phase = state.ws.phase

    if act.actor_id == p.id then
        local cfg = state.ws.mode and WS[state.ws.mode]
        if not cfg then
            log_msg('abort', '【WS】', 'WSセット', '中断', 'cfg取得失敗')
            ws_set_off()
            return
        end

        if phase == 'ws1_wait' then
            local judge = ws_judge and ws_judge.consume_result_for and ws_judge.consume_result_for("WS1")
            if not judge then return end
            if judge == "fail" then
                log_msg('report', '【WS】', cfg.ws1, 'ミス', 'WS1 リトライ移行')
                state.ws.ws1_confirmed = false
                state.ws.ws1_retry_count = (state.ws.ws1_retry_count or 0)
                state.ws.phase = 'ws1_retry'
                state.ws.phase_started_at = now()
                return
            end

            -- WS1: parse が使えるなら mode="ws1" で、なければ analyze(act, nil)
            local parsed = detect_with_wsdetector(act, nil, "ws1", cfg, false)
            if not parsed then
                log_msg('abort', '【WS】', 'WSセット', '中断', 'WS1判定不可 (解析失敗)')
                ws_set_off()
                return
            end

            state.ws.ws1_name = parsed.ws_name or cfg.ws1
            state.ws.ws1_props = parsed.props
            state.ws.last_ws_name = state.ws.ws1_name
            state.ws.ws1_confirmed = true

            local mob = windower.ffxi.get_mob_by_target('t')
            state.ws.target_id = state.ws.target_id or (mob and mob.id or nil)
            state.ws.initial_target_id = state.ws.initial_target_id or state.ws.target_id

            state.ws.phase = 'ws2'
            state.ws.phase_started_at = now()
            log_msg('report', '【WS】', state.ws.ws1_name, '実行', 'WS1 成功')
            return
        end

        if state.current_special.name then
            return
        end

        if phase == 'ws2_wait' then
            if not state.ws.ws1_confirmed then
                log_msg('abort', '【WS】', 'WSセット', '中断', 'WS1未確定 → WS2判定スキップ')
                ws_set_off()
                return
            end

            local judge = ws_judge and ws_judge.consume_result_for and ws_judge.consume_result_for("WS2")
            if not judge then return end
            if judge == "fail" then
                log_msg('abort', '【WS】', 'WSセット', '中断', 'WS2 失敗')
                ws_set_off()
                return
            end

            local parsed = detect_with_wsdetector(act, state.ws.ws1_props, "ws2", cfg, false)
            if not parsed then
                log_msg('abort', '【WS】', 'WSセット', '中断', 'WS2 判定不可 (解析失敗)')
                ws_set_off()
                return
            end

            log_msg('report', '【WS】', parsed.ws_name or cfg.ws2, '実行', 'WS2 成功')
            ws_set_off()
            return
        end

        return
    end

    -- 割り込み WS 判定（他者が自分ターゲットにWS）
    if (act.category == 3 or act.category == 7 or act.category == 11)
    and is_friendly_actor(act.actor_id)
    and state.ws.active
    and state.ws.phase == 'ws2'
    and state.ws.ws1_confirmed
    then
        if state.current_special.name then return end

        local my_target = windower.ffxi.get_mob_by_target('t')
        if not my_target then return end

        local hit_flag = false
        for _, tgt in ipairs(act.targets or {}) do
            if tgt.id == my_target.id then
                hit_flag = true
                break
            end
        end
        if not hit_flag then return end

        local cfg = state.ws.mode and WS[state.ws.mode]
        if not cfg then return end

        local parsed = detect_with_wsdetector(act, state.ws.ws1_props, "interrupt", cfg, hit_flag)
        if not parsed then return end

        if act.param == 4260 then return end

        if not (parsed.success or parsed.sc_en) then
            log_msg('abort', '【WS】', 'WSセット', '中断', '割り込みWS 失敗')
            return
        end

        local now_t = now()
        state.ws.ws2_name = parsed.ws_name
        state.ws.ws2_props = parsed.props
        state.ws.last_ws_name = parsed.ws_name

        state.ws.sc_en = parsed.sc_en
        state.ws.mb1_spell = parsed.mb1
        state.ws.mb2_reserved = parsed.mb2
        state.ws.mb2_spell = nil
        state.ws.mb2_time = 0
        state.ws.mb2_release_time = 0

        state.buffset.active = false
        state.buffset.step = 0
        state.buffset.waiting_for_finish = false
        state.buffset.next_step_on_finish = 0
        state.buffset.next_time = 0

        log_msg(
            'detect',
            '【WS】',
            parsed.ws_name,
            '検知',
            string.format('割り込みWS 成功 sc=%s MB1=%s MB2=%s',
                tostring(parsed.sc_en),
                tostring(parsed.mb1),
                tostring(parsed.mb2)
            )
        )

        ws_set_off()
        return
    end
end)

------------------------------------------------------------
-- 魔法完了 / 中断 ハンドラ（handle_spell_finish）
-- MB2完了時は終了ログを出す。MB1のみで終了/その他異常終了時も終了ログ。
------------------------------------------------------------
local function handle_spell_finish(act)
    local p = get_player()
    if not p then return end
    if act.actor_id ~= p.id then return end
    if act.category ~= 4 then return end

    local spell_res = res.spells[act.param]
    if not spell_res then return end
    local name = spell_res.ja or spell_res.en or ''

    state.casting = false
    state.cast_fail_time = nil

    if state.retry.active and name == state.retry.spell_name then
        reset_retry()
    end

    if state.current_special.name and name == state.current_special.name then
        log_msg('finish', '【SP】', name, '詠唱完了')
        state.current_special.name = nil
        state.current_special.priority = nil
        state.current_special.start_time = nil
        state.current_special.recast_id = nil
        state.current_special.target = nil
        state.current_special.is_sleep2 = false

        state.special_delay_until = now() + 3.0
        state.suspend_buffs = false
        state.buff_resume_time = now()

        if state.retry.active and state.retry.spell_name == name then
            reset_retry()
        end
        return
    end

    state.magic_delay_until = now() + 3.0

    if state.buffset.active and state.buffset.waiting_for_finish then
        state.buffset.waiting_for_finish  = false
        state.buffset.step                = state.buffset.next_step_on_finish
        state.buffset.next_step_on_finish = 0
        state.buffset.next_time           = now() + 0.5
        state.buffset_last_finish_time    = now()
    end

    do
        local m = state.mbset
        if m and m.mb1_spell and name == m.mb1_spell then
            log_msg('report', '【MB】', name, '詠唱完了', 'MB1')
            m.mb1_spell = nil
            -- MB1 完了後: MB2 が設定されていれば時間を確保、なければ MB セッションを終了しバフ復帰
            if m.mb2_spell then
                if m.mb2_time == 0 then
                    m.mb2_time = now() + 4.0
                end
                -- 現在 MB2 を待機中フラグを有効にしておく
                m.awaiting_mb2 = true
            else
                reset_mbset('MB1のみで終了')
            end
        end

        if m and m.mb2_spell and name == m.mb2_spell then
            log_msg('report', '【MB】', name, '詠唱完了', 'MB2')
            reset_mbset('MB2詠唱完了')
        end
    end

    state.last_spell = nil

    if state.combatbuff.casting then
        state.combatbuff.casting = false
        state.combatbuff.start_time = nil
        state.combatbuff.last_finish_time = now()
        if not state.ws.active then
            log_msg('finish', '【auto】', name, '詠唱完了')
        end
    end
end

windower.register_event('action', handle_spell_finish)

------------------------------------------------------------
-- 戦闘終了一元処理（重複ログ抑止）
-- 戦闘終了時は WS/MB 個別終了ログを出さず、ここ���のみ戦闘終了ログを出す
------------------------------------------------------------
local function emit_combat_end(reason)
    local t = now()
    if state.combat_end_suppressed_until and t < state.combat_end_suppressed_until then
        return
    end

    -- 出力: 戦闘終了ログのみ
    --log_msg('finish', '【ALL】', '戦闘終了', 'ターゲット撃破')

    -- サイレントに外部状態をリセット（WS の終了ログは出さない）
    ws_set_off(true)        -- suppress_log = true
    reset_mbset()           -- silent reset (no reason -> no MB finish log)

    -- 直後の重複出力を抑止（1秒程度）
    state.combat_end_suppressed_until = t + 1.0
end

------------------------------------------------------------
-- prerender（メインループ）
-- 戦闘終了遷移を先に検出して一元処理する（WS/MB/ターゲットログの重複を防止）
------------------------------------------------------------
windower.register_event('prerender', function()
    local t = now()

    if not state.enabled then return end
    local p = get_player()
    if not p or p.main_job_id ~= JOB_RDM then return end

    if state.last_prerender_tick and (t - state.last_prerender_tick) < 0.05 then
        return
    end
    state.last_prerender_tick = t
    state.last_prerender_time = t

    -- 戦闘終了遷移 (前回 in-combat -> 今回 not in-combat) を先に処理
    local prev_status = state.last_player_status
    local cur_status = p.status
    if prev_status == nil then
        state.last_player_status = cur_status
    else
        if prev_status == 1 and cur_status ~= 1 then
            -- 戦闘終了の一本化
            emit_combat_end('戦闘終了')
            state.last_player_status = cur_status
            -- 戦闘終了があったので他の終了処理は行わない（重複防止）
            return
        end
        state.last_player_status = cur_status
    end

    local current_target = windower.ffxi.get_mob_by_target('t')
    local current_id = current_target and current_target.id or nil

    -- ターゲット変更時（ターゲット切替や撃破）
    if current_id ~= state.last_target_id and not state.buffset.active then
        -- もし戦闘終了抑止フラグが有効なら既に戦闘終了ログを出しているため、個別ログは抑制
        if state.combat_end_suppressed_until and now() < state.combat_end_suppressed_until then
            -- サイレントにリセット
            ws_set_off(true)
            reset_mbset()
        else
            if state.ws.active then
                --log_msg('finish', '【WS】', 'WSセット', '完了', 'ターゲット撃破')
                ws_set_off()
            end

            -- ターゲット変更時に MB をリセット（理由付きログ）
            reset_mbset('ターゲット切替')
        end

        state.current_special.name = nil
        state.current_special.priority = nil

        state.queued_special.name = nil
        state.queued_special.recast_id = nil
        state.queued_special.target = nil
        state.queued_special.is_sleep2 = false
        state.queued_special.priority = nil

        state.buffset.active = false
        state.buffset.step = 0
        state.buffset.waiting_for_finish = false
        state.buffset.next_step_on_finish = 0
        state.buffset.next_time = 0

        reset_retry()

        state.casting = false
        state.cast_fail_time = nil
        state.suspend_buffs = false
        state.first_hit_done = false
        state.last_target_id = current_id
    end

    -- WS が残っているが戦闘終了なら先に一元処理が済んでいるはずなので抑制
    if p.status ~= 1 and state.ws.active then
        if state.combat_end_suppressed_until and now() < state.combat_end_suppressed_until then
            ws_set_off(true)
        else
            --log_msg('finish', '【WS】', 'WSセット', '完了', '戦闘終了')
            ws_set_off()
        end
    end

    if magic_judge and magic_judge.check_mp then
        magic_judge.check_mp()
    end

    if state.combatbuff.pending and state.combatbuff.pending_spell then
        local ok, reason = can_start_special()
        if ok then
            local sp = state.combatbuff.pending_spell
            local tgt = state.combatbuff.pending_target
            state.combatbuff.pending = false
            state.combatbuff.pending_spell = nil
            state.combatbuff.pending_target = nil

            if cast_spell_combatbuff(sp, tgt) then
                log_msg('report', '【SP】', sp.name, '予約実行')
            else
                log_msg('abort', '【SP】', sp.name, '予約実行失敗')
            end
        end
    end

    if state.casting and state.cast_fail_time and t > state.cast_fail_time + 8 then
        log_msg('abort', '【safety】', '通常魔法', '中断', '8秒以上継続')
        state.casting = false
        state.cast_fail_time = nil
        reset_retry()
    end

    if state.combatbuff and state.combatbuff.casting and state.combatbuff.start_time and (t - state.combatbuff.start_time) > 5 then
        state.combatbuff.casting = false
        state.combatbuff.start_time = nil
        state.combatbuff.last_finish_time = t
    end

    if state.current_special.name and state.current_special.start_time and t - state.current_special.start_time > 8 then
        log_msg('abort', '【safety】', state.current_special.name, '中断', '8秒以上継続')
        state.current_special.name = nil
        state.current_special.priority = nil
        state.current_special.start_time = nil
        state.current_special.pending_start = nil
        state.current_special.start_check_time = nil

        state.queued_special.name = nil
        state.queued_special.recast_id = nil
        state.queued_special.target = nil
        state.queued_special.is_sleep2 = false
        state.queued_special.priority = nil

        state.suspend_buffs = false
        state.buff_resume_time = 0

        state.casting = false
        state.cast_fail_time = nil

        if state.retry.active and state.retry.kind == 'special' then
            reset_retry()
        end
    end

    if state.queued_special.name and not state.current_special.name then
        local ok, reason = can_start_special()
        if ok then
            local qs = state.queued_special
            local qname = qs.name
            local qrecast = qs.recast_id
            local qtarget = qs.target
            local qsleep2 = qs.is_sleep2

            state.queued_special.name = nil
            state.queued_special.recast_id = nil
            state.queued_special.target = nil
            state.queued_special.is_sleep2 = false
            state.queued_special.priority = nil

            start_special_spell(qname, qrecast, qtarget, qsleep2, true)
        end
    end

    if state.ws_motion then
        local me = windower.ffxi.get_player()
        if me and me.status ~= 1 then
            log_msg('abort', '【safety】', 'WSセット', '固まり検知リセット')
            reset_all_states()
            return
        end
        state.ws_motion_start = state.ws_motion_start or t
        if t - state.ws_motion_start > 5 then
            log_msg('abort', '【safety】', 'WSセット', '固まり検知リセット')
            reset_all_states()
            state.ws_motion_start = nil
            return
        end
    else
        state.ws_motion_start = nil
    end

    process_mbset_in_prerender(t)

    if state.ws.active then
        if state.ws.interrupt_mb and state.ws.interrupt_time > 0 and (t - state.ws.interrupt_time > 1.0) and not state.ws.sc_en then
            log_msg('abort', '【safety】', 'WSセット', '中断', '連携未発生')
            state.ws.interrupt_mb = false
            state.ws.interrupt_time = 0
            ws_set_off()
        end

        if state.ws.interrupt_mb and state.ws.interrupt_time > 0 and t - state.ws.interrupt_time > 8 then
            log_msg('abort', '【safety】', 'MBセット', '中断', '8秒以上継続')
            state.ws.interrupt_mb = false
            state.ws.interrupt_time = 0
            ws_set_off()
        end

        if state.ws.mb2_release_time and state.ws.mb2_release_time > 0 and t >= state.ws.mb2_release_time then
            state.suspend_buffs = false
            state.ws.mb2_release_time = 0
        end
    end

    if state.buffset.active and not state.current_special.name and state.buffset.step_start_time and (t - state.buffset.step_start_time > 5) then
        log_msg('abort', '【safety】', '強化セット', '中断', '5秒以上継続')
        state.buffset.active = false
        state.buffset.step = 0
        state.buffset.waiting_for_finish = false
        state.buffset.next_step_on_finish = 0
        state.buffset.next_time = 0
    end

    if state.casting and state.cast_fail_time and t > state.cast_fail_time then
        state.casting = false
        state.cast_fail_time = nil
        if state.retry.active and state.retry.pending then
            state.retry.pending = false
            if state.retry.is_utsu then
                state.retry.next_time = t + 0.5
            else
                state.retry.next_time = t
            end
        end
    end

    if ws_judge and ws_judge.state and ws_judge.check_timeout then ws_judge.check_timeout() end
    if magic_judge and magic_judge.state and magic_judge.check_timeout then magic_judge.check_timeout() end

    if state.retry.active then
        if state.current_special.name and state.casting then return end
        if state.casting then return end
        if t < state.retry.next_time then return end

        local r = nil
        if state.retry.kind == 'special' and magic_judge and magic_judge.consume_result_for then
            r = magic_judge.consume_result_for("special")
        end

        if r == "fail" then
            if state.retry.kind == 'special' and not state.retry.from_queue then
                enqueue_special_spell(
                    state.retry.spell_name,
                    state.retry.spell_id,
                    state.retry.target,
                    false,
                    '理由: magic_judge fail'
                )
                state.current_special.name = nil
                state.current_special.priority = nil
                state.current_special.start_time = nil
                state.suspend_buffs = false
                state.casting = false
                state.cast_fail_time = nil
                reset_retry()
                return
            end
            state.retry.pending = false
        end

        local recasts = windower.ffxi.get_spell_recasts()
        local recast = recasts[state.retry.spell_id or 0] or 0
        if recast > 0 then
            reset_retry()
            return
        end

        if state.retry.pending then
            state.retry.next_time = t + state.retry.interval
            return
        end

        if not can_act() then
            state.retry.next_time = t + 0.2
            return
        end

        local ok, reason = can_start_special()
        if not ok then
            state.retry.next_time = t + 0.25
            return
        end

        cast_spell(
            { name = state.retry.spell_name, recast_id = state.retry.spell_id },
            state.retry.target,
            {
                is_mb     = false,
                kind      = state.retry.kind or 'retry',
                source    = 'retry',
                max_count = state.retry.max_count or 2,
            }
        )

        state.retry.interval  = 0.5
        state.retry.next_time = t + state.retry.interval
        state.retry.count = (state.retry.count or 0) + 1

        if state.retry.kind == 'special' then
            if state.retry.count == 1 then
                log_msg('report', '【SP】', state.retry.spell_name, 'リトライ', '1回目')
            elseif state.retry.count == 2 then
                log_msg('report', '【SP】', state.retry.spell_name, 'リトライ', '2回目')
            end
        end

        if state.retry.count >= (state.retry.max_count or 2) then
            if state.retry.kind == 'special' then
                log_msg('abort', '【SP】', state.retry.spell_name, '中断', 'リトライ回数上限')
            end
            reset_retry()
        end
    end

    if state.current_special.name then
        local r = nil
        if magic_judge and magic_judge.consume_result_for then
            r = magic_judge.consume_result_for("special")
        end
        if r == "success" then
            state.current_special.name = nil
            state.current_special.priority = nil
            state.current_special.start_time = nil

            state.suspend_buffs = false
            state.casting = false
            state.cast_fail_time = nil

            reset_retry()
            return
        elseif r == "fail" then
            enqueue_special_spell(
                state.current_special.name,
                state.current_special.recast_id,
                state.current_special.target or '<t>',
                state.current_special.is_sleep2 or false,
                '理由: magic_judge fail'
            )

            state.current_special.name = nil
            state.current_special.priority = nil
            state.current_special.start_time = nil

            state.suspend_buffs = false
            state.casting = false
            state.cast_fail_time = nil

            reset_retry()
            return
        end
        return
    end

    if state.ws.active then
        local mob = windower.ffxi.get_mob_by_target('t')
        if not mob then
            ws_set_off()
            return
        end
    end

    process_ws()
    if state.ws.active then
        return
    end

    if state.buffset.active then
        process_buffset()
        return
    end

    if p.status == 1 then
        process_buffs()
        return
    end
end)

------------------------------------------------------------
-- 外部アドオン自動切替（login / job change）
------------------------------------------------------------
local last_job_is_rdm = nil
local function update_external_tools()
    local p = get_player()
    if not p then return end
    local is_rdm = (p.main_job_id == JOB_RDM)
    if last_job_is_rdm == is_rdm then return end
    last_job_is_rdm = is_rdm

    if is_rdm then
        send_cmd('lua unload skillchains')
        log('外部ツールOFF（RDMモード）')
    else
        send_cmd('lua load skillchains')
        log('外部ツールON（非RDMモード）')
    end
end

windower.register_event('login', update_external_tools)
windower.register_event('job change', update_external_tools)

------------------------------------------------------------
-- 全フラグ完全リセット関数
------------------------------------------------------------
function reset_all_states()
    ws_set_off(true)

    state.buffset.active = false
    state.buffset.step = 0
    state.buffset.waiting_for_finish = false
    state.buffset.next_step_on_finish = 0
    state.buffset.next_time = 0
    state.buffset.step_start_time = 0

    reset_retry()

    state.current_special.name = nil
    state.current_special.priority = nil
    state.current_special.start_time = nil
    state.current_special.pending_start = nil
    state.current_special.start_check_time = nil
    state.current_special.recast_id = nil
    state.current_special.target = nil
    state.current_special.is_sleep2 = false

    state.queued_special.name = nil
    state.queued_special.recast_id = nil
    state.queued_special.target = nil
    state.queued_special.is_sleep2 = false
    state.queued_special.priority = nil

    state.sleep2_initial = false
    state.sleep2_waiting_for_confirm = false
    state.sleep2_name = nil
    state.sleep2_recast_id = nil

    state.casting = false
    state.cast_fail_time = nil
    state.last_spell = nil
    state.last_target_id = nil

    state.suspend_buffs = false
    state.buff_resume_time = 0
    state.combatbuff.casting = false
    state.combatbuff.start_time = nil
    state.combatbuff.last_finish_time = 0
    state.combatbuff.suspend_until = nil

    state.combatbuff.pending = false
    state.combatbuff.pending_spell = nil
    state.combatbuff.pending_target = nil

    state.buffset_last_finish_time = 0

    state.first_hit_done = false

    reset_mbset()

    log('完全リセット')
end

------------------------------------------------------------
-- addon command（コマンド処理）
------------------------------------------------------------
windower.register_event('addon command', function(...)
    local args = {...}
    local cmd = args[1] and args[1]:lower():gsub('%s+', '') or ''

    if cmd == 'on' then
        state.enabled = true
        log('ON')

    elseif cmd == 'off' then
        state.enabled = false
        ws_set_off()
        state.buffset.active = false
        state.buffset.step = 0
        state.buffset.waiting_for_finish = false
        state.buffset.next_step_on_finish = 0
        state.buffset.next_time = 0
        reset_retry()
        reset_mbset()
        log('OFF')

    elseif cmd == 'reset' then
        reset_all_states()

    elseif cmd == 'seta' then
        toggle_seta()

    elseif cmd == 'setb' then
        toggle_setb()

    elseif cmd == 'setc' then
        toggle_setc()

    elseif cmd == 'buffset' then
        start_buffset()

    elseif cmd == 'stun' then
        enqueue_special_spell(spells.stun.name, spells.stun.recast_id, '<t>', false)

    elseif cmd == 'sleepga' then
        enqueue_special_spell(spells.sleepga.name, spells.sleepga.recast_id, '<t>', false)

    elseif cmd == 'sleep2' or cmd == 'sleepii' then
        enqueue_special_spell(spells.sleep2.name, spells.sleep2.recast_id, '<stnpc>', true)

    elseif cmd == 'silence' then
        enqueue_special_spell(spells.silence.name, spells.silence.recast_id, '<t>', false)

    elseif cmd == 'dispel' then
        enqueue_special_spell(spells.dispel.name, spells.dispel.recast_id, '<t>', false)

    elseif cmd == 'cure4' then
        enqueue_special_spell(spells.cure4.name, spells.cure4.recast_id, nil, false)

    elseif cmd == 'debug' then
        log(('debug: ws_active=%s buffset=%s step=%d waiting=%s special=%s retry_active=%s mbset.active=%s mbcount=%d last_props=%s target_id=%s suspend_buffs=%s'):format(
            tostring(state.ws.active),
            tostring(state.buffset.active),
            state.buffset.step,
            tostring(state.buffset.waiting_for_finish),
            tostring(state.current_special.name or 'nil'),
            tostring(state.retry.active),
            tostring(state.mbset.active),
            tonumber(state.mbset.count or 0),
            tostring(state.mbset.last_props and table.concat(state.mbset.last_props, ',') or 'nil'),
            tostring(state.last_target_id or 'nil'),
            tostring(state.suspend_buffs)
        ))

    else
        log('使い方: //ardm on | off | reset | seta | setb | setc | buffset | sleepga | sleep2 | silence | dispel | cure4 | debug')
    end
end)