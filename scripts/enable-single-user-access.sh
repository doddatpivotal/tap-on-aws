# Script from: https://docs.vmware.com/en/VMware-Tanzu-Application-Platform/1.3/tap/GUID-set-up-namespaces-aws.html#enable-single-user-access-0

: ${AWS_ACCOUNT_ID?"Need to set AWS_ACCOUNT_ID environment variable"}
: ${PARAMS_YAML?"Need to set AWS_ACCOUNT_ID environment variable"}

DEV_NAMESPACE=$(yq e .tap.dev-namespace $PARAMS_YAML)

ROLE_ARN=arn:aws:iam::${AWS_ACCOUNT_ID}:role/tap-workload

cat <<EOF | kubectl -n ${DEV_NAMESPACE} apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: default
  annotations:
    eks.amazonaws.com/role-arn: ${ROLE_ARN}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: default-permit-deliverable
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: deliverable
subjects:
  - kind: ServiceAccount
    name: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: default-permit-workload
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: workload
subjects:
  - kind: ServiceAccount
    name: default
EOF