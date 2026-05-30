CREATE OR REPLACE SECURE VIEW WEA_SANDBOX.GUILLERMO_N.VW_YOUTUBE_CID_RISK_SCAN AS
WITH latest_core_assets AS (
    -- Step 1: Isolate and capture ONLY the single newest record for each unique ISRC
    SELECT *
    FROM (
        SELECT 
            *,
            ROW_NUMBER() OVER (PARTITION BY ISRC ORDER BY CREATED_ON DESC) AS asset_version_rank
        FROM CORP_GCDMI_PROD.REPORTING.RPT_ASSET
        WHERE IS_ACTIVE = 'Y' 
          AND IS_DELETED = 'N'
          AND IS_CORE = 'Y'
    )
    WHERE asset_version_rank = 1
),
latest_rights_mapping AS (
    -- Step 2: Isolate and capture ONLY the single latest active UGV MASTER right row per asset
    SELECT *
    FROM (
        SELECT 
            rpc.asset_id,
            r.PERMISSION_TYPE,
            r.RIGHT_TYPE,
            r.TERRITORY,
            r.GRANT_DESC,
            r.EFFECTIVE_FROM_DATE AS UGV_EFFECTIVE_FROM_DATE,
            r.EFFECTIVE_TO_DATE AS UGV_EFFECTIVE_TO_DATE,
            ROW_NUMBER() OVER (PARTITION BY rpc.asset_id ORDER BY r.EFFECTIVE_FROM_DATE DESC, r.id DESC) AS rights_version_rank
        FROM CORP_GCDMI_PROD.REPORTING.RPT_PRODUCT_COMPONENT rpc 
        INNER JOIN CORP_GCDMI_PROD.REPORTING.RPT_PRODUCT_COMPANY_REL rp 
            ON rpc.parent_product_id = rp.product_id
        INNER JOIN CORP_GCDMI_PROD.REPORTING.RPT_PRODUCT_COMPONENT_RIGHT r 
            ON rpc.id = r.product_component_id
        WHERE rp.is_deleted = 'N' 
          AND rp.is_in_effect = 'Y'
          AND r.is_deleted = 'N' 
          AND r.PERMISSION_TYPE_ID = 5       -- User Generated Video
          AND r.RIGHT_TYPE = 'Master'        -- Enforces strict Master rights constraint
          AND r.EFFECTIVE_FROM_DATE IS NOT NULL -- Rule 1: From date must always have a value
          AND r.EFFECTIVE_TO_DATE IS NULL     -- Rule 2: To date must be null (active/open-ended)
    )
    WHERE rights_version_rank = 1
),
keyword_matches AS (
    -- Step 3: Flatten keyword evaluation into a standard relational join to fix the compiler error
    SELECT 
        a.id AS asset_id,
        MAX(CASE WHEN k.RISK_CATEGORY = 'Ambient / Noise' THEN 1 ELSE 0 END) AS kw_ambient_risk,
        MAX(CASE WHEN k.RISK_CATEGORY = 'Video Game / Soundtrack' THEN 1 ELSE 0 END) AS kw_gaming_risk,
        MAX(CASE WHEN k.RISK_CATEGORY = 'Non-Exclusive Elements' THEN 1 ELSE 0 END) AS kw_loop_risk,
        MAX(CASE WHEN k.RISK_CATEGORY = 'Compilations / Mixes' THEN 1 ELSE 0 END) AS kw_comp_risk
    FROM latest_core_assets a
    LEFT JOIN WEA_SANDBOX.GUILLERMO_N.BLOCKED_KEYWORDS k
      ON (k.MATCH_TYPE = 'SUBSTRING' AND (REGEXP_LIKE(a.TITLE, '.*' || k.KEYWORD || '.*', 'i') OR REGEXP_LIKE(a.DISPLAY_TITLE, '.*' || k.KEYWORD || '.*', 'i') OR REGEXP_LIKE(a.ARTIST_DISPLAY_TITLE, '.*' || k.KEYWORD || '.*', 'i')))
      OR (k.MATCH_TYPE = 'WORD_BOUNDARY' AND (REGEXP_LIKE(a.TITLE, '.*\\b' || k.KEYWORD || '\\b.*', 'i') OR REGEXP_LIKE(a.DISPLAY_TITLE, '.*\\b' || k.KEYWORD || '\\b.*', 'i') OR REGEXP_LIKE(a.ARTIST_DISPLAY_TITLE, '.*\\b' || k.KEYWORD || '\\b.*', 'i')))
    GROUP BY a.id
),
flagged_assets AS (
    -- Step 4: Map evaluated risk layers together cleanly
    SELECT 
        -- Basic Metadata Columns
        a.ISRC,
        a.ARTIST_DISPLAY_TITLE,
        a.TITLE,
        a.DISPLAY_TITLE,
        a.SUB_TYPE,
        a.PMO_TITLE,
        a.WW_REPERTOIRE_OWNER,
        
        -- Scanned Metadata Columns
        a.MAJOR_GENRE,
        a.MINOR_GENRE,
        a.PLAY_LENGTH,
        a.CREATED_ON,
        
        -- Deduplicated Projected UGV Rights Columns
        r.PERMISSION_TYPE,
        r.RIGHT_TYPE,
        r.TERRITORY,
        r.GRANT_DESC,
        r.UGV_EFFECTIVE_FROM_DATE,
        r.UGV_EFFECTIVE_TO_DATE,
        
        -- 1. Ambient, White Noise, Nature, Meditation, Sleep, and ASMR Check
        CASE 
            WHEN REGEXP_LIKE(a.MAJOR_GENRE, '.*(ambient|new age|meditation|nature|relaxation).*', 'i')
              OR REGEXP_LIKE(a.MINOR_GENRE, '.*(ambient|new age|meditation|nature|relaxation).*', 'i')
              OR NVL(km.kw_ambient_risk, 0) = 1
            THEN 1 ELSE 0 
        END AS is_ambient_risk,
        
        -- 2. Video Game, Soundtracks (OST), and Gameplay Elements Check
        CASE 
            WHEN REGEXP_LIKE(a.MAJOR_GENRE, '.*(soundtrack|video game|gaming).*', 'i')
              OR REGEXP_LIKE(a.MINOR_GENRE, '.*(soundtrack|video game|gaming).*', 'i')
              OR NVL(km.kw_gaming_risk, 0) = 1
            THEN 1 ELSE 0 
        END AS is_gaming_risk,
        
        -- 3. Non-Exclusive Loops, Sample Packs, and Type Beats Check
        CASE 
            WHEN NVL(km.kw_loop_risk, 0) = 1 THEN 1 ELSE 0 
        END AS is_loop_risk,

        -- 4. Compilations, Continuous Mixes, or Duration Limit Check (> 10 mins)
        CASE 
            WHEN (a.PLAY_LENGTH IS NOT NULL AND a.PLAY_LENGTH >= '000:10:00')
              OR NVL(km.kw_comp_risk, 0) = 1
            THEN 1 ELSE 0 
        END AS is_compilation_or_duration_risk
    FROM latest_core_assets a
    INNER JOIN latest_rights_mapping r 
        ON a.id = r.asset_id
    LEFT JOIN keyword_matches km
        ON a.id = km.asset_id
)
SELECT 
    ISRC,
    ARTIST_DISPLAY_TITLE,
    TITLE,
    DISPLAY_TITLE,
    SUB_TYPE,
    PMO_TITLE,
    WW_REPERTOIRE_OWNER,
    MAJOR_GENRE,
    MINOR_GENRE,
    PLAY_LENGTH,
    CREATED_ON,
    PERMISSION_TYPE,
    RIGHT_TYPE,
    TERRITORY,
    GRANT_DESC,
    UGV_EFFECTIVE_FROM_DATE,
    UGV_EFFECTIVE_TO_DATE,
    (is_ambient_risk + is_gaming_risk + is_loop_risk + is_compilation_or_duration_risk) AS risk_indicators,
    CASE 
        WHEN (is_ambient_risk + is_gaming_risk + is_loop_risk + is_compilation_or_duration_risk) >= 2 
             OR PLAY_LENGTH >= '000:10:00' THEN 'HIGH RISK - BLOCK CONTENT ID'
        WHEN (is_ambient_risk + is_gaming_risk + is_loop_risk + is_compilation_or_duration_risk) = 1 THEN 'NEEDS MANUAL REVIEW'
        ELSE 'CLEAN'
    END AS youtube_cid_status
FROM flagged_assets
WHERE youtube_cid_status != 'CLEAN'
ORDER BY PMO_TITLE, ISRC;