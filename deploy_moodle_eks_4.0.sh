#!/bin/bash
# ==============================================
# 直接部署Moodle完整環境腳本
# 功能：
#   1. 創建EKS集群
#   2. 部署RDS PostgreSQL
#   3. 創建EFS並配置自動掛載
#   4. 創建S3存儲桶
#   5. 部署Moodle應用
#   6. 配置ALB Ingress
#   7. 設置Auto Scaling
#   8. 配置Route 53域名解析
# ==============================================

# ------------ 配置變量 ------------
REGION="us-east-1"
EKS_CLUSTER_NAME="moodle-direct"
NODE_TYPE="t3.medium"
MIN_NODES=1
MAX_NODES=2
MOODLE_IMAGE="bitnami/moodle:5.0-debian-12"

# RDS配置
RDS_INSTANCE_CLASS="db.t3.medium"
RDS_STORAGE_SIZE=20
RDS_ENGINE="postgres"

# Auto Scaling配置
MIN_PODS=1
MAX_PODS=3
TARGET_CPU=50

# S3配置
S3_BUCKET_NAME="moodle-data-$(date +%s | md5sum | head -c 8)"

# Route 53配置
DOMAIN_NAME="fipcuring.com"
RECORD_NAME="www.${DOMAIN_NAME}"

# ------------ 創建EKS集群 ------------
create_eks_cluster() {
    echo "=== 創建EKS集群 ==="
    
    eksctl create cluster \
        --name $EKS_CLUSTER_NAME \
        --region $REGION \
        --version "1.28" \
        --nodegroup-name workers \
        --node-type $NODE_TYPE \
        --nodes $MIN_NODES \
        --nodes-max $MAX_NODES \
        --managed \
        --ssh-access \
        --asg-access \
        --full-ecr-access \
        --alb-ingress-access
    
    aws eks update-kubeconfig --name $EKS_CLUSTER_NAME --region $REGION
}

# ------------ 部署RDS PostgreSQL ------------
deploy_rds() {
    echo "=== 部署RDS PostgreSQL ==="
    
    VPC_ID=$(aws eks describe-cluster --name $EKS_CLUSTER_NAME --region $REGION \
        --query 'cluster.resourcesVpcConfig.vpcId' --output text)
    SG_ID=$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=*ClusterSharedNodeSecurityGroup*" \
        --region $REGION --query 'SecurityGroups[0].GroupId' --output text)
    
    aws rds create-db-instance \
        --db-instance-identifier moodle-db \
        --db-instance-class $RDS_INSTANCE_CLASS \
        --engine $RDS_ENGINE \
        --allocated-storage $RDS_STORAGE_SIZE \
        --master-username moodleadmin \
        --master-user-password $(date +%s | sha256sum | base64 | head -c 32) \
        --vpc-security-group-ids $SG_ID \
        --backup-retention-period 1 \
        --no-multi-az \
        --no-publicly-accessible \
        --region $REGION
    
    echo -n "等待RDS就緒..."
    aws rds wait db-instance-available --db-instance-identifier moodle-db --region $REGION
    echo "✓"
}

# ------------ 創建EFS存儲 ------------
create_efs() {
    echo "=== 創建EFS存儲 ==="
    
    EFS_ID=$(aws efs create-file-system \
        --creation-token "moodle-efs" \
        --tags "Key=Name,Value=MoodleEFS" \
        --region $REGION \
        --query 'FileSystemId' --output text)
    
    VPC_ID=$(aws eks describe-cluster --name $EKS_CLUSTER_NAME --region $REGION \
        --query 'cluster.resourcesVpcConfig.vpcId' --output text)
    SUBNET_IDS=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:aws:cloudformation:logical-id,Values=SubnetPrivate*" \
        --region $REGION --query 'Subnets[*].SubnetId' --output text)
    NODE_SG=$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=*ClusterSharedNodeSecurityGroup*" \
        --region $REGION --query 'SecurityGroups[0].GroupId' --output text)
    
    for SUBNET_ID in $SUBNET_IDS; do
        aws efs create-mount-target \
            --file-system-id $EFS_ID \
            --subnet-id $SUBNET_ID \
            --security-groups $NODE_SG \
            --region $REGION
    done
    
    kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-sc
provisioner: efs.csi.aws.com
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: efs-pv
spec:
  capacity:
    storage: 50Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: efs-sc
  csi:
    driver: efs.csi.aws.com
    volumeHandle: $EFS_ID
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: efs-pvc
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: efs-sc
  resources:
    requests:
      storage: 50Gi
EOF
}

# ------------ 創建S3存儲桶 ------------
create_s3_bucket() {
    echo "=== 創建S3存儲桶 ==="
    
    aws s3api create-bucket \
        --bucket $S3_BUCKET_NAME \
        --region $REGION \
        --create-bucket-configuration LocationConstraint=$REGION
    
    aws s3api put-public-access-block \
        --bucket $S3_BUCKET_NAME \
        --public-access-block-configuration \
        "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
}

# ------------ 部署Moodle應用 ------------
deploy_moodle() {
    echo "=== 部署Moodle應用 ==="
    
    DB_PASSWORD=$(aws rds describe-db-instances --db-instance-identifier moodle-db --region $REGION \
        --query 'DBInstances[0].MasterUserPassword' --output text)
    DB_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier moodle-db --region $REGION \
        --query 'DBInstances[0].Endpoint.Address' --output text)
    
    kubectl create secret generic moodle-secrets \
        --from-literal=username=moodleadmin \
        --from-literal=password="$DB_PASSWORD" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    kubectl create secret generic moodle-s3-secrets \
        --from-literal=s3-key=AKIAEXAMPLE \
        --from-literal=s3-secret=EXAMPLEKEY \
        --dry-run=client -o yaml | kubectl apply -f -
    
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: moodle
spec:
  replicas: 1
  selector:
    matchLabels:
      app: moodle
  template:
    metadata:
      labels:
        app: moodle
    spec:
      containers:
      - name: moodle
        image: $MOODLE_IMAGE
        ports:
        - containerPort: 80
        env:
        - name: DATABASE_HOST
          value: "$DB_ENDPOINT"
        - name: DATABASE_USER
          valueFrom:
            secretKeyRef:
              name: moodle-secrets
              key: username
        - name: DATABASE_PASSWORD
          valueFrom:
            secretKeyRef:
              name: moodle-secrets
              key: password
        - name: MOODLE_USE_S3
          value: "true"
        - name: MOODLE_S3_KEY
          valueFrom:
            secretKeyRef:
              name: moodle-s3-secrets
              key: s3-key
        - name: MOODLE_S3_SECRET
          valueFrom:
            secretKeyRef:
              name: moodle-s3-secrets
              key: s3-secret
        - name: MOODLE_S3_BUCKET
          value: "$S3_BUCKET_NAME"
        - name: MOODLE_S3_REGION
          value: "$REGION"
        volumeMounts:
        - name: moodledata
          mountPath: /bitnami/moodledata
      volumes:
      - name: moodledata
        persistentVolumeClaim:
          claimName: efs-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: moodle-service
spec:
  selector:
    app: moodle
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
EOF
    
    echo -n "等待Moodle Pod就緒..."
    kubectl wait --for=condition=ready pod -l app=moodle --timeout=300s
    echo "✓"
}

# ------------ 配置ALB Ingress ------------
setup_alb_ingress() {
    echo "=== 配置ALB Ingress ==="
    
    kubectl apply -k "github.com/aws/eks-charts/stable/aws-load-balancer-controller/crds?ref=master"
    
    helm repo add eks https://aws.github.io/eks-charts
    helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
        --set clusterName=$EKS_CLUSTER_NAME \
        --set serviceAccount.create=true \
        -n kube-system
    
    kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: moodle-ingress
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/healthcheck-path: /login/index.php
    alb.ingress.kubernetes.io/healthcheck-port: traffic-port
    alb.ingress.kubernetes.io/success-codes: "200,302"
spec:
  rules:
  - host: $RECORD_NAME
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: moodle-service
            port:
              number: 80
EOF
    
    echo -n "等待ALB創建..."
    sleep 30
    echo "✓"
}

# ------------ 配置Auto Scaling ------------
setup_autoscaling() {
    echo "=== 配置Auto Scaling ==="
    
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
    kubectl wait --for=condition=available deployment/metrics-server -n kube-system --timeout=120s
    
    kubectl autoscale deployment moodle \
        --cpu-percent=$TARGET_CPU \
        --min=$MIN_PODS \
        --max=$MAX_PODS
}

# ------------ 配置Route 53域名解析 ------------
setup_route53() {
    echo "=== 配置Route 53域名解析 ==="
    
    ALB_DNS=$(kubectl get ingress moodle-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    ALB_HOSTED_ZONE_ID=$(aws elbv2 describe-load-balancers --region $REGION \
        --query "LoadBalancers[?DNSName=='$ALB_DNS'].CanonicalHostedZoneId" \
        --output text)
    
    HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name $DOMAIN_NAME \
        --query 'HostedZones[0].Id' --output text | cut -d'/' -f3)
    
    aws route53 change-resource-record-sets \
        --hosted-zone-id $HOSTED_ZONE_ID \
        --change-batch file://<(cat <<EOF
{
    "Comment": "Creating Alias record for Moodle ALB",
    "Changes": [
        {
            "Action": "UPSERT",
            "ResourceRecordSet": {
                "Name": "$RECORD_NAME",
                "Type": "A",
                "AliasTarget": {
                    "HostedZoneId": "$ALB_HOSTED_ZONE_ID",
                    "DNSName": "$ALB_DNS",
                    "EvaluateTargetHealth": false
                }
            }
        }
    ]
}
EOF
)
}

# ------------ 顯示部署信息 ------------
show_info() {
    ALB_DNS=$(kubectl get ingress moodle-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    
    echo ""
    echo "=========================================="
    echo "部署完成！"
    echo "Moodle 訪問地址: http://$RECORD_NAME"
    echo "(DNS解析可能需要幾分鐘時間生效)"
    echo ""
    echo "資源信息:"
    echo "- EKS 集群名稱: $EKS_CLUSTER_NAME"
    echo "- RDS 端點: $(aws rds describe-db-instances --db-instance-identifier moodle-db --region $REGION --query 'DBInstances[0].Endpoint.Address' --output text)"
    echo "- EFS ID: $(aws efs describe-file-systems --region $REGION --query "FileSystems[?Tags[?Key=='Name' && Value=='MoodleEFS']].FileSystemId" --output text)"
    echo "- S3 桶名: $S3_BUCKET_NAME"
    echo "- ALB DNS: $ALB_DNS"
    echo "- Route 53 記錄: $RECORD_NAME -> $ALB_DNS"
    echo ""
    echo "管理命令:"
    echo "- 查看Pods狀態: kubectl get pods"
    echo "- 查看服務狀態: kubectl get svc"
    echo "- 查看Ingress狀態: kubectl get ingress"
    echo "- 查看HPA狀態: kubectl get hpa"
    echo "=========================================="
}

# ------------ 主流程 ------------
main() {
    create_eks_cluster
    deploy_rds
    create_efs
    create_s3_bucket
    deploy_moodle
    setup_alb_ingress
    setup_autoscaling
    setup_route53
    show_info
}

# ------------ 執行 ------------
main