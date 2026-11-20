"""Safe, user-facing messages for PolicyLens answer failures."""

from app.rag_pipeline import GuardrailError, SnowflakeRequestError


def user_error_message(error: Exception) -> str:
    if isinstance(error, GuardrailError):
        return ("PolicyLens could not verify the answer against the retrieved "
                "sources, so no answer was shown. Please try again.")
    if isinstance(error, SnowflakeRequestError):
        return ("PolicyLens could not access Snowflake or complete the request. "
                "Check the local connector, connection, and service access, then try again.")
    return "PolicyLens could not process this question. Please try again."
