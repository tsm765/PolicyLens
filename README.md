# PolicyLens

PolicyLens is a Snowflake-native retrieval-augmented generation (RAG) assistant for fictional industrial equipment warranty policies. It answers policy questions with cited passages and abstains when the retrieved documents do not support an answer.

> **Fictional-policy disclaimer:** Asteron Equipment and its policies are fictional. PolicyLens is an informational portfolio project; it does not approve claims or make final warranty eligibility decisions.

## Problem and approach

Warranty terms, exclusions, and service steps are spread across multiple documents. PolicyLens brings the relevant passages together so a reader can check an answer against its sources.

**PDFs → Snowflake document parsing and chunking → Cortex Search → AI_COMPLETE → Streamlit answer and citations**

The initial knowledge base contains three approved PDFs in [`sample_data/pdfs/`](sample_data/pdfs/): Product Warranty Policy, Service Procedures, and Extended Warranty Terms. Snowflake parsed six pages and stores 32 section-aware chunks (11, 12, and 9 respectively). The app retrieves up to five chunks, asks `AI_COMPLETE` for a structured grounded response to general questions, and rejects citation IDs that were not retrieved. Explicit standard-warranty date questions use Python calendar-month arithmetic with durations taken from retrieved policy text.

## Technology

- **Snowflake:** internal stage, `AI_PARSE_DOCUMENT`, SQL transformations, `DOCUMENT_CHUNKS`, Cortex Search, and `AI_COMPLETE`
- **Python:** Snowflake Python APIs, grounded answer pipeline, and evaluation scripts
- **Streamlit:** local question-and-answer interface with expandable cited passages
- **Terraform:** configuration-driven import of three pre-existing foundation resources

## Run locally

The app requires an existing Snowflake environment with `POLICYLENS_DB.APP.POLICYLENS_SEARCH`, `POLICYLENS_WH`, the parsed/chunked document data, and permission to query Cortex Search and use `AI_COMPLETE`. Snowflake requests can incur charges. Configure a **local** Snowflake Connector named connection called `policylens`; keep its credentials outside this repository. See [Snowflake's named-connection guide](https://docs.snowflake.com/en/developer-guide/python-connector/python-connector-connect).

Verified locally with Python 3.14. From the repository root:

```powershell
python -m venv .venv
& .\.venv\Scripts\python.exe -m pip install -r requirements.txt
& .\.venv\Scripts\python.exe -m streamlit run .\app\streamlit_app.py
```

The app sends a Snowflake request only after **Ask** is clicked. For an offline input check, run `python -m evaluation.run_answer_evaluation --validate-only`. The [`sql/`](sql/) scripts document stage verification, parsing, chunking, and search-service creation. The initial Snowflake foundation, PDF upload, and first document parse were performed manually; these scripts are not a one-command rebuild.

## Terraform scope

[`terraform/`](terraform/) pins the official `snowflakedb/snowflake` provider to v2.23.0 and declares import blocks for the existing `POLICYLENS_WH` warehouse, `POLICYLENS_DB` database, and `POLICYLENS_DB.APP` schema. Each resource has `prevent_destroy`. The local provider profile uses `ACCOUNTADMIN` with interactive MFA for this learning setup; credentials and state stay outside Git. The import was verified with **3 imports, 0 additions, 0 changes, and 0 destroys**, followed by a no-change plan. Importing these resources does not provision the internal stage, PDFs, parsed tables, chunks, Cortex Search service, or application. Review any future Terraform plan before applying it.

## Evaluation

The fixed [`ground_truth.csv`](evaluation/ground_truth.csv) has 20 questions: 8 direct factual, 4 conditional, 4 cross-document, and 4 unanswerable. Retrieval relevance is labeled separately in [`retrieval_evidence_labels_v1_1.csv`](evaluation/retrieval_evidence_labels_v1_1.csv), with 31 evidence units. The evaluation answers are **not** indexed in Cortex Search.

| Verified run | Result | Meaning |
| --- | --- | --- |
| V1.1 retrieval rescore, 16 answerable questions | Hit@5 **16/16**; average evidence coverage@5 **95.8%**; complete evidence@5 **14/16** | V1.1 refined one acceptable evidence label and rescored the **same saved V1 rankings** offline; it is not a retrieval improvement. |
| Full V1 answer run, 20 questions | Expected status **20/20**; unanswerable abstentions **4/4**; answered responses with citation IDs **16/16** | Automated status and presence checks only. |
| Full V1 answer run, 16 answered responses | All cited IDs belonged to retrieved chunks **16/16** | ID membership does **not** establish that a cited passage supports the answer. |

Results and intermediate targeted retests are preserved in [`evaluation/results/`](evaluation/results/). The published [ranked retrieval results](evaluation/results/retrieval_ranked_results_public.csv) and [unanswerable retrieval results](evaluation/results/unanswerable_retrieval_public.csv) omit Snowflake request IDs; the unchanged originals stay local and Git-ignored. To rerun the offline V1.1 rescore from a clone, copy `retrieval_ranked_results_public.csv` to `retrieval_ranked_results.csv` in that directory. Manual review found wrong calendar-date calculations and incomplete or terse answers in the original V1 run. Targeted code changes and retests followed, but the complete 20-question answer set has not been rerun and manually scored after those changes. The CSV fields for manual factual correctness, citation support, and cross-document completeness are unfilled; **no final factual-accuracy or citation-support rate is claimed**.

## Screenshots

| Image | View |
| --- | --- |
| [AX-200 answer and citation](screenshots/Screenshot%202026-11-15%20035055.png) | Warranty-period answer with an expanded source passage |
| [Insufficient evidence](screenshots/Screenshot%202026-11-15%20035152.png) | An unanswerable question and abstention status |
| [Maintenance exclusion answer](screenshots/Screenshot%202026-11-15%20035545.png) | Conditional answer with an expanded source passage |

The answer screenshots were captured before the interface stopped displaying full chunk IDs; the current interface shows chunk numbers instead.

## Limits and next steps

The corpus is intentionally small and fictional. Minor PDF header/footer artifacts remain in V1 chunks. The current app uses one unfiltered Top-5 search and a local named connection; broader retrieval strategies, cleaner parsed text, least-privilege deployment, and a fully scored post-refinement answer evaluation are future work.
