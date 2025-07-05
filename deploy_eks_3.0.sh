#!/bin/bash
# ==============================================
# 實驗室環境完整Moodle部署腳本
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
EKS_CLUSTER_NAME="moodle-lab-$(date +%s | cut -c 6-10)"  # 添加隨機後綴避免衝突
NODE_TYPE="t3.medium"
MIN_NODES=1
MAX_NODES=2            # 不超過實驗室限制
MOODLE_VERSION="4.2"
MOODLE_IMAGE="bitnami/moodle:5.0-debian-12"  # 使用預構建鏡像避免權限問題

# RDS配置
RDS_INSTANCE_CLASS="db.t3.medium"
RDS_STORAGE_SIZE=20
RDS_ENGINE="postgres"

# Auto Scaling配置
MIN_PODS=1
MAX_PODS=3
TARGET_CPU=50

# S3配置
S3_BUCKET_NAME="moodle-data-$(date +%s | md5sum | head -c 8)"  # 隨機桶名

# Route 53配置
DOMAIN_NAME="www.fipcuring.com"
HOSTED_ZONE_ID=""  # 如果已有託管區域，請填寫ID
RECORD_NAME="www.${DOMAIN_NAME}"

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
    
    # 檢查當前角色
    CURRENT_ROLE=$(aws sts get-caller-identity --query 'Arn' --output text)
    if [[ ! $CURRENT_ROLE == *"LabRole"* ]]; then
        echo "錯誤: 必須使用LabRole執行此腳本"
        exit 1
    fi
    
    # 檢查EC2實例數量限制
    RUNNING_INSTANCES=$(aws ec2 describe-instances --region $REGION \
        --filters "Name=instance-state-name,Values=running" \
        --query 'length(Reservations[].Instances[])')
    if [ "$RUNNING_INSTANCES" -ge 8 ]; then
        echo "錯誤: 已達到EC2實例數量限制(9個)"
        exit 1
    fi
    
    # 檢查Route 53託管區域
    if [ -z "$HOSTED_ZONE_ID" ]; then
        HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name $DOMAIN_NAME \
            --query 'HostedZones[0].Id' --output text | cut -d'/' -f3)
        if [ -z "$HOSTED_ZONE_ID" ] || [ "$HOSTED_ZONE_ID" == "None" ]; then
            echo "錯誤: 找不到 $DOMAIN_NAME 的Route 53託管區域"
            echo "請先在Route 53控制台創建託管區域或設置HOSTED_ZONE_ID變量"
            exit 1
        fi
    fi
    
    echo "✓ 所有檢查通過"
}

# ... [之前的函數保持不變：create_eks_cluster, deploy_rds, create_efs, create_s3_bucket, deploy_moodle, setup_alb_ingress, setup_autoscaling] ...

# ------------ 配置Route 53域名解析 ------------
setup_route53() {
    echo "=== 配置Route 53域名解析 ==="
    
    # 獲取ALB DNS名稱
    ALB_DNS=$(kubectl get ingress moodle-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    if [ -z "$ALB_DNS" ]; then
        echo "錯誤: 無法獲取ALB DNS名稱"
        exit 1
    fi
    
    # 獲取ALB的Hosted Zone ID
    ALB_HOSTED_ZONE_ID=$(aws elbv2 describe-load-balancers --region $REGION \
        --query "LoadBalancers[?DNSName=='$ALB_DNS'].CanonicalHostedZoneId" \
        --output text)
    
    # 創建DNS記錄
    cat > route53-change.json <<EOF
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
    
    # 更新Route 53記錄
    aws route53 change-resource-record-sets \
        --hosted-zone-id $HOSTED_ZONE_ID \
        --change-batch file://route53-change.json || {
        echo "錯誤: 更新Route 53記錄失敗"
        exit 1
    }
    
    echo "✓ Route 53配置完成"
    echo "域名解析可能需要幾分鐘時間生效"
    echo "最終訪問地址: http://$RECORD_NAME"
}

# ------------ 顯示部署信息 ------------
show_info() {
    echo ""
    echo "=========================================="
    echo "部署完成！"
    echo "Moodle 訪問地址: http://$RECORD_NAME"
    echo "(DNS解析可能需要幾分鐘時間生效)"
    echo ""
    echo "資源信息:"
    echo "- EKS 集群名稱: $EKS_CLUSTER_NAME"
    echo "- RDS 端點: $(aws rds describe-db-instances --db-instance-identifier moodle-db --region $REGION --query 'DBInstances[0].Endpoint.Address' --output text 2>/dev/null || echo '未獲取到')"
    echo "- EFS ID: $(aws efs describe-file-systems --region $REGION --query "FileSystems[?Tags[?Key=='Name' && Value=='MoodleEFS']].FileSystemId" --output text)"
    echo "- S3 桶名: $S3_BUCKET_NAME"
    echo "- ALB DNS: $(kubectl get ingress moodle-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
    echo "- Route 53 記錄: $RECORD_NAME -> ALB"
    echo ""
    echo "管理命令:"
    echo "- 查看Pods狀態: kubectl get pods"
    echo "- 查看服務狀態: kubectl get svc"
    echo "- 查看Ingress狀態: kubectl get ingress"
    echo "- 查看HPA狀態: kubectl get hpa"
    echo "- 清理所有資源: ./$(basename $0) cleanup"
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
    
    # 刪除Route 53記錄
    echo "正在刪除Route 53記錄..."
    ALB_DNS=$(kubectl get ingress moodle-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
    if [ -n "$ALB_DNS" ] && [ -n "$HOSTED_ZONE_ID" ]; then
        ALB_HOSTED_ZONE_ID=$(aws elbv2 describe-load-balancers --region $REGION \
            --query "LoadBalancers[?DNSName=='$ALB_DNS'].CanonicalHostedZoneId" \
            --output text 2>/dev/null || true)
        
        if [ -n "$ALB_HOSTED_ZONE_ID" ]; then
            cat > route53-delete.json <<EOF
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
            aws route53 change-resource-record-sets \
                --hosted-zone-id $HOSTED_ZONE_ID \
                --change-batch file://route53-delete.json || true
        fi
    fi
    
    # ... [保持之前的清理代碼不變] ...
    
    echo "✓ 資源清理完成"
}

# ------------ 主流程 ------------
main() {
    init_checks
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