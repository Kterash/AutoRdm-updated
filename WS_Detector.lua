------------------------------------------------------------
-- WS_Detector.lua-1/2
-- ・WS1 / WS2 / 割り込み WS の成功判定を内部で完結
-- ・本体は result.success を見るだけ
-- ・フェーズ(state.ws.phase) には一切触らない
-- ・追加: analyze(act, ws1_props) --- 解析専用 API（AutoRdm 等が常時監視して使うため）
------------------------------------------------------------

local WS_Detector = {}

------------------------------------------------------------
-- 1. Skillchains式 成功判定（旧ロジック）
------------------------------------------------------------

local SC_MESSAGE_IDS = {
    [110] = true,
    [185] = false,
    [187] = true,
    [317] = true,
    [802] = true,
}

local SC_SKILLCHAIN_IDS = {
    -- Level 2/3 Skillchains (damage)
    [288] = true, [289] = true, [290] = true, [291] = true,
    [767] = true, [768] = true,
    -- Level 1 Skillchains (damage)
    [292] = true, [293] = true, [294] = true, [295] = true,
    [296] = true, [297] = true, [298] = true, [299] = true,
    [300] = true, [301] = true, [302] = true,
    -- Level 2/3 Skillchains (healing)
    [385] = true, [386] = true,
    -- Level 1 Skillchains (healing)
    [387] = true, [388] = true, [389] = true, [390] = true,
    [391] = true, [392] = true, [393] = true, [394] = true,
    [395] = true, [396] = true, [397] = true, [398] = true,
    -- Other skillchain variants
    [732] = true, [769] = true, [770] = true,
}

local SC_MESSAGES_FROM_AEM = {
    -- Level 2/3 Skillchains
    [288] = 'Light',
    [289] = 'Darkness',
    [290] = 'Gravitation',
    [291] = 'Fragmentation',
    [767] = 'Radiance',
    [768] = 'Umbra',
    -- Level 1 Skillchains
    [292] = 'Distortion',
    [293] = 'Fusion',
    [294] = 'Compression',
    [295] = 'Liquefaction',
    [296] = 'Induration',
    [297] = 'Reverberation',
    [298] = 'Transfixion',
    [299] = 'Scission',
    [300] = 'Detonation',
    [301] = 'Impaction',
    [302] = 'Cosmic Elucidation',
    -- Healing variants (Level 2/3)
    [385] = 'Light',
    [386] = 'Darkness',
    [387] = 'Gravitation',
    [388] = 'Fragmentation',
    [389] = 'Distortion',
    [390] = 'Fusion',
    -- Healing variants (Level 1)
    [391] = 'Compression',
    [392] = 'Liquefaction',
    [393] = 'Induration',
    [394] = 'Reverberation',
    [395] = 'Transfixion',
    [396] = 'Scission',
    [397] = 'Detonation',
    [398] = 'Impaction',
    -- Other variants
    [732] = 'Universal Enlightenment',
    [769] = 'Radiance',
    [770] = 'Umbra',
}

local function sc_is_hit_success(hit_action)
    if not hit_action then
        return false, false
    end

    local msg     = hit_action.message or 0
    local add_msg = hit_action.add_effect_message or 0

    if SC_SKILLCHAIN_IDS[add_msg] then
        return true, true
    end

    if msg == 185 then
        return false, false
    end

    if SC_MESSAGE_IDS[msg] then
        return true, false
    end

    if (hit_action.param or 0) > 0 and msg ~= 0 then
        return true, false
    end

    return false, false
end

local function is_ws_success(hit_action)
    local ok, _ = sc_is_hit_success(hit_action)
    return ok
end

------------------------------------------------------------
-- 2. WS名・属性取得（PC / フェイス）
------------------------------------------------------------

local SC_EN_TO_JA = {
    Light         = "光",
    Darkness      = "闇",
    Fusion        = "核熱",
    Fragmentation = "分解",
    Distortion    = "湾曲",
    Gravitation   = "重力",
    Liquefaction  = "溶解",
    Induration    = "硬化",
    Detonation    = "炸裂",
    Impaction     = "衝撃",
    Scission      = "切断",
    Reverberation = "振動",
    Compression   = "圧縮",
    Transfixion   = "貫通",
}

local function get_ws_name_and_props(act, hit)
    local is_face = (act.category == 7 or act.category == 11)
    local wsid, ws_name, actor_type
    local props = {}

    if is_face then
        wsid = act.param
        local ma_entry = res.monster_abilities[wsid]

        if (not ma_entry) and hit and hit.message then
            for id, ws in pairs(res.monster_abilities) do
                if ws.message == hit.message then
                    ma_entry = ws
                    wsid = id
                    break
                end
            end
        end

        if not ma_entry then
            return nil
        end

        ws_name    = ma_entry.ja or ma_entry.en or ('WSID:' .. tostring(wsid))
        actor_type = 'face'

        for _, p_sc in ipairs({
            ma_entry.skillchain_a,
            ma_entry.skillchain_b,
            ma_entry.skillchain_c,
        }) do
            if p_sc and p_sc ~= "" then
                table.insert(props, p_sc)
            end
        end

        if ma_entry.skillchain and #props == 0 then
            for _, p_sc in ipairs(ma_entry.skillchain) do
                if p_sc and p_sc ~= "" then
                    table.insert(props, p_sc)
                end
            end
        end

    else
        wsid = act.param
        local ws_res = res.weapon_skills[wsid]
        if not ws_res then
            return nil
        end

        ws_name    = ws_res.ja or ws_res.en or ('WSID:' .. tostring(wsid))
        actor_type = 'pc'

        for _, p_sc in ipairs({
            ws_res.skillchain_a,
            ws_res.skillchain_b,
            ws_res.skillchain_c,
        }) do
            if p_sc and p_sc ~= "" then
                table.insert(props, p_sc)
            end
        end
    end

    return {
        ws_id      = wsid,
        ws_name    = ws_name,
        actor_type = actor_type,
        props      = props,
    }
end

------------------------------------------------------------
-- WS_Detector.lua-2/2
------------------------------------------------------------
------------------------------------------------------------
-- 3. 属性×属性 → SC 英語名（完全版）
------------------------------------------------------------

local SC_COMBO = {

    --------------------------------------------------
    -- Lv1（溶解・硬化・炸裂・衝撃・切断・振動・収縮・貫通）
    --------------------------------------------------

    Liquefaction = {
        Scission      = "Scission",
        Impaction     = "Fusion",
    },

    Scission = {
        Liquefaction  = "Liquefaction",
        Detonation    = "Detonation",
        Reverberation = "Reverberation",
    },

    Impaction = {
        Liquefaction  = "Liquefaction",
        Detonation    = "Detonation",
    },

    Induration = {
        Impaction     = "Impaction",
        Compression   = "Compression",
        Reverberation = "Fragmentation",
    },

    Reverberation = {
        Induration    = "Induration",
        Impaction     = "Impaction",
    },

    Detonation = {
        Scission      = "Scission",
        Compression   = "Gravitation",
    },

    Compression = {
        Detonation    = "Detonation",
        Transfixion   = "Transfixion",
    },

    Transfixion = {
        Reverberation = "Reverberation",
        Compression   = "Compression",
        Scission      = "Distortion",
    },

    --------------------------------------------------
    -- Lv2（核熱・重力・分解・湾曲）
    --------------------------------------------------

    Fusion = {
        Gravitation   = "Gravitation",
        Fragmentation = "Light",
    },

    Gravitation = {
        Fragmentation = "Fragmentation",
        Distortion    = "Darkness",
    },

    Fragmentation = {
        Distortion    = "Distortion",
        Fusion        = "Light",
    },

    Distortion = {
        Fusion        = "Fusion",
        Gravitation   = "Darkness",
    },

    --------------------------------------------------
    -- Lv3（光・闇）
    --------------------------------------------------

    Light = {
        Light         = "Light",
    },

    Darkness = {
        Darkness      = "Darkness",
    },
}

local function determine_skillchain_sc(props1, props2)
    if not props1 or not props2 then return nil end

    for _, p1 in ipairs(props1) do
        for _, p2 in ipairs(props2) do
            local row = SC_COMBO[p1]
            local sc  = row and row[p2]
            if sc then
                return sc
            end
        end
    end
end

------------------------------------------------------------
-- 4. MB1/MB2 決定
------------------------------------------------------------

local MB_MAP = {
    ["光"]   = {mb3="サンダーIV", mb2="サンダーII"},
    ["闇"]   = {mb3="ブリザドIV", mb2="ブリザドII"},
    ["湾曲"] = {mb3="ブリザドIV", mb2="ブリザドII"},
    ["分解"] = {mb3="サンダーIV", mb2="サンダーII"},
    ["核熱"] = {mb3="ファイアIV", mb2="ファイアII"},
    ["重力"] = {mb3="ストーンIV", mb2="ストーンII"},
    ["溶解"] = {mb3="ファイアIV",  mb2="ファイアII"},
    ["硬化"] = {mb3="ブリザドIV",  mb2="ブリザドII"},
    ["炸裂"] = {mb3="エアロIV",    mb2="エアロII"},
    ["衝撃"] = {mb3="サンダーIV",  mb2="サンダーII"},
    ["切断"] = {mb3="ストーンIV",  mb2="ストーンII"},
    ["振動"] = {mb3="ウォータIV",  mb2="ウォータII"},
    ["圧縮"] = {mb3="ブリザドIV",  mb2="ブリザドII"},
    ["貫通"] = {mb3="サンダーIV",  mb2="サンダーII"},
}

local function select_mb_magic(sc_ja)
    if sc_ja and MB_MAP[sc_ja] then
        return MB_MAP[sc_ja].mb3, MB_MAP[sc_ja].mb2
    end
    return "サンダーII", "サンダー"
end

local function decide_mb_magic(sc_en)
    if not sc_en then
        return nil, nil
    end

    local sc_ja = SC_EN_TO_JA[sc_en]
    if not sc_ja then
        return nil, nil
    end

    local mb1, mb2 = select_mb_magic(sc_ja)
    return mb1, mb2
end

------------------------------------------------------------
-- 5. 新規公開関数：analyze
--  - act を解析して、ws_name, props, actor_type, hit, sc_en, mb1, mb2, skillchains_success を返す
--  - 解析専用（成功/失敗の最終判定は呼び出し側に委ねる）
------------------------------------------------------------
function WS_Detector.analyze(act, ws1_props)
    if not act or not act.targets then return nil end

    local t_tgt = act.targets[1]
    local hit   = t_tgt and t_tgt.actions and t_tgt.actions[1]
    if not hit then
        return {
            ws_id      = nil,
            ws_name    = nil,
            props      = nil,
            sc_en      = nil,
            mb1        = nil,
            mb2        = nil,
            actor_type = nil,
            hit        = nil,
            skillchains_success = false,
            reason     = "no_hit",
        }
    end

    local base = get_ws_name_and_props(act, hit)
    if not base then return nil end

    local wsid       = base.ws_id
    local ws_name    = base.ws_name
    local props      = base.props
    local actor_type = base.actor_type

    local skillchains_success = is_ws_success(hit)

    local sc_en_from_packet = SC_MESSAGES_FROM_AEM[hit.add_effect_message or 0]
    local sc_en_calc        = nil

    if ws1_props and (not sc_en_from_packet) then
        sc_en_calc = determine_skillchain_sc(ws1_props, props)
    end

    local sc_en = sc_en_from_packet or sc_en_calc

    local mb1, mb2 = decide_mb_magic(sc_en)

    return {
        ws_id      = wsid,
        ws_name    = ws_name,
        props      = props,
        sc_en      = sc_en,
        mb1        = mb1,
        mb2        = mb2,
        actor_type = actor_type,
        hit        = hit,
        skillchains_success = skillchains_success,
        add_effect_message = hit.add_effect_message or 0,
    }
end

------------------------------------------------------------
-- 6. 既存 parse は analyze を利用して後方互換を維持
------------------------------------------------------------
function WS_Detector.parse(act, ws1_props, mode, cfg, hit_flag, expected_sc_en)
    -- use analyze to obtain base data
    local analyzed = WS_Detector.analyze(act, ws1_props)
    if not analyzed then return nil end

    local wsid       = analyzed.ws_id
    local ws_name    = analyzed.ws_name
    local props      = analyzed.props
    local actor_type = analyzed.actor_type
    local hit        = analyzed.hit
    local skillchains_success = analyzed.skillchains_success

    local sc_en_from_packet = SC_MESSAGES_FROM_AEM[analyzed.add_effect_message or 0]
    local sc_en_calc = nil
    if ws1_props and (not sc_en_from_packet) then
        sc_en_calc = determine_skillchain_sc(ws1_props, props)
    end
    local sc_en = sc_en_from_packet or sc_en_calc

    local mb1, mb2 = decide_mb_magic(sc_en)

    --------------------------------------------------------
    -- ★ 最終成功判定 (従来の parse の判定)
    --------------------------------------------------------
    local final_success = false
    local reason        = nil

    if mode == "ws1" then
        final_success =
            (ws_name == cfg.ws1) or
            skillchains_success

        if not final_success then
            reason = "ws1_failed"
        end

    elseif mode == "ws2" then
        final_success =
            (ws_name == cfg.ws2) or
            skillchains_success or
            (sc_en ~= nil)

        if not final_success then
            reason = "ws2_failed"
        end

    elseif mode == "interrupt" then
        final_success =
            hit_flag or
            skillchains_success

        if not final_success then
            reason = "interrupt_failed"
        end

    elseif mode == "post_mb" then
        if not expected_sc_en then
            final_success = true
        else
            if sc_en == nil then
                final_success = false
                reason = "sc_broken"
            elseif sc_en ~= expected_sc_en then
                final_success = false
                reason = "sc_changed"
            else
                final_success = true
            end
        end
    end

    return {
        ws_id      = wsid,
        ws_name    = ws_name,
        props      = props,
        sc_en      = sc_en,
        mb1        = mb1,
        mb2        = mb2,
        actor_type = actor_type,
        success    = final_success,
        reason     = reason,
        add_effect_message = analyzed.add_effect_message or 0,
    }
end

return WS_Detector