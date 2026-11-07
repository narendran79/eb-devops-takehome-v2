# Findings — Part 4 debug lab

Session recording: I have recorded the command session on the file `part4-session.log` (recorded with `script -q`).

---

## Defect 1 — containers never start (`runAsNonRoot` without a numeric user)

**Symptom:**

`./scenario.sh verify` reported every deployment `0/1 ready`, and:

```
$ kubectl get pods -n debug-lab
NAME                        READY   STATUS                       RESTARTS   AGE
backend-7948fd6b4b-mxsk7    0/1     CreateContainerConfigError   0          2m11s
gateway-5cbdcd4bf8-gnlgj    0/1     CreateContainerConfigError   0          2m11s
metrics-547dccf75-6qlkg     0/1     CreateContainerConfigError   0          2m11s
reporter-6f8bff6b8d-mq6x8   0/1     CreateContainerConfigError   0          2m11s
worker-5fcd6b9b6b-8gwjr     0/1     CreateContainerConfigError   0          2m11s
```

```
$ kubectl -n debug-lab get events --sort-by=.lastTimestamp
...
39s  Warning  Failed  pod/reporter-6f8bff6b8d-mq6x8  Error: container has runAsNonRoot and image has non-numeric user (nonroot), cannot verify user is non-root (pod: "reporter-6f8bff6b8d-mq6x8_debug-lab(...)", container: reporter)
```

The same message appeared for all five pods (backend, gateway, metrics, worker, reporter). The image pull itself
succeeded.

**Cause:**

All six templates set `runAsNonRoot: true` on the container but none sets `runAsUser`. The image declares its user
by name (`USER nonroot`). The kubelet cannot resolve a name to a UID, so it cannot prove the user is not root and
refuses to create the container. One cause, five symptoms.

**Fix:**

Added a numeric `runAsUser: 65532` and `runAsGroup: 65532` to the container `securityContext` in all six templates,
keeping `runAsNonRoot: true`. I did not remove `runAsNonRoot`, because that
would hide the error by weakening the security setting. 65532 is the UID I confirmed from the image itself.

**How I found it:**

1. `kubectl get pods -n debug-lab` showed the same status on all five pods, which suggested one shared cause.
2. `kubectl get events --sort-by=.lastTimestamp` gave the exact message above.
3. While checking the templates I've noted that `runAsNonRoot: true` on all six templates
4. Found the right UID by inspecting the image locally - the image had been pulled by containerd inside the kind node:
   ```
   $ docker inspect docker.io/ebinterview/eb-debug-app:1.0.1 --format '{{.Config.User}}'
   nonroot
   $ docker create --name eb-peek docker.io/ebinterview/eb-debug-app:1.0.1 /app
   $ docker cp eb-peek:/etc/passwd - | grep -a nonroot
   nonroot:x:65532:65532:nonroot:/home/nonroot:/sbin/nologin
   $ docker rm eb-peek
   ```

---

## Defect 2 — migrate Job rejected by the API server, release stuck in `failed`

**Symptom:**

`verify` reported: `FAIL  migrate Job has not completed`

```
$ helm -n debug-lab list
NAME        NAMESPACE   REVISION  UPDATED                               STATUS  CHART            APP VERSION
debug-lab   debug-lab   1         2026-11-07 00:03:51.485473 +0530 IST  failed  debug-lab-2.0.0  1.0.1
```

```
$ helm upgrade debug-lab . -n debug-lab
Error: UPGRADE FAILED: failed to create resource: server-side apply failed for object debug-lab/migrate batch/v1, Kind=Job: Job.batch "migrate" is invalid: spec.template.spec.restartPolicy: Required value: valid values: "OnFailure", "Never"
```

`helm history debug-lab` showed revisions 1, 2 and 3 all `failed` with this same error. There was no `migrate` Job
or pod in the namespace.

**Cause:**

The Job's pod template had no `restartPolicy`. For a Job it must be `OnFailure` or `Never`, so the API server rejected
the object, the Job was never created, and Helm marked the release failed each time.

**Fix:**

Added `restartPolicy: OnFailure` under `spec.template.spec` in `templates/migrate-job.yaml`, at the same level
as `containers:`.

**How I found it:**

1. `helm -n debug-lab list` showed the release as `failed`, which was a clue that the install itself had a problem
   and not just the pods.
2. `helm upgrade` printed the API server's validation error naming the exact field.
3. `helm -n debug-lab history debug-lab` and `helm -n debug-lab status debug-lab` showed the same error on every
   revision, so it was a persistent template error and not a transient one.
4. Read `templates/migrate-job.yaml` and found `restartPolicy` missing from the pod spec.
5. Validated with `helm upgrade debug-lab . -n debug-lab --dry-run=server` before the real upgrade, so I would not
   create another failed revision.

---

## Defect 3 — app listens on 8081, chart expects 8080

**Symptom:**

After defects 1 and 2, the new pods were `Running` but `0/1` Ready, and the Services had no endpoints:

```
$ kubectl -n debug-lab get endpoints
NAME       ENDPOINTS   AGE
backend                46m
gateway                46m
reporter               46m
```

```
$ kubectl -n debug-lab logs backend-6865788b54-qpbhw
... eb-debug-app 2.0.0 starting: mode=api pod=backend-6865788b54-qpbhw listening on :8081 (image default is 8081; set PORT to override)
```

```
$ kubectl -n debug-lab describe pod backend-6865788b54-qpbhw | sed -n '/Events:/,$p'
  Warning  Unhealthy  3m16s (x63 over 8m19s)  kubelet  Readiness probe failed: Get "http://10.244.0.16:8080/healthz": dial tcp 10.244.0.16:8080: connect: connection refused
```

The gateway, metrics and reporter logs also said `listening on :8081`, and `describe` showed
`Readiness: http-get http://:8080/healthz` for all of them.

**Cause:**

The image listens on 8081 by default. The chart sets `containerPort`, the readiness probe and the Service
`targetPort` to `common.port` (8080), and no template sets the `PORT` env var, so the app never moves to 8080.
Probes get `connection refused`, pods never become Ready, and the Services have no endpoints.

**Fix:**

Set `PORT` env to the chart's `common.port` (8080) for backend, gateway, metrics, reporter and worker,
rather than changing the probe to 8081, because the Services and the `verify` check expect
`backend:8080`.

**How I found it:**

1. `kubectl get endpoints` showed empty endpoints, which meant no ready pod was behind those Services.
2. `kubectl logs` on each pod showed the port the app really listens on (8081).
3. `kubectl describe pod ... | grep -E 'Readiness|Liveness|Port|PORT'` showed the probe and port the chart configured (8080).
4. `grep -n -i -E 'port|PORT' templates/*.yaml` showed everything keyed to `common.port` and no `PORT` env anywhere.

---

## Defect 4 — worker crashes: read-only root filesystem, no writable cache directory

**Symptom:**

```
$ kubectl -n debug-lab get pods
worker-644f6d84cd-zjczr   0/1   CrashLoopBackOff   6 (2m12s ago)   7m57s
```

```
$ kubectl -n debug-lab logs worker-644f6d84cd-zjczr --previous
... FATAL: worker could not initialise its cache: mkdir /var/cache/app: read-only file system — the process needs a writable directory at /var/cache/app (mount a volume there, or set CACHE_DIR)
```

`./scenario.sh verify` also reported `FAIL  1 pod(s) in CrashLoopBackOff`.

**Cause:**

The container runs with `readOnlyRootFilesystem: true`, but the worker needs to create `/var/cache/app`, and nothing
is mounted there.

**Fix:**

Need to add an `emptyDir` volume named `cache` mounted at `/var/cache/app` in `templates/worker.yaml`, and keep `readOnlyRootFilesystem: true`.

**How I found it:**

1. `kubectl get pods` showed the worker in `CrashLoopBackOff`.
2. `kubectl logs <worker-pod> --previous` showed the log of the crashed attempt, which contained the exact path and
   suggested fixes. (Plain `kubectl logs` can be empty or show a different attempt.)
3. Cross-checked against the chart's `readOnlyRootFilesystem: true` setting.

---

## How I used AI on this part

Tool: Kiro, used as a pairing partner, not as a replacement for investigating.

- I debugged the issue and checked with AI that I'm working on the right path or not.
- I've asked with AI on the area's I'm stuck with an issue while debugging and it helped me on those area's.
- Before running anything on cluster, I'll check the response from AI and only if its true and related to issue I'll check that on cluster. 

## If I ran out of time
- Sorry I can able to find only 4 defects within timeline.