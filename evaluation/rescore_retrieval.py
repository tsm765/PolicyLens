"""Rescore saved V1 search rankings against V1.1 evidence labels, offline.

From the repository root: python evaluation/rescore_retrieval.py
Uses only the Python standard library. No Snowflake connection is made.
"""

import math
import re
from collections import defaultdict
from pathlib import Path

from run_retrieval_baseline import load_inputs, read_csv, score, write_csv


HERE = Path(__file__).resolve().parent
RANKED = HERE / "results" / "retrieval_ranked_results.csv"
V1_METRICS = HERE / "results" / "retrieval_question_metrics.csv"
V1_1_LABELS = HERE / "retrieval_evidence_labels_v1_1.csv"
OUTPUT = HERE / "results" / "v1_1" / "retrieval_question_metrics.csv"
METRIC_FIELDS = ["question_id", "category", "evidence_units"] + [
    field for k in (3, 5) for field in (
        f"matched_units_at_{k}", f"hit_at_{k}",
        f"evidence_coverage_at_{k}", f"complete_evidence_at_{k}")
]


def load_revised_labels(questions, original):
    rows = read_csv(V1_1_LABELS, [
        "question_id", "category", "evidence_id", "acceptable_chunk_ids", "label_status"
    ])
    if len(rows) != 31:
        raise ValueError("V1.1 labels must have exactly 31 evidence units")
    old_by_id = {eid: (qid, ids) for qid, units in original.items() for eid, ids in units}
    revised = defaultdict(list)
    seen = set()
    for row in rows:
        qid, eid = row["question_id"].strip(), row["evidence_id"].strip()
        alternatives = [value.strip().lower() for value in row["acceptable_chunk_ids"].split("|")]
        if (qid not in questions or not eid or eid in seen or eid not in old_by_id
                or old_by_id[eid][0] != qid
                or row["category"].strip() != questions[qid]["category"]
                or not row["label_status"].startswith("APPROVED")
                or any(not re.fullmatch(r"[0-9a-f]{64}", value) for value in alternatives)
                or len(alternatives) != len(set(alternatives))):
            raise ValueError(f"Invalid V1.1 evidence row: {eid or qid}")
        seen.add(eid)
        revised[qid].append((eid, set(alternatives)))
    if set(revised) != set(questions) or seen != set(old_by_id):
        raise ValueError("V1.1 labels must cover the same questions and evidence units as V1")
    for units in revised.values():
        for eid, ids in units:
            old_ids = old_by_id[eid][1]
            if eid == "Q16-E03":
                if not old_ids < ids or len(ids - old_ids) != 1:
                    raise ValueError("Q16-E03 must add exactly one alternative to V1")
            elif ids != old_ids:
                raise ValueError(f"Unexpected label change: {eid}")
    return revised


def load_ranked(questions):
    rows = read_csv(RANKED, [
        "question_id", "category", "rank", "chunk_id", "document_name", "chunk_number"
    ])
    ranked = defaultdict(list)
    for row in rows:
        qid = row["question_id"].strip()
        chunk_id = row["chunk_id"].strip().lower()
        if (qid not in questions or row["category"].strip() != questions[qid]["category"]
                or not re.fullmatch(r"[0-9a-f]{64}", chunk_id)
                or not row["document_name"].strip()):
            raise ValueError(f"Invalid ranked result for {qid}")
        try:
            rank = int(row["rank"])
            chunk_number = int(row["chunk_number"])
        except ValueError as exc:
            raise ValueError(f"Invalid rank or chunk number for {qid}") from exc
        if chunk_number < 1:
            raise ValueError(f"Invalid chunk number for {qid}")
        ranked[qid].append((rank, chunk_id))
    if set(ranked) != set(questions):
        raise ValueError("Ranked results must cover all 16 answerable questions")
    for qid, items in ranked.items():
        items.sort()
        if ([rank for rank, _ in items] != [1, 2, 3, 4, 5]
                or len({chunk_id for _, chunk_id in items}) != 5):
            raise ValueError(f"{qid}: expected ranks 1–5 with distinct chunk IDs")
    return {qid: [chunk_id for _, chunk_id in items] for qid, items in ranked.items()}


def check_v1_baseline(calculated, questions):
    saved = read_csv(V1_METRICS, METRIC_FIELDS)
    if len(saved) != 16 or {row["question_id"] for row in saved} != set(questions):
        raise ValueError("Saved V1 metrics must contain one row per answerable question")
    by_id = {row["question_id"]: row for row in calculated}
    for row in saved:
        qid = row["question_id"]
        if row["category"] != by_id[qid]["category"]:
            raise ValueError(f"Saved V1 category mismatch for {qid}")
        for field in METRIC_FIELDS[2:]:
            try:
                agrees = math.isclose(float(row[field]), float(by_id[qid][field]), abs_tol=1e-9)
            except ValueError as exc:
                raise ValueError(f"Invalid saved V1 metric {field} for {qid}") from exc
            if not agrees:
                raise ValueError(f"Saved V1 metric mismatch: {qid} {field}")


def print_comparison(v1, v1_1):
    for category in ["ALL"] + sorted({row["category"] for row in v1}):
        old = [row for row in v1 if category == "ALL" or row["category"] == category]
        new = [row for row in v1_1 if category == "ALL" or row["category"] == category]
        n = len(old)
        print(f"{category} (n={n}), V1 -> V1.1")
        for k in (3, 5):
            hits = [sum(row[f"hit_at_{k}"] for row in group) for group in (old, new)]
            complete = [sum(row[f"complete_evidence_at_{k}"] for row in group) for group in (old, new)]
            coverage = [sum(row[f"evidence_coverage_at_{k}"] for row in group) / n
                        for group in (old, new)]
            print(f"  @{k} Hit {hits[0]}/{n} -> {hits[1]}/{n}; "
                  f"Coverage {coverage[0]:.1%} -> {coverage[1]:.1%}; "
                  f"Complete {complete[0]}/{n} -> {complete[1]}/{n}")
    old_q16 = next(row for row in v1 if row["question_id"] == "Q16")
    new_q16 = next(row for row in v1_1 if row["question_id"] == "Q16")
    print("Q16 evidence units matched, V1 -> V1.1")
    for k in (3, 5):
        print(f"  @{k} {old_q16[f'matched_units_at_{k}']}/{old_q16['evidence_units']} "
              f"-> {new_q16[f'matched_units_at_{k}']}/{new_q16['evidence_units']}")


def main():
    questions, original = load_inputs()
    revised = load_revised_labels(questions, original)
    ranked = load_ranked(questions)
    v1 = [score(qid, row["category"], ranked[qid], original[qid])
          for qid, row in questions.items()]
    check_v1_baseline(v1, questions)
    v1_1 = [score(qid, row["category"], ranked[qid], revised[qid])
            for qid, row in questions.items()]
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    write_csv(OUTPUT, v1_1, METRIC_FIELDS)
    print_comparison(v1, v1_1)
    print(f"Saved V1.1 metrics to {OUTPUT}")


if __name__ == "__main__":
    main()
