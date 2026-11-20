"""Offline regression checks for Cortex Search result validation."""

import json
import unittest
from types import SimpleNamespace

from app.rag_pipeline import SourcePassage, _calculated_expiry, _checked_completion, _search


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
    def passages(self, model, commissioning_months, shipment_months):
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


if __name__ == "__main__":
    unittest.main()
