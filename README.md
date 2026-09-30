# Tapestry deployment through SSM

The cloud agent sends an `AWS-RunShellScript` command to the approved EC2 instance. That command clones this repository, enters `ssm-script`, and runs `ssm-init.sh`. The script verifies that `manifest/manifest.yaml` has the same SHA-256 as the manifest inspected in Bitbucket, replaces the matching container image with the pipeline image digest, applies the manifest to EKS, waits for the workload rollout, and exits.

Keep `manifest/manifest.yaml` byte-for-byte identical to `k8s/deployment.yaml` at the Bitbucket commit used by the workflow. The manifest here currently matches Tapestry commit `53f5686c721b3bd24b2c844c19087130987e2004` (SHA-256 `103cd2e48cac8d21e8a4f14092dfbd9cad1080b4d9c850b1343818e6e4ac8261`). A changed manifest must be copied here and published before the workflow uses it.

The EC2 instance needs outbound HTTPS access to GitHub, Git, Bash, AWS CLI, kubectl, Python 3 with PyYAML, and an IAM/Kubernetes identity allowed to access the target EKS cluster and namespace. The script uses a temporary kubeconfig and removes its temporary files when it exits. It does not need a preinstalled `/opt/valueops/bin/deploy-eks` runner.
