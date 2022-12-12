# Script from: https://docs.vmware.com/en/VMware-Tanzu-Application-Platform/1.3/tap/GUID-install-aws.html#full-profile
# Modified slightly for generation based upon variables

: ${AWS_REGION?"Need to set AWS_REGION environment variable"}
: ${AWS_ACCOUNT_ID?"Need to set AWS_ACCOUNT_ID environment variable"}
: ${PARAMS_YAML?"Need to set AWS_ACCOUNT_ID environment variable"}

INGRESS_DOMAIN=$(yq e .tap.ingress-domain $PARAMS_YAML)
DEV_NAMESPACE=$(yq e .tap.dev-namespace $PARAMS_YAML)
GIT_CATALOG_URL=$(yq e .tap.git-catalog-url $PARAMS_YAML)

cat << EOF > generated/tap-values.yaml
shared:
  ingress_domain: ${INGRESS_DOMAIN}

ceip_policy_disclosed: true

#The above keys are minimum numbers of entries needed in tap-values.yaml to get a functioning TAP Full profile installation.

#Below are the keys which may have default values set, but can be overridden.

profile: full # Can take iterate, build, run, view.

excluded_packages:
- policy.apps.tanzu.vmware.com

supply_chain: basic # Can take testing, testing_scanning.

ootb_supply_chain_basic: # Based on supply_chain set above, can be changed to ootb_supply_chain_testing, ootb_supply_chain_testing_scanning.
  registry:
    server: ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com
    # The prefix of the ECR repository.  Workloads will need
    # two repositories created:
    #
    # tanzu-application-platform/<workloadname>-<namespace>
    # tanzu-application-platform/<workloadname>-<namespace>-bundle
    repository: tanzu-application-platform

buildservice:
  kp_default_repository: ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/tap-build-service
  # Enable the build service k8s service account to bind to the AWS IAM Role
  kp_default_repository_aws_iam_role_arn: "arn:aws:iam::${AWS_ACCOUNT_ID}:role/tap-build-service"
  exclude_dependencies: true

ootb_templates:
  # Enable the config writer service to use cloud based iaas authentication
  # which are retrieved from the developer namespace service account by
  # default
  iaas_auth: true

tap_gui:
  service_type: ClusterIP # If shared.ingress_domain is set earlier, this must be set to ClusterIP.
  app_config:
    catalog:
      locations:
        - type: url
          target: https://${GIT_CATALOG_URL}/catalog-info.yaml

metadata_store:
  ns_for_export_app_cert: ${DEV_NAMESPACE}
  app_service_type: ClusterIP # Defaults to LoadBalancer. If shared.ingress_domain is set earlier, this must be set to ClusterIP.

scanning:
  metadataStore:
    url: "" # Configuration is moved, so set this string to empty.

EOF