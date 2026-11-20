"""Save unfiltered Top-5 Cortex Search results for Q17–Q20 without scoring.

Run from the repository root with a locally configured Snowflake connection:
    python evaluation/inspect_unanswerable_retrieval.py --connection NAME
"""

import argparse

from run_retrieval_baseline import GROUND_TRUTH, RESULTS, SERVICE, read_csv, write_csv


COLUMNS = [
    "CHUNK_ID", "DOCUMENT_NAME", "CHUNK_NUMBER",
    "HEADER_1", "HEADER_2", "SEARCHABLE_TEXT",
]
OUTPUT = RESULTS / "unanswerable_retrieval.csv"


def load_questions():
    rows = read_csv(GROUND_TRUTH, ["question_id", "question", "answerable"])
    if any(row["answerable"].strip().lower() not in {"true", "false"} for row in rows):
        raise ValueError("ground_truth.csv: answerable must be true or false")
    questions = [row for row in rows if row["answerable"].strip().lower() == "false"]
    if len(questions) != 4 or {row["question_id"] for row in questions} != {
        "Q17", "Q18", "Q19", "Q20"
    } or any(not row["question"].strip() for row in questions):
        raise ValueError("ground_truth.csv: expected exactly four unanswerable questions, Q17–Q20")
    return questions


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--connection", required=True, help="Name in local Snowflake connections.toml")
    args = parser.parse_args()
    questions = load_questions()

    from snowflake.connector import connect
    from snowflake.core import Root

    ranked_rows = []
    with connect(connection_name=args.connection) as connection:
        root = Root(connection)
        service = root.databases[SERVICE[0]].schemas[SERVICE[1]].cortex_search_services[SERVICE[2]]
        for question in questions:
            question_id = question["question_id"]
            try:
                response = service.search(query=question["question"], columns=COLUMNS, limit=5)
            except Exception as exc:
                raise RuntimeError(f"Cortex Search failed for {question_id}: {exc}") from exc
            results = response.results
            if not isinstance(results, list) or not 1 <= len(results) <= 5:
                count = len(results) if isinstance(results, list) else "invalid response"
                raise RuntimeError(f"{question_id}: expected 1–5 search results, got {count}")

            seen_ids = set()
            for rank, result in enumerate(results, start=1):
                if not isinstance(result, dict):
                    raise RuntimeError(f"{question_id} rank {rank}: malformed search result")
                result = {key.upper(): value for key, value in result.items()}
                if any(result.get(key) in (None, "") for key in (
                    "CHUNK_ID", "DOCUMENT_NAME", "CHUNK_NUMBER", "SEARCHABLE_TEXT"
                )):
                    raise RuntimeError(f"{question_id} rank {rank}: missing chunk data")
                chunk_id = str(result["CHUNK_ID"])
                if chunk_id in seen_ids:
                    raise RuntimeError(f"{question_id}: duplicate chunk ID in search results")
                seen_ids.add(chunk_id)
                ranked_rows.append({
                    "question_id": question_id,
                    "question": question["question"],
                    "rank": rank,
                    "request_id": response.request_id,
                    **{column.lower(): result.get(column, "") for column in COLUMNS},
                })

    RESULTS.mkdir(exist_ok=True)
    write_csv(OUTPUT, ranked_rows, ["question_id", "question", "rank", "request_id"]
              + [column.lower() for column in COLUMNS])
    print(f"Saved {len(ranked_rows)} ranked results for {len(questions)} questions to {OUTPUT}")


if __name__ == "__main__":
    main()
