-- PolicyLens Section 04.6: chunk the stored Service and Extended Warranty PDFs.
-- Run after 04_6_parse_remaining.sql reports PASS for both documents.
-- Product Warranty chunks and all PARSED_DOCUMENTS rows remain unchanged.

USE WAREHOUSE POLICYLENS_WH;
USE DATABASE POLICYLENS_DB;
USE SCHEMA APP;

-- Use only one stored parse per named document. Skip a document if it already
-- has any chunks, so an unchanged rerun cannot create duplicate rows. If a
-- document has only a partial set, review it instead of appending blindly.
INSERT INTO DOCUMENT_CHUNKS (
    CHUNK_ID, DOCUMENT_NAME, CHUNK_NUMBER, HEADER_1, HEADER_2, HEADER_3,
    CHUNK_BODY, SEARCHABLE_TEXT
)
WITH source_documents AS (
    SELECT d.DOCUMENT_NAME, d.PARSED_CONTENT
    FROM PARSED_DOCUMENTS AS d
    WHERE d.DOCUMENT_NAME IN (
        'Service_Procedures.pdf', 'Extended_Warranty_Terms.pdf'
    )
    AND NOT EXISTS (
        SELECT 1 FROM DOCUMENT_CHUNKS AS existing
        WHERE existing.DOCUMENT_NAME = d.DOCUMENT_NAME
    )
    QUALIFY COUNT(*) OVER (PARTITION BY d.DOCUMENT_NAME) = 1
),
full_documents AS (
    SELECT
        d.DOCUMENT_NAME,
        LISTAGG(p.value:content::STRING, '\n\n')
            WITHIN GROUP (ORDER BY p.value:index::INTEGER) AS FULL_TEXT
    FROM source_documents AS d,
         LATERAL FLATTEN(INPUT => d.PARSED_CONTENT:pages) AS p
    GROUP BY d.DOCUMENT_NAME
    HAVING COUNT(*) = 2
       AND COUNT(NULLIF(TRIM(p.value:content::STRING), '')) = 2
       AND COUNT(DISTINCT p.value:index::INTEGER) = 2
       AND MIN(p.value:index::INTEGER) = 0
       AND MAX(p.value:index::INTEGER) = 1
),
split_chunks AS (
    SELECT
        d.DOCUMENT_NAME,
        d.FULL_TEXT,
        c.index + 1 AS CHUNK_NUMBER,
        c.value:headers:header_1::VARCHAR AS HEADER_1,
        c.value:headers:header_2::VARCHAR AS HEADER_2,
        c.value:headers:header_3::VARCHAR AS HEADER_3,
        c.value:chunk::VARCHAR AS CHUNK_BODY
    FROM full_documents AS d,
         LATERAL FLATTEN(
             INPUT => SNOWFLAKE.CORTEX.SPLIT_TEXT_MARKDOWN_HEADER(
                 d.FULL_TEXT,
                 OBJECT_CONSTRUCT(
                     '#', 'header_1',
                     '##', 'header_2',
                     '###', 'header_3'
                 ),
                 1000,
                 100
             )
         ) AS c
)
SELECT
    SHA2(
        DOCUMENT_NAME || '|' || SHA2(FULL_TEXT, 256) || '|' ||
        CHUNK_NUMBER::VARCHAR || '|' || CHUNK_BODY,
        256
    ) AS CHUNK_ID,
    DOCUMENT_NAME,
    CHUNK_NUMBER,
    HEADER_1,
    HEADER_2,
    HEADER_3,
    CHUNK_BODY,
    COALESCE(HEADER_1 || CHR(10), '') ||
    COALESCE(HEADER_2 || CHR(10), '') ||
    COALESCE(HEADER_3 || CHR(10), '') ||
    CHUNK_BODY AS SEARCHABLE_TEXT
FROM split_chunks;

-- Each document should have contiguous chunk numbers, unique IDs, and
-- nonblank bodies. Counts are observed results, not predetermined targets.
WITH actual AS (
    SELECT
        DOCUMENT_NAME,
        COUNT(*) AS CHUNK_COUNT,
        COUNT(DISTINCT CHUNK_ID) AS DISTINCT_CHUNK_IDS,
        COUNT(DISTINCT CHUNK_NUMBER) AS DISTINCT_CHUNK_NUMBERS,
        MIN(CHUNK_NUMBER) AS FIRST_CHUNK_NUMBER,
        MAX(CHUNK_NUMBER) AS LAST_CHUNK_NUMBER,
        COALESCE(COUNT_IF(
            CHUNK_BODY IS NULL OR TRIM(CHUNK_BODY) = ''
            OR SEARCHABLE_TEXT IS NULL OR TRIM(SEARCHABLE_TEXT) = ''
        ), 0) AS BLANK_CHUNKS
    FROM DOCUMENT_CHUNKS
    WHERE DOCUMENT_NAME IN (
        'Service_Procedures.pdf', 'Extended_Warranty_Terms.pdf'
    )
    GROUP BY DOCUMENT_NAME
)
SELECT
    expected.DOCUMENT_NAME,
    COALESCE(a.CHUNK_COUNT, 0) AS CHUNK_COUNT,
    COALESCE(a.DISTINCT_CHUNK_IDS, 0) AS DISTINCT_CHUNK_IDS,
    COALESCE(a.DISTINCT_CHUNK_NUMBERS, 0) AS DISTINCT_CHUNK_NUMBERS,
    COALESCE(a.BLANK_CHUNKS, 0) AS BLANK_CHUNKS,
    IFF(a.CHUNK_COUNT > 0
        AND a.CHUNK_COUNT = a.DISTINCT_CHUNK_IDS
        AND a.CHUNK_COUNT = a.DISTINCT_CHUNK_NUMBERS
        AND a.FIRST_CHUNK_NUMBER = 1
        AND a.LAST_CHUNK_NUMBER = a.CHUNK_COUNT
        AND a.BLANK_CHUNKS = 0,
        'PASS', 'REVIEW') AS CHUNK_STATUS
FROM (
    SELECT COLUMN1 AS DOCUMENT_NAME FROM VALUES
        ('Service_Procedures.pdf'),
        ('Extended_Warranty_Terms.pdf')
) AS expected
LEFT JOIN actual AS a ON a.DOCUMENT_NAME = expected.DOCUMENT_NAME
ORDER BY expected.DOCUMENT_NAME;

-- Inspect every section and its heading metadata before proceeding.
SELECT DOCUMENT_NAME, CHUNK_NUMBER, HEADER_1, HEADER_2, HEADER_3,
       LENGTH(CHUNK_BODY) AS BODY_CHARACTERS,
       LEFT(CHUNK_BODY, 250) AS BODY_PREVIEW
FROM DOCUMENT_CHUNKS
WHERE DOCUMENT_NAME IN (
    'Service_Procedures.pdf', 'Extended_Warranty_Terms.pdf'
)
ORDER BY DOCUMENT_NAME, CHUNK_NUMBER;

-- Confirm each source ID and core policy rule appears in searchable chunks.
-- The next query exposes the matching passages for a manual wording review.
SELECT
    DOCUMENT_NAME,
    COALESCE(COUNT_IF(SEARCHABLE_TEXT ILIKE IFF(
        DOCUMENT_NAME = 'Service_Procedures.pdf',
        '%AST-SVC-001%', '%AST-EW-001%')), 0) AS DOCUMENT_ID_CHUNKS,
    COALESCE(COUNT_IF(SEARCHABLE_TEXT ILIKE IFF(
        DOCUMENT_NAME = 'Service_Procedures.pdf',
        '%authorization%', '%12 months%')), 0) AS CORE_RULE_CHUNKS,
    IFF(DOCUMENT_ID_CHUNKS > 0 AND CORE_RULE_CHUNKS > 0,
        'PASS', 'REVIEW') AS POLICY_CHECK
FROM DOCUMENT_CHUNKS
WHERE DOCUMENT_NAME IN (
    'Service_Procedures.pdf', 'Extended_Warranty_Terms.pdf'
)
GROUP BY DOCUMENT_NAME
ORDER BY DOCUMENT_NAME;

-- Searchable text must include the available headings in their original order.
-- This query should return zero rows.
SELECT DOCUMENT_NAME, CHUNK_NUMBER, CHUNK_ID
FROM DOCUMENT_CHUNKS
WHERE DOCUMENT_NAME IN (
    'Service_Procedures.pdf', 'Extended_Warranty_Terms.pdf'
)
AND SEARCHABLE_TEXT <> (
    COALESCE(HEADER_1 || CHR(10), '') ||
    COALESCE(HEADER_2 || CHR(10), '') ||
    COALESCE(HEADER_3 || CHR(10), '') ||
    CHUNK_BODY
)
ORDER BY DOCUMENT_NAME, CHUNK_NUMBER;

-- Review key policy terms and source IDs in the newly created chunks.
SELECT DOCUMENT_NAME, CHUNK_NUMBER, HEADER_1, HEADER_2, CHUNK_BODY
FROM DOCUMENT_CHUNKS
WHERE (DOCUMENT_NAME = 'Service_Procedures.pdf'
       AND (SEARCHABLE_TEXT ILIKE '%service request%'
            OR SEARCHABLE_TEXT ILIKE '%authorization%'
            OR SEARCHABLE_TEXT ILIKE '%AST-SVC-001%'))
   OR (DOCUMENT_NAME = 'Extended_Warranty_Terms.pdf'
       AND (SEARCHABLE_TEXT ILIKE '%12 months%'
            OR SEARCHABLE_TEXT ILIKE '%before the standard warranty expires%'
            OR SEARCHABLE_TEXT ILIKE '%AST-EW-001%'))
ORDER BY DOCUMENT_NAME, CHUNK_NUMBER;

-- Report possible PDF page headers and footers for later evaluation.
-- A document ID can also be a legitimate reference; nothing is removed here.
SELECT DOCUMENT_NAME, CHUNK_NUMBER, HEADER_1, HEADER_2, CHUNK_BODY
FROM DOCUMENT_CHUNKS
WHERE DOCUMENT_NAME IN (
    'Service_Procedures.pdf', 'Extended_Warranty_Terms.pdf'
)
AND (SEARCHABLE_TEXT ILIKE '% Page 2%'
     OR SEARCHABLE_TEXT ILIKE '%AST-SVC-001%'
     OR SEARCHABLE_TEXT ILIKE '%AST-EW-001%')
ORDER BY DOCUMENT_NAME, CHUNK_NUMBER;
