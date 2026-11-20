-- PolicyLens Section 05.4: run only after reviewing 05_check_search_readiness.sql.
-- Creation builds the initial index and starts billable Cortex Search usage.
-- Plain CREATE fails if this service already exists; it will not replace it.
CREATE CORTEX SEARCH SERVICE POLICYLENS_DB.APP.POLICYLENS_SEARCH
    ON SEARCHABLE_TEXT
    PRIMARY KEY (CHUNK_ID)             -- Stable unique text ID; supports efficient refresh.
    ATTRIBUTES DOCUMENT_NAME, HEADER_1 -- Filterable document and top-level section.
    WAREHOUSE = POLICYLENS_WH          -- Runs the source query and index refreshes.
    TARGET_LAG = '12 hours'            -- Desired maximum source-to-index delay.
    AUTO_SUSPEND = 1800                -- Suspend serving after 30 idle minutes.
    -- EMBEDDING_MODEL omitted: use Snowflake's default supported model.
AS
SELECT
    CHUNK_ID,
    DOCUMENT_NAME,
    CHUNK_NUMBER,
    HEADER_1,
    HEADER_2,
    HEADER_3,
    SEARCHABLE_TEXT
FROM POLICYLENS_DB.APP.DOCUMENT_CHUNKS;
