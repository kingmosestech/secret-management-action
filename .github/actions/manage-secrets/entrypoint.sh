#!/bin/bash
set -e pipefail

source "${GITHUB_ACTION_PATH}/../shared/library.sh"

# Azure Key Vault Functions (existing)
az_kvs_list() {
if [[ "${INPUT_KV_PROJECT_TAG}" ]]; then
   az keyvault secret list --vault-name "${INPUT_VAULT}" --query "[?tags.project=='${INPUT_KV_PROJECT_TAG}'].{name:name, id:id}" || exit 1;
else
   az keyvault secret list --vault-name "${INPUT_VAULT}" --query "[].{name:name, id:id}" || exit 1;
fi
}

az_kvs_create_update() {
if [[ "${INPUT_KV_PROJECT_TAG}" ]]; then
   az keyvault secret set --name "${INPUT_SECRET_NAME}" --vault-name "${INPUT_VAULT}" --value "${INPUT_SECRET_VALUE}" --tag "project=${INPUT_KV_PROJECT_TAG}" --query "{attributes:attributes, contentType:contentType, id:id, kid:kid, managed:managed, name:name, tags:tags}" || exit 1;
else
   az keyvault secret set --name "${INPUT_SECRET_NAME}" --vault-name "${INPUT_VAULT}" --value "${INPUT_SECRET_VALUE}" --query "{attributes:attributes, contentType:contentType, id:id, kid:kid, managed:managed, name:name, tags:tags}" || exit 1;
fi
}

az_kvs_delete() {
az keyvault secret delete --name "${INPUT_SECRET_NAME}" --vault-name "${INPUT_VAULT}" --only-show-errors || exit 1;
}

az_kvs_recover() {
az keyvault secret recover --name "${INPUT_SECRET_NAME}" --vault-name "${INPUT_VAULT}" --only-show-errors || exit 1;
}

# AWS Functions

# AWS Parameter Store Functions
aws_ps_list() {
echo "[INFO] Listing AWS Parameter Store parameters."
aws ssm describe-parameters --region "${INPUT_AWS_REGION}" --query "Parameters[].Name" --output json
}

aws_ps_get() {
echo "[INFO] Getting AWS Parameter Store parameter: ${INPUT_SECRET_NAME}"
aws ssm get-parameter --name "${INPUT_SECRET_NAME}" --region "${INPUT_AWS_REGION}" --with-decryption
}

aws_ps_create_update() {
local tags=""
if [[ -n "${INPUT_AWS_TAGS}" && "${INPUT_AWS_TAGS}" != "{}" ]]; then
   # Convert JSON tags to AWS CLI format
   tags="--tags $(echo "${INPUT_AWS_TAGS}" | jq -r 'to_entries | map("Key=\(.key),Value=\(.value)") | join(" ")')"
fi

local kms_param=""
if [[ -n "${INPUT_AWS_KMS_KEY_ID}" ]]; then
   kms_param="--key-id ${INPUT_AWS_KMS_KEY_ID}"
fi

echo "[INFO] Creating/updating AWS Parameter Store parameter: ${INPUT_SECRET_NAME}"
aws ssm put-parameter \
   --name "${INPUT_SECRET_NAME}" \
   --value "${INPUT_SECRET_VALUE}" \
   --type "${INPUT_AWS_PARAMETER_TYPE}" \
   --overwrite \
   --region "${INPUT_AWS_REGION}" \
   ${kms_param} \
   ${tags}

echo "[INFO] Parameter Store parameter created/updated successfully."
}

aws_ps_delete() {
echo "[INFO] Deleting AWS Parameter Store parameter: ${INPUT_SECRET_NAME}"
aws ssm delete-parameter --name "${INPUT_SECRET_NAME}" --region "${INPUT_AWS_REGION}"
echo "[INFO] Parameter Store parameter deleted successfully."
}

# AWS Secrets Manager Functions
aws_sm_list() {
echo "[INFO] Listing AWS Secrets Manager secrets."
aws secretsmanager list-secrets --region "${INPUT_AWS_REGION}" --query "SecretList[].Name" --output json
}

aws_sm_get() {
echo "[INFO] Getting AWS Secrets Manager secret: ${INPUT_SECRET_NAME}"
aws secretsmanager get-secret-value --secret-id "${INPUT_SECRET_NAME}" --region "${INPUT_AWS_REGION}"
}

aws_sm_create_update() {
local tags=""
if [[ -n "${INPUT_AWS_TAGS}" && "${INPUT_AWS_TAGS}" != "{}" ]]; then
   # Convert JSON tags to AWS CLI format
   tags="--tags $(echo "${INPUT_AWS_TAGS}" | jq -r 'to_entries | map("{\"Key\":\"\(.key)\",\"Value\":\"\(.value)\"}") | join(",")')"
fi

local kms_param=""
if [[ -n "${INPUT_AWS_KMS_KEY_ID}" ]]; then
   kms_param="--kms-key-id ${INPUT_AWS_KMS_KEY_ID}"
fi

# Check if secret exists
if aws secretsmanager describe-secret --secret-id "${INPUT_SECRET_NAME}" --region "${INPUT_AWS_REGION}" 2>/dev/null; then
   echo "[INFO] Updating AWS Secrets Manager secret: ${INPUT_SECRET_NAME}"
   aws secretsmanager update-secret \
     --secret-id "${INPUT_SECRET_NAME}" \
     --secret-string "${INPUT_SECRET_VALUE}" \
     --region "${INPUT_AWS_REGION}" \
     ${kms_param}
else
   echo "[INFO] Creating new AWS Secrets Manager secret: ${INPUT_SECRET_NAME}"
   aws secretsmanager create-secret \
     --name "${INPUT_SECRET_NAME}" \
     --secret-string "${INPUT_SECRET_VALUE}" \
     --region "${INPUT_AWS_REGION}" \
     ${kms_param} \
     ${tags}
fi

echo "[INFO] Secrets Manager secret created/updated successfully."
}

aws_sm_delete() {
echo "[INFO] Deleting AWS Secrets Manager secret: ${INPUT_SECRET_NAME}"
aws secretsmanager delete-secret --secret-id "${INPUT_SECRET_NAME}" --region "${INPUT_AWS_REGION}" --force-delete-without-recovery
echo "[INFO] Secrets Manager secret deleted successfully."
}

aws_sm_recover() {
echo "[INFO] Recovering AWS Secrets Manager secret: ${INPUT_SECRET_NAME}"
aws secretsmanager restore-secret --secret-id "${INPUT_SECRET_NAME}" --region "${INPUT_AWS_REGION}"
echo "[INFO] Secrets Manager secret recovered successfully."
}

# AWS KMS Functions
aws_kms_list() {
echo "[INFO] Listing AWS KMS keys."
aws kms list-keys --region "${INPUT_AWS_REGION}" --query "Keys[].KeyId" --output json
}

aws_kms_create() {
local tags=""
if [[ -n "${INPUT_AWS_TAGS}" && "${INPUT_AWS_TAGS}" != "{}" ]]; then
   # Convert JSON tags to AWS CLI format
   tags="--tags $(echo "${INPUT_AWS_TAGS}" | jq -r 'to_entries | map("Key=\(.key),Value=\(.value)") | join(" ")')"
fi

echo "[INFO] Creating AWS KMS key: ${INPUT_SECRET_NAME}"
aws kms create-key \
   --description "${INPUT_SECRET_NAME}" \
   --region "${INPUT_AWS_REGION}" \
   ${tags}

# Create an alias for the key
local key_id=$(aws kms list-keys --region "${INPUT_AWS_REGION}" --query "Keys[?contains(KeyId, '${INPUT_SECRET_NAME}')].KeyId" --output text)
if [[ -n "${key_id}" ]]; then
   aws kms create-alias \
     --alias-name "alias/${INPUT_SECRET_NAME}" \
     --target-key-id "${key_id}" \
     --region "${INPUT_AWS_REGION}"
fi

echo "[INFO] KMS key created successfully."
}

aws_kms_delete() {
echo "[INFO] Scheduling deletion of AWS KMS key: ${INPUT_SECRET_NAME}"
local key_id=""

# Check if input is an alias
if [[ "${INPUT_SECRET_NAME}" == alias/* ]]; then
   key_id=$(aws kms list-aliases --region "${INPUT_AWS_REGION}" --query "Aliases[?AliasName=='${INPUT_SECRET_NAME}'].TargetKeyId" --output text)
else
   # Try as direct key ID
   key_id="${INPUT_SECRET_NAME}"
fi

if [[ -n "${key_id}" ]]; then
   # Schedule key deletion (minimum 7 days required by AWS)
   aws kms schedule-key-deletion \
     --key-id "${key_id}" \
     --pending-window-in-days 7 \
     --region "${INPUT_AWS_REGION}"
   echo "[INFO] KMS key scheduled for deletion successfully."
else
   echo "[ERROR] KMS key not found: ${INPUT_SECRET_NAME}"
   exit 1
fi
}

# AWS ACM (Certificate Manager) Functions
aws_acm_list() {
echo "[INFO] Listing AWS ACM certificates."
aws acm list-certificates --region "${INPUT_AWS_REGION}" --query "CertificateSummaryList[].{DomainName:DomainName,CertificateArn:CertificateArn}" --output json
}



aws_acm_create() {
# For certificate creation, we're using the certificate value as the certificate request
echo "[INFO] Requesting AWS ACM certificate for: ${INPUT_SECRET_NAME}"

# Check if INPUT_SECRET_VALUE is a file path or direct content
if [[ -f "${INPUT_SECRET_VALUE}" ]]; then
   local cert_content=$(cat "${INPUT_SECRET_VALUE}")
else
   local cert_content="${INPUT_SECRET_VALUE}"
fi

local tags=""
if [[ -n "${INPUT_AWS_TAGS}" && "${INPUT_AWS_TAGS}" != "{}" ]]; then
   # Convert JSON tags to AWS CLI format
   tags="--tags $(echo "${INPUT_AWS_TAGS}" | jq -r 'to_entries | map("Key=\(.key),Value=\(.value)") | join(" ")')"
fi

# Create certificate (assumes PEM format in INPUT_SECRET_VALUE)
aws acm import-certificate \
   --certificate-arn "${INPUT_SECRET_NAME}" \
   --certificate "${cert_content}" \
   --region "${INPUT_AWS_REGION}" \
   ${tags}

echo "[INFO] ACM certificate imported successfully."
}

aws_acm_delete() {
echo "[INFO] Deleting AWS ACM certificate: ${INPUT_SECRET_NAME}"
aws acm delete-certificate --certificate-arn "${INPUT_SECRET_NAME}" --region "${INPUT_AWS_REGION}"
echo "[INFO] ACM certificate deleted successfully."
}

# Main function to check inputs and execute commands
for INPUT in INPUT_VAULT INPUT_ACTION; do check_inputs "${INPUT}"; done

# Configure AWS CLI
if [[ -n "${INPUT_AWS_SERVICE}" ]]; then
echo "[DEBUG] Configuring AWS CLI"
export AWS_DEFAULT_REGION="${INPUT_AWS_REGION}"
fi

# Process commands
case ${INPUT_ACTION} in
list)
   echo "[INFO] Listing secrets created by GitHub action."

   if [[ -n "${INPUT_AWS_SERVICE}" ]]; then
     echo "[INFO] Service: ${INPUT_AWS_SERVICE}"

     case ${INPUT_AWS_SERVICE} in
       parameter-store)
         aws_ps_list
         ;;
       secrets-manager)
         aws_sm_list
         ;;
       kms)
         aws_kms_list
         ;;
       acm)
         aws_acm_list
         ;;
       *)
         echo "[ERROR] Unknown AWS service: ${INPUT_AWS_SERVICE}. Available services: parameter-store, secrets-manager, kms, acm."
         exit 1
         ;;
     esac
   else
     echo "[INFO] Key Vault: ${INPUT_VAULT}."
     echo "[INFO] List of secret names:"
     az_kvs_list
   fi
   ;;

create)
   for INPUT in INPUT_SECRET_NAME INPUT_SECRET_VALUE; do check_inputs "${INPUT}"; done

   if [[ -n "${INPUT_AWS_SERVICE}" ]]; then
     echo "[INFO] Creating a new secret in ${INPUT_AWS_SERVICE}."
     echo "[INFO] Service: ${INPUT_AWS_SERVICE}"

     case ${INPUT_AWS_SERVICE} in
       parameter-store)
         aws_ps_create_update
         ;;
       secrets-manager)
         aws_sm_create_update
         ;;
       kms)
         aws_kms_create
         ;;
       acm)
         aws_acm_create
         ;;
       *)
         echo "[ERROR] Unknown AWS service: ${INPUT_AWS_SERVICE}. Available services: parameter-store, secrets-manager, kms, acm."
         exit 1
         ;;
     esac
   else
     echo "[INFO] Creating a new Key Vault secret."
     echo "[INFO] Key Vault: ${INPUT_VAULT}."
     echo "[INFO] Secret name: ${INPUT_SECRET_NAME}."
     az_kvs_create_update
     echo "[INFO] Created."
     echo "[INFO] Updated list of secret names:"
     az_kvs_list
   fi
   ;;

update)
   for INPUT in INPUT_SECRET_NAME INPUT_SECRET_VALUE; do check_inputs "${INPUT}"; done

   if [[ -n "${INPUT_AWS_SERVICE}" ]]; then
     echo "[INFO] Updating a secret in ${INPUT_AWS_SERVICE}."
     echo "[INFO] Service: ${INPUT_AWS_SERVICE}"

     case ${INPUT_AWS_SERVICE} in
       parameter-store)
         aws_ps_create_update
         ;;
       secrets-manager)
         aws_sm_create_update
         ;;
       kms)
         echo "[ERROR] Update operation not supported for KMS."
         exit 1
         ;;
       acm)
         aws_acm_create  # For ACM, create and update are the same operation
         ;;
       *)
         echo "[ERROR] Unknown AWS service: ${INPUT_AWS_SERVICE}. Available services: parameter-store, secrets-manager, kms, acm."
         exit 1
         ;;
     esac
   else
     echo "[INFO] Updating Key Vault secret."
     echo "[INFO] Key Vault: ${INPUT_VAULT}."
     echo "[INFO] Secret name: ${INPUT_SECRET_NAME}."
     az_kvs_create_update
     echo "[INFO] Updated."
     echo "[INFO] Updated list of secret names:"
     az_kvs_list
   fi
   ;;

delete)
   for INPUT in INPUT_SECRET_NAME; do check_inputs "${INPUT}"; done

   if [[ -n "${INPUT_AWS_SERVICE}" ]]; then
     echo "[INFO] Deleting a secret from ${INPUT_AWS_SERVICE}."
     echo "[INFO] Service: ${INPUT_AWS_SERVICE}"

     case ${INPUT_AWS_SERVICE} in
       parameter-store)
         aws_ps_delete
         ;;
       secrets-manager)
         aws_sm_delete
         ;;
       kms)
         aws_kms_delete
         ;;
       acm)
         aws_acm_delete
         ;;
       *)
         echo "[ERROR] Unknown AWS service: ${INPUT_AWS_SERVICE}. Available services: parameter-store, secrets-manager, kms, acm."
         exit 1
         ;;
     esac
   else
     echo "[INFO] Deleting a secret from Key Vault."
     echo "[INFO] Key Vault: ${INPUT_VAULT}."
     echo "[INFO] Secret name: ${INPUT_SECRET_NAME}."
     az_kvs_delete
     echo "[INFO] Deleted."
     echo "[INFO] Updated list of secret names:"
     az_kvs_list
   fi
   ;;

recover)
   for INPUT in INPUT_SECRET_NAME; do check_inputs "${INPUT}"; done

   if [[ -n "${INPUT_AWS_SERVICE}" ]]; then
     echo "[INFO] Recovering a secret from ${INPUT_AWS_SERVICE}."
     echo "[INFO] Service: ${INPUT_AWS_SERVICE}"

     case ${INPUT_AWS_SERVICE} in
       parameter-store)
         echo "[ERROR] Recover operation not supported for Parameter Store."
         exit 1
         ;;
       secrets-manager)
         aws_sm_recover
         ;;
       kms)
         echo "[ERROR] Recover operation not supported for KMS."
         exit 1
         ;;
       acm)
         echo "[ERROR] Recover operation not supported for ACM."
         exit 1
         ;;
       *)
         echo "[ERROR] Unknown AWS service: ${INPUT_AWS_SERVICE}. Available services: parameter-store, secrets-manager, kms, acm."
         exit 1
         ;;
     esac
   else
     echo "[INFO] Recovering a secret from Key Vault."
     echo "[INFO] Key Vault: ${INPUT_VAULT}."
     echo "[INFO] Secret name: ${INPUT_SECRET_NAME}."
     az_kvs_recover
     echo "[INFO] Recovered."
     echo "[INFO] Updated list of secret names:"
     az_kvs_list
   fi
   ;;

*)
   echo -n "[ERROR] Unknown action: ${INPUT_ACTION}. Available actions: list, create, update, delete, recover"
   exit 1
   ;;
esac

echo "[DEBUG] az logout"
az logout
