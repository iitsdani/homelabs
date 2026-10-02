# CLIProxyAPI: ChatGPT Plus login for Open WebUI

Open WebUI uses CLIProxyAPI's OpenAI-compatible API at
`http://cliproxyapi.default.svc.cluster.local:8317/v1`. Models appear with the
`codex.` prefix. Ollama Cloud remains a separate connection.

CLIProxyAPI authenticates through Codex OAuth using the ChatGPT account. Available
models and quotas depend on that account's Codex entitlement. This does not add
OpenAI API credits or the ChatGPT website's other features.

## Deployment

Merge the manifests into `main` and let ArgoCD reconcile:

- `app-cliproxyapi`: PVC, encrypted Secret, child Application.
- `cliproxyapi`: proxy Deployment and ClusterIP Service.
- `open-webui`: proxy connection environment defaults.

Inspect readiness:

```sh
kubectl --context=home -n argo-system get applications app-cliproxyapi cliproxyapi open-webui
kubectl --context=home -n default get pods -l app.kubernetes.io/instance=cliproxyapi
kubectl --context=home -n default get pvc cliproxyapi-data
```

Proxy can start before an account is enrolled; its model list will be empty.

## Enroll ChatGPT account

Run device login inside the deployed proxy container:

```sh
kubectl --context=home -n default exec -it deployment/cliproxyapi -c main -- \
  /CLIProxyAPI/CLIProxyAPI --config /config/config.yaml --codex-device-login --no-browser
```

Open the displayed OpenAI device authorization URL in your browser. Sign in with
the ChatGPT Plus account, enter the displayed code, and approve access. If OpenAI
requests it, enable device-code authorization in the account's security settings.

Wait for `Codex device authentication successful!`. The login command can return
zero after an authentication failure, so confirm this message rather than relying
on its exit status. If authorization expires or fails, rerun the command.

Login writes credentials to `/data/auths` on the existing encrypted PVC. Proxy
watches this directory and loads new credentials automatically; refreshed tokens
remain on PVC. No restart or additional Kubernetes resource is needed.

## Validate Open WebUI

Visit `https://chat.home.cianfr.one`, refresh the model list, and choose a `codex.`
model. Test streamed chat, a follow-up message, and a tool-enabled conversation.
Confirm Ollama Cloud models remain available.

Existing persisted settings can override the environment defaults. If the proxy
connection does not appear, add it manually under **Admin Panel → Settings →
Connections → OpenAI**:

- URL: `http://cliproxyapi.default.svc.cluster.local:8317/v1`
- API key: `stringData.api-key` from
  `kube/home/default/cliproxyapi/cliproxyapi-secrets.enc.yaml`, decrypted with SOPS.
- Prefix ID: `codex`

Reloader rolls out Open WebUI after Git-driven Secret rotation. If the connection
was saved in the UI, update its saved API key manually as well.

## Configuration and recovery

- `cliproxyapi-secrets.enc.yaml` contains the client `api-key` and `config.yaml`.
  Both copies of the key must match when rotating it with SOPS.
- OAuth files are writable runtime state on `cliproxyapi-data`, not a mounted
  Secret: automatic refresh must be able to replace them.
- Proxy exposes only ClusterIP port 8317. Management API and bundled control panel
  are disabled. API callers must supply the client bearer key.
- Credentials require PVC backup or re-enrollment after volume loss. Longhorn
  replication alone is not a backup.
- If removing CLIProxyAPI, remove its connection from Open WebUI's persisted
  settings before deleting the Secret. Removing environment defaults alone does
  not remove persisted connections.

## References

- [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI)
- [Pinned configuration schema](https://github.com/router-for-me/CLIProxyAPI/blob/v8.0.11/config.example.yaml)
- [Open WebUI OpenAI-compatible connections](https://docs.openwebui.com/getting-started/quick-start/starting-with-openai-compatible/)
