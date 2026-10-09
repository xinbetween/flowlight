# Flowlight Inspection Plugin Template

This template describes an advisory Flowlight inspection plugin package. Flowlight can import and export this manifest shape today; installed packages are visible and configurable, while executable plugin logic remains limited to official built-in Swift rules until the sandbox phase.

## Trust boundary

Plugins run after an inspected HTTP exchange has been recorded locally. They can add findings and suggest normal Flowlight guardrails, but they do not block, rewrite, mock, transform, upload, or export traffic by themselves.

Evidence must be bounded and redacted. Do not include raw request or response bodies, prompts, completions, header values, credentials, full tool inputs, or unredacted query strings.

## Files

- `manifest.json`: plugin identity, publisher category, guardrail provider, privacy summary, optional `configuration` string map and capabilities.
- `findings.example.json`: sample findings the plugin may produce.
- `validate.py`: local schema and privacy sanity checks for the template package.

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
python3 validate.py
```
