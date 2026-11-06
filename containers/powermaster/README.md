# PowerMaster+ Local container

Packages the official PowerWalker PowerMaster+ Local 1.2.3 Linux installer for
`linux/amd64`. The installer archive is verified against its pinned SHA-256.
This is repository-maintained packaging, not an official PowerWalker image.

The Local component connects directly to the UPS over USB. The installer selects
Local and deselects Remote; it includes the vendor's Java runtime. Installation
happens during the image build, not container startup.

## Build

From the repository root:

```sh
docker buildx build --platform linux/amd64 --load \
  --tag powermaster:local containers/powermaster
```

On an ARM workstation, x86-64 emulation is required. If the bundled JVM hangs
under emulation, try running with `--env INSTALL4J_ADD_VM_PARAMS=-Xint`.
Native amd64 runtime and actual UPS communication remain unverified.

## Runtime contract

- HTTP web interface: TCP **3052**, initial path `/`.
- Persistent state: mount a writable volume at **`/data`**. Includes configuration,
  local/cloud databases, certificates, event logs, external commands, uploads,
  and Java preferences. Back up this volume while the service is stopped.
- One process runs the vendor launcher in foreground mode, supervised by `tini`.
  Container stop forwards SIGTERM to Java; allow at least 30 seconds for shutdown.
- Runs as root for USB/native-driver access. USB devices and permissions must be
  supplied by the eventual deployment. NUT must release the same USB interface
  before PowerMaster starts.
- Additional vendor communication ports are declared in the Dockerfile. Declaring
  a port does not publish it; browser-only testing needs only TCP 3052.
- Host power actions inside the container do not automatically shut down Proxmox
  or Kubernetes nodes. Coordinated shutdown is separate configuration.
- Update software by rebuilding the image. Do not use in-application updates to
  replace the container's binaries or bundled JRE.

Example for a local UI check without UPS access:

```sh
docker run --rm --platform linux/amd64 --name powermaster \
  --publish 127.0.0.1:3052:3052 \
  --volume powermaster-data:/data \
  powermaster:local
```

Open `http://localhost:3052`. USB passthrough, reverse-proxy behavior, and UPS
controls remain deployment-time checks. No Kubernetes resources are included.

## GitHub Actions / GHCR

`build-powermaster.yaml` builds pull requests affecting this
directory or the workflow. Pushes to `main` and manual runs on `main` also publish
to `ghcr.io/<repository-owner>/powermaster:sha-<full-commit-sha>` using
`GITHUB_TOKEN`. No GitHub Release or additional publishing secret is needed.

CI checks shell scripts and image builds; it does not run the application.
The workflow summary records the published digest for a future digest-pinned
deployment. No manifest updates or ArgoCD deployment happen in this workflow.
GHCR package visibility is managed separately; new packages normally start private.

To update PowerMaster, change `POWERMASTER_VERSION` in both image stages and
update `POWERMASTER_URL` and `POWERMASTER_SHA256` from the official download.
Recheck installer component IDs in `response.varfile`, startup, persistence, and
shutdown before publishing.

## Sources

- [VI 2200 RLE product and compatible software](https://powerwalker.com/product/10121100/)
- [Official PowerMaster downloads](https://powerwalker.com/software/#powermaster)
- [1.2.3 Linux x86-64 archive](https://powerwalker.com/wp-content/uploads/2025/07/pmp123_linux64.zip)

The bundled software remains subject to its vendor and bundled dependency licenses.
