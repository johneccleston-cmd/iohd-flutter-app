-- PROPOSAL ONLY, NOT RUN. v2 of payroll_run8_backfill_PROPOSAL_2026-11-16.sql (same 132 rows, harder guards).
-- Needs the user's explicit approval before anyone runs it against production.
--
-- Adds the 132 sales-commission rows that payroll run 8 (week of Oct 26, 2026) never saved for Heather Vera
-- (user 34, run line 34). The line already holds the right amount ($1,589.42, paid); only its per-job breakdown is
-- missing, because the old items query skipped sales rows for people off technician commission.
--
-- It changes NO paid amount: payroll_runs and payroll_run_lines are only read (and row-locked). The engine reads run
-- items only for kinds 'advance' and 'settlement', so 'rep_commission' rows cannot move any pay. What changes: run 8's
-- detail lists the rows, Jarvis's job lookup shows these as paid in run 8, and the manual delete is blocked for these
-- 132 records (123 jobs + 9 won estimates, which the engine keys by estimate number; all already locked or won).
--
-- Rows: the engine's own rep_commission rows, re-checked read-only against production on 2026-11-16 (132 of 132 match
-- job, date and amount both ways; sum $1,589.42; the line's job_ids are exactly these 132). Source list:
-- build/payroll_audit/backfill/heather_run8_sales_rows.csv.
--
-- What v2 adds over v1 (dry-run on a scratch Postgres with production's table definitions):
--   * locks run 8 (FOR UPDATE) and the week's payroll advisory lock, in the same order as the app's void route, then
--     line 34: a void, a finalize for the week, or a second copy of this script waits, then sees the result and stops;
--   * checks the whole line (week, name, payable, previously paid, no retainage/advances, 132 distinct job_ids);
--   * refuses if ANY finalized run already has rep_commission items for user 34 on these jobs (not just line 34);
--   * checks every amount is a positive whole-cent figure, and that the row list and the line's job_ids are the same set;
--   * after the insert, checks count, commission, net and the job set against the line again.
-- Every check raises an exception, which aborts the transaction: nothing is written unless all of them pass.
--
-- HOW TO RUN (only with approval):  psql "<connection>" -v ON_ERROR_STOP=1 -f <this file>
--   psql stops at the first error and the open transaction is rolled back when it disconnects.
--   In pgAdmin: run the whole file; if any error shows, run ROLLBACK (or close the tab) before doing anything else.
--   To rehearse without writing, change the final COMMIT to ROLLBACK (it still takes the locks briefly).
-- UNDO (only these rows, only this line):
--   DELETE FROM payroll_run_items WHERE run_id = 8 AND line_id = 34 AND user_id = 34 AND kind = 'rep_commission';

BEGIN;

-- 1. Lock in the app's order (void: run row FOR UPDATE, then the week's advisory lock), then the line.
SELECT id FROM payroll_runs WHERE id = 8 FOR UPDATE;
SELECT pg_advisory_xact_lock(hashtext('payroll:2026-10-26'));
SELECT id FROM payroll_run_lines WHERE id = 34 FOR UPDATE;

-- 2. The run and line are exactly the paid $1,589.42 sales line, and nothing was saved for it yet.
DO $$
DECLARE
    l record;
BEGIN
    SELECT r.status, r.week_start, ln.user_id, ln.tech_name, ln.job_commission, ln.payable, ln.previously_paid,
           ln.amount_paid, ln.retainage_held, ln.advances_paid, ln.advances_repaid,
           cardinality(ln.job_ids) AS n_ids, (SELECT COUNT(DISTINCT j) FROM UNNEST(ln.job_ids) j) AS n_distinct
      INTO l
      FROM payroll_runs r JOIN payroll_run_lines ln ON ln.run_id = r.id
     WHERE r.id = 8 AND ln.id = 34;
    IF NOT FOUND THEN RAISE EXCEPTION 'run 8 / line 34 not found'; END IF;
    IF l.status <> 'finalized' OR l.week_start <> DATE '2026-10-26' THEN
        RAISE EXCEPTION 'run 8 is not the finalized run for the week of 2026-10-26 (status %, week %)', l.status, l.week_start;
    END IF;
    IF l.user_id <> 34 OR l.tech_name <> 'Heather Vera' THEN RAISE EXCEPTION 'line 34 is not Heather Vera (user 34)'; END IF;
    IF l.job_commission <> 1589.42 OR l.payable <> 1589.42 OR l.amount_paid <> 1589.42 OR l.previously_paid <> 0
       OR l.retainage_held <> 0 OR l.advances_paid <> 0 OR l.advances_repaid <> 0 THEN
        RAISE EXCEPTION 'line 34 is not the plain $1,589.42 sales line';
    END IF;
    IF l.n_ids <> 132 OR l.n_distinct <> 132 THEN
        RAISE EXCEPTION 'line 34 records % job ids (% distinct), expected 132', l.n_ids, l.n_distinct;
    END IF;
    IF EXISTS (SELECT 1 FROM payroll_run_items WHERE line_id = 34) THEN
        RAISE EXCEPTION 'line 34 already has items; nothing to backfill';
    END IF;
END $$;

CREATE TEMP TABLE hv_rows (job_id text PRIMARY KEY, work_date date NOT NULL, amount numeric NOT NULL) ON COMMIT DROP;
INSERT INTO hv_rows (job_id, work_date, amount) VALUES
    ('1097276976', DATE '2026-10-01', 4.40),
    ('1098306934', DATE '2026-10-01', 5.90),
    ('1093547114', DATE '2026-10-02', 2.20),
    ('1095813152', DATE '2026-10-02', 12.60),
    ('1097921819', DATE '2026-10-02', 6.60),
    ('1093652699', DATE '2026-10-06', 6.27),
    ('1095809012', DATE '2026-10-06', 101.16),
    ('1097884615', DATE '2026-10-06', 2.20),
    ('1097884863', DATE '2026-10-06', 2.20),
    ('1097933768', DATE '2026-10-06', 2.20),
    ('1098031292', DATE '2026-10-06', 2.20),
    ('1098145889', DATE '2026-10-06', 2.20),
    ('1098146343', DATE '2026-10-06', 2.20),
    ('1098147137', DATE '2026-10-06', 2.20),
    ('1098272161', DATE '2026-10-06', 2.20),
    ('1098965163', DATE '2026-10-06', 3.94),
    ('1095203892', DATE '2026-10-07', 12.00),
    ('1097932187', DATE '2026-10-07', 2.20),
    ('1097932660', DATE '2026-10-07', 2.20),
    ('1098463637', DATE '2026-10-07', 6.93),
    ('1098466995', DATE '2026-10-07', 15.94),
    ('1098958838', DATE '2026-10-07', 3.94),
    ('1099063158', DATE '2026-10-07', 7.51),
    ('1095369168', DATE '2026-10-09', 7.98),
    ('1095535091', DATE '2026-10-09', 6.00),
    ('1096720854', DATE '2026-10-09', 6.00),
    ('1096722768', DATE '2026-10-09', 6.00),
    ('1097924693', DATE '2026-10-09', 2.20),
    ('1098467707', DATE '2026-10-09', 7.88),
    ('1098479286', DATE '2026-10-09', 2.20),
    ('1098485551', DATE '2026-10-09', 9.34),
    ('1098508476', DATE '2026-10-09', 4.40),
    ('1098510590', DATE '2026-10-09', 2.20),
    ('1098141268', DATE '2026-10-12', 2.20),
    ('1098956815', DATE '2026-10-12', 3.50),
    ('1099101367', DATE '2026-10-12', 0.98),
    ('1098960689', DATE '2026-10-13', 3.94),
    ('1099058008', DATE '2026-10-13', 20.94),
    ('1099211785', DATE '2026-10-13', 2.20),
    ('1095203295', DATE '2026-10-14', 12.00),
    ('1095207874', DATE '2026-10-14', 6.00),
    ('1098147846', DATE '2026-10-14', 2.20),
    ('1098241168', DATE '2026-10-14', 3.94),
    ('1098983087', DATE '2026-10-14', 10.94),
    ('1099456844', DATE '2026-10-14', 6.86),
    ('1093084168', DATE '2026-10-15', 6.00),
    ('1093553947', DATE '2026-10-15', 6.00),
    ('1094865244', DATE '2026-10-15', 49.90),
    ('1095201263', DATE '2026-10-15', 6.00),
    ('1095207455', DATE '2026-10-15', 12.00),
    ('1096721434', DATE '2026-10-15', 6.00),
    ('1098313648', DATE '2026-10-15', 8.00),
    ('1099373142', DATE '2026-10-15', 2.20),
    ('1099544037', DATE '2026-10-15', 5.28),
    ('1095199813', DATE '2026-10-16', 6.00),
    ('1095206283', DATE '2026-10-16', 6.00),
    ('1096676465', DATE '2026-10-16', 6.00),
    ('1099401293', DATE '2026-10-16', 4.35),
    ('1099590292', DATE '2026-10-16', 3.30),
    ('1099705228', DATE '2026-10-16', 3.30),
    ('1099783626', DATE '2026-10-16', 1.50),
    ('1093746008', DATE '2026-10-19', 6.27),
    ('1094280444', DATE '2026-10-19', 199.13),
    ('1095535451', DATE '2026-10-19', 6.00),
    ('1096184283', DATE '2026-10-19', 6.00),
    ('1096669974', DATE '2026-10-19', 6.00),
    ('1096721142', DATE '2026-10-19', 6.00),
    ('1097266344', DATE '2026-10-19', 33.30),
    ('1098314169', DATE '2026-10-19', 5.50),
    ('1099360559', DATE '2026-10-19', 4.40),
    ('1099539392', DATE '2026-10-19', 2.20),
    ('1099542855', DATE '2026-10-19', 2.20),
    ('1099776698', DATE '2026-10-19', 4.50),
    ('1099780417', DATE '2026-10-19', 5.50),
    ('1095208817', DATE '2026-10-20', 12.00),
    ('1099086415', DATE '2026-10-20', 20.30),
    ('1099369821', DATE '2026-10-20', 4.40),
    ('1099539918', DATE '2026-10-20', 2.20),
    ('1099540141', DATE '2026-10-20', 2.20),
    ('1094461921', DATE '2026-10-21', 3.94),
    ('1097089324', DATE '2026-10-21', 60.28),
    ('1097786489', DATE '2026-10-21', 6.00),
    ('1099361165', DATE '2026-10-21', 2.20),
    ('1099543693', DATE '2026-10-21', 5.28),
    ('1099878817', DATE '2026-10-21', 2.20),
    ('1099879303', DATE '2026-10-21', 2.20),
    ('1092783677', DATE '2026-10-22', 210.91),
    ('1096545665', DATE '2026-10-22', 23.51),
    ('1097785609', DATE '2026-10-22', 6.00),
    ('1100014191', DATE '2026-10-22', 2.20),
    ('1095205426', DATE '2026-10-23', 6.00),
    ('1098293446', DATE '2026-10-23', 5.28),
    ('1099370240', DATE '2026-10-23', 2.20),
    ('1099880864', DATE '2026-10-23', 2.20),
    ('1099882534', DATE '2026-10-23', 2.20),
    ('1099883489', DATE '2026-10-23', 2.20),
    ('1099883808', DATE '2026-10-23', 2.20),
    ('1094749459', DATE '2026-10-26', 6.00),
    ('1096724120', DATE '2026-10-26', 6.00),
    ('1096725913', DATE '2026-10-26', 6.00),
    ('1099370565', DATE '2026-10-26', 2.20),
    ('1099883223', DATE '2026-10-26', 2.20),
    ('1100053101', DATE '2026-10-26', 3.30),
    ('1096657235', DATE '2026-10-27', 6.00),
    ('1096723093', DATE '2026-10-27', 6.00),
    ('1096727586', DATE '2026-10-27', 12.00),
    ('1099749987', DATE '2026-10-27', 2.20),
    ('1099751521', DATE '2026-10-27', 2.20),
    ('1099884366', DATE '2026-10-27', 2.20),
    ('1099887857', DATE '2026-10-27', 2.20),
    ('1099888446', DATE '2026-10-27', 2.20),
    ('1100316090', DATE '2026-10-27', 3.00),
    ('1100319254', DATE '2026-10-27', 3.00),
    ('1100321203', DATE '2026-10-27', 4.50),
    ('1095160209', DATE '2026-10-28', 6.00),
    ('1096977024', DATE '2026-10-28', 18.00),
    ('1100219315', DATE '2026-10-28', 4.40),
    ('1100263579', DATE '2026-10-28', 4.50),
    ('1096659846', DATE '2026-10-29', 6.00),
    ('1096975854', DATE '2026-10-29', 18.00),
    ('1099633895', DATE '2026-10-29', 2.20),
    ('1100218440', DATE '2026-10-29', 2.20),
    ('1100318656', DATE '2026-10-29', 4.50),
    ('1100525538', DATE '2026-10-29', 2.20),
    ('1100653191', DATE '2026-10-29', 3.30),
    ('1096784577', DATE '2026-10-30', 200.78),
    ('1097839095', DATE '2026-10-30', 54.00),
    ('1099558445', DATE '2026-10-30', 27.72),
    ('1100219619', DATE '2026-10-30', 2.20),
    ('1100651917', DATE '2026-10-30', 5.50),
    ('1100747526', DATE '2026-10-30', 5.50),
    ('1100843189', DATE '2026-10-30', 3.00)
;

-- 3. The rows are the line: 132 distinct positive cent amounts adding to $1,589.42, the same set as its job_ids, and no
--    finalized run already holds a sales item for Heather on any of them.
DO $$
BEGIN
    IF (SELECT COUNT(*) FROM hv_rows) <> 132 OR (SELECT SUM(amount) FROM hv_rows) <> 1589.42 THEN
        RAISE EXCEPTION 'the rows do not add to 132 / $1,589.42';
    END IF;
    IF EXISTS (SELECT 1 FROM hv_rows WHERE amount <= 0 OR amount <> ROUND(amount, 2)) THEN
        RAISE EXCEPTION 'every amount must be a positive whole-cent figure';
    END IF;
    IF EXISTS (SELECT job_id FROM hv_rows EXCEPT SELECT UNNEST(job_ids) FROM payroll_run_lines WHERE id = 34)
       OR EXISTS (SELECT UNNEST(job_ids) FROM payroll_run_lines WHERE id = 34 EXCEPT SELECT job_id FROM hv_rows) THEN
        RAISE EXCEPTION 'the rows and the job_ids of line 34 are not the same set';
    END IF;
    IF EXISTS (SELECT 1 FROM payroll_run_items i JOIN payroll_runs r ON r.id = i.run_id AND r.status = 'finalized'
                WHERE i.user_id = 34 AND i.kind = 'rep_commission' AND i.job_id IN (SELECT job_id FROM hv_rows)) THEN
        RAISE EXCEPTION 'a finalized run already has a sales item for user 34 on one of these jobs';
    END IF;
END $$;

-- 4. Write the breakdown (the same shape payroll_runs.js now saves for a rep_commission row).
INSERT INTO payroll_run_items (run_id, line_id, user_id, kind, job_id, work_date, commission, retainage_held,
                               advance, advance_repaid, advance_shortfall, net)
SELECT 8, 34, 34, 'rep_commission', job_id, work_date, amount, 0, 0, 0, 0, amount FROM hv_rows ORDER BY work_date, job_id;

-- 5. After the insert, the items ARE the line: count, commission, net and the job set.
DO $$
DECLARE
    s record;
BEGIN
    SELECT COUNT(*) AS n, COUNT(DISTINCT job_id) AS nd, SUM(commission) AS comm, SUM(net) AS net INTO s
      FROM payroll_run_items WHERE line_id = 34;
    IF s.n <> 132 OR s.nd <> 132
       OR s.comm <> (SELECT job_commission FROM payroll_run_lines WHERE id = 34)
       OR s.net <> (SELECT amount_paid FROM payroll_run_lines WHERE id = 34) THEN
        RAISE EXCEPTION 'after insert the items do not equal the line (% rows, % / %)', s.n, s.comm, s.net;
    END IF;
    IF EXISTS (SELECT job_id FROM payroll_run_items WHERE line_id = 34
               EXCEPT SELECT UNNEST(job_ids) FROM payroll_run_lines WHERE id = 34) THEN
        RAISE EXCEPTION 'after insert an item is not one of the jobs of line 34';
    END IF;
END $$;

SELECT COUNT(*) AS items_written, SUM(net) AS total FROM payroll_run_items WHERE line_id = 34;

COMMIT;
