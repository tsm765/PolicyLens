-- PolicyLens Section 03: verify the approved PDF inventory in DOCUMENT_STAGE.
-- Run all statements in order in a Snowsight SQL worksheet.
-- This checks file names and directory metadata only. It does not read PDF
-- contents, verify document versions, or parse documents.

-- 1. Use the existing PolicyLens compute and namespace.
USE WAREHOUSE POLICYLENS_WH;
USE DATABASE POLICYLENS_DB;
USE SCHEMA APP;

-- 2. Show files physically present in the named internal stage.
LIST @DOCUMENT_STAGE;

-- 3. Synchronize the manually refreshed directory table with the stage.
ALTER STAGE DOCUMENT_STAGE REFRESH;

-- 4. Inspect the refreshed directory metadata for every staged file.
SELECT RELATIVE_PATH, SIZE, LAST_MODIFIED, FILE_URL
FROM DIRECTORY(@DOCUMENT_STAGE)
ORDER BY RELATIVE_PATH;

-- 5. Missing expected PDFs. A result with zero rows means none are missing.
WITH expected AS (
    SELECT column1 AS relative_path
    FROM VALUES
        ('Product_Warranty_Policy.pdf'),
        ('Service_Procedures.pdf'),
        ('Extended_Warranty_Terms.pdf')
),
actual AS (
    SELECT RELATIVE_PATH FROM DIRECTORY(@DOCUMENT_STAGE)
)
SELECT e.relative_path AS missing_expected_file
FROM expected AS e
LEFT JOIN actual AS a ON a.relative_path = e.relative_path
WHERE a.relative_path IS NULL
ORDER BY e.relative_path;

-- 6. Unexpected files, including files in subpaths. Zero rows means none.
WITH expected AS (
    SELECT column1 AS relative_path
    FROM VALUES
        ('Product_Warranty_Policy.pdf'),
        ('Service_Procedures.pdf'),
        ('Extended_Warranty_Terms.pdf')
),
actual AS (
    SELECT RELATIVE_PATH FROM DIRECTORY(@DOCUMENT_STAGE)
)
SELECT a.relative_path AS unexpected_extra_file
FROM actual AS a
LEFT JOIN expected AS e ON e.relative_path = a.relative_path
WHERE e.relative_path IS NULL
ORDER BY a.relative_path;

-- 7. PASS requires exactly three files, all expected and no extras.
WITH expected AS (
    SELECT column1 AS relative_path
    FROM VALUES
        ('Product_Warranty_Policy.pdf'),
        ('Service_Procedures.pdf'),
        ('Extended_Warranty_Terms.pdf')
),
actual AS (
    SELECT RELATIVE_PATH FROM DIRECTORY(@DOCUMENT_STAGE)
),
missing AS (
    SELECT e.relative_path
    FROM expected AS e
    LEFT JOIN actual AS a ON a.relative_path = e.relative_path
    WHERE a.relative_path IS NULL
),
unexpected AS (
    SELECT a.relative_path
    FROM actual AS a
    LEFT JOIN expected AS e ON e.relative_path = a.relative_path
    WHERE e.relative_path IS NULL
)
SELECT
    IFF(
        (SELECT COUNT(*) FROM actual) = 3
        AND (SELECT COUNT(*) FROM missing) = 0
        AND (SELECT COUNT(*) FROM unexpected) = 0,
        'PASS', 'FAIL'
    ) AS inventory_status,
    (SELECT COUNT(*) FROM actual) AS actual_file_count,
    (SELECT COUNT(*) FROM missing) AS missing_file_count,
    (SELECT COUNT(*) FROM unexpected) AS unexpected_file_count;
