#!/bin/bash
set -e

# This script will initiate the provisioning process of MAS. It will perform following steps,

## Variables
export AWS_DEFAULT_REGION=$DEPLOY_REGION
MASTER_INSTANCE_TYPE="m5.2xlarge"
WORKER_INSTANCE_TYPE="m5.4xlarge"
# Mongo variables
export MONGODB_STORAGE_CLASS=gp2
# Amqstreams variables
export KAFKA_STORAGE_CLASS=gp2
# IAM variables
IAM_POLICY_NAME="masocp-policy-${RANDOM_STR}"
IAM_USER_NAME="masocp-user-${RANDOM_STR}"
# SLS variables
export SLS_STORAGE_CLASS=gp2
# CP4D variables
export CPD_METADB_BLOCK_STORAGE_CLASS=gp2

# Retrieve SSH public key
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
SSH_PUB_KEY=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" â€“v http://169.254.169.254/latest/meta-data/public-keys/0/openssh-key)

log "Below are Cloud specific deployment parameters,"
log " AWS_DEFAULT_REGION: $AWS_DEFAULT_REGION"
log " MASTER_INSTANCE_TYPE: $MASTER_INSTANCE_TYPE"
log " WORKER_INSTANCE_TYPE: $WORKER_INSTANCE_TYPE"
log " MONGODB_STORAGE_CLASS: $MONGODB_STORAGE_CLASS"
log " KAFKA_STORAGE_CLASS: $KAFKA_STORAGE_CLASS"
log " IAM_POLICY_NAME: $IAM_POLICY_NAME"
log " IAM_USER_NAME: $IAM_USER_NAME"
log " SLS_STORAGE_CLASS: $SLS_STORAGE_CLASS"
log " CPD_METADB_BLOCK_STORAGE_CLASS: $CPD_METADB_BLOCK_STORAGE_CLASS"
log " SSH_PUB_KEY: $SSH_PUB_KEY"

if [[ -f entitlement.lic ]]; then
  chmod 600 entitlement.lic
fi

## Download files from S3 bucket
# Download SLS certificate
cd $GIT_REPO_HOME
if [[ ${SLS_PUB_CERT_URL,,} =~ ^https? ]]; then
  log "Downloading SLS certificate from HTTP URL"
  wget "$SLS_PUB_CERT_URL" -O sls.crt
elif [[ ${SLS_PUB_CERT_URL,,} =~ ^s3 ]]; then
  log "Downloading SLS certificate from S3 URL"
  aws s3 cp "$SLS_PUB_CERT_URL" sls.crt
fi
if [[ -f sls.crt ]]; then
  chmod 600 sls.crt
fi
# Download UDS certificate
cd $GIT_REPO_HOME
if [[ ${UDS_PUB_CERT_URL,,} =~ ^https? ]]; then
  log "Downloading BAS certificate from HTTP URL"
  wget "$UDS_PUB_CERT_URL" -O bas.crt
elif [[ ${UDS_PUB_CERT_URL,,} =~ ^s3 ]]; then
  log "Downloading BAS certificate from S3 URL"
  aws s3 cp "$UDS_PUB_CERT_URL" bas.crt
fi
if [[ -f bas.crt ]]; then
  chmod 600 bas.crt
fi

### Read License File & Retrive SLS hostname and host id
line=$(head -n 1 entitlement.lic)
set -- $line
hostname=$2
hostid=$3
log " SLS_HOSTNAME: $hostname"
log " SLS_HOST_ID: $hostid"
#SLS Instance name
export SLS_INSTANCE_NAME="$hostname"
export SLS_LICENSE_ID="$hostid"

## IAM
# Create IAM policy
cd $GIT_REPO_HOME/aws
policyarn=$(aws iam create-policy --policy-name ${IAM_POLICY_NAME} --policy-document file://${GIT_REPO_HOME}/aws/iam/policy.json | jq '.Policy.Arn' | tr -d "\"")
# Create IAM user
aws iam create-user --user-name ${IAM_USER_NAME}
aws iam attach-user-policy --user-name ${IAM_USER_NAME} --policy-arn $policyarn
accessdetails=$(aws iam create-access-key --user-name ${IAM_USER_NAME})
export AWS_ACCESS_KEY_ID=$(echo $accessdetails | jq '.AccessKey.AccessKeyId' | tr -d "\"")
export AWS_SECRET_ACCESS_KEY=$(echo $accessdetails | jq '.AccessKey.SecretAccessKey' | tr -d "\"")
echo " AWS_ACCESS_KEY_ID: $AWS_ACCESS_KEY_ID"
# Put some delay for IAM permissions to be applied in the backend
sleep 60

if [[ $OPENSHIFT_USER_PROVIDE == "false" ]]; then
  ## Provisiong OCP cluster
  # Create tfvars file
  cd $GIT_REPO_HOME/aws/ocp-terraform
  rm -rf terraform.tfvars

  if [[ $DEPLOY_REGION == "ap-northeast-1" ]]
  then
    AVAILABILITY_ZONE_1="${DEPLOY_REGION}a"
    AVAILABILITY_ZONE_2="${DEPLOY_REGION}c"
    AVAILABILITY_ZONE_3="${DEPLOY_REGION}d"
  elif [[ $DEPLOY_REGION == "ca-central-1" ]]
  then
    AVAILABILITY_ZONE_1="${DEPLOY_REGION}a"
    AVAILABILITY_ZONE_2="${DEPLOY_REGION}b"
    AVAILABILITY_ZONE_3="${DEPLOY_REGION}d"
  else
    AVAILABILITY_ZONE_1="${DEPLOY_REGION}a"
    AVAILABILITY_ZONE_2="${DEPLOY_REGION}b"
    AVAILABILITY_ZONE_3="${DEPLOY_REGION}c"
  fi

  cat <<EOT >> terraform.tfvars
cluster_name                    = "$CLUSTER_NAME"
region                          = "$DEPLOY_REGION"
az                              = "$AZ_MODE"
availability_zone1              = "${AVAILABILITY_ZONE_1}"
availability_zone2              = "${AVAILABILITY_ZONE_2}"
availability_zone3              = "${AVAILABILITY_ZONE_3}"
access_key_id                   = "$AWS_ACCESS_KEY_ID"
secret_access_key               = "$AWS_SECRET_ACCESS_KEY"
base_domain                     = "$BASE_DOMAIN"
openshift_pull_secret_file_path = "$OPENSHIFT_PULL_SECRET_FILE_PATH"
public_ssh_key                  = "$SSH_PUB_KEY"
openshift_username              = "$OCP_USERNAME"
openshift_password              = "$OCP_PASSWORD"
cpd_api_key                     = "$CPD_API_KEY"
master_instance_type            = "$MASTER_INSTANCE_TYPE"
worker_instance_type            = "$WORKER_INSTANCE_TYPE"
master_replica_count            = "$MASTER_NODE_COUNT"
worker_replica_count            = "$WORKER_NODE_COUNT"
accept_cpd_license              = "accept"
EOT
  log "==== OCP cluster creation started ===="
  # Deploy OCP cluster
  sed -i "s/<REGION>/$DEPLOY_REGION/g" variables.tf
  terraform init -input=false
  terraform plan -input=false -out=tfplan
  set +e
  terraform apply -input=false -auto-approve
  retcode=$?
  if [[ $retcode -ne 0 ]]; then
    log "OCP cluster creation failed in Terraform step"
    exit 21
  fi
  set -e
  log "==== OCP cluster creation completed ===="

## Add ER Key to global pull secret
#   cd /tmp
#   # Login to OCP cluster
#   oc login -u $OCP_USERNAME -p $OCP_PASSWORD --server=https://api.${CLUSTER_NAME}.${BASE_DOMAIN}:6443
#   oc extract secret/pull-secret -n openshift-config --keys=.dockerconfigjson --to=. --confirm
#   export encodedEntitlementKey=$(echo cp:$SLS_ENTITLEMENT_KEY | tr -d '\n' | base64 -w0)
#   ##export encodedEntitlementKey=$(echo cp:$SLS_ENTITLEMENT_KEY | base64 -w0)
#   export emailAddress=$(cat .dockerconfigjson | jq -r '.auths["cloud.openshift.com"].email')
#   jq '.auths |= . + {"cp.icr.io": { "auth" : "$encodedEntitlementKey", "email" : "$emailAddress"}}' .dockerconfigjson > /tmp/dockerconfig.json
#   envsubst < /tmp/dockerconfig.json > /tmp/.dockerconfigjson
#   oc set data secret/pull-secret -n openshift-config --from-file=/tmp/.dockerconfigjson

  ## Create bastion host
  cd $GIT_REPO_HOME/aws
  set +e
  ./create-bastion-host.sh
  retcode=$?
  if [[ $retcode -ne 0 ]]; then
    log "Bastion host creation failed in Terraform step"
    exit 22
  fi
  set -e

  # Backup Terraform configuration
  cd $GIT_REPO_HOME
  rm -rf /tmp/mas-multicloud
  mkdir /tmp/mas-multicloud
  cp -r * /tmp/mas-multicloud
  cd /tmp
  zip -r $BACKUP_FILE_NAME mas-multicloud/*
  set +e
  aws s3 cp $BACKUP_FILE_NAME $DEPLOYMENT_CONTEXT_UPLOAD_PATH
  retcode=$?
  if [[ $retcode -ne 0 ]]; then
    log "Failed while uploading deployment context to S3"
    exit 23
  fi
  set -e
  log "OCP cluster Terraform configuration backed up at $DEPLOYMENT_CONTEXT_UPLOAD_PATH in file $CLUSTER_NAME.zip"
else
  log "==== Existing OCP cluster provided, skipping the cluster creation, Bastion host creation and S3 upload of deployment context ===="
fi

log "==== Adding ER key details to OCP default pull-secret ===="
cd /tmp
# Login to OCP cluster
export OCP_SERVER="$(echo https://api.${CLUSTER_NAME}.${BASE_DOMAIN}:6443)"
oc login -u $OCP_USERNAME -p $OCP_PASSWORD --server=$OCP_SERVER --insecure-skip-tls-verify=true
export OCP_TOKEN="$(oc whoami --show-token)"
oc extract secret/pull-secret -n openshift-config --keys=.dockerconfigjson --to=. --confirm
export encodedEntitlementKey=$(echo cp:$SLS_ENTITLEMENT_KEY | tr -d '\n' | base64 -w0)
##export encodedEntitlementKey=$(echo cp:$SLS_ENTITLEMENT_KEY | base64 -w0)
export emailAddress=$(cat .dockerconfigjson | jq -r '.auths["cloud.openshift.com"].email')
jq '.auths |= . + {"cp.icr.io": { "auth" : "$encodedEntitlementKey", "email" : "$emailAddress"}}' .dockerconfigjson > /tmp/dockerconfig.json
envsubst < /tmp/dockerconfig.json > /tmp/.dockerconfigjson
oc set data secret/pull-secret -n openshift-config --from-file=/tmp/.dockerconfigjson


## Configure OCP cluster
log "==== OCP cluster configuration (Cert Manager and SBO) started ===="
cd $GIT_REPO_HOME/../ibm/mas_devops/playbooks
set +e
ansible-playbook ocp/configure-ocp.yml
if [[ $? -ne 0 ]]; then
  # One reason for this failure is catalog sources not having required state information, so recreate the catalog-operator pod
  # https://bugzilla.redhat.com/show_bug.cgi?id=1807128
  echo "Deleting catalog-operator pod"
  podname=$(oc get pods -n openshift-operator-lifecycle-manager | grep catalog-operator | awk {'print $1'})
  oc logs $podname -n openshift-operator-lifecycle-manager
  oc delete pod $podname -n openshift-operator-lifecycle-manager
  sleep 10
  # Retry the step
  ansible-playbook ocp/configure-ocp.yml
  retcode=$?
  if [[ $retcode -ne 0 ]]; then
    log "Failed while configuring OCP cluster"
    exit 24
  fi
fi
set -e
log "==== OCP cluster configuration (Cert Manager and SBO) completed ===="

## Deploy MongoDB
log "==== MongoDB deployment started ===="
ansible-playbook dependencies/install-mongodb-ce.yml
log "==== MongoDB deployment completed ===="

## Copying the entitlement.lic to MAS_CONFIG_DIR
cp $GIT_REPO_HOME/entitlement.lic $MAS_CONFIG_DIR

## Deploy Amqstreams
# log "==== Amq streams deployment started ===="
# ansible-playbook install-amqstream.yml
# log "==== Amq streams deployment completed ===="

# SLS Deployment
if [[ (-z $SLS_ENDPOINT_URL) || (-z $SLS_REGISTRATION_KEY) || (-z $SLS_PUB_CERT_URL) ]]
then
    ## Deploy SLS
    log "==== SLS deployment started ===="
    ansible-playbook dependencies/install-sls.yml
    log "==== SLS deployment completed ===="

else
    log "=== Using Existing SLS Deployment ==="
    ansible-playbook dependencies/cfg-sls.yml
    log "=== Generated SLS Config YAML ==="
fi

#UDS Deployment
if [[ (-z $UDS_API_KEY) || (-z $UDS_ENDPOINT_URL) || (-z $UDS_PUB_CERT_URL) ]]
then
    ## Deploy UDS
    log "==== UDS deployment started ===="
    ansible-playbook dependencies/install-uds.yml
    log "==== UDS deployment completed ===="

else
    log "=== Using Existing BAS Deployment ==="
    ansible-playbook dependencies/cfg-bas.yml
    log "=== Generated BAS Config YAML ==="
fi

# Deploy CP4D
if [[ $DEPLOY_CP4D == "true" ]]; then
  log "==== CP4D deployment started ===="
  ansible-playbook cp4d/install-services-db2.yml
  ansible-playbook cp4d/create-db2-instance.yml
  log "==== CP4D deployment completed ===="
fi

## Create MAS Workspace
log "==== MAS Workspace generation started ===="
ansible-playbook mas/gencfg-workspace.yml
log "==== MAS Workspace generation completed ===="

if [[ $DEPLOY_MANAGE == "true" ]]; then
  log "==== Configure JDBC  started ===="
  ansible-playbook mas/configure-suite-db.yml
  log "==== Configure JDBC completed ===="
fi

## Deploy MAS
log "==== MAS deployment started ===="
## Evalute custom annotations to set with reference from aws-product-codes.config
product_code_metadata="$(curl http://169.254.169.254/latest/meta-data/product-codes)"

if [[ -n "$product_code_metadata" ]];then
  log "Product Code: $product_code_metadata"
  aws_product_codes_config_file="$GIT_REPO_HOME/aws/aws-product-codes.config"
  log "Checking for product type corrosponding to $product_code_metadata from file $aws_product_codes_config_file"
  if grep -E "^$product_code_metadata:" $aws_product_codes_config_file 1>/dev/null 2>&1;then
    product_type="$(grep -E "^$product_code_metadata:" $aws_product_codes_config_file | cut -f 3 -d ":")"
    if [[ $product_type == "byol" ]];then
      export MAS_ANNOTATIONS="mas.ibm.com/hyperscalerProvider=aws,mas.ibm.com/hyperscalerFormat=byol,mas.ibm.com/hyperscalerChannel=ibm"
    elif [[ $product_type == "privatepublic" ]];then
      export MAS_ANNOTATIONS="mas.ibm.com/hyperscalerProvider=aws,mas.ibm.com/hyperscalerFormat=privatepublic,mas.ibm.com/hyperscalerChannel=aws"
    else
      log "Invalid product type : $product_type"
      exit 28
    fi
  else
    log "Product code not found in file $aws_product_codes_config_file"
    exit 28
  fi
else
  log "MAS product code not found, skipping custom annotations suite_install"
fi
ansible-playbook mas/install-suite.yml
log "==== MAS deployment completed ===="

## Deploy Manage
if [[ $DEPLOY_MANAGE == "true" ]]; then
  # Deploy Manage
  log "==== MAS Manage deployment started ===="
  ansible-playbook mas/install-app.yml
  log "==== MAS Manage deployment completed ===="

  # Configure app to use the DB
  log "==== MAS Manage configure app started ===="
  ansible-playbook mas/configure-app.yml
  log "==== MAS Manage configure app completed ===="
fi
