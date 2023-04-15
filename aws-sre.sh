#!/bin/bash
#####
echo "starting the build"
sudo yum -y install openssl
curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 > get_helm.sh
chmod 700 get_helm.sh
./get_helm.sh
rm -f get_helm.sh
curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin
sudo yum install -y yum-utils shadow-utils
sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
sudo yum -y install terraform
#####
cd tf
aws sts get-caller-identity

terraform init
terraform plan
aws sts get-caller-identity

terraform apply --auto-approve
#####
unset CLUSTER_NAME
unset AMP_WORKSPACE_ALIAS
unset WORKSPACE_ID
unset AMP_ENDPOINT_RW

export CLUSTER_NAME="demo"
export AMP_WORKSPACE_ALIAS="demo"
export WORKSPACE_ID=$(aws amp list-workspaces --alias "${AMP_WORKSPACE_ALIAS}" --region="us-east-1" --query 'workspaces[0].[workspaceId]' --output text)
export AMP_ENDPOINT_RW=https://aps-workspaces.us-east-1.amazonaws.com/workspaces/$WORKSPACE_ID/api/v1/remote_write

echo $CLUSTER_NAME
echo $AMP_WORKSPACE_ALIAS
echo $WORKSPACE_ID
echo $AMP_ENDPOINT_RW

aws eks update-kubeconfig --region ${AWS_REGION} --name ${CLUSTER_NAME}
#####
cd ../
kubectl apply -f eks-console-full-access.yaml
eksctl get iamidentitymapping --cluster demo --region=us-east-1
# eksctl create iamidentitymapping --cluster demo --region=us-east-1 --arn arn:aws:iam::348232623726:user/eks-mgr --group eks-console-dashboard-full-access-group --no-duplicate-arns
eksctl create iamidentitymapping --cluster demo --region=us-east-1 --arn arn:aws:iam::348232623726:user/eks-admin --group eks-console-dashboard-full-access-group --no-duplicate-arns
eksctl create iamidentitymapping --cluster demo --region=us-east-1 --arn arn:aws:iam::348232623726:user/* --group eks-console-dashboard-full-access-group --no-duplicate-arns
kubectl create -f prometheus-operator-crd
kubectl apply -f prometheus-operator
sed -i "s?{{amp_url}}?$AMP_ENDPOINT_RW?g" ./prometheus-agent/4-prometheus.yaml
kubectl apply -f prometheus-agent
kubectl apply -f node-exporter
kubectl apply -f cadvisor
kubectl apply -f kube-state-metrics
#####
eksctl create iamserviceaccount --name cloudwatch-agent --namespace amazon-cloudwatch --cluster demo --role-name "eks-demo-iamserviceaccount-CWAgent-Role" --attach-policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy --approve --override-existing-serviceaccounts

kubectl apply -f ./cw-ci/cloudwatch-namespace.yaml
kubectl apply -f ./cw-ci/cwagent-serviceaccount.yaml
kubectl apply -f ./cw-ci/cwagent-configmap.yaml
kubectl apply -f ./cw-ci/cwagent-daemonset.yaml

ClusterName=${CLUSTER_NAME}
RegionName=${AWS_REGION}
FluentBitHttpPort='2020'
FluentBitReadFromHead='Off'
[[ ${FluentBitReadFromHead} = 'On' ]] && FluentBitReadFromTail='Off'|| FluentBitReadFromTail='On'
[[ -z ${FluentBitHttpPort} ]] && FluentBitHttpServer='Off' || FluentBitHttpServer='On'

kubectl create configmap fluent-bit-cluster-info --from-literal=cluster.name=${ClusterName} --from-literal=http.server=${FluentBitHttpServer} --from-literal=http.port=${FluentBitHttpPort} --from-literal=read.head=${FluentBitReadFromHead} --from-literal=read.tail=${FluentBitReadFromTail} --from-literal=logs.region=${RegionName} -n amazon-cloudwatch

kubectl apply -f ./cw-ci/fluent-bit.yaml

DASHBOARD_NAME=my-demo-dashboard
REGION_NAME=${AWS_REGION}
CLUSTER_NAME=${CLUSTER_NAME}

cat ./cw-ci/cw_dashboard_fluent_bit.json | sed "s/{{YOUR_AWS_REGION}}/${REGION_NAME}/g" | sed "s/{{YOUR_CLUSTER_NAME}}/${CLUSTER_NAME}/g" | xargs -0 aws cloudwatch put-dashboard --dashboard-name ${DASHBOARD_NAME} --dashboard-body

eksctl create iamserviceaccount --name cwagent-prometheus --namespace amazon-cloudwatch --cluster demo --attach-policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy --approve --override-existing-serviceaccounts

kubectl apply -f ./cw-ci/prometheus-eks.yaml
####
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
kubectl create namespace nginx-ingress-sample
helm install my-nginx ingress-nginx/ingress-nginx --namespace nginx-ingress-sample --set controller.metrics.enabled=true --set-string controller.metrics.service.annotations."prometheus\.io/port"="10254" --set-string controller.metrics.service.annotations."prometheus\.io/scrape"="true"
sleep 30
EXTERNAL_IP=`kubectl get service -n nginx-ingress-sample | grep 'LoadBalancer' |  awk '{ print $4 }'`
SAMPLE_TRAFFIC_NAMESPACE=nginx-sample-traffic
cat ./nginx-app/nginx-traffic-sample.yaml | sed "s/{{external_ip}}/$EXTERNAL_IP/g" | sed "s/{{namespace}}/$SAMPLE_TRAFFIC_NAMESPACE/g" | kubectl apply --validate="false" -f -
