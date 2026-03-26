# Claude Certified Architect – Foundations: Exam Preparation Guide

## Overview

This certification covers designing, building, and operating production applications on Claude and large language models. It spans four domains: tool interface design, conversation context management, system prompt engineering, and agentic workflow architecture.

Expect questions about trade-offs. Why pick one approach over another in a given situation? How do design decisions ripple through a system? Where does the model get to decide, and where must the application enforce rules programmatically? You should be comfortable reasoning about real-world failures: tools that return ambiguous errors, conversations that blow past context limits, agents that skip confirmation steps, system prompts whose influence fades mid-conversation.

New to LLMs? Start with how the API works, what context windows are, and why models are stateless. Then move into tool design and agentic patterns. Already building LLM applications? Focus on error handling strategies, MCP trust semantics, and the gap between prompt-based and programmatic enforcement.

---

## 1. Designing Tool Interfaces for LLM Agents

### What to Know

When an LLM agent interacts with the outside world (querying databases, calling APIs, modifying records), it does so through *tools*. A tool is a function signature the model can invoke: a name, a description, and typed parameters. The quality of this interface shapes whether the agent picks the right tool, fills in the right parameters, or even knows the tool exists.

The model decides which tool to call and how to populate its parameters based on the tool's name, description, and parameter descriptions. That's it. A vague description like "Analyzes dependencies" will lose to a well-described built-in alternative every time. Good descriptions explain what the tool does, when to use it instead of alternatives, what inputs it expects (with format examples), and what the output looks like. If a human developer couldn't figure out how to use it from the description alone, the model won't either.

Ambiguous parameters cause bad tool calls. A bare `string` for dates, free-text fields for names that should come from a controlled vocabulary: these lead to invalid combinations. The fix depends on the kind of ambiguity:

- When parameters have *interdependent constraints* (the valid payment method depends on the region or currency), consider splitting into separate tools where each enforces its own constraints structurally. A `create_bank_transfer(amount, iban, bic)` tool makes it impossible to pass a credit card number. The parameter doesn't exist.
- When the problem is *entity resolution* (matching free-text input to a specific record), introduce a lookup-then-act pattern: one tool to search and return identifiers, a second tool to act on a specific ID.
- When parameters have known valid values, use `enum` constraints. But enums alone don't capture *relationships* between parameters.

Don't try to encode format hints in parameter names. Writing `account_number_integer_eight_digits` is less effective than a concise description: `"account_number": 8-digit customer account ID (e.g., "10482930")`. The model reads descriptions. It doesn't parse semantic meaning from camelCase conventions.

When one tool's output becomes another tool's input, format matters. A lot. If a product search tool returns `"Found 3 items: 'Blue Widget', 'Red Gadget', 'Green Sprocket'"`, the agent has to parse a natural-language string to get identifiers for the next call. If it returns `[{"id": "prod_881", "name": "Blue Widget", "price": 24.99, ...}]`, the agent can pass `prod_881` directly to `add_to_cart(product_id, quantity)`. Use structured responses with explicit IDs and metadata for anything that feeds into downstream tools.

One more thing: when a tool performs an action (provisioning resources, placing an order), the response should include the details a user would need to understand what happened. Costs, target project, specifications, timestamps. If a tool returns only "Done," users end up asking follow-up questions the system could have answered up front.

### Key Relationships

How a tool reports failures matters as much as how it reports successes. Verbose tool responses eat into context window space, so lean structured responses matter in long conversations. And tool descriptions are the bridge to MCP adoption: poor MCP tool descriptions mean agents default to built-in alternatives regardless of how capable the MCP tools are.

### Common Pitfalls

- **Relying on prompt instructions to enforce tool usage patterns.** If you need the agent to always call a preview before executing a destructive action, a prompt instruction won't guarantee that. The model will skip the preview step some percentage of the time. Structural enforcement (requiring a single-use token from the preview tool to call the execution tool) is deterministic.
- **Conflating schema validation with behavioral guidance.** Marking a field as `required` in JSON Schema ensures the parameter is present. It doesn't help the model understand what *value* to provide. Schema constraints and descriptive documentation serve different purposes.
- **Over-composing tools.** Combining multiple operations into one tool improves efficiency when intermediate steps don't require model judgment. But if the model needs to *see* intermediate results to make a decision, those steps must stay separate. Combine mechanical steps; keep decision points visible.
- **Using `preview: boolean` flags for safety-critical operations.** A single tool with a preview parameter creates a path where the agent can skip the preview. Two separate tools (one that generates a plan and returns a one-time approval code, one that requires that code to execute) make the unsafe path impossible.

### Go Deeper

- **The lookup-then-act pattern**: When to decompose a tool with ambiguous parameters into a search tool paired with an action tool that takes an unambiguous identifier. This comes up whenever tools operate on entities that users refer to by name.
- **Balancing tool granularity and efficiency**: Too many fine-grained tools cause excessive round-trips. Too few coarse tools hide decisions the model needs to make. Learn to identify which steps can be combined without removing decision points.
- **Confirmation and safety flows for destructive operations**: The spectrum runs from prompt-based instructions (unreliable) through tool annotations (hints only) to structural enforcement (tokens, two-tool patterns). Know when each level of protection is appropriate.

---

## 2. Error Handling in Agent Tools

### What to Know

Error handling is where most production agent issues originate, and it's where most teams underinvest. When a tool fails, the information it returns determines whether the agent retries intelligently, communicates clearly, or wastes turns on futile attempts.

The most important distinction: transient vs. permanent errors. A network timeout (503, connection reset) is transient. The same request may succeed moments later. A business rule violation ("account balance insufficient") is permanent. Retrying won't change the outcome. If a tool returns the same generic error for both types, the agent has no basis for choosing the right response. It will waste calls retrying permanent failures and tell users to "try again later" for issues it could resolve immediately.

Handle what you can at the tool level. For transient errors like network timeouts, implement automatic retry with backoff *inside the tool itself*. The model never needs to know a transient failure occurred. It just sees a slightly delayed success. For permanent errors like validation failures, return the error immediately with enough detail for the agent to explain the situation and suggest alternatives. This keeps the model focused on user communication rather than infrastructure problems.

Structured error responses beat plain text messages. Rather than returning `"Error: Operation failed"`, return structured data:

```json
{
  "error_type": "business_rule",
  "error_category": "validation",
  "retryable": false,
  "message": "Account balance insufficient for transfer (available: $1,200, requested: $5,000)",
  "customer_explanation": "Your account doesn't have enough funds to complete this transfer."
}
```

The agent gets everything it needs: it knows not to retry, understands the root cause, and has a customer-friendly explanation ready.

There's a third category beyond transient and permanent: uncertain state. When a tool calls an external API that times out during a *write* operation (sending a notification, processing a payment), the tool often can't determine whether the operation succeeded. This is different from a read-timeout. The tool should communicate that uncertainty explicitly: "Status unknown. The message may have been sent. Do not retry." If the tool returns a generic "failed" message instead, the agent will retry, potentially causing double charges or duplicate notifications.

And one more pattern to internalize: return errors as normal tool output, not exceptions. When a tool throws an exception, the framework catches it and presents a generic error to the model, stripping away all the detail the model needs. Return errors in the `content` field and use the `isError` flag to signal failure.

### Key Relationships

Error handling is a tool design decision. Whether an agent retries, escalates, or explains depends on how errors are categorized. MCP has its own conventions for error reporting that build on these same ideas.

### Common Pitfalls

- **Treating all errors identically.** The single most common mistake. Uniform error responses produce unpredictable agent behavior because the model has to guess.
- **Returning `retryable: true` for operations with uncertain outcomes.** If you don't know whether a notification was sent, marking it as retryable will cause duplicates. Communicate uncertainty and let the user decide.
- **Using exceptions instead of structured error returns.** Framework-level exception handling strips context. Return errors as tool content.
- **Relying on the model to parse error messages for classification.** Teaching the model to distinguish "503 Service Unavailable" from "Order not found" by text parsing is fragile. Structured metadata is reliable.

### Go Deeper

- **Idempotency and uncertain state**: How to handle the case where a side-effecting operation times out and you don't know if it succeeded. This is a subtle distributed systems problem with direct implications for agent tool design.
- **MCP-specific error patterns**: The Model Context Protocol distinguishes between *protocol-level* errors (malformed requests, invalid parameters, reported as JSON-RPC errors) and *application-level* errors (API failures, business rule violations, reported as tool results with `isError: true`). Learn which failure modes fall into which category.
- **Where to place retry logic**: Tool-level retries are transparent to the model and good for transient infrastructure issues. Model-level retries are appropriate when the model needs to modify its approach. Know when to use each.

---

## 3. Conversation Context Management

### What to Know

Here's the thing that trips up most people new to LLM development: the Claude API is stateless. Claude does not maintain any internal memory between API calls. Every time you send a request, you must include the *entire* conversation history you want the model to see. If a message isn't in the `messages` array, it doesn't exist for the model.

This has real consequences.

First, costs and latency grow with every turn. The full conversation history goes out with each request, so input tokens increase linearly. A 60-turn conversation costs much more per request than a 5-turn conversation, and responds noticeably slower.

Second, when the model "forgets" something the user said three messages ago, it's almost always an application bug. Your code isn't including prior messages in the `messages` array. There is no `session_id` parameter. No built-in memory system. No vector database requirement. The model sees exactly what you send. Nothing more.

Third, context windows are finite. Modern models have large windows (100K-200K tokens), but long-running conversations, accumulated tool responses, and injected RAG results will eventually push against those limits. You need a strategy.

Four strategies for managing long conversations:

1. **Sliding window**: Keep only the most recent N turns. Simple. Works well when users rarely reference earlier exchanges. The downside: if a user asks about something from 20 turns ago, it's gone.

2. **Progressive summarization**: Summarize older turns into a condensed running summary while keeping the most recent 5-8 turns verbatim. This is usually the best general-purpose approach because it preserves historical context in compressed form while keeping recent exchanges at full fidelity. The summary should extract key decisions, conclusions, stated preferences, and important facts. Not just a vague narrative.

3. **Structured state extraction**: For conversations where users iteratively refine preferences, maintain a JSON object capturing the *current* state (budget, preferences, filters) and include it in every request. This is more reliable than depending on the model to pick the most recent preference from a long history where old and new values coexist.

4. **Retrieval-based approaches**: For scenarios requiring precision recall (numerical data, exact quotes, statistical values), store extracted facts in a structured database and retrieve relevant entries when the user's question needs them. Summaries lose precision. A summary that says "sample sizes ranged from 200-500" is useless when the user asks for the exact sample size of study #3.

Accumulated tool responses and RAG results can also crowd out conversation history, degrading coherence. You can manage this by keeping only RAG results from the last 2-3 queries, extracting relevant fields from verbose tool responses, or summarizing tool outputs once they've been discussed.

When a user returns to a conversation after hours or days, tool results from the earlier session may be outdated. The most reliable approach: start a new session with a structured summary of prior interactions, then make fresh tool calls before engaging. Don't resume with full historical context that includes stale data the model might reference.

When your system receives external updates (webhooks, notifications) during an active conversation, the cleanest pattern is to append the update to the next user message before calling the API. This makes the information part of the natural conversation flow.

### Key Relationships

Context management touches everything. System prompt adherence degrades as context grows. Tool response design determines how fast tool outputs eat through context budget. Wasted turns from poor error handling consume context. And agentic workflows must account for context limits during multi-step investigations.

### Common Pitfalls

- **Assuming the model has built-in memory.** It doesn't. No memory, no session state, no internal profile that persists between calls. Your application manages all state.
- **Confusing context capacity with context attention.** Even when context usage is well under half capacity, the model may not reliably track preference changes scattered across many turns. A structured state object is more reliable.
- **Summarizing too aggressively.** Summaries lose detail. When users need exact numbers, specific criteria, or exact phrasing, summaries produce hedged or inaccurate responses. Know when to use structured fact extraction instead.
- **Accumulating RAG results without cleanup.** If every query's retrieved context stays in the conversation forever, it crowds out the actual conversation history.

### Go Deeper

- **Progressive summarization implementation**: How to structure summaries that preserve different types of information (decisions, facts, preferences, open questions) at different fidelity levels.
- **Structured state objects for preference tracking**: When and how to maintain a separate JSON state object that represents "current truth," rather than relying on the model to parse through conversation history.
- **System prompt versioning for multi-session conversations**: Updating a system prompt for ongoing conversations can cause the model to contradict its own prior statements. Learn strategies for managing this transition.

---

## 4. System Prompt Engineering

### What to Know

The system prompt is your main lever for shaping model behavior: persona, tone, guidelines, safety guardrails, behavioral constraints. It's included at the beginning of every API request and frames how the model interprets the conversation that follows.

General principles work better than exhaustive conditionals. A common instinct is to write system prompts as decision trees: "If the user says X, do Y. If they say Z, do W." This works for explicit signals but fails for implicit ones. Write "If the user says they are new to investing, explain every term," and the model handles explicit declarations fine. But it misses contextual cues like domain jargon that implies sophistication. A general principle like "Match financial detail and terminology to the user's demonstrated knowledge level" gives the model room to interpret signals you haven't enumerated.

The exception: safety-critical rules should stay as explicit conditionals. "If the user describes symptoms of a medical emergency, always direct them to call emergency services" is a rule that must fire reliably. Keep it specific.

When a system prompt has many instructions and the model consistently ignores one of them, the issue is usually salience. The instruction is buried in prose. Organizing the prompt into clearly-delimited sections (XML-style tags like `<escalation_policy>`, `<tone>`, `<guardrails>`) with behavioral examples in each section makes individual instructions more prominent.

System prompt influence gets diluted. As conversations grow, the accumulated assistant responses create a behavioral pattern that can override system prompt instructions. And this isn't a token-limit issue. It happens even in conversations of just a few thousand tokens. The model's attention to the system prompt weakens relative to the growing body of conversational context. You can fight this by using few-shot examples in the system prompt (concrete demonstrations persist better than abstract rules), injecting periodic reminders as system messages, or placing critical instructions in high-attention positions within the prompt.

Few-shot examples hold up better than verbose instructions. A lengthy system prompt packed with written rules about adapting to different audience levels will lose influence over extended conversations. A few concrete examples showing appropriate responses at each level demonstrate the *difference* directly and tend to stick longer. Show, don't tell.

### Key Relationships

Context management and system prompts are deeply linked: as context grows, prompt influence fades. Tool descriptions function like mini-prompts. And deciding whether a business rule should live in the system prompt or be enforced programmatically is a recurring design question in agentic workflows.

### Common Pitfalls

- **Believing the system prompt is sent only once.** It's included in *every* API request. If your application sends it only with the first request, that's a bug.
- **Using emphatic language ("CRITICAL", "NEVER", "ALWAYS") as a reliability mechanism.** These may slightly increase compliance but don't guarantee it. For rules that must hold 100% of the time, use programmatic enforcement.
- **Adding more conditionals to cover edge cases.** Each additional branch makes the prompt longer and dilutes attention to each instruction. When you find yourself writing increasingly specific conditions, consider whether a general principle would work better.
- **Ignoring prompt versioning.** Updating a system prompt for ongoing multi-session conversations can cause the model to contradict its own prior statements, because new instructions conflict with patterns in the historical context.

### Go Deeper

- **Prompt structure and attention**: How position and formatting of instructions affect compliance rates. XML-style section delimiters, examples within sections, and strategic placement of critical rules all make a difference.
- **The dilution problem**: Why system prompt compliance degrades even in relatively short conversations, and the relative effectiveness of different mitigation strategies.
- **Principles vs. conditionals**: Practice identifying when conditional rules can be collapsed into a general principle and when a rule must remain explicit. The key question: does this rule require *judgment* (use a principle) or must it fire *deterministically* (keep it explicit, or enforce programmatically)?

---

## 5. Model Context Protocol (MCP)

### What to Know

The Model Context Protocol is a standardized interface for connecting AI agents to external tools and data sources. Instead of writing custom integration code for each tool in each application, MCP gives you a common protocol: build an MCP *server* that wraps your API or data source, and any MCP-compatible *client* can discover and use its tools automatically.

The main value is reusability. If your team builds multiple AI applications that all need access to the same data, an MCP server exposes that data once. Each application connects to the server and discovers its tools at connection time. No custom integration code per app.

MCP does *not* provide automatic authentication handling, built-in retry logic, rate limiting, or performance optimization through binary protocols. Those are your responsibility. MCP is a protocol for tool discovery and invocation, not a middleware framework.

When an agent connects to multiple MCP servers (say one for a CRM, one for Slack, one for a metrics dashboard), tools from *all* connected servers are discovered at connection time and available simultaneously. The agent doesn't need to be told which server to use. It sees a flat list of all tools and selects based on descriptions. This makes tool descriptions even more important: overlapping or vague descriptions across servers lead to poor tool selection.

The most common failure mode with MCP tools is non-adoption. The agent has access to a specialized MCP tool but uses a built-in alternative instead (using Grep to manually search for SQL patterns instead of calling a dedicated `scan_sql_vulnerabilities` tool). Almost always, this happens because the MCP tool's description is too vague. The model can't tell when the MCP tool is better than a familiar built-in. Expanding descriptions to explain capabilities, expected inputs, output format, and when to prefer this tool over alternatives is the most effective fix. More effective than adding routing instructions to the system prompt. More effective than removing competing tools.

MCP tools can carry annotations like `readOnlyHint: true` or `destructiveHint: true`. These are *self-reported* by the server. A tool annotated as read-only might not actually be read-only. The annotation is metadata, not a security guarantee. Base trust decisions (like bypassing confirmation prompts) on your assessment of the server's trustworthiness, not on its self-reported annotations.

MCP error handling has two tiers:

- **Protocol-level errors** (malformed requests, missing required parameters, invalid JSON-RPC): reported as JSON-RPC error responses. The request itself was invalid.
- **Application-level errors** (API returned 404, service unavailable, business rule violation): reported as normal tool results with `isError: true`. The tool was invoked correctly, but the operation it performed hit a problem.

Protocol errors mean the tool wasn't called properly. Application errors mean the tool was called properly but the operation failed.

When deciding between MCP and custom tools: use MCP when the integration serves multiple applications or when a community MCP server already exists for your data source. Use custom tools when the integration is specific to a single application's workflow and reusability isn't a concern.

### Key Relationships

MCP builds on tool design (descriptions drive adoption) and error handling (the two-tier model). It's also the mechanism through which developer productivity agents connect to code analysis, ticketing, and documentation tools.

### Common Pitfalls

- **Assuming MCP handles infrastructure concerns automatically.** It's a protocol, not a platform. Authentication, retries, rate limiting, and caching are on you.
- **Writing minimal tool descriptions ("Checks code quality").** This is the primary reason agents don't adopt MCP tools. Invest in descriptions.
- **Trusting tool annotations from unverified servers.** Self-reported metadata is not a security boundary.
- **Thinking MCP tools are per-request.** All tools from all configured servers are available simultaneously. You don't select a server per turn.

### Go Deeper

- **MCP error tier classification**: Practice categorizing failure scenarios. A missing required parameter is protocol-level. A 404 from the underlying API is application-level. So is a 503. This distinction determines the error reporting mechanism.
- **Optimizing MCP tool descriptions for adoption**: Study the difference between descriptions that win tool selection ("Runs static analysis across all source files, checking for unused variables, unreachable code, and style violations. Returns severity-ranked list with file paths, line numbers, and suggested fixes.") and descriptions that lose to built-in alternatives ("Checks code quality").
- **Choosing between existing and custom MCP servers**: For standard integrations (Jira, GitHub, Slack), an existing community server is almost always the right choice. Custom servers are justified when your workflow has requirements generic tools don't address.

---

## 6. Agentic Patterns and Task Decomposition

### What to Know

Agentic applications give the model autonomy to plan and execute multi-step tasks. The agent reads information, reasons about what to do next, takes an action, observes the result, and repeats. Understanding how to structure this autonomy matters.

The core loop is observe, reason, act. At each step, tool results get added to the conversation and the model decides its next move. This isn't a pre-configured decision tree or a fixed sequence of tool calls. The model dynamically chooses what to do based on what it has learned so far. That flexibility is what makes agents powerful. But it also means the model needs sufficient context (tool descriptions, error information, prior results) to make good choices.

Four task decomposition patterns worth knowing:

- **Prompt chaining**: Break a task into a fixed sequence of steps where each step's output feeds the next. Best for predictable, repeating workflows (a code review that always checks style, then security, then documentation). The key: steps are known in advance and don't change based on intermediate results.

- **Routing**: Classify the input first, then dispatch to a specialized prompt or workflow. Best when different input types need completely different handling (classifying a support ticket as billing vs. technical vs. account management before processing).

- **Orchestrator-workers**: A central LLM analyzes the task and dynamically determines what subtasks are needed, then delegates each to a worker. Best when the required steps aren't known in advance.

- **Dynamic decomposition**: The agent generates subtasks incrementally based on what it discovers. Best for investigative tasks (debugging, codebase exploration) where each finding reshapes the plan.

Not every task benefits from multi-phase decomposition. Mechanical, well-defined tasks (reformatting dates across a codebase) are straightforward enough that adding analyze-propose-implement phases just adds overhead. Open-ended, judgment-heavy tasks (refactoring a module to support multi-tenancy with proper data isolation) benefit significantly because the analysis phase surfaces considerations that improve the implementation.

When a main conversation has accumulated deep context about one area (a database access layer, say) and needs to explore an adjacent area (caching infrastructure), spawning a sub-agent works well. But the sub-agent needs context. Summarize the key findings from the main conversation and include that summary in the sub-agent's initial prompt. This preserves the important knowledge without overloading the sub-agent with the full exploration history.

When two parallel explorations need to build on the same prior analysis, export the findings to a file and create two new sessions that both reference it. Saves re-reading the same dozens of files in each session.

Claude Code supports named sessions (`--resume session-name`) for returning to previous investigations. But if the codebase has changed since the last session (a teammate merged a PR, some functions got renamed), launching a fresh agent with a *summary* of prior findings is more effective than resuming the old transcript. The old transcript may reference code that no longer exists.

### Key Relationships

The granularity of your tools determines what "steps" are available for decomposition. Long investigations need context management strategies. The choice of pattern affects cost and latency: chained prompts are cheaper than orchestrator-workers.

### Common Pitfalls

- **Applying orchestrator-workers to predictable workflows.** If the steps are the same every time, prompt chaining is simpler and cheaper.
- **Using fixed, upfront plans for investigative tasks.** Creating a plan before reading any code is wasteful because the first discovery may invalidate it. Use dynamic, adaptive decomposition instead.
- **Resuming transcripts when the codebase has changed.** An old transcript may reference renamed functions or moved files. A summary of findings is more robust.
- **Exhaustive analysis before any action.** Reading every file in a large codebase before writing a single test is an anti-pattern. Prioritize, start with high-impact areas, and adapt as you learn.

### Go Deeper

- **Choosing the right decomposition pattern**: Practice mapping scenarios to patterns. A fixed three-step code review? Prompt chaining. Debugging an unknown error? Dynamic decomposition. Processing different document types? Routing.
- **Built-in tool selection (Read, Write, Edit, Grep, Glob, Bash)**: Know which tool is appropriate for each task. Grep searches file *contents* by pattern. Glob finds files by *name* pattern. Edit does targeted modifications via string matching. When Edit fails (repetitive file content), Read + Write is the fallback for full-file replacement.
- **Context transfer between agents**: The trade-offs between resuming sessions (stale context risk), starting fresh (re-read overhead), and the summary-and-spawn pattern (some information loss but better efficiency).

---

## 7. Agentic Workflow Design: Customer Service and Beyond

### What to Know

Building an agent that handles real customer interactions pulls together everything in this guide. This section covers the design decisions specific to production workflows.

When an agent receives tool results (order details, account information), those results get added to the conversation context and the model reasons about what to do next. It's not pre-programmed routing. The model evaluates the information and decides whether to process a refund, escalate to a human, or ask for more information. So tool results need to contain enough structured information for the model to make good decisions.

Getting escalation right is hard. Some principles:

Escalate when the customer explicitly asks for a human, when the issue requires authority the agent doesn't have (policy exceptions, amounts above authorization limits), or when the agent can't make meaningful progress. Don't use mechanical rules like "escalate after 3 failed tool calls" or "escalate when sentiment score exceeds a threshold." These produce too many false positives and false negatives.

When escalating to a human agent who won't have access to the conversation transcript, pass a structured summary: customer ID, root cause identified, relevant transaction IDs, amounts, and recommended action. Don't dump the entire transcript. And don't send only the original complaint.

When a customer is frustrated and demands a human, don't silently investigate their account first. Acknowledge the frustration. Ask one targeted question to understand the issue. Then decide whether to escalate or resolve directly.

If the agent has confirmed that a return is straightforward and within policy, but the customer has asked for a human, acknowledge their frustration, let them know the issue can be resolved right now, and offer to complete it or escalate. Let the customer choose.

When a business rule must hold 100% of the time (wire transfers exceeding $10,000 require a compliance officer's approval), prompt-based enforcement isn't enough. Even emphatic system prompt instructions fail some percentage of the time. The reliable approach is programmatic: implement a hook or middleware that intercepts tool calls, checks the amount, and blocks execution if it exceeds the threshold. This takes the model out of the compliance decision entirely.

When a tool times out mid-workflow, the agent should maximize the value it *can* deliver. If it has verified that a customer qualifies for an account upgrade but can't apply the change due to a system error, it should confirm eligibility, be transparent about the system issue, and offer alternatives (escalation, retry later). Don't pretend the change will apply automatically. But don't immediately escalate when partial resolution is possible, either.

In extended sessions where customers raise multiple issues, conversations approach context limits. Extracting structured data (order IDs, amounts, statuses, resolution states) for each issue into a separate context layer ensures the agent can return to any issue when the customer circles back, even as older turns get compressed.

### Key Relationships

This is where everything converges. Agentic workflows depend on well-designed tools, good error handling, context management, effective system prompts, and appropriate decomposition patterns. Customer service is where you'll see all these concepts interact in practice.

### Common Pitfalls

- **Relying on prompt instructions for hard compliance rules.** Prompt-based enforcement has a non-zero failure rate. Business rules with legal or financial consequences must be enforced programmatically.
- **Passing raw conversation transcripts in escalation handoffs.** Human agents need structured, actionable summaries.
- **Resuming sessions with stale tool results.** When a customer returns hours later, old tool results with outdated status fields compete for the model's attention against fresh results. Start new sessions with structured summaries.
- **Acting on a frustrated customer's account without their consent.** Even when the return is straightforward, offer choice. Don't process unilaterally.

### Go Deeper

- **The spectrum of enforcement mechanisms**: The reliability gradient runs from prompt instructions (lowest) to few-shot examples to tool-level validation to orchestration-layer hooks (highest). Know which level fits which type of rule.
- **Context management in tool-heavy conversations**: When verbose, multi-field tool responses accumulate across several lookups, learn how to extract relevant fields and compress results without losing information the agent needs.
- **Handling uncertain tool outcomes in customer-facing contexts**: When a payment API times out and you don't know if it succeeded, how you communicate that to the customer matters a lot. Learn to be honest about uncertainty without causing unnecessary alarm.

---

## Study Strategy

### Recommended Order of Study

1. Start with API fundamentals (the stateless model, how conversations are rebuilt from scratch each request, finite context windows). Everything else builds on this.
2. Move to tool design. Parameter design, descriptions, structured output, tool composition. This is concrete and practical.
3. Study error handling. This is where most production issues start. Transient vs. permanent, structured error responses, uncertain state.
4. Learn system prompt engineering. How prompts shape behavior, why their influence degrades, and the mitigation strategies.
5. Cover MCP. Trust model, error tiers, description quality.
6. Study agentic patterns. How agents compose multi-step workflows.
7. Finish with agentic workflow design. This ties everything together.

### Self-Assessment Approach

For each section, try to:

- Explain the core trade-off to a colleague without notes. For example: "Why would you split a tool into two tools instead of adding validation? Because splitting makes the unsafe path structurally impossible, while validation makes it recoverable. Here's when each matters..."
- Given a failure scenario, diagnose the root cause. If an agent ignores MCP tools, what's the most likely cause? If an agent retries a business error, what's missing from the tool response?
- Compare two approaches and articulate why one is better *in a specific context*. Progressive summarization vs. sliding window. Prompt-based enforcement vs. programmatic hooks. The answer is always contextual. Practice identifying what makes the difference.

### Time Allocation Guidance

Allocate your study time roughly like this:

- **Tool design and error handling**: ~35%. Deeply connected and the broadest set of practical scenarios.
- **Context management**: ~20%. Foundational, with several distinct strategies to understand.
- **System prompt engineering**: ~15%. Fewer distinct concepts but important subtleties.
- **MCP**: ~10%. Narrower scope, focused on protocol-specific concepts.
- **Agentic patterns and workflows**: ~20%. Integration of all other areas.

---

## Quick Reference Cheat Sheet

### API Fundamentals
- The Claude API is stateless. No built-in memory, no session state.
- Your application sends the complete conversation history with every request.
- Costs and latency grow linearly with conversation length (input tokens increase each turn).
- "Memory loss" = your app isn't including prior messages in the `messages` array.

### Tool Design Principles
- Descriptions are the primary mechanism for tool selection. Be detailed and specific.
- Structured JSON output enables reliable tool chaining (include IDs, metadata).
- Split tools when parameters have interdependent constraints.
- Lookup-then-act pattern: search tool returns IDs, action tool takes a specific ID.
- Two-tool pattern for safety: preview tool returns token, execute tool requires token.
- Prompt-based enforcement is unreliable for safety-critical operations.

### Error Handling
- Transient errors (network timeouts): handle with automatic retry *inside the tool*.
- Permanent errors (business rules): return immediately with structured detail.
- Uncertain state (write-operation timeout): communicate uncertainty, advise no retry.
- Return errors as tool content with `isError` flag, not as thrown exceptions.
- Include: `error_type`, `retryable` boolean, `message`, `customer_explanation`.

### MCP Protocol
- Primary value: reusability. One server, many clients.
- Tools from all configured servers available simultaneously.
- Tool annotations (`readOnlyHint`) are untrusted. Trust the server, not the annotation.
- Protocol errors (bad request) = JSON-RPC error.
- Application errors (API failure) = tool result with `isError: true`.
- Poor descriptions = agents default to built-in tools.

### Context Management Strategies
| Strategy | Best For | Weakness |
|---|---|---|
| Sliding window | Short, focused conversations | Complete loss of older context |
| Progressive summarization | General-purpose, most situations | Loses precision on numerical details |
| Structured state objects | Iteratively refined preferences | Must be explicitly maintained |
| Structured fact database | Precision-dependent recall (stats, IDs) | Additional infrastructure |
| RAG sliding window | Tool/retrieval-heavy conversations | May lose relevant older results |

### System Prompts
- Included in every API request, not just the first.
- General principles > exhaustive conditionals (except safety-critical rules).
- Few-shot examples > verbose written instructions (more resilient to dilution).
- XML-style sections improve instruction salience and compliance.
- Influence dilutes as conversation grows, even in short conversations.
- Version prompts for multi-session conversations to prevent contradictions.

### Agentic Patterns
| Pattern | When to Use |
|---|---|
| Prompt chaining | Fixed, repeating workflows with known steps |
| Routing | Different input types need different handling |
| Orchestrator-workers | Steps depend on input, determined dynamically |
| Dynamic decomposition | Investigative tasks where findings reshape the plan |

### Escalation & Compliance
- Escalate when: customer requests human, issue exceeds authority, agent stuck.
- Handoff content: structured summary (customer ID, root cause, amount, recommendation).
- Hard compliance rules need programmatic enforcement (hooks/middleware), not prompt instructions.
- Frustrated customer: acknowledge first, understand issue, then decide action.
- Agent can resolve + customer wants human: offer choice, don't force either path.

### Built-in Tool Selection (Claude Code / Agent SDK)
| Task | Tool |
|---|---|
| Search file contents by pattern | Grep |
| Find files by name/path pattern | Glob |
| Read a specific file | Read |
| Targeted edit (unique string match) | Edit |
| Full file replacement (when Edit fails) | Read then Write |
| Shell commands, system operations | Bash |

---

## Recommended Reading & Resources

### Official Documentation
- [Anthropic Docs: Tool Use](https://docs.anthropic.com/en/docs/build-with-claude/tool-use/overview) - Guide to designing and using tools with Claude, including parameter schemas, descriptions, and error handling.
- [Anthropic Docs: System Prompts](https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering/system-prompts) - Best practices for writing effective system prompts.
- [Anthropic Docs: Prompt Engineering](https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering/overview) - Prompt engineering guide covering clarity, examples, structure, and formatting.
- [Anthropic Docs: Long Context Tips](https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering/long-context-tips) - Working with long context and conversation management.
- [Anthropic Docs: Claude Agent SDK](https://docs.anthropic.com/en/docs/agents-and-tools/claude-code/claude-code-sdk-overview) - Building developer productivity tools and agents with the SDK.

### Model Context Protocol (MCP)
- [Model Context Protocol Specification](https://modelcontextprotocol.io/) - The official MCP spec: transport mechanisms, tool discovery, error handling tiers, and trust model.
- [MCP GitHub Repository](https://github.com/modelcontextprotocol) - Reference implementations, example servers, and community resources.
- [Anthropic Docs: MCP Overview](https://docs.anthropic.com/en/docs/agents-and-tools/mcp) - Anthropic's guide to integrating MCP servers with Claude.

### Agentic Patterns & Architecture
- [Building Effective Agents](https://www.anthropic.com/engineering/building-effective-agents) - Anthropic's engineering blog on agentic design patterns including prompt chaining, routing, and orchestrator-workers.
- [Anthropic Cookbook: Tool Use](https://github.com/anthropics/anthropic-cookbook/tree/main/tool_use) - Practical examples of tool design, error handling, and multi-step workflows.
- [Prompt Engineering Interactive Tutorial](https://github.com/anthropics/courses/tree/master/prompt_engineering_interactive_tutorial) - Hands-on tutorial covering prompt structure and system prompt design.

### Foundational Concepts
- [Anthropic Docs: Messages API](https://docs.anthropic.com/en/api/messages) - The stateless API model, message structure, and how conversation history works.
- [Anthropic Docs: Prompt Caching](https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching) - How prompt caching reduces costs for repeated context.
- [Anthropic Docs: Extended Thinking](https://docs.anthropic.com/en/docs/build-with-claude/extended-thinking) - Model reasoning capabilities, relevant to agentic decision-making.

### Claude Code
- [Claude Code Documentation](https://docs.anthropic.com/en/docs/agents-and-tools/claude-code/overview) - Complete reference for the CLI, including session management, sub-agents, built-in tools, and CLAUDE.md files.
- [Claude Code Best Practices](https://www.anthropic.com/engineering/claude-code-best-practices) - Practical guidance for getting the most from Claude Code.
