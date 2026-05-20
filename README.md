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

Deploy this package as a WSO2 Developer Platform service component and point it at the Tailscale proxy instead of the raw private API:

```toml
coreBankingBaseUrl = "http://tailscale-proxy:8080"
provisionalCreditLimit = 500.00
```

The private core banking endpoint stays reachable only inside the Tailnet. The MCP server talks to the WSO2 Tailscale proxy service, and the proxy forwards traffic over Tailscale/WireGuard to the on-premise node.

## WSO2 Developer Platform Source Config

The current WSO2 Developer Platform source configuration file is:

```text
.choreo/component.yaml
```

The older `endpoints.yaml` and `component-config.yaml` formats are deprecated. This sample uses `component.yaml` with a single endpoint for the Ballerina MCP service:

```yaml
schemaVersion: 1.2
endpoints:
  - name: banking-mcp
    displayName: Banking Dispute MCP Endpoint
    service:
      basePath: /mcp
      port: 9090
    type: REST
    networkVisibilities:
      - Project
```

There is no `MCP` endpoint type in the `component.yaml` endpoint schema. The Ballerina MCP listener speaks MCP over HTTP, so the WSO2 endpoint type should be `REST`. If you need external MCP clients to call this endpoint directly, change `networkVisibilities` to `Organization` or `Public` and keep endpoint authentication enabled.

WSO2 Developer Platform also has a separate MCP Server component type, but the current docs describe stdio-based MCP servers exposed over SSE for Node.js/Python. This sample is a Ballerina HTTP MCP service, so it should be deployed as a service component with a REST endpoint.

## Tailscale Proxy Config

The Tailscale proxy is a separate WSO2 Developer Platform service component. Use:

- `.choreo/tailscale-proxy-config.yaml` as the file mount content for `/config.yaml`.
- `.choreo/tailscale-proxy-component.yaml.example` as the endpoint source-config example for that separate proxy component.

The proxy endpoint remains project-visible by default:

```yaml
schemaVersion: 1.2
endpoints:
  - name: private-core-banking
    displayName: Private Core Banking through Tailscale
    service:
      basePath: /
      port: 8080
    type: REST
    networkVisibilities:
      - Project
```

For the Ballerina service component, set the runtime configuration value to the Tailscale proxy URL:

```text
BAL_CONFIG_VAR_coreBankingBaseUrl=http://tailscale-proxy:8080
```

Do not expose the private core banking endpoint as `Public` unless you explicitly want WSO2 Developer Platform gateway access to that private service.
