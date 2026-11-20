"""Run PolicyLens answer evaluation without overwriting the V1 baseline.

From the repository root, use --validate-only for an offline input check.
Live runs require a named local Snowflake connection and make one Cortex
Search and (when evidence is found) one AI_COMPLETE request per question.
"""

import argparse
import csv
import json
from dataclasses import asdict
from pathlib import Path

from app.rag_pipeline import answer_question
from evaluation.run_retrieval_baseline import read_csv


GROUND_TRUTH = Path(__file__).resolve().parent / "ground_truth.csv"
BASELINE_OUTPUT = Path(__file__).resolve().parent / "results" / "answer_generation_v1.csv"
DEFAULT_OUTPUT = Path(__file__).resolve().parent / "results" / "answer_generation_v1_1.csv"
COLUMNS = [
    "question_id", "category", "question", "expected_answerable", "expected_status",
    "generated_answer", "status", "cited_chunk_ids", "retrieved_chunk_ids",
    "retrieved_passages_json", "status_matches_expected", "citation_id_valid",
    "answered_has_citations", "expected_answer", "required_facts", "source_sections",
    "manual_factual_correctness", "manual_citation_support",
    "manual_cross_document_completeness", "manual_notes", "error",
]


def load_questions():
    rows = read_csv(GROUND_TRUTH, [
        "question_id", "category", "question", "answerable", "expected_answer",
        "required_facts", "source_sections",
    ])
    ids = [row["question_id"].strip() for row in rows]
    if len(rows) != 20 or set(ids) != {f"Q{i:02d}" for i in range(1, 21)}:
        raise ValueError("ground_truth.csv: expected unique question IDs Q01 through Q20")
    if any(not row["category"].strip() or not row["question"].strip()
           or row["answerable"].strip().lower() not in {"true", "false"}
           for row in rows):
        raise ValueError("ground_truth.csv: blank question/category or invalid answerable value")
    answerable = sum(row["answerable"].strip().lower() == "true" for row in rows)
    if answerable != 16 or any(
        (row["category"].strip() == "unanswerable") !=
        (row["answerable"].strip().lower() == "false") for row in rows
    ):
        raise ValueError("ground_truth.csv: expected 16 answerable and 4 unanswerable questions")
    return rows


def evaluate_one(question, connection_name, model):
    expected_answerable = question["answerable"].strip().lower() == "true"
    row = {
        "question_id": question["question_id"].strip(),
        "category": question["category"].strip(),
        "question": question["question"].strip(),
        "expected_answerable": expected_answerable,
        "expected_status": "answered" if expected_answerable else "insufficient_evidence",
        "expected_answer": question["expected_answer"],
        "required_facts": question["required_facts"],
        "source_sections": question["source_sections"],
    }
    try:
        result = answer_question(row["question"], connection_name, model)
        cited = result.citation_chunk_ids
        retrieved = [passage.chunk_id for passage in result.source_passages]
        row.update({
            "generated_answer": result.answer,
            "status": result.status,
            "cited_chunk_ids": "|".join(cited),
            "retrieved_chunk_ids": "|".join(retrieved),
            "retrieved_passages_json": json.dumps(
                [asdict(passage) for passage in result.source_passages], ensure_ascii=False
            ),
            "status_matches_expected": result.status == row["expected_status"],
            "citation_id_valid": len(cited) == len(set(cited)) and set(cited) <= set(retrieved),
            "answered_has_citations": bool(cited) if result.status == "answered" else "",
        })
    except Exception as exc:
        row["error"] = f"{type(exc).__name__}: {exc}"
    return row


def print_summary(rows):
    groups = {"ALL": rows}
    for category in sorted({row["category"] for row in rows}):
        groups[category] = [row for row in rows if row["category"] == category]
    for name, group in groups.items():
        successful = [row for row in group if not row.get("error")]
        answered = [row for row in successful if row["status"] == "answered"]
        print(
            f"{name}: {len(group)} questions, {len(group) - len(successful)} errors; "
            f"status match {sum(row['status_matches_expected'] for row in successful)}/{len(successful)}; "
            f"valid citation IDs {sum(row['citation_id_valid'] for row in successful)}/{len(successful)}; "
            f"answered with citations {sum(row['answered_has_citations'] for row in answered)}/{len(answered)}"
        )
    print("Factual correctness, citation support, and cross-document completeness require manual review.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--connection", help="Name in local Snowflake connections.toml")
    parser.add_argument("--model", default="llama3.3-70b", help="AI_COMPLETE model")
    parser.add_argument("--limit", type=int, help="Run only the first N questions")
    parser.add_argument("--question-ids", nargs="+", help="Run selected IDs, such as Q09 Q10")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT,
                        help="New CSV path; the V1 baseline cannot be overwritten")
    parser.add_argument("--validate-only", action="store_true", help="Check CSV inputs without Snowflake")
    args = parser.parse_args()
    if not args.validate_only and not args.connection:
        parser.error("--connection is required for a live run")
    if args.limit is not None and not 1 <= args.limit <= 20:
        parser.error("--limit must be between 1 and 20")
    if args.limit and args.question_ids:
        parser.error("use either --limit or --question-ids")
    if args.output.resolve() == BASELINE_OUTPUT.resolve():
        parser.error("the V1 baseline output must remain unchanged")

    questions = load_questions()
    if args.question_ids:
        ids = [question_id.upper() for question_id in args.question_ids]
        if len(ids) != len(set(ids)) or set(ids) - {row["question_id"] for row in questions}:
            parser.error("--question-ids must contain distinct IDs from Q01 through Q20")
        selected = [row for row in questions if row["question_id"] in ids]
    else:
        selected = questions[:args.limit] if args.limit else questions
    if args.validate_only:
        print(f"Validated {len(questions)} questions: 16 answerable, 4 unanswerable; "
              f"{len(selected)} selected for a live run.")
        return

    args.output.parent.mkdir(parents=True, exist_ok=True)
    results = []
    with args.output.open("x", newline="", encoding="utf-8") as file:
        writer = csv.DictWriter(file, fieldnames=COLUMNS)
        writer.writeheader()
        for question in selected:
            row = evaluate_one(question, args.connection, args.model)
            writer.writerow(row)
            file.flush()  # Preserve completed rows if a later question fails or the run stops.
            results.append(row)
    print_summary(results)
    print(f"Saved {len(results)} rows to {args.output}")


if __name__ == "__main__":
    main()
