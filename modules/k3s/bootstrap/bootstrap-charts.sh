until kubectl --request-timeout=10s get --raw=/readyz >/dev/null; do
  sleep 5
done

kubectl --request-timeout=30s wait --for=create crd/helmcharts.helm.cattle.io --timeout=60s
kubectl --request-timeout=30s wait --for=condition=Established crd/helmcharts.helm.cattle.io --timeout=60s

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

for manifest in "$@"; do
  if [[ -d "$manifest" ]]; then
    kubectl kustomize "$manifest" > "$workdir/rendered.yaml"
  else
    cp "$manifest" "$workdir/rendered.yaml"
  fi

  yq -o=json -I=0 '.' "$workdir/rendered.yaml" |
    jq -sc '[.[] | select(. != null) | if .kind == "List" then .items[] else . end]' > "$workdir/objects.json"

  while IFS= read -r object; do
    printf '%s\n' "$object" > "$workdir/object.json"
    namespace=$(jq -r '.metadata.namespace // empty' "$workdir/object.json")
    if [[ -n "$namespace" ]]; then
      kubectl --request-timeout=30s wait --for=create "namespace/$namespace" --timeout=60s
    fi

    existing=$(kubectl --request-timeout=30s get -f "$workdir/object.json" --ignore-not-found -o name)
    if [[ -n "$existing" ]]; then
      echo "$existing already exists; leaving unchanged"
    else
      kind=$(jq -r '.kind' "$workdir/object.json")
      if [[ "$kind" == HelmChart ]]; then
        target_namespace=$(jq -r '.spec.targetNamespace // .metadata.namespace' "$workdir/object.json")
        kubectl --request-timeout=30s wait --for=create "namespace/$target_namespace" --timeout=60s
        while IFS= read -r secret; do
          kubectl --request-timeout=30s -n "$target_namespace" wait --for=create "secret/$secret" --timeout=60s
        done < <(jq -r '.metadata.annotations["bootstrap.homelabs/required-secrets"] // "" | split(" ")[] | select(length > 0)' "$workdir/object.json")
      fi

      if kubectl --request-timeout=30s create -f "$workdir/object.json"; then
        echo "Created bootstrap resource from $manifest"
      else
        create_status=$?
        # Another creator may have won the race after the initial lookup.
        existing=$(kubectl --request-timeout=30s get -f "$workdir/object.json" --ignore-not-found -o name)
        if [[ -z "$existing" ]]; then
          exit "$create_status"
        fi
        echo "$existing now exists; leaving unchanged"
      fi
    fi

    if [[ "$(jq -r '.kind' "$workdir/object.json")" == CustomResourceDefinition ]]; then
      kubectl --request-timeout=30s wait --for=condition=Established -f "$workdir/object.json" --timeout=60s
    fi
  done < <(jq -c '.[]' "$workdir/objects.json")
done
