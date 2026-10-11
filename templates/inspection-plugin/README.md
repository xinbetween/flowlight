# Flowlight Inspection Plugin Template

This template describes an advisory Flowlight inspection plugin package. Flowlight can import and export this manifest shape, run installed JavaScript advisory plugins in a short-lived sandbox, and show returned findings beside official built-in plugin findings.

## Trust boundary

Plugins run after an inspected HTTP exchange has been recorded locally. They can add findings and suggest normal Flowlight guardrails, but they do not block, rewrite, mock, transform, upload, or export traffic by themselves.

Evidence must be bounded and redacted. Do not include raw request or response bodies, prompts, completions, header values, credentials, full tool inputs, or unredacted query strings.

## JavaScript contract

Define a synchronous `evaluate(context)` function. Flowlight passes `context.manifest` and `context.exchange`; the exchange contains method, host, path without query, header names, byte counts, app/agent labels, declared tools and MCP connector metadata. It does not contain request bodies, response bodies, header values, prompts, completions or full tool inputs.

Return up to 8 findings. Each finding uses `severity`, `title`, `summary`, bounded `evidence`, and an optional `suggestedGuardrail` with `agent`, `server`, `tool` or `resource`. Scripts run out of process with an empty environment, a 128 KB script limit and a short timeout. Failures produce no findings.

## Files

- `manifest.json`: plugin identity, publisher category, guardrail provider, privacy summary, optional `configuration` string map, capabilities and embedded script.
- `plugin.js`: the readable source for `evaluate(context)`; keep it in sync with `manifest.script` before publishing.
- `findings.example.json`: sample findings the plugin may produce.
- `validate.js`: local schema, script and privacy sanity checks for the template package.

## Supported guardrail providers

- `presidio`: PII detection and masking.
- `bedrock`: AWS Bedrock guardrails.
- `lakera`: content moderation.
- `aporia`: custom guardrails.
- `noma`: Noma Security policies.
- `prismaAIRS`: PANW Prisma AIRS guardrails.
- `custom`: your own guardrail implementation.
- `flowlight`: Flowlight's official built-in rules.

## Validate

```sh
node validate.js
```
