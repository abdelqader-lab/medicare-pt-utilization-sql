-- ===================================================
use healthcare_db;
-- ===================================================
-- Q0. Is the data clean? 
-- ===================================================
-- 0a. Size of the data
select count(*) as Row_Count,
	   count(distinct Rndrng_NPI) as Provider,
       count(distinct Rndrng_Prvdr_State_Abrvtn) as State,
       count(distinct HCPCS_Cd) as Codes
from pt_raw;
-- 60 state codes: states + DC + territories + military/unknown. 
SELECT DISTINCT Rndrng_Prvdr_State_Abrvtn
FROM pt_raw
ORDER BY 1;
-- Military postal codes (AA, AE, AP) and unknown codes (XX, ZZ) are present in the data
-- and are NOT filtered out. They do not affect the top-10 state results.
-- U.S. territories (PR, VI, GU, MP) and DC are kept as valid CMS reporting regions.
-- ======================================================
-- 0b. NULLs in the numeric columns (they appear when a value was not a number)
SELECT SUM(Tot_Benes IS NULL)         AS null_benes,
       SUM(Tot_Srvcs IS NULL)         AS null_srvcs,
       SUM(Avg_Mdcr_Pymt_Amt IS NULL) AS null_pymt
FROM pt_raw;
-- There is no null ----
-- =======================================================
-- 0c. Strange values (zero or negative)
SELECT SUM(Tot_Benes <= 0)         AS bad_benes,
       SUM(Tot_Srvcs <= 0)         AS bad_srvcs,
       SUM(Avg_Mdcr_Pymt_Amt <= 0) AS bad_pymt
FROM pt_raw;
-- we got 5 bad_paymt---
-- ========================================================
-- 0d. Duplicates: the same provider + code + place should appear once
SELECT Rndrng_NPI, HCPCS_Cd, Place_Of_Srvc, COUNT(*) AS n
FROM pt_raw
GROUP BY Rndrng_NPI, HCPCS_Cd, Place_Of_Srvc
HAVING COUNT(*) > 1;
-- no Duplications ----
-- ========================================================
-- 0e. Which codes are actually present and how many rows each
SELECT HCPCS_Cd, MAX(HCPCS_Desc) AS description, COUNT(*) AS rows_n
FROM pt_raw
GROUP BY HCPCS_Cd
ORDER BY rows_n DESC;
-- code 97110 is the most repetation one ---
-- =========================================================
-- 0f. Clean view used by every query below. Write down in your log
CREATE OR REPLACE VIEW pt_clean AS
SELECT Rndrng_NPI                    AS npi,
       Rndrng_Prvdr_State_Abrvtn     AS state,
       HCPCS_Cd                      AS code,
       HCPCS_Desc                    AS code_desc,
       Place_Of_Srvc                 AS place,        -- F = facility, O = office
       Tot_Benes                     AS benes,
       Tot_Srvcs                     AS srvcs,
       Avg_Mdcr_Pymt_Amt             AS avg_pymt,
       Tot_Srvcs * Avg_Mdcr_Pymt_Amt AS est_payment   -- metric 1: money
FROM pt_raw
WHERE Tot_Benes > 0
  AND Tot_Srvcs > 0
  AND Avg_Mdcr_Pymt_Amt > 0;
  
  -- ===================================================================
-- Q1. Where does the money go? (payment by code)
-- =====================================================================
-- 1a.Top CPT Codes by Estimated Medicare Payment
SELECT code,
       MAX(code_desc)                                   AS description,
       SUM(srvcs)                                       AS services,
       ROUND(SUM(est_payment))                          AS est_payment,
       ROUND(100 * SUM(est_payment) /
             (SELECT SUM(est_payment) FROM pt_clean), 1) AS pct_of_total
FROM pt_clean
GROUP BY code
ORDER BY est_payment DESC;
-- ====================================================================
-- 1b. Cumulative share (how many codes make up 80% of spend)
WITH by_code AS (
    SELECT code,
           MAX(code_desc) AS code_desc,
           SUM(est_payment) AS pay
    FROM pt_clean
    GROUP BY code
)
SELECT code,
       code_desc,
       ROUND(pay) AS est_payment,
       ROUND(
           100 * SUM(pay) OVER (ORDER BY pay DESC)
           / SUM(pay) OVER (),
           1
       ) AS cumulative_pct
FROM by_code
ORDER BY pay DESC;
-- codes -97110- -97530- -97112- -97140-  make up 85.9% of spend --
-- =====================================================================
-- Q2. Office (O) vs facility (F)
-- =====================================================================
-- 2a."Which procedure codes generate the highest Medicare payments in each place of service ?
SELECT place,code_desc,
       code,
       SUM(srvcs)                       AS services,
       ROUND(SUM(est_payment))          AS est_payment,
       ROUND(SUM(est_payment) / SUM(srvcs), 2) AS avg_pymt_per_service
FROM pt_clean
GROUP BY place, code ,code_desc
ORDER BY place, est_payment DESC;
-- =======================================================
-- 2b. Only the office setting, top 5 codes
SELECT code,code_desc,place, ROUND(SUM(est_payment)) AS est_payment
FROM pt_clean
WHERE place = 'O'
GROUP BY code,code_desc,place
ORDER BY est_payment DESC
LIMIT 5;
-- =====================================================================
-- Q3. Which states receive the most payment?
-- =====================================================================
	SELECT state,
       COUNT(DISTINCT npi)                       AS providers,
       ROUND(SUM(est_payment))                   AS est_payment,
       ROUND(SUM(est_payment) / SUM(srvcs), 2)   AS avg_pymt_per_service,
       ROUND(SUM(est_payment) / COUNT(DISTINCT npi)) AS payment_per_provider
FROM pt_clean
GROUP BY state
ORDER BY est_payment DESC
LIMIT 10;
-- =====================================================================
-- Q4. Service intensity per provider (services per beneficiary)
-- =====================================================================
CREATE OR REPLACE VIEW pt_intensity AS
SELECT npi,
       state,
       code,
       code_desc,
       benes,
       srvcs,
       est_payment,
       srvcs / NULLIF(benes, 0) AS srvcs_per_bene     -- metric 2: intensity
FROM pt_clean
WHERE place = 'O'        -- keep one setting so groups are comparable
  AND benes >= 20;       -- small counts are unstable; state the reason in README
-- ==========================================================
-- 4a. Quick look: distribution of intensity for one code
SELECT code,code_desc,
       COUNT(*)                          AS providers,
       ROUND(MIN(srvcs_per_bene), 1)     AS min_val,
       ROUND(AVG(srvcs_per_bene), 1)     AS avg_val,
       ROUND(MAX(srvcs_per_bene), 1)     AS max_val
FROM pt_intensity
GROUP BY code,code_desc
ORDER BY providers DESC;
-- ========================================================
-- 4b. Top 20 providers by intensity for a single code (example: 97110)
SELECT npi as providers, state, benes, srvcs, ROUND(srvcs_per_bene, 1) AS srvcs_per_bene
FROM pt_intensity
WHERE code = '97110'
ORDER BY srvcs_per_bene DESC
LIMIT 20;
-- =====================================================================
-- Q5. Rank each provider inside its own state and code (advanced)
-- =====================================================================
DROP TABLE IF EXISTS pt_intensity_tbl;

CREATE TABLE pt_intensity_tbl AS
SELECT * FROM pt_intensity;

CREATE INDEX idx_int ON pt_intensity_tbl (state(50), code(50), srvcs_per_bene);

DROP TABLE IF EXISTS pt_ranked_tbl;

CREATE TABLE pt_ranked_tbl AS
WITH counted AS (
    SELECT i.*,
           COUNT(*) OVER (PARTITION BY state, code) AS peers
    FROM pt_intensity_tbl i
)
SELECT npi, state, code, code_desc, benes, srvcs, srvcs_per_bene, peers,
       PERCENT_RANK() OVER (PARTITION BY state, code
                            ORDER BY srvcs_per_bene) AS pct_rank,
       NTILE(10)      OVER (PARTITION BY state, code
                            ORDER BY srvcs_per_bene, npi) AS decile
FROM counted
WHERE peers >= 10;
-- ===========================================================
-- 5a. Providers in the top decile
SELECT
    npi,
    state,
    code_desc,
    code,
    ROUND(srvcs_per_bene, 1) AS srvcs_per_bene,
    ROUND(pct_rank, 2)       AS pct_rank
FROM pt_ranked_tbl
WHERE decile = 10
  AND pct_rank >= 0.90
ORDER BY
    state,
    code,
    srvcs_per_bene DESC;
-- ===========================================================
-- 5b. How many top-decile providers per state
SELECT
    state,
    COUNT(DISTINCT npi) AS providers_in_top_decile
FROM pt_ranked_tbl
WHERE decile = 10
GROUP BY state
ORDER BY providers_in_top_decile DESC
LIMIT 15;
-- =====================================================================
-- Q6. How do high-intensity providers differ? 
-- =====================================================================
-- 6a. Flag each provider ONCE: top group if they are in the top decile
WITH flag AS (
    SELECT npi,
           MAX(CASE WHEN decile = 10 THEN 1 ELSE 0 END) AS is_top
    FROM pt_ranked_tbl
    GROUP BY npi
),
mix AS (
    SELECT c.npi, c.code, SUM(c.srvcs) AS srvcs
    FROM pt_clean c
    WHERE c.place = 'O'
    GROUP BY c.npi, c.code
)
SELECT f.is_top,
       m.code,
       SUM(m.srvcs)                                              AS services,
       ROUND(100 * SUM(m.srvcs) /
             SUM(SUM(m.srvcs)) OVER (PARTITION BY f.is_top), 1)  AS pct_of_group_services
FROM mix m
JOIN flag f ON f.npi = m.npi
GROUP BY f.is_top, m.code
ORDER BY m.code, f.is_top;
-- =================================================
-- 6b. Group sizes (providers per group)
WITH flag AS (
  SELECT npi, MAX(CASE WHEN decile = 10 THEN 1 ELSE 0 END) AS is_top
  FROM pt_ranked_tbl GROUP BY npi
)
SELECT is_top, COUNT(*) AS providers FROM flag GROUP BY is_top;
-- ==================================================
-- 6c. P90 / P50 ratio for one code (MySQL has no PERCENTILE_CONT
WITH ordered AS (
    SELECT code, srvcs_per_bene,
           ROW_NUMBER() OVER (PARTITION BY code ORDER BY srvcs_per_bene) AS rn,
           COUNT(*)     OVER (PARTITION BY code)                         AS n
    FROM pt_intensity
    WHERE code IN ('97110','97530','97112','97140')
)
SELECT code,
       ROUND(MAX(CASE WHEN rn = CEIL(0.50 * n) THEN srvcs_per_bene END), 1) AS p50,
       ROUND(MAX(CASE WHEN rn = CEIL(0.90 * n) THEN srvcs_per_bene END), 1) AS p90,
       ROUND(MAX(CASE WHEN rn = CEIL(0.90 * n) THEN srvcs_per_bene END) /
             MAX(CASE WHEN rn = CEIL(0.50 * n) THEN srvcs_per_bene END), 2)  AS p90_to_p50
FROM ordered
GROUP BY code
ORDER BY code;
-- ===========================================================
-- 6d. Evaluation share per provider (evaluation codes 97161-97163)
-- vs treatment codes: a very low share can be worth a closer look.
SELECT npi,
       SUM(CASE WHEN code IN ('97161','97162','97163') THEN srvcs ELSE 0 END) AS eval_srvcs,
       SUM(srvcs)                                                              AS all_srvcs,
       ROUND(100 * SUM(CASE WHEN code IN ('97161','97162','97163') THEN srvcs ELSE 0 END)
             / SUM(srvcs), 1)                                                  AS eval_pct
FROM pt_clean
WHERE place = 'O'
GROUP BY npi
HAVING SUM(srvcs) >= 100       -- HAVING filters AFTER the grouping; WHERE filters BEFORE
ORDER BY eval_pct;


-- =====================================================================
-- Q7. Export for Excel (run each, then use Workbench's Export button)
-- =====================================================================
-- Q1 result  -> sheet "spend_by_code"
-- Q3 result  -> sheet "top_states"
-- 5a result  -> sheet "top_decile_providers"
-- 6a result  -> sheet "code_mix_top_vs_rest"
-- 6b result  -> group sizes (providers in top decile vs rest), quoted in the README
-- 6c result  -> sheet "p50_p90_intensity"
