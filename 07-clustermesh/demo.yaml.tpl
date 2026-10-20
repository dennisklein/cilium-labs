apiVersion: apps/v1
kind: Deployment
metadata: {name: echo}
spec:
  replicas: 2
  selector: {matchLabels: {app: echo}}
  template:
    metadata: {labels: {app: echo}}
    spec:
      containers:
      - name: echo
        image: hashicorp/http-echo:1.0.0
        args: ["-text=hello from ${NAME}"]
        ports: [{containerPort: 5678}]
---
apiVersion: v1
kind: Service
metadata:
  name: echo
  annotations: {service.cilium.io/global: "true"}   # endpoints merged across clusters
spec:
  selector: {app: echo}
  # NAME THE PORT: with an unnamed port, Cilium 1.18.0 exported the backends without port info,
  # so remote backends were never merged. Port == targetPort is the combination verified on a real host.
  ports: [{name: http, port: 5678, targetPort: 5678}]
---
apiVersion: v1
kind: Pod
metadata: {name: client}
spec:
  containers: [{name: curl, image: "curlimages/curl:8.23.0", command: ["sleep", "infinity"]}]
