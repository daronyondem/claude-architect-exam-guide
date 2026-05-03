# Claude Certified Architect - Foundations: Exam Preparation Guide

## Overview

This guide teaches the architecture knowledge needed to design, build, and operate production systems with Claude, Claude Code, the Claude Agent SDK, tools, and MCP integrations. It is intentionally scenario-oriented: the exam is likely to test trade-offs, not rote definitions.

The most important habit is to ask: where should responsibility live?

- The model is good at interpreting language, choosing among well-described options, synthesizing evidence, and adapting plans.
- Application code is responsible for deterministic guarantees: permissions, compliance thresholds, state persistence, retries, idempotency, validation, and auditability.
- Tool and schema design shape the model's behavior. A vague tool or underspecified schema creates model errors that look like "reasoning" failures but are really interface failures.

This guide avoids exam-question content. The examples are original teaching examples that illustrate the underlying concepts.

---

## 1. API Fundamentals and Output Control

### What to Know

Claude's Messages API is stateless. Claude does not remember previous API calls unless your application includes the relevant content in the next request. A production chat application must store the conversation and send the full current context on each turn: the system prompt, the selected prior messages, current application state, retrieved documents, and any tool results the model needs.

There is no magic memory flag that makes Claude remember earlier turns. A `session_id` in your own product, database, or orchestration layer can help you find stored history, but the model only sees what the request contains. If an assistant forgets facts from two turns ago in a short conversation, the most likely cause is that the application is not sending those prior messages.

As conversations grow, two things happen:

- Input token cost and latency increase because more context is sent every turn.
- The model has more competing information to attend to, including older user preferences, stale tool results, verbose RAG results, and its own earlier responses.

The Messages API uses a top-level `system` parameter for system prompts, not a `"system"` role inside `messages`. User and assistant turns go in `messages`. Tool use is represented with content blocks: assistant messages can contain `tool_use` blocks, and user messages can contain `tool_result` blocks.

### Structured Outputs and Tool Use as Output Control

Claude has two related ways to get machine-readable output:

- **JSON structured outputs** use `output_config.format` with a JSON Schema. Claude's direct text response is constrained to valid JSON matching that schema.
- **Tool use / strict tool use** constrains tool calls. You can define a tool with an input schema and read the model's `tool_use.input` as structured data, or use `strict: true` where supported to enforce tool-parameter schema compliance.

Use JSON structured outputs when the final assistant response itself should be JSON. Use tool use when the structured output represents a function call, extraction step, or intermediate agent action. These can be combined in workflows where the agent must both call tools with valid parameters and produce a structured final response.

For exam-style architecture questions, the key principle is stable: schema-backed output is more reliable than asking for free-form text that "looks like JSON."

`tool_choice` matters:

| Setting | Meaning | Use Case |
|---|---|---|
| `auto` | Claude may call a tool or answer normally | General agents where tool use is optional |
| `any` | Claude must call one of the provided tools | Extraction where the document type is unknown but one extraction tool from a defined set must be used |
| `tool` | Claude must call a specific named tool | A pipeline stage that must produce one schema before enrichment |
| `none` | Claude cannot call tools | Pure text response or a step where tools are unsafe/unneeded |

`tool_choice: "any"` is especially useful when you have several extraction tools (one per document type) and you want guaranteed tool use without choosing which schema in advance. Setting `auto` with prompt instructions to "use a tool" can still produce conversational text in edge cases; `any` cannot.

When multiple tools are available but one must run first, use `tool_choice` with a specific tool name (e.g., `{"type": "tool", "name": "extract_metadata"}`) for the first call, receive the structured result, then make subsequent calls for enrichment. Reordering tool definitions or relying on system prompt priority is unreliable.

For extraction systems, common patterns are:

1. Use `output_config.format` with a JSON Schema when you want the response body to be validated JSON.
2. Define an extraction tool whose input schema is the desired output schema when the extraction is modeled as a tool call.
3. Set `tool_choice` to a required tool or to `any` across several extraction tools when a tool call must happen.
4. Validate the result in application code.
5. If semantic validation fails, call Claude again with the source, the invalid extraction, and the validation errors. This validation-error feedback loop is far more effective than retrying the same prompt unchanged.

Tool definitions, tool schemas, output schemas, and tool-use/result blocks count as input tokens or add injected prompt overhead. A large schema (for example, a 12-field tool definition with detailed descriptions consuming ~2,500 tokens) combined with a long document can approach the context limit. When that happens, accuracy degrades on content near the end of the document because the model is processing close to the effective attention boundary. The root cause is total context consumption, not a model defect.

Structured outputs also have operational implications: the first request for a schema may have additional latency while the grammar is compiled; schemas are cached for reuse; very complex schemas can exceed compilation limits; refusals or max-token stops can still produce nonconforming output. Do not treat schema compliance as a substitute for domain validation.

### Partial Assistant Prefill

Claude can continue from a partially filled assistant response in some API patterns. This can be useful for response format control, such as starting directly with `{` for text JSON-style output or preventing repetitive greetings by providing a concise opening. Use this carefully: schema-constrained tool use is usually better than relying on text prefill for machine-readable output.

### Token Growth in Extended Conversations

Each new turn includes the entire conversation history in the request. As conversations grow:

- Input token count rises with every message.
- Latency rises proportionally because the model must attend to more input.
- Per-turn cost rises.

If users notice slower responses and higher costs in long sessions, the cause is almost always input token growth, not a defect in the model or database. Context management strategies (sliding window, progressive summarization, structured state) address this directly.

### Common Pitfalls

- **Assuming Claude has persistent memory.** It does not. Your app manages state and history.
- **Treating `session_id` as model memory.** A session identifier can locate stored context in your system, but it does not automatically change what Claude sees.
- **Forcing text JSON with prompt instructions when tool use is available.** Prompt-only JSON is more fragile than schema-backed tool use.
- **Ignoring tool-definition token cost.** Large tool schemas reduce the remaining budget for documents, conversation, and outputs.
- **Confusing `tool_choice: "auto"` with required tool use.** `auto` allows tools; only `any` or a named tool guarantees a tool call.

### Original Example

Suppose a maintenance report parser must return:

```json
{
  "site_name": "string",
  "reported_by": "string|null",
  "observed_issues": ["string"],
  "service_visits": [
    {
      "technician": "string",
      "work_performed": "string",
      "visit_date": "YYYY-MM-DD|null"
    }
  ]
}
```

The reliable design is not "Respond only with valid JSON." Define an `extract_candidate_profile` tool with that schema, force that tool, and validate the resulting input object. If validation fails because a date is malformed, feed back the exact validation error rather than retrying blindly.

---

## 2. Designing Tool Interfaces for LLM Agents

### What to Know

An agent selects tools from their names, descriptions, parameter schemas, and examples. Tool design is prompt design plus API design. A good tool interface makes the right action easy and the wrong action difficult or impossible.

Good tool descriptions explain:

- What the tool does.
- When to use it.
- When not to use it.
- Required input formats.
- What the output contains.
- Important limitations and safety concerns.

For complex tools, include `input_examples` when supported. Examples are especially helpful for nested objects, date formats, identifiers, and domain-specific enums.

### Parameter Design

Prefer parameters that match the operation's real domain model. Do not ask the model to reconstruct business invariants from a bag of strings.

Use enums for stable, closed sets:

```json
{
  "source": {
    "type": "string",
    "enum": ["knowledge_base", "billing_records", "support_tickets"],
    "description": "Which repository to search."
  }
}
```

Use lookup-then-act when users refer to entities by ambiguous names:

1. `search_projects(query)` returns project IDs and distinguishing metadata.
2. `archive_project(project_id)` acts only on an unambiguous ID.

When the lookup returns multiple candidates and the agent cannot confidently pick one, prefer presenting the candidates to the user with differentiating fields (creation date, owner, last activity, location) so the user can confirm which one is meant. A "single-click" UI selection — the user sees three candidates, picks one, and the agent proceeds with the chosen ID — is far more reliable than asking the model to guess and run a destructive operation. This pattern is complementary to preview-then-execute: disambiguation resolves *which entity* the user means, preview-then-execute confirms *what action* will happen to it.

Prefer stable identifiers over derived intermediate values. If the user already has a `device_id`, a downstream tool should usually accept `device_id` rather than requiring the agent to call a previous tool just to extract a serial number or location. Let the tool resolve mechanical dependencies internally when model judgment is not needed.

Split tools when parameters have interdependent constraints. If a workout can be cardio or strength, a single `log_workout(type, value, unit)` tool invites invalid combinations. Separate `log_cardio_session` and `log_strength_session` tools make the schema itself encode the distinction.

When one operation type has different required fields from another, use separate tools. A unified `manage_order(action, ...)` tool causes omitted parameters and irrelevant fields. Separate `issue_store_credit`, `cancel_subscription`, and `replace_damaged_item` tools give Claude a simpler choice and a cleaner schema.

### Output Design

Tool results should be structured, compact, and useful for the next decision. Include identifiers that downstream tools can use.

Weak output:

```text
Found these documents: Maintenance Schedule, Lab Access Plan, Vendor Notes.
```

Better output:

```json
{
  "results": [
    {
      "document_id": "doc_284",
      "title": "Maintenance Schedule",
      "owner": "operations",
      "updated_at": "2026-04-20"
    }
  ],
  "total_matches": 1
}
```

Normalize heterogeneous backend data before returning it to the agent. If three carriers represent shipment status differently, the tool should return a consistent schema such as `status`, `estimated_delivery`, `delay_reason`, and `requires_action`. Do not force the model to learn carrier-specific code mappings from raw payloads.

Distinguish a successful empty result from an error. "No matches found" should be a successful result with an empty `results` array, not an `isError` tool result. Otherwise the agent may retry a valid query as though the tool failed.

For paginated APIs, do not automatically fetch hundreds of items if the user may only need the first page. Return the first page, `total_count`, and a cursor or continuation token. Fetch more only if needed.

### Tool Composition

Combine operations only when doing so preserves the model's required judgment.

Good candidates for composition:

- Mechanical sequences where no decision is needed between steps.
- Latency-heavy repeated lookups that always happen together.
- Atomic operations where separate calls create race conditions (for example, "check availability and book" must be atomic when other users may grab the slot between two separate calls).

Keep steps separate when the model must inspect intermediate results before deciding. Selection, judgment, and editorial choice belong outside composite tools.

Original examples:

- A news-curation agent can use a composite `discover_and_score_articles(topic)` tool that returns candidates plus relevance scores, while leaving `add_article_to_collection(article_id)` separate because editorial selection requires judgment.
- A booking system should combine "check availability" and "reserve slot" into one atomic `find_and_book_appointment` operation when separate calls risk another user taking the slot between calls. Adding a `hold_slot` tool can work but introduces a new race window and an extra step.
- A research workflow should not combine "retrieve sources" and "write final conclusion" because the model needs to inspect the sources and preserve provenance.

When a downstream tool keeps requiring an upstream tool's output for a mechanical reason (for example, fetching the address of a property just to pass it to a neighborhood-info tool), redesign the downstream tool to accept the stable identifier directly and resolve the address internally. This eliminates the latency of an unnecessary lookup and the failure coupling when the upstream call fails.

### Pagination

External APIs often return paginated results. Auto-fetching every page is rarely the right behavior:

- It causes long latency for queries that match many results.
- It wastes tokens when the user only needs the first few items.
- It can blow context when matches are very large.

Better design: return the first page, a `total_count` (or estimate), and a cursor or continuation token. Let the agent or user request more pages only when necessary.

### Large Tool Sets and Progressive Availability

Tool selection degrades when the model must choose among too many similar tools. Empirically, accuracy drops noticeably as the tool count grows past a handful of similar options. If an agent has dozens of external connectors, API operations, or domain-specific tools, do not expose everything at once by default.

Use progressive availability:

1. Start with a small set of discovery tools, such as `search_available_connectors` or `find_relevant_operations`.
2. Return a ranked shortlist with names, descriptions, required inputs, and confidence.
3. Dynamically add the selected matching tools to the agent's available tools so it can call them on subsequent turns. Once discovered, the relevant tools persist and the agent uses them like any other tool.

This is different from a monolithic `find_and_execute` tool. Search-and-execute hides the final decision and can perform the wrong action too early. A discovery tool should narrow the choices; the agent or user should still be able to inspect the selected operation before execution when risk is meaningful.

The Claude Agent SDK supports this pattern natively through tool search and dynamic tool registration. MCP servers can also notify clients when their tool list changes, allowing connected agents to refresh their view of available tools without reconnecting.

### Output: requires_review and Decision Hints

When tool outputs include uncertainty (for example, ML extractions with confidence scores), do not just return raw confidence and ask the model to interpret it. Calibrate thresholds against a labeled validation set and return both the data and a derived `requires_review` boolean with reasons:

```json
{
  "fields": {
    "vendor": {"value": "Acme Corp", "confidence": 0.94},
    "amount": {"value": 1280.5, "confidence": 0.62}
  },
  "requires_review": true,
  "review_reasons": ["amount_below_confidence_threshold"]
}
```

Raw scores invite both over-trust and over-escalation. Calibrated thresholds produce consistent agent behavior.

For confirmation flows, the tool should also return enough structured detail that the user can see what they are confirming: cost, target, schedule, irreversible effects, scope, and anything else needed to catch a mistake. A "Ready to post. Confirm?" prompt with no details is unsafe even when users always click yes.

### Safety and Confirmation

Prompt instructions are not enough for destructive actions. If an operation must always be previewed before execution, do not use `dry_run: boolean` on a single tool. The model can call the tool with `dry_run: false`.

Use a structural pattern:

1. `preview_delete_workspace(workspace_id)` returns the impact and a one-time confirmation token.
2. The user reviews the impact.
3. `execute_delete_workspace(workspace_id, confirmation_token)` requires the token and verifies it matches the previewed action.

Confirmation content must be meaningful. A prompt that says "Confirm?" is weak. Show the target account, irreversible effects, cost, schedule, destination, and anything a user would need to catch a mistake.

For ambiguous destructive operations, first resolve the target. If a CRM contains several similarly named contacts, show the candidates with differentiating fields and require the user to choose the intended record.

### Common Pitfalls

- **Encoding format hints in parameter names.** Use descriptions and schemas, not names like `date_string_iso_yyyy_mm_dd`.
- **Making everything a free-text string.** Free text increases ambiguity and invalid combinations.
- **Returning only human-readable prose.** Downstream tools need IDs and structured fields.
- **Combining decision points.** Composite tools are good for mechanical work, not for hiding choices from the model.
- **Assuming annotations or descriptions enforce security.** Security belongs in code, hooks, permissions, and tool logic.

---

## 3. Error Handling in Agent Tools

### What to Know

Tool errors shape agent behavior. A generic failure message forces the model to guess whether it should retry, ask the user, escalate, or stop. Production tools should classify failures and return enough context for the agent to respond appropriately.

Use these categories:

| Category | Example | Correct Handling |
|---|---|---|
| Transient infrastructure | Timeout, 503, connection reset | Retry inside the tool with backoff when safe |
| Permanent validation | Bad date, invalid enum, malformed ID | Return structured details so the agent can correct or ask |
| Business rule | Not eligible, duplicate, insufficient balance | Return non-retryable error with user-facing explanation |
| Permission | Authenticated user lacks access | Return non-retryable error and escalation/permission path |
| Uncertain write state | Timeout after submitting payment or notification | Report uncertainty and avoid automatic retry |

The tool should absorb recoverable infrastructure noise when it can. If a read-only API times out and immediate retries usually succeed, retry inside the tool. The model does not need to see the first failed network attempt.

Do not retry blindly when an operation may have already caused a side effect. If a payment, notification, order, or posting request times out after submission, the tool may not know whether it succeeded. Return a structured uncertain-state result and tell the agent not to retry without an idempotency key or explicit user decision.

### Structured Error Results

Return application-level errors as normal tool results, not uncaught exceptions. In MCP, tool execution errors use `isError: true`; protocol-level failures use JSON-RPC errors.

Example application-level error:

```json
{
  "isError": true,
  "content": [
    {
      "type": "text",
      "text": "{\"error_category\":\"business_rule\",\"retryable\":false,\"code\":\"warranty_window_closed\",\"customer_explanation\":\"This device is outside the standard warranty window.\",\"next_steps\":[\"offer_paid_repair\",\"escalate_for_exception_review\"]}"
    }
  ]
}
```

A cleaner internal representation might be:

```json
{
  "success": false,
  "error_category": "validation",
  "retryable": false,
  "field": "shipping_postal_code",
  "message": "Postal code must be 5 digits for US addresses.",
  "user_repair": "Ask the user to confirm the postal code."
}
```

### MCP Error Tiers

MCP tools have two error mechanisms:

- **Protocol errors**: the request could not be processed as a protocol operation. Examples: unknown tool, malformed JSON-RPC request, invalid arguments at the protocol boundary (such as a missing required parameter that the schema declares mandatory), unsupported method.
- **Tool execution errors**: the tool was invoked, but the underlying operation failed. Examples: upstream API returned 404 because the requested record does not exist, upstream API returned 503 because the service is temporarily unavailable, business rule violation, permission denial, rate limit.

Concrete example. An `check_availability(user_email)` tool faces three errors:

1. Caller omits `user_email` entirely, violating the tool's input schema. This is a **protocol error** (JSON-RPC error) — the call was not even structurally well-formed.
2. The calendar API returns 404 because the user does not exist. The tool was invoked correctly, the operation simply failed. **Tool execution error** with `isError: true`.
3. The calendar API returns 503 because the service is down. Again, the tool was invoked correctly. **Tool execution error** with `isError: true`.

Do not turn ordinary business failures into protocol failures. A missing record in the backend is not a JSON-RPC protocol failure; it is a tool execution result with `isError: true`.

### Retry Responsibility

Place retry logic where the needed information lives.

- Tool-level retry is right for transient backend failures where the same request should succeed (timeout, 503, connection reset on a read).
- Model-level retry is right when the model needs to change inputs or strategy (validation errors, syntax errors in user-provided filters, wrong identifier).
- Human approval is needed when retrying may duplicate a side effect or violate a policy.

A common production pattern: a `search_catalog` tool has 12% failures, split between transient timeouts (~8%, succeed on retry) and syntax errors in user filters (~4%, never succeed). Returning both identically wastes turns retrying syntax errors and tells users to "try again later" for timeouts. Correct design: retry transient errors inside the tool with backoff and surface only the final success or failure; surface syntax errors immediately with parameter validation details so the model can correct them or ask the user.

A `retryable: true|false` boolean alone is not as effective as actually retrying transient failures inside the tool, because it still costs a model turn and risks the agent retrying anyway.

### Uncertain Side Effects

Writes deserve special care. If a `send_notification`, `process_payment`, or `post_content` request times out **after** submission, the tool may not know whether the side effect occurred. Returning a generic error encourages automatic retry — and that creates duplicate notifications, double charges, or duplicate posts.

The right behavior:

- Mark the result as an error, but communicate uncertainty in the message: "Timeout — delivery status unknown. Message may have been sent. Avoid retry without idempotency check."
- Do not flag it as `retry_safe: true`.
- Encourage the agent to verify with a separate status lookup, or to confirm with the user before acting.

This is the inverse of read-side timeouts where retrying is usually safe.

### Common Pitfalls

- **Throwing exceptions for expected business errors.** Frameworks often hide exception details from the model.
- **Marking uncertain side effects as retryable.** This causes duplicates.
- **Returning empty data for backend failures.** An empty list means "success with no matches," not "the API failed."
- **Making the model parse free-text errors.** Give it structured fields.

---

## 4. Structured Data Extraction and Validation

### What to Know

Structured extraction is a first-class architecture problem. The goal is not merely valid JSON. The goal is data that is syntactically valid, semantically correct, traceable to the source, and safe for downstream systems.

Use schema-backed output for extraction. On current Claude APIs, that may mean `output_config.format` JSON structured outputs for direct JSON responses, or tool use/strict tool use when the extraction is represented as a tool call. Prompt-only JSON can work for low-risk prototypes, but it is not the best choice for production pipelines that feed databases, workflow engines, or audits.

### Schema Design

Schema constraints help shape the output, but they do not prove that the source supports the value. A schema can verify that `attendee_count` is an integer; it cannot verify that the article actually stated an attendee count.

Use optional or nullable fields for information that may be absent. If a field is required even when the source may not contain it, the model is pressured to fabricate. Teach the extractor to return `null`, an empty array, or an explicit absence reason when information is not stated.

Choose absence semantics deliberately:

| Situation | Schema Pattern |
|---|---|
| Field may not appear in source | Optional field or nullable value |
| List may be explicitly empty | Empty array allowed |
| List item unknown but field exists | Item with `value: null` and `reason` |
| Ambiguous classification | Add enum value such as `unclear` |
| Open-ended category set | Enum plus `other_detail`, or string plus normalization |

Closed enums are good when the domain is stable. If new categories appear constantly, a strict enum without escape hatch creates validation failures. A common design is:

```json
{
  "equipment_type": {
    "type": "string",
    "enum": ["laptop", "monitor", "printer", "network_device", "other"]
  },
  "equipment_type_detail": {
    "type": ["string", "null"],
    "description": "Original source wording when equipment_type is other."
  }
}
```

### Reducing Fabrication

Use instructions and examples that distinguish extraction from inference:

- "Extract only values stated in the source."
- "Use `null` when the source does not provide the information."
- "Do not infer missing values from typical examples."
- "Preserve informal measurements verbatim when no precise value is given."

Schema design also affects fabrication. If a field is required but the source rarely contains the information, the model is structurally pressured to invent values. Make these fields optional or nullable.

A common alternative — running a second LLM call to "verify" extracted values against the source — is generally inferior to fixing the schema. Verification calls add cost and latency, can themselves hallucinate or rationalize the original answer, and do not address the root cause: the model produced a value because the schema demanded one. Allowing `null` (or `unclear`, or `not_stated`) lets the first call signal absence directly, which is both cheaper and more honest. Use a verification pass only as a sampling-based audit on already-good extractions, not as a fix for fabrication caused by overly strict schemas.

Allow `null` rather than empty arrays when the distinction matters semantically. An empty `pros` array often reads as "the reviewer mentioned no pros," which is a real claim. `null` reads as "the document did not address pros," which is closer to the truth for very short reviews. Similarly, an enum like `["positive", "negative", "mixed"]` should grow an `unclear` value when sarcasm or ambiguity is common, so the model has a correct option instead of being forced to pick.

Few-shot examples are especially effective when the model is inconsistent across varied document structures. Show complete input-output pairs for edge cases: missing data, ambiguous sentiment, informal units, compound skills, multiple values, amendments, and values buried in nonstandard sections. They are also more effective than verbose written rules at teaching subtle distinctions: when standardized formats matter (for example, "cotton blend" vs "Cotton/Polyester mix"), 2–3 input/output examples teach the format more reliably than narrative instructions.

A specific failure pattern: a strict enum without escape hatch fails when new categories keep appearing. Add an `other` enum value with a paired `*_detail` string field for the source's actual wording. This handles long-tail categories without rewriting the schema each time a new category appears.

### Source Grounding and Provenance

For high-stakes extraction, include provenance fields:

```json
{
  "field": "termination_notice_days",
  "value": 45,
  "source_location": "Amendment 2, section 4",
  "source_quote": "The notice period is amended to forty-five days.",
  "effective_date": "2026-01-01"
}
```

This is critical when:

- Source documents contain amendments.
- Multiple sections contain conflicting values.
- Final reports need citations.
- Human reviewers must audit the model's choices.

API-level citation features can help for narrative answers over documents, but strict JSON structured outputs and citations may be incompatible because citations require interleaved citation blocks while JSON schemas require constrained JSON. When you need structured extraction plus provenance, represent source locations explicitly in your schema instead of assuming the citation feature can be attached to every JSON field.

For documents with amendments, a single scalar field may be the wrong schema. Capture original and amended values with effective dates and locations. For documents with a known precedence rule, such as "use the detailed specifications table over marketing summary text," include that rule in the extraction instructions and keep the schema simple.

### Semantic Validation

JSON Schema, structured outputs, strict tool use, and Pydantic catch type, presence, enum, and shape errors. They do not catch every semantic error. Add domain validation:

- Line items sum to totals.
- Dates fall within allowed ranges.
- IDs match known formats or known records.
- Required citations exist in the source.
- Fields are not copied into the wrong category (a duration is not an ingredient quantity, a competitor's specs are not the product's specs).

When validation fails, do not blindly retry the same request. Send a correction request that includes the source document, the previous extraction, and the exact validation errors. This is much more effective than asking the model to "try again" — and far more effective than setting `temperature: 0`, which only removes variability without addressing the underlying mismatch.

Example correction prompt structure:

```text
The extraction below failed validation.

Validation errors:
- line_items_total does not equal stated_total
- vendor_id does not match the expected pattern

Return a corrected call to extract_invoice. Do not change fields unless needed to fix the errors.
```

For fields prone to internal inconsistency (such as line items vs grand total on invoices), add explicit reconciliation fields to your schema:

```json
{
  "line_items": [...],
  "calculated_total": 1280.5,
  "stated_total": 1295.0,
  "totals_match": false
}
```

Then flag mismatches automatically. This catches both OCR errors and extraction mistakes without forcing the model to reconcile values it cannot verify.

#### When Retries Don't Help

Some failures cannot be fixed by retrying with the same input:

- The information is in an external document that was not provided to the model. Retries will only produce hallucinated values.
- The schema requires a different format than the source provides (for example, the schema requires a flat array of strings but the source organizes the data as a nested object). The model can usually fix this on retry with feedback.
- A locale-formatted number ("1,234") needs to become an integer (1234). Easily fixed on retry.
- A date is given as ISO 8601 datetime but the schema requires only the date portion. Easily fixed on retry.

The first case is the only one where additional retries are unproductive. Retrieve the missing source or route to human review instead.

### Long and Scattered Documents

Long documents can fit in the context window and still be hard to extract from when facts are scattered, repeated, or revised over time. Accuracy often improves when you split the task into stages:

1. Identify and summarize the relevant sections, decisions, tables, or events.
2. Extract structured data from that focused intermediate representation.
3. Preserve source locations so the extraction can be audited against the original.

Use chunking when documents exceed context limits or when independent sections can be processed separately. Use a pre-extraction summarization or mapping step when the document fits but the key facts are distributed across a meandering transcript, long contract, or multi-section report. Chunking alone can lose cross-section relationships; summarization alone can lose exact values. Choose based on the failure mode.

For long-but-in-context inputs (a sprawling meeting transcript, a long support thread, an unstructured incident report) where the source fits but key facts are buried among unrelated content, a model-driven pre-extraction pass usually outperforms both raw extraction with more few-shot examples and mechanical chunking. Add a first call that asks the model to surface the relevant sections — decisions, action items, named entities, dollar amounts, dates — into a structured intermediate. Then run extraction against that intermediate. The intermediate keeps the model focused on the parts that matter and substantially reduces the rate at which scattered details are missed or conflated. Few-shot examples help when extraction patterns are unusual; they do not by themselves help the model find a needle in a haystack. Chunking spreads the haystack across requests but loses cross-chunk relationships. Pre-extraction summarization preserves both.

### Confidence and Human Review

Self-reported confidence is useful only after calibration. Do not assume `confidence: 0.92` means 92% accuracy. Build a labeled validation set and measure accuracy by document type, field, source quality, and confidence band.

Better than a raw confidence score alone:

```json
{
  "amount_due": {
    "value": 1280.5,
    "confidence": 0.88,
    "requires_review": true,
    "review_reasons": ["total_mismatch", "low_ocr_quality"]
  }
}
```

Route human review based on:

- Low calibrated confidence.
- Ambiguous or contradictory source content.
- High-impact fields.
- Failed semantic validation.
- New or historically error-prone document types.

#### Validating Automation Plans

Before automating high-confidence extractions, do not just verify aggregate accuracy. A pipeline that is 97% accurate overall can still be 80% accurate on a specific document type or field. Break down accuracy by segment (document type, field, source) before raising the automation threshold. Lowering the threshold or comparing thresholds before that segment-level analysis is premature.

Even after automation begins, sample high-confidence outputs continuously. Use stratified random review of a fixed percentage to detect hidden error patterns and measure whether improvements actually reduce error rates. Lowering the threshold or relying only on downstream complaints misses systematic errors that look reasonable to humans not reading the source.

### Feedback Loops

Human corrections should feed prompt and schema improvements. Look for recurring patterns:

- Informal units being converted incorrectly.
- Compound phrases split inconsistently.
- Missing fields in nonstandard sections.
- False positives in code review findings.
- Repeated validation failures by field.

When you observe a clear recurring failure mode (for example, "informal measurements like 'a handful' or 'a splash' get either invented or omitted in 23% of corrections"), the highest-leverage change is usually adding a few-shot example demonstrating the correct handling — extracting the informal phrase verbatim. Fine-tuning, regex post-processing, or new schema fields are heavier interventions that can be considered only if focused prompt/schema improvements do not move the metric.

For dismissed code-review findings, add fields like `detected_pattern`, `rule_id`, or `evidence` so analysts can see *what kind of code construct* triggered each finding. Aggregate dismiss rates by pattern, then update the prompt criteria for the over-reporting patterns. Without that field, you can only see "35% are dismissed," not which constructs to suppress.

### Batch Extraction

For high-volume asynchronous extraction, the Message Batches API can reduce cost but adds latency. Use it when the workflow tolerates delayed results. Use real-time Messages API for urgent documents, interactive user flows, or SLA-sensitive alerts.

Batch requests have `custom_id` values. Results may not arrive in the same order as requests, so always join results by `custom_id`. If a small percentage fail due to context length or validation errors, resubmit only the failed documents after fixing the cause, such as chunking long inputs or improving the prompt.

For mixed urgency, route per-document, not per-batch. Standard documents go to the Batch API for cost savings; urgent ones go to the real-time Messages API to meet tight latency SLAs. Trying to batch everything and then expedite urgent documents inside the batch defeats the purpose — batch processing latency is the main reason urgent items cannot use it.

For one-shot bulk extraction with a deadline (for example, 50,000 documents under a two-week deadline where a meaningful percentage will need prompt iteration), submit everything to the Batch API for the bulk discount, then submit the failures in successive batches with refined prompts. Sequencing 10 sequential batches of 5,000 each costs more in calendar time and does not buy meaningful learning. Sampling first via real-time API can help characterize failure modes, but it is a small slice of the overall workload, not the main strategy.

### Common Pitfalls

- **Treating valid JSON as correct data.** Syntax validation is only the first layer.
- **Confusing schema compliance with source truth.** A constrained decoder can guarantee shape, not that the source supports the value.
- **Making absent source fields required.** This encourages hallucination.
- **Using strict enums without escape hatches in evolving domains.** Add `other` plus detail or normalize later.
- **Relying only on aggregate accuracy.** Accuracy can hide poor performance for specific fields or document types.
- **Sending all long documents through one extraction call.** Chunk, summarize first, or use staged extraction when information is scattered.

---

## 5. Conversation Context Management

### What to Know

Context management is state management. The model sees a request, not your database. You decide what to include.

The right context strategy depends on what must be preserved:

| Need | Best Strategy |
|---|---|
| Recent conversational flow | Keep recent turns verbatim |
| Long-term narrative continuity | Progressive summaries with decisions and themes |
| Current user preferences | Structured state object |
| Exact facts and numbers | Retrieval from source or structured fact store |
| Persistent creative canon | Compact "bible" or reference section |
| Tool-heavy workflows | Extract relevant fields and discard verbose payloads |

### Sliding Window

A sliding window keeps the most recent messages and drops older ones. It is simple and cheap. It works when older context is rarely needed. It fails when users refer back to earlier decisions, preferences, or exact data.

Use sliding windows when production logs show older messages are rarely referenced — for example, when 94% of user messages only reference the previous 3-5 exchanges and the remaining 6% ask about information users could easily re-state. In that traffic profile, a sliding window keeping the last 8-10 turns plus the system prompt restores response speed and quality. When users do reach back, the assistant can ask them to re-state the relevant information.

Sliding windows are also the right tool for **accumulated RAG results**. If RAG retrievals from many earlier queries pile up alongside the conversation, they crowd out turn-by-turn coherence. Apply a sliding window specifically to RAG results (keep the last 2-3 retrievals) while preserving conversation history under its own policy. Aggressive deduplication or summarizing all RAG into one digest is more complicated and rarely better.

### Progressive Summarization

Progressive summarization replaces older conversation blocks with a running summary while keeping recent turns verbatim. A useful summary is structured:

```text
Decisions:
- The user selected option B because it preserves existing integrations.

Current preferences:
- Budget target: $8,000.
- Avoid vendor lock-in.

Open questions:
- Confirm whether the migration must support offline mode.

Important facts:
- Existing system processes about 40K records per day.
```

Bad summaries are vague narratives. They lose the exact facts that users later ask about. When information matters specifically — themes of past discussions, narrative continuity across many sessions, the group's prior conclusions — summaries should explicitly extract decisions, conclusions, and recurring themes rather than producing prose that "describes the conversation."

Use a hybrid approach for ongoing conversations: replace older turns with structured summaries, keep the most recent turns verbatim. Increasing the sliding window from 25 to 50 turns is rarely the right answer; it just defers the limit. Hybrid summarization preserves long-term continuity at much lower token cost.

### Persistent Reference Sections

Some content must remain exact and stable across the whole conversation, even when the surrounding discussion is ephemeral. Examples:

- Story bibles: character backgrounds, plot structure, world rules.
- User-defined terms: "room temperature butter means 68°F in this kitchen."
- Critical safety info: allergies, medication interactions.
- Active scaling parameters: "scale all recipes to 8 servings."

Separate these into a retained reference section at the start of context. Apply trimming or summarization only to the surrounding discussion. Mixing the two and applying a single summarization pass risks losing the exact details the user expects to remain consistent.

For dinner-party-style sessions where the conversation includes both critical structured data (allergies, serving counts, definitions) and general back-and-forth (timing, presentation), the right strategy combines several techniques: extract critical data into a compact reference section, summarize general discussion, and retain recent exchanges verbatim. A pure sliding window loses the allergies; a single summary blurs the exact serving count.

### Structured State

When users revise preferences mid-conversation, maintain a canonical state object that represents current truth:

```json
{
  "workspace_search": {
    "monthly_budget_max": 4200,
    "space_type": "private_office",
    "must_have": ["bike storage", "after-hours access"],
    "no_longer_relevant": ["shared desk"]
  }
}
```

Update the object whenever the user changes a preference. Include it in each request. This is more reliable than:

- Expecting the model to infer current truth from a long conversation containing old and new values.
- Adding system prompt instructions like "always prioritize the most recently stated preferences." The model usually does, but not reliably enough.
- Pruning old turns. Pruning may remove important context for other reasons.
- Few-shot examples of "the assistant correctly applies preference changes." These help framing but do not give the model a single source of truth.

When preferences conflict, do not silently pick one if the decision matters. A user who says "I have very low risk tolerance" and later says "I want to maximize my returns like my friends did with crypto" has stated incompatible goals. The right behavior is to surface the contradiction and ask which priority should govern. A balanced compromise risks recommending something that fits neither stated preference.

The same principle applies to multi-issue customer sessions. If a customer raises three separate issues across 45 turns (a refund, a subscription question, a payment update), structured state can track each issue's current status — order ID, amounts, resolution state — independently of the linear conversation, so the agent can reliably answer "what happened with my refund?" later in the session.

### Retrieval and Fact Stores

Summaries lose precision. If users need exact p-values, source quotes, clauses, measurements, transaction IDs, or numeric thresholds, store facts in a structured database or retrieve the relevant source passage when needed.

For research assistants, combine:

- Summaries for the interpretive discussion.
- Source retrieval for exact claims.
- Structured fact tables for recurring numerical lookups.

A common pattern: a research assistant summarizes paper discussions after 8 turns to control context, but then users ask follow-up questions requiring precise numerical details (sample sizes, p-values, inclusion criteria) that the summaries blurred. Two design responses both work, but the most direct fix is to **re-inject relevant source sections on demand** when a user's question signals they need precision. A separate structured fact store of every numerical detail is heavier and may not match the variety of follow-ups; "higher fidelity summaries" that preserve all numbers tend to balloon back into the original document. On-demand retrieval scales better.

### Tool Result Compression

Verbose tool results can crowd out useful conversation. After a tool result has been processed, extract the fields that matter and drop the rest.

Example: after retrieving order details, keep `order_id`, `purchase_date`, `items`, `return_window`, `payment_status`, and `resolution_state`; discard internal backend fields, unrelated shipping events, and duplicated metadata. If a `lookup_order` tool returns 40+ fields and the agent has called it multiple times for an investigation into return requests, those tool outputs can come to dominate context. Compressing each prior order response to its return-relevant fields, then making additional lookups, is more reliable than continuing to accumulate raw responses, summarizing them all into prose, or moving them to a vector database for retrieval.

### Returning Users and Stale Data

Tool results age. A user returning hours later should not be served from stale tool outputs embedded in an old transcript. Start with a structured summary of prior interaction, then fetch fresh state before making claims about current status.

Good returning-session summary:

```json
{
  "user_issue": "billing adjustment requested",
  "prior_actions": ["validated identity", "opened case"],
  "known_ids": ["case_9138", "invoice_2044"],
  "last_known_status": "pending as of 2026-04-28T15:30:00Z",
  "fresh_lookup_required": true
}
```

Why not just resume the old session and add an instruction telling the agent to "prefer the most recent tool results"? Because the agent often references old tool results regardless of instructions, especially when the older results are more detailed than the newer ones. Filtering tool_result messages from the resumed history risks confusing the model about why earlier turns reference data it cannot see. Configuring the agent to re-call all previous tools at session start wastes calls on tools whose results may not be relevant to the new question. Starting fresh with a structured summary plus targeted fresh lookups is the most reliable pattern.

### External Updates During a Conversation

When an external system receives new information during an active chat, include the fresh state in the next model request. Depending on your architecture, this may be a system/application context block, an injected state section, or a prefix attached to the next user turn. The important principles:

- Do not expect Claude to know about events outside the request.
- Do not generate unsolicited assistant messages unless the product intentionally supports proactive notifications.
- Make current state clearly more authoritative than stale prior tool results.

### System Prompt Versioning

If you change a system prompt for users with ongoing multi-session conversations, old context may conflict with new behavior. Version system prompts and associate each conversation with the version it started under, or use a deliberate migration strategy. Applying a new persona or policy midstream can cause contradictions.

### Common Pitfalls

- **Confusing context capacity with attention.** A 200K window does not mean every detail is equally salient.
- **Summarizing exact facts into vague prose.** Use structured facts or retrieval when precision matters.
- **Keeping every RAG result forever.** Use a sliding window for retrieved context unless earlier results remain relevant.
- **Resuming old transcripts with stale tool results.** Summaries plus fresh lookups are safer.

---

## 6. System Prompt Engineering and Conversational Behavior

### What to Know

The system prompt defines role, tone, constraints, and priorities. It should be included in every request. It is not a one-time initialization message.

A common confusion is "the system prompt is sent only on the first turn and Claude remembers it." That model is wrong. Claude has no memory between API calls. The system prompt and the full message history must be sent on every request. If your application omits the system prompt on later turns, behavior will diverge from the configured persona immediately, not gradually. Likewise, prior assistant and user messages must be sent in the `messages` array, even when their content seems redundant — the model has no other way to see them.

A separate effect is real, however: even when the system prompt is included on every call, **attention to it weakens as the conversation grows.** This is not because the prompt is "dropped." It is because the model's recent assistant outputs and the latest user turns increasingly compete for attention with the system prompt. After many turns, behavior can drift even though the system prompt is unchanged and the context window is not full. The fix is structural — reinforce key instructions at natural breakpoints, version the prompt for long-lived sessions, and move hard requirements into code or tool implementations.

Good system prompts use clear sections:

```xml
<role>
You are a careful financial education assistant.
</role>

<style>
Use plain language for beginners. Match the user's demonstrated sophistication.
</style>

<safety>
If the user asks for personalized investment, legal, or medical decisions, explain limits and recommend a qualified professional where appropriate.
</safety>

<examples>
...
</examples>
```

XML-style tags are not magic, but they improve salience and organization. They are particularly helpful when the same word means different things in different contexts (a `<role>` block clearly separates persona from a `<style>` block, even if both reference "tone"), and when you want examples or constraints to be referenceable later in the conversation ("apply the rule from `<safety>`").

When external systems update state mid-session — for example, a webhook reports that an order has shipped, or a billing event flips a customer's plan — the right place to surface that change is the system prompt for the next call, not buried inside a tool result. The system prompt is the natural home for "what is currently true about this user, account, or environment." Tool results are appropriate when the agent itself called for the information; system-prompt updates are appropriate when state changed without the agent asking.

### Principles vs Conditionals

Use general principles for judgment-heavy behavior:

- "Adapt explanation depth to the user's demonstrated expertise."
- "Prefer one clarifying question at a time."
- "State reasonable assumptions when moving forward under ambiguity."

Use explicit conditionals for safety-critical triggers:

- "If the user describes an immediate medical emergency, direct them to emergency services."
- "If the request requires a regulated financial decision, do not provide personalized advice."

If a rule must hold 100% of the time, move it out of the prompt and into code.

A common over-correction is to translate every nuanced behavior into an explicit conditional. This rarely improves behavior and often hurts it. Consider an assistant that should adapt explanation depth to demonstrated user expertise. A general principle ("Adapt depth to the user's demonstrated proficiency, increasing detail when their questions show domain familiarity") lets the model integrate dozens of implicit signals — vocabulary, framing, follow-up specificity, the level of error in their guesses. A long list of conditionals ("If user mentions X, assume novice; if user uses term Y, assume intermediate…") forces the model into a shallow keyword match and tends to misclassify users who phrase things atypically. Use principles for judgment; reserve conditionals for safety triggers and policy bright lines.

### Few-Shot Examples

Examples often outperform long prose instructions. Use examples when you need the model to learn distinctions:

- Beginner vs expert explanations.
- Acceptable vs reportable code review findings.
- Correct extraction from unusual document layouts.
- Good vs bad clarifying-question behavior.
- Handling missing information without fabrication.

Keep examples realistic and compact. Show the exact behavior you want.

When a system prompt has grown into long bulleted rule lists, behavior often drifts because the model cannot keep all rules salient at once. Replacing chunks of those rules with two or three contrasting examples typically restores adherence: rather than telling the model in seven sentences how to summarize a beginner's question vs an expert's question, show it both. Examples are denser than prose for behavior the model needs to learn rather than recite.

### Prompt Dilution

System prompt adherence can weaken as conversation grows, even before the context window is full. The assistant's previous responses become a behavioral pattern. Mitigations:

- Use concise, well-structured system prompts.
- Put critical instructions in salient sections.
- Include behavioral examples.
- Add natural reminders before complex tasks.
- Validate or enforce important rules outside the model.

For long-running workflows, reinforcement can be inserted as application state or user-role reminders at natural breakpoints. Avoid cluttering every turn with giant repeated instructions.

Concretely, two reinforcement patterns work well:

- **User-role reminders at natural breakpoints.** When a session crosses a phase change — finishing one task and starting another, returning after a long idle period, switching topics — append a brief user-role message that re-states the current operating constraints. This is more effective than re-sending the entire system prompt because it integrates with the conversational flow the model is already attending to.
- **System prompt versioning across long sessions.** For multi-day or multi-session conversations, allow the application to update the system prompt between turns to reflect what is now true (the user's current plan, latest decisions, completed steps). Treat the system prompt as living configuration, not a static initialization string. The full conversation messages still go in `messages`; the system prompt carries "what currently holds" rather than "what was true on day one."

### Clarifying Questions and Assumptions

Asking too many clarifying questions increases friction. The right behavior depends on risk.

Ask a clarifying question when:

- Multiple interpretations lead to substantially different actions.
- The action is irreversible or costly.
- The user has expressed conflicting goals.
- Required information is truly missing.

Proceed with stated assumptions when:

- The action is low risk.
- Context strongly suggests the likely intent.
- The user can easily correct the direction.

Good pattern:

```text
I'll assume you want the report edited for clarity rather than rebuilt from scratch. I'll focus on structure and wording first, and you can redirect me if you meant formatting or data analysis.
```

For genuinely ambiguous requests, prefer **one focused clarifying question** over a list of three or four. Multiple simultaneous questions feel like an interrogation and frequently cause users to answer only the first. Pick the disambiguation that most changes your next action.

Front-loading many clarifying questions before any action is also typically wrong. The cost of a small redirected effort is usually lower than the friction of long preflight Q&A. The exception is when the action is irreversible, costly, or touches a regulated domain — there, ask first and proceed only after explicit confirmation.

When user preferences conflict, do not average them into a vague compromise. Name the tension and ask which priority should govern. For example, if a user wants both "the cheapest possible flight" and "arriving by 9 AM Friday with no layovers," surface the contradiction explicitly: a cheap nonstop arriving by Friday morning may not exist on this route, so which constraint should bend? Hidden compromises produce results that satisfy neither stated goal and usually require rework.

### Response Format Control

If responses become repetitive, do not only add "never say X" lists. Better options include:

- Better examples in the system prompt.
- A concise style guide.
- Partial assistant prefill for specific API calls.
- Post-processing for purely cosmetic cleanup when safe.

Partial assistant prefill is particularly effective for repetitive openers. If every reply starts with "Great question!" or "I'd be happy to help," prefilling a more neutral first sentence (or a constrained format like a checklist marker) skips the boilerplate without expanding the system prompt. Keep the prefill short — one phrase, not a paragraph — and avoid prefilling content the model needs to reason about.

For strict machine-readable output, prefer structured outputs or tool use over text formatting instructions.

### Common Pitfalls

- **Using "IMPORTANT" and "NEVER" as reliability mechanisms.** They help salience but do not guarantee behavior.
- **Adding endless conditionals.** This bloats the prompt and can reduce adherence.
- **Hiding key rules in long prose.** Use sections and examples.
- **Putting workflow-specific checklists in global memory.** Use slash commands or task-specific prompts when the checklist applies only sometimes.

---

## 7. Model Context Protocol (MCP)

### What to Know

MCP is an open standard for connecting AI applications to external systems. An MCP server exposes capabilities; MCP clients connect to servers; the host application decides how users and models interact with those capabilities.

MCP provides three important server-side building blocks:

| MCP Feature | Who Controls It | Purpose |
|---|---|---|
| Tools | Model-controlled | Actions and computations the model may invoke |
| Resources | Application-controlled | Context such as files, schemas, catalogs, or documents |
| Prompts | User/application-controlled | Reusable prompt templates or workflows |

Use tools for actions: search, update, create, analyze, send, calculate.

Use resources for passive context: database schemas, documentation trees, issue summaries, file catalogs, API references. Resources reduce exploratory tool calls because the agent can see what information exists before acting.

Use prompts for reusable workflows: review checklists, report templates, investigation playbooks.

A common design question is "should this be a resource, a tool, or a separate aggregator?" The default decision rule:

- If the content is reference material the agent might want to consult before acting (database schemas, API specs, file catalogs, project guidelines, configuration), expose it as a **resource**. The agent reads it like context; no tool call is needed beyond the resource fetch.
- If the content is dynamic and requires computation or external lookup at the moment of use (the current state of an order, the result of a query against live data), expose it as a **tool**.
- If the agent is overwhelmed by similar tools across many servers, the right fix is improving descriptions and using progressive availability — not consolidating everything behind a single "natural language entry tool" that re-routes to the underlying tools. That kind of aggregator hides the real tool surface from the model and tends to produce worse selection, not better.

Resources and tools are complements, not alternatives. A well-designed MCP server typically exposes both: resources for "what is true and stable about this system" and tools for "what actions can be taken on it." Replacing resources with tools forces the agent to make a tool call to learn anything; replacing tools with resources prevents the agent from acting at all.

### Why MCP

MCP is most valuable when the integration should be reusable across multiple clients or applications. If five AI tools need the same internal ticketing data, expose it once through an MCP server. If only one agent needs a deeply application-specific workflow, a custom tool inside that application may be simpler.

MCP does not automatically solve authentication, rate limiting, retries, caching, authorization, or performance optimization. Those remain system design responsibilities.

### Tool Discovery and Selection

Tools from connected MCP servers are discovered and exposed to the model through the client/host. When multiple servers are connected, the agent typically sees a combined tool registry. Good descriptions are critical because MCP tools compete with built-in tools and other server tools.

If the agent ignores a specialized MCP tool and uses generic search or shell commands instead, the most likely fix is to improve the MCP tool description:

- Explain when the tool is preferable to generic alternatives.
- Describe inputs and outputs.
- Include examples.
- Mention key capabilities such as transitive dependency analysis, ranking, source metadata, or safe refactoring.

Do not first remove all competing tools. The agent often needs generic tools too.

### Tool Annotations and Trust

MCP tool annotations are metadata that servers may include alongside their tool definitions. The standard hints include `readOnlyHint` (the tool does not modify state), `destructiveHint` (the tool may make irreversible changes), `idempotentHint` (calling the tool twice with the same input has the same effect as calling it once), and `openWorldHint` (the tool reaches external systems whose behavior the host cannot fully predict). These hints help the host build sensible UI affordances — for example, auto-allowing read-only tools, warning on destructive ones, suppressing repeat-confirmation on idempotent ones.

**Annotations are not a security boundary.** A malicious or buggy server can advertise `readOnlyHint: true` for a tool that deletes data. The host must treat annotations as untrusted hints and base actual permission and confirmation decisions on the server's trust level, the user's policy, the tool's identity, and the operation's real risk. A typical correct policy: use annotations to choose which prompt to show, but never use them to skip a security check that policy requires.

### MCP Error Handling

MCP distinguishes two error tiers, and using the wrong one is a common bug:

- **JSON-RPC protocol errors** are returned when the request itself is invalid or the tool cannot be invoked at all: missing required parameters, unknown method, malformed JSON, parameter type mismatches. The client treats these as protocol-level failures, not as something to relay to the model as if the tool had run.
- **Tool result with `isError: true`** is returned when the tool ran but failed semantically: a remote 404, a 503 from an upstream service, a permission denial, a validation rejection from the underlying system. The model sees these as tool results and can adapt — retry, choose a different tool, or surface to the user.

A useful rule: if the failure happened before the tool's business logic could execute, return a JSON-RPC protocol error. If the tool reached its target system and that system or the operation itself failed, return a tool result with `isError: true` and a useful message. Putting a missing-parameter failure in `isError` confuses the agent into retrying with the same bad call; putting a remote 503 into a JSON-RPC error prevents the agent from trying again later.

For resources, servers should validate URIs and return appropriate JSON-RPC errors for not found or internal failures. For tools that wrap inherently flaky network calls, lean toward `isError: true` with a clear message so the agent can decide whether to retry, switch tools, or escalate.

### Tool Search and Progressive Availability

Hosts can expose dozens of MCP servers, and presenting all their tools at once would consume a large fraction of the context window before any work begins. Two coordinating mechanisms exist:

- **Tool search / progressive availability.** The host shows the agent a small surface initially and lets it pull additional tool definitions on demand based on the current task. The agent only spends tokens on tools it is about to use.
- **`list_changed` notifications.** A server can notify clients that its tool set has changed (a server connected, a feature flag flipped, a permission changed). The client refreshes its tool list and the agent can pick up the new capability without a session restart.

When designing an MCP server intended for a host with progressive availability, pay extra attention to descriptions and names: the agent may discover the tool through search, so the description must read well in isolation, not only when listed alongside its siblings.

### MCP in Claude Code

Claude Code can configure MCP servers at several scopes. The scope determines where the configuration lives, who can see it, and which copy wins when names collide:

| Scope | Storage | Visibility | Typical Use |
|---|---|---|---|
| Project | `.mcp.json` at the repository root, checked into version control | Everyone who clones the repo | Tools the whole team needs to do the project's work — internal documentation servers, project-specific test runners, build orchestration |
| Local | An entry inside `~/.claude.json` keyed to the current project path | Only the current user, only when working in that project | Sensitive credentials for personal accounts, experimental servers under evaluation, project-specific tooling not yet ready to share |
| User | A separate entry in `~/.claude.json` not tied to a project | Only the current user, in any project they work on | Personal productivity tools — calendar, email, notes, clipboard — that the user wants available everywhere |

When the same server name exists at multiple scopes, the higher-precedence configuration wins. A common convention is project > local > user, so a team-shared `.mcp.json` definition overrides a user's experimental copy of the same server name. Use project scope deliberately because it is shared. Avoid putting personal credentials in project scope — those belong in local or user scope, where they remain on the developer's machine.

A nuance worth remembering for the exam: local and user scopes both live inside `~/.claude.json`, but at different keys. They are not "the same scope with different names" — local entries are scoped to a project path, user entries are global to the user. Selecting the wrong scope for a personal tool can leak credentials into a shared repo or, conversely, hide a tool the developer expected to see in every project.

MCP prompts surface as slash commands in Claude Code. The slash-command name typically follows a `mcp__<server>__<prompt>` pattern so the user can disambiguate prompts coming from different servers. MCP output can be large; tool authors should control output size and offer pagination or summarization affordances so a single tool call does not crowd out the rest of the conversation.

### Common Pitfalls

- **Using a tool where a resource is better.** Catalogs and schemas are often resources, not tools.
- **Assuming MCP handles auth and retries automatically.** It is a protocol, not a complete middleware platform.
- **Trusting self-reported annotations.** Trust the server and your policy controls.
- **Writing minimal descriptions.** "Analyzes code" is not enough.

---

## 8. Agentic Patterns and Task Decomposition

### What to Know

Agentic applications run a loop: observe, reason, act, observe again. The model sees current context, chooses a tool or response, incorporates results, and continues until the task is done or blocked.

The architecture question is how much autonomy to give the model and how to structure the work.

### Core Patterns

| Pattern | Best For | Avoid When |
|---|---|---|
| Prompt chaining | Fixed workflows with known steps | The path depends heavily on findings |
| Routing | Inputs fall into distinct handling categories | Categories are fuzzy or evolving rapidly |
| Orchestrator-workers | A coordinator chooses and delegates subtasks | A simple fixed chain would be cheaper |
| Dynamic decomposition | Investigation where each discovery changes the plan | The task is mechanical and well-defined |
| Parallel subagents | Independent workstreams | Workstreams depend on each other's results |

Examples:

- Use prompt chaining for a fixed three-stage review: style, security, documentation.
- Use routing when invoices, receipts, and contracts require different extraction tools.
- Use orchestrator-workers when a research coordinator decides which specialists to invoke.
- Use dynamic decomposition for debugging an intermittent backend failure.
- Use parallel subagents when several independent documents or repositories can be analyzed separately.

The decision is not "which pattern is best" but "which pattern matches the shape of this work." Prompt chaining adds reliability by constraining the model to a known sequence; pay that cost when the steps really are fixed and skip it when the work is exploratory. Dynamic decomposition is appropriate when the next step genuinely depends on what the model just learned — for example, an investigation where the first finding determines whether to gather logs, query a database, or interview a stakeholder. Hard-coding investigation steps tends to either miss the actual problem or waste effort gathering irrelevant data.

A useful contrast: a billing-dispute resolution workflow that always runs "verify identity → fetch invoice → check policy → propose adjustment" is a good fit for prompt chaining. A security incident triage that runs "examine alert → decide whether to pull logs, query a SIEM, page on-call, or all three" is a good fit for dynamic decomposition. Forcing chaining onto the second wastes coordinator effort and produces shallow analyses; forcing decomposition onto the first invites unnecessary tool calls and inconsistent outputs.

Dynamic decomposition specifically suits investigations where the next move only becomes clear after the current finding. Debugging an intermittent backend failure, root-causing a customer's unusual error report, or narrowing down a flaky test all share that shape: the model cannot write a fixed plan upfront because what to look at next depends on what the previous step revealed. A pre-written debugging checklist often misses the actual cause and runs every step regardless. With dynamic decomposition, the coordinator commits to a goal (find the cause), inspects what it has, and decides the next action — gather logs, examine config, reproduce locally, escalate — based on the current evidence. The trade-off is unpredictability: dynamic plans are harder to budget for than fixed chains, so set explicit termination criteria and step caps.

### When the Coordinator Should Not Delegate

Subagents add overhead. Each delegation incurs a tool call, a fresh context, a separate model invocation, and a result-passing step. When the coordinator already has the relevant context and the work is small, calling a subagent is slower and more expensive than just doing the work in the coordinator's turn. Save delegation for cases where the task would flood the coordinator's context (a long document analysis), genuinely needs a different prompt or tool set (a specialist persona), or can run in parallel with other work. For "summarize these three sentences I just retrieved," let the coordinator answer.

### Parallel Subagents Across a Partition

When a single large task can be cut into independent pieces — auditing 50 repositories, analyzing 30 documents, scanning 100 dependencies — the right pattern is partition-then-parallel: the coordinator divides the input set into N roughly equal chunks, spawns N subagents (one per chunk), and synthesizes their structured outputs. Each subagent works only on its slice of the partition, returning a uniform result shape the coordinator can merge.

This pattern wins when the work is uniform enough that the coordinator can describe each subagent's job from a template and the units do not need to consult one another. Total elapsed time becomes max(subagent_durations), so balance partitions by expected effort rather than by raw count. If a few partitions are far heavier than the rest, the slowest one dictates total time and the parallelism is wasted.

Avoid this pattern when units depend on each other's findings (a finding from repo A must inform the analysis of repo B), when the partition would split a logical unit (chopping a document mid-section), or when sequential streaming output to the user matters more than total throughput.

### Multi-Agent Context Passing

Subagents do not automatically share the parent's conversation state. When the parent agent invokes a subagent (in the Claude Agent SDK, this typically happens through a Task or Agent tool), the subagent starts a fresh conversation. It receives only what the parent explicitly passes — usually the prompt the parent constructed, plus the subagent's own definition (system prompt, allowed tools, model selection). It does not see the parent's prior user turns, prior assistant turns, prior tool results, or memory of earlier subagent runs.

Two consequences follow. First, every piece of context the subagent needs has to be in the prompt the parent constructs: the goal, the relevant findings, the constraints, the expected output shape, the source references. Second, a "resume the previous research subagent" pattern doesn't exist by default — calling the Agent tool again starts a brand-new agent. If you need continuity, the parent must persist an identifier and pass it through, or include the prior summary in the new prompt.

A coordinator must therefore pass the context each subagent needs. Usually that means a concise task, relevant findings, source references, constraints, and expected output shape.

Poor handoff:

```text
Synthesize the findings.
```

Better handoff:

```text
Synthesize the following claim-source records into an executive summary. Preserve uncertainty, cite each claim with its source_id, and separate established findings from contested findings.
```

For final report generation, do not pass only a prose summary if citations are required. Pass a structured source index that maps claims to source IDs, URLs, excerpts, dates, and confidence/uncertainty notes.

### Tool Distribution Across Agents

More tools are not always better. Giving every subagent every tool increases selection complexity and can lead agents outside their role. Restrict tools to what each subagent needs.

Examples:

- A web research subagent needs search and fetch tools.
- A document analysis subagent needs document-read/extraction tools.
- A synthesis subagent may need no external search tools if it should only work from supplied findings.
- A report generator needs formatting and citation inputs, not raw broad search.

In the Claude Agent SDK, the mechanism for delegating to a subagent is itself a tool — typically named `Task` or `Agent`. For the parent to spawn a subagent, this tool must appear in the parent's `allowedTools` list. Forgetting to allow the Task/Agent tool is a common reason an "orchestrator" cannot delegate at all: the subagent definitions exist, but the parent has no callable interface to launch them. The subagent's own `allowedTools` is configured separately in the AgentDefinition and constrains what the subagent can do once spawned.

### Parallel Execution

If tasks are independent, the coordinator should start them concurrently rather than serially. In tool-calling systems, that often means emitting multiple tool calls in one assistant turn when the platform supports parallel tool calls. In an external orchestrator, it may mean launching concurrent SDK calls and aggregating results.

Do not parallelize when the second task needs the first task's output. For example, document analysis cannot inspect sources until sources are identified, but analyzing independent source documents can run in parallel after retrieval.

A common phasing pattern is: serial decomposition (one model call to plan and identify the independent units of work) followed by parallel execution (each unit runs as its own subagent or tool call concurrently) followed by serial synthesis (one final call assembles the results). The parallel phase wins the most latency back when subtasks involve I/O — fetches, searches, document analyses — because elapsed time becomes max(subtask_durations) instead of sum(subtask_durations). For CPU-bound or token-bound work the speedup is smaller. When subtasks have differing latency, the slowest determines total time, so balance work across subagents rather than letting one of them carry an outsized share.

### State Persistence

Long-running multi-agent workflows need durable state. Persist structured exports, not only transcripts:

```json
{
  "workflow_id": "research_2026_04_30",
  "completed_steps": ["source_search", "source_screening"],
  "documents": [
    {
      "source_id": "src_17",
      "status": "analyzed",
      "claims": ["claim_40", "claim_41"]
    }
  ],
  "open_gaps": ["recent regulatory changes"]
}
```

On resume, the coordinator loads the manifest and injects only relevant state into each agent prompt. This is more efficient than replaying every subagent transcript.

### Provenance, Time, and Uncertainty

Research agents must preserve provenance and dates. Without dates, a synthesis agent may treat older and newer statistics as contradictory when they actually show a trend. Without source mapping, claims lose citations. Without uncertainty structure, reports become either overconfident or over-hedged.

Ask subagents to output:

- Claim.
- Source ID and location.
- Publication or data collection date.
- Methodology notes.
- Confidence or uncertainty language from the source.
- Whether the finding is established, contested, or insufficiently supported.

Render different content types appropriately. Financial metrics may belong in tables; qualitative developments may belong in prose; patent categories may belong in grouped lists.

### Common Pitfalls

- **Using a full pipeline for simple facts.** Let the coordinator choose a smaller path for simple queries.
- **Strict one-pass research.** If analysis finds gaps, the coordinator should trigger targeted follow-up search.
- **Passing raw 100K-token outputs between every agent.** Pass structured summaries plus source indexes.
- **Over-prescribing subagents.** Give goals and quality criteria, not brittle step-by-step search strings, when adaptability matters.

---

## 9. Customer Service and Production Workflow Design

### What to Know

Customer service agents combine tool use, policy, state, escalation, and user experience. The agent should resolve what it can, escalate when it should, and communicate uncertainty honestly.

### Escalation

Escalate when:

- The user explicitly asks for a human and the issue cannot be resolved immediately without overriding their preference.
- The issue requires authority the agent does not have.
- A policy exception, regulated approval, or high-value transaction is involved.
- The agent cannot make meaningful progress.
- Tool results show an uncertain or unsafe state that requires human judgment.

Do not rely on simplistic counters such as "escalate after three failed tools." The category and impact of the failure matter more than the count.

When escalating, pass a structured handoff:

```json
{
  "customer_id": "cust_193",
  "issue_type": "billing_adjustment",
  "root_cause": "subscription tier mismatch",
  "relevant_records": ["invoice_8841", "case_2209"],
  "amount": 72.15,
  "actions_taken": ["verified account", "checked invoice"],
  "recommended_next_action": "manager approval for adjustment"
}
```

Do not pass only the user's first complaint. Do not dump the full transcript unless the receiving system can use it.

### Frustrated Users

When a user is frustrated, acknowledge the frustration and move efficiently. If the issue is straightforward and the user asks for a human, offer the immediate resolution while preserving their choice:

```text
I can resolve this now, and I can also transfer you if you prefer. The eligible action is ready; would you like me to complete it or connect you to a specialist?
```

Do not silently perform account actions after a frustrated user asks for a person. Do not make them answer a long intake questionnaire if one targeted question is enough.

### Compliance and Authorization

Hard rules must be enforced programmatically:

- Refunds above a threshold.
- Reimbursements requiring manager approval.
- Regulated financial or healthcare workflows.
- Destructive infrastructure operations.

Use tool-level enforcement, middleware, permissions, or hooks. Prompt instructions can guide behavior but are not tamper-proof.

The safest design often puts the rule inside the tool itself. For example, `process_reimbursement` can internally disburse amounts below a threshold and create a pending manager approval above it. This prevents the model from bypassing the rule by choosing the wrong tool or setting an approval flag incorrectly.

A few patterns work well in combination, and the exam tends to test the difference:

- **Threshold enforcement inside the tool.** The tool reads the threshold from a server-controlled source — feature flag, policy service, account record — not from a parameter the model passes. The model can call `issue_credit(amount=…)` but cannot raise the cap by setting `override=true`, because no such parameter exists on the public interface. If a model call exceeds the limit, the tool returns a structured "requires_approval" result, not a silent failure.
- **Preview-then-execute with single-use tokens.** For high-impact actions (closing accounts, charging cards, sending external notifications), split the operation into two tools: a preview tool that returns a redacted summary plus a one-time execution token, and an execute tool that consumes that token. The model presents the preview to the user verbatim, the user confirms, and only then does the execute tool fire. The token is short-lived and bound to the previewed payload; the model cannot construct a token from scratch or reuse one with different parameters.
- **Server-side authorization checks before any state change.** Even when the model is well-behaved, the tool should re-verify the caller's authority on every invocation. "The model already checked policy" is not a defense. Tools live inside the trust boundary; they must validate.

Avoid letting prompt instructions ("never refund above $50 without manager approval") be the only line of defense. Adversarial users, prompt-injection in retrieved content, or a malformed tool description can all push the model past prose rules. Defense-in-depth means: prompt rules to bias the agent, tool implementations to enforce, and audit logs to detect.

### Graceful Degradation

If a tool fails mid-workflow, the agent should still deliver useful progress:

- Explain what has been verified.
- State what could not be completed.
- Be transparent about system issues.
- Offer next steps such as retry, escalation, or notification.

Do not claim a side effect will happen if the system has not completed it. Do not immediately escalate when the agent can still answer part of the user's problem.

For partial completion, prefer "here is what is done, here is what is pending, here is how we can finish" over either a flat success message or a generic "we hit an error." Users tolerate visible incompleteness; they do not tolerate later discovering that an action they thought was completed had silently rolled back. When the same tool keeps failing on the same input, treat it as a signal to switch strategies — try a different tool, ask a clarifying question, or escalate — rather than burning more retries on the same call.

### Common Pitfalls

- **Escalating with no useful handoff.** Human agents need context and recommendations.
- **Processing high-risk actions based on prompt rules.** Use code-level enforcement.
- **Retrying uncertain writes.** Avoid duplicate charges, messages, or postings.
- **Over-automating user confirmation.** Show concrete action details.

---

## 10. Claude Code and Claude Agent SDK Workflows

### What to Know

Claude Code is an agentic coding tool. The Claude Agent SDK exposes the same style of agent loop, built-in tools, hooks, sessions, subagents, permissions, and MCP integrations for programmable agents.

Current docs refer to the product library as the Claude Agent SDK. Older references may say Claude Code SDK.

### Built-in Tool Selection

| Task | Best Tool |
|---|---|
| Search file contents | Grep |
| Find files by path/name pattern | Glob |
| Read a known file | Read |
| Targeted unique edit | Edit or MultiEdit |
| Full file replacement | Read then Write |
| Run tests or shell commands | Bash |
| Delegate broad exploration | Task/subagent |

Use Grep for text inside files. Use Glob for filenames and paths. Do not use filename search to find code references inside files.

For codebase exploration, start from entry points and follow imports/calls. Do not read hundreds of files upfront. Map first, then read selectively.

Original exploration workflow:

1. Grep for route names, error codes, or function identifiers.
2. Read the matching entry files.
3. Follow imports to core abstractions.
4. Trace one or two representative execution paths.
5. Summarize findings in a scratchpad when the investigation is long.

When asking Claude Code to follow existing project patterns, provide concrete context rather than vague instructions. Use file references such as `@src/payments/repository.ts` or `@docs/testing.md` when those files are the examples the agent should imitate. Concrete examples beat generic requests like "follow our usual style."

### Plan Mode vs Direct Execution

Use direct execution for small, localized, low-risk changes where the target is clear.

Use plan mode when:

- The change spans many files.
- There are architectural choices.
- The work involves migrations or breaking changes.
- You need stakeholder approval before edits.
- You want read-only exploration before implementation.

Plan mode lets Claude read and propose a plan before touching disk. In Claude Code, `--permission-mode plan` starts in plan mode, and `Shift+Tab` can toggle modes in interactive sessions.

For urgent production bugs, start by gathering evidence: stack trace, relevant code, logs, and reproduction path. If the fix is obvious and narrow, implement directly. If the root cause reveals broad architectural impact, switch to planning before a larger change.

### Plan Mode vs Extended Thinking

These are different mechanisms and should not be conflated. Plan mode is a Claude Code session mode in which the assistant explores read-only and produces a plan before any edits, then waits for user approval. It is about *workflow control* — gating the transition from "thinking" to "doing" so the human can review the strategy.

Extended thinking is a model capability where Claude is given more internal reasoning budget before producing its output. It is about *reasoning quality* on hard problems — multi-step proofs, intricate code analysis, ambiguous requirement reconciliation — and does not by itself change whether the model takes actions or asks for approval.

Both can be used together: plan mode for review-gate the workflow, extended thinking for harder reasoning during planning or implementation. But they solve different problems. If the issue is that the agent jumps straight to edits without surfacing trade-offs, use plan mode. If the issue is that the agent gives shallow analyses on a complex problem, use extended thinking.

### Sessions

Claude Code organizes work into sessions — each session is a stored conversation transcript that can be resumed later. Several CLI flags control session behavior, and they are easy to confuse:

| Flag | Behavior | Best Use |
|---|---|---|
| `--continue` | Resumes the most recent conversation in the current directory without prompting | Returning to the latest in-progress work in a project |
| `--resume` (`-r`) | Resumes a specific saved session, opening a picker if no identifier is given | Selecting a specific historical session or an explicitly named session |
| `--session-id <UUID>` | Uses (or creates) a session with a specific UUID | Programmatic workflows that need a stable, known identifier |
| `--fork-session` | Creates a new session branched from an existing transcript | Exploring an alternative path without contaminating the original |

Use a named or specific session when returning to a known investigation. Use `--continue` only when the most recent conversation is definitely the one you want — in a directory where you've worked on multiple unrelated tasks, "the latest" can be the wrong session.

`--fork-session` is the right tool when you want to evaluate two different approaches starting from the same prior state. The original session is preserved untouched; the fork is a separate transcript whose history is a copy of the original at the fork point. This is preferable to resuming the original twice and trying to keep two diverging conversations straight, and preferable to copying-and-pasting context into a fresh session, which loses tool-call history.

If the codebase changed since the previous session:

- Resume and tell Claude exactly which files or functions changed when most prior context remains useful.
- Start fresh with a summary when the old transcript is likely stale or misleading.

Sessions persist conversation history, not filesystem state. If you need isolated file changes, use git branches or worktrees. For comparing two alternative implementations, fork the session so each approach can evolve independently *and* use a separate worktree so the file changes do not collide. Forking the session without isolating the files leaves both attempts editing the same checkout; isolating files without forking the session intermingles the conversation transcripts.

Avoid resuming the same session in multiple terminals at once. Both processes can append to the same session history, making later resumes confusing.

### Context Isolation and Self-Review

The same session that wrote code may be less critical of its own choices because its context includes the earlier reasoning. For high-stakes review, use a fresh review context, a dedicated review subagent, CI review, or a separate session with the diff and review criteria.

### Scratchpads

For long codebase exploration, write a concise scratchpad of durable findings:

- Important files.
- Data flow.
- Open questions.
- Confirmed assumptions.
- Risk areas.
- Next steps.

This helps when context compacts or when another session must pick up the work.

### CLAUDE.md and Memory

`CLAUDE.md` files store project or user memory: build commands, conventions, architecture notes, testing standards, and workflow preferences. They are auto-loaded into Claude Code's context based on a hierarchy:

- The root `CLAUDE.md` at the repository root applies to the whole project.
- Subdirectory `CLAUDE.md` files apply to work in that subtree, layered on top of the root.
- A user-level memory file applies across all projects for that user.
- Imports using `@path/to/file.md` syntax pull in additional shared content without copy-pasting; this is the right way to reuse a standards document across multiple `CLAUDE.md` files.

When multiple files are loaded, more specific files refine or override more general ones for the area they cover. The user-level memory is for personal preferences (preferred commit message style, preferred test command shortcuts) — not team-wide rules, which belong in repo-tracked `CLAUDE.md` files so all collaborators benefit.

Use `/memory` to inspect and edit loaded memory files. This is the first diagnostic step when Claude inconsistently follows project conventions: confirm the expected memory file is loaded before adding more instructions. If the rule is in a memory file that isn't being loaded for the current working directory, no amount of additional prompting will fix the behavior — the problem is the loading scope, not the rule's wording.

Prefer scoped memory:

- Root `CLAUDE.md` for repo-wide rules.
- Subdirectory `CLAUDE.md` files for area-specific conventions.
- `@imports` to reuse shared standards without duplicating content.
- Personal memory for individual preferences, not team rules.

Do not put every occasional workflow into global memory. A code-review checklist belongs in a slash command or review subagent if it is only relevant during reviews. Memory files are read on every turn — bloating them with workflow-specific content costs tokens and dilutes the parts that matter for ordinary work.

The mechanism for project memory is `CLAUDE.md` files plus `@import` references. There is no separate "rules directory with YAML frontmatter" mechanism — proposals that suggest a `.claude/rules/` folder with per-rule frontmatter for path scoping are not the standard model. Path scoping is achieved by placing `CLAUDE.md` files at the appropriate directory level so that work in that subtree picks them up; sharing across files is achieved with `@imports`. If you encounter advice to add YAML-frontmatter rule files, treat it as not how Claude Code's memory system actually loads context.

### Slash Commands

Slash commands are reusable prompts. Use them for explicit workflows that developers invoke intentionally:

- `/review` for a review checklist.
- `/release-notes` for release note formatting.
- `/migration-plan` for a standard migration analysis.

Project commands are shared with the repo; user commands are personal. MCP prompts can also appear as slash commands.

### Hooks and Permissions

Hooks run at lifecycle events. The most common ones to know are:

- **`PreToolUse`** — fires before a tool call. Can deny the call, allow it, ask the user for approval, defer (let normal permission rules decide), inject additional context the model will see, or modify the tool's input. This is the correct class of mechanism for "must always require approval" policies.
- **`PostToolUse`** — fires after a tool call. Useful for logging, formatting, secondary checks, or appending follow-up context.
- **`UserPromptSubmit`** — fires when the user submits a prompt. Can block the submission, modify it, or attach extra context.
- **`SessionStart`** — fires once when a session begins. Useful for loading project context, setting up environment variables, or running pre-flight checks.

A `PreToolUse` hook is the canonical way to enforce hard rules in Claude Code: matching tool name and parameters against an allow/deny list, requiring confirmation for destructive shell commands, blocking edits to generated files, or refusing writes outside an approved directory. Because hooks run as code in your environment, they cannot be talked around by the model — that is exactly why they are the right place for hard rules.

Examples:

- Block destructive Bash patterns unless approved.
- Prevent edits to generated files.
- Run a formatter after successful edits.
- Add environment context at session start.

Hooks execute shell commands in your environment. Treat them as code with security implications: a malicious or buggy hook can damage your system or exfiltrate data. Review hook configurations from third-party sources before enabling them, and avoid putting secrets in arguments that hook commands can log.

### Subagents

Subagents have separate context windows, focused prompts, and configurable tool access. Use them when a side task would flood the main context, when specialized behavior is reused, or when independent work can run in parallel.

Good subagent design:

- Clear single responsibility.
- Specific description so Claude knows when to use it.
- Limited tools needed for the role.
- Output contract that the coordinator can consume.

Avoid making every subagent inherit every tool. Tool restriction improves focus and security.

In Agent SDK and Claude Code configurations, delegation still requires the agent to have access to the tool or mechanism that launches subagents. If an agent describes a delegation but no subagent runs, check tool permissions and whether the subagent invocation tool is allowed.

A subagent does not inherit the parent's conversation. When the parent launches it, the subagent receives its AgentDefinition (its own system prompt, allowed tools, model selection) and the prompt string the parent constructed for that specific invocation. It does not see the parent's earlier turns, prior tool results, or any other subagent's output. This is intentional — it keeps subagent context focused — but it means the parent must restate every fact the subagent will need. Treat the prompt to a subagent like a brief to a contractor: assume nothing carries over.

Two practical consequences:

- **Don't assume the subagent "remembers" your project.** If the subagent needs the project's coding conventions, paste or reference them in the prompt. CLAUDE.md will not always be loaded into the subagent's context unless its definition does so.
- **Don't expect a "second invocation" of the same subagent to continue where the first left off.** Each call is fresh. If state needs to persist across invocations, the parent persists it (in a file, in a structured note) and re-supplies the relevant slice with each call.

### Common Pitfalls

- **Using plan mode for tiny edits.** It adds overhead.
- **Using direct execution for broad migrations.** You lose review and architecture planning.
- **Assuming all session resumes are safe.** Old context may reference changed code.
- **Using a global `CLAUDE.md` for task-specific checklists.** Use slash commands or subagents.
- **Relying on prompt instructions for destructive Bash approval.** Use hooks/permissions.

---

## 11. Iterative Refinement, Testing, and Evaluation

### What to Know

Claude improves fastest when feedback is concrete and executable. Instead of "handle edge cases better," provide failing inputs, expected outputs, test failures, validation errors, or code review examples.

### Effective Iteration

For coding:

1. Define behavior with tests or examples.
2. Ask for the smallest useful implementation.
3. Run tests.
4. Feed back exact failures.
5. Iterate one failure class at a time.

For uncertain requirements, ask Claude to interview the user or surface decisions before implementation. This is especially useful for caching, real-time architecture, auth changes, or data consistency requirements.

For formatting defects, fix one visible class at a time and verify. Avoid broad rewrites that introduce new regressions.

The most effective feedback is concrete enough that the model can locate the failure: a specific failing input, the expected output, the actual output, the validation error, or the failing test name with its assertion message. "It's not handling edge cases" gives the model nothing to act on; "for input X, the expected key `service_visits` is missing because the source uses 'maintenance entries' instead of 'service visits'" lets the model fix exactly that. When iterating on extraction or generation tasks, pair each failure with the specific source excerpt that triggered it and the rule that was violated.

When the same defect keeps recurring across several runs of the same prompt, treat that as a signal that the prompt or schema needs a structural change — adding a few-shot example, splitting a tool into more specific tools, or surfacing a new field — rather than a sign that the model needs another retry. Prompt-level fixes generalize; per-instance retries do not.

### Test Generation Quality

Generated tests are low value when they:

- Only assert that code does not throw.
- Duplicate existing coverage.
- Ignore project fixtures.
- Test implementation details rather than behavior.
- Miss important branches and error paths.

Document test standards in project memory or a testing guide. Include examples of valuable behavioral tests versus trivial tests. Provide fixture names and intended use.

### Code Review Agents

A useful review agent needs explicit report criteria. Tell it which findings matter: bugs, security, correctness, data loss, missing tests, incompatible API changes. Tell it what to skip: minor style preferences, local conventions already accepted, speculative performance advice.

For false positive reduction, few-shot examples are more effective than vague "be conservative" instructions. Show acceptable code patterns next to genuinely problematic ones.

If developers dismiss findings, capture why. Add fields such as `detected_pattern`, `rule_id`, or `evidence` so you can analyze what the system is over-reporting.

### Evaluation Loops

Evaluate by segment:

- Document type.
- Field.
- Prompt version.
- Model.
- Source quality.
- Confidence band.
- Reviewer correction category.

Aggregate accuracy can be misleading. A pipeline that is 97% accurate overall may fail on a specific high-impact field or document type.

### Common Pitfalls

- **Asking for a full rewrite after a narrow failure.** Give the failing test and ask for a targeted fix.
- **Using confidence without calibration.** Measure it against labeled data.
- **Treating reviewer dismissals as noise.** They are feedback.
- **Adding infrastructure before improving examples and criteria.** Prompt/schema changes often solve repeated patterns.

---

## 12. Batch Processing, Cost, and Latency

### What to Know

The Message Batches API processes many Messages API requests asynchronously. Each batch is submitted as a set of independent requests; the API processes them in the background and returns results when the batch ends. Each request inside the batch supports the same general request shape as a Messages API call — model, messages, tools, system prompt — and each carries a `custom_id` chosen by the client.

The two most important properties to remember:

- **Discount.** Batch processing is offered at roughly half the cost of standard synchronous calls. The exact figure to remember is approximately 50% off the equivalent on-demand pricing.
- **Window.** A batch can take up to 24 hours to complete. In practice many batches finish much sooner, but you cannot rely on faster completion. Design SLAs around the 24-hour worst case, not the typical case.

Batching is useful when:

- Work is high volume.
- Results do not need to be immediate.
- The workflow can tolerate up to 24 hours.
- Cost reduction matters.
- Requests are independent.

Batching is a poor fit when:

- A user is waiting interactively.
- Alerts or business actions have short deadlines.
- Each step depends on the previous result.
- Humans need immediate feedback to continue.

Results may not be ordered like inputs, so `custom_id` is mandatory for reliable processing. The application matches each result back to its original request by `custom_id` — never by position. A duplicated or reused `custom_id` will make matching ambiguous; use stable, unique identifiers (often the source record's primary key) so re-running a partial batch is straightforward.

Operational details to know:

- A batch has a processing status such as in progress, canceling, or ended.
- Individual results can succeed, error, be canceled, or expire.
- Batch results are returned as JSONL and should be streamed or processed incrementally for large jobs.
- Validate your request shape with the standard Messages API before submitting a large batch — a single malformed request will not fail the batch, but it will produce a per-request error you must reconcile.
- Batch size and request count have platform limits, so large pipelines may need multiple batches.

### SLA Design

When documents arrive continuously, choose a batch cadence based on deadline minus worst-case processing window and operational buffer. The arithmetic is mechanical: a record submitted at the next batch run has to wait up to (interval until next run) + (batch processing time, up to 24 hours) + (post-processing) before its result is usable. The slowest record sets the worst case, not the average.

Example: if results must be available within 30 hours and batch processing may take up to 24 hours, leaving a 6-hour buffer for downstream work, the maximum acceptable interval between submissions is six hours. Anything longer means a record that arrives just after a submission can wait long enough that the deadline is missed. With a six-hour cadence, the worst case is a record that arrives one second after submission and must wait six hours to enter the next batch — combined with the 24-hour batch worst case, that totals 30 hours, exactly at the SLA boundary. To leave any margin at all, choose a cadence shorter than (deadline − batch window − processing buffer).

A second example: if the SLA is 36 hours and the batch worst case is 24 hours, the cadence can stretch to roughly 12 hours. If the SLA is 26 hours, the cadence must drop to 2 hours or less, because there is almost no margin. Tightening the cadence costs more API calls and orchestration overhead but is the only way to honor a tight SLA against a 24-hour batch ceiling. Submitting "once a day" is only safe when the SLA is at least 48 hours and you are willing to absorb tail latency.

### Failure Handling

Do not rerun the entire batch when a small percentage fails.

Handle by failure type:

- `context_length_exceeded`: chunk only failed inputs, then merge partial extractions.
- Validation failure: resubmit failed records with validation-error feedback.
- Prompt/schema issue: refine prompt and resubmit affected records.
- Expired/canceled: resubmit only incomplete `custom_id`s.

### Batch and Prompt Caching

Prompt caching can reduce costs for repeated context in some workflows, but it does not solve latency or context-limit failures by itself. If a request is too long, caching the prompt does not make the context window larger. If a result is needed immediately, batch discount does not matter.

### Common Pitfalls

- **Choosing batch solely for cost.** Latency and SLA dominate.
- **Assuming result order.** Always join by `custom_id`.
- **Retrying all records after partial failure.** Resubmit only failures.
- **Using batch for interactive refinement.** Use real-time calls when humans are waiting.

---

## 13. Quick Reference Cheat Sheet

### API and Output

- Claude is stateless. Send the context you want the model to use.
- System prompt goes in the top-level `system` parameter.
- Tool definitions and schemas consume input tokens.
- Use `output_config.format` for schema-backed JSON responses where supported.
- Use tool use or strict tool use for schema-backed tool calls.
- `tool_choice: auto` allows tools; `any` requires one; `tool` requires a named tool; `none` disables tools.
- Partial assistant prefill can control text starts, but structured outputs/tools are better for strict data.

### Tool Design

- Use clear names and 3-4 sentence descriptions for nontrivial tools.
- Include examples for complex nested inputs.
- Use lookup-then-act for ambiguous entities.
- Atomic operations for race-prone work (find_and_book together, not find then book).
- Split tools when required parameters differ by operation.
- Use progressive discovery for very large tool sets instead of exposing every tool at once.
- Return structured IDs and metadata for chaining.
- Accept stable IDs in downstream tools when intermediate lookup fields are mechanical.
- Pagination: return first page plus cursor and total_count; do not dump every record.
- Add `requires_review` and decision hints to outputs that may need human judgment.
- Empty result is success with no matches, not an error.
- Use preview-token-execute for mandatory confirmation.
- Enforce hard limits in code, not prompts; threshold values should come from server-controlled state, not model-provided parameters.

### Error Handling

- Retry transient read/infrastructure failures inside the tool when safe (network blips, 503, rate limit).
- Return validation and business errors with structured, non-retryable metadata.
- Treat write timeouts as uncertain state unless idempotency proves otherwise — the side effect may have happened.
- Distinguish "no rows found" (empty success) from "tool failed" (error) — a missing record is data, not a bug.
- MCP protocol errors are JSON-RPC errors (missing required parameter, unknown method); tool execution errors return `isError: true` (404, 503, denied).
- Repeated identical failures with the same input mean switch strategies, not retry harder.
- Do not use exceptions for expected business failures.

### Structured Extraction

- Use structured outputs or tool use with schema for reliable structured output.
- Optional/nullable fields prevent forced hallucination.
- Distinguish null (unknown / not present) from empty array (asked-and-found-none).
- Add `unclear`, `other`, or detail fields when categories are ambiguous or evolving.
- Use few-shot examples for varied document layouts and edge cases.
- Pair stated and calculated totals (e.g., `stated_total` and `calculated_total`) so reconciliation is automatic.
- Validate semantics after schema validation.
- Correct with validation-error feedback — a re-prompt that includes the source plus the validation errors fixes far more cases than a blind retry.
- Recognize when retries cannot help: if the source genuinely lacks the information, no retry will produce it.
- Use pre-extraction mapping/summarization for long documents with scattered facts.
- Add source locations for auditability.
- Capture `detected_pattern` / `rule_id` for review-agent findings so dismissals become signal.
- Calibrate confidence before automation.
- Sample high-confidence outputs to catch hidden errors.

### Context Management

- Sliding window: simple, loses older context — appropriate for forum-style or stateless help.
- Progressive summary: preserves narrative decisions and themes — appropriate for advisor/coach sessions.
- Structured state: best for current preferences and constraints — appropriate for ordering, planning, configuration.
- Persistent reference sections (story bibles, allergy lists): for facts that must remain available verbatim.
- Retrieval/fact store: best for exact numbers, clauses, and quotes pulled on demand.
- Compress verbose tool results into relevant fields — keep `lookup_order` rather than full menu rows.
- For returning users, prefer fresh start with a structured summary plus targeted fresh lookups over replaying old tool results.
- Surface conflicts between user goals; do not average them.
- Version prompts for long-lived conversations.

### System Prompts

- Send the system prompt on every request — there is no implicit memory.
- Use sections and examples.
- Principles for judgment; explicit conditionals for safety triggers.
- Move deterministic guarantees into code.
- Few-shot examples beat long abstract instructions for subtle distinctions.
- Attention to system prompt weakens with conversation length even when the prompt is included on every call.
- Reinforce critical guidelines at natural breakpoints in long sessions; version the system prompt across long-lived sessions.
- Surface contradictions in conflicting goals rather than averaging them.
- Ask one focused clarifying question for genuinely ambiguous, high-impact actions; state assumptions for low-risk ambiguity.

### MCP

- Tools are model-controlled actions.
- Resources are application-controlled context.
- Prompts are reusable workflow templates.
- MCP enables reusable integrations across clients.
- MCP does not automatically handle auth, retries, or rate limits.
- Tool annotations (`readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`) are untrusted hints, not guarantees.
- Poor descriptions cause poor tool selection.
- JSON-RPC errors for protocol-level failures (missing param, unknown method); `isError: true` tool results for execution failures (404, 503, denied).
- Project MCP config uses `.mcp.json` at the repo root; local and user Claude Code MCP config both live in `~/.claude.json` at different keys.
- Progressive availability and `list_changed` notifications keep large tool surfaces tractable.

### Agentic Patterns

- Prompt chaining: fixed steps.
- Routing: classify then dispatch.
- Orchestrator-workers: coordinator chooses subtasks.
- Dynamic decomposition: investigative work that changes as facts emerge.
- Parallel subagents: independent tasks; phase as serial decompose → parallel execute → serial synthesize.
- Subagents do not inherit parent conversation; the parent must include every needed fact in the prompt.
- The Task/Agent tool must be in the parent's `allowedTools` for delegation to work.
- Pass context explicitly to subagents.
- Preserve claim-source-date mappings in research.
- Restrict tools by subagent role.

### Claude Code / Agent SDK

- Grep searches file contents.
- Glob finds file paths.
- Read known files.
- Edit/MultiEdit for targeted changes.
- Write for full-file replacement after reading.
- Bash for commands and tests.
- Plan mode for broad or risky changes.
- Direct execution for narrow clear edits.
- `--continue` resumes most recent conversation.
- `--resume` resumes a specific session by ID/name or opens picker.
- `--session-id` uses a UUID.
- `--fork-session` branches a prior conversation; pair with a separate worktree for isolated parallel work.
- CLAUDE.md hierarchy: root, subdirectory, user-level; `@imports` reuse shared standards.
- Use scratchpads for long investigations.
- Use `/memory` to inspect loaded `CLAUDE.md`.
- Use slash commands for task-specific reusable workflows.
- Hooks: `PreToolUse` (deny/allow/ask/defer/modify-input/inject-context), `PostToolUse`, `UserPromptSubmit`, `SessionStart`.
- Subagents start fresh — they do not inherit the parent's conversation; the parent must include all needed context.

### Batch Processing

- Use Message Batches for high-volume asynchronous work.
- Avoid batch when users need immediate results.
- Roughly 50% discount versus on-demand calls; up to 24 hours per batch.
- Use `custom_id` to match unordered results.
- Resubmit only failures.
- Chunk context-length failures.
- Batch cadence ≈ deadline − 24h batch window − processing buffer; submit periodically for tight SLAs.
- Batch discount does not fix latency or context limits.

---

## Study Strategy

### Recommended Order

1. API fundamentals: stateless requests, messages, system prompt, tool-use blocks.
2. Tool design: descriptions, parameters, structured outputs, tool composition.
3. Error handling: retry categories, uncertain state, MCP error tiers.
4. Structured extraction: schemas, validation, provenance, review loops.
5. Context management: summarization, state, retrieval, stale data.
6. System prompts: salience, examples, principles, clarification.
7. MCP: tools, resources, prompts, trust, configuration.
8. Agentic patterns: decomposition, subagents, research provenance.
9. Claude Code/Agent SDK: tools, plan mode, sessions, memory, hooks.
10. Batch processing and evaluation: cost, latency, feedback, calibration.

### How to Practice

For each topic, practice choosing between two plausible designs:

- Prompt instruction vs hook.
- Enum vs free-form string plus normalization.
- Sliding window vs progressive summary.
- Tool-level retry vs model-level retry.
- Batch API vs real-time API.
- Resume old session vs start fresh with a summary.
- Single tool vs split tools.
- Raw source handoff vs structured claim-source mapping.

A strong answer explains why one design fits the scenario's constraints.

### Exam Reasoning Checklist

When faced with a scenario, identify:

1. Is the failure caused by missing context, bad tool design, bad prompt design, or missing programmatic enforcement?
2. Is the needed behavior probabilistic guidance or deterministic policy?
3. Does the model need to inspect intermediate results before acting?
4. Is the data absent, ambiguous, stale, or contradictory?
5. Is the operation interactive, asynchronous, or high volume?
6. Does a human need raw transcript, structured handoff, or source citations?
7. Are we optimizing for accuracy, cost, latency, safety, or developer workflow?

---

## Recommended Reading and Resources

### Official Anthropic Documentation

- [Messages API examples](https://docs.anthropic.com/en/api/messages-examples) - Stateless Messages API and conversation-history structure.
- [Tool use with Claude](https://docs.anthropic.com/en/docs/agents-and-tools/tool-use/overview) - Tool-use concepts, pricing/token implications, and examples.
- [Define tools](https://docs.anthropic.com/en/docs/agents-and-tools/tool-use/implement-tool-use) - Tool definitions, descriptions, schemas, and `tool_choice`.
- [Structured outputs](https://docs.anthropic.com/en/docs/build-with-claude/structured-outputs) - JSON structured outputs and strict tool use.
- [Batch processing](https://docs.anthropic.com/en/docs/build-with-claude/batch-processing) - Message Batches API, asynchronous processing, cost trade-offs.
- [Long context prompting tips](https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering/long-context-tips) - Prompt structure for long documents and retrieval-heavy tasks.
- [Citations](https://docs.anthropic.com/en/docs/build-with-claude/citations) - Source-grounded responses and citation constraints.
- [Claude Code CLI reference](https://docs.anthropic.com/en/docs/claude-code/cli-reference) - `--continue`, `--resume`, `--session-id`, output formats, and permission modes.
- [Agent SDK sessions](https://code.claude.com/docs/en/agent-sdk/sessions) - Continue, resume, fork, and session persistence behavior.
- [Claude Code common workflows](https://docs.anthropic.com/en/docs/claude-code/tutorials) - Plan mode, sessions, worktrees, subagents, and automation workflows.
- [Claude Code memory](https://docs.anthropic.com/en/docs/claude-code/memory) - `CLAUDE.md`, `/memory`, and memory scoping.
- [Claude Code slash commands](https://docs.anthropic.com/en/docs/claude-code/slash-commands) - Built-in and custom slash commands.
- [Claude Code hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) - `PreToolUse`, hook outputs, and blocking behavior.
- [Claude Code MCP](https://docs.anthropic.com/en/docs/claude-code/mcp) - MCP server scopes and configuration in Claude Code.
- [Claude Agent SDK overview](https://docs.anthropic.com/en/docs/claude-code/sdk) - Programmable agents with built-in tools, hooks, sessions, MCP, and subagents.
- [Claude Code subagents](https://docs.anthropic.com/en/docs/claude-code/sub-agents) - Subagent contexts, tool limits, and configuration.

### MCP Documentation

- [MCP overview](https://modelcontextprotocol.io/docs) - What MCP is and why it exists.
- [MCP architecture overview](https://modelcontextprotocol.io/docs/learn/architecture) - Host/client/server architecture and unified tool registry.
- [MCP tools specification](https://modelcontextprotocol.io/specification/2024-11-05/server/tools) - Tool discovery, calling, and error handling.
- [MCP resources specification](https://modelcontextprotocol.io/specification/2025-06-18/server/resources) - Resources as context, URI handling, subscriptions, and resource errors.
- [MCP Inspector](https://modelcontextprotocol.io/docs/tools) - Debugging MCP servers and validating tools/resources/prompts.

### Anthropic Engineering and Courses

- [Building effective agents](https://www.anthropic.com/engineering/building-effective-agents) - Agentic workflow patterns and when to use them.
- [Claude Code best practices](https://www.anthropic.com/engineering/claude-code-best-practices) - Practical development workflow guidance.
- [Anthropic Cookbook](https://github.com/anthropics/anthropic-cookbook) - Implementation examples for tool use, extraction, and workflows.
