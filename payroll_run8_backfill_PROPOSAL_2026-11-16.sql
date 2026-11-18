-- PROPOSAL ONLY, NOT RUN. Needs the user's explicit approval before anyone runs it against production.
--
-- Adds the 132 sales-commission rows that payroll run 8 (week of Oct 26, 2026) never saved for Heather Vera
-- (user 34, run line 34). The run's line already holds the right amount ($1,589.42, paid); only its per-job
-- breakdown is missing, because the old items query skipped sales rows for people off technician commission.
--
-- It changes NO paid amount: payroll_run_lines and payroll_runs are untouched. The engine reads run items only for
-- kinds 'advance' and 'settlement', so 'rep_commission' rows cannot move any pay. What changes: run 8's detail lists
-- the rows, Jarvis's job lookup shows these jobs as paid in run 8, and the manual job delete is blocked for them
-- (they are already locked, so it was blocked anyway).
--
-- Values are the engine's own rows, read read-only from production on 2026-11-16 and listed in
-- build/payroll_audit/backfill/heather_run8_sales_rows.csv. Every guard below must pass or nothing is written.
-- Undo: DELETE FROM payroll_run_items WHERE run_id = 8 AND line_id = 34 AND kind = 'rep_commission';

BEGIN;

DO $$
DECLARE
    l record;
BEGIN
    SELECT r.status, ln.user_id, ln.job_commission, ln.amount_paid, ln.job_ids INTO l
      FROM payroll_runs r JOIN payroll_run_lines ln ON ln.run_id = r.id
     WHERE r.id = 8 AND ln.id = 34;
    IF NOT FOUND OR l.status <> 'finalized' OR l.user_id <> 34 OR l.job_commission <> 1589.42 OR l.amount_paid <> 1589.42 THEN
        RAISE EXCEPTION 'run 8 / line 34 is not the finalized $1,589.42 line for user 34';
    END IF;
    IF EXISTS (SELECT 1 FROM payroll_run_items WHERE line_id = 34) THEN
        RAISE EXCEPTION 'line 34 already has items; nothing to backfill';
    END IF;
END $$;

CREATE TEMP TABLE hv_rows (job_id varchar PRIMARY KEY, work_date date NOT NULL, amount numeric NOT NULL) ON COMMIT DROP;
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
    ('1100843189', DATE '2026-10-30', 3.00);

DO $$
BEGIN
    IF (SELECT COUNT(*) FROM hv_rows) <> 132 OR (SELECT SUM(amount) FROM hv_rows) <> 1589.42 THEN
        RAISE EXCEPTION 'the rows do not add to 132 / $1,589.42';
    END IF;
    IF EXISTS (SELECT 1 FROM hv_rows h
                WHERE NOT EXISTS (SELECT 1 FROM payroll_run_lines ln, UNNEST(ln.job_ids) AS j(id)
                                   WHERE ln.id = 34 AND j.id::text = h.job_id)) THEN
        RAISE EXCEPTION 'a row is not one of the jobs the run line already records';
    END IF;
END $$;

INSERT INTO payroll_run_items (run_id, line_id, user_id, kind, job_id, work_date, commission, retainage_held,
                               advance, advance_repaid, advance_shortfall, net)
SELECT 8, 34, 34, 'rep_commission', job_id, work_date, amount, 0, 0, 0, 0, amount FROM hv_rows ORDER BY work_date, job_id;

DO $$
BEGIN
    IF (SELECT COUNT(*) FROM payroll_run_items WHERE line_id = 34) <> 132
       OR (SELECT SUM(net) FROM payroll_run_items WHERE line_id = 34) <> (SELECT amount_paid FROM payroll_run_lines WHERE id = 34) THEN
        RAISE EXCEPTION 'after insert the items do not equal the line';
    END IF;
END $$;

COMMIT;
