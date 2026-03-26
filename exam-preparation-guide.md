# Claude Certified Architect – Foundations: Exam Preparation Guide

## Overview

This certification covers the practical knowledge required to design, build, and operate production-quality applications powered by Claude and large language models. The exam focuses on four interconnected domains: **designing tool interfaces** that agents use effectively, **managing conversation context** across extended interactions, **writing system prompts** that drive consistent behavior, and **building agentic workflows** that balance autonomy with safety.

Candidates should expect questions that go beyond surface-level recall. The exam emphasizes understanding *trade-offs* — why one approach is better than another in a specific situation, how design decisions ripple through a system, and where the boundaries lie between what the model should decide and what the application must enforce programmatically. You should be comfortable reasoning about real-world failure modes: tools that return ambiguous errors, conversations that exceed context limits, agents that skip confirmation steps, and system prompts whose influence fades over time.

If you are new to LLMs, start with the foundational concepts (how the API works, what context windows are, why models are stateless) before moving into tool design and agentic patterns. If you have experience building LLM applications, focus your study on the nuances — especially around error handling strategies, MCP trust semantics, and the difference between prompt-based and programmatic enforcement of business rules.

---

## 1. Designing Tool Interfaces for LLM Agents

### What to Know

When an LLM agent interacts with the outside world — querying databases, calling APIs, modifying records — it does so through *tools*. A tool is essentially a function signature that the model can choose to invoke: it has a name, a description, and typed parameters. The quality of this interface determines whether the agent uses the tool correctly, selects the right tool for the job, or even knows the tool exists.

**Descriptions are the primary steering mechanism.** The model selects which tool to call and how to populate its parameters based almost entirely on the tool's name, description, and parameter descriptions. A vague description like "Analyzes dependencies" will lose out to a well-described built-in alternative every time. Effective descriptions explain *what the tool does*, *when to use it instead of alternatives*, *what inputs it expects* (with format examples), and *what the output contains*. Think of the description as the tool's documentation — if a human developer couldn't figure out how to use it from the description alone, the model won't either.

**Parameter design shapes correctness.** When parameters are ambiguous — a bare `string` for dates, free-text fields for names that should come from a controlled vocabulary — the agent will inevitably produce invalid combinations. The most effective mitigation depends on the nature of the ambiguity:

- When parameters have *interdependent constraints* (e.g., the valid payment method depends on the region or currency), consider splitting into separate tools where each enforces its own constraints structurally. A `create_bank_transfer(amount, iban, bic)` tool makes it impossible to pass a credit card number — the parameter simply doesn't exist.
- When the problem is *entity resolution* (matching free-text input to a specific record), introduce a lookup-then-act pattern: one tool to search and return identifiers, a second tool to act on a specific ID. This eliminates ambiguity at the point of action.
- When parameters have known valid values, use `enum` constraints in the schema, but recognize that enums alone don't capture *relationships* between parameters.

**Clear parameter descriptions beat verbose parameter names.** Writing `account_number_integer_eight_digits` as a parameter name is less effective than a concise description: `"account_number": 8-digit customer account ID (e.g., "10482930")`. The model reads descriptions; it doesn't parse semantic meaning from camelCase naming conventions.

**Structured output enables tool chaining.** When one tool's output becomes another tool's input, the format matters enormously. If a product search tool returns `"Found 3 items: 'Blue Widget', 'Red Gadget', 'Green Sprocket'"`, the agent must parse a natural-language string to extract identifiers for the next call. If it returns `[{"id": "prod_881", "name": "Blue Widget", "price": 24.99, ...}]`, the agent can directly pass `prod_881` to an `add_to_cart(product_id, quantity)` call. Structured responses with explicit IDs and metadata are essential for reliable multi-step workflows.

**Return useful context, not just acknowledgments.** When a tool performs an action (provisioning resources, placing an order), the response should include the details a user would need to understand what happened: costs, target project, specifications, timestamps. If a tool returns only "Done," users are left asking follow-up questions that the system could have answered proactively.

### Key Relationships

Tool design intersects heavily with error handling (covered next) — how a tool reports failures is as important as how it reports successes. It also connects to context management: verbose tool responses consume context window space, so designing lean structured responses matters in long conversations. And tool descriptions are the bridge to MCP adoption: if your MCP tools have poor descriptions, agents will default to built-in alternatives regardless of how capable the MCP tools are.

### Common Pitfalls

- **Relying on prompt instructions to enforce tool usage patterns.** If you need the agent to always call a preview before executing a destructive action, embedding that requirement in a prompt instruction produces an inherently unreliable guarantee. The model may skip the preview step some percentage of the time. Structural enforcement — like requiring a single-use token from the preview tool to call the execution tool — is deterministic.
- **Conflating schema validation with behavioral guidance.** Marking a field as `required` in JSON Schema ensures the parameter is present, but doesn't help the model understand what *value* to provide. Schema constraints and descriptive documentation serve complementary purposes.
- **Over-composing tools.** Combining multiple operations into one tool improves efficiency when the intermediate steps don't require model judgment. But if the model needs to *see* intermediate results to make a decision (which articles to include, which records to delete), those steps must remain visible. Combine mechanical steps; keep decision points separate.
- **Designing tools with `preview: boolean` flags for safety-critical operations.** A single tool with a preview parameter creates a path where the agent can skip the preview. Two separate tools — one that generates a plan and returns a one-time approval code, one that executes and requires that code — make the unsafe path structurally impossible.

### Go Deeper

- **The lookup-then-act pattern**: Understand when to decompose a single tool with ambiguous parameters into a search/lookup tool paired with an action tool that takes an unambiguous identifier. This pattern appears frequently when tools operate on entities that users refer to by natural language names.
- **Balancing tool granularity and efficiency**: Too many fine-grained tools cause excessive round-trips and latency. Too few coarse tools remove the model's ability to exercise judgment at decision points. Study how to identify which steps can be combined without hiding decisions the model needs to make.
- **Confirmation and safety flows for destructive operations**: Understand the spectrum from prompt-based instructions (unreliable) through tool annotations (hints only) to structural enforcement (tokens, two-tool patterns). Know when each level of protection is appropriate.

---

## 2. Error Handling in Agent Tools

### What to Know

Error handling is one of the most consequential aspects of tool design, and one of the most commonly underinvested. When a tool fails, the information it returns determines whether the agent retries intelligently, communicates clearly to the user, or wastes turns on futile attempts.

**The fundamental distinction: transient vs. permanent errors.** A network timeout (503, connection reset) is transient — the same request may succeed moments later. A business rule violation ("order exceeds 30-day return window") is permanent — no amount of retrying will change the outcome. If a tool returns the same generic error for both types, the agent has no basis for choosing the right response. It will waste calls retrying permanent failures and tell users to "try again later" for issues that could be resolved immediately.

**The best practice is to handle what you can at the tool level.** For transient errors like network timeouts, implement automatic retry with backoff *inside the tool implementation itself*. The model never needs to know a transient failure occurred — it just sees a slightly delayed success. For permanent errors like validation failures, return the error immediately with enough detail for the agent to explain the situation to the user and suggest alternatives. This division keeps the model focused on user communication rather than infrastructure resilience.

**Structured error responses outperform plain text messages.** Rather than returning `"Error: Operation failed"`, return structured data:

```json
{
  "error_type": "business_rule",
  "error_category": "validation",
  "retryable": false,
  "message": "Account balance insufficient for transfer (available: $1,200, requested: $5,000)",
  "customer_explanation": "Your account doesn't have enough funds to complete this transfer."
}
```

This gives the agent everything it needs: it knows not to retry, understands the root cause, and has a customer-friendly explanation ready.

**Uncertain state requires special handling.** When a tool calls an external API that times out during a *write* operation (sending a notification, processing a payment), the tool often cannot determine whether the operation succeeded or failed. This is fundamentally different from a read-timeout. The tool should communicate this uncertainty explicitly: "Status unknown — the message may have been sent. Do not retry." If the tool returns a generic "failed" message, the agent will retry, potentially causing duplicate operations (double charges, duplicate notifications).

**Errors as normal tool output, not exceptions.** In the agent tool paradigm, errors should be returned *as content within the tool result*, not thrown as exceptions. When a tool throws an exception, the framework typically catches it and presents a generic error to the model, stripping away all the contextual detail the model needs. Return errors in the `content` field and use the `isError` flag to signal that the result represents a failure.

### Key Relationships

Error handling connects directly to tool design (the structure of error responses is a tool design decision) and to agentic workflows (whether an agent retries, escalates, or explains depends on error categorization). It also connects to the MCP protocol, which has its own specific conventions for error reporting.

### Common Pitfalls

- **Treating all errors identically.** This is the single most common mistake. Uniform error responses produce unpredictable agent behavior because the model must guess at the appropriate response.
- **Returning `retryable: true` for operations with uncertain outcomes.** If you don't know whether a notification was sent, marking it as retryable will cause duplicates. Err on the side of communicating uncertainty and letting the user decide.
- **Using exceptions instead of structured error returns.** Framework-level exception handling strips context. Return errors as tool content.
- **Relying on the model to parse error messages for classification.** Few-shot examples teaching the model to distinguish "503 Service Unavailable" from "Order not found" by text parsing is fragile. Structured metadata is reliable.

### Go Deeper

- **Idempotency and uncertain state**: Study how to handle the case where a side-effecting operation times out and you don't know if it succeeded. This is a particularly subtle aspect of distributed systems that has direct implications for agent tool design.
- **MCP-specific error patterns**: The Model Context Protocol distinguishes between *protocol-level* errors (malformed requests, invalid parameters — reported as JSON-RPC errors) and *application-level* errors (API failures, business rule violations — reported as tool results with `isError: true`). Understand which category different failure modes fall into.
- **Where to place retry logic**: Understand the trade-off between tool-level retries (transparent to the model, good for transient infrastructure issues) and model-level retries (visible to the model, appropriate when the model needs to modify its approach).

---

## 3. Conversation Context Management

### What to Know

This is arguably the most important foundational concept for anyone building LLM applications: **the Claude API is stateless.** Claude does not maintain any internal memory between API calls. Every time you send a request, you must include the *entire* conversation history you want the model to consider. If a message is not in the `messages` array, it does not exist for the model.

This has immediate, practical consequences:

- **Costs and latency grow with every turn.** Because the full conversation history is sent with each request, input tokens increase linearly as conversations extend. A 60-turn conversation sends far more tokens per request than a 5-turn conversation, resulting in higher costs and noticeably slower responses.
- **"Memory loss" is almost always an application bug.** If the model forgets something the user said three messages ago, the most likely cause is that your application is not including prior messages in the `messages` array. There is no `session_id` parameter, no built-in memory system, no vector database requirement. The model sees exactly what you send.
- **Context windows are finite.** Even though modern models have large context windows (100K–200K tokens), long-running conversations, accumulated tool responses, and injected RAG results will eventually approach these limits. You need a strategy.

**Strategies for managing long conversations:**

1. **Sliding window**: Keep only the most recent N turns. Simple and effective for conversations where users rarely reference earlier exchanges. The drawback is complete loss of older context — if a user asks about something from 20 turns ago, it's gone.

2. **Progressive summarization (hybrid approach)**: Summarize older conversation turns into a condensed running summary while keeping the most recent 5-8 turns verbatim. This is generally the most effective general-purpose strategy because it preserves historical context in compressed form while keeping recent exchanges at full fidelity. The summary should explicitly extract key decisions, conclusions, stated preferences, and important facts — not just a vague narrative.

3. **Structured state extraction**: For conversations where users iteratively refine preferences or requirements, maintain a structured JSON object capturing the *current* state (budget, preferences, filters, etc.) and include it in every request. This is more reliable than depending on the model to correctly identify the most recent preference from a long history where old and new values coexist.

4. **Retrieval-based approaches**: For scenarios requiring precision recall of specific details (numerical data, exact quotes, statistical values), store extracted facts in a structured database or indexed store and retrieve relevant entries when the user's question requires them. Summaries inherently lose precision — a summary that says "sample sizes ranged from 200-500" is useless when the user asks for the exact sample size of study #3.

**Managing injected content (RAG results, tool outputs):**

Accumulated tool responses and RAG results can crowd out conversation history, degrading coherence. Strategies include:

- Keeping only RAG results from the last 2-3 queries (sliding window on injected content, not conversation history)
- Extracting relevant fields from verbose tool responses when only a subset is needed for the current task
- Summarizing or compressing tool outputs once they've been discussed

**Handling stale data in resumed sessions:** When a user returns to a conversation after hours or days, tool results from the earlier session may be outdated. The most reliable approach is to start a new session with a structured summary of prior interactions and make fresh tool calls before engaging, rather than resuming with the full historical context (which includes potentially stale data the model may reference).

**Injecting real-time information:** When your system receives external updates (webhooks, notifications) during an active conversation, the cleanest pattern is to append the update to the next user message before calling the API. This makes the information part of the natural conversation flow without requiring synthetic assistant responses or constant tool polling.

### Key Relationships

Context management underpins everything else. System prompt adherence degrades as context grows (covered in the next section). Tool response design (Section 1) determines how quickly tool outputs consume context budget. Error handling strategies (Section 2) affect how many wasted turns consume context. And agentic workflows (Sections 6-7) must account for context limits when processing multi-step investigations.

### Common Pitfalls

- **Assuming the model has built-in memory.** This is the most fundamental misconception. The model has no memory, no session state, no internal profile that persists between calls. Your application manages all state.
- **Confusing context capacity with context attention.** Even when context usage is well under half capacity, the model may not reliably track preference changes scattered across many turns. A structured state object is more reliable than trusting the model to always find the most recent version of a preference in conversation history.
- **Summarizing too aggressively.** Summaries inherently lose detail. When users need precision (exact numbers, specific criteria, exact phrasing), summaries produce hedged or inaccurate responses. Know when to use structured fact extraction (database-like) instead of narrative summarization.
- **Accumulating RAG results without cleanup.** If every query's retrieved context stays in the conversation, it crowds out the actual conversation history, degrading coherence.

### Go Deeper

- **Progressive summarization implementation**: Study how to structure summaries that preserve different types of information (decisions, facts, preferences, open questions) at different fidelity levels. Not all historical context degrades equally when summarized.
- **Structured state objects for preference tracking**: Understand when and how to maintain a separate JSON state object that represents the "current truth" of a conversation's accumulated decisions, rather than relying on the model to parse through conversation history.
- **System prompt versioning for multi-session conversations**: When you update a system prompt, existing conversations may produce inconsistent behavior because the model's new instructions conflict with its prior responses in the history. Understand strategies for managing this transition.

---

## 4. System Prompt Engineering

### What to Know

The system prompt is your primary mechanism for shaping model behavior: persona, tone, task-specific guidelines, safety guardrails, and behavioral constraints. It's included at the beginning of every API request and frames the model's interpretation of the conversation that follows.

**General principles outperform exhaustive conditionals.** A common instinct is to write system prompts as decision trees: "If the user says X, do Y. If they say Z, do W." This works for explicit, clear-cut signals but fails for implicit ones. If you write "If the user says they are new to investing, explain every term," the model handles explicit declarations fine but misses contextual cues like domain jargon that implies sophistication. A general principle — "Match financial detail and terminology to the user's demonstrated knowledge level" — gives the model room to interpret signals you haven't explicitly enumerated.

The exception: **safety-critical rules** should remain as explicit conditionals. "If the user describes symptoms of a medical emergency, always direct them to call emergency services" is a rule that must fire reliably and is better as a clear conditional than a vague principle.

**Structure and formatting improve compliance.** When a system prompt contains many instructions and the model consistently ignores one of them, the issue is often salience — the instruction is buried in prose. Organizing the prompt into clearly-delimited sections (XML-style tags like `<escalation_policy>`, `<tone>`, `<guardrails>`) with behavioral examples within each section makes individual instructions more prominent and easier for the model to attend to.

**System prompt influence can be diluted.** As conversations grow, the accumulated assistant responses create a behavioral pattern that can override system prompt instructions. This is not a token-limit issue — it happens even in conversations well within context limits (just a few thousand tokens). The model's attention to the system prompt weakens relative to the growing body of conversational context. Mitigation strategies include:

- Using few-shot examples in the system prompt (concrete demonstrations are more persistent than abstract rules)
- Injecting periodic reminders as system messages at regular intervals
- Restructuring the prompt to place critical instructions in high-attention positions

**Few-shot examples are more resilient than verbose instructions.** A lengthy system prompt packed with written rules about adapting to different audience levels will lose influence over extended conversations. A handful of concrete examples demonstrating appropriate responses at each level show the *difference* directly and tend to maintain influence longer. Show, don't tell.

### Key Relationships

System prompt design is tightly coupled with context management: as context grows, prompt influence fades. It connects to tool design through tool descriptions (which function like mini-prompts). And it intersects with agentic workflow design when you need to decide whether a business rule should be enforced via prompt instruction or programmatic mechanism.

### Common Pitfalls

- **Believing the system prompt is sent only once.** The system prompt is included in *every* API request. It is not a one-time initialization. If your application sends it only with the first request, you've introduced a bug.
- **Using emphatic language ("CRITICAL", "NEVER", "ALWAYS") as a reliability mechanism.** These may slightly increase compliance but do not guarantee it. For rules that must hold 100% of the time, use programmatic enforcement outside the model.
- **Adding more conditionals to cover edge cases.** Each additional conditional branch makes the prompt longer and dilutes the attention given to each one. When you find yourself writing increasingly specific conditions, consider whether a general principle would handle the cases more gracefully.
- **Ignoring prompt versioning.** Updating a system prompt for ongoing multi-session conversations can cause the model to contradict its own prior statements, because the new instructions conflict with patterns in the historical context.

### Go Deeper

- **Prompt structure and attention**: Study how the position and formatting of instructions within a system prompt affect compliance rates. XML-style section delimiters, examples within sections, and strategic placement of critical rules all influence how reliably the model follows instructions.
- **The dilution problem in extended conversations**: Understand why system prompt compliance degrades even in relatively short conversations and the relative effectiveness of different mitigation strategies (periodic reminders, few-shot examples, structural reinforcement).
- **Principles vs. conditionals**: Practice identifying when a set of conditional rules can be collapsed into a general principle and when a rule must remain explicit. The distinguishing factor is usually whether the rule requires *judgment* (use a principle) or must fire *deterministically* (keep it explicit, or enforce programmatically).

---

## 5. Model Context Protocol (MCP)

### What to Know

The Model Context Protocol is a standardized interface for connecting AI agents to external tools and data sources. Rather than writing custom integration code for each tool in each application, MCP provides a common protocol: you build an MCP *server* that wraps your API or data source, and any MCP-compatible *client* (agent application) can discover and use its tools automatically.

**The core value proposition is reusability.** If your team builds multiple AI applications that all need access to the same data (weather, Jira tickets, git operations), an MCP server exposes that data once. Each application connects to the server and discovers its tools at connection time — no custom integration code per application. This is MCP's primary advantage over custom tool implementations.

**MCP does NOT provide:** automatic authentication handling, built-in retry logic, rate limiting, or performance optimization through binary protocols. These are responsibilities of your MCP server implementation or your application. MCP is a protocol for tool discovery and invocation, not a middleware framework.

**Multi-server tool availability.** When an agent connects to multiple MCP servers (e.g., one for a CRM, one for Slack, one for a metrics dashboard), tools from *all* connected servers are discovered at connection time and available simultaneously. The agent doesn't need to be told which server to use — it sees a flat list of all tools and selects based on descriptions. This makes tool descriptions even more critical: if tools from different servers have overlapping or vague descriptions, the model may select poorly.

**Tool descriptions are the adoption bottleneck.** The most common failure mode with MCP tools is *non-adoption*: the agent has access to a specialized MCP tool but uses a built-in alternative instead (e.g., using Grep to manually search for SQL patterns instead of calling a dedicated `scan_sql_vulnerabilities` tool). In nearly every case, this is because the MCP tool's description is too vague. The model cannot understand when the MCP tool is preferable to a familiar built-in. Expanding descriptions to explain capabilities, expected inputs, output format, and when to prefer this tool over alternatives is the most effective remedy — more effective than adding routing instructions to the system prompt or removing competing tools.

**MCP trust model: annotations are untrusted.** MCP tools can carry annotations like `readOnlyHint: true` or `destructiveHint: true`. These are *self-reported* by the server. A tool annotated as read-only might not actually be read-only — the annotation is metadata, not a security guarantee. Trust decisions (such as bypassing confirmation prompts for "read-only" tools) should be based on your assessment of the *server's trustworthiness*, not on the server's self-reported annotations. Treat annotations from untrusted servers the same way you'd treat claims in an unverified email.

**MCP error handling follows a two-tier model:**

- **Protocol-level errors** (malformed requests, missing required parameters, invalid JSON-RPC) — these are reported as JSON-RPC error responses. They indicate the request itself was invalid.
- **Application-level errors** (API returned 404, service unavailable, business rule violation) — these are reported as normal tool results with `isError: true` in the result content. The tool was invoked correctly, but the operation it performed encountered a problem.

The distinction: protocol errors mean the tool *wasn't called properly*. Application errors mean the tool *was called properly but the operation failed*.

**When to use MCP vs. custom tools**: Use MCP when the integration serves multiple applications or when a community/vendor MCP server already exists for your data source (Jira, Slack, databases). Use custom tools when the integration is tightly coupled to a single application's specific workflow and reusability isn't a concern.

### Key Relationships

MCP connects to tool design (descriptions drive adoption), error handling (the two-tier error model), and developer productivity workflows (where MCP servers provide code analysis, ticketing, and documentation tools). Understanding MCP is essential for the sections on agentic patterns, where agents coordinate across multiple tool sources.

### Common Pitfalls

- **Assuming MCP handles infrastructure concerns automatically.** MCP is a protocol, not a platform. Authentication, retries, rate limiting, and caching are your responsibility.
- **Writing minimal tool descriptions ("Checks code quality").** These are the primary reason agents don't adopt MCP tools. Invest in descriptions.
- **Trusting tool annotations from unverified servers.** Self-reported metadata is not a security boundary.
- **Thinking MCP tools are per-request.** All tools from all configured servers are available simultaneously — you don't select a server per turn.

### Go Deeper

- **MCP error tier classification**: Practice categorizing different failure scenarios into protocol-level vs. application-level. A missing required parameter is protocol-level. A 404 from the underlying API is application-level. A 503 from the underlying API is also application-level. This distinction determines the error reporting mechanism.
- **Optimizing MCP tool descriptions for adoption**: Study the difference between descriptions that win tool selection ("Runs static analysis across all source files, checking for unused variables, unreachable code, and style violations. Returns severity-ranked list with file paths, line numbers, and suggested fixes.") vs. descriptions that lose to built-in alternatives ("Checks code quality").
- **Choosing between existing and custom MCP servers**: For standard integrations (Jira, GitHub, Slack), an existing community MCP server is almost always the right choice. Custom MCP servers are justified when your workflow has unique requirements that generic tools don't address.

---

## 6. Agentic Patterns and Task Decomposition

### What to Know

Agentic applications give the model autonomy to plan and execute multi-step tasks. Rather than responding to a single prompt, the agent iterates: it reads information, reasons about what to do next, takes an action, observes the result, and repeats. Understanding the patterns for structuring this autonomy is essential.

**The agentic loop: observe → reason → act.** At each step, tool results are added to the conversation and the model reasons about what action to take next. This is not a pre-configured decision tree or a fixed sequence of tool calls — the model dynamically decides its next action based on what it has learned so far. This flexibility is what makes agents powerful, but it also means the model needs sufficient context (tool descriptions, error information, prior results) to make good decisions.

**Task decomposition patterns:**

- **Prompt chaining**: Break a task into a fixed sequence of steps where each step's output feeds the next. Best for predictable, repeating workflows (e.g., a code review that always checks style, then security, then documentation). The key characteristic: the steps are known in advance and don't change based on intermediate results.

- **Routing**: Classify the input first, then dispatch to a specialized prompt or workflow. Best when different input types require fundamentally different handling (e.g., classifying a support ticket as billing vs. technical vs. account management before processing).

- **Orchestrator-workers**: A central LLM analyzes the task and *dynamically* determines what subtasks are needed, then delegates each to a worker. Best for tasks where the required steps aren't known in advance and depend on the input.

- **Dynamic decomposition**: The agent generates subtasks incrementally based on what it discovers. Best for investigative tasks (debugging, codebase exploration) where each finding reshapes the investigation plan.

**When structured workflows add value**: Not every task benefits from multi-phase decomposition. Mechanical, well-defined tasks (reformatting dates from one format to another across a codebase) are straightforward enough that adding analyze → propose → implement phases adds overhead without improving quality. Open-ended, judgment-intensive tasks (refactoring a module to support multi-tenancy with proper data isolation) benefit significantly because the analysis phase surfaces considerations that improve the implementation.

**Sub-agent management and context transfer**: When a main conversation accumulates deep context about one area (e.g., a database access layer) and needs to explore an adjacent area (caching infrastructure), spawning a sub-agent is effective — but the sub-agent needs context. The best approach is to summarize the key findings from the main conversation and include that summary in the sub-agent's initial prompt. This preserves the essential knowledge without overloading the sub-agent with the full exploration history.

When two parallel explorations need to build on the same prior analysis, export the analysis findings to a file and create two new sessions that both reference it. This avoids re-reading the same dozens of files in each session.

**Session management in Claude Code**: Claude Code supports named sessions (`--resume session-name`) for returning to previous investigations. When resuming after code changes (a teammate merged a PR), launching a fresh agent with a *summary* of prior findings is more effective than resuming the old transcript, because the old transcript may reference code that has since changed.

### Key Relationships

Task decomposition patterns connect to tool design (the granularity of tools determines what "steps" are available), context management (long investigations require context management strategies), and system prompts (which may need to guide decomposition behavior). The choice of pattern also affects cost and latency — chained prompts are cheaper than orchestrator-workers.

### Common Pitfalls

- **Applying orchestrator-workers to predictable workflows.** If the steps are the same every time, prompt chaining is simpler and cheaper. Orchestrator-workers are for tasks where the steps vary based on input.
- **Using fixed, upfront plans for investigative tasks.** Creating a comprehensive plan before reading any code is wasteful because the first discovery may invalidate the plan. Dynamic, adaptive decomposition suits investigative work.
- **Resuming transcripts when the codebase has changed.** An old transcript may reference functions that were renamed or files that were moved. A summary of findings is more robust than the raw transcript.
- **Exhaustive analysis before any action.** Reading every file in a large codebase before writing a single test is an anti-pattern. Prioritize, start with high-impact areas, and adapt the plan as you learn.

### Go Deeper

- **Choosing the right decomposition pattern**: Practice mapping scenarios to patterns. A fixed three-step code review? Prompt chaining. Debugging an unknown error? Dynamic decomposition. Processing different document types? Routing. The wrong pattern wastes effort or limits quality.
- **Built-in tool selection (Read, Write, Edit, Grep, Glob, Bash)**: Know which tool is appropriate for each task. Grep is for searching file *contents* by pattern. Glob is for finding files by *name* pattern. Edit is for targeted modifications using string matching. When Edit fails (repetitive file content), Read + Write is the fallback for full-file replacement.
- **Context transfer between agents**: Understand the trade-offs between resuming sessions (stale context risk), starting fresh (re-read overhead), and the summary-and-spawn pattern (information loss but efficiency).

---

## 7. Agentic Workflow Design: Customer Service and Beyond

### What to Know

Building an agent that handles real customer interactions brings together every concept in this guide: tool design, error handling, context management, system prompts, and task decomposition. This section focuses on the design decisions specific to production agentic workflows.

**The reasoning loop drives tool selection.** When an agent receives tool results (order details, account information), those results are added to the conversation context and the model *reasons* about what to do next. This is not pre-programmed routing — the model evaluates the information and decides whether to process a refund, escalate to a human, or ask for more information. This means tool results must contain enough structured information for the model to make good decisions.

**Escalation design**: Getting escalation right is critical. Key principles:

- **Escalate when appropriate, not by rigid rules.** The right triggers for escalation are: the customer explicitly requests a human, the issue requires authority the agent doesn't have (policy exceptions, amounts above authorization limits), or the agent cannot make meaningful progress. Mechanical rules (escalate after 3 failed tool calls, escalate when sentiment score exceeds threshold) produce too many false positives and false negatives.

- **Provide structured context in escalation handoffs.** When escalating to a human agent who won't have access to the conversation transcript, pass a structured summary: customer ID, root cause identified, relevant order/transaction IDs, refund amount, and recommended action. Don't dump the entire transcript; don't send only the original complaint.

- **Acknowledge before investigating.** When a customer is frustrated and demands a human, don't silently investigate their account first. Acknowledge the frustration and ask one targeted question to understand the issue before deciding whether to escalate or resolve directly.

- **Offer choice when resolution is possible.** If the agent has confirmed that a return is straightforward and within policy, but the customer has asked for a human, the best approach is to acknowledge their frustration, inform them the issue can be resolved immediately, and offer to complete it now or escalate — let the customer choose.

**Programmatic enforcement for compliance rules**: When a business rule must hold 100% of the time (wire transfers exceeding $10,000 require a compliance officer's approval), prompt-based enforcement is insufficient — even emphatic system prompt instructions ("CRITICAL: NEVER process transfers over $10,000 without compliance review") fail some percentage of the time. The reliable approach is programmatic: implement a hook or middleware that intercepts tool calls, checks the amount, and blocks execution if it exceeds the threshold, redirecting to the required review. This removes the model from the compliance decision entirely.

**Graceful degradation when tools fail**: When a tool times out mid-workflow, the agent should maximize the value it *can* deliver. If it has already verified that a customer qualifies for an account upgrade but can't apply the change due to a system error, it should confirm eligibility, acknowledge the system issue transparently, and offer alternatives (escalation, retry later) — not pretend the change will apply automatically and not immediately escalate when partial resolution is possible.

**Multi-issue session management**: In extended sessions where customers raise multiple issues, conversations approach context limits. Extracting structured data (order IDs, amounts, statuses, resolution states) for each issue into a separate context layer ensures the agent can return to any issue when the customer circles back, even as older conversation turns are compressed.

### Key Relationships

This section is the integration point for the entire guide. Agentic workflows depend on well-designed tools (Sections 1-2), robust context management (Section 3), effective system prompts (Section 4), MCP integration (Section 5), and appropriate decomposition patterns (Section 6). The customer service domain is where all these concepts converge in practice.

### Common Pitfalls

- **Relying on prompt instructions for hard compliance rules.** Prompt-based enforcement has a non-zero failure rate. Business rules with legal or financial consequences must be enforced programmatically.
- **Passing raw conversation transcripts in escalation handoffs.** Human agents need structured, actionable summaries — not lengthy back-and-forth to read through.
- **Resuming sessions with stale tool results.** When a customer returns hours later, old tool results in the conversation history (with now-outdated status fields) compete for the model's attention against fresh results. Start new sessions with structured summaries of prior interactions.
- **Processing refunds without customer awareness to "solve the problem quickly."** Even when the return is straightforward, acting unilaterally on a frustrated customer's account without their explicit consent creates trust issues. Offer choice.

### Go Deeper

- **The spectrum of enforcement mechanisms**: Understand the reliability gradient from prompt instructions (lowest) → few-shot examples → tool-level validation → orchestration-layer hooks (highest). Know which level is appropriate for which type of rule.
- **Context management in tool-heavy conversations**: When tool results dominate the context (verbose multi-field responses accumulated across several lookups), know how to extract relevant fields and compress verbose results without losing information the agent needs.
- **Handling uncertain tool outcomes in customer-facing contexts**: When a payment API times out and you don't know if it succeeded, the customer-facing communication strategy matters enormously. Study how to communicate uncertainty honestly without causing unnecessary alarm.

---

## Study Strategy

### Recommended Order of Study

1. **Start with the API fundamentals** (Section 3, first half): Understand that the API is stateless, that conversations are rebuilt from scratch each request, and that context windows are finite. Everything else builds on this.

2. **Move to tool design** (Section 1): Learn how parameter design, descriptions, structured output, and tool composition affect agent behavior. This is concrete and practical.

3. **Study error handling** (Section 2): This is where most production issues originate. Understand the transient/permanent distinction, structured error responses, and uncertain state handling.

4. **Learn system prompt engineering** (Section 4): With the API model clear, study how system prompts shape behavior and why their influence degrades. Understand the mitigation strategies.

5. **Cover MCP** (Section 5): Build on your tool design knowledge with the standardized protocol layer — trust model, error tiers, description quality.

6. **Study agentic patterns** (Section 6): With tools, errors, and context understood, learn how agents compose multi-step workflows.

7. **Integrate with agentic workflows** (Section 7): This ties everything together in production scenarios.

### Self-Assessment Approach

For each section, try to:

- **Explain the core trade-off to a colleague without notes.** For example: "Why would you split a tool into two tools instead of adding validation? Because splitting makes the unsafe path structurally impossible, while validation makes it recoverable — here's when each matters..."
- **Given a failure scenario, diagnose the root cause.** If an agent ignores MCP tools, what's the most likely cause? If an agent retries a business error, what's missing from the tool response?
- **Compare two approaches and articulate why one is better *in a specific context*.** Progressive summarization vs. sliding window. Prompt-based enforcement vs. programmatic hooks. The answer is always contextual — practice identifying the context that makes the difference.

### Time Allocation Guidance

Allocate your study time proportionally:

- **Tool design and error handling**: ~35% — These are deeply interconnected and account for the broadest set of practical scenarios.
- **Context management**: ~20% — Foundational and cross-cutting, with several distinct strategies to understand.
- **System prompt engineering**: ~15% — Fewer distinct concepts but important subtleties around dilution and structure.
- **MCP**: ~10% — Important but narrower in scope; focuses on protocol-specific concepts.
- **Agentic patterns and workflows**: ~20% — Integration of all other areas into practical workflow design.

---

## Quick Reference Cheat Sheet

### API Fundamentals
- The Claude API is **stateless** — no built-in memory, no session state
- Your application must send the **complete conversation history** with every request
- Costs and latency grow **linearly** with conversation length (input tokens increase each turn)
- "Memory loss" = your app isn't including prior messages in the `messages` array

### Tool Design Principles
- **Descriptions** are the primary mechanism for tool selection — be detailed and specific
- **Structured JSON** output enables reliable tool chaining (include IDs, metadata)
- **Split tools** when parameters have interdependent constraints (each tool enforces its own)
- **Lookup → Act** pattern: search tool returns IDs, action tool takes a specific ID
- **Two-tool pattern for safety**: preview tool returns token, execute tool requires token
- Prompt-based enforcement is **unreliable** for safety-critical operations

### Error Handling
- **Transient errors** (network timeouts): handle with automatic retry *inside the tool*
- **Permanent errors** (business rules): return immediately with structured detail
- **Uncertain state** (write-operation timeout): communicate uncertainty, advise *no retry*
- Return errors as **tool content with `isError` flag**, not as thrown exceptions
- Include: `error_type`, `retryable` boolean, `message`, `customer_explanation`

### MCP Protocol
- Primary value: **reusability** — one server, many clients
- Tools from **all** configured servers available **simultaneously**
- Tool annotations (`readOnlyHint`) are **untrusted** — trust the server, not the annotation
- **Protocol errors** (bad request) → JSON-RPC error
- **Application errors** (API failure) → tool result with `isError: true`
- Poor descriptions → agents default to built-in tools

### Context Management Strategies
| Strategy | Best For | Weakness |
|---|---|---|
| Sliding window | Short, focused conversations | Complete loss of older context |
| Progressive summarization | General-purpose, most situations | Loses precision on numerical details |
| Structured state objects | Iteratively refined preferences | Must be explicitly maintained |
| Structured fact database | Precision-dependent recall (stats, IDs) | Additional infrastructure |
| RAG sliding window | Tool/retrieval-heavy conversations | May lose relevant older results |

### System Prompts
- Included in **every** API request, not just the first
- **General principles** > exhaustive conditionals (except safety-critical rules)
- **Few-shot examples** > verbose written instructions (more resilient to dilution)
- **XML-style sections** improve instruction salience and compliance
- Influence **dilutes** as conversation grows — even in short conversations
- Version prompts for multi-session conversations to prevent contradictions

### Agentic Patterns
| Pattern | When to Use |
|---|---|
| Prompt chaining | Fixed, repeating workflows with known steps |
| Routing | Different input types need different handling |
| Orchestrator-workers | Steps depend on input, determined dynamically |
| Dynamic decomposition | Investigative tasks where findings reshape the plan |

### Escalation & Compliance
- Escalate when: customer requests human, issue exceeds authority, agent stuck
- Handoff content: **structured summary** (customer ID, root cause, amount, recommendation)
- Hard compliance rules → **programmatic enforcement** (hooks/middleware), not prompt instructions
- Frustrated customer → acknowledge first, understand issue, then decide action
- Agent can resolve + customer wants human → **offer choice**, don't force either path

### Built-in Tool Selection (Claude Code / Agent SDK)
| Task | Tool |
|---|---|
| Search file contents by pattern | **Grep** |
| Find files by name/path pattern | **Glob** |
| Read a specific file | **Read** |
| Targeted edit (unique string match) | **Edit** |
| Full file replacement (when Edit fails) | **Read → Write** |
| Shell commands, system operations | **Bash** |

---

## Recommended Reading & Resources

### Official Documentation
- [Anthropic Documentation — Tool Use](https://docs.anthropic.com/en/docs/build-with-claude/tool-use/overview) — Comprehensive guide to designing and using tools with Claude, including parameter schemas, descriptions, and error handling.
- [Anthropic Documentation — System Prompts](https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering/system-prompts) — Best practices for writing effective system prompts.
- [Anthropic Documentation — Prompt Engineering Overview](https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering/overview) — Broad prompt engineering guide covering clarity, examples, structure, and formatting.
- [Anthropic Documentation — Conversation History & Context](https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering/long-context-tips) — Working with long context and conversation management.
- [Anthropic Documentation — Claude Agent SDK](https://docs.anthropic.com/en/docs/agents-and-tools/claude-code/claude-code-sdk-overview) — Overview of building developer productivity tools and agents with the SDK.

### Model Context Protocol (MCP)
- [Model Context Protocol Specification](https://modelcontextprotocol.io/) — The official MCP specification, including transport mechanisms, tool discovery, error handling tiers, and trust model.
- [MCP GitHub Repository](https://github.com/modelcontextprotocol) — Reference implementations, example servers, and community resources.
- [Anthropic Documentation — MCP Overview](https://docs.anthropic.com/en/docs/agents-and-tools/mcp) — Anthropic's guide to integrating MCP servers with Claude.

### Agentic Patterns & Architecture
- [Anthropic — Building Effective Agents](https://www.anthropic.com/engineering/building-effective-agents) — Anthropic's engineering blog post on agentic design patterns including prompt chaining, routing, orchestrator-workers, and when to use each.
- [Anthropic Cookbook — Tool Use Examples](https://github.com/anthropics/anthropic-cookbook/tree/main/tool_use) — Practical examples of tool design, error handling, and multi-step workflows.
- [Anthropic Cookbook — Prompt Engineering Interactive Tutorial](https://github.com/anthropics/courses/tree/master/prompt_engineering_interactive_tutorial) — Hands-on tutorial covering prompt structure, examples, and system prompt design.

### Foundational Concepts
- [Anthropic Documentation — Messages API](https://docs.anthropic.com/en/api/messages) — Understanding the stateless API model, message structure, and how conversation history works.
- [Anthropic Documentation — Prompt Caching](https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching) — How prompt caching reduces costs for repeated context (relevant to understanding context management trade-offs).
- [Anthropic Documentation — Extended Thinking](https://docs.anthropic.com/en/docs/build-with-claude/extended-thinking) — Understanding model reasoning capabilities, relevant to agentic decision-making.

### Claude Code
- [Claude Code Documentation](https://docs.anthropic.com/en/docs/agents-and-tools/claude-code/overview) — Complete reference for Claude Code CLI, including session management (--resume), sub-agents, built-in tools, and CLAUDE.md files.
- [Claude Code Best Practices](https://www.anthropic.com/engineering/claude-code-best-practices) — Practical guidance for getting the most from Claude Code in development workflows.
