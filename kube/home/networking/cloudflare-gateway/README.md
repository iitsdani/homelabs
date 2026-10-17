# Cloudflare gateway

This application deploys the shared controller, `cloudflare-cianfr-one` GatewayClass and
`networking/cianfr-one-tunnel` Gateway. The controller creates the tunnel,
connector Deployment, and tunnel-token Secret. Each HTTPRoute attached to this
Gateway publishes its hostnames through Cloudflare DNS.

## Credentials

`credentials.enc.yaml` currently contains unencrypted placeholders. Replace them
and encrypt the Secret before committing real credentials or merging this
application. KSOPS is already configured; rendering requires an encrypted file.

Create a Cloudflare user API token with:

- **Account > Cloudflare Tunnel > Edit**, restricted to the account owning
  `cianfr.one`.
- **Zone > DNS > Edit**, restricted to the `cianfr.one` zone.
- **Zone > Zone > Read**, restricted to the `cianfr.one` zone, for DNS zone
  discovery.

For an account-owned API token, the equivalent permission names are
**Cloudflare One / Zero Trust > Argo Tunnel (Legacy) > Edit** and
**DNS & Zones > DNS > Edit**, plus zone-read access, scoped to the same account
and zone.

Set `ACCOUNT_ID` to the Cloudflare account ID, not the zone ID, and `TOKEN` to
the API token.

From the repository root, after filling the placeholder file:

```sh
sops --encrypt --in-place kube/home/networking/cloudflare-gateway/credentials.enc.yaml
```

## Adding routes

Use explicit hostnames, path matches, and backend ports. Public HTTPS terminates
at Cloudflare; this controller connects to backend Services over HTTP.

Before publishing routes, establish separate DNS ownership from ExternalDNS
(for example, filter its Gateway source to explicitly labelled Envoy Gateways).
Configure Cloudflare access restrictions separately. No HTTPRoutes or Cloudflare
WAF/Access policies are included in this application.

The controller does not enforce `allowedRoutes` namespace restrictions or
ReferenceGrants; these fields are not a tenant-isolation boundary. It also does
not preserve Gateway API path-match semantics or support method/header matches.
Deleted or renamed HTTPRoute hostnames require separate DNS cleanup.

Use another credential Secret and GatewayClass for a separate Cloudflare project.
Use distinct Gateway names within each account, since the controller discovers
tunnels by Gateway name. Remove Gateways while the controller and credentials
are still available so tunnel finalization can complete.
