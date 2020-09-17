# Deploying Tinkerbell Locally on Kubernetes with kind

Registry configuration roughly cribbed from https://www.civo.com/learn/set-up-a-private-docker-registry-with-tls-on-kubernetes

## Prerequisites

### Standalone tools

- [kind](https://kind.sigs.k8s.io/) (v0.8.0+, Tested with v0.8.1)
- [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl/) (tested with v1.18.8)
- [helm](https://helm.sh/docs/intro/quickstart/) (v3+, tested with v3.3.0)
- [krew](https://krew.sigs.k8s.io/) (tested with v0.4.0)
- [tilt](https://tilt.dev) (v0.17.5+, tested with v0.17.5)

### Kubectl plugins

- [virt](https://kubevirt.io/user-guide/#/installation/virtctl?id=install-virtctl-with-krew) (tested with v0.32.0)

## Setup

- Bring up a new kind cluster

```sh
kind create cluster
```

- Start tilt

```sh
tilt up
```

## Running the CLI

TODO: better way to run this outside of the kind cluster

```sh
kubectl run -it --command --rm --attach --image quay.io/tinkerbell/tink-cli:latest --env="TINKERBELL_GRPC_AUTHORITY=tink-server:42113" --env="TINKERBELL_CERT_URL=http://tink-server:42114/cert" cli /bin/ash
```

## Create the hardware, template, and workflow

```sh
cat > hardware-data.json <<EOF
{
  "id": "ce2e62ed-826f-4485-a39f-a82bb74338e2",
  "metadata": {
    "facility": {
      "facility_code": "onprem"
    },
    "instance": {},
    "state": ""
  },
  "network": {
    "interfaces": [
      {
        "dhcp": {
          "arch": "x86_64",
          "ip": {
            "address": "172.30.0.5",
            "netmask": "255.255.0.0"
          },
          "mac": "08:00:27:00:00:01",
          "uefi": false
        },
        "netboot": {
          "allow_pxe": true,
          "allow_workflow": true
        }
      }
    ]
  }
}
EOF

tink hardware push --file hardware-data.json

cat > hello-world.yml  <<EOF
version: "0.1"
name: hello_world_workflow
global_timeout: 600
tasks:
  - name: "hello world"
    worker: "{{.device_1}}"
    actions:
      - name: "hello_world"
        image: hello-world
        timeout: 60
EOF

tink template create -n hello-world -p hello-world.yml
tink workflow create -t <template id> -r '{"device_1":"08:00:27:00:00:01"}'
```

## Load the hello-world image into the registry

```sh
kubectl run -it --command --rm --attach --image quay.io/containers/skopeo:v1.1.1 --overrides='{ "apiVersion": "v1", "metadata": {"annotations": { "k8s.v1.cni.cncf.io/networks":"[{\"interface\":\"net1\",\"mac\":\"08:00:31:00:00:00\",\"ips\":[\"172.30.0.100/16\"],\"name\":\"tink-dev\",\"namespace\":\"default\"}]" } }, "spec": { "containers": [ { "name": "skopeo", "image": "quay.io/containers/skopeo:v1.1.1", "command": [ "sh" ], "tty": true, "stdin": true, "volumeMounts": [ { "name": "registry-creds", "mountPath": "/creds" } ] } ], "volumes": [ { "name": "registry-creds", "secret": { "secretName": "tink-registry" } } ] } }' skopeo -- sh

skopeo copy --dest-tls-verify=false --dest-creds=admin:$(cat /creds/PASSWORD) docker://hello-world docker://$(cat /creds/URL)/hello-world
skopeo copy --dest-tls-verify=false --dest-creds=admin:$(cat /creds/PASSWORD) docker://quay.io/tinkerbell/tink-worker:latest docker://$(cat /creds/URL)/tink-worker:latest
```

## Bring up the worker VM

```sh
kubectl create -f deploy/kind/worker.yaml
```

## Watching the worker console

```sh
kubectl virt vnc worker
```

## Teardown

```sh
kind delete cluster
```

## TODO
- Add some type of templating mechanism helm/kustomize????
