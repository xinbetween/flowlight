function evaluate(context) {
  const findings = [];
  const tools = (context.exchange.llm && context.exchange.llm.declaredTools) || [];
  for (const tool of tools) {
    if (!/(bash|shell|exec|write|edit|delete|remove|patch)/i.test(tool.name)) continue;
    findings.push({
      severity: 'medium',
      title: 'High-risk tool available',
      summary: 'The agent declared a shell-like or write-capable tool. Add a guardrail if this tool should be refused.',
      evidence: [
        { label: 'Tool', value: tool.name },
        { label: 'Provider', value: context.exchange.llm.provider }
      ],
      suggestedActions: [{
        kind: 'guardrail',
        title: 'Review guardrail',
        reason: 'Refuse this tool only after reviewing the normal Flowlight guardrail.',
        guardrail: {
          agent: context.exchange.agent || '',
          server: tool.server || '',
          tool: tool.name
        }
      }]
    });
  }

  const connectors = (context.exchange.llm && context.exchange.llm.connectors) || [];
  for (const connector of connectors) {
    findings.push({
      severity: connector.authorized ? 'medium' : 'low',
      title: 'Provider-run MCP connector',
      summary: 'The model provider offered an MCP connector. Local network rules cannot block provider-side calls unless the same host is also contacted locally.',
      evidence: [
        { label: 'Provider', value: connector.provider },
        { label: 'Connector', value: connector.label },
        { label: 'Approval', value: connector.approval || 'unspecified' }
      ],
      suggestedActions: [{
        kind: 'networkRule',
        title: 'Review provider connector traffic',
        reason: 'Use this only if the same host is contacted locally by an app or agent.',
        networkRule: {
          action: 'block',
          app: context.exchange.agent || context.exchange.bundleID || '',
          destination: 'api.github.com',
          status: 403,
          name: 'Review provider connector traffic'
        }
      }]
    });
  }

  return findings;
}
