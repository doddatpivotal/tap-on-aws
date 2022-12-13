# TAP on AWS

[Docs](https://docs.vmware.com/en/VMware-Tanzu-Application-Platform/1.3/tap/GUID-aws-install-intro.html)

This plan assumes relocating images (cluster essentials, tap, and tbs-full-dependencies) to ECR.  This adds over an hour to the process.  If this is not required, consider alternative approaches.

## Prereqs
- Installed eksctl through brew
- Needed to update the aws cli using command line installer - https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html

## Setup environment

Update the params.yaml file with your environment specific values and then setup shell variables.

```bash
cp local-config/params-REDACTED.yaml local-config/params.yaml
# Update params.yaml based upon your environment
export PARAMS_YAML=local-config/params.yaml
```

## Relocate TAP Images

```bash
# Need to create ECR repositories before pushing images
aws ecr create-repository --repository-name tap-images --region $AWS_REGION

# Login to ECR (12 hour access)
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com
# Login to Tanzu Net
echo $INSTALL_REGISTRY_PASSWORD | docker login --username $INSTALL_REGISTRY_USERNAME --password-stdin registry.tanzu.vmware.com

export TAP_VERSION=$(yq e .tap.version $PARAMS_YAML)
export INSTALL_REGISTRY_HOSTNAME=$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com
export INSTALL_REPO=tap-images

imgpkg copy --concurrency 1 -b registry.tanzu.vmware.com/tanzu-application-platform/tap-packages:${TAP_VERSION} --to-repo ${INSTALL_REGISTRY_HOSTNAME}/${INSTALL_REPO}
# The above command took 1.5 hours on my macbook and home internet.  Consider continuing on through next several steps and then stopping an waiting to complete before
# Creating Tanzu Package Repository

```

## Create EKS Cluster

```bash
export AWS_ACCOUNT_ID=$(yq e .aws.account-id $PARAMS_YAML)
export AWS_REGION=$(yq e .aws.region $PARAMS_YAML)
export EKS_CLUSTER_NAME=$(yq e .aws.eks-cluster-name $PARAMS_YAML)
export K8S_VERSION=$(yq e .aws.eks-k8s-version $PARAMS_YAML)

# --with-oidc flag ensures that an IAM OIDC provider is setup for the cluster.  This is requried for CSI Driver.  If you don't do this here, you
# woudl have to follow steps at https://docs.aws.amazon.com/eks/latest/userguide/enable-iam-roles-for-service-accounts.html
eksctl create cluster --name $EKS_CLUSTER_NAME --managed --region $AWS_REGION --instance-types t3.xlarge --version $K8S_VERSION --with-oidc -N 4

```

## CSI Setup

```bash

## Create's cluster specific IAM role for CSI
eksctl create iamserviceaccount \
  --name ebs-csi-controller-sa \
  --namespace kube-system \
  --cluster $EKS_CLUSTER_NAME \
  --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
  --approve \
  --role-only \
  --role-name AmazonEKS_EBS_CSI_DriverRole

# Create the add on referencing the role above
eksctl create addon --name aws-ebs-csi-driver --cluster $EKS_CLUSTER_NAME --service-account-role-arn arn:aws:iam::$AWS_ACCOUNT_ID:role/AmazonEKS_EBS_CSI_DriverRole --force

# Validate the addon was created properly.  Look at Status=ACTIVE and Issues=0
eksctl get addon --name aws-ebs-csi-driver --cluster $EKS_CLUSTER_NAME

```

## (Optional) Validate CSI Driver is working properly

```bash
# Test https://docs.aws.amazon.com/eks/latest/userguide/ebs-sample-app.html

git clone https://github.com/kubernetes-sigs/aws-ebs-csi-driver.git /tmp/aws-ebc-csi-driver
pushd /tmp/aws-ebc-csi-driver/examples/kubernetes/dynamic-provisioning/
# create PVC, Pod, SC
kubectl apply -f manifests/
kubectl describe storageclass ebs-sc
kubectl get pods
kubectl get pv
kubectl describe pv $(kubectl get pv -ojsonpath='{.items[0].metadata.name}')
kubectl exec -it app -- cat /data/out.txt
kubectl delete -f manifests/
popd

```

## Setup IAM Roles for Access to ECR
```bash
# Create IAM Roles for TBS and Supply Chain to write images to tap-build-service and tanzu-application-platform repositories
./scripts/iam-roles.sh

```

## Deploy Cluster Essentials

```bash
pivnet download-product-files --product-slug='tanzu-cluster-essentials' --release-version='1.3.0' --product-file-id=1330472 -d /tmp/
mkdir $HOME/tanzu-cluster-essentials
tar -xvf /tmp/tanzu-cluster-essentials-darwin-amd64-1.3.0.tgz -C $HOME/tanzu-cluster-essentials

aws ecr create-repository --repository-name cluster-essentials-bundle --region $AWS_REGION

export INSTALL_REGISTRY_HOSTNAME=$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com
export INSTALL_BUNDLE=$INSTALL_REGISTRY_HOSTNAME/cluster-essentials-bundle@sha256:54bf611711923dccd7c7f10603c846782b90644d48f1cb570b43a082d18e23b9
export INSTALL_REGISTRY_USERNAME=AWS
export INSTALL_REGISTRY_PASSWORD=$(aws ecr get-login-password --region $AWS_REGION)

imgpkg copy \
  -b registry.tanzu.vmware.com/tanzu-cluster-essentials/cluster-essentials-bundle@sha256:54bf611711923dccd7c7f10603c846782b90644d48f1cb570b43a082d18e23b9 \
  --to-repo $INSTALL_REGISTRY_HOSTNAME/cluster-essentials-bundle


pushd $HOME/tanzu-cluster-essentials
./install.sh --yes
popd
```

## Create Tanzu Package Repository

>Note: Ensure that the relocation of TAP images has completed before continuing.

```bash
kubectl create ns tap-install
tanzu package repository add tanzu-tap-repository \
  --url ${INSTALL_REGISTRY_HOSTNAME}/${INSTALL_REPO}:$TAP_VERSION \
  --namespace tap-install

tanzu package repository get tanzu-tap-repository --namespace tap-install
tanzu package available list --namespace tap-install
```

## Deploy TAP

```bash
# TBS will create clusterbuilder, clusterstack iamges here.  Need to create ECR repositories before, TBS can push images there
aws ecr create-repository --repository-name tap-build-service --region $AWS_REGION

# Generate TAP Values, using mostly default values
./scripts/gen-tap-values.sh 

# Install TAP (does not include TBS builderse)
tanzu package install tap -p tap.tanzu.vmware.com -v $TAP_VERSION --values-file generated/tap-values.yaml -n tap-install
```

## Configure TBS with Full Dependencies

```bash
TBS_VERSION=$(tanzu package available list buildservice.tanzu.vmware.com --namespace tap-install -ojson | jq '.[0].version' -r)

# You will relocate tbs full dependency images here
aws ecr create-repository --repository-name tbs-full-deps --region $AWS_REGION

# Relocate full dependency images to the ECR repository you created earlier
imgpkg copy -b registry.tanzu.vmware.com/tanzu-application-platform/full-tbs-deps-package-repo:$TBS_VERSION --to-repo ${INSTALL_REGISTRY_HOSTNAME}/tbs-full-deps
# The above command took 0.5 hours on my macbook and home internet

# Create package repo and install the dependency package
tanzu package repository add tbs-full-deps-repository --url ${INSTALL_REGISTRY_HOSTNAME}/tbs-full-deps:$TBS_VERSION --namespace tap-install
tanzu package install full-tbs-deps -p full-tbs-deps.tanzu.vmware.com -v $TBS_VERSION -n tap-install

```

## Access TAP GUI

```bash
kubectl get service envoy -n tanzu-system-ingress
# Add CNAME record for "*."+$(yq e .tap.ingress-domain $PARAMS_YAML)

open http://tap-gui.$(yq e .tap.ingress-domain $PARAMS_YAML)
```

## Setup Developer Namespace

```bash
./scripts/enable-single-user-access.sh
```

## Test out Getting Started

```bash
# First Create ECR Repositories
./scripts/create-workload-repositories.sh tanzu-java-web-app
```

Follow [Getting Started](https://docs.vmware.com/en/VMware-Tanzu-Application-Platform/1.3/tap/GUID-getting-started.html)

## Notes
- Workload Role is only granted on the default service account within default namespace.  Would need to update this, if you are to create other developer namespaces

## Teardown

```bash
# Delete EKS Cluster
eksctl delete cluster tap-on-aws

# Remove ECR repositories
aws ecr delete-repository --repository-name tanzu-application-platform/tanzu-java-web-app-default --force --region $AWS_REGION
aws ecr delete-repository --repository-name tanzu-application-platform/tanzu-java-web-app-default-bundle --force --region $AWS_REGION
aws ecr delete-repository --repository-name tanzu-application-platform/tanzu-java-web-app-default-source --force --region $AWS_REGION
aws ecr delete-repository --repository-name tap-images --force --region $AWS_REGION
aws ecr delete-repository --repository-name tap-build-service --force --region $AWS_REGION
aws ecr delete-repository --repository-name tbs-full-deps --force --region $AWS_REGION

# Remove IAM Roles
aws iam delete-role-policy --role-name tap-build-service --policy-name tapBuildServicePolicy
aws iam delete-role --role-name tap-build-service
aws iam delete-role-policy --role-name tap-workload --policy-name tapWorkload
aws iam delete-role --role-name tap-workload
aws iam detach-role-policy --role-name AmazonEKS_EBS_CSI_DriverRole --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy
aws iam delete-role --role-name AmazonEKS_EBS_CSI_DriverRole

# Delete CNAME in regestra
"*." + $(yq e .tap.ingress-domain $PARAMS_YAML)
```