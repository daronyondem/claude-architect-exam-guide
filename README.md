# Claude Certified Architect - Foundations: Exam Preparation Guide

A comprehensive study guide for developers and solution architects preparing for the **Claude Certified Architect - Foundations** certification exam.

## Who Is This For?

This guide is designed for developers and solution architects who are **new to the LLM space** and want to build a solid foundation for the certification. If you have experience building LLM applications, it also serves as a focused review of the nuances the exam emphasizes.

## What Does It Cover?

The guide covers interconnected knowledge areas:

1. **API fundamentals and output control** - stateless requests, tool choice, structured outputs, response prefill
2. **Designing tool interfaces for LLM agents** - parameter design, structured output, tool composition, confirmation flows
3. **Error handling in agent tools** - transient vs. permanent errors, structured error responses, uncertain state, MCP error patterns
4. **Structured data extraction and validation** - schemas, nullability, semantic validation, provenance, human review
5. **Conversation context management** - progressive summarization, state objects, retrieval, stale data handling
6. **System prompt engineering** - structure, principles vs. conditionals, dilution, few-shot examples
7. **Model Context Protocol (MCP)** - tools, resources, prompts, trust model, tool descriptions, configuration scopes
8. **Agentic patterns and multi-agent workflows** - prompt chaining, routing, orchestrator-workers, subagents, provenance
9. **Customer service workflow design** - escalation, compliance enforcement, graceful degradation, handoff design
10. **Claude Code and Agent SDK workflows** - built-in tools, plan mode, sessions, memory, slash commands, hooks
11. **Evaluation, feedback loops, and batch processing** - validation, false-positive reduction, Message Batches, cost/latency trade-offs

Each section includes:
- **What to Know** - core concepts explained as teaching material
- **Common Pitfalls** - misconceptions and subtle distinctions

Plus a **Study Strategy**, **Quick Reference Cheat Sheet**, and **Recommended Reading & Resources** with links to official documentation.

## Read the Guide

**[exam-preparation-guide.md](exam-preparation-guide.md)**

## Downloads

PDF and EPUB versions are published from tagged releases. See the repository's [GitHub Releases](https://github.com/daronyondem/claude-architect-exam-guide/releases) for downloadable study booklet formats.

## Building the Booklet

Release assets are generated from `exam-preparation-guide.md` with Pandoc. The Markdown file remains the source of truth, while the files in `publishing/` provide booklet metadata, front matter, PDF styling, EPUB styling, and the cover image.

To build locally:

```bash
./scripts/build-release-assets.sh
```

The script writes generated files to `dist/`. EPUB generation requires Pandoc. PDF generation also requires `xelatex`. If `rsvg-convert` is available, the EPUB cover is converted to PNG for broader reader compatibility.

For local test builds, the generated title pages use `Version: dev`. Tagged releases use the tag name automatically. You can override the displayed version with:

```bash
RELEASE_VERSION=v1.0.0 ./scripts/build-release-assets.sh
```

## Disclaimer

This is an **independent, community-created** study guide. It is not affiliated with, endorsed by, or sponsored by Anthropic. No exam questions are included, paraphrased, or hinted at - this guide teaches the underlying knowledge domains only.

The guide was authored with assistance from Claude.

## Contributing

Found an error? Have a suggestion? Feel free to open an issue or submit a pull request.

## Star History

<a href="https://www.star-history.com/?repos=daronyondem%2Fclaude-architect-exam-guide&type=timeline&legend=bottom-right">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=daronyondem/claude-architect-exam-guide&type=timeline&theme=dark&legend=bottom-right" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=daronyondem/claude-architect-exam-guide&type=timeline&legend=bottom-right" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=daronyondem/claude-architect-exam-guide&type=timeline&legend=bottom-right" />
 </picture>
</a>

## License

This work is licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). You are free to share and adapt it with attribution.
