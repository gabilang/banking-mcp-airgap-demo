# Banking MCP Airgap Demo

This demo models the architecture from the article:

- A cloud-side Ballerina MCP server exposes guarded tools for a dispute agent.
- A private core banking REST API represents the on-premise legacy system.
- In local development the MCP server calls `http://localhost:8090`; in WSO2 Developer Platform/Choreo, set `coreBankingBaseUrl` to the project-level Tailscale proxy endpoint.

## Run Locally

```sh
bal run
```

The package starts:

- MCP server: `http://localhost:9090/mcp`
- Mock core banking API: `http://localhost:8090/corebank`

Use any MCP client that supports Streamable HTTP. The exposed tools are:

- `retrieveAccountHistory(accountId)`
- `assessDisputeRisk(accountId, transactionId)`
- `placeFraudHold(accountId, transactionId, provisionalCreditAmount, analystOrAgentRef)`

Sample account IDs:

- `acct-9001` with suspicious transaction `txn-10002`
- `acct-7755` with normal transaction `txn-20001`

## Production Shape

Deploy the MCP server in WSO2 Integrator or WSO2 Developer Platform and point it at the Tailscale proxy instead of the raw private API:

```toml
coreBankingBaseUrl = "http://tailscale-proxy:8080"
provisionalCreditLimit = 500.00
```

The private core banking endpoint stays reachable only inside the Tailnet. The MCP server talks to the WSO2 Tailscale proxy service, and the proxy forwards traffic over Tailscale/WireGuard to the on-premise node.
