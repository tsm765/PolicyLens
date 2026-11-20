-- PolicyLens Section 04.5: persist Product Warranty chunks from stored parsed text.
-- Run in a Snowsight SQL worksheet. This script does not parse a PDF again.
-- Source: the existing Product_Warranty_Policy.pdf row in PARSED_DOCUMENTS.
-- PARSED_CONTENT is a VARIANT with two indexed page objects. Other documents
-- in the table are excluded by DOCUMENT_NAME.

USE WAREHOUSE POLICYLENS_WH;
USE DATABASE POLICYLENS_DB;
USE SCHEMA APP;

-- Check that exactly one stored parse has the requested document name.
SELECT COUNT(*) AS product_warranty_source_rows
FROM PARSED_DOCUMENTS
WHERE DOCUMENT_NAME = 'Product_Warranty_Policy.pdf';

-- Create the destination only if absent. Existing rows are never replaced.
CREATE TABLE IF NOT EXISTS DOCUMENT_CHUNKS (
    CHUNK_ID         VARCHAR NOT NULL,
    DOCUMENT_NAME    VARCHAR NOT NULL,
    CHUNK_NUMBER     NUMBER(38, 0) NOT NULL,
    HEADER_1         VARCHAR,
    HEADER_2         VARCHAR,
    HEADER_3         VARCHAR,
    CHUNK_BODY       VARCHAR NOT NULL,
    SEARCHABLE_TEXT  VARCHAR NOT NULL
);

-- Read the named stored parse, order pages by the parser's zero-based index,
-- and join them with blank lines so a heading at a page boundary stays distinct.
-- The HAVING checks prevent insertion if a page is missing, empty, duplicated,
-- or the document name has multiple stored parses. No text is cleaned.
-- FLATTEN's INDEX gives the split array's zero-based order; add 1 for a
-- human-readable chunk number. Headers are stored separately from chunk body.
-- The SHA-256 ID incorporates the document, full parsed text, position, and
-- body, so the same source and settings produce the same ID on every run.
INSERT INTO DOCUMENT_CHUNKS (
    CHUNK_ID, DOCUMENT_NAME, CHUNK_NUMBER, HEADER_1, HEADER_2, HEADER_3,
    CHUNK_BODY, SEARCHABLE_TEXT
)
WITH source_document AS (
    SELECT DOCUMENT_NAME, PARSED_CONTENT
    FROM PARSED_DOCUMENTS
    WHERE DOCUMENT_NAME = 'Product_Warranty_Policy.pdf'
    QUALIFY COUNT(*) OVER () = 1
),
full_document AS (
    SELECT
        d.DOCUMENT_NAME,
        LISTAGG(p.value:content::STRING, '\n\n')
            WITHIN GROUP (ORDER BY p.value:index::INTEGER) AS full_text
    FROM source_document AS d,
         LATERAL FLATTEN(INPUT => d.PARSED_CONTENT:pages) AS p
    GROUP BY d.DOCUMENT_NAME
    HAVING COUNT(*) = 2
       AND COUNT(
           NULLIF(TRIM(p.value:content::STRING), '')
       ) = 2
       AND COUNT(DISTINCT p.value:index::INTEGER) = 2
       AND MIN(p.value:index::INTEGER) = 0
       AND MAX(p.value:index::INTEGER) = 1
),
split_chunks AS (
    SELECT
        d.document_name,
        d.full_text,
        c.index + 1 AS chunk_number,
        c.value:headers:header_1::VARCHAR AS header_1,
        c.value:headers:header_2::VARCHAR AS header_2,
        c.value:headers:header_3::VARCHAR AS header_3,
        c.value:chunk::VARCHAR AS chunk_body
    FROM full_document AS d,
         LATERAL FLATTEN(
             INPUT => SNOWFLAKE.CORTEX.SPLIT_TEXT_MARKDOWN_HEADER(
                 d.full_text,
                 OBJECT_CONSTRUCT(
                     '#', 'header_1',
                     '##', 'header_2',
                     '###', 'header_3'
                 ),
                 1000,
                 100
             )
         ) AS c
),
prepared AS (
    SELECT
        SHA2(
            document_name || '|' || SHA2(full_text, 256) || '|' ||
            chunk_number::VARCHAR || '|' || chunk_body,
            256
        ) AS chunk_id,
        document_name,
        chunk_number,
        header_1,
        header_2,
        header_3,
        chunk_body,
        COALESCE(header_1 || CHR(10), '') ||
        COALESCE(header_2 || CHR(10), '') ||
        COALESCE(header_3 || CHR(10), '') ||
        chunk_body AS searchable_text
    FROM split_chunks
)
SELECT
    s.chunk_id, s.document_name, s.chunk_number,
    s.header_1, s.header_2, s.header_3,
    s.chunk_body, s.searchable_text
FROM prepared AS s
WHERE NOT EXISTS (
    SELECT 1 FROM DOCUMENT_CHUNKS AS existing
    WHERE existing.CHUNK_ID = s.chunk_id
);

-- Validation 1: the verified preview had 11 chunks. A rerun should still
-- show 11 rows and 11 distinct IDs for this document, not 22.
SELECT
    COUNT(*) AS chunk_count,
    COUNT(DISTINCT CHUNK_ID) AS distinct_chunk_ids,
    COUNT(DISTINCT CHUNK_NUMBER) AS distinct_chunk_numbers,
    MIN(CHUNK_NUMBER) AS first_chunk_number,
    MAX(CHUNK_NUMBER) AS last_chunk_number,
    IFF(COUNT(*) = 11 AND COUNT(DISTINCT CHUNK_ID) = 11
        AND COUNT(DISTINCT CHUNK_NUMBER) = 11
        AND MIN(CHUNK_NUMBER) = 1 AND MAX(CHUNK_NUMBER) = 11,
        'PASS', 'REVIEW') AS count_check
FROM DOCUMENT_CHUNKS
WHERE DOCUMENT_NAME = 'Product_Warranty_Policy.pdf';

-- Validation 2: no required field or chunk body should be missing or blank.
-- Heading columns may legitimately be NULL at higher or lower levels.
SELECT CHUNK_NUMBER, CHUNK_ID, DOCUMENT_NAME, CHUNK_BODY, SEARCHABLE_TEXT
FROM DOCUMENT_CHUNKS
WHERE DOCUMENT_NAME = 'Product_Warranty_Policy.pdf'
  AND (CHUNK_ID IS NULL OR DOCUMENT_NAME IS NULL OR CHUNK_NUMBER IS NULL
       OR CHUNK_BODY IS NULL OR TRIM(CHUNK_BODY) = ''
       OR SEARCHABLE_TEXT IS NULL OR TRIM(SEARCHABLE_TEXT) = '')
ORDER BY CHUNK_NUMBER;

-- Inspect optional heading coverage separately; NULL can be valid before
-- a heading appears or when a level is absent.
SELECT
    COUNT_IF(HEADER_1 IS NULL) AS chunks_without_header_1,
    COUNT_IF(HEADER_2 IS NULL) AS chunks_without_header_2,
    COUNT_IF(HEADER_3 IS NULL) AS chunks_without_header_3
FROM DOCUMENT_CHUNKS
WHERE DOCUMENT_NAME = 'Product_Warranty_Policy.pdf';

-- Validation 3: inspect the model-specific warranty clauses and headings.
-- The verified preview placed the AX-100 and AX-200 headings in HEADER_2.
-- AX-100 should carry 24/30 months; AX-200 should carry 18/24.
SELECT CHUNK_NUMBER, HEADER_1, HEADER_2, HEADER_3, CHUNK_BODY
FROM DOCUMENT_CHUNKS
WHERE DOCUMENT_NAME = 'Product_Warranty_Policy.pdf'
  AND (HEADER_2 ILIKE '%AX-100%' OR HEADER_2 ILIKE '%AX-200%')
ORDER BY CHUNK_NUMBER;

SELECT
    COUNT_IF(HEADER_2 ILIKE '%AX-100%'
             AND CHUNK_BODY ILIKE '%24 months%'
             AND CHUNK_BODY ILIKE '%30 months%') AS ax100_clause_chunks,
    COUNT_IF(HEADER_2 ILIKE '%AX-200%'
             AND CHUNK_BODY ILIKE '%18 months%'
             AND CHUNK_BODY ILIKE '%24 months%') AS ax200_clause_chunks,
    IFF(
        COUNT_IF(HEADER_2 ILIKE '%AX-100%'
                 AND CHUNK_BODY ILIKE '%24 months%'
                 AND CHUNK_BODY ILIKE '%30 months%') >= 1
        AND COUNT_IF(HEADER_2 ILIKE '%AX-200%'
                     AND CHUNK_BODY ILIKE '%18 months%'
                     AND CHUNK_BODY ILIKE '%24 months%') >= 1,
        'PASS', 'REVIEW') AS warranty_clause_check
FROM DOCUMENT_CHUNKS
WHERE DOCUMENT_NAME = 'Product_Warranty_Policy.pdf';

-- Validation 4: searchable text must equal available headings
-- followed by the unchanged chunk body. Zero rows means no mismatches.
SELECT CHUNK_NUMBER, HEADER_1, HEADER_2, HEADER_3, SEARCHABLE_TEXT
FROM DOCUMENT_CHUNKS
WHERE DOCUMENT_NAME = 'Product_Warranty_Policy.pdf'
  AND SEARCHABLE_TEXT <> (
      COALESCE(HEADER_1 || CHR(10), '') ||
      COALESCE(HEADER_2 || CHR(10), '') ||
      COALESCE(HEADER_3 || CHR(10), '') ||
      CHUNK_BODY
  )
ORDER BY CHUNK_NUMBER;

-- Validation 5: show candidate PDF header, footer, and printed page-number
-- artifacts for human review. Matches are not automatically removed; some
-- document-ID occurrences can be legitimate policy references.
SELECT CHUNK_NUMBER, HEADER_1, HEADER_2, HEADER_3, CHUNK_BODY, SEARCHABLE_TEXT
FROM DOCUMENT_CHUNKS
WHERE DOCUMENT_NAME = 'Product_Warranty_Policy.pdf'
  AND (
      CONTAINS(SEARCHABLE_TEXT, 'Document ID:')
      OR CONTAINS(SEARCHABLE_TEXT, 'Version:')
      OR CONTAINS(SEARCHABLE_TEXT, 'Effective date:')
      OR CONTAINS(SEARCHABLE_TEXT, 'AST-WAR-001')
      OR REGEXP_LIKE(SEARCHABLE_TEXT, '.*Page[[:space:]]+[0-9]+.*', 'is')
  )
ORDER BY CHUNK_NUMBER;
