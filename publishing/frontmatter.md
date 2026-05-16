## Before You Start

This is an independent, community-created study guide. It is not affiliated with, endorsed by, or sponsored by Anthropic.

No exam questions are included, paraphrased, or hinted at. The guide teaches the underlying architecture concepts, trade-offs, and implementation patterns that a practitioner should understand.

This work is licensed under [Creative Commons Attribution 4.0 International](https://creativecommons.org/licenses/by/4.0/). You may share and adapt it with attribution.

## How to Use This Guide

Read the chapters in order if you are new to production LLM systems. If you already build with Claude, use the chapter list to jump directly to weaker areas, then use the quick reference near the end as a final review.

For each topic, focus on the design trade-off being tested:

- Where should responsibility live: model, application code, tool, schema, or human reviewer?
- Which behavior needs deterministic enforcement instead of prompt guidance?
- What context, state, or provenance must be preserved for the workflow to be reliable?
- Which failures should be retried, escalated, validated, or treated as impossible to infer?

The goal is not memorization. A strong answer explains why a design fits the scenario's constraints.
