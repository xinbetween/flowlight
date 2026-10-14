# Flowlight Inspection Plugin Template

This template describes an advisory Flowlight inspection plugin package. Flowlight can import and export this manifest shape, review provenance and permissions before install, run installed JavaScript advisory plugins in a short-lived sandbox, and show returned findings beside official built-in plugin findings.

## Trust boundary

Plugins run after an inspected HTTP exchange has been recorded locally. They can add findings and suggest reviewed Flowlight actions for the user to open in existing editors, but they do not block, rewrite, mock, transform, upload, export, or save settings by themselves.

Evidence must be bounded and redacted. Do not include raw request or response bodies, prompts, completions, header values, credentials, full tool inputs, or unredacted query strings.

## Review metadata

`permissions` declares which sanitized metadata families the plugin expects, such as `trafficMetadata`, `headerNames`, `appIdentity`, `llmMetadata`, `mcpMetadata`, and `suggestAction`. The legacy `suggestGuardrail` spelling is still accepted for older packages. These are not mutation powers.

`privacy` provides structured categories for the review sheet. Keep `privacySummary` human-readable and specific enough that someone can tell what the plugin sees.

`provenance` records source and review metadata. Local template packages are unsigned and reviewed as local/community packages; they cannot claim official provenance. Published packages can add a detached P-256 `signature` envelope outside the manifest so Flowlight can detect tampering before install.

## JavaScript contract

Define a synchronous `evaluate(context)` function. Flowlight passes `context.manifest` and `context.exchange`; the exchange contains only the sanitized metadata allowed by the plugin's declared permissions. It never contains request bodies, response bodies, header values, prompts, completions or full tool inputs.

Return up to 8 findings. Each finding uses `severity`, `title`, `summary`, bounded `evidence`, and optional `suggestedActions`. Actions can be `guardrail`, `networkRule`, `mockResponse`, `requestRewrite`, or `responseTransform`; each opens the matching Flowlight editor with bounded prefilled fields and is saved only if the user reviews and clicks Save. Suggestions require the `suggestAction` capability and permission. Scripts run out of process with an empty environment, a 128 KB script limit and a short timeout. Failures produce no findings.

## Files

- `manifest.json`: plugin identity, publisher category, guardrail provider, privacy summary, structured privacy categories, permissions, provenance, optional `configuration` string map, capabilities and embedded script.
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
