-- PolicyLens Section 04.6: parse the two remaining staged PDFs.
-- Run in a Snowsight SQL worksheet before 04_6_chunk_remaining.sql.
-- The existing Product Warranty parse is not touched. A rerun skips documents
-- already stored in PARSED_DOCUMENTS. Review the validation results below.

USE WAREHOUSE POLICYLENS_WH;
USE DATABASE POLICYLENS_DB;
USE SCHEMA APP;

-- Check that both approved PDFs are available in the existing stage.
SELECT RELATIVE_PATH, SIZE, LAST_MODIFIED
FROM DIRECTORY(@DOCUMENT_STAGE)
WHERE RELATIVE_PATH IN (
    'Service_Procedures.pdf',
    'Extended_Warranty_Terms.pdf'
)
ORDER BY RELATIVE_PATH;

-- Parse only missing documents. This session-temporary table lets us inspect
-- the AI output before any row is added to the permanent parsed-document table.
-- LAYOUT and page_split match the Product Warranty parsing configuration.
CREATE OR REPLACE TEMP TABLE PL_046_PARSE_CANDIDATES AS
SELECT
    'Service_Procedures.pdf' AS DOCUMENT_NAME,
    PARSE_JSON(AI_PARSE_DOCUMENT(
        TO_FILE('@DOCUMENT_STAGE', 'Service_Procedures.pdf'),
        {'mode': 'LAYOUT', 'page_split': TRUE}
    )) AS PARSED_CONTENT
WHERE EXISTS (
    SELECT 1 FROM DIRECTORY(@DOCUMENT_STAGE)
    WHERE RELATIVE_PATH = 'Service_Procedures.pdf'
)
AND NOT EXISTS (
    SELECT 1 FROM PARSED_DOCUMENTS
    WHERE DOCUMENT_NAME = 'Service_Procedures.pdf'
)
UNION ALL
SELECT
    'Extended_Warranty_Terms.pdf' AS DOCUMENT_NAME,
    PARSE_JSON(AI_PARSE_DOCUMENT(
        TO_FILE('@DOCUMENT_STAGE', 'Extended_Warranty_Terms.pdf'),
        {'mode': 'LAYOUT', 'page_split': TRUE}
    )) AS PARSED_CONTENT
WHERE EXISTS (
    SELECT 1 FROM DIRECTORY(@DOCUMENT_STAGE)
    WHERE RELATIVE_PATH = 'Extended_Warranty_Terms.pdf'
)
AND NOT EXISTS (
    SELECT 1 FROM PARSED_DOCUMENTS
    WHERE DOCUMENT_NAME = 'Extended_Warranty_Terms.pdf'
);

-- Stop here and inspect the candidate output before executing the INSERT.
-- Both approved PDFs should show pages 0 and 1 with nonblank policy text.
-- Zero candidates is normal on an unchanged rerun.
SELECT
    c.DOCUMENT_NAME,
    ARRAY_SIZE(c.PARSED_CONTENT:pages) AS PAGE_COUNT,
    p.value:index::INTEGER AS PAGE_INDEX,
    LENGTH(p.value:content::STRING) AS TEXT_CHARACTERS,
    LEFT(p.value:content::STRING, 200) AS PAGE_START,
    RIGHT(p.value:content::STRING, 200) AS PAGE_END
FROM PL_046_PARSE_CANDIDATES AS c,
     LATERAL FLATTEN(INPUT => c.PARSED_CONTENT:pages) AS p
ORDER BY c.DOCUMENT_NAME, PAGE_INDEX;

-- Store a candidate only when its two parsed pages have the expected indexes
-- and nonblank text. Existing rows are retained; no document is reparsed on
-- an unchanged rerun.
INSERT INTO PARSED_DOCUMENTS (DOCUMENT_NAME, PARSED_CONTENT, PARSED_AT)
SELECT c.DOCUMENT_NAME, c.PARSED_CONTENT, CURRENT_TIMESTAMP()
FROM PL_046_PARSE_CANDIDATES AS c,
     LATERAL FLATTEN(INPUT => c.PARSED_CONTENT:pages) AS p
WHERE ARRAY_SIZE(c.PARSED_CONTENT:pages) = 2
GROUP BY c.DOCUMENT_NAME, c.PARSED_CONTENT
HAVING COUNT(*) = 2
   AND COUNT(NULLIF(TRIM(p.value:content::STRING), '')) = 2
   AND COUNT(DISTINCT p.value:index::INTEGER) = 2
   AND MIN(p.value:index::INTEGER) = 0
   AND MAX(p.value:index::INTEGER) = 1;

-- Both documents should now have exactly one stored parse with two nonblank
-- pages. The page excerpts help identify any PDF headers or footers for later
-- evaluation; this script does not clean or remove parsed text.
WITH pages AS (
    SELECT
        d.DOCUMENT_NAME,
        COUNT(*) AS PAGE_COUNT,
        COUNT(NULLIF(TRIM(p.value:content::STRING), '')) AS NONBLANK_PAGES,
        COUNT(DISTINCT p.value:index::INTEGER) AS DISTINCT_PAGE_INDEXES,
        MIN(p.value:index::INTEGER) AS FIRST_PAGE_INDEX,
        MAX(p.value:index::INTEGER) AS LAST_PAGE_INDEX
    FROM PARSED_DOCUMENTS AS d,
         LATERAL FLATTEN(INPUT => d.PARSED_CONTENT:pages) AS p
    WHERE d.DOCUMENT_NAME IN (
        'Service_Procedures.pdf', 'Extended_Warranty_Terms.pdf'
    )
    GROUP BY d.DOCUMENT_NAME
),
stored AS (
    SELECT DOCUMENT_NAME, COUNT(*) AS STORED_ROWS
    FROM PARSED_DOCUMENTS
    WHERE DOCUMENT_NAME IN (
        'Service_Procedures.pdf', 'Extended_Warranty_Terms.pdf'
    )
    GROUP BY DOCUMENT_NAME
)
SELECT
    expected.DOCUMENT_NAME,
    COALESCE(s.STORED_ROWS, 0) AS STORED_ROWS,
    COALESCE(p.PAGE_COUNT, 0) AS PAGE_COUNT,
    COALESCE(p.NONBLANK_PAGES, 0) AS NONBLANK_PAGES,
    IFF(s.STORED_ROWS = 1 AND p.PAGE_COUNT = 2
        AND p.NONBLANK_PAGES = 2 AND p.DISTINCT_PAGE_INDEXES = 2
        AND p.FIRST_PAGE_INDEX = 0 AND p.LAST_PAGE_INDEX = 1,
        'PASS', 'REVIEW') AS PARSE_STATUS
FROM (
    SELECT COLUMN1 AS DOCUMENT_NAME FROM VALUES
        ('Service_Procedures.pdf'),
        ('Extended_Warranty_Terms.pdf')
) AS expected
LEFT JOIN stored AS s ON s.DOCUMENT_NAME = expected.DOCUMENT_NAME
LEFT JOIN pages AS p ON p.DOCUMENT_NAME = expected.DOCUMENT_NAME
ORDER BY expected.DOCUMENT_NAME;

-- Confirm that the expected document ID and core policy sections survived
-- extraction. Review the full page excerpts above if either row says REVIEW.
WITH full_documents AS (
    SELECT
        d.DOCUMENT_NAME,
        LISTAGG(p.value:content::STRING, '\n\n')
            WITHIN GROUP (ORDER BY p.value:index::INTEGER) AS FULL_TEXT
    FROM PARSED_DOCUMENTS AS d,
         LATERAL FLATTEN(INPUT => d.PARSED_CONTENT:pages) AS p
    WHERE d.DOCUMENT_NAME IN (
        'Service_Procedures.pdf', 'Extended_Warranty_Terms.pdf'
    )
    GROUP BY d.DOCUMENT_NAME
)
SELECT
    DOCUMENT_NAME,
    CONTAINS(FULL_TEXT, IFF(DOCUMENT_NAME = 'Service_Procedures.pdf',
        'AST-SVC-001', 'AST-EW-001')) AS HAS_DOCUMENT_ID,
    CONTAINS(FULL_TEXT, IFF(DOCUMENT_NAME = 'Service_Procedures.pdf',
        '5. Warranty repair authorization',
        '3. Purchase and registration timing')) AS HAS_KEY_SECTION,
    CONTAINS(FULL_TEXT, IFF(DOCUMENT_NAME = 'Service_Procedures.pdf',
        '8. Related documents', '7. Summary of the coverage sequence'))
        AS HAS_FINAL_SECTION,
    IFF(HAS_DOCUMENT_ID AND HAS_KEY_SECTION AND HAS_FINAL_SECTION,
        'PASS', 'REVIEW') AS CONTENT_STATUS
FROM full_documents
ORDER BY DOCUMENT_NAME;
