"""Offline regression checks for Cortex Search result validation."""

import json
import sys
import unittest
from types import ModuleType, SimpleNamespace
from unittest.mock import patch

from app.rag_pipeline import (
    GuardrailError, SnowflakeRequestError, SourcePassage, _calculated_expiry,
    _checked_completion, _prompt, _search, answer_question,
)
from app.ui_errors import user_error_message


def policy_passages(model, commissioning_months, shipment_months):
    return [
        SourcePassage(1, "policy-rule", "Product_Warranty_Policy.pdf", 4,
                      "3. Standard warranty periods", f"3.1 {model}", None,
                      f"The {model} standard warranty runs for {commissioning_months} months "
                      f"from its commissioning date, subject to a maximum of {shipment_months} "
                      "months from its shipment date. The warranty expires at whichever of "
                      "those two applicable deadlines occurs first."),
        SourcePassage(2, "calendar-rule", "Product_Warranty_Policy.pdf", 2,
                      "2. Definitions and date interpretation", None, None,
                      "A period stated in months is measured by calendar months "
                      "from the applicable start date."),
    ]


class SearchValidationTests(unittest.TestCase):
    def setUp(self):
        self.result = {
            "CHUNK_ID": "chunk-1",
            "DOCUMENT_NAME": "Product_Warranty_Policy.pdf",
            "CHUNK_NUMBER": 0,
            "SEARCHABLE_TEXT": "Warranty passage",
        }

    def search(self, result):
        service = SimpleNamespace(
            search=lambda **kwargs: SimpleNamespace(results=[result])
        )
        return _search(service, "What is covered?")

    def test_zero_chunk_number_is_valid(self):
        self.assertEqual(self.search(self.result)[0].chunk_number, 0)

    def test_missing_null_and_blank_required_fields_are_rejected(self):
        for field in self.result:
            for value in (None, "", "  "):
                with self.subTest(field=field, value=value):
                    result = {**self.result, field: value}
                    with self.assertRaisesRegex(RuntimeError, "missing evidence field"):
                        self.search(result)
            with self.subTest(field=field, value="missing"):
                result = {key: value for key, value in self.result.items() if key != field}
                with self.assertRaisesRegex(RuntimeError, "missing evidence field"):
                    self.search(result)


class ExpiryCalculationTests(unittest.TestCase):
    passages = staticmethod(policy_passages)

    def test_q09_ax100_expiry(self):
        question = ("An AX-100 shipped on 2026-01-01 and commissioned on 2027-01-01. "
                    "Which date is earlier: 24 months after commissioning or 30 months "
                    "after shipment, and when does standard coverage expire?")
        result = _calculated_expiry(question, self.passages("AX-100", 24, 30))
        self.assertEqual(result.status, "answered")
        self.assertIn("2029-01-01", result.answer)
        self.assertIn("2028-07-01", result.answer)
        self.assertIn("earlier deadline is 2028-07-01", result.answer)
        self.assertEqual(result.citation_chunk_ids, ["policy-rule", "calendar-rule"])

    def test_q10_ax200_expiry(self):
        question = ("An AX-200 shipped on 2026-03-01 and commissioned on 2026-11-01. "
                    "Which date is earlier: 18 months after commissioning or 24 months "
                    "after shipment, and when does standard coverage expire?")
        result = _calculated_expiry(question, self.passages("AX-200", 18, 24))
        self.assertEqual(result.status, "answered")
        self.assertIn("2028-05-01", result.answer)
        self.assertIn("2028-03-01", result.answer)
        self.assertIn("earlier deadline is 2028-03-01", result.answer)
        self.assertEqual(result.citation_chunk_ids, ["policy-rule", "calendar-rule"])

    def test_expiry_abstains_without_calendar_rule(self):
        question = ("An AX-100 shipped on 2026-01-01 and commissioned on 2027-01-01. "
                    "When does standard coverage expire?")
        result = _calculated_expiry(question, self.passages("AX-100", 24, 30)[:1])
        self.assertEqual(result.status, "insufficient_evidence")
        self.assertEqual(result.citation_chunk_ids, [])

    def test_commissioning_before_shipment_requires_clarification(self):
        question = ("An AX-200 shipped on 2026-11-01 and commissioned on 2026-03-01. "
                    "When does standard coverage expire?")
        result = _calculated_expiry(question, self.passages("AX-200", 18, 24))
        self.assertEqual(result.status, "insufficient_evidence")
        self.assertEqual(result.citation_chunk_ids, [])
        self.assertIn("confirm both records", result.answer)
        self.assertNotIn("expires on", result.answer)

    def test_commissioning_on_shipment_date_is_allowed(self):
        question = ("An AX-200 shipped on 2026-03-01 and commissioned on 2026-03-01. "
                    "When does standard coverage expire?")
        result = _calculated_expiry(question, self.passages("AX-200", 18, 24))
        self.assertEqual(result.status, "answered")
        self.assertIn("earlier deadline is 2027-09-01", result.answer)

    def test_undefined_month_end_boundary_abstains(self):
        question = ("An AX-200 shipped on 2026-08-31 and commissioned on 2026-08-31. "
                    "When does standard coverage expire?")
        result = _calculated_expiry(question, self.passages("AX-200", 18, 24))
        self.assertEqual(result.status, "insufficient_evidence")
        self.assertEqual(result.citation_chunk_ids, [])


class AnswerValidationTests(unittest.TestCase):
    def test_bare_yes_no_is_rejected(self):
        passage = SourcePassage(1, "policy-rule", "Product_Warranty_Policy.pdf", 1,
                                None, None, None, "Policy evidence")
        for answer in ("No", "Yes.", "no!"):
            with self.subTest(answer=answer):
                response = json.dumps({"answer": answer, "status": "answered",
                                       "citation_chunk_ids": ["policy-rule"]})
                with self.assertRaisesRegex(RuntimeError, "bare yes/no"):
                    _checked_completion(response, [passage])

        explained = json.dumps({"answer": "No, because the policy excludes that damage.",
                                "status": "answered", "citation_chunk_ids": ["policy-rule"]})
        self.assertEqual(_checked_completion(explained, [passage]).status, "answered")

    def test_invalid_citation_is_a_guardrail_failure_without_showing_answer(self):
        passage = policy_passages("AX-200", 18, 24)[0]
        raw = json.dumps({"answer": "Internal rejected answer", "status": "answered",
                          "citation_chunk_ids": ["invented-id"]})
        with self.assertRaises(GuardrailError) as caught:
            _checked_completion(raw, [passage])
        message = user_error_message(caught.exception)
        self.assertIn("no answer was shown", message)
        self.assertNotIn("Internal rejected answer", message)
        self.assertNotIn("invented-id", message)

    def test_contradictory_expiry_is_rejected(self):
        question = ("An AX-200 shipped on 2026-03-01 and commissioned on 2026-11-01. "
                    "When does standard coverage expire?")
        passages = policy_passages("AX-200", 18, 24)
        calculated = _calculated_expiry(question, passages)
        raw = json.dumps({
            "answer": "Commissioning gives 2028-05-01 and shipment gives 2028-03-01. "
                      "The earlier deadline is 2028-05-01; standard expiry is 2028-03-01.",
            "status": "answered", "citation_chunk_ids": ["policy-rule", "calendar-rule"],
        })
        with self.assertRaisesRegex(GuardrailError, "contradicted"):
            _checked_completion(raw, passages, calculated, question)

    def test_wrong_coverage_end_date_is_rejected(self):
        question = ("An AX-200 shipped on 2026-03-01 and commissioned on 2026-11-01. "
                    "When does standard coverage expire?")
        passages = policy_passages("AX-200", 18, 24)
        calculated = _calculated_expiry(question, passages)
        raw = json.dumps({
            "answer": "The shipment deadline is 2028-03-01 and the commissioning "
                      "deadline is 2028-05-01. Standard coverage ends on "
                      "2028-05-01; the earlier deadline is 2028-03-01.",
            "status": "answered", "citation_chunk_ids": ["policy-rule", "calendar-rule"],
        })
        with self.assertRaisesRegex(GuardrailError, "contradicted"):
            _checked_completion(raw, passages, calculated, question)

    def test_missing_date_rule_citation_is_rejected(self):
        question = ("An AX-200 shipped on 2026-03-01 and commissioned on 2026-11-01. "
                    "When does standard coverage expire?")
        passages = policy_passages("AX-200", 18, 24)
        calculated = _calculated_expiry(question, passages)
        raw = json.dumps({
            "answer": "The commissioning deadline is 2028-05-01 and shipment "
                      "deadline is 2028-03-01. The earlier deadline is 2028-03-01.",
            "status": "answered", "citation_chunk_ids": ["policy-rule"],
        })
        with self.assertRaisesRegex(GuardrailError, "date-rule citations"):
            _checked_completion(raw, passages, calculated, question)

    def test_swapped_deadline_labels_are_rejected(self):
        question = ("An AX-200 shipped on 2026-03-01 and commissioned on 2026-11-01. "
                    "When does standard coverage expire?")
        passages = policy_passages("AX-200", 18, 24)
        calculated = _calculated_expiry(question, passages)
        raw = json.dumps({
            "answer": "The commissioning deadline is 2028-03-01 and the shipment "
                      "deadline is 2028-05-01. The earlier standard expiry is "
                      "2028-03-01.",
            "status": "answered", "citation_chunk_ids": ["policy-rule", "calendar-rule"],
        })
        with self.assertRaisesRegex(GuardrailError, "calculated deadline"):
            _checked_completion(raw, passages, calculated, question)


class AnswerFlowTests(unittest.TestCase):
    def fake_modules(self, connection, root):
        snowflake = ModuleType("snowflake")
        snowflake.__path__ = []
        connector = ModuleType("snowflake.connector")
        connector.connect = lambda **kwargs: connection
        core = ModuleType("snowflake.core")
        core.Root = lambda active_connection: root
        return {"snowflake": snowflake, "snowflake.connector": connector,
                "snowflake.core": core}

    def test_multi_part_question_uses_calculation_and_grounded_completion(self):
        question = ("An AX-200 shipped on 2026-03-01 and commissioned on 2026-11-01. "
                    "When does standard coverage expire, and what must happen to buy "
                    "and register a 12-month extension?")
        passages = policy_passages("AX-200", 18, 24) + [
            SourcePassage(3, "extension-rule", "Extended_Warranty_Terms.pdf", 4,
                          "3. Purchase and registration timing", None, None,
                          "Both purchase and registration must be completed before "
                          "the standard warranty expires. The extension lasts 12 months."),
        ]
        raw_results = [{
            "CHUNK_ID": passage.chunk_id, "DOCUMENT_NAME": passage.document_name,
            "CHUNK_NUMBER": passage.chunk_number, "HEADER_1": passage.header_1,
            "HEADER_2": passage.header_2, "HEADER_3": passage.header_3,
            "SEARCHABLE_TEXT": passage.searchable_text,
        } for passage in passages]
        service = SimpleNamespace(search=lambda **kwargs: SimpleNamespace(results=raw_results))
        root = SimpleNamespace(databases={"POLICYLENS_DB": SimpleNamespace(schemas={
            "APP": SimpleNamespace(cortex_search_services={"POLICYLENS_SEARCH": service})
        })})
        output = json.dumps({
            "answer": "The commissioning deadline is 2028-05-01 and the shipment "
                      "deadline is 2028-03-01; the earlier standard expiry is "
                      "2028-03-01. A 12-month extension requires both purchase "
                      "and registration before that expiry.",
            "status": "answered",
            "citation_chunk_ids": ["policy-rule", "calendar-rule", "extension-rule"],
        })

        class Cursor:
            params = None

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def execute(self, sql, params):
                self.params = params

            def fetchone(self):
                return (output,)

        cursor = Cursor()

        class Connection:
            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def cursor(self):
                return cursor

        with patch.dict(sys.modules, self.fake_modules(Connection(), root)):
            result = answer_question(question, "offline-test")
        self.assertEqual(result.status, "answered")
        self.assertIn("extension", result.answer)
        self.assertIsNotNone(cursor.params)
        self.assertEqual(cursor.params[0], "llama3.3-70b")
        self.assertIn(question, cursor.params[1])
        self.assertIn('"earlier_standard_expiry": "2028-03-01"', cursor.params[1])
        self.assertIn("extension-rule", cursor.params[1])

    def test_connection_failure_has_distinct_safe_message(self):
        snowflake = ModuleType("snowflake")
        snowflake.__path__ = []
        connector = ModuleType("snowflake.connector")

        def fail_connect(**kwargs):
            raise RuntimeError("private connection detail")

        connector.connect = fail_connect
        core = ModuleType("snowflake.core")
        core.Root = lambda connection: None
        with patch.dict(sys.modules, {"snowflake": snowflake,
                                      "snowflake.connector": connector,
                                      "snowflake.core": core}):
            with self.assertRaises(SnowflakeRequestError) as caught:
                answer_question("What is covered?", "offline-test")
        message = user_error_message(caught.exception)
        self.assertIn("Snowflake", message)
        self.assertNotIn("private connection detail", message)


if __name__ == "__main__":
    unittest.main()
