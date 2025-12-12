#!/bin/bash
#
# ThingsBoard 开发环境一键启动脚本
# 自动启动TB + 配置Rule Chain + 创建测试设备
#
# 用法:
#   ./start-tb-dev.sh          # 启动TB并配置所有组件
#   ./start-tb-dev.sh config   # 仅配置（TB已运行时使用）
#   ./start-tb-dev.sh stop     # 停止TB
#   ./start-tb-dev.sh restart  # 重启TB
#   ./start-tb-dev.sh logs     # 查看日志
#   ./start-tb-dev.sh status   # 查看状态
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 配置
TB_URL="http://localhost:7070"
TB_USERNAME="tenant@thingsboard.org"
TB_PASSWORD="tenant"
RUOYI_URL="http://host.docker.internal:5500"
TEST_DEVICE_NAME="TEST001"
TEST_DEVICE_TYPE="YL012"

# 输出文件
OUTPUT_FILE="$SCRIPT_DIR/.tb-dev-config"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# 启动ThingsBoard
start_thingsboard() {
    log_step "1/5 启动 ThingsBoard..."
    docker compose -f docker-compose.dev.yml up -d

    log_info "等待 ThingsBoard 启动（可能需要2-3分钟）..."
    local max_attempts=60
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        # 尝试登录验证服务是否就绪
        local response=$(curl -s -X POST "$TB_URL/api/auth/login" \
            -H "Content-Type: application/json" \
            -d "{\"username\":\"$TB_USERNAME\",\"password\":\"$TB_PASSWORD\"}" 2>/dev/null || echo "")

        if echo "$response" | grep -q '"token"'; then
            echo ""
            log_info "ThingsBoard 启动成功!"
            return 0
        fi
        attempt=$((attempt + 1))
        echo -n "."
        sleep 5
    done

    echo ""
    log_error "ThingsBoard 启动超时，请检查日志: docker compose -f docker-compose.dev.yml logs"
    return 1
}

# 获取JWT Token
get_token() {
    log_step "2/5 获取认证Token..."

    local response=$(curl -s -X POST "$TB_URL/api/auth/login" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"$TB_USERNAME\",\"password\":\"$TB_PASSWORD\"}")

    TB_TOKEN=$(echo "$response" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')

    if [ -n "$TB_TOKEN" ]; then
        log_info "Token获取成功"
        return 0
    else
        log_error "获取Token失败: $response"
        return 1
    fi
}

# 创建并配置Rule Chain
configure_rule_chain() {
    log_step "3/5 配置 Rule Chain..."

    # 检查是否已存在IoT Webhook Chain
    local existing=$(curl -s -X GET "$TB_URL/api/ruleChains?pageSize=100&page=0" \
        -H "X-Authorization: Bearer $TB_TOKEN" | grep -o '"name":"IoT Webhook Chain"' || echo "")

    if [ -n "$existing" ]; then
        log_info "IoT Webhook Chain 已存在，跳过创建"
        # 获取ID并确保是Root
        local chain_id=$(curl -s -X GET "$TB_URL/api/ruleChains?pageSize=100&page=0" \
            -H "X-Authorization: Bearer $TB_TOKEN" | \
            sed -n 's/.*"id":{"entityType":"RULE_CHAIN","id":"\([^"]*\)"[^}]*}[^}]*"name":"IoT Webhook Chain".*/\1/p')

        if [ -n "$chain_id" ]; then
            RULE_CHAIN_ID="$chain_id"
            # 确保是Root
            curl -s -X POST "$TB_URL/api/ruleChain/$chain_id/root" \
                -H "X-Authorization: Bearer $TB_TOKEN" > /dev/null 2>&1
        fi
        return 0
    fi

    # 创建新的Rule Chain
    log_info "创建 IoT Webhook Chain..."
    local create_response=$(curl -s -X POST "$TB_URL/api/ruleChain" \
        -H "X-Authorization: Bearer $TB_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"name":"IoT Webhook Chain","type":"CORE","root":false,"debugMode":false}')

    RULE_CHAIN_ID=$(echo "$create_response" | sed -n 's/.*"id":{"entityType":"RULE_CHAIN","id":"\([^"]*\)".*/\1/p')

    if [ -z "$RULE_CHAIN_ID" ]; then
        log_error "创建Rule Chain失败: $create_response"
        return 1
    fi

    log_info "Rule Chain创建成功: $RULE_CHAIN_ID"

    # 设置Metadata（节点和连接）
    log_info "配置Webhook节点..."

    local metadata_json=$(cat << EOF
{
  "ruleChainId": {"entityType": "RULE_CHAIN", "id": "$RULE_CHAIN_ID"},
  "firstNodeIndex": 0,
  "nodes": [
    {
      "type": "org.thingsboard.rule.engine.filter.TbMsgTypeSwitchNode",
      "name": "Message Type Switch",
      "debugMode": false,
      "configuration": {"version": 0},
      "additionalInfo": {"layoutX": 350, "layoutY": 200}
    },
    {
      "type": "org.thingsboard.rule.engine.rest.TbRestApiCallNode",
      "name": "Telemetry Webhook",
      "debugMode": false,
      "configuration": {
        "restEndpointUrlPattern": "$RUOYI_URL/iot/webhook/telemetry",
        "requestMethod": "POST",
        "headers": {"Content-Type": "application/json"}
      },
      "additionalInfo": {"layoutX": 650, "layoutY": 100}
    },
    {
      "type": "org.thingsboard.rule.engine.rest.TbRestApiCallNode",
      "name": "Attributes Webhook",
      "debugMode": false,
      "configuration": {
        "restEndpointUrlPattern": "$RUOYI_URL/iot/webhook/attributes",
        "requestMethod": "POST",
        "headers": {"Content-Type": "application/json"}
      },
      "additionalInfo": {"layoutX": 650, "layoutY": 200}
    },
    {
      "type": "org.thingsboard.rule.engine.rest.TbRestApiCallNode",
      "name": "Activity Webhook",
      "debugMode": false,
      "configuration": {
        "restEndpointUrlPattern": "$RUOYI_URL/iot/webhook/activity",
        "requestMethod": "POST",
        "headers": {"Content-Type": "application/json"}
      },
      "additionalInfo": {"layoutX": 650, "layoutY": 300}
    },
    {
      "type": "org.thingsboard.rule.engine.telemetry.TbMsgTimeseriesNode",
      "name": "Save Telemetry",
      "debugMode": false,
      "configuration": {"defaultTTL": 0},
      "additionalInfo": {"layoutX": 950, "layoutY": 100}
    },
    {
      "type": "org.thingsboard.rule.engine.telemetry.TbMsgAttributesNode",
      "name": "Save Attributes",
      "debugMode": false,
      "configuration": {"scope": "CLIENT_SCOPE"},
      "additionalInfo": {"layoutX": 950, "layoutY": 200}
    }
  ],
  "connections": [
    {"fromIndex": 0, "toIndex": 1, "type": "Post telemetry"},
    {"fromIndex": 0, "toIndex": 2, "type": "Post attributes"},
    {"fromIndex": 0, "toIndex": 3, "type": "Activity Event"},
    {"fromIndex": 1, "toIndex": 4, "type": "Success"},
    {"fromIndex": 2, "toIndex": 5, "type": "Success"}
  ]
}
EOF
)

    local metadata_response=$(curl -s -X POST "$TB_URL/api/ruleChain/metadata" \
        -H "X-Authorization: Bearer $TB_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$metadata_json")

    if echo "$metadata_response" | grep -q "RULE_NODE"; then
        log_info "Webhook节点配置成功"
    else
        log_warn "Webhook节点配置可能失败: ${metadata_response:0:100}"
    fi

    # 设置为Root Rule Chain
    log_info "设置为Root Rule Chain..."
    curl -s -X POST "$TB_URL/api/ruleChain/$RULE_CHAIN_ID/root" \
        -H "X-Authorization: Bearer $TB_TOKEN" > /dev/null 2>&1

    log_info "Rule Chain配置完成"
}

# 创建YL012设备配置文件
create_device_profile() {
    log_step "4/5 创建设备配置文件..."

    # 检查是否已存在
    local existing=$(curl -s -X GET "$TB_URL/api/deviceProfiles?pageSize=100&page=0" \
        -H "X-Authorization: Bearer $TB_TOKEN" | grep -o '"name":"YL012"' || echo "")

    if [ -n "$existing" ]; then
        log_info "YL012设备配置文件已存在，跳过创建"
        return 0
    fi

    local profile_json='{
        "name": "YL012",
        "description": "YL012智能眼部按摩仪",
        "type": "DEFAULT",
        "transportType": "DEFAULT",
        "profileData": {
            "configuration": {"type": "DEFAULT"},
            "transportConfiguration": {"type": "DEFAULT"}
        }
    }'

    local response=$(curl -s -X POST "$TB_URL/api/deviceProfile" \
        -H "X-Authorization: Bearer $TB_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$profile_json")

    if echo "$response" | grep -q '"name":"YL012"'; then
        log_info "YL012设备配置文件创建成功"
    else
        log_warn "设备配置文件创建失败或已存在"
    fi
}

# 创建测试设备
create_test_device() {
    log_step "5/5 创建测试设备..."

    # 使用TB API按设备名查询（更可靠的方式）
    local device_response=$(curl -s -X GET "$TB_URL/api/tenant/devices?deviceName=$TEST_DEVICE_NAME" \
        -H "X-Authorization: Bearer $TB_TOKEN")

    # 检查是否已存在（响应包含设备ID表示存在）
    if echo "$device_response" | grep -q '"entityType":"DEVICE"'; then
        log_info "测试设备 $TEST_DEVICE_NAME 已存在"
        # 从响应中提取设备ID
        DEVICE_ID=$(echo "$device_response" | sed -n 's/.*"id":{"entityType":"DEVICE","id":"\([^"]*\)".*/\1/p')

        if [ -n "$DEVICE_ID" ]; then
            log_info "设备ID: $DEVICE_ID"
            # 获取Access Token
            local cred_response=$(curl -s -X GET "$TB_URL/api/device/$DEVICE_ID/credentials" \
                -H "X-Authorization: Bearer $TB_TOKEN")
            ACCESS_TOKEN=$(echo "$cred_response" | sed -n 's/.*"credentialsId":"\([^"]*\)".*/\1/p')
            log_info "Access Token: $ACCESS_TOKEN"
        fi
        return 0
    fi

    # 创建新设备
    local device_json="{\"name\":\"$TEST_DEVICE_NAME\",\"type\":\"$TEST_DEVICE_TYPE\",\"label\":\"测试眼部按摩仪-$TEST_DEVICE_NAME\"}"

    local response=$(curl -s -X POST "$TB_URL/api/device" \
        -H "X-Authorization: Bearer $TB_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$device_json")

    DEVICE_ID=$(echo "$response" | sed -n 's/.*"id":{"entityType":"DEVICE","id":"\([^"]*\)".*/\1/p')

    if [ -z "$DEVICE_ID" ]; then
        log_warn "创建测试设备失败"
        return 1
    fi

    log_info "测试设备创建成功: $DEVICE_ID"

    # 获取Access Token
    local cred_response=$(curl -s -X GET "$TB_URL/api/device/$DEVICE_ID/credentials" \
        -H "X-Authorization: Bearer $TB_TOKEN")
    ACCESS_TOKEN=$(echo "$cred_response" | sed -n 's/.*"credentialsId":"\([^"]*\)".*/\1/p')

    log_info "Access Token: $ACCESS_TOKEN"
}

# 保存配置到文件
save_config() {
    cat > "$OUTPUT_FILE" << EOF
# ThingsBoard 开发环境配置
# 生成时间: $(date)

TB_URL=$TB_URL
TB_USERNAME=$TB_USERNAME
RUOYI_URL=$RUOYI_URL

# 测试设备信息
TEST_DEVICE_NAME=$TEST_DEVICE_NAME
TEST_DEVICE_ID=$DEVICE_ID
TEST_ACCESS_TOKEN=$ACCESS_TOKEN

# Rule Chain
RULE_CHAIN_ID=$RULE_CHAIN_ID
EOF
    log_info "配置已保存到: $OUTPUT_FILE"
}

# 显示完成信息
show_info() {
    echo ""
    echo "=========================================="
    echo -e "${GREEN}ThingsBoard 开发环境已就绪${NC}"
    echo "=========================================="
    echo ""
    echo -e "${BLUE}访问地址:${NC}"
    echo "  - TB管理界面: http://localhost:7070"
    echo "  - MQTT端口: 1883"
    echo ""
    echo -e "${BLUE}登录账号:${NC}"
    echo "  - 系统管理员: sysadmin@thingsboard.org / sysadmin"
    echo "  - 租户管理员: tenant@thingsboard.org / tenant"
    echo ""
    echo -e "${BLUE}测试设备:${NC}"
    echo "  - 设备名称: $TEST_DEVICE_NAME"
    echo "  - 设备类型: $TEST_DEVICE_TYPE"
    echo "  - Access Token: $ACCESS_TOKEN"
    echo ""
    echo -e "${BLUE}Webhook端点 (Ruoyi 5500端口):${NC}"
    echo "  - Telemetry: $RUOYI_URL/iot/webhook/telemetry"
    echo "  - Attributes: $RUOYI_URL/iot/webhook/attributes"
    echo "  - Activity: $RUOYI_URL/iot/webhook/activity"
    echo ""
    echo -e "${BLUE}验证命令:${NC}"
    echo "  # 模拟设备上报数据"
    echo "  curl -X POST \"http://localhost:7070/api/v1/$ACCESS_TOKEN/telemetry\" \\"
    echo "    -H \"Content-Type: application/json\" \\"
    echo "    -d '{\"power_state_reported\":1,\"battery_level\":85}'"
    echo ""
    echo -e "${BLUE}常用命令:${NC}"
    echo "  ./start-tb-dev.sh config   # 重新配置（不重启TB）"
    echo "  ./start-tb-dev.sh status   # 查看状态"
    echo "  ./start-tb-dev.sh logs     # 查看日志"
    echo "  ./start-tb-dev.sh stop     # 停止服务"
    echo ""
}

# 查看状态
show_status() {
    echo ""
    echo "=========================================="
    echo "ThingsBoard 状态"
    echo "=========================================="
    echo ""

    # Docker容器状态
    echo -e "${BLUE}Docker容器:${NC}"
    docker compose -f docker-compose.dev.yml ps 2>/dev/null || echo "Docker Compose未运行"
    echo ""

    # TB健康检查
    echo -e "${BLUE}TB服务:${NC}"
    local health=$(curl -s "$TB_URL/api/noauth/health" 2>/dev/null || echo "无法连接")
    if echo "$health" | grep -q "status"; then
        echo "  状态: 运行中"
    else
        echo "  状态: 未运行或无法连接"
    fi
    echo ""

    # 显示已保存的配置
    if [ -f "$OUTPUT_FILE" ]; then
        echo -e "${BLUE}已保存配置:${NC}"
        cat "$OUTPUT_FILE" | grep -E "^(TEST_|RULE_)" | sed 's/^/  /'
    fi
    echo ""
}

# 仅配置（TB已运行时使用）
config_only() {
    echo ""
    echo "=========================================="
    echo "ThingsBoard 配置（仅配置模式）"
    echo "=========================================="
    echo ""

    # 检查TB是否运行
    local health=$(curl -s "$TB_URL/api/noauth/health" 2>/dev/null || echo "")
    if [ -z "$health" ]; then
        log_error "ThingsBoard未运行，请先启动: ./start-tb-dev.sh"
        exit 1
    fi

    get_token || exit 1
    configure_rule_chain
    create_device_profile
    create_test_device
    save_config
    show_info
}

# 主流程
main() {
    echo ""
    echo "=========================================="
    echo "ThingsBoard 开发环境一键启动"
    echo "=========================================="
    echo ""

    # 检查Docker
    if ! command -v docker &> /dev/null; then
        log_error "Docker未安装，请先安装Docker"
        exit 1
    fi

    # 执行各步骤
    start_thingsboard || exit 1
    get_token || exit 1
    configure_rule_chain
    create_device_profile
    create_test_device
    save_config
    show_info
}

# 命令行参数处理
case "$1" in
    -h|--help)
        echo "用法: $0 [命令]"
        echo ""
        echo "命令:"
        echo "  (无参数)    启动TB并配置所有组件"
        echo "  config      仅配置（TB已运行时使用）"
        echo "  stop        停止ThingsBoard"
        echo "  restart     重启ThingsBoard"
        echo "  logs        查看日志"
        echo "  status      查看状态"
        echo "  -h, --help  显示帮助信息"
        echo ""
        exit 0
        ;;
    stop)
        log_info "停止 ThingsBoard..."
        docker compose -f docker-compose.dev.yml down
        exit 0
        ;;
    restart)
        log_info "重启 ThingsBoard..."
        docker compose -f docker-compose.dev.yml restart
        exit 0
        ;;
    logs)
        docker compose -f docker-compose.dev.yml logs -f thingsboard
        exit 0
        ;;
    status)
        show_status
        exit 0
        ;;
    config)
        config_only
        exit 0
        ;;
    *)
        main
        ;;
esac
