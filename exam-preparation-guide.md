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
| `any` | Claude must call one of the provided tools | Extraction where the document type is unknown but one extraction tool must be used |
| `tool` | Claude must call a specific named tool | A pipeline stage that must produce one schema before enrichment |
| `none` | Claude cannot call tools | Pure text response or a step where tools are unsafe/unneeded |

For extraction systems, common patterns are:

1. Use `output_config.format` with a JSON Schema when you want the response body to be validated JSON.
2. Define an extraction tool whose input schema is the desired output schema when the extraction is modeled as a tool call.
3. Set `tool_choice` to a required tool or to `any` across several extraction tools when a tool call must happen.
4. Validate the result in application code.
5. If semantic validation fails, call Claude again with the source, the invalid extraction, and the validation errors.

Tool definitions, tool schemas, output schemas, and tool-use/result blocks count as input tokens or add injected prompt overhead. A large schema can push long-document extraction close to the context limit, even if the document itself seems to fit.

Structured outputs also have operational implications: the first request for a schema may have additional latency while the grammar is compiled; schemas are cached for reuse; very complex schemas can exceed compilation limits; refusals or max-token stops can still produce nonconforming output. Do not treat schema compliance as a substitute for domain validation.

### Partial Assistant Prefill

Claude can continue from a partially filled assistant response in some API patterns. This can be useful for response format control, such as starting directly with `{` for text JSON-style output or preventing repetitive greetings by providing a concise opening. Use this carefully: schema-constrained tool use is usually better than relying on text prefill for machine-readable output.

### Common Pitfalls

- **Assuming Claude has persistent memory.** It does not. Your app manages state and history.
- **Treating `session_id` as model memory.** A session identifier can locate stored context in your system, but it does not automatically change what Claude sees.
- **Forcing text JSON with prompt instructions when tool use is available.** Prompt-only JSON is more fragile than schema-backed tool use.
- **Ignoring tool-definition token cost.** Large tool schemas reduce the remaining budget for documents, conversation, and outputs.

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
- Atomic operations where separate calls create race conditions.

Keep steps separate when the model must inspect intermediate results before deciding.

Original examples:

- A news-curation agent can use a composite `discover_and_score_articles(topic)` tool that returns candidates plus relevance scores, while leaving `add_article_to_collection(article_id)` separate because editorial selection requires judgment.
- A booking system might combine "check availability" and "reserve slot" into one atomic operation if separate calls risk another user taking the slot between calls.
- A research workflow should not combine "retrieve sources" and "write final conclusion" because the model needs to inspect the sources and preserve provenance.

### Large Tool Sets and Progressive Availability

Tool selection degrades when the model must choose among too many similar tools. If an agent has dozens of external connectors, API operations, or domain-specific tools, do not expose everything at once by default.

Use progressive availability:

1. Start with a small set of discovery tools, such as `search_available_connectors` or `find_relevant_operations`.
2. Return a ranked shortlist with names, descriptions, required inputs, and confidence.
3. Add or enable only the selected matching tools for the next step, or route through an orchestrator that narrows the tool set.

This is different from a monolithic `find_and_execute` tool. Search-and-execute hides the final decision and can perform the wrong action too early. A discovery tool should narrow the choices; the agent or user should still be able to inspect the selected operation before execution when risk is meaningful.

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

- **Protocol errors**: the request could not be processed as a protocol operation. Examples: unknown tool, malformed JSON-RPC request, invalid arguments at the protocol boundary, unsupported method.
- **Tool execution errors**: the tool was invoked, but the underlying operation failed. Examples: upstream API returned 404 or 503, business rule violation, permission denial, rate limit.

Do not turn ordinary business failures into protocol failures. A missing record in the backend is not a JSON-RPC protocol failure; it is a tool execution result with `isError: true`.

### Retry Responsibility

Place retry logic where the needed information lives.

- Tool-level retry is right for transient backend failures where the same request should succeed.
- Model-level retry is right when the model needs to change inputs or strategy.
- Human approval is needed when retrying may duplicate a side effect or violate a policy.

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

Few-shot examples are especially effective when the model is inconsistent across varied document structures. Show complete input-output pairs for edge cases: missing data, ambiguous sentiment, informal units, compound skills, multiple values, amendments, and values buried in nonstandard sections.

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
- Fields are not copied into the wrong category.

When validation fails, do not blindly retry the same request. Send a correction request that includes the source document, the previous extraction, and the exact validation errors. This is much more effective than asking the model to "try again."

Example correction prompt structure:

```text
The extraction below failed validation.

Validation errors:
- line_items_total does not equal stated_total
- vendor_id does not match the expected pattern

Return a corrected call to extract_invoice. Do not change fields unless needed to fix the errors.
```

Some failures cannot be fixed by retrying. If the needed information is in an external document that was not provided, additional retries will not invent reliable evidence. Retrieve the missing source or route to human review.

### Long and Scattered Documents

Long documents can fit in the context window and still be hard to extract from when facts are scattered, repeated, or revised over time. Accuracy often improves when you split the task into stages:

1. Identify and summarize the relevant sections, decisions, tables, or events.
2. Extract structured data from that focused intermediate representation.
3. Preserve source locations so the extraction can be audited against the original.

Use chunking when documents exceed context limits or when independent sections can be processed separately. Use a pre-extraction summarization or mapping step when the document fits but the key facts are distributed across a meandering transcript, long contract, or multi-section report. Chunking alone can lose cross-section relationships; summarization alone can lose exact values. Choose based on the failure mode.

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

Even high-confidence automation needs ongoing sampling. Use stratified random review of high-confidence outputs to detect hidden error patterns and measure whether improvements actually reduce error rates.

### Feedback Loops

Human corrections should feed prompt and schema improvements. Look for recurring patterns:

- Informal units being converted incorrectly.
- Compound phrases split inconsistently.
- Missing fields in nonstandard sections.
- False positives in code review findings.
- Repeated validation failures by field.

Add few-shot examples or schema changes that target the pattern. Do not jump immediately to fine-tuning or heavy infrastructure when a focused prompt/schema improvement addresses the failure.

### Batch Extraction

For high-volume asynchronous extraction, the Message Batches API can reduce cost but adds latency. Use it when the workflow tolerates delayed results. Use real-time Messages API for urgent documents, interactive user flows, or SLA-sensitive alerts.

Batch requests have `custom_id` values. Results may not arrive in the same order as requests, so always join results by `custom_id`. If a small percentage fail due to context length or validation errors, resubmit only the failed documents after fixing the cause, such as chunking long inputs or improving the prompt.

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

Use sliding windows for short, transactional flows where old context has little value.

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

Bad summaries are vague narratives. They lose the exact facts that users later ask about.

### Structured State

When users revise preferences, maintain a canonical state object that represents current truth:

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

This is more reliable than expecting the model to infer the current preference from a long conversation containing old and new values.

When preferences conflict, do not silently pick one if the decision matters. Surface the conflict and ask the user to resolve it before making a recommendation.

### Retrieval and Fact Stores

Summaries lose precision. If users need exact p-values, source quotes, clauses, measurements, transaction IDs, or numeric thresholds, store facts in a structured database or retrieve the relevant source passage when needed.

For research assistants, combine:

- Summaries for the interpretive discussion.
- Source retrieval for exact claims.
- Structured fact tables for recurring numerical lookups.

### Tool Result Compression

Verbose tool results can crowd out useful conversation. After a tool result has been processed, extract the fields that matter and drop the rest.

Example: after retrieving order details, keep `order_id`, `purchase_date`, `items`, `return_window`, `payment_status`, and `resolution_state`; discard internal backend fields, unrelated shipping events, and duplicated metadata.

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

XML-style tags are not magic, but they improve salience and organization.

### Principles vs Conditionals

Use general principles for judgment-heavy behavior:

- "Adapt explanation depth to the user's demonstrated expertise."
- "Prefer one clarifying question at a time."
- "State reasonable assumptions when moving forward under ambiguity."

Use explicit conditionals for safety-critical triggers:

- "If the user describes an immediate medical emergency, direct them to emergency services."
- "If the request requires a regulated financial decision, do not provide personalized advice."

If a rule must hold 100% of the time, move it out of the prompt and into code.

### Few-Shot Examples

Examples often outperform long prose instructions. Use examples when you need the model to learn distinctions:

- Beginner vs expert explanations.
- Acceptable vs reportable code review findings.
- Correct extraction from unusual document layouts.
- Good vs bad clarifying-question behavior.
- Handling missing information without fabrication.

Keep examples realistic and compact. Show the exact behavior you want.

### Prompt Dilution

System prompt adherence can weaken as conversation grows, even before the context window is full. The assistant's previous responses become a behavioral pattern. Mitigations:

- Use concise, well-structured system prompts.
- Put critical instructions in salient sections.
- Include behavioral examples.
- Add natural reminders before complex tasks.
- Validate or enforce important rules outside the model.

For long-running workflows, reinforcement can be inserted as application state or user-role reminders at natural breakpoints. Avoid cluttering every turn with giant repeated instructions.

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

When user preferences conflict, do not average them into a vague compromise. Name the tension and ask which priority should govern.

### Response Format Control

If responses become repetitive, do not only add "never say X" lists. Better options include:

- Better examples in the system prompt.
- A concise style guide.
- Partial assistant prefill for specific API calls.
- Post-processing for purely cosmetic cleanup when safe.

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

MCP tool annotations such as read-only or destructive hints are metadata supplied by the server. They are not a security boundary. Use them as UI or planning hints, not as proof. Confirmation and permission decisions should depend on server trust, tool identity, user policy, and operation risk.

### MCP Error Handling

Tools use two error mechanisms:

- JSON-RPC protocol errors for protocol-level failures.
- Tool results with `isError: true` for execution failures.

For resources, servers should validate URIs and return appropriate JSON-RPC errors for not found or internal failures.

### MCP in Claude Code

Claude Code can configure MCP servers at several scopes:

- Project scope uses `.mcp.json` in the repository root and is meant for shared team configuration.
- Local and user scopes are stored in `~/.claude.json`, with local tied to the current project entry and user available across projects.
- If the same server name exists at multiple scopes, higher-precedence definitions win.

Use project scope for shared tools required by the repo. Use user scope for personal tools used across many projects. Use local scope for sensitive or experimental project-specific setup.

MCP prompts can appear as slash commands. MCP output can be large; control output size so it does not crowd out the conversation.

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

### Multi-Agent Context Passing

Subagents do not automatically share full conversation state. A coordinator must pass the context each subagent needs. Usually that means a concise task, relevant findings, source references, constraints, and expected output shape.

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

### Parallel Execution

If tasks are independent, the coordinator should start them concurrently rather than serially. In tool-calling systems, that often means emitting multiple tool calls in one assistant turn when the platform supports parallel tool calls. In an external orchestrator, it may mean launching concurrent SDK calls and aggregating results.

Do not parallelize when the second task needs the first task's output. For example, document analysis cannot inspect sources until sources are identified, but analyzing independent source documents can run in parallel after retrieval.

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

### Graceful Degradation

If a tool fails mid-workflow, the agent should still deliver useful progress:

- Explain what has been verified.
- State what could not be completed.
- Be transparent about system issues.
- Offer next steps such as retry, escalation, or notification.

Do not claim a side effect will happen if the system has not completed it. Do not immediately escalate when the agent can still answer part of the user's problem.

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

### Sessions

Key CLI behaviors:

- `--continue` resumes the most recent conversation in the current directory.
- `--resume` / `-r` resumes a specific session by ID or name, or opens a picker.
- `--session-id` uses a specific UUID for the conversation.
- `--fork-session` creates a new session branched from an existing conversation history, useful for exploring alternatives without appending both paths to the same transcript.

Use a named or specific session when returning to a known investigation. Use `--continue` only when the most recent conversation is definitely the one you want.

If the codebase changed since the previous session:

- Resume and tell Claude exactly which files or functions changed when most prior context remains useful.
- Start fresh with a summary when the old transcript is likely stale or misleading.

Sessions persist conversation history, not the filesystem state. If you need isolated file changes, use git branches or worktrees. For comparing two alternative implementations, fork or branch the session when available so each approach can evolve independently. For parallel filesystem work, use separate worktrees to prevent edits from colliding.

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

`CLAUDE.md` files store project or user memory: build commands, conventions, architecture notes, testing standards, and workflow preferences.

Use `/memory` to inspect and edit loaded memory files. This is the first diagnostic step when Claude inconsistently follows project conventions: confirm the expected memory file is loaded before adding more instructions.

Prefer scoped memory:

- Root `CLAUDE.md` for repo-wide rules.
- Subdirectory `CLAUDE.md` files for area-specific conventions.
- `@imports` to reuse shared standards without duplicating content.
- Personal memory for individual preferences, not team rules.

Do not put every occasional workflow into global memory. A code-review checklist belongs in a slash command or review subagent if it is only relevant during reviews.

### Slash Commands

Slash commands are reusable prompts. Use them for explicit workflows that developers invoke intentionally:

- `/review` for a review checklist.
- `/release-notes` for release note formatting.
- `/migration-plan` for a standard migration analysis.

Project commands are shared with the repo; user commands are personal. MCP prompts can also appear as slash commands.

### Hooks and Permissions

Hooks run at lifecycle events such as before a tool call, after a tool call, or when a session starts. A `PreToolUse` hook can block a dangerous command before it runs. This is the correct class of mechanism for "must always require approval" policies.

Examples:

- Block destructive Bash patterns unless approved.
- Prevent edits to generated files.
- Run a formatter after successful edits.
- Add environment context at session start.

Hooks execute shell commands in your environment. Treat them as code with security implications.

### Subagents

Subagents have separate context windows, focused prompts, and configurable tool access. Use them when a side task would flood the main context, when specialized behavior is reused, or when independent work can run in parallel.

Good subagent design:

- Clear single responsibility.
- Specific description so Claude knows when to use it.
- Limited tools needed for the role.
- Output contract that the coordinator can consume.

Avoid making every subagent inherit every tool. Tool restriction improves focus and security.

In Agent SDK and Claude Code configurations, delegation still requires the agent to have access to the tool or mechanism that launches subagents. If an agent describes a delegation but no subagent runs, check tool permissions and whether the subagent invocation tool is allowed.

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

The Message Batches API processes many Messages API requests asynchronously. It supports the same general request shape as Messages API calls, including model, messages, tools, and system prompts. Each request has a `custom_id` used to match results.

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

Anthropic's docs describe batch usage as discounted relative to standard API calls and note that batches can take up to 24 hours to complete. Results may not be ordered like inputs, so `custom_id` is mandatory for reliable processing.

Operational details to know:

- A batch has a processing status such as in progress, canceling, or ended.
- Individual results can succeed, error, be canceled, or expire.
- Batch results are returned as JSONL and should be streamed or processed incrementally for large jobs.
- Validate your request shape with the standard Messages API before submitting a large batch.
- Batch size and request count have platform limits, so large pipelines may need multiple batches.

### SLA Design

When documents arrive continuously, choose a batch cadence based on deadline minus worst-case processing window and operational buffer.

Example: if results must be available within 30 hours and processing may take up to 24 hours, submitting once at the end of the day can violate the SLA for early-day arrivals. Submit smaller periodic batches so each document enters processing with enough buffer.

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
- Split tools when required parameters differ by operation.
- Use progressive discovery for very large tool sets instead of exposing every tool at once.
- Return structured IDs and metadata for chaining.
- Accept stable IDs in downstream tools when intermediate lookup fields are mechanical.
- Empty result is success with no matches, not an error.
- Use preview-token-execute for mandatory confirmation.
- Enforce hard limits in code, not prompts.

### Error Handling

- Retry transient read/infrastructure failures inside the tool when safe.
- Return validation and business errors with structured, non-retryable metadata.
- Treat write timeouts as uncertain state unless idempotency proves otherwise.
- MCP protocol errors are JSON-RPC errors; tool execution errors are `isError: true`.
- Do not use exceptions for expected business failures.

### Structured Extraction

- Use structured outputs or tool use with schema for reliable structured output.
- Optional/nullable fields prevent forced hallucination.
- Add `unclear`, `other`, or detail fields when categories are ambiguous or evolving.
- Use few-shot examples for varied document layouts and edge cases.
- Validate semantics after schema validation.
- Correct with validation-error feedback.
- Use pre-extraction mapping/summarization for long documents with scattered facts.
- Add source locations for auditability.
- Calibrate confidence before automation.
- Sample high-confidence outputs to catch hidden errors.

### Context Management

- Sliding window: simple, loses older context.
- Progressive summary: preserves narrative decisions and themes.
- Structured state: best for current preferences.
- Retrieval/fact store: best for exact numbers, clauses, and quotes.
- Compress verbose tool results into relevant fields.
- Returning users need summaries plus fresh lookups.
- Version prompts for long-lived conversations.

### System Prompts

- Use sections and examples.
- Principles for judgment; explicit conditionals for safety triggers.
- Move deterministic guarantees into code.
- Few-shot examples beat long abstract instructions for subtle distinctions.
- Reinforce critical guidelines at natural breakpoints in long sessions.
- Ask clarifying questions for irreversible or materially ambiguous actions.
- State assumptions for low-risk ambiguity.

### MCP

- Tools are model-controlled actions.
- Resources are application-controlled context.
- Prompts are reusable workflow templates.
- MCP enables reusable integrations across clients.
- MCP does not automatically handle auth, retries, or rate limits.
- Tool annotations are hints, not guarantees.
- Poor descriptions cause poor tool selection.
- Project MCP config uses `.mcp.json`; local/user Claude Code MCP config uses `~/.claude.json`.

### Agentic Patterns

- Prompt chaining: fixed steps.
- Routing: classify then dispatch.
- Orchestrator-workers: coordinator chooses subtasks.
- Dynamic decomposition: investigative work that changes as facts emerge.
- Parallel subagents: independent tasks.
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
- `--fork-session` branches a prior conversation into a new session.
- Use scratchpads for long investigations.
- Use `/memory` to inspect loaded `CLAUDE.md`.
- Use slash commands for task-specific reusable workflows.
- Use `PreToolUse` hooks for deterministic blocking.

### Batch Processing

- Use Message Batches for high-volume asynchronous work.
- Avoid batch when users need immediate results.
- Use `custom_id` to match unordered results.
- Resubmit only failures.
- Chunk context-length failures.
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
