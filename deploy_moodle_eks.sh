#!/bin/bash
# ==============================================
# AWS EKS Moodle 专属部署脚本
# 功能：
#   1. 从GitHub克隆Moodle源码
#   2. 构建自定义Docker镜像并推送至ECR
#   3. 创建EKS集群
#   4. 部署RDS PostgreSQL
#   5. 部署EFS共享存储
#   6. 配置ALB Ingress访问
# 版本：1.0
# 要求：
#   - 已安装AWS CLI, eksctl, kubectl, docker, jq
#   - 已配置AWS凭证（aws configure）
# ==============================================

# ------------ 配置变量 ------------
REGION="us-east-1"
EKS_CLUSTER_NAME="moodle-cluster"
NODE_TYPE="t3.medium"
MIN_NODES=1
MAX_NODES=3
VPC_CIDR="10.0.0.0/16"
MOODLE_GIT_URL="https://github.com/moodle/moodle.git"  # 替换为实际Moodle源码仓库
ECR_REPO="115916007852.dkr.ecr.$REGION.amazonaws.com/simple_system"  # 替换为你的ECR地址

# Secrets Manager名称
SECRET_DB="moodle-db-credentials"   # 存储RDS用户名/密码
SECRET_KEYPAIR="ec2-keypair-name"   # 存储EKS节点密钥对名称

# ------------ 依赖检查 ------------
check_dependencies() {
    for cmd in aws eksctl kubectl docker jq git; do
        if ! command -v $cmd &> /dev/null; then
            echo "错误：未安装 $cmd!请先安装。"
            exit 1
        fi
    done
}

# ------------ 从Secrets Manager获取敏感信息 ------------
load_secrets() {
    echo "步骤1/7:从Secrets Manager加载敏感信息..."
    DB_SECRET=$(aws secretsmanager get-secret-value --secret-id $SECRET_DB --region $REGION --query 'SecretString' --output text)
    DB_USERNAME=$(echo $DB_SECRET | jq -r '.username')
    DB_PASSWORD=$(echo $DB_SECRET | jq -r '.password')
    KEY_PAIR=$(aws secretsmanager get-secret-value --secret-id $SECRET_KEYPAIR --region $REGION --query 'SecretString' --output text | jq -r '.keyName')

    if [ -z "$DB_PASSWORD" ] || [ -z "$KEY_PAIR" ]; then
        echo "错误:无法从Secrets Manager获取敏感信息!"
        exit 1
    fi
}

# ------------ 创建EKS集群 ------------
create_eks_cluster() {
    echo "步骤2/7:创建EKS集群..."
    cat > eks-cluster-config.yaml <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: $EKS_CLUSTER_NAME
  region: $REGION
  version: "1.28"
vpc:
  cidr: $VPC_CIDR
managedNodeGroups:
  - name: workers
    instanceType: $NODE_TYPE
    minSize: $MIN_NODES
    maxSize: $MAX_NODES
    ssh:
      allow: true
      publicKeyName: $KEY_PAIR
EOF
    eksctl create cluster -f eks-cluster-config.yaml
}

# ------------ 部署RDS PostgreSQL ------------
deploy_rds() {
    echo "步骤3/7:部署RDS PostgreSQL..."
    SUBNET_IDS=$(aws ec2 describe-subnets \
        --filters "Name=tag:eksctl.cluster.k8s.io/v1alpha1/cluster-name,Values=$EKS_CLUSTER_NAME" "Name=tag:aws:cloudformation:logical-id,Values=SubnetPrivate*" \
        --query 'Subnets[*].SubnetId' --output text | tr '\n' ' ')

    aws rds create-db-subnet-group \
        --db-subnet-group-name MoodleDBSubnetGroup \
        --db-subnet-group-description "Moodle DB Subnet Group" \
        --subnet-ids $SUBNET_IDS

    aws rds create-db-instance \
        --db-instance-identifier moodle-db \
        --db-instance-class db.t3.medium \
        --engine postgres \
        --allocated-storage 20 \
        --master-username $DB_USERNAME \
        --master-user-password $DB_PASSWORD \
        --db-subnet-group-name MoodleDBSubnetGroup \
        --vpc-security-group-ids $(aws ec2 describe-security-groups \
            --filters "Name=tag:eksctl.cluster.k8s.io/v1alpha1/cluster-name,Values=$EKS_CLUSTER_NAME" "Name=group-name,Values=*ClusterSharedNodeSecurityGroup*" \
            --query 'SecurityGroups[0].GroupId' --output text) \
        --backup-retention-period 7 \
        --multi-az \
        --no-publicly-accessible

    echo "等待RDS就绪(约10分钟)..."
    aws rds wait db-instance-available --db-instance-identifier moodle-db
}

# ------------ 部署EFS ------------
deploy_efs() {
    echo "步骤4/7:部署EFS文件系统..."
    EFS_ID=$(aws efs create-file-system \
        --tags Key=Name,Value=MoodleEFS \
        --query 'FileSystemId' --output text)

    for subnet in $SUBNET_IDS; do
        aws efs create-mount-target \
            --file-system-id $EFS_ID \
            --subnet-id $subnet \
            --security-groups $(aws ec2 describe-security-groups \
                --filters "Name=tag:eksctl.cluster.k8s.io/v1alpha1/cluster-name,Values=$EKS_CLUSTER_NAME" "Name=group-name,Values=*ClusterSharedNodeSecurityGroup*" \
                --query 'SecurityGroups[0].GroupId' --output text)
    done

    EFS_DNS="$EFS_ID.efs.$REGION.amazonaws.com"
    echo "EFS挂载点: $EFS_DNS"
}

# ------------ 构建Moodle镜像 ------------
build_moodle_image() {
    echo "步骤5/7:构建Moodle镜像..."
    git clone $MOODLE_GIT_URL /tmp/moodle-source
    cd /tmp/moodle-source

    cat > Dockerfile <<EOF
FROM bitnami/moodle:5.0-debian-12
# 复制自定义配置
COPY . /opt/bitnami/moodle/
# 安装额外依赖（示例）
RUN apt-get update && apt-get install -y python3-pip \\
    && pip3 install --upgrade pip \\
    && chown -R daemon:daemon /opt/bitnami/moodle
EOF

    aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ECR_REPO
    docker build -t $ECR_REPO/moodle:latest .
    docker push $ECR_REPO/moodle:latest
    cd -
}

# ------------ 部署Moodle到EKS ------------
deploy_moodle() {
    echo "步骤6/7:部署Moodle到EKS..."
    aws eks update-kubeconfig --name $EKS_CLUSTER_NAME --region $REGION

    kubectl create secret generic moodle-secrets \
        --from-literal=username=$DB_USERNAME \
        --from-literal=password=$DB_PASSWORD

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
        image: $ECR_REPO/moodle:latest
        ports:
        - containerPort: 80
        env:
        - name: DATABASE_HOST
          value: "$(aws rds describe-db-instances --db-instance-identifier moodle-db --query 'DBInstances[0].Endpoint.Address' --output text)"
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
EOF

    kubectl apply -f moodle-deployment.yaml
}

# ------------ 配置ALB Ingress ------------
setup_ingress() {
    echo "步骤7/7:配置ALB Ingress..."
    # 安装ALB控制器
    eksctl utils associate-iam-oidc-provider --cluster $EKS_CLUSTER_NAME --region $REGION --approve
    kubectl apply -k "github.com/aws/eks-charts/stable/aws-load-balancer-controller/crds?ref=master"
    helm repo add eks https://aws.github.io/eks-charts
    helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
        --set clusterName=$EKS_CLUSTER_NAME \
        --set serviceAccount.create=false \
        --set serviceAccount.name=aws-load-balancer-controller \
        -n kube-system

    # 创建Ingress
    cat > moodle-ingress.yaml <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: moodle-ingress
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
spec:
  rules:
  - host: www.fipcuring.com
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
    kubectl apply -f moodle-ingress.yaml
}

# ------------ 主流程 ------------
main() {
    check_dependencies
    load_secrets
    create_eks_cluster
    deploy_rds
    deploy_efs
    build_moodle_image
    deploy_moodle
    setup_ingress

    echo "=========================================="
    echo "部署完成！"
    echo "Moodle访问地址: http://www.fipcuring.com"
    echo "ALB DNS: $(kubectl get ingress moodle-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
    echo "RDS端点: $(aws rds describe-db-instances --db-instance-identifier moodle-db --query 'DBInstances[0].Endpoint.Address' --output text)"
    echo "EFS挂载点: $EFS_DNS"
    echo "=========================================="
}

main