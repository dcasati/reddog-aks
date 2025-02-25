#!/usr/bin/env bash

set -eou pipefail

mkdir -p outputs
export RG_NAME=$1
export LOCATION=$2
export SUFFIX=$3
export USERNAME=$4
export MONITORING=$5
export STATE_STORE=$6
export USE_VIRTUAL_CUSTOMER=$7

# set additional params
export UNIQUE_SERVICE_NAME=reddog$RANDOM$USERNAME$SUFFIX

start_time=$(date +%s)

# Check for Azure login
echo 'Checking to ensure logged into Azure CLI'
AZURE_LOGIN=0 
# run a command against Azure to check if we are logged in already.
az group list -o table
# save the return code from above. Anything different than 0 means we need to login
AZURE_LOGIN=$?

if [[ ${AZURE_LOGIN} -ne 0 ]]; then
# not logged in. Initiate login process
    az login --use-device-code
    export AZURE_LOGIN
fi

# get current user
# export CURRENT_USER_ID=$(az ad signed-in-user show -o json | jq -r .objectId)
export CURRENT_USER_ID=$(az ad signed-in-user show -o json | jq -r .id)

# show all params
echo '****************************************************'
echo 'Starting Red Dog on AKS deployment'
echo ''
echo 'Parameters:'
echo 'SUBSCRIPTION: ' $SUBSCRIPTION_ID
echo 'TENANT: ' $TENANT_ID
echo 'LOCATION: ' $LOCATION
echo 'USER/PREFIX: ' $USERNAME
echo 'RG_NAME: ' $RG_NAME
echo 'UNIQUE NAME: ' $UNIQUE_SERVICE_NAME
echo 'LOGFILE_NAME: ' $LOGFILE_NAME
echo 'MONITORING: ' $MONITORING
echo 'STATE_STORE: ' $STATE_STORE
echo 'VIRTUAL CUSTOMER?: ' $USE_VIRTUAL_CUSTOMER
echo 'CURRENT_USER_ID: ' $CURRENT_USER_ID
echo '****************************************************'
echo ''

# update az CLI to install extensions automatically
az config set extension.use_dynamic_install=yes_without_prompt

# setup az CLI features
echo 'Configuring extensions and features for az CLI'
az feature register --namespace Microsoft.ContainerService --name AKS-ExtensionManager
az provider register --namespace Microsoft.Kubernetes --consent-to-permissions
az provider register --namespace Microsoft.ContainerService --consent-to-permissions
az provider register --namespace Microsoft.KubernetesConfiguration --consent-to-permissions
az extension add -n k8s-configuration
az extension add -n k8s-extension
az extension update -n k8s-configuration
az extension update -n k8s-extension

# create RG
echo "Creating Azure Resource Group"
az group create --name $RG_NAME --location $LOCATION

# create SSH keys
# echo 'Generating SSH keys (will overwrite existing)'
# ssh-keygen -f ~/.ssh/aks-reddog -N '' <<< y  

# export SSH_PUB_KEY="$(cat ~/.ssh/aks-reddog.pub)"

# Bicep deployment
echo ''
echo '****************************************************'
echo 'Starting Bicep deployment of resources'
echo '****************************************************'

az deployment group create \
    --name aks-reddog \
    --mode Incremental \
    --only-show-errors \
    --resource-group $RG_NAME \
    --template-file ./deploy/bicep/main.bicep \
    --parameters uniqueServiceName=$UNIQUE_SERVICE_NAME \
    --parameters currentUserId="$CURRENT_USER_ID" \
    --parameters monitoringTool="$MONITORING" \
    --parameters stateStore="$STATE_STORE"
    # --parameters adminUsername="azureuser" \
    # --parameters adminPublicKey="$SSH_PUB_KEY" \

echo ''
echo '****************************************************'
echo 'Base infra deployed. Starting config/app deployment'
echo '****************************************************'    

# Save deployment outputs
az deployment group show -g $RG_NAME -n aks-reddog -o json --query properties.outputs > "./outputs/$RG_NAME-bicep-outputs.json"

# Connect to AKS and create namespace, redis
echo ''
echo '****************************************************'
echo 'AKS. Create namespace, secrets, Helm charts'
echo '****************************************************'
AKS_NAME=$(cat ./outputs/$RG_NAME-bicep-outputs.json | jq -r .aksName.value)
echo 'AKS Cluster Name: ' $AKS_NAME
az aks get-credentials -n $AKS_NAME -g $RG_NAME --overwrite-existing

echo ''
echo 'Create namespaces'
kubectl create ns reddog
kubectl create ns dapr-system
kubectl create ns traefik

echo ''
echo 'Helm repo updates'
helm repo add dapr https://dapr.github.io/helm-charts
helm repo add azure-marketplace https://marketplace.azurecr.io/helm/v1/repo
helm repo add traefik https://helm.traefik.io/traefik
helm repo update

echo ''
echo 'Deploying Dapr Helm chart'
helm install dapr dapr/dapr --namespace dapr-system

echo ''
echo 'Deploying Traefik Helm chart' # 
helm install traefik traefik/traefik \
    --namespace traefik \
    --set service.annotations."service\.beta\.kubernetes\.io/azure-dns-label-name"=reddog$SUFFIX

if [ "$STATE_STORE" = "redislocal" ]
then
    echo ''
    echo 'Deploying Redis Helm chart in AKS as configured in config.json' # https://bitnami.com/stack/redis/helm
    export REDIS_PASSWD='w@lkingth3d0g'
    kubectl create ns redis
    helm install redis-release azure-marketplace/redis --namespace redis --set auth.password=$REDIS_PASSWD --set replica.replicaCount=2
    kubectl create secret generic redis-password --from-literal=redis-password=$REDIS_PASSWD -n reddog 
elif [ "$STATE_STORE" = "cosmos" ]
then
    echo ''
    echo 'CosmosDB deployed via Bicep as configured in config.json'
else
    echo 'ERROR: State store value in config.json is not valid. Exiting'
    exit 0
fi

# Zipkin
echo ''
echo 'Installing Zipkin for Dapr'
kubectl create ns zipkin
kubectl create deployment zipkin -n zipkin --image openzipkin/zipkin
kubectl expose deployment zipkin -n zipkin --type LoadBalancer --port 9411   

if [ "$MONITORING" = "prometheus" ]
then
    echo ''
    echo 'Installing Prometheus/Grafana as configured in config.json'
    echo 'Note: use admin to login'
    git clone https://github.com/appdevgbb/kube-prometheus.git
    cd kube-prometheus/manifests
    kubectl apply --server-side -f ./setup
    kubectl apply -f ./
    cd ../..
    rm -rf kube-prometheus
elif [ "$MONITORING" = "loganalytics" ]
then
    echo ''
    echo 'Log Analytics used for monitoring as configured in config.json'
else
    echo 'No correct monitoring tool was set in config.json. Skipping'
fi

# Initialize KV  
echo ''
echo 'Create SP for KV and setup permissions'
export KV_NAME=$(cat ./outputs/$RG_NAME-bicep-outputs.json | jq -r .keyvaultName.value)
echo 'Key Vault: ' $KV_NAME


az ad sp create-for-rbac \
        --name "http://sp-$RG_NAME.microsoft.com" \
        --only-show-errors \
        --create-cert \
        --cert $RG_NAME-cert \
        --keyvault $KV_NAME \
        --years 1
  

## Get SP APP ID
echo 'Getting SP_APPID ...'
SP_INFO=$(az ad sp list -o json --display-name "http://sp-$RG_NAME.microsoft.com")
SP_APPID=$(echo $SP_INFO | jq -r .[].appId)  
echo 'AKV SP_APPID: ' $SP_APPID

## Get SP Object ID
echo 'Getting SP_OBJECTID ...'
# SP_OBJECTID=$(echo $SP_INFO | jq -r .[].objectId)
SP_OBJECTID=$(echo $SP_INFO | jq -r .[].id)
echo 'AKV SP_OBJECTID: ' $SP_OBJECTID

# Assign SP to KV with GET permissions
az keyvault set-policy \
    --name $KV_NAME \
    --object-id $SP_OBJECTID \
    --secret-permissions get  \
    --certificate-permissions get

# Assign permissions to the current user
UPN=$(az ad signed-in-user show  -o json | jq -r '.userPrincipalName')
echo 'User UPN: ' $UPN

az keyvault set-policy \
    --name $KV_NAME \
    --secret-permissions get list set \
    --certificate-permissions create get list \
    --upn $UPN  

# Download .pfx for Dapr secret (later)
az keyvault secret download \
    --vault-name $KV_NAME \
    --name $RG_NAME-cert \
    --encoding base64 \
    --file ./kv-$RG_NAME-cert.pfx

# Create K8s secret for above pfx (used by Dapr)
kubectl create secret generic reddog.secretstore \
    --namespace reddog \
    --from-file=secretstore-cert=./kv-$RG_NAME-cert.pfx \
    --from-literal=vaultName=$KV_NAME \
    --from-literal=spnClientId=$SP_APPID \
    --from-literal=spnTenantId=$TENANT_ID

# Write keys to KV
echo ''
echo '****************************************************'
echo 'Writing all secrets to KeyVault'
echo '****************************************************'

    # storage account
    export STORAGE_NAME=$(cat ./outputs/$RG_NAME-bicep-outputs.json | jq -r .storageAccountName.value)
    echo 'Storage Account: ' $STORAGE_NAME
    export STORAGE_KEY=$(cat ./outputs/$RG_NAME-bicep-outputs.json | jq -r .storageAccountKey.value)
    
    az keyvault secret set --vault-name $KV_NAME --name blob-storage-account --value $STORAGE_NAME
    echo 'KeyVault secret created: blob-storage-account'

    az keyvault secret set --vault-name $KV_NAME --name blob-storage-key --value $STORAGE_KEY
    echo 'KeyVault secret created: blob-storage-key'

    # service bus
    export SB_NAME=$(jq -r .serviceBusName.value ./outputs/$RG_NAME-bicep-outputs.json)
    export SB_CONNECT_STRING=$(jq -r .serviceBusConnectString.value ./outputs/$RG_NAME-bicep-outputs.json)

    az keyvault secret set --vault-name $KV_NAME --name sb-root-connectionstring --value $SB_CONNECT_STRING
    echo 'KeyVault secret created: sb-root-connectionstring'

    # Azure SQL
    export SQL_SERVER=$(jq -r .sqlServerName.value ./outputs/$RG_NAME-bicep-outputs.json)
    export SQL_ADMIN_USER_NAME=$(jq -r .sqlAdmin.value ./outputs/$RG_NAME-bicep-outputs.json)
    export SQL_ADMIN_PASSWD=$(jq -r .sqlPassword.value ./outputs/$RG_NAME-bicep-outputs.json)
    
    export REDDOG_SQL_CONNECTION_STRING="Server=tcp:${SQL_SERVER}.database.windows.net,1433;Database=reddog;User ID=${SQL_ADMIN_USER_NAME};Password=${SQL_ADMIN_PASSWD};Encrypt=true;Connection Timeout=30;"
    
    az keyvault secret set --vault-name $KV_NAME --name reddog-sql --value "${REDDOG_SQL_CONNECTION_STRING}"
    echo 'KeyVault secret created: reddog-sql'

    if [ "$STATE_STORE" = "redislocal" ]
    then
        echo ''
        export REDIS_HOST='redis-release-master.redis.svc.cluster.local'
        export REDIS_PORT='6379'
        export REDIS_FQDN="${REDIS_HOST}:${REDIS_PORT}"
        export REDIS_PASSWORD=$(kubectl get secret --namespace redis redis-release -o jsonpath="{.data.redis-password}" | base64 --decode)

        az keyvault secret set --vault-name $KV_NAME --name redis-server --value $REDIS_FQDN
        echo "KeyVault secret created: redis-server"
        az keyvault secret set --vault-name $KV_NAME --name redis-password --value $REDIS_PASSWD
        echo 'KeyVault secret created: redis-password'        
    elif [ "$STATE_STORE" = "cosmos" ]
    then
        echo ''
        export COSMOS_URI=$(jq -r .cosmosUri.value ./outputs/$RG_NAME-bicep-outputs.json)
        echo "Cosmos URI: " $COSMOS_URI
        export COSMOS_ACCOUNT=$(jq -r .cosmosAccountName.value ./outputs/$RG_NAME-bicep-outputs.json)
        echo "Cosmos Account: " $COSMOS_ACCOUNT
        export COSMOS_PRIMARY_RW_KEY=$(az cosmosdb keys list -n $COSMOS_ACCOUNT  -g $RG_NAME -o json | jq -r '.primaryMasterKey')
        
        az keyvault secret set --vault-name $KV_NAME --name cosmos-uri --value $COSMOS_URI
        echo "KeyVault secret created: cosmos-uri"    

        az keyvault secret set --vault-name $KV_NAME --name cosmos-primary-rw-key --value $COSMOS_PRIMARY_RW_KEY
        echo "KeyVault secret created: cosmos-primary-rw-key"          
    else
        echo 'ERROR: State store value in config.json is not valid'
    fi    

# Azure SQL server must set firewall to allow azure services
export AZURE_SQL_SERVER=$(jq -r .sqlServerName.value ./outputs/$RG_NAME-bicep-outputs.json)
echo ''
echo 'Allow Azure Services to access Azure SQL (Firewall)'
az sql server firewall-rule create \
    --resource-group $RG_NAME \
    --server $AZURE_SQL_SERVER \
    --name AllowAzureServices \
    --start-ip-address 0.0.0.0 \
    --end-ip-address 0.0.0.0

# Configure AKS Flux v2 GitOps deployments
echo ''
echo '****************************************************'
echo 'Configure AKS Flux v2 GitOps deployments'
echo '****************************************************'
export AKS_NAME=$(jq -r .aksName.value ./outputs/$RG_NAME-bicep-outputs.json)

# Deploy Flux config for base dapr components
echo ''
echo 'Deploy Flux config for base dapr components'
az k8s-configuration flux create \
    --resource-group $RG_NAME \
    --cluster-name $AKS_NAME \
    --cluster-type managedClusters \
    --scope cluster \
    --name reddog-components-base \
    --namespace flux-system \
    --url https://github.com/Azure/reddog-aks.git \
    --branch main \
    --kustomization name=kustomize path=./manifests/base/components-main prune=true 

if [ "$STATE_STORE" = "redislocal" ]
then
    # Deploy Flux config Dapr components for Redis state store
    echo ''
    echo 'Deploy Flux config Dapr components for Redis state store'
    az k8s-configuration flux create \
        --resource-group $RG_NAME \
        --cluster-name $AKS_NAME \
        --cluster-type managedClusters \
        --scope cluster \
        --name reddog-components-redis \
        --namespace flux-system \
        --url https://github.com/Azure/reddog-aks.git \
        --branch main \
        --kustomization name=kustomize path=./manifests/base/components-redis prune=true 
elif [ "$STATE_STORE" = "cosmos" ]
then
    # Deploy Flux config Dapr components for Cosmos state store
    echo ''
    echo 'Deploy Flux config Dapr components for Cosmos state store'
    az k8s-configuration flux create \
        --resource-group $RG_NAME \
        --cluster-name $AKS_NAME \
        --cluster-type managedClusters \
        --scope cluster \
        --name reddog-components-cosmos \
        --namespace flux-system \
        --url https://github.com/Azure/reddog-aks.git \
        --branch main \
        --kustomization name=kustomize path=./manifests/base/components-cosmos prune=true 
else
    echo 'ERROR: State store value in config.json is not valid'
fi 

# Deploy Flux config for reddog base services
echo ''
echo 'Deploy Flux config for reddog base services'
az k8s-configuration flux create \
    --resource-group $RG_NAME \
    --cluster-name $AKS_NAME \
    --cluster-type managedClusters \
    --scope cluster \
    --name reddog-deployments \
    --namespace flux-system \
    --url https://github.com/Azure/reddog-aks.git \
    --branch main \
    --kustomization name=kustomize path=./manifests/base/deployments prune=true 

# Deploy Flux config for virtual customer (optional)
if [ "$USE_VIRTUAL_CUSTOMER" = "true" ]
then
    echo ''
    echo 'Deploy Flux config for virtual customer as specified in config.json'
    az k8s-configuration flux create \
        --resource-group $RG_NAME \
        --cluster-name $AKS_NAME \
        --cluster-type managedClusters \
        --scope cluster \
        --name reddog-virt-customer \
        --namespace flux-system \
        --url https://github.com/Azure/reddog-aks.git \
        --branch main \
        --kustomization name=kustomize path=./manifests/base/deployments-virt-customer prune=true 
else
    echo 'Virtual Customer was not deployed as specified in config.json'
fi 

sleep 60

# get URL's for application
export UI_URL="http://"$(kubectl get svc --namespace reddog ui -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
export ORDER_URL="http://"$(kubectl get svc --namespace reddog order-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}')":8081"
export MAKE_LINE_URL="http://"$(kubectl get svc --namespace reddog make-line-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}')":8082"
export ACCOUNTING_URL="http://"$(kubectl get svc --namespace reddog accounting-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}')":8083"
export ZIPKIN_URL="http://"$(kubectl get svc --namespace zipkin zipkin -o jsonpath='{.status.loadBalancer.ingress[0].ip}')":9411"
if [ "$MONITORING" = "prometheus" ]
then
    export GRAFANA_URL="http://"$(kubectl get svc --namespace monitoring grafana -o jsonpath='{.status.loadBalancer.ingress[0].ip}')":3000"
fi

echo ''
echo '*********************************************************************'
echo 'Application URLs'
echo ''
echo 'UI: ' $UI_URL
echo 'UI ingress path: ' 'http://reddog'$SUFFIX'.eastus.cloudapp.azure.com'
if [ "$MONITORING" = "prometheus" ]
then
    echo 'Grafana dashboard (use admin): ' $GRAFANA_URL
fi
echo 'Zipkin: ' $ZIPKIN_URL
echo ''
echo 'Order test path: ' $ORDER_URL'/product'
echo 'Order test path (POST): ' $ORDER_URL'/order'
echo 'Makeline test path: ' $MAKE_LINE_URL'/orders/denver'
echo 'Accounting test path: ' $ACCOUNTING_URL'/OrderMetrics?StoreId=denver'
echo ''
echo 'Order Swagger: ' $ORDER_URL'/swagger/v1/swagger.json'
echo 'Makeline Swagger: ' $MAKE_LINE_URL'/swagger/v1/swagger.json'
echo 'Accounting Swagger: ' $ACCOUNTING_URL'/swagger/v1/swagger.json'
echo '*********************************************************************'

# elapsed time with second resolution
echo ''
end_time=$(date +%s)
elapsed=$(( end_time - start_time ))
printf 'Script elapsed time: %dh:%dm:%ds\n' $((elapsed/3600)) $((elapsed%3600/60)) $((elapsed%60))