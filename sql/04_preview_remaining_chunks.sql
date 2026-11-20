-- PolicyLens Section 04.6.3: read-only preview of the two remaining PDFs.
-- Run in a Snowsight SQL worksheet after both parses are stored.
-- This script reads PARSED_DOCUMENTS only. It does not parse again, write
-- DOCUMENT_CHUNKS, clean PDF artifacts, or create any Snowflake object.
-- Heading-marker corrections exist only in the query result.

USE WAREHOUSE POLICYLENS_WH;
USE DATABASE POLICYLENS_DB;
USE SCHEMA APP;

-- 1. Require one stored parse per document and exactly two nonblank pages
-- with distinct zero-based indexes 0 and 1. A failed row needs investigation
-- before treating the chunk preview as complete.
WITH expected AS (
    SELECT COLUMN1 AS DOCUMENT_NAME FROM VALUES
        ('Service_Procedures.pdf'),
        ('Extended_Warranty_Terms.pdf')
),
source_rows AS (
    SELECT DOCUMENT_NAME, COUNT(*) AS STORED_PARSES
    FROM PARSED_DOCUMENTS
    WHERE DOCUMENT_NAME IN (
        'Service_Procedures.pdf', 'Extended_Warranty_Terms.pdf'
    )
    GROUP BY DOCUMENT_NAME
),
page_checks AS (
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
)
SELECT
    e.DOCUMENT_NAME,
    COALESCE(s.STORED_PARSES, 0) AS STORED_PARSES,
    COALESCE(p.PAGE_COUNT, 0) AS PAGE_COUNT,
    COALESCE(p.NONBLANK_PAGES, 0) AS NONBLANK_PAGES,
    COALESCE(p.DISTINCT_PAGE_INDEXES, 0) AS DISTINCT_PAGE_INDEXES,
    p.FIRST_PAGE_INDEX,
    p.LAST_PAGE_INDEX,
    IFF(s.STORED_PARSES = 1
        AND p.PAGE_COUNT = 2
        AND p.NONBLANK_PAGES = 2
        AND p.DISTINCT_PAGE_INDEXES = 2
        AND p.FIRST_PAGE_INDEX = 0
        AND p.LAST_PAGE_INDEX = 1,
        'PASS', 'REVIEW') AS PAGE_STATUS
FROM expected AS e
LEFT JOIN source_rows AS s ON s.DOCUMENT_NAME = e.DOCUMENT_NAME
LEFT JOIN page_checks AS p ON p.DOCUMENT_NAME = e.DOCUMENT_NAME
ORDER BY e.DOCUMENT_NAME;

-- 2. Inspect both sides of the physical PDF page boundary. For Service
-- Procedures, compare the end of page 0 and start of page 1 with the
-- Section 4 chunks below. Printed page headers and footers are left intact.
SELECT
    d.DOCUMENT_NAME,
    p.value:index::INTEGER AS PAGE_INDEX,
    LENGTH(p.value:content::STRING) AS PAGE_CHARACTERS,
    LEFT(p.value:content::STRING, 300) AS PAGE_START,
    RIGHT(p.value:content::STRING, 300) AS PAGE_END
FROM PARSED_DOCUMENTS AS d,
     LATERAL FLATTEN(INPUT => d.PARSED_CONTENT:pages) AS p
WHERE d.DOCUMENT_NAME IN (
    'Service_Procedures.pdf', 'Extended_Warranty_Terms.pdf'
)
ORDER BY d.DOCUMENT_NAME, PAGE_INDEX;

-- 3. Audit the in-memory heading correction before previewing chunks.
-- The two capture groups preserve the original spacing and section number;
-- only one leading # is removed from each confirmed top-level heading.
-- Reversing that marker change must reproduce the original text exactly.
-- Extended Warranty's genuine ## 2.1 and ## 2.2 must remain unchanged.
WITH target_patterns AS (
    SELECT
        COLUMN1 AS DOCUMENT_NAME,
        COLUMN2 AS BAD_HEADING_PATTERN,
        COLUMN3 AS GOOD_HEADING_PATTERN,
        COLUMN4 AS EXPECTED_CHANGES,
        COLUMN5 AS EXPECTED_SUBSECTIONS
    FROM VALUES
        ('Service_Procedures.pdf',
         '^##([[:blank:]]+)([5-8][.][[:blank:]]+)',
         '^#([[:blank:]]+)([5-8][.][[:blank:]]+)', 4, 0),
        ('Extended_Warranty_Terms.pdf',
         '^##([[:blank:]]+)([5-7][.][[:blank:]]+)',
         '^#([[:blank:]]+)([5-7][.][[:blank:]]+)', 3, 2)
),
source_documents AS (
    SELECT d.DOCUMENT_NAME, d.PARSED_CONTENT
    FROM PARSED_DOCUMENTS AS d
    WHERE d.DOCUMENT_NAME IN (
        'Service_Procedures.pdf', 'Extended_Warranty_Terms.pdf'
    )
    QUALIFY COUNT(*) OVER (PARTITION BY d.DOCUMENT_NAME) = 1
),
full_documents AS (
    SELECT
        d.DOCUMENT_NAME,
        LISTAGG(p.value:content::STRING, '\n\n')
            WITHIN GROUP (ORDER BY p.value:index::INTEGER) AS ORIGINAL_TEXT
    FROM source_documents AS d,
         LATERAL FLATTEN(INPUT => d.PARSED_CONTENT:pages) AS p
    GROUP BY d.DOCUMENT_NAME
    HAVING COUNT(*) = 2
       AND COUNT(NULLIF(TRIM(p.value:content::STRING), '')) = 2
       AND COUNT(DISTINCT p.value:index::INTEGER) = 2
       AND MIN(p.value:index::INTEGER) = 0
       AND MAX(p.value:index::INTEGER) = 1
),
normalized_documents AS (
    SELECT
        d.DOCUMENT_NAME,
        d.ORIGINAL_TEXT,
        REGEXP_REPLACE(
            d.ORIGINAL_TEXT,
            t.BAD_HEADING_PATTERN,
            '#\\1\\2',
            1, 0, 'm'
        ) AS NORMALIZED_TEXT,
        t.BAD_HEADING_PATTERN,
        t.GOOD_HEADING_PATTERN,
        t.EXPECTED_CHANGES,
        t.EXPECTED_SUBSECTIONS
    FROM full_documents AS d
    JOIN target_patterns AS t ON t.DOCUMENT_NAME = d.DOCUMENT_NAME
),
audit AS (
    SELECT
        DOCUMENT_NAME,
        EXPECTED_CHANGES,
        REGEXP_COUNT(ORIGINAL_TEXT, BAD_HEADING_PATTERN, 1, 'm')
            AS MATCHED_HEADINGS_BEFORE,
        REGEXP_COUNT(NORMALIZED_TEXT, BAD_HEADING_PATTERN, 1, 'm')
            AS BAD_HEADINGS_AFTER,
        REGEXP_COUNT(NORMALIZED_TEXT, GOOD_HEADING_PATTERN, 1, 'm')
            AS TOP_HEADINGS_AFTER,
        LENGTH(ORIGINAL_TEXT) - LENGTH(NORMALIZED_TEXT)
            AS MARKER_CHARACTERS_REMOVED,
        IFF(REGEXP_REPLACE(
            NORMALIZED_TEXT, GOOD_HEADING_PATTERN, '##\\1\\2', 1, 0, 'm'
        ) = ORIGINAL_TEXT, 'PASS', 'REVIEW') AS EXACT_TEXT_ROUND_TRIP,
        EXPECTED_SUBSECTIONS,
        REGEXP_COUNT(
            ORIGINAL_TEXT,
            '^##[[:blank:]]+2[.][12][[:blank:]]+',
            1, 'm'
        ) AS SUBSECTIONS_BEFORE,
        REGEXP_COUNT(
            NORMALIZED_TEXT,
            '^##[[:blank:]]+2[.][12][[:blank:]]+',
            1, 'm'
        ) AS SUBSECTIONS_AFTER
    FROM normalized_documents
)
SELECT
    DOCUMENT_NAME,
    EXPECTED_CHANGES,
    MATCHED_HEADINGS_BEFORE,
    BAD_HEADINGS_AFTER,
    TOP_HEADINGS_AFTER,
    MARKER_CHARACTERS_REMOVED,
    EXACT_TEXT_ROUND_TRIP,
    SUBSECTIONS_BEFORE,
    SUBSECTIONS_AFTER,
    IFF(MATCHED_HEADINGS_BEFORE = EXPECTED_CHANGES
        AND BAD_HEADINGS_AFTER = 0
        AND TOP_HEADINGS_AFTER = EXPECTED_CHANGES
        AND MARKER_CHARACTERS_REMOVED = EXPECTED_CHANGES
        AND EXACT_TEXT_ROUND_TRIP = 'PASS'
        AND SUBSECTIONS_BEFORE = EXPECTED_SUBSECTIONS
        AND SUBSECTIONS_AFTER = EXPECTED_SUBSECTIONS,
        'PASS', 'REVIEW') AS NORMALIZATION_STATUS
FROM audit
ORDER BY DOCUMENT_NAME;

-- 4. Join the pages in index order, normalize only the confirmed top-level
-- headings, then use the same Markdown header-aware splitter and settings as
-- Product Warranty. Invalid or duplicate parses are excluded by the checks.
-- TOTAL_CHUNKS is observed per document; no count of 11 is assumed.
-- CHUNK_BODY is shown in full so Section 4's page-2 continuation can be
-- compared with the page-boundary excerpts above. Its HEADER_1 should still
-- identify "4. Service team review" if the heading is preserved.
-- Review Extended Warranty Sections 2/3/5 for the 12-month term, timing
-- requirements, and exclusions. POSSIBLE_PDF_ARTIFACT is a review flag only;
-- document IDs can also be legitimate citations or metadata.
WITH expected AS (
    SELECT COLUMN1 AS DOCUMENT_NAME FROM VALUES
        ('Service_Procedures.pdf'),
        ('Extended_Warranty_Terms.pdf')
),
target_patterns AS (
    SELECT COLUMN1 AS DOCUMENT_NAME, COLUMN2 AS BAD_HEADING_PATTERN,
           COLUMN3 AS EXPECTED_TOP_SECTIONS
    FROM VALUES
        ('Service_Procedures.pdf',
         '^##([[:blank:]]+)([5-8][.][[:blank:]]+)', 4),
        ('Extended_Warranty_Terms.pdf',
         '^##([[:blank:]]+)([5-7][.][[:blank:]]+)', 3)
),
source_documents AS (
    SELECT d.DOCUMENT_NAME, d.PARSED_CONTENT
    FROM PARSED_DOCUMENTS AS d
    WHERE d.DOCUMENT_NAME IN (
        'Service_Procedures.pdf', 'Extended_Warranty_Terms.pdf'
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
normalized_documents AS (
    SELECT
        d.DOCUMENT_NAME,
        REGEXP_REPLACE(
            d.FULL_TEXT,
            t.BAD_HEADING_PATTERN,
            '#\\1\\2',
            1, 0, 'm'
        ) AS FULL_TEXT
    FROM full_documents AS d
    JOIN target_patterns AS t ON t.DOCUMENT_NAME = d.DOCUMENT_NAME
),
split_chunks AS (
    SELECT
        d.DOCUMENT_NAME,
        c.index + 1 AS CHUNK_NUMBER,
        c.value:headers:header_1::VARCHAR AS HEADER_1,
        c.value:headers:header_2::VARCHAR AS HEADER_2,
        c.value:headers:header_3::VARCHAR AS HEADER_3,
        c.value:chunk::VARCHAR AS CHUNK_BODY
    FROM normalized_documents AS d,
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
),
prepared AS (
    SELECT
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
    FROM split_chunks
),
heading_checks AS (
    SELECT
        DOCUMENT_NAME,
        COUNT(DISTINCT CASE
            WHEN DOCUMENT_NAME = 'Service_Procedures.pdf'
                 AND REGEXP_LIKE(
                     HEADER_1, '[5-8][.][[:blank:]]+.*'
                 ) THEN LEFT(HEADER_1, 2)
            WHEN DOCUMENT_NAME = 'Extended_Warranty_Terms.pdf'
                 AND REGEXP_LIKE(
                     HEADER_1, '[5-7][.][[:blank:]]+.*'
                 ) THEN LEFT(HEADER_1, 2)
        END) AS NORMALIZED_TOP_SECTIONS,
        COALESCE(COUNT_IF(
            DOCUMENT_NAME = 'Service_Procedures.pdf'
            AND HEADER_1 = '4. Service team review'
            AND CONTAINS(CHUNK_BODY, '3. Reviewing the fault description')
        ), 0) AS SERVICE_PAGE_2_ITEMS,
        COALESCE(COUNT_IF(
            DOCUMENT_NAME = 'Service_Procedures.pdf'
            AND HEADER_1 = '4. Service team review'
            AND CONTAINS(
                CHUNK_BODY, 'The review is based on the information available.'
            )
        ), 0) AS SERVICE_SECTION_4_END
    FROM prepared
    GROUP BY DOCUMENT_NAME
),
preview AS (
    SELECT
        p.*,
        COUNT(*) OVER (PARTITION BY DOCUMENT_NAME) AS TOTAL_CHUNKS,
        SUM(IFF(CHUNK_BODY IS NULL OR TRIM(CHUNK_BODY) = '', 1, 0))
            OVER (PARTITION BY DOCUMENT_NAME) AS EMPTY_BODY_COUNT
    FROM prepared AS p
)
SELECT
    e.DOCUMENT_NAME,
    COALESCE(p.TOTAL_CHUNKS, 0) AS TOTAL_CHUNKS,
    COALESCE(p.EMPTY_BODY_COUNT, 0) AS EMPTY_BODY_COUNT,
    h.NORMALIZED_TOP_SECTIONS,
    IFF(h.NORMALIZED_TOP_SECTIONS = t.EXPECTED_TOP_SECTIONS,
        'PASS', 'REVIEW') AS TOP_HEADING_STATUS,
    IFF(e.DOCUMENT_NAME = 'Service_Procedures.pdf',
        IFF(h.SERVICE_PAGE_2_ITEMS > 0 AND h.SERVICE_SECTION_4_END > 0,
            'PASS', 'REVIEW'),
        NULL) AS SECTION_4_CONTINUITY_STATUS,
    p.CHUNK_NUMBER,
    p.HEADER_1,
    p.HEADER_2,
    p.HEADER_3,
    LENGTH(p.CHUNK_BODY) AS BODY_CHARACTERS,
    LEFT(p.CHUNK_BODY, 220) AS CHUNK_PREVIEW,
    p.CHUNK_BODY,
    p.SEARCHABLE_TEXT,
    IFF(p.CHUNK_NUMBER IS NULL, 'NO CHUNKS',
        IFF(p.CHUNK_BODY IS NULL OR TRIM(p.CHUNK_BODY) = '',
            'REVIEW', 'OK')) AS BODY_STATUS,
    IFF(p.CHUNK_NUMBER IS NULL, 'NO CHUNKS',
        IFF(p.SEARCHABLE_TEXT = (
            COALESCE(p.HEADER_1 || CHR(10), '') ||
            COALESCE(p.HEADER_2 || CHR(10), '') ||
            COALESCE(p.HEADER_3 || CHR(10), '') ||
            p.CHUNK_BODY
        ),
            'PASS', 'REVIEW')) AS HEADING_PREFIX_STATUS,
    CASE
        WHEN e.DOCUMENT_NAME = 'Service_Procedures.pdf'
             AND p.HEADER_1 ILIKE '%4. Service team review%'
            THEN 'SERVICE SECTION 4: CHECK PAGE CONTINUATION'
        WHEN e.DOCUMENT_NAME = 'Extended_Warranty_Terms.pdf'
             AND (p.HEADER_1 ILIKE '%2. Eligible products and extension duration%'
                  OR p.HEADER_1 ILIKE '%3. Purchase and registration timing%'
                  OR p.HEADER_1 ILIKE '%5. Extended coverage and exclusions%')
            THEN 'EXTENDED TERMS: CHECK RULES AND HEADING'
    END AS FOCUS_AREA,
    IFF(p.CHUNK_BODY ILIKE '%Page 2%'
        OR p.CHUNK_BODY ILIKE '%AST-SVC-001%'
        OR p.CHUNK_BODY ILIKE '%AST-EW-001%',
        'REVIEW', NULL) AS POSSIBLE_PDF_ARTIFACT
FROM expected AS e
LEFT JOIN target_patterns AS t ON t.DOCUMENT_NAME = e.DOCUMENT_NAME
LEFT JOIN preview AS p ON p.DOCUMENT_NAME = e.DOCUMENT_NAME
LEFT JOIN heading_checks AS h ON h.DOCUMENT_NAME = e.DOCUMENT_NAME
ORDER BY e.DOCUMENT_NAME, p.CHUNK_NUMBER;
