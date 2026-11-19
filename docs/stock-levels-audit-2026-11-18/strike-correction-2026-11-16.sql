-- Correction of ONE duplicate warehouse strike, 16 Nov 2026 (approved by the owner 2026-11-19; this file is the preview
-- he asked for). Not run by Claude: the Render SQL tool is read-only. Run it yourself in pgAdmin, step by step.
--
-- WHAT HAPPENED (verified read-only, 2026-11-19)
--   The 8:30 AM warehouse audit runs on every server. On 16 Nov two servers were up (deploy overlap, finding N3) and
--   both ran it, 20 ms apart, for the SAME missed truck:
--     2026-11-16T14:30:00.679Z  srv-d7bs4ulm5p6s73f51itg-lrghx  "WAREHOUSE MISSED: No staging done for Andrew Johnson's jobs."
--     2026-11-16T14:30:00.685Z  srv-d7bs4ulm5p6s73f51itg-lrghx  "WAREHOUSE STRIKE applied to warehouse1 (1 missed trucks)."   log id 4ad1120a-8631-4313-8dfc-4fb744c2e6ba
--     2026-11-16T14:30:00.699Z  srv-d7bs4ulm5p6s73f51itg-vpxsw  "WAREHOUSE MISSED: No staging done for Andrew Johnson's jobs."
--     2026-11-16T14:30:00.705Z  srv-d7bs4ulm5p6s73f51itg-vpxsw  "WAREHOUSE STRIKE applied to warehouse1 (1 missed trucks)."   log id cafec977-9243-4f2e-9b2f-6adc5e2274d1
--   Same day, same rule run, same single tech (Andrew Johnson), "1 missed trucks" on both: one missed truck, struck twice.
--   Every other strike in the logs (9-19 Nov) is a single line: 12 Nov (2 missed), 13 Nov (1), 17 Nov (1). Nothing else
--   is touched here.
--
-- THE RECORD TO CORRECT
--   Warehouse strikes are not stored as events: each one is +1 on users.warehouse_strikes of the shared login
--   warehouse1 (users.id 40, users_repo.addWarehouseStrike). So the "record" is that counter. The second strike (the
--   vpxsw line, cafec977...) is the duplicate.
--
-- COUNTS
--   current  warehouse1 (id 40) warehouse_strikes = 11   (read 2026-11-19)
--   proposed warehouse1 (id 40) warehouse_strikes = 10
--
-- AUDIT HISTORY
--   Nothing existing is edited or deleted. The correction adds ONE row to user_admin_audit (the table the Team screen's
--   history reads; it had no strike rows before), with the evidence above in its note. Render keeps logs for 30 days, so
--   the two log lines are also copied into this file and into strike-correction-2026-11-16-evidence.json.
--   Where it shows: Team -> Warehouse (warehouse1) -> change history: "Warehouse strikes  11 -> 10", by John Eccleston,
--   with the note underneath (GET /api/admin/users/40/history; office app team_admin_screen.dart, the history list shows
--   the label, old -> new, who, when and the note).
--
-- SAFETY
--   The UPDATE only runs if warehouse1 still has exactly 11 strikes. If an 8:30 AM strike lands before you run this
--   (the count is then 12), it stops with an error and changes nothing; re-read step 1 and tell me.

-- ── Step 1: preview (read-only). Expect one row: 40 | warehouse1 | Warehouse | 11 ─────────────────────────────────────
SELECT id, username, name, warehouse_strikes
  FROM users
 WHERE LOWER(TRIM(username)) = 'warehouse1';

-- ── Step 2: the correction (one transaction; it refuses to run unless the count is still 11) ─────────────────────────
BEGIN;

DO $$
DECLARE
    n integer;
BEGIN
    UPDATE users
       SET warehouse_strikes = warehouse_strikes - 1,
           updated_at = NOW()
     WHERE id = 40
       AND LOWER(TRIM(username)) = 'warehouse1'
       AND warehouse_strikes = 11;
    GET DIAGNOSTICS n = ROW_COUNT;
    IF n <> 1 THEN
        RAISE EXCEPTION 'warehouse1 does not have 11 strikes any more; nothing was changed';
    END IF;

    INSERT INTO user_admin_audit (user_id, field, old_value, new_value, note, changed_by_id, changed_by_name)
    VALUES (40, 'warehouse_strikes', '11', '10',
            'Duplicate strike removed (approved 2026-11-19). The 8:30 AM warehouse audit on 16 Nov 2026 ran on two servers '
            || 'during a deploy overlap and struck warehouse1 twice for the same missed truck (Andrew Johnson''s jobs): '
            || 'srv-d7bs4ulm5p6s73f51itg-lrghx 14:30:00.685Z (log 4ad1120a-8631-4313-8dfc-4fb744c2e6ba, kept) and '
            || 'srv-d7bs4ulm5p6s73f51itg-vpxsw 14:30:00.705Z (log cafec977-9243-4f2e-9b2f-6adc5e2274d1, removed). '
            || 'Only this strike was corrected.',
            29, 'John Eccleston');
END $$;

-- ── Step 3: check before committing. Expect 10, and one audit row with old 11 -> new 10 ─────────────────────────────
SELECT id, username, warehouse_strikes FROM users WHERE id = 40;
SELECT id, field, old_value, new_value, changed_by_name, changed_at FROM user_admin_audit
 WHERE user_id = 40 AND field = 'warehouse_strikes' ORDER BY id DESC LIMIT 1;

-- If both look right:
COMMIT;
-- If anything looks wrong instead:  ROLLBACK;

-- Undo, if ever needed (also audited): set it back to 11 with a second audit row; never delete the audit row.
-- UPDATE users SET warehouse_strikes = warehouse_strikes + 1, updated_at = NOW() WHERE id = 40 AND warehouse_strikes = 10;
-- INSERT INTO user_admin_audit (user_id, field, old_value, new_value, note, changed_by_id, changed_by_name)
-- VALUES (40, 'warehouse_strikes', '10', '11', 'Undo of the 16 Nov duplicate-strike correction', 29, 'John Eccleston');
