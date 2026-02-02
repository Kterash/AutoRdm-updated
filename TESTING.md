# Manual Testing Guide for WS1 and MB1 Fixes

## Overview
This document describes how to manually test the fixes for WS1 and MB1 execution issues.

## Issue ①: WS1 Execution Flow (Already Working)

### Test Scenario 1: WS1 Reservation and Execution
**Steps:**
1. Activate a WS set (e.g., `/lua c autordm seta`)
2. Observe the log messages:
   - Should see "WS1予約" (WS1 reserved) if conditions not ready
   - Should see "WS1実行待機" (WS1 execution waiting) with reason if blocked
   - Should see WS1 execute when `can_start_special()` is ready
3. Verify WS1 is NOT executed while:
   - Casting a spell
   - In WS motion
   - During delay period

**Expected Result:**
- WS1 waits for proper timing
- No "Unable to use weapon skill" or "no action category" errors

### Test Scenario 2: WS1 Retry on Failure
**Steps:**
1. Activate a WS set
2. Let WS1 execute and fail (e.g., miss, out of range)
3. Observe the log: Should see "WS1 リトライ移行" (WS1 retry transition)
4. Verify WS1 retry waits for proper timing with "WS1リトライ待機" if needed
5. Verify WS1 retry executes when ready

**Expected Result:**
- WS1 automatically retries after failure
- Retry also waits for `can_start_special()` timing
- No immediate execution causing errors

## Issue ②: MB1 Execution Flow (Fixed)

### Test Scenario 3: MB1 Reservation at New Skillchain
**Steps:**
1. Be in a party with other players
2. Have party members perform weapon skills to create a skillchain
3. When the first skillchain is detected, observe the log:
   - Should see "MBセット 開始" (MB set start)
   - Should see "MB1予約" (MB1 reserved) or "スペシャル魔法中に予約" (reserved during special spell)
4. Verify MB1 does NOT execute immediately
5. Verify MB1 waits for `can_start_special()` to be ready
6. Verify MB1 executes when timing is good

**Expected Result:**
- MB1 is reserved, not immediately executed
- No "魔法が唱えられない" (cannot cast spell) errors
- MB1 waits for proper timing

### Test Scenario 4: Rapid Skillchain Detection (Critical)
**Steps:**
1. Be in a party creating skillchains rapidly
2. While an MB set is active (MB1 or MB2 in progress):
   - Have party create a NEW skillchain
3. Observe the behavior:
   - Old MB set should be reset: "新しい連携を検知; MBセットをリセット"
   - New MB set should start: "MBセット 開始"
   - MB1 should be reserved: "MB1予約"
4. Verify the NEW MB1 does NOT execute immediately
5. Verify the NEW MB1 waits for proper timing

**Expected Result:**
- Old MB set cleanly transitions to new MB set
- New MB1 is properly reserved
- No "cannot cast spell" errors from immediate execution
- MB1 waits and executes when `can_start_special()` is ready

### Test Scenario 5: MB1 During Special Spell
**Steps:**
1. Cast a special spell (e.g., Dia, Slow)
2. While special spell is casting, have party create a skillchain
3. Observe: Should see "スペシャル魔法中に予約" (reserved during special spell)
4. When special spell completes:
   - If `can_start_special()` is ready: MB1 should execute with "SP終了後に実行"
   - If not ready: Should see "SP終了後実行待機" (waiting after SP) and MB1 executes later

**Expected Result:**
- MB1 properly reserved during special spell
- MB1 executes after special spell when timing is good
- No casting conflicts or errors

## Common Issues to Watch For

### For WS1:
- ❌ "Unable to use weapon skill" errors when trying to execute
- ❌ "no action category" (アクションカテゴリなし) errors
- ❌ WS1 executing during spell casting
- ❌ WS1 retry not happening after failure

### For MB1:
- ❌ "魔法が唱えられない" (cannot cast spell) errors
- ❌ "Unable to cast spells" messages in log
- ❌ MB1 executing immediately without waiting
- ❌ MB1 executing during WS motion or other actions
- ❌ New MB1 failing when rapid skillchains occur

## Success Criteria

All scenarios should show:
- ✅ Proper reservation with "予約" (reserved) log messages
- ✅ Waiting with "待機" (waiting) log messages when conditions not ready
- ✅ Execution only when `can_start_special()` returns true
- ✅ No casting or action errors
- ✅ Smooth transitions between old and new MB sets
