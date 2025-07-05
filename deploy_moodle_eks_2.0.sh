#!/bin/bash
# ==============================================
# AWS CloudShell 專用 Moodle 部署腳本
# 特點：
#   1. 完全使用當前CloudShell角色權限
#   2. 無需預先創建IAM角色
#   3. 優化資源清理
# ==============================================

# ------------ 配置變量 ------------
REGION="us-east-1"
EKS_CLUSTER_NAME="moodle-cluster-$(date +%s | cut -c 6-10)"  # 添加隨機後綴避免衝突
NODE_TYPE="t3.medium"
MIN_NODES=1
MAX_NODES=3
MOODLE_VERSION="4.2"  # 使用穩定版本
MOODLE_GIT_URL="https://github.com/moodle/moodle.git"
MOODLE_GIT_BRANCH="MOODLE_${MOODLE_VERSION}_STABLE"

# 從當前會話獲取帳號ID
ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
ECR_REPO="115916007852.dkr.ecr.$REGION.amazonaws.com/simple_system"

# ------------ 初始化檢查 ------------
init_checks() {
    echo "=== 初始化檢查 ==="
    
    # 檢查必要工具
    for cmd in aws eksctl kubectl docker jq git; do
        if ! command -v $cmd &>/dev/null; then
            echo "錯誤: $cmd 未安裝!"
            exit 1
        fi
    done
    
    # 檢查CloudShell存儲空間 (至少需要3GB)
    AVAIL_SPACE=$(df -h /home/cloudshell-user | awk 'NR==2 {print $4}' | tr -d '[:alpha:]')
    if [ "$AVAIL_SPACE" -lt 3 ]; then
        echo "錯誤: 可用存儲空間不足 (需要至少3GB，當前僅有${AVAIL_SPACE}GB)"
        exit 1
    fi
    
    # 檢查當前角色權限
    if ! aws iam simulate-principal-policy \
        --policy-source-arn $(aws sts get-caller-identity --query 'Arn' --output text) \
        --action-names "eks:CreateCluster" "rds:CreateDBInstance" "ec2:CreateVolume" &>/dev/null; then
        echo "錯誤: 當前角色權限不足!"
        exit 1
    fi
    
    echo "✓ 所有檢查通過"
}

# ------------ 設置臨時目錄 ------------
setup_workspace() {
    WORKSPACE="/home/cloudshell-user/moodle-deploy-$(date +%s)"
    mkdir -p $WORKSPACE
    cd $WORKSPACE
    echo "工作目錄設置在: $WORKSPACE"
}

# ------------ 創建EKS集群 ------------
create_eks_cluster() {
    echo "=== 創建EKS集群 ==="
    
    # 檢查集群是否已存在
    if eksctl get cluster --name $EKS_CLUSTER_NAME --region $REGION &>/dev/null; then
        echo "警告: 集群 $EKS_CLUSTER_NAME 已存在"
        return 0
    fi
    
    echo "正在創建 EKS 集群 (約10-15分鐘)..."
    
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
        --ssh-public-key "$(aws ec2 describe-key-pairs --query 'KeyPairs[0].KeyName' --output text)" \
        --asg-access \
        --full-ecr-access \
        --alb-ingress-access || {
        echo "錯誤: 創建EKS集群失敗"
        exit 1
    }
    
    # 配置kubectl
    aws eks update-kubeconfig --name $EKS_CLUSTER_NAME --region $REGION
    
    echo "✓ EKS集群創建完成"
}

# ------------ 部署RDS PostgreSQL ------------
deploy_rds() {
    echo "=== 部署RDS PostgreSQL ==="
    
    # 檢查RDS實例是否已存在
    if aws rds describe-db-instances --db-instance-identifier moodle-db --region $REGION &>/dev/null; then
        echo "警告: RDS實例 moodle-db 已存在"
        return 0
    fi
    
    # 獲取EKS VPC和子網
    VPC_ID=$(aws eks describe-cluster --name $EKS_CLUSTER_NAME --region $REGION \
        --query 'cluster.resourcesVpcConfig.vpcId' --output text)
    SUBNET_IDS=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:aws:cloudformation:logical-id,Values=SubnetPrivate*" \
        --region $REGION --query 'Subnets[*].SubnetId' --output text | tr '\n' ' ')
    
    # 創建數據庫子網組
    aws rds create-db-subnet-group \
        --db-subnet-group-name moodle-db-subnet \
        --db-subnet-group-description "Moodle DB Subnet Group" \
        --subnet-ids $SUBNET_IDS \
        --region $REGION || {
        echo "警告: 創建DB子網組失敗 (可能已存在)"
    }
    
    # 創建安全組
    SG_ID=$(aws ec2 create-security-group \
        --group-name "moodle-db-sg" \
        --description "Moodle DB Security Group" \
        --vpc-id $VPC_ID \
        --region $REGION \
        --query 'GroupId' --output text)
    
    # 允許EKS節點訪問
    aws ec2 authorize-security-group-ingress \
        --group-id $SG_ID \
        --protocol tcp \
        --port 5432 \
        --cidr $(aws ec2 describe-vpcs --vpc-ids $VPC_ID --region $REGION --query 'Vpcs[0].CidrBlock' --output text) \
        --region $REGION
    
    # 創建RDS實例
    echo "正在創建RDS PostgreSQL實例 (約10-15分鐘)..."
    aws rds create-db-instance \
        --db-instance-identifier moodle-db \
        --db-instance-class db.t3.medium \
        --engine postgres \
        --engine-version "14.7" \
        --allocated-storage 20 \
        --master-username moodleadmin \
        --master-user-password $(date +%s | sha256sum | base64 | head -c 32) \
        --db-subnet-group-name moodle-db-subnet \
        --vpc-security-group-ids $SG_ID \
        --backup-retention-period 7 \
        --no-multi-az \
        --no-publicly-accessible \
        --region $REGION || {
        echo "錯誤: 創建RDS實例失敗"
        exit 1
    }
    
    # 等待RDS可用
    echo -n "等待RDS就緒..."
    aws rds wait db-instance-available --db-instance-identifier moodle-db --region $REGION
    echo "✓"
    
    DB_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier moodle-db --region $REGION \
        --query 'DBInstances[0].Endpoint.Address' --output text)
    echo "✓ RDS端點: $DB_ENDPOINT"
}

# ------------ 部署EFS存儲 ------------
deploy_efs() {
    echo "=== 部署EFS存儲 ==="
    
    VPC_ID=$(aws eks describe-cluster --name $EKS_CLUSTER_NAME --region $REGION \
        --query 'cluster.resourcesVpcConfig.vpcId' --output text)
    
    # 創建EFS文件系統
    EFS_ID=$(aws efs create-file-system \
        --creation-token "moodle-efs" \
        --tags "Key=Name,Value=MoodleEFS" \
        --region $REGION \
        --query 'FileSystemId' --output text) || {
        echo "錯誤: 創建EFS失敗"
        exit 1
    }
    
    # 獲取私有子網
    SUBNET_IDS=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:aws:cloudformation:logical-id,Values=SubnetPrivate*" \
        --region $REGION --query 'Subnets[*].SubnetId' --output text)
    
    # 獲取節點安全組
    NODE_SG=$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=*ClusterSharedNodeSecurityGroup*" \
        --region $REGION --query 'SecurityGroups[0].GroupId' --output text)
    
    # 在每個子網創建掛載點
    for SUBNET_ID in $SUBNET_IDS; do
        aws efs create-mount-target \
            --file-system-id $EFS_ID \
            --subnet-id $SUBNET_ID \
            --security-groups $NODE_SG \
            --region $REGION || {
            echo "警告: 在子網 $SUBNET_ID 創建掛載點失敗"
        }
    done
    
    # 等待EFS可用
    sleep 10
    
    EFS_DNS="$EFS_ID.efs.$REGION.amazonaws.com"
    echo "✓ EFS掛載點: $EFS_DNS"
}

# ------------ 構建Moodle鏡像 ------------
build_moodle_image() {
    echo "=== 構建Moodle鏡像 ==="
    
    # 克隆Moodle源代碼
    echo "正在克隆Moodle源代碼 (分支: $MOODLE_GIT_BRANCH)..."
    git clone --depth 1 --branch $MOODLE_GIT_BRANCH $MOODLE_GIT_URL moodle-source || {
        echo "錯誤: 克隆Moodle源代碼失敗"
        exit 1
    }
    
    cd moodle-source
    
    # 創建Dockerfile
    cat > Dockerfile <<EOF
FROM bitnami/moodle:5.0-debian-12

# 複製Moodle代碼
COPY . /opt/bitnami/moodle/

# 安裝依賴 (使用虛擬環境避免權限問題)
RUN apt-get update && apt-get install -y python3-pip python3-venv \\
    && python3 -m venv /opt/venv \\
    && /opt/venv/bin/pip install --upgrade pip \\
    && chown -R daemon:daemon /opt/bitnami/moodle

# 健康檢查
HEALTHCHECK --interval=30s --timeout=3s \\
  CMD curl -f http://localhost/ || exit 1
EOF
    
    # 登錄ECR
    aws ecr get-login-password --region $REGION | \
        docker login --username AWS --password-stdin $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com || {
        echo "錯誤: ECR登錄失敗"
        exit 1
    }
    
    # 創建ECR倉庫
    aws ecr create-repository --repository-name $ECR_REPO_NAME --region $REGION || {
        echo "警告: ECR倉庫可能已存在"
    }
    
    # 構建並推送鏡像
    echo "正在構建Docker鏡像..."
    docker build -t $ECR_REPO . || {
        echo "錯誤: 鏡像構建失敗"
        exit 1
    }
    
    echo "正在推送鏡像到ECR..."
    docker push $ECR_REPO || {
        echo "錯誤: 鏡像推送失敗"
        exit 1
    }
    
    cd ..
    echo "✓ Moodle鏡像構建完成: $ECR_REPO"
}

# ------------ 部署Moodle到EKS ------------
deploy_moodle() {
    echo "=== 部署Moodle到EKS ==="
    
    # 確保kubectl配置正確
    aws eks update-kubeconfig --name $EKS_CLUSTER_NAME --region $REGION
    
    # 獲取數據庫密碼
    DB_PASSWORD=$(aws rds describe-db-instances --db-instance-identifier moodle-db --region $REGION \
        --query 'DBInstances[0].MasterUserPassword' --output text)
    DB_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier moodle-db --region $REGION \
        --query 'DBInstances[0].Endpoint.Address' --output text)
    
    # 創建Kubernetes Secret
    kubectl create secret generic moodle-secrets \
        --from-literal=username=moodleadmin \
        --from-literal=password="$DB_PASSWORD" \
        --dry-run=client -o yaml | kubectl apply -f - || {
        echo "錯誤: 創建Secret失敗"
        exit 1
    }
    
    # 部署Moodle應用
    cat > moodle-deployment.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: moodle
spec:
  replicas: 2
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
        image: $ECR_REPO
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
        volumeMounts:
        - name: moodledata
          mountPath: /bitnami/moodledata
      volumes:
      - name: moodledata
        nfs:
          server: $EFS_DNS
          path: /
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
  type: NodePort
EOF
    
    kubectl apply -f moodle-deployment.yaml || {
        echo "錯誤: 部署Moodle失敗"
        exit 1
    }
    
    # 等待Pod就緒
    echo -n "等待Moodle Pod就緒..."
    kubectl wait --for=condition=ready pod -l app=moodle --timeout=300s
    echo "✓"
    
    echo "✓ Moodle部署完成"
}

# ------------ 配置ALB Ingress ------------
setup_ingress() {
    echo "=== 配置ALB Ingress ==="
    
    # 安裝ALB控制器
    echo "正在安裝ALB控制器..."
    kubectl apply -k "github.com/aws/eks-charts/stable/aws-load-balancer-controller/crds?ref=master" || {
        echo "錯誤: 安裝ALB CRDs失敗"
        exit 1
    }
    
    helm repo add eks https://aws.github.io/eks-charts || {
        echo "警告: EKS倉庫已存在"
    }
    
    helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
        --set clusterName=$EKS_CLUSTER_NAME \
        --set serviceAccount.create=true \
        -n kube-system || {
        echo "錯誤: 安裝ALB控制器失敗"
        exit 1
    }
    
    # 創建Ingress
    cat > moodle-ingress.yaml <<EOF
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
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: moodle-service
            port:
              number: 80
EOF
    
    kubectl apply -f moodle-ingress.yaml || {
        echo "錯誤: 創建Ingress失敗"
        exit 1
    }
    
    # 獲取ALB DNS
    echo -n "等待ALB創建..."
    sleep 30
    ALB_DNS=$(kubectl get ingress moodle-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    echo "✓"
    
    echo "✓ ALB配置完成"
    echo "訪問地址: http://$ALB_DNS"
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
    
    # 刪除Ingress
    kubectl delete ingress moodle-ingress || true
    
    # 刪除部署
    kubectl delete -f moodle-deployment.yaml || true
    
    # 刪除Secret
    kubectl delete secret moodle-secrets || true
    
    # 刪除RDS
    echo "正在刪除RDS實例..."
    aws rds delete-db-instance \
        --db-instance-identifier moodle-db \
        --skip-final-snapshot \
        --region $REGION || true
    
    # 刪除EFS
    echo "正在刪除EFS..."
    EFS_ID=$(aws efs describe-file-systems --region $REGION \
        --query "FileSystems[?Tags[?Key=='Name' && Value=='MoodleEFS']].FileSystemId" \
        --output text)
    
    if [ -n "$EFS_ID" ]; then
        # 刪除掛載目標
        MOUNT_TARGETS=$(aws efs describe-mount-targets --file-system-id $EFS_ID --region $REGION \
            --query 'MountTargets[].MountTargetId' --output text)
        for mt in $MOUNT_TARGETS; do
            aws efs delete-mount-target --mount-target-id $mt --region $REGION || true
        done
        
        # 等待掛載目標刪除
        sleep 30
        
        # 刪除文件系統
        aws efs delete-file-system --file-system-id $EFS_ID --region $REGION || true
    fi
    
    # 刪除ECR倉庫
    echo "正在刪除ECR倉庫..."
    aws ecr delete-repository \
        --repository-name $ECR_REPO_NAME \
        --force \
        --region $REGION || true
    
    # 刪除EKS集群
    echo "正在刪除EKS集群 (這可能需要15-20分鐘)..."
    eksctl delete cluster --name $EKS_CLUSTER_NAME --region $REGION || true
    
    echo "✓ 資源清理完成"
}

# ------------ 顯示部署信息 ------------
show_info() {
    echo ""
    echo "=========================================="
    echo "部署完成！"
    echo "Moodle 訪問地址: http://$(kubectl get ingress moodle-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
    echo ""
    echo "資源信息:"
    echo "- EKS 集群名稱: $EKS_CLUSTER_NAME"
    echo "- RDS 端點: $(aws rds describe-db-instances --db-instance-identifier moodle-db --region $REGION --query 'DBInstances[0].Endpoint.Address' --output text 2>/dev/null || echo '未獲取到')"
    echo "- EFS 掛載點: $EFS_DNS"
    echo "- ECR 鏡像倉庫: $ECR_REPO"
    echo ""
    echo "管理命令:"
    echo "- 查看Pods狀態: kubectl get pods"
    echo "- 查看服務狀態: kubectl get svc"
    echo "- 查看Ingress狀態: kubectl get ingress"
    echo "- 清理所有資源: ./$(basename $0) cleanup"
    echo "=========================================="
}

# ------------ 主流程 ------------
main() {
    init_checks
    setup_workspace
    
    # 執行部署步驟
    create_eks_cluster
    deploy_rds
    deploy_efs
    build_moodle_image
    deploy_moodle
    setup_ingress
    
    show_info
}

# ------------ 執行 ------------
if [ "$1" == "cleanup" ]; then
    cleanup_resources
else
    main
fi