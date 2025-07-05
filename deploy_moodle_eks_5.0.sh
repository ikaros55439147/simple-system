#!/bin/bash
# ==============================================
# Moodle 完整部署腳本
# 功能：
#   1. 創建 EKS 集群
#   2. 部署 RDS PostgreSQL
#   3. 設置 EFS 存儲
#   4. 創建 S3 存儲桶
#   5. 部署 Moodle 應用
#   6. 配置 ALB Ingress
#   7. 設置 Auto Scaling
#   8. 配置 Route 53 域名解析
# ==============================================

# ------------ 配置變量 ------------
REGION="us-east-1"
EKS_CLUSTER_NAME="moodle-cluster-$(date +%Y%m%d%H%M)"
NODE_TYPE="t3.medium"
MIN_NODES=1
MAX_NODES=2
MOODLE_IMAGE="bitnami/moodle:5.0-debian-12"

# RDS 配置
RDS_INSTANCE_CLASS="db.t3.medium"
RDS_STORAGE_SIZE=20
RDS_ENGINE="postgres"

# Auto Scaling 配置
MIN_PODS=1
MAX_PODS=3
TARGET_CPU=50

# S3 配置
S3_BUCKET_NAME="moodle-data-$(date +%s | md5sum | head -c 8)"

# Route 53 配置
DOMAIN_NAME="fipcuring.com"
RECORD_NAME="www.${DOMAIN_NAME}"

# 密鑰對配置
KEY_PAIR_NAME="moodle-key-$(date +%Y%m%d)"

# ------------ 初始化檢查 ------------
init_checks() {
    echo "=== 初始化檢查 ==="
    
    # 檢查必要工具
    for cmd in aws eksctl kubectl jq; do
        if ! command -v $cmd &>/dev/null; then
            echo "錯誤: $cmd 未安裝!"
            exit 1
        fi
    done
    
    echo "✓ 所有檢查通過"
}

# ------------ 創建 SSH 密鑰對 ------------
create_key_pair() {
    echo "=== 創建 SSH 密鑰對 ==="
    
    if ! aws ec2 describe-key-pairs --key-names $KEY_PAIR_NAME --region $REGION &>/dev/null; then
        echo "創建新密鑰對: $KEY_PAIR_NAME"
        aws ec2 create-key-pair \
            --key-name $KEY_PAIR_NAME \
            --region $REGION \
            --query 'KeyMaterial' \
            --output text > ${KEY_PAIR_NAME}.pem
        
        chmod 400 ${KEY_PAIR_NAME}.pem
    else
        echo "使用現有密鑰對: $KEY_PAIR_NAME"
    fi
}

# ------------ 創建 EKS 集群 ------------
create_eks_cluster() {
    echo "=== 創建 EKS 集群 ==="
    
    if eksctl get cluster --name $EKS_CLUSTER_NAME --region $REGION &>/dev/null; then
        echo "警告: 集群 $EKS_CLUSTER_NAME 已存在"
        return 0
    fi
    
    cat <<EOF | eksctl create cluster -f -
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: $EKS_CLUSTER_NAME
  region: $REGION
  version: "1.28"
iam:
  withOIDC: true
managedNodeGroups:
  - name: workers
    instanceType: $NODE_TYPE
    minSize: $MIN_NODES
    maxSize: $MAX_NODES
    ssh:
      allow: true
      publicKeyName: $KEY_PAIR_NAME
    iam:
      attachPolicyARNs:
        - arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
        - arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
        - arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
        - arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess
EOF

    eksctl utils wait --cluster $EKS_CLUSTER_NAME --region $REGION
    aws eks update-kubeconfig --name $EKS_CLUSTER_NAME --region $REGION
    
    echo "✓ EKS 集群創建完成"
}

# ------------ 部署 RDS PostgreSQL ------------
deploy_rds() {
    echo "=== 部署 RDS PostgreSQL ==="
    
    if aws rds describe-db-instances --db-instance-identifier moodle-db --region $REGION &>/dev/null; then
        echo "警告: RDS 實例 moodle-db 已存在"
        return 0
    fi
    
    VPC_ID=$(aws eks describe-cluster --name $EKS_CLUSTER_NAME --region $REGION \
        --query 'cluster.resourcesVpcConfig.vpcId' --output text)
    SG_ID=$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:eksctl.cluster.k8s.io/v1alpha1/cluster-name,Values=$EKS_CLUSTER_NAME" \
        --query 'SecurityGroups[0].GroupId' --output text)
    
    aws rds create-db-instance \
        --db-instance-identifier moodle-db \
        --db-instance-class $RDS_INSTANCE_CLASS \
        --engine $RDS_ENGINE \
        --allocated-storage $RDS_STORAGE_SIZE \
        --master-username moodleadmin \
        --master-user-password $(openssl rand -base64 16) \
        --vpc-security-group-ids $SG_ID \
        --backup-retention-period 1 \
        --no-multi-az \
        --no-publicly-accessible \
        --region $REGION
    
    echo -n "等待 RDS 就緒..."
    aws rds wait db-instance-available --db-instance-identifier moodle-db --region $REGION
    echo "✓"
    
    DB_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier moodle-db --region $REGION \
        --query 'DBInstances[0].Endpoint.Address' --output text)
    echo "✓ RDS 端點: $DB_ENDPOINT"
}

# ------------ 創建 EFS 存儲 ------------
create_efs() {
    echo "=== 創建 EFS 存儲 ==="
    
    EFS_ID=$(aws efs describe-file-systems --region $REGION \
        --query "FileSystems[?Tags[?Key=='Name' && Value=='MoodleEFS']].FileSystemId" \
        --output text)
    
    if [ -z "$EFS_ID" ]; then
        EFS_ID=$(aws efs create-file-system \
            --creation-token "moodle-efs" \
            --tags "Key=Name,Value=MoodleEFS" \
            --region $REGION \
            --query 'FileSystemId' --output text)
        
        sleep 10
    fi
    
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
            --region $REGION || true
    done
    
    EFS_DNS="$EFS_ID.efs.$REGION.amazonaws.com"
    echo "✓ EFS 掛載點: $EFS_DNS"
    
    # 部署 EFS CSI 驅動
    kubectl apply -k "github.com/kubernetes-sigs/aws-efs-csi-driver/deploy/kubernetes/overlays/stable/?ref=release-1.3"
    
    # 創建 StorageClass 和 PVC
    kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-sc
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: $EFS_ID
  directoryPerms: "700"
  gidRangeStart: "1000"
  gidRangeEnd: "2000"
  basePath: "/dynamic_provisioning"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: efs-claim
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: efs-sc
  resources:
    requests:
      storage: 5Gi
EOF
}

# ------------ 創建 S3 存儲桶 ------------
create_s3_bucket() {
    echo "=== 創建 S3 存儲桶 ==="
    
    if ! aws s3 ls "s3://$S3_BUCKET_NAME" --region $REGION &>/dev/null; then
        aws s3api create-bucket \
            --bucket $S3_BUCKET_NAME \
            --region $REGION \
            --create-bucket-configuration LocationConstraint=$REGION
        
        aws s3api put-public-access-block \
            --bucket $S3_BUCKET_NAME \
            --public-access-block-configuration \
            "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
    fi
    
    echo "✓ S3 桶創建完成: $S3_BUCKET_NAME"
}

# ------------ 部署 Moodle 應用 ------------
deploy_moodle() {
    echo "=== 部署 Moodle 應用 ==="
    
    DB_PASSWORD=$(aws rds describe-db-instances --db-instance-identifier moodle-db --region $REGION \
        --query 'DBInstances[0].MasterUserPassword' --output text)
    DB_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier moodle-db --region $REGION \
        --query 'DBInstances[0].Endpoint.Address' --output text)
    
    # 創建 Kubernetes Secrets
    kubectl create secret generic moodle-db-secret \
        --from-literal=username=moodleadmin \
        --from-literal=password="$DB_PASSWORD" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    kubectl create secret generic moodle-s3-secret \
        --from-literal=accesskey="AKIAEXAMPLE" \
        --from-literal=secretkey="EXAMPLEKEY" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # 部署 Moodle
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: moodle
  labels:
    app: moodle
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
              name: moodle-db-secret
              key: username
        - name: DATABASE_PASSWORD
          valueFrom:
            secretKeyRef:
              name: moodle-db-secret
              key: password
        - name: MOODLE_USE_S3
          value: "true"
        - name: MOODLE_S3_KEY
          valueFrom:
            secretKeyRef:
              name: moodle-s3-secret
              key: accesskey
        - name: MOODLE_S3_SECRET
          valueFrom:
            secretKeyRef:
              name: moodle-s3-secret
              key: secretkey
        - name: MOODLE_S3_BUCKET
          value: "$S3_BUCKET_NAME"
        - name: MOODLE_S3_REGION
          value: "$REGION"
        volumeMounts:
        - name: moodle-data
          mountPath: /bitnami/moodledata
        resources:
          requests:
            cpu: 500m
            memory: 1Gi
          limits:
            cpu: 1000m
            memory: 2Gi
      volumes:
      - name: moodle-data
        persistentVolumeClaim:
          claimName: efs-claim
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

    echo -n "等待 Moodle Pod 就緒..."
    kubectl wait --for=condition=ready pod -l app=moodle --timeout=300s
    echo "✓"
}

# ------------ 配置 ALB Ingress ------------
setup_alb_ingress() {
    echo "=== 配置 ALB Ingress ==="
    
    # 安裝 ALB 控制器
    eksctl utils associate-iam-oidc-provider --cluster $EKS_CLUSTER_NAME --region $REGION --approve
    
    kubectl apply -k "github.com/aws/eks-charts/stable/aws-load-balancer-controller/crds?ref=master"
    
    helm repo add eks https://aws.github.io/eks-charts
    helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
        --set clusterName=$EKS_CLUSTER_NAME \
        --set serviceAccount.create=true \
        -n kube-system
    
    # 創建 Ingress
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
    alb.ingress.kubernetes.io/success-codes: "200,302"
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}]'
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

    echo -n "等待 ALB 創建..."
    sleep 30
    ALB_DNS=$(kubectl get ingress moodle-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    echo "✓"
    echo "ALB DNS: $ALB_DNS"
}

# ------------ 配置 Auto Scaling ------------
setup_autoscaling() {
    echo "=== 配置 Auto Scaling ==="
    
    # 安裝 Metrics Server
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
    kubectl wait --for=condition=available deployment/metrics-server -n kube-system --timeout=120s
    
    # 設置 Horizontal Pod Autoscaler
    kubectl autoscale deployment moodle \
        --cpu-percent=$TARGET_CPU \
        --min=$MIN_PODS \
        --max=$MAX_PODS
    
    echo "✓ Auto Scaling 配置完成"
    echo "Pod 擴展範圍: $MIN_PODS-$MAX_PODS (CPU 閾值: $TARGET_CPU%)"
}

# ------------ 配置 Route 53 域名解析 ------------
setup_route53() {
    echo "=== 配置 Route 53 域名解析 ==="
    
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
    
    echo "✓ Route 53 配置完成"
    echo "域名: $RECORD_NAME → $ALB_DNS"
}

# ------------ 顯示部署信息 ------------
show_info() {
    ALB_DNS=$(kubectl get ingress moodle-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    DB_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier moodle-db --region $REGION \
        --query 'DBInstances[0].Endpoint.Address' --output text)
    EFS_ID=$(aws efs describe-file-systems --region $REGION \
        --query "FileSystems[?Tags[?Key=='Name' && Value=='MoodleEFS']].FileSystemId" \
        --output text)
    
    echo ""
    echo "=========================================="
    echo "部署完成！"
    echo "Moodle 訪問地址: http://$RECORD_NAME"
    echo "(DNS 解析可能需要幾分鐘時間生效)"
    echo ""
    echo "資源信息:"
    echo "- EKS 集群名稱: $EKS_CLUSTER_NAME"
    echo "- RDS 端點: $DB_ENDPOINT"
    echo "- EFS ID: $EFS_ID"
    echo "- S3 桶名: $S3_BUCKET_NAME"
    echo "- ALB DNS: $ALB_DNS"
    echo "- Route 53 記錄: $RECORD_NAME → $ALB_DNS"
    echo ""
    echo "管理命令:"
    echo "- 查看 Pods: kubectl get pods"
    echo "- 查看服務: kubectl get svc"
    echo "- 查看 Ingress: kubectl get ingress"
    echo "- 查看 HPA: kubectl get hpa"
    echo "- 查看 PVC: kubectl get pvc"
    echo "=========================================="
}

# ------------ 清理資源 ------------
cleanup_resources() {
    echo "=== 清理資源 ==="
    
    echo "警告: 這將刪除所有創建的資源!"
    read -p "確定要繼續嗎? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 0
    fi
    
    # 刪除 Route 53 記錄
    ALB_DNS=$(kubectl get ingress moodle-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
    if [ -n "$ALB_DNS" ]; then
        HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name $DOMAIN_NAME \
            --query 'HostedZones[0].Id' --output text | cut -d'/' -f3 2>/dev/null || true)
        
        if [ -n "$HOSTED_ZONE_ID" ]; then
            ALB_HOSTED_ZONE_ID=$(aws elbv2 describe-load-balancers --region $REGION \
                --query "LoadBalancers[?DNSName=='$ALB_DNS'].CanonicalHostedZoneId" \
                --output text 2>/dev/null || true)
            
            if [ -n "$ALB_HOSTED_ZONE_ID" ]; then
                aws route53 change-resource-record-sets \
                    --hosted-zone-id $HOSTED_ZONE_ID \
                    --change-batch file://<(cat <<EOF
{
    "Comment": "Deleting Alias record for Moodle ALB",
    "Changes": [
        {
            "Action": "DELETE",
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
) || true
            fi
        fi
    fi
    
    # 刪除 RDS 實例
    echo "正在刪除 RDS 實例..."
    aws rds delete-db-instance \
        --db-instance-identifier moodle-db \
        --skip-final-snapshot \
        --region $REGION || true
    
    # 刪除 EFS
    echo "正在刪除 EFS..."
    EFS_ID=$(aws efs describe-file-systems --region $REGION \
        --query "FileSystems[?Tags[?Key=='Name' && Value=='MoodleEFS']].FileSystemId" \
        --output text 2>/dev/null || true)
    
    if [ -n "$EFS_ID" ]; then
        MOUNT_TARGETS=$(aws efs describe-mount-targets --file-system-id $EFS_ID --region $REGION \
            --query 'MountTargets[].MountTargetId' --output text 2>/dev/null || true)
        for mt in $MOUNT_TARGETS; do
            aws efs delete-mount-target --mount-target-id $mt --region $REGION || true
        done
        
        sleep 30
        aws efs delete-file-system --file-system-id $EFS_ID --region $REGION || true
    fi
    
    # 刪除 S3 桶
    echo "正在刪除 S3 桶..."
    aws s3 rb "s3://$S3_BUCKET_NAME" --force || true
    
    # 刪除 EKS 集群
    echo "正在刪除 EKS 集群..."
    eksctl delete cluster --name $EKS_CLUSTER_NAME --region $REGION || true
    
    # 刪除 SSH 密鑰
    echo "正在刪除 SSH 密鑰..."
    aws ec2 delete-key-pair --key-name $KEY_PAIR_NAME --region $REGION || true
    rm -f ${KEY_PAIR_NAME}.pem 2>/dev/null || true
    
    echo "✓ 資源清理完成"
}

# ------------ 主流程 ------------
main() {
    init_checks
    create_key_pair
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
if [ "$1" == "cleanup" ]; then
    cleanup_resources
else
    main
fi