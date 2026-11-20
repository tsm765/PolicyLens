-- Section 05.6: inspect the stored chunks before labeling retrieval evidence.
-- Expect 32 rows: 11 Product Warranty, 12 Service Procedures, 9 Extended Warranty.
SELECT
    CHUNK_ID,
    DOCUMENT_NAME,
    CHUNK_NUMBER,
    HEADER_1,
    HEADER_2,
    HEADER_3,
    LEFT(CHUNK_BODY, 240) AS CHUNK_BODY_PREVIEW
FROM POLICYLENS_DB.APP.DOCUMENT_CHUNKS
ORDER BY DOCUMENT_NAME, CHUNK_NUMBER;
