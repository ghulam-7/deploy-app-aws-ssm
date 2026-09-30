#!/usr/bin/env bash
set -euo pipefail

declare -A ARG
while (($#)); do
  case "$1" in
    --region|--cluster|--namespace|--commit|--manifest-sha256|--image|--image-digest|--rollout-timeout)
      ARG["${1#--}"]="${2:?missing value for $1}"
      shift 2
      ;;
    *) echo "unsupported argument: $1" >&2; exit 2 ;;
  esac
done

for key in region cluster namespace commit manifest-sha256 image image-digest rollout-timeout; do
  [[ -n "${ARG[$key]:-}" ]] || { echo "missing --$key" >&2; exit 2; }
done

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source_manifest="$repo_root/manifest/manifest.yaml"
[[ -f "$source_manifest" ]] || { echo "manifest/manifest.yaml is missing from the cloned repository" >&2; exit 3; }
actual_sha="$(sha256sum "$source_manifest" | awk '{print $1}')"
[[ "$actual_sha" == "${ARG[manifest-sha256],,}" ]] || {
  echo "manifest checksum mismatch: sync manifest/manifest.yaml with the inspected Bitbucket manifest" >&2
  exit 3
}

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
rendered_manifest="$workdir/rendered.yaml"
resolved_image="$(python3 - "$source_manifest" "$rendered_manifest" "${ARG[image]}" "${ARG[image-digest]}" "${ARG[namespace]}" <<'PY'
import sys
import yaml

source, destination, image, digest, namespace = sys.argv[1:]
repository = image.split('@', 1)[0]
if repository.rfind(':') > repository.rfind('/'):
    repository = repository[:repository.rfind(':')]
resolved = f'{repository}@{digest}'

documents = list(yaml.safe_load_all(open(source, encoding='utf-8')))
matches = 0
for document in documents:
    if not isinstance(document, dict):
        continue
    if (document.get('metadata') or {}).get('namespace') not in (None, namespace):
        raise SystemExit('manifest resource targets a different namespace')
    kind = document.get('kind')
    spec = document.get('spec') or {}
    if kind in {'Deployment', 'StatefulSet', 'DaemonSet', 'Job'}:
        pod = ((spec.get('template') or {}).get('spec') or {})
    elif kind == 'CronJob':
        pod = (((((spec.get('jobTemplate') or {}).get('spec') or {}).get('template') or {}).get('spec')) or {})
    else:
        continue
    for container in [*(pod.get('containers') or []), *(pod.get('initContainers') or [])]:
        current = str(container.get('image') or '').split('@', 1)[0]
        if current.rfind(':') > current.rfind('/'):
            current = current[:current.rfind(':')]
        if current == repository:
            container['image'] = resolved
            matches += 1

if matches == 0:
    raise SystemExit('manifest contains no container matching the pipeline image repository')
with open(destination, 'w', encoding='utf-8') as output:
    yaml.safe_dump_all(documents, output, sort_keys=False)
print(resolved)
PY
)"

aws eks update-kubeconfig --region "${ARG[region]}" --name "${ARG[cluster]}" --kubeconfig "$workdir/kubeconfig"
export KUBECONFIG="$workdir/kubeconfig"
kubectl apply --server-side --dry-run=server -n "${ARG[namespace]}" -f "$rendered_manifest" >/dev/null
kubectl apply --server-side -n "${ARG[namespace]}" -f "$rendered_manifest"

while read -r kind name; do
  case "$kind" in
    Deployment|StatefulSet|DaemonSet)
      kubectl rollout status -n "${ARG[namespace]}" "${kind,,}/$name" --timeout="${ARG[rollout-timeout]}s"
      ;;
  esac
done < <(kubectl get -n "${ARG[namespace]}" -f "$rendered_manifest" -o jsonpath='{range .items[*]}{.kind}{" "}{.metadata.name}{"\n"}{end}')

printf '{"deployed":true,"cluster":"%s","namespace":"%s","commit":"%s","image":"%s"}\n' \
  "${ARG[cluster]}" "${ARG[namespace]}" "${ARG[commit]}" "$resolved_image"
