/*
emo_addressable_eda.sql

Base logic for emo_addressable_population_eda.ipynb (Growth outreach sizing).

Parameters (Python replaces tokens):
  {report_start_date}  e.g. 2025-01-01
  {report_end_date}    e.g. 2026-01-01 (end-exclusive)
  {claims_trust_lookback_date}  e.g. 2024-01-01

Outreach list (Allison Kim): OR of COMPLEX_PATIENTS, MSK_NEURO, HIGH_COST on member_risk_assessments.history:v1 (pid -> GR_PID).
Eligibility: member-month overlap with risk month (same-month join).
Claims client flag: any claim month in lookback + report window (WITH_CLAIMS vs WITHOUT_CLAIMS only).
Member claims history: member_spend_rolling_12_months:v3 paid > 0.
*/

WITH params AS (
    SELECT
        DATE('{report_start_date}') AS report_start_date,
        DATE('{report_end_date}') AS report_end_date,
        DATE('{claims_trust_lookback_date}') AS claims_trust_lookback_date
)

, emo_clients AS (
    SELECT DISTINCT
           gmap.client_account_id,
           gmap.client_account_name,
           gmap.aggregation_id,
           gmap.aggregation_name
      FROM client_reporting.global_client_reporting_map:v1 AS gmap
     CROSS JOIN params
     WHERE gmap.has_cemo = TRUE
       AND gmap.scheme_type = 'account_level'
       AND gmap.aggregation_id LIKE 'SALES%'
       AND gmap.aggregation_name NOT LIKE '%Catch-All%'
       AND gmap.aggregation_name NOT LIKE '%Non-Affiliation%'
)

, client_claims_profile AS (
    SELECT
        ec.client_account_id,
        MAX(ec.client_account_name) AS client_account_name,
        MAX(ec.aggregation_id) AS aggregation_id,
        MAX(ec.aggregation_name) AS aggregation_name,
        COALESCE(
            BOOL_OR(
                claims.client_account_id IS NOT NULL
                AND claims.service_month IS NOT NULL
            ),
            FALSE
        ) AS is_claims_present,
        CASE
            WHEN COALESCE(
                BOOL_OR(
                    claims.client_account_id IS NOT NULL
                    AND claims.service_month IS NOT NULL
                ),
                FALSE
            ) THEN 'WITH_CLAIMS'
            ELSE 'WITHOUT_CLAIMS'
        END AS client_workstream
    FROM emo_clients AS ec
    CROSS JOIN params AS p
    LEFT JOIN customer_analytics.trusted_data.all_claim_eligibility_sets:v1 AS claims
        ON ec.client_account_id = claims.client_account_id
       AND DATE(claims.service_month) >= p.claims_trust_lookback_date
       AND DATE(claims.service_month) < p.report_end_date
    GROUP BY ec.client_account_id
)

, emo_ra_members AS (
    SELECT DISTINCT
           xwalk.entity_id,
           DATE_TRUNC('month', ra.rundate) AS member_month,
           ra.riskassessment
      FROM data_science.recommendations.member_risk_assessments.history:v1 AS ra
      JOIN data_factory.entity_id_crosswalk:v1 AS xwalk
        ON ra.pid = xwalk.identifier_value
       AND xwalk.identifier_type = 'GR_PID'
     CROSS JOIN params AS p
     WHERE ra.riskassessment IN (
               'COMPLEX_PATIENTS',  /* EMO marketing outreach list */
               'MSK_NEURO',
               'HIGH_COST'
           )
       AND ra.rundate >= p.report_start_date
       AND ra.rundate < p.report_end_date
)

, elig AS (
    SELECT DISTINCT
           mm.client_account_id,
           mm.client_account_name,
           mm.member_month,
           xwalk.entity_id
      FROM client_reporting.member_months_exploded:v1 AS mm
      JOIN data_factory.entity_id_crosswalk:v1 AS xwalk
        ON mm.member_entity_id = xwalk.identifier_value
       AND xwalk.identifier_type = 'ENTITY_ID'
      JOIN emo_clients AS ec
        ON mm.client_account_id = ec.client_account_id
     CROSS JOIN params AS p
     WHERE mm.member_month >= p.report_start_date
       AND mm.member_month < p.report_end_date
)

, emo_members_by_client AS (
    SELECT DISTINCT
           e.client_account_id,
           e.client_account_name,
           e.entity_id,
           r.riskassessment
      FROM elig AS e
      JOIN emo_ra_members AS r
        ON e.entity_id = r.entity_id
       AND e.member_month = r.member_month
)

, elig_population_by_client AS (
    SELECT
        client_account_id,
        MAX(client_account_name) AS client_account_name,
        COUNT(DISTINCT entity_id) AS n_eligible_member_months_distinct
    FROM elig
    GROUP BY 1
)

, outreach_member_list AS (
    SELECT
        em.client_account_id,
        em.client_account_name,
        em.entity_id,
        em.riskassessment AS outreach_riskassessment
    FROM emo_members_by_client AS em
)

, risk_outreach_by_client AS (
    SELECT
        em.client_account_id,
        MAX(em.client_account_name) AS client_account_name,
        COUNT(DISTINCT em.entity_id) AS n_outreach_members,
        COUNT(DISTINCT CASE WHEN em.riskassessment = 'COMPLEX_PATIENTS' THEN em.entity_id END)
            AS n_complex_patients,
        COUNT(DISTINCT CASE WHEN em.riskassessment = 'MSK_NEURO' THEN em.entity_id END)
            AS n_msk_neuro,
        COUNT(DISTINCT CASE WHEN em.riskassessment = 'HIGH_COST' THEN em.entity_id END)
            AS n_high_cost
    FROM emo_members_by_client AS em
    GROUP BY 1
)

, members_with_claims_history AS (
    SELECT DISTINCT
           e.client_account_id,
           e.entity_id
      FROM elig AS e
      JOIN client_claims_profile AS ccp
        ON e.client_account_id = ccp.client_account_id
       AND ccp.is_claims_present = TRUE
      JOIN customer_analytics.member_spend_rolling_12_months:v3 AS spend
        ON spend.entity_id = e.entity_id
     CROSS JOIN params AS p
     WHERE DATE(spend.member_month) >= p.report_start_date
       AND DATE(spend.member_month) < p.report_end_date
       AND COALESCE(spend.current_month_total_net_paid, 0) > 0
)

, addressable_with_claims_by_client AS (
    SELECT
        em.client_account_id,
        COUNT(DISTINCT em.entity_id) AS n_addressable_risk_and_claims_history
    FROM emo_members_by_client AS em
    INNER JOIN members_with_claims_history AS mch
        ON em.client_account_id = mch.client_account_id
       AND em.entity_id = mch.entity_id
    GROUP BY 1
)

, client_eda AS (
    SELECT
        ccp.client_account_id,
        ccp.client_account_name,
        ccp.aggregation_id,
        ccp.aggregation_name,
        ccp.is_claims_present,
        ccp.client_workstream,
        COALESCE(ep.n_eligible_member_months_distinct, 0) AS n_eligible_distinct_members,
        COALESCE(ro.n_outreach_members, 0) AS n_outreach_members,
        COALESCE(ro.n_complex_patients, 0) AS n_complex_patients,
        COALESCE(ro.n_msk_neuro, 0) AS n_msk_neuro,
        COALESCE(ro.n_high_cost, 0) AS n_high_cost,
        COALESCE(aw.n_addressable_risk_and_claims_history, 0)
            AS n_addressable_risk_and_claims_history,
        ROUND(
            COALESCE(ro.n_outreach_members, 0) * 1.0
            / NULLIF(COALESCE(ep.n_eligible_member_months_distinct, 0), 0),
            4
        ) AS pct_eligible_on_outreach_list,
        ROUND(
            COALESCE(aw.n_addressable_risk_and_claims_history, 0) * 1.0
            / NULLIF(COALESCE(ep.n_eligible_member_months_distinct, 0), 0),
            4
        ) AS pct_addressable_risk_and_claims
    FROM client_claims_profile AS ccp
    LEFT JOIN elig_population_by_client AS ep
        ON ccp.client_account_id = ep.client_account_id
    LEFT JOIN risk_outreach_by_client AS ro
        ON ccp.client_account_id = ro.client_account_id
    LEFT JOIN addressable_with_claims_by_client AS aw
        ON ccp.client_account_id = aw.client_account_id
)

SELECT *
  FROM {final_cte}
-- final_cte: client_eda | outreach_member_list | client_claims_profile | emo_members_by_client
;
