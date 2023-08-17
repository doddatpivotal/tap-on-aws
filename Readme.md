# TAP on AWS

The Tanzu Application Platform runs great on AWS.  You can get up and running following the [AWS Specific Installation Docs](https://docs.vmware.com/en/VMware-Tanzu-Application-Platform/1.6/tap/install-aws-intro.html).

The docs provide some deployment optionality.  It also references some external content for certain tasks.  This repository follows those docs, presenting the actual commands I had executed to complete the installation.
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
export AWS_REGION=$(yq e .aws.region $PARAMS_YAML)
export AWS_ACCOUNT_ID=$(yq e .aws.account-id $PARAMS_YAML)
export EKS_CLUSTER_NAME=$(yq e .aws.eks-cluster-name $PARAMS_YAML)
export TAP_VERSION=$(yq e .tap.version $PARAMS_YAML)
export INSTALL_REPO=tap-images
export TANZUNET_USERNAME=$(yq e .tanzunet.username $PARAMS_YAML)
export TANZUNET_PASSWORD=$(yq e .tanzunet.password $PARAMS_YAML)
export INSTALL_REGISTRY_USERNAME=AWS
export INSTALL_REGISTRY_PASSWORD=$(aws ecr get-login-password --region $AWS_REGION)
export INSTALL_REGISTRY_HOSTNAME=$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com
export CLUSTER_ESSENTIALS_INSTALL_BUNDLE_SHA256=54e516b5d088198558d23cababb3f907cd8073892cacfb2496bb9d66886efe15
export K8S_VERSION=$(yq e .aws.eks-k8s-version $PARAMS_YAML)

```

## Create EKS Cluster

```bash

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

# Validate the addon was created properly.  Look at Status=ACTIVE and Issues=0.  You might have to repeat a few times while it is creating
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
# whait until STATUS=Running
kubectl get pv
# wait until STATUS=Bound
kubectl describe pv $(kubectl get pv -ojsonpath='{.items[0].metadata.name}')
kubectl exec -it app -- cat /data/out.txt
# look for time stamps
kubectl delete -f manifests/
popd

```

## Create the container repositories

```bash
# TAP will dynamically push images to these repositories
aws ecr create-repository --repository-name tap-build-service --region $AWS_REGION --output json
aws ecr create-repository --repository-name tap-lsp --region $AWS_REGION --output json

# Images will be relocated to these reposibitores during the installation process
aws ecr create-repository --repository-name tap-images --region $AWS_REGION --output json
aws ecr create-repository --repository-name tbs-full-deps --region ${AWS_REGION} --output json
aws ecr create-repository --repository-name tanzu-cluster-essentials --region $AWS_REGION

```

## Setup IAM Roles for Access to ECR
```bash
# Create IAM Roles for TBS and Supply Chain to write images to tap-build-service and tanzu-application-platform repositories

./scripts/iam-roles.sh

```

## Download Cluster Essentials Script

```
pivnet download-product-files --product-slug='tanzu-cluster-essentials' --release-version='1.6.0' --product-file-id=1526700 -d /tmp/
rm -rf $HOME/tanzu-cluster-essentials && mkdir $HOME/tanzu-cluster-essentials
tar -xvf /tmp/tanzu-cluster-essentials-darwin-amd64-1.6.0.tgz -C $HOME/tanzu-cluster-essentials
```

## Relocate Cluster Essentials Images

```bash

# Login to ECR (12 hour access)
echo $INSTALL_REGISTRY_PASSWORD | docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

# Login to Tanzu Net
echo $TANZUNET_PASSWORD | docker login --username $TANZUNET_USERNAME --password-stdin registry.tanzu.vmware.com

IMGPKG_REGISTRY_HOSTNAME_0=registry.tanzu.vmware.com \
  IMGPKG_REGISTRY_USERNAME_0=$TANZUNET_USERNAME \
  IMGPKG_REGISTRY_PASSWORD_0=$TANZUNET_PASSWORD \
  IMGPKG_REGISTRY_HOSTNAME_1=$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com \
  IMGPKG_REGISTRY_USERNAME_1=$INSTALL_REGISTRY_USERNAME \
  IMGPKG_REGISTRY_PASSWORD_1=$INSTALL_REGISTRY_PASSWORD \
  imgpkg copy \
    -b registry.tanzu.vmware.com/tanzu-cluster-essentials/cluster-essentials-bundle@sha256:$CLUSTER_ESSENTIALS_INSTALL_BUNDLE_SHA256 \
    --to-repo $INSTALL_REGISTRY_HOSTNAME/tanzu-cluster-essentials \
    --include-non-distributable-layers

```

## Deploy Cluster Essentials

```bash
export INSTALL_BUNDLE=$INSTALL_REGISTRY_HOSTNAME/tanzu-cluster-essentials@sha256:$CLUSTER_ESSENTIALS_INSTALL_BUNDLE_SHA256

pushd $HOME/tanzu-cluster-essentials
./install.sh --yes
popd
```

## Relocate TAP Images

Putting this step ahead of the EKS cluster create because it takes a long time to complete.

```bash

# Need to create ECR repositories before pushing images

imgpkg copy --concurrency 1 -b registry.tanzu.vmware.com/tanzu-application-platform/tap-packages:${TAP_VERSION} --to-repo ${INSTALL_REGISTRY_HOSTNAME}/${INSTALL_REPO} --include-non-distributable-layers
# The above command took 1.5 hours on my macbook and home internet.  Consider continuing on through next several steps and then stopping an waiting to complete before
# Creating Tanzu Package Repository

```


## Create Tanzu Package Repository

>Note: Ensure that the relocation of TAP images has completed before continuing.

```bash
kubectl create ns tap-install
tanzu package repository add tanzu-tap-repository \
  --url ${INSTALL_REGISTRY_HOSTNAME}/${INSTALL_REPO}:${TAP_VERSION} \
  --namespace tap-install

# Verification
tanzu package repository get tanzu-tap-repository --namespace tap-install
tanzu package available list --namespace tap-install

```

## Deploy TAP

```bash
# Generate TAP Values, using mostly default values
./scripts/gen-tap-values.sh 

# Install TAP (does not include TBS builders)
tanzu package install tap -p tap.tanzu.vmware.com -v ${TAP_VERSION} --values-file generated/tap-values.yaml -n tap-install
```

## Relocatae TBS Full Dependencies

```bash
# You will relocate tbs full dependency images here

# Relocate full dependency images to the ECR repository you created earlier
IMGPKG_REGISTRY_HOSTNAME_0=registry.tanzu.vmware.com \
  IMGPKG_REGISTRY_USERNAME_0=$TANZUNET_USERNAME \
  IMGPKG_REGISTRY_PASSWORD_0=$TANZUNET_PASSWORD \
  IMGPKG_REGISTRY_HOSTNAME_1=$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com \
  IMGPKG_REGISTRY_USERNAME_1=AWS \
  IMGPKG_REGISTRY_PASSWORD_1=$INSTALL_REGISTRY_PASSWORD \
  imgpkg copy -b registry.tanzu.vmware.com/tanzu-application-platform/full-deps-package-repo:${TAP_VERSION} --to-repo ${INSTALL_REGISTRY_HOSTNAME}/tbs-full-deps
# The above command took 0.5 hours on my macbook and home internet

```

## Configure TBS with Full Dependencies

```bash

# Create package repo and install the dependency package
tanzu package repository add full-deps-repository --url ${INSTALL_REGISTRY_HOSTNAME}/tbs-full-deps:${TAP_VERSION} --namespace tap-install

tanzu package install full-deps -p full-deps.buildservice.tanzu.vmware.com -v "> 0.0.0" -n tap-install --values-file generated/tap-values.yaml

# wait until become ready
tanzu build-service clusterstack list
tanzu build-service clusterbuilder list
```

## Access TAP GUI

```bash
CNAME=$(kubectl get service envoy -n tanzu-system-ingress -oyaml | yq e .status.loadBalancer.ingress[0].hostname)
echo "TODO: Create Route53 CNAME record for *."$(yq e .tap.ingress-domain $PARAMS_YAML)" pointing to $CNAME"
# Wait a minute to allow the record to propagate
open https://tap-gui.$(yq e .tap.ingress-domain $PARAMS_YAML)
```

## Setup Developer Namespace

```bash
DEV_NAMESPACE=$(yq e .tap.dev-namespace $PARAMS_YAML)
kubectl label namespace $DEV_NAMESPACE apps.tanzu.vmware.com/tap-ns=""
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
aws ecr delete-repository --repository-name tap-images --force --region $AWS_REGION
aws ecr delete-repository --repository-name tap-build-service --force --region $AWS_REGION
aws ecr delete-repository --repository-name tanzu-cluster-essentials --force --region $AWS_REGION
aws ecr delete-repository --repository-name tbs-full-deps --force --region $AWS_REGION
aws ecr delete-repository --repository-name tap-lsp --force --region $AWS_REGION

# Remove IAM Roles
aws iam delete-role-policy --role-name tap-build-service --policy-name tapBuildServicePolicy
aws iam delete-role --role-name tap-build-service
aws iam delete-role-policy --role-name tap-workload --policy-name tapWorkload
aws iam delete-role --role-name tap-workload
aws iam delete-role-policy --role-name tap-local-source-proxy --policy-name tapLocalSourcePolicy
aws iam delete-role --role-name tap-local-source-proxy

# Following is not necessary if you already deleted the eks clsuter
aws iam detach-role-policy --role-name AmazonEKS_EBS_CSI_DriverRole --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy
aws iam delete-role --role-name AmazonEKS_EBS_CSI_DriverRole

# Delete CNAME in registrar
echo "*." + $(yq e .tap.ingress-domain $PARAMS_YAML)
```