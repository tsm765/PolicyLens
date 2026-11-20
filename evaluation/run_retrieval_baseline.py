"""Run the unfiltered Top-5 Cortex Search baseline for answerable questions.

Requires the Snowflake Python APIs package (``pip install "snowflake>=0.8.0"``)
and a named connection in your local Snowflake connections.toml. From the
repository root, run:

    python evaluation/run_retrieval_baseline.py --connection YOUR_CONNECTION_NAME
    python evaluation/run_retrieval_baseline.py --validate-only

This reads two local CSVs, makes 16 search requests, and writes only to
evaluation/results/. It does not run SQL or change Snowflake objects.
"""

import argparse
import csv
from collections import defaultdict
from pathlib import Path


HERE = Path(__file__).resolve().parent
GROUND_TRUTH = HERE / "ground_truth.csv"
EVIDENCE = HERE / "retrieval_evidence_labels_v1.csv"
RESULTS = HERE / "results"
SERVICE = ("POLICYLENS_DB", "APP", "POLICYLENS_SEARCH")
COLUMNS = ["CHUNK_ID", "DOCUMENT_NAME", "CHUNK_NUMBER", "HEADER_1", "HEADER_2", "HEADER_3"]


def read_csv(path, required_columns):
    with path.open(newline="", encoding="utf-8-sig") as file:
        reader = csv.DictReader(file)
        if not reader.fieldnames or not set(required_columns) <= set(reader.fieldnames):
            raise ValueError(f"{path.name}: missing required columns {set(required_columns) - set(reader.fieldnames or [])}")
        rows = list(reader)
    if any(None in row or any(value is None for value in row.values()) for row in rows):
        raise ValueError(f"{path.name}: malformed CSV row")
    return rows


def load_inputs():
    questions = read_csv(GROUND_TRUTH, ["question_id", "category", "question", "answerable"])
    labels = read_csv(EVIDENCE, ["question_id", "category", "evidence_id", "acceptable_chunk_ids"])

    ids = [row["question_id"].strip() for row in questions]
    if len(questions) != 20 or set(ids) != {f"Q{i:02d}" for i in range(1, 21)}:
        raise ValueError("ground_truth.csv: expected unique question IDs Q01 through Q20")
    if any(row["answerable"].strip().lower() not in {"true", "false"} for row in questions):
        raise ValueError("ground_truth.csv: answerable must be true or false")
    answerable = {
        row["question_id"].strip(): row for row in questions
        if row["answerable"].strip().lower() == "true"
    }
    if len(answerable) != 16 or any(not row["question"].strip() or not row["category"].strip()
                                    for row in answerable.values()):
        raise ValueError("ground_truth.csv: expected 16 answerable questions with text and category")

    if len(labels) != 31:
        raise ValueError("retrieval_evidence_labels_v1.csv: expected 31 evidence units")
    evidence = defaultdict(list)
    evidence_ids = set()
    for row in labels:
        question_id = row["question_id"].strip()
        evidence_id = row["evidence_id"].strip()
        raw_ids = row["acceptable_chunk_ids"].split("|")
        chunk_ids = {chunk_id.strip() for chunk_id in raw_ids}
        if (question_id not in answerable or not evidence_id or evidence_id in evidence_ids
                or row["category"].strip() != answerable[question_id]["category"].strip()
                or any(not chunk_id.strip() for chunk_id in raw_ids)):
            raise ValueError(f"retrieval_evidence_labels_v1.csv: invalid evidence row {evidence_id or question_id}")
        evidence_ids.add(evidence_id)
        evidence[question_id].append((evidence_id, chunk_ids))
    if set(evidence) != set(answerable):
        raise ValueError("retrieval_evidence_labels_v1.csv: every answerable question needs evidence")
    return answerable, evidence


def score(question_id, category, ranked_ids, units):
    row = {"question_id": question_id, "category": category, "evidence_units": len(units)}
    for k in (3, 5):
        top_ids = set(ranked_ids[:k])
        matched = sum(bool(acceptable & top_ids) for _, acceptable in units)
        row[f"matched_units_at_{k}"] = matched
        row[f"hit_at_{k}"] = int(matched > 0)
        row[f"evidence_coverage_at_{k}"] = matched / len(units)
        row[f"complete_evidence_at_{k}"] = int(matched == len(units))
    return row


def write_csv(path, rows, columns):
    with path.open("w", newline="", encoding="utf-8") as file:
        writer = csv.DictWriter(file, fieldnames=columns)
        writer.writeheader()
        writer.writerows(rows)


def print_summary(metrics):
    groups = {"ALL": metrics}
    for category in sorted({row["category"] for row in metrics}):
        groups[category] = [row for row in metrics if row["category"] == category]
    for name, rows in groups.items():
        n = len(rows)
        parts = [f"{name}: n={n}"]
        for k in (3, 5):
            hits = sum(row[f"hit_at_{k}"] for row in rows)
            complete = sum(row[f"complete_evidence_at_{k}"] for row in rows)
            coverage = sum(row[f"evidence_coverage_at_{k}"] for row in rows) / n
            parts.append(f"@{k} hit={hits}/{n} coverage={coverage:.1%} complete={complete}/{n}")
        print(" | ".join(parts))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--connection", help="Name in your local Snowflake connections.toml")
    parser.add_argument("--validate-only", action="store_true", help="Validate local CSVs without Snowflake")
    args = parser.parse_args()
    if not args.validate_only and not args.connection:
        parser.error("--connection is required unless --validate-only is set")
    questions, evidence = load_inputs()
    if args.validate_only:
        categories = sorted({row["category"] for row in questions.values()})
        print(f"Answerable questions: {len(questions)}")
        print(f"Evidence units: {sum(len(units) for units in evidence.values())}")
        print(f"Question categories: {len(categories)} ({', '.join(categories)})")
        return

    from snowflake.connector import connect
    from snowflake.core import Root

    ranked_rows = []
    metrics = []
    with connect(connection_name=args.connection) as connection:
        root = Root(connection)
        service = root.databases[SERVICE[0]].schemas[SERVICE[1]].cortex_search_services[SERVICE[2]]
        for question_id, question in questions.items():
            try:
                response = service.search(query=question["question"], columns=COLUMNS, limit=5)
            except Exception as exc:
                raise RuntimeError(f"Cortex Search failed for {question_id}: {exc}") from exc
            results = response.results
            if not results or len(results) > 5:
                raise RuntimeError(f"{question_id}: expected 1–5 search results, got {len(results)}")

            ranked_ids = []
            for rank, result in enumerate(results, start=1):
                if not isinstance(result, dict):
                    raise RuntimeError(f"{question_id} rank {rank}: malformed search result")
                result = {key.upper(): value for key, value in result.items()}
                if any(result.get(key) in (None, "") for key in ("CHUNK_ID", "DOCUMENT_NAME", "CHUNK_NUMBER")):
                    raise RuntimeError(f"{question_id} rank {rank}: missing chunk identity")
                chunk_id = str(result["CHUNK_ID"])
                ranked_ids.append(chunk_id)
                matched_ids = [evidence_id for evidence_id, acceptable in evidence[question_id]
                               if chunk_id in acceptable]
                ranked_rows.append({
                    "question_id": question_id,
                    "category": question["category"],
                    "rank": rank,
                    "request_id": response.request_id,
                    **{column.lower(): result.get(column, "") for column in COLUMNS},
                    "matched_evidence_ids": "|".join(matched_ids),
                })
            if len(set(ranked_ids)) != len(ranked_ids):
                raise RuntimeError(f"{question_id}: duplicate chunk IDs in search results")
            metrics.append(score(question_id, question["category"], ranked_ids, evidence[question_id]))

    RESULTS.mkdir(exist_ok=True)
    write_csv(RESULTS / "retrieval_ranked_results.csv", ranked_rows,
              ["question_id", "category", "rank", "request_id"]
              + [column.lower() for column in COLUMNS] + ["matched_evidence_ids"])
    write_csv(RESULTS / "retrieval_question_metrics.csv", metrics,
              ["question_id", "category", "evidence_units"]
              + [field for k in (3, 5) for field in (
                  f"matched_units_at_{k}", f"hit_at_{k}",
                  f"evidence_coverage_at_{k}", f"complete_evidence_at_{k}")])
    print_summary(metrics)
    print(f"Saved results in {RESULTS}")


if __name__ == "__main__":
    main()
