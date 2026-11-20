-- PolicyLens Section 05.4: read-only checks before creating Cortex Search.
USE DATABASE POLICYLENS_DB;
USE SCHEMA APP;
USE WAREHOUSE POLICYLENS_WH;

-- Expect 11 Product Warranty, 12 Service Procedures, and 9 Extended Warranty rows.
-- The evaluation/ground_truth.csv answers must not enter this source table.
SELECT DOCUMENT_NAME, COUNT(*) AS CHUNK_COUNT
FROM DOCUMENT_CHUNKS
GROUP BY DOCUMENT_NAME
ORDER BY DOCUMENT_NAME;

-- Expect 32 rows, 32 distinct non-null IDs, and zero blank search texts.
SELECT
    COUNT(*) AS TOTAL_CHUNKS,
    COUNT(DISTINCT CHUNK_ID) AS DISTINCT_CHUNK_IDS,
    COALESCE(COUNT_IF(CHUNK_ID IS NULL), 0) AS NULL_CHUNK_IDS,
    COALESCE(COUNT_IF(SEARCHABLE_TEXT IS NULL OR TRIM(SEARCHABLE_TEXT) = ''), 0)
        AS BLANK_SEARCHABLE_TEXTS
FROM DOCUMENT_CHUNKS;

-- Expect no rows. A duplicate CHUNK_ID could cause rows to be omitted if it
-- is used as the service primary key.
SELECT CHUNK_ID, COUNT(*) AS ROW_COUNT
FROM DOCUMENT_CHUNKS
GROUP BY CHUNK_ID
HAVING COUNT(*) > 1;

-- Expect no rows. This view lists only services visible to the current role.
-- If the name already exists, inspect its definition; do not create over it.
SELECT SERVICE_NAME, SERVICE_SCHEMA, DEFINITION
FROM POLICYLENS_DB.INFORMATION_SCHEMA.CORTEX_SEARCH_SERVICES
WHERE SERVICE_SCHEMA = 'APP'
  AND SERVICE_NAME = 'POLICYLENS_SEARCH';

-- Inspect retention_time (days) and change_tracking for DOCUMENT_CHUNKS.
-- Retention must be nonzero and longer than the 12-hour target lag.
-- If change tracking is OFF, Snowflake may attempt to enable it at creation;
-- confirm the creator role is allowed to do that before running the next file.
SHOW TABLES LIKE 'DOCUMENT_CHUNKS' IN SCHEMA POLICYLENS_DB.APP;

-- Privilege review for the creator role (no grants are made here):
-- USAGE on POLICYLENS_DB and APP; CREATE CORTEX SEARCH SERVICE on APP;
-- SELECT on DOCUMENT_CHUNKS; USAGE on POLICYLENS_WH; and either
-- SNOWFLAKE.CORTEX_USER or SNOWFLAKE.CORTEX_EMBED_USER database role.
-- Ask a grant administrator to confirm any privilege this role cannot inspect.
SELECT CURRENT_ROLE() AS CREATOR_ROLE;
