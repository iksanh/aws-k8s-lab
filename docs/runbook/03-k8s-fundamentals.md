# Kubernetes Fundamentals

## Pod vs Deployment

### Pod
The smallest unit in Kubernetes. Contains one or more containers.
If a Pod dies, it does not restart on its own.

### Deployment
Manages Pods by defining how many replicas should run at all times.
If a Pod dies, the Deployment automatically creates a new one to
maintain the desired replica count.

### Practice

#### Create a Pod directly (without Deployment)
```bash
kubectl run nginx-pod --image=nginx
```

Output:
```
pod/nginx-pod created
```

#### Delete the Pod
```bash
kubectl delete pod nginx-pod
```

Output:
```
pod "nginx-pod" deleted
```

Result: Pod is gone permanently — nothing recreates it.

#### Create a Deployment
```bash
kubectl create deployment nginx-deployment --image=nginx --replicas=2
```

Output:
```
deployment.apps/nginx-deployment created
```

#### Verify Pods created by Deployment
```bash
kubectl get pods
```

Output:
```
NAME                                READY   STATUS    RESTARTS   AGE
nginx-deployment-6d6565499c-9tq2v   1/1     Running   0          10s
nginx-deployment-6d6565499c-b4r9g   1/1     Running   0          10s
```

#### Delete one Pod from the Deployment
```bash
kubectl delete pod nginx-deployment-6d6565499c-9tq2v
```

#### Verify — Deployment creates a new Pod automatically
```bash
kubectl get pods
```

Output:
```
NAME                                READY   STATUS    RESTARTS   AGE
nginx-deployment-6d6565499c-b4r9g   1/1     Running   0          76s
nginx-deployment-6d6565499c-qqhxv   1/1     Running   0          12s
```

Result: A new Pod was created automatically to maintain 2 replicas.

### Key Takeaway
Always use Deployment instead of creating Pods directly.
Deployment ensures the desired number of Pods is always running,
even if one is deleted or crashes.

---

## Service

### Why do we need Service?
Every Pod has its own IP address, but if a Pod dies, a new Pod is
created with a different IP — causing connection loss for anything
that was pointing to the old IP. Service solves this by providing
a permanent IP that never changes, and automatically forwards
traffic to whichever Pods are currently running.

### Types of Service

| Type | Access | Use case |
|---|---|---|
| ClusterIP | Inside cluster only | Communication between Pods (default) |
| NodePort | Outside cluster via Node port | Testing only, not for production |
| LoadBalancer | Outside cluster via cloud LB (ALB/NLB) | Production |

### Practice

#### Create ClusterIP Service
```bash
kubectl expose deployment nginx-deployment \
  --port=80 \
  --target-port=80 \
  --name=nginx-svc
```

Output:
```
service/nginx-svc exposed
```

#### Verify Service
```bash
kubectl get svc nginx-svc
```

Output:
```
NAME        TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)   AGE
nginx-svc   ClusterIP   10.107.132.114   <none>        80/TCP    17s
```

#### Access via Service IP
```bash
curl 10.107.132.114
```

Output:
```
Welcome to nginx!
```

#### Prove Service IP does not change
```bash
# Delete all pods
kubectl delete pod --all

# Wait for new pods to be created
kubectl get pods

# Access via same Service IP
curl 10.107.132.114
```

Result: nginx is still accessible via the same IP even after all Pods were replaced.

### Key Takeaway
Service provides a stable IP that never changes regardless of Pod restarts.
Traffic is automatically forwarded to healthy running Pods at all times.

---

## ConfigMap & Secret

### Why not hardcode configuration?
- **Security risk** — passwords exposed in Git, anyone with repo access can see them
- **Not flexible** — changing a database host requires rebuilding the image and editing manifests

### ConfigMap
Used for non-sensitive data such as database host, port, and app config.
Values are stored as plain text and are visible to anyone with kubectl access.

### Secret
Used for sensitive data such as passwords, API keys, and tokens.
Values are base64 encoded — not encrypted. Anyone with kubectl access
can still decode them with `base64 --decode`.

> In production, Secret should be combined with RBAC, AWS Secrets Manager,
> or Vault for proper encryption.

### Practice

#### Create ConfigMap
```bash
kubectl create configmap wordpress-config \
  --from-literal=DB_HOST=mydb.example.com \
  --from-literal=DB_NAME=wordpressdb
```

#### Verify ConfigMap — values are visible in plain text
```bash
kubectl describe configmap wordpress-config
```

Output:
```
Data
====
DB_HOST:
----
mydb.example.com
DB_NAME:
----
wordpressdb
```

#### Create Secret
```bash
kubectl create secret generic wordpress-secret \
  --from-literal=DB_PASSWORD=SuperSecret123 \
  --from-literal=DB_USER=wpuser
```

#### Verify Secret — values are hidden
```bash
kubectl describe secret wordpress-secret
```

Output:
```
Data
====
DB_PASSWORD:  14 bytes
DB_USER:      6 bytes
```

#### Decode Secret value
```bash
kubectl get secret wordpress-secret -o jsonpath='{.data.DB_PASSWORD}' | base64 --decode
```

Output:
```
SuperSecret123
```

Result: Secret is base64 encoded, not encrypted — the original value can be decoded.

### Key Takeaway
- Use **ConfigMap** for non-sensitive configuration
- Use **Secret** for sensitive data
- Secret is NOT encryption — it is only base64 encoding
- In production, always add an extra layer of protection for Secrets

---

## PersistentVolume & PersistentVolumeClaim

### Why do we need PV & PVC?
Container storage is ephemeral (temporary). If a Pod crashes, any data
stored inside the Pod is lost. PV and PVC solve this by storing data
outside the Pod so it survives restarts and crashes.

### PersistentVolume (PV)
The actual storage available in the cluster. Can be backed by
hostPath, EBS, NFS, and others. Created by a cluster admin.

### PersistentVolumeClaim (PVC)
A request for storage made by a Pod. Kubernetes automatically binds
the PVC to a PV that matches the criteria.

### How PVC binds to PV
Kubernetes matches PVC to PV based on 3 criteria:
- **accessModes** must match
- **storage** requested by PVC must not exceed PV capacity
- **StorageClass** must match

Once bound, the Pod references the PVC via `claimName` in the volumes
section, and mounts it to a path inside the container via `volumeMounts`.

```
PV (storage available)
  ↑ bound automatically by Kubernetes
PVC (storage requested)
  ↑ claimName
volumes
  ↑ name reference
volumeMounts (mount path inside container)
```

### Practice

#### Create PV manually
```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-demo
spec:
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteOnce
  hostPath:
    path: /tmp/pv-demo
EOF
```

#### Verify PV — status should be Available
```bash
kubectl get pv
```

Output:
```
NAME      CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS      AGE
pv-demo   1Gi        RWO            Retain           Available   15s
```

#### Create PVC
```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-demo
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF
```

#### Verify PV and PVC — status should be Bound
```bash
kubectl get pv && kubectl get pvc
```

Output:
```
NAME      CAPACITY   STATUS   CLAIM
pv-demo   1Gi        Bound    default/pvc-demo

NAME       STATUS   VOLUME    CAPACITY
pvc-demo   Bound    pv-demo   1Gi
```

#### Create Pod that uses PVC
```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: pod-with-storage
spec:
  containers:
  - name: nginx
    image: nginx
    volumeMounts:
    - mountPath: /data
      name: my-storage
  volumes:
  - name: my-storage
    persistentVolumeClaim:
      claimName: pvc-demo
EOF
```

#### Write data to storage
```bash
kubectl exec pod-with-storage -- sh -c "echo 'data is not lost' > /data/test.txt"
kubectl exec pod-with-storage -- cat /data/test.txt
```

Output:
```
data is not lost
```

#### Delete Pod and recreate — verify data persists
```bash
# Delete Pod
kubectl delete pod pod-with-storage

# Recreate same Pod
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: pod-with-storage
spec:
  containers:
  - name: nginx
    image: nginx
    volumeMounts:
    - mountPath: /data
      name: my-storage
  volumes:
  - name: my-storage
    persistentVolumeClaim:
      claimName: pvc-demo
EOF

# Verify data still exists
kubectl exec pod-with-storage -- cat /data/test.txt
```

Output:
```
data is not lost
```

Result: Data survived Pod deletion because it was stored in PV, not inside the Pod.

### Key Takeaway
- Before PVC is created — PV status is **Available**
- After PVC is created — PV status is **Bound**, PVC status is **Bound**
- Data stored in PV survives Pod restarts and crashes
- Always use PVC in Deployments to ensure data persistence
