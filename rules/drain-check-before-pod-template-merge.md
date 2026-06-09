Before merging a gitops PR that changes a pod template, identify the workloads that will roll and drain-check the affected agents' sessions — under ArgoCD auto-sync, merge time IS rollout time.
