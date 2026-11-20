-- PolicyLens Section 04.6: persist the two reviewed, normalized documents.
-- Run in one Snowsight SQL worksheet session. Temporary tables hold candidates
-- and checks; only the final guarded INSERT writes to DOCUMENT_CHUNKS.
-- No PDF is reparsed. Printed PDF header/footer artifacts remain for V1.

USE WAREHOUSE POLICYLENS_WH;
USE DATABASE POLICYLENS_DB;
USE SCHEMA APP;

-- 1. Rebuild session-only normalized text from the two stored parses.
-- The expressions and 1000/100 splitter below match the verified preview.
-- DDL is deliberately outside the later transaction.
CREATE OR REPLACE TEMP TABLE PL_046_NORMALIZED_DOCS AS
WITH target_patterns AS (
    SELECT
        COLUMN1 AS DOCUMENT_NAME,
        COLUMN2 AS BAD_PATTERN,
        COLUMN3 AS GOOD_PATTERN,
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
single_sources AS (
    SELECT DOCUMENT_NAME, PARSED_CONTENT
    FROM PARSED_DOCUMENTS
    WHERE DOCUMENT_NAME IN (
        'Service_Procedures.pdf', 'Extended_Warranty_Terms.pdf'
    )
    QUALIFY COUNT(*) OVER (PARTITION BY DOCUMENT_NAME) = 1
),
full_documents AS (
    SELECT
        d.DOCUMENT_NAME,
        LISTAGG(p.value:content::STRING, '\n\n')
            WITHIN GROUP (ORDER BY p.value:index::INTEGER) AS ORIGINAL_TEXT,
        COUNT(*) AS PAGE_COUNT,
        COUNT(NULLIF(TRIM(p.value:content::STRING), '')) AS NONBLANK_PAGES,
        COUNT(DISTINCT p.value:index::INTEGER) AS DISTINCT_PAGE_INDEXES,
        MIN(p.value:index::INTEGER) AS FIRST_PAGE_INDEX,
        MAX(p.value:index::INTEGER) AS LAST_PAGE_INDEX
    FROM single_sources AS d,
         LATERAL FLATTEN(INPUT => d.PARSED_CONTENT:pages) AS p
    GROUP BY d.DOCUMENT_NAME
),
normalized AS (
    SELECT
        f.*,
        t.BAD_PATTERN,
        t.GOOD_PATTERN,
        t.EXPECTED_CHANGES,
        t.EXPECTED_SUBSECTIONS,
        REGEXP_REPLACE(
            f.ORIGINAL_TEXT, t.BAD_PATTERN, '#\\1\\2', 1, 0, 'm'
        ) AS NORMALIZED_TEXT
    FROM full_documents AS f
    JOIN target_patterns AS t ON t.DOCUMENT_NAME = f.DOCUMENT_NAME
)
SELECT
    DOCUMENT_NAME, ORIGINAL_TEXT, NORMALIZED_TEXT,
    PAGE_COUNT, NONBLANK_PAGES, DISTINCT_PAGE_INDEXES,
    FIRST_PAGE_INDEX, LAST_PAGE_INDEX,
    EXPECTED_CHANGES, EXPECTED_SUBSECTIONS,
    REGEXP_COUNT(ORIGINAL_TEXT, BAD_PATTERN, 1, 'm')
        AS MATCHED_HEADINGS_BEFORE,
    REGEXP_COUNT(NORMALIZED_TEXT, BAD_PATTERN, 1, 'm')
        AS BAD_HEADINGS_AFTER,
    REGEXP_COUNT(NORMALIZED_TEXT, GOOD_PATTERN, 1, 'm')
        AS TOP_HEADINGS_AFTER,
    LENGTH(ORIGINAL_TEXT) - LENGTH(NORMALIZED_TEXT)
        AS MARKER_CHARACTERS_REMOVED,
    IFF(REGEXP_REPLACE(
        NORMALIZED_TEXT, GOOD_PATTERN, '##\\1\\2', 1, 0, 'm'
    ) = ORIGINAL_TEXT, 'PASS', 'REVIEW') AS EXACT_TEXT_ROUND_TRIP,
    REGEXP_COUNT(
        ORIGINAL_TEXT, '^##[[:blank:]]+2[.][12][[:blank:]]+', 1, 'm'
    ) AS SUBSECTIONS_BEFORE,
    REGEXP_COUNT(
        NORMALIZED_TEXT, '^##[[:blank:]]+2[.][12][[:blank:]]+', 1, 'm'
    ) AS SUBSECTIONS_AFTER
FROM normalized;

-- 2. Materialize the exact rows proposed for insertion. The hash includes
-- document name, normalized whole-document text, chunk number, and body.
-- Existing Product Warranty rows are outside this candidate set.
CREATE OR REPLACE TEMP TABLE PL_046_CANDIDATE_CHUNKS AS
WITH split_chunks AS (
    SELECT
        d.DOCUMENT_NAME,
        d.NORMALIZED_TEXT,
        c.index + 1 AS CHUNK_NUMBER,
        c.value:headers:header_1::VARCHAR AS HEADER_1,
        c.value:headers:header_2::VARCHAR AS HEADER_2,
        c.value:headers:header_3::VARCHAR AS HEADER_3,
        c.value:chunk::VARCHAR AS CHUNK_BODY
    FROM PL_046_NORMALIZED_DOCS AS d,
         LATERAL FLATTEN(
             INPUT => SNOWFLAKE.CORTEX.SPLIT_TEXT_MARKDOWN_HEADER(
                 d.NORMALIZED_TEXT,
                 OBJECT_CONSTRUCT(
                     '#', 'header_1',
                     '##', 'header_2',
                     '###', 'header_3'
                 ),
                 1000,
                 100
             )
         ) AS c
    WHERE d.PAGE_COUNT = 2
      AND d.NONBLANK_PAGES = 2
      AND d.DISTINCT_PAGE_INDEXES = 2
      AND d.FIRST_PAGE_INDEX = 0
      AND d.LAST_PAGE_INDEX = 1
)
SELECT
    SHA2(
        DOCUMENT_NAME || '|' || SHA2(NORMALIZED_TEXT, 256) || '|' ||
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

-- 3. One row per expected document summarizes source, normalization,
-- candidate, and existing-row checks. An existing document is safe only when
-- it has zero rows or a complete row-for-row match with this candidate set.
-- EXCEPT compares all stored columns in both directions; counts catch
-- duplicate rows that set comparison alone would hide.
CREATE OR REPLACE TEMP TABLE PL_046_INSERT_CHECKS AS
WITH expected AS (
    SELECT COLUMN1 AS DOCUMENT_NAME, COLUMN2 AS EXPECTED_CHUNKS
    FROM VALUES
        ('Service_Procedures.pdf', 12),
        ('Extended_Warranty_Terms.pdf', 9)
),
source_counts AS (
    SELECT DOCUMENT_NAME, COUNT(*) AS STORED_PARSES
    FROM PARSED_DOCUMENTS
    WHERE DOCUMENT_NAME IN (
        'Service_Procedures.pdf', 'Extended_Warranty_Terms.pdf'
    )
    GROUP BY DOCUMENT_NAME
),
candidate_stats AS (
    SELECT
        DOCUMENT_NAME,
        COUNT(*) AS CANDIDATE_COUNT,
        COUNT(DISTINCT CHUNK_ID) AS DISTINCT_IDS,
        COUNT(DISTINCT CHUNK_NUMBER) AS DISTINCT_NUMBERS,
        MIN(CHUNK_NUMBER) AS FIRST_NUMBER,
        MAX(CHUNK_NUMBER) AS LAST_NUMBER,
        COALESCE(COUNT_IF(
            CHUNK_ID IS NULL OR CHUNK_BODY IS NULL OR TRIM(CHUNK_BODY) = ''
            OR SEARCHABLE_TEXT IS NULL OR TRIM(SEARCHABLE_TEXT) = ''
            OR SEARCHABLE_TEXT IS DISTINCT FROM (
                COALESCE(HEADER_1 || CHR(10), '') ||
                COALESCE(HEADER_2 || CHR(10), '') ||
                COALESCE(HEADER_3 || CHR(10), '') ||
                CHUNK_BODY
            )
        ), 0) AS INVALID_ROWS,
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
        COALESCE(COUNT_IF(HEADER_2 = '2.1 Eligible products'), 0)
            AS SUBSECTION_21,
        COALESCE(COUNT_IF(HEADER_2 = '2.2 Duration'), 0)
            AS SUBSECTION_22,
        COALESCE(COUNT_IF(
            HEADER_1 = '4. Service team review'
            AND CONTAINS(CHUNK_BODY, '3. Reviewing the fault description')
        ), 0) AS SERVICE_PAGE_2_ITEMS,
        COALESCE(COUNT_IF(
            HEADER_1 = '4. Service team review'
            AND CONTAINS(
                CHUNK_BODY, 'The review is based on the information available.'
            )
        ), 0) AS SERVICE_SECTION_4_END
    FROM PL_046_CANDIDATE_CHUNKS
    GROUP BY DOCUMENT_NAME
),
candidate_inventory AS (
    SELECT
        COUNT(*) AS TOTAL_CANDIDATES,
        COUNT(DISTINCT CHUNK_ID) AS DISTINCT_CANDIDATE_IDS,
        COALESCE(COUNT_IF(DOCUMENT_NAME NOT IN (
            'Service_Procedures.pdf', 'Extended_Warranty_Terms.pdf'
        ) OR DOCUMENT_NAME IS NULL), 0) AS UNEXPECTED_CANDIDATES
    FROM PL_046_CANDIDATE_CHUNKS
),
expected_headings AS (
    SELECT COLUMN1 AS DOCUMENT_NAME, COLUMN2 AS HEADING_LEVEL,
           COLUMN3 AS HEADING
    FROM VALUES
        ('Service_Procedures.pdf', 'HEADER_1',
         '5. Warranty repair authorization'),
        ('Service_Procedures.pdf', 'HEADER_1',
         '6. Incomplete information and escalation'),
        ('Service_Procedures.pdf', 'HEADER_1',
         '7. Request record and follow-up'),
        ('Service_Procedures.pdf', 'HEADER_1',
         '8. Related documents'),
        ('Extended_Warranty_Terms.pdf', 'HEADER_1',
         '5. Extended coverage and exclusions'),
        ('Extended_Warranty_Terms.pdf', 'HEADER_1',
         '6. Service requests and repair authorization'),
        ('Extended_Warranty_Terms.pdf', 'HEADER_1',
         '7. Summary of the coverage sequence'),
        ('Extended_Warranty_Terms.pdf', 'HEADER_2',
         '2.1 Eligible products'),
        ('Extended_Warranty_Terms.pdf', 'HEADER_2',
         '2.2 Duration')
),
heading_counts AS (
    SELECT
        e.DOCUMENT_NAME,
        COUNT(DISTINCT e.HEADING)
        - COUNT(DISTINCT IFF(
            (e.HEADING_LEVEL = 'HEADER_1' AND c.HEADER_1 = e.HEADING)
            OR (e.HEADING_LEVEL = 'HEADER_2' AND c.HEADER_2 = e.HEADING),
            e.HEADING, NULL
        )) AS MISSING_HEADINGS
    FROM expected_headings AS e
    LEFT JOIN PL_046_CANDIDATE_CHUNKS AS c
      ON c.DOCUMENT_NAME = e.DOCUMENT_NAME
    GROUP BY e.DOCUMENT_NAME
),
existing_stats AS (
    SELECT
        DOCUMENT_NAME,
        COUNT(*) AS EXISTING_COUNT,
        COUNT(DISTINCT CHUNK_ID) AS DISTINCT_EXISTING_IDS
    FROM DOCUMENT_CHUNKS
    WHERE DOCUMENT_NAME IN (
        'Service_Procedures.pdf', 'Extended_Warranty_Terms.pdf'
    )
    GROUP BY DOCUMENT_NAME
),
differences AS (
    SELECT DOCUMENT_NAME FROM (
        SELECT CHUNK_ID, DOCUMENT_NAME, CHUNK_NUMBER,
               HEADER_1, HEADER_2, HEADER_3, CHUNK_BODY, SEARCHABLE_TEXT
        FROM DOCUMENT_CHUNKS
        WHERE DOCUMENT_NAME IN (
            'Service_Procedures.pdf', 'Extended_Warranty_Terms.pdf'
        )
        EXCEPT
        SELECT CHUNK_ID, DOCUMENT_NAME, CHUNK_NUMBER,
               HEADER_1, HEADER_2, HEADER_3, CHUNK_BODY, SEARCHABLE_TEXT
        FROM PL_046_CANDIDATE_CHUNKS
    ) AS only_existing
    UNION ALL
    SELECT DOCUMENT_NAME FROM (
        SELECT CHUNK_ID, DOCUMENT_NAME, CHUNK_NUMBER,
               HEADER_1, HEADER_2, HEADER_3, CHUNK_BODY, SEARCHABLE_TEXT
        FROM PL_046_CANDIDATE_CHUNKS
        EXCEPT
        SELECT CHUNK_ID, DOCUMENT_NAME, CHUNK_NUMBER,
               HEADER_1, HEADER_2, HEADER_3, CHUNK_BODY, SEARCHABLE_TEXT
        FROM DOCUMENT_CHUNKS
        WHERE DOCUMENT_NAME IN (
            'Service_Procedures.pdf', 'Extended_Warranty_Terms.pdf'
        )
    ) AS only_candidate
),
difference_counts AS (
    SELECT DOCUMENT_NAME, COUNT(*) AS DIFFERENT_ROWS
    FROM differences
    GROUP BY DOCUMENT_NAME
),
inventory AS (
    SELECT
        COUNT_IF(DOCUMENT_NAME = 'Product_Warranty_Policy.pdf')
            AS PRODUCT_ROWS,
        COALESCE(COUNT_IF(DOCUMENT_NAME NOT IN (
            'Product_Warranty_Policy.pdf',
            'Service_Procedures.pdf',
            'Extended_Warranty_Terms.pdf'
        ) OR DOCUMENT_NAME IS NULL), 0) AS UNEXPECTED_ROWS
    FROM DOCUMENT_CHUNKS
)
SELECT
    e.DOCUMENT_NAME,
    e.EXPECTED_CHUNKS,
    COALESCE(s.STORED_PARSES, 0) AS STORED_PARSES,
    n.PAGE_COUNT,
    n.NONBLANK_PAGES,
    n.DISTINCT_PAGE_INDEXES,
    n.FIRST_PAGE_INDEX,
    n.LAST_PAGE_INDEX,
    n.MATCHED_HEADINGS_BEFORE,
    n.BAD_HEADINGS_AFTER,
    n.TOP_HEADINGS_AFTER,
    n.MARKER_CHARACTERS_REMOVED,
    n.EXACT_TEXT_ROUND_TRIP,
    n.SUBSECTIONS_BEFORE,
    n.SUBSECTIONS_AFTER,
    COALESCE(c.CANDIDATE_COUNT, 0) AS CANDIDATE_COUNT,
    COALESCE(c.DISTINCT_IDS, 0) AS DISTINCT_CANDIDATE_IDS,
    ci.TOTAL_CANDIDATES,
    ci.DISTINCT_CANDIDATE_IDS AS TOTAL_DISTINCT_CANDIDATE_IDS,
    COALESCE(c.INVALID_ROWS, 0) AS INVALID_CANDIDATE_ROWS,
    COALESCE(c.NORMALIZED_TOP_SECTIONS, 0) AS NORMALIZED_TOP_SECTIONS,
    h.MISSING_HEADINGS,
    COALESCE(x.EXISTING_COUNT, 0) AS EXISTING_COUNT,
    COALESCE(d.DIFFERENT_ROWS, 0) AS DIFFERENT_ROWS,
    i.PRODUCT_ROWS,
    i.UNEXPECTED_ROWS,
    IFF(
        s.STORED_PARSES = 1
        AND n.PAGE_COUNT = 2 AND n.NONBLANK_PAGES = 2
        AND n.DISTINCT_PAGE_INDEXES = 2
        AND n.FIRST_PAGE_INDEX = 0 AND n.LAST_PAGE_INDEX = 1
        AND n.MATCHED_HEADINGS_BEFORE = n.EXPECTED_CHANGES
        AND n.BAD_HEADINGS_AFTER = 0
        AND n.TOP_HEADINGS_AFTER = n.EXPECTED_CHANGES
        AND n.MARKER_CHARACTERS_REMOVED = n.EXPECTED_CHANGES
        AND n.EXACT_TEXT_ROUND_TRIP = 'PASS'
        AND n.SUBSECTIONS_BEFORE = n.EXPECTED_SUBSECTIONS
        AND n.SUBSECTIONS_AFTER = n.EXPECTED_SUBSECTIONS
        AND c.CANDIDATE_COUNT = e.EXPECTED_CHUNKS
        AND c.DISTINCT_IDS = e.EXPECTED_CHUNKS
        AND ci.TOTAL_CANDIDATES = 21
        AND ci.DISTINCT_CANDIDATE_IDS = 21
        AND ci.UNEXPECTED_CANDIDATES = 0
        AND c.DISTINCT_NUMBERS = e.EXPECTED_CHUNKS
        AND c.FIRST_NUMBER = 1
        AND c.LAST_NUMBER = e.EXPECTED_CHUNKS
        AND c.INVALID_ROWS = 0
        AND c.NORMALIZED_TOP_SECTIONS = n.EXPECTED_CHANGES
        AND h.MISSING_HEADINGS = 0
        AND (e.DOCUMENT_NAME = 'Service_Procedures.pdf'
             AND c.SERVICE_PAGE_2_ITEMS > 0
             AND c.SERVICE_SECTION_4_END > 0
             OR e.DOCUMENT_NAME = 'Extended_Warranty_Terms.pdf'
             AND c.SUBSECTION_21 > 0 AND c.SUBSECTION_22 > 0)
        AND (COALESCE(x.EXISTING_COUNT, 0) = 0
             OR (x.EXISTING_COUNT = e.EXPECTED_CHUNKS
                 AND x.DISTINCT_EXISTING_IDS = e.EXPECTED_CHUNKS
                 AND COALESCE(d.DIFFERENT_ROWS, 0) = 0))
        AND i.PRODUCT_ROWS = 11
        AND i.UNEXPECTED_ROWS = 0,
        'PASS', 'FAIL'
    ) AS INSERT_STATUS
FROM expected AS e
LEFT JOIN source_counts AS s ON s.DOCUMENT_NAME = e.DOCUMENT_NAME
LEFT JOIN PL_046_NORMALIZED_DOCS AS n ON n.DOCUMENT_NAME = e.DOCUMENT_NAME
LEFT JOIN candidate_stats AS c ON c.DOCUMENT_NAME = e.DOCUMENT_NAME
LEFT JOIN heading_counts AS h ON h.DOCUMENT_NAME = e.DOCUMENT_NAME
LEFT JOIN existing_stats AS x ON x.DOCUMENT_NAME = e.DOCUMENT_NAME
LEFT JOIN difference_counts AS d ON d.DOCUMENT_NAME = e.DOCUMENT_NAME
CROSS JOIN candidate_inventory AS ci
CROSS JOIN inventory AS i;

-- Review these two rows before the guarded insert. On an unchanged rerun,
-- EXISTING_COUNT is 12 or 9 and DIFFERENT_ROWS is zero.
SELECT *
FROM PL_046_INSERT_CHECKS
ORDER BY DOCUMENT_NAME;

-- 4. Abort on any failed check. Insert only documents with no existing
-- chunks. A complete, identical document is a no-op; a partial or different
-- version fails rather than mixing rows. The single INSERT is transactional.
EXECUTE IMMEDIATE $$
DECLARE
    failed_preflight EXCEPTION (-20001, 'PolicyLens candidate or existing-row check failed.');
    failed_postcheck EXCEPTION (-20002, 'PolicyLens post-insert check failed; insert rolled back.');
    issue_count NUMBER;
    check_rows NUMBER;
BEGIN
    SELECT COUNT(*) INTO :check_rows
    FROM PL_046_INSERT_CHECKS;

    SELECT COUNT(*) INTO :issue_count
    FROM PL_046_INSERT_CHECKS
    WHERE INSERT_STATUS <> 'PASS';

    IF (check_rows <> 2 OR issue_count <> 0) THEN
        RAISE failed_preflight;
    END IF;

    BEGIN
        BEGIN TRANSACTION;

        INSERT INTO DOCUMENT_CHUNKS (
            CHUNK_ID, DOCUMENT_NAME, CHUNK_NUMBER,
            HEADER_1, HEADER_2, HEADER_3, CHUNK_BODY, SEARCHABLE_TEXT
        )
        SELECT
            c.CHUNK_ID, c.DOCUMENT_NAME, c.CHUNK_NUMBER,
            c.HEADER_1, c.HEADER_2, c.HEADER_3,
            c.CHUNK_BODY, c.SEARCHABLE_TEXT
        FROM PL_046_CANDIDATE_CHUNKS AS c
        JOIN PL_046_INSERT_CHECKS AS v
          ON v.DOCUMENT_NAME = c.DOCUMENT_NAME
        WHERE v.EXISTING_COUNT = 0;

        SELECT COUNT(*) INTO :issue_count
        FROM (
            SELECT expected.DOCUMENT_NAME
            FROM (
                SELECT COLUMN1 AS DOCUMENT_NAME, COLUMN2 AS EXPECTED_COUNT
                FROM VALUES
                    ('Product_Warranty_Policy.pdf', 11),
                    ('Service_Procedures.pdf', 12),
                    ('Extended_Warranty_Terms.pdf', 9)
            ) AS expected
            LEFT JOIN DOCUMENT_CHUNKS AS actual
              ON actual.DOCUMENT_NAME = expected.DOCUMENT_NAME
            GROUP BY expected.DOCUMENT_NAME, expected.EXPECTED_COUNT
            HAVING COUNT(actual.CHUNK_ID) <> expected.EXPECTED_COUNT
                OR COUNT(DISTINCT actual.CHUNK_ID) <> expected.EXPECTED_COUNT
        ) AS wrong_counts;

        IF (issue_count <> 0) THEN
            RAISE failed_postcheck;
        END IF;

        SELECT IFF(
            COUNT(*) = 32
            AND COUNT(DISTINCT CHUNK_ID) = 32
            AND COALESCE(COUNT_IF(
                CHUNK_BODY IS NULL OR TRIM(CHUNK_BODY) = ''
                OR SEARCHABLE_TEXT IS NULL OR TRIM(SEARCHABLE_TEXT) = ''
                OR DOCUMENT_NAME IS NULL
                OR DOCUMENT_NAME NOT IN (
                    'Product_Warranty_Policy.pdf',
                    'Service_Procedures.pdf',
                    'Extended_Warranty_Terms.pdf'
                )
                OR SEARCHABLE_TEXT IS DISTINCT FROM (
                    COALESCE(HEADER_1 || CHR(10), '') ||
                    COALESCE(HEADER_2 || CHR(10), '') ||
                    COALESCE(HEADER_3 || CHR(10), '') ||
                    CHUNK_BODY
                )
            ), 0) = 0,
            0, 1
        ) INTO :issue_count
        FROM DOCUMENT_CHUNKS;

        IF (issue_count <> 0) THEN
            RAISE failed_postcheck;
        END IF;

        COMMIT;
    EXCEPTION
        WHEN OTHER THEN
            ROLLBACK;
            RAISE;
    END;

    RETURN 'PASS: 21 candidate chunks are present; no stale rows were mixed.';
END;
$$;

-- 5. Fresh post-insertion inventory. Expected: 11, 12, 9, total 32.
WITH expected AS (
    SELECT COLUMN1 AS DOCUMENT_NAME, COLUMN2 AS EXPECTED_COUNT
    FROM VALUES
        ('Product_Warranty_Policy.pdf', 11),
        ('Service_Procedures.pdf', 12),
        ('Extended_Warranty_Terms.pdf', 9)
),
actual AS (
    SELECT
        DOCUMENT_NAME,
        COUNT(*) AS CHUNK_COUNT,
        COUNT(DISTINCT CHUNK_ID) AS DISTINCT_IDS,
        COUNT(DISTINCT CHUNK_NUMBER) AS DISTINCT_NUMBERS,
        MIN(CHUNK_NUMBER) AS FIRST_NUMBER,
        MAX(CHUNK_NUMBER) AS LAST_NUMBER
    FROM DOCUMENT_CHUNKS
    GROUP BY DOCUMENT_NAME
)
SELECT
    e.DOCUMENT_NAME,
    e.EXPECTED_COUNT,
    COALESCE(a.CHUNK_COUNT, 0) AS CHUNK_COUNT,
    COALESCE(a.DISTINCT_IDS, 0) AS DISTINCT_IDS,
    COALESCE(a.DISTINCT_NUMBERS, 0) AS DISTINCT_NUMBERS,
    a.FIRST_NUMBER,
    a.LAST_NUMBER,
    IFF(a.CHUNK_COUNT = e.EXPECTED_COUNT
        AND a.DISTINCT_IDS = e.EXPECTED_COUNT
        AND a.DISTINCT_NUMBERS = e.EXPECTED_COUNT
        AND a.FIRST_NUMBER = 1
        AND a.LAST_NUMBER = e.EXPECTED_COUNT,
        'PASS', 'REVIEW') AS INVENTORY_STATUS
FROM expected AS e
LEFT JOIN actual AS a ON a.DOCUMENT_NAME = e.DOCUMENT_NAME
ORDER BY e.DOCUMENT_NAME;

WITH totals AS (
    SELECT
        COUNT(*) AS TOTAL_CHUNKS,
        COUNT(DISTINCT CHUNK_ID) AS DISTINCT_CHUNK_IDS,
        COALESCE(COUNT_IF(
            CHUNK_BODY IS NULL OR TRIM(CHUNK_BODY) = ''
            OR SEARCHABLE_TEXT IS NULL OR TRIM(SEARCHABLE_TEXT) = ''
        ), 0) AS BLANK_ROWS,
        COALESCE(COUNT_IF(DOCUMENT_NAME NOT IN (
            'Product_Warranty_Policy.pdf',
            'Service_Procedures.pdf',
            'Extended_Warranty_Terms.pdf'
        ) OR DOCUMENT_NAME IS NULL), 0) AS UNEXPECTED_DOCUMENT_ROWS
    FROM DOCUMENT_CHUNKS
)
SELECT
    TOTAL_CHUNKS, DISTINCT_CHUNK_IDS, BLANK_ROWS,
    UNEXPECTED_DOCUMENT_ROWS,
    IFF(TOTAL_CHUNKS = 32 AND DISTINCT_CHUNK_IDS = 32
        AND BLANK_ROWS = 0 AND UNEXPECTED_DOCUMENT_ROWS = 0,
        'PASS', 'REVIEW') AS TOTAL_STATUS
FROM totals;

-- Zero rows expected: required fields and heading-prefixed search text.
SELECT DOCUMENT_NAME, CHUNK_NUMBER, CHUNK_ID
FROM DOCUMENT_CHUNKS
WHERE CHUNK_ID IS NULL OR DOCUMENT_NAME IS NULL OR CHUNK_NUMBER IS NULL
   OR CHUNK_BODY IS NULL OR TRIM(CHUNK_BODY) = ''
   OR SEARCHABLE_TEXT IS NULL OR TRIM(SEARCHABLE_TEXT) = ''
   OR SEARCHABLE_TEXT IS DISTINCT FROM (
       COALESCE(HEADER_1 || CHR(10), '') ||
       COALESCE(HEADER_2 || CHR(10), '') ||
       COALESCE(HEADER_3 || CHR(10), '') ||
       CHUNK_BODY
   )
ORDER BY DOCUMENT_NAME, CHUNK_NUMBER;

-- Inspect the corrected hierarchy and genuine Extended Warranty subsections.
SELECT DOCUMENT_NAME, CHUNK_NUMBER, HEADER_1, HEADER_2, HEADER_3,
       LEFT(SEARCHABLE_TEXT, 250) AS SEARCHABLE_PREVIEW
FROM DOCUMENT_CHUNKS
WHERE (DOCUMENT_NAME = 'Service_Procedures.pdf'
       AND REGEXP_LIKE(HEADER_1, '[4-8][.][[:blank:]]+.*'))
   OR (DOCUMENT_NAME = 'Extended_Warranty_Terms.pdf'
       AND (REGEXP_LIKE(HEADER_1, '[5-7][.][[:blank:]]+.*')
            OR HEADER_2 IN ('2.1 Eligible products', '2.2 Duration')))
ORDER BY DOCUMENT_NAME, CHUNK_NUMBER;

-- Each expected section must be represented at the intended heading level.
WITH expected_headings AS (
    SELECT COLUMN1 AS DOCUMENT_NAME, COLUMN2 AS HEADING_LEVEL,
           COLUMN3 AS HEADING
    FROM VALUES
        ('Service_Procedures.pdf', 'HEADER_1',
         '5. Warranty repair authorization'),
        ('Service_Procedures.pdf', 'HEADER_1',
         '6. Incomplete information and escalation'),
        ('Service_Procedures.pdf', 'HEADER_1',
         '7. Request record and follow-up'),
        ('Service_Procedures.pdf', 'HEADER_1',
         '8. Related documents'),
        ('Extended_Warranty_Terms.pdf', 'HEADER_1',
         '5. Extended coverage and exclusions'),
        ('Extended_Warranty_Terms.pdf', 'HEADER_1',
         '6. Service requests and repair authorization'),
        ('Extended_Warranty_Terms.pdf', 'HEADER_1',
         '7. Summary of the coverage sequence'),
        ('Extended_Warranty_Terms.pdf', 'HEADER_2',
         '2.1 Eligible products'),
        ('Extended_Warranty_Terms.pdf', 'HEADER_2',
         '2.2 Duration')
),
heading_results AS (
    SELECT
        e.DOCUMENT_NAME, e.HEADING_LEVEL, e.HEADING,
        COALESCE(COUNT_IF(
            (e.HEADING_LEVEL = 'HEADER_1' AND c.HEADER_1 = e.HEADING)
            OR (e.HEADING_LEVEL = 'HEADER_2' AND c.HEADER_2 = e.HEADING)
        ), 0) AS MATCHING_CHUNKS
    FROM expected_headings AS e
    LEFT JOIN DOCUMENT_CHUNKS AS c ON c.DOCUMENT_NAME = e.DOCUMENT_NAME
    GROUP BY e.DOCUMENT_NAME, e.HEADING_LEVEL, e.HEADING
)
SELECT
    DOCUMENT_NAME, HEADING_LEVEL, HEADING, MATCHING_CHUNKS,
    IFF(MATCHING_CHUNKS > 0, 'PASS', 'REVIEW') AS HEADING_STATUS
FROM heading_results
ORDER BY DOCUMENT_NAME, HEADING_LEVEL, HEADING;

-- Both parts of Service Section 4 should remain under its top-level heading.
SELECT
    COALESCE(COUNT_IF(
        HEADER_1 = '4. Service team review'
        AND CONTAINS(CHUNK_BODY, '3. Reviewing the fault description')
    ), 0) AS PAGE_2_REVIEW_ITEM_CHUNKS,
    COALESCE(COUNT_IF(
        HEADER_1 = '4. Service team review'
        AND CONTAINS(
            CHUNK_BODY, 'The review is based on the information available.'
        )
    ), 0) AS SECTION_4_END_CHUNKS
FROM DOCUMENT_CHUNKS
WHERE DOCUMENT_NAME = 'Service_Procedures.pdf';

-- Zero rows expected. Unexpected document names are reported separately.
SELECT DISTINCT DOCUMENT_NAME
FROM DOCUMENT_CHUNKS
WHERE DOCUMENT_NAME NOT IN (
    'Product_Warranty_Policy.pdf',
    'Service_Procedures.pdf',
    'Extended_Warranty_Terms.pdf'
) OR DOCUMENT_NAME IS NULL;
