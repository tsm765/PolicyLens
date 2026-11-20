"""Local PolicyLens question-and-answer interface."""

import streamlit as st

from app.rag_pipeline import answer_question


CONNECTION_NAME = "policylens"  # Named local Snowflake connection; no credentials here.

st.set_page_config(page_title="PolicyLens", page_icon="🔎", layout="centered")
st.title("PolicyLens")
st.caption("Answers about fictional Asteron Equipment warranty and service policies. "
           "This is an informational aid, not a warranty approval or eligibility decision.")
st.markdown("**Your question** → **Cortex Search** → **AI_COMPLETE** → **Answer + citations**")
st.caption("Retrieval and LLM generation powered by Snowflake.")

with st.form("policy_question", enter_to_submit=False):
    question = st.text_area(
        "Warranty policy question",
        placeholder="For example: What is the AX-200 standard warranty period?",
        height=100,
    )
    asked = st.form_submit_button("Ask", type="primary")

if asked:
    st.session_state.pop("policy_answer", None)
    if not question.strip():
        st.warning("Enter a question before asking.")
    else:
        with st.spinner("Searching policy documents and generating your answer…"):
            try:
                st.session_state["policy_answer"] = answer_question(
                    question.strip(), connection_name=CONNECTION_NAME
                )
            except Exception:
                st.error("Could not get an answer from Snowflake. Check the local "
                         "connection and service access, then try again.")

result = st.session_state.get("policy_answer")
if result is not None:
    st.subheader("Answer")
    if result.status == "answered":
        st.success("Answered")
    else:
        st.info("Insufficient evidence")
    st.write(result.answer)

    if result.citation_chunk_ids:
        st.subheader("Cited policy passages")
        passages_by_id = {passage.chunk_id: passage for passage in result.source_passages}
        for chunk_id in result.citation_chunk_ids:
            passage = passages_by_id[chunk_id]
            section = " / ".join(filter(None, (
                passage.header_1, passage.header_2, passage.header_3
            ))) or "Section not labeled"
            with st.expander(f"{passage.document_name} · {section}", expanded=True):
                st.caption(f"Chunk {passage.chunk_number}")
                st.text(passage.searchable_text)
