#!/bin/bash

# SPMS 一键部署脚本
# 包含网络错误容错处理

clone_or_update_repo() {
    local repo_url="$1"
    local target_dir="$2"

    if [ -d "$target_dir/.git" ]; then
        echo "仓库 $target_dir 已存在，尝试更新..."
        if (cd "$target_dir" && git pull --rebase --autostash); then
            echo "仓库 $target_dir 更新成功"
        else
            echo "警告: 更新 $target_dir 失败，尝试强制同步远程分支..."
            if (cd "$target_dir" && git fetch --all && git reset --hard origin/HEAD); then
                echo "仓库 $target_dir 强制同步成功"
            else
                echo "错误: 无法更新仓库 $target_dir"
                return 1
            fi
        fi
    else
        echo "正在克隆仓库 $repo_url 到 $target_dir ..."
        git clone "$repo_url" "$target_dir" || return 1
        echo "仓库 $target_dir 克隆完成"
    fi
}

download_node_archive() {
    local url="$1"
    local output="$2"

    echo "正在下载 Node.js 归档: $url"
    if command -v curl &> /dev/null; then
        echo "使用 curl 下载"
        curl -fsSL "$url" -o "$output"
    else
        echo "使用 wget 下载"
        wget -qO "$output" "$url"
    fi
}

node_download_arch() {
    local arch="$1"
    case "$arch" in
        x86_64|amd64) printf 'x64' ;;
        aarch64|arm64) printf 'arm64' ;;
        armv7l) printf 'armv7l' ;;
        ppc64le) printf 'ppc64le' ;;
        s390x) printf 's390x' ;;
        *) printf '%s' "$arch" ;;
    esac
}

try_use_nvm_node() {
    local nvm_dir="${NVM_DIR:-$HOME/.nvm}"
    local node_bin

    echo "尝试从 NVM 安装目录查找 node: $nvm_dir"
    if [ -d "$nvm_dir/versions/node" ]; then
        node_bin="$(find "$nvm_dir/versions/node" -type f -path '*/bin/node' 2>/dev/null | sort | head -n 1)"
        if [ -n "$node_bin" ] && [ -x "$node_bin" ]; then
            echo "找到 NVM 中的 node: $node_bin"
            export PATH="$(dirname "$node_bin"):$PATH"
            return 0
        fi
    fi

    echo "未在 NVM 目录中找到可用的 node"
    return 1
}

get_latest_node_archive() {
    local platform="$1"
    local arch="$2"
    local index_url="https://nodejs.org/dist/latest/SHASUMS256.txt"
    local list

    if command -v curl &> /dev/null; then
        list="$(curl -fsSL "$index_url")"
    else
        list="$(wget -qO- "$index_url")"
    fi

    printf '%s\n' "$list" | grep "node-v.*-${platform}-${arch}\.tar\.xz" | head -1 | awk '{print $2}'
}

ensure_node() {
    local node_version="24.14.0"
    local install_dir="$HOME/.local/node-v${node_version}"
    local arch
    local node_arch
    local platform

    if node -v > /dev/null 2>&1; then
        echo "检测到系统已安装 Node.js: $(node -v 2>/dev/null)"
        return 0
    fi

    echo "未在当前 PATH 中检测到 node，尝试使用 NVM 安装路径"
    if try_use_nvm_node; then
        echo "已使用 NVM 的 node: $(node -v 2>/dev/null)"
        return 0
    fi

    arch=$(uname -m)
    node_arch="$(node_download_arch "$arch")"
    case "$(uname -s)" in
        Linux) platform="linux" ;;
        Darwin) platform="darwin" ;;
        *) platform="$(uname -s | tr '[:upper:]' '[:lower:]')" ;;
    esac

    if [ -d "$install_dir" ] && [ -x "$install_dir/bin/node" ]; then
        echo "检测到本地安装目录 Node.js: $install_dir"
        export PATH="$install_dir/bin:$PATH"
        return 0
    fi

    echo "未检测到 Node.js，准备安装 Node.js v${node_version}..."
    echo "检测到平台: $platform，架构: $node_arch"
    if ! command -v curl &> /dev/null && ! command -v wget &> /dev/null; then
        echo "错误: 未检测到 curl 或 wget，无法下载 Node.js"
        return 1
    fi

    local archive_name="node-v${node_version}-${platform}-${node_arch}.tar.xz"
    local download_url="https://nodejs.org/dist/v${node_version}/${archive_name}"
    local tmpfile
    local downloaded_version="$node_version"

    tmpfile="$(mktemp)"

    if ! download_node_archive "$download_url" "$tmpfile"; then
        echo "警告: 下载 Node.js v${node_version} 失败，尝试下载最新 Node.js..."
        local latest_archive
        latest_archive="$(get_latest_node_archive "$platform" "$node_arch")"
        if [ -z "$latest_archive" ]; then
            echo "错误: 无法获取最新 Node.js 下载链接"
            rm -f "$tmpfile"
            return 1
        fi

        echo "已找到最新 Node.js 归档: $latest_archive"
        archive_name="$latest_archive"
        download_url="https://nodejs.org/dist/latest/${archive_name}"
        install_dir="$HOME/.local/${archive_name%.tar.xz}"

        if ! download_node_archive "$download_url" "$tmpfile"; then
            echo "错误: 下载最新 Node.js 失败"
            rm -f "$tmpfile"
            return 1
        fi
        downloaded_version="latest"
    fi

    echo "正在解压 Node.js 归档到 $HOME/.local"
    tar -xJf "$tmpfile" -C "$HOME/.local" || { echo "错误: 解压 Node.js 失败"; rm -f "$tmpfile"; return 1; }
    rm -f "$tmpfile"

    echo "移动解压后的 Node.js 目录到 $install_dir"
    mv "$HOME/.local/${archive_name%.tar.xz}" "$install_dir" 2>/dev/null || true
    export PATH="$install_dir/bin:$PATH"

    if node -v > /dev/null 2>&1; then
        echo "Node.js ${downloaded_version} 已安装到 $install_dir"
        return 0
    fi

    echo "错误: Node.js 安装完成后仍无法找到 node"
    return 1
}

install_web_dependencies() {
    local target_dir="$1"

    echo "准备安装 $target_dir 的前端依赖"
    if [ ! -f "$target_dir/package.json" ]; then
        echo "跳过依赖安装：$target_dir/package.json 不存在"
        return 0
    fi

    ensure_node || return 1

    if ! command -v npm &> /dev/null; then
        echo "错误: 未检测到 npm，请先安装 Node.js/npm"
        return 1
    fi

    echo "当前 npm 路径: $(command -v npm 2>/dev/null)"
    echo "正在为 $target_dir 运行 npm install..."
    if (cd "$target_dir" && npm install); then
        echo "依赖安装完成：$target_dir"
    else
        echo "错误: $target_dir 依赖安装失败"
        return 1
    fi
}

clone_or_update_repo "https://github.com/610643819/SPMS-Web.git" "SPMS-Web" || exit 1
# install_web_dependencies "SPMS-Web" || exit 1
echo "跳过 SPMS-Web 前端依赖安装，继续后续部署。"

# SPMS-Server 仅在 docker-compose 中被引用，旧目录名可能为 SPMS-Serve。
if [ ! -d "SPMS-Server/.git" ] && [ -d "SPMS-Serve/.git" ]; then
    echo "检测到旧目录 SPMS-Serve，重命名为 SPMS-Server"
    mv "SPMS-Serve" "SPMS-Server"
fi

clone_or_update_repo "https://github.com/610643819/SPMS-Serve.git" "SPMS-Server" || exit 1

echo "开始部署SPMS系统..."

# 检查Docker是否安装
if ! command -v docker &> /dev/null
then
    echo "错误: 未检测到Docker，请先安装Docker"
    exit 1
fi

# 检查Docker Compose是否安装
if ! command -v docker-compose &> /dev/null
then
    echo "错误: 未检测到Docker Compose，请先安装Docker Compose"
    exit 1
fi

echo "正在停止并删除已存在的容器..."
docker-compose down

# 检查是否需要清理数据库卷（通过参数传递）
if [ "$1" = "--clean" ]; then
    echo "清理数据库和Redis数据卷..."
    docker-compose down -v
fi

# 拉取镜像（带重试机制和国内镜像源）
pull_image_with_retry() {
    local image=$1
    local retries=3
    local count=0
    
    until [ $count -ge $retries ]
    do
        echo "正在拉取镜像: $image (尝试 $((count+1))/$retries)"
        if docker pull $image; then
            echo "成功拉取镜像: $image"
            return 0
        else
            count=$((count+1))
            if [ $count -ge $retries ]; then
                echo "警告: 拉取镜像失败 $retries 次，尝试使用国内镜像源..."
                # 使用国内镜像源重试
                case $image in
                    "mysql:8.0")
                        if docker pull registry.docker-cn.com/mysql:8.0; then
                            docker tag registry.docker-cn.com/mysql:8.0 mysql:8.0
                            echo "成功使用国内镜像源拉取: $image"
                            return 0
                        fi
                        ;;
                    "redis:7-alpine")
                        if docker pull registry.docker-cn.com/redis:7-alpine; then
                            docker tag registry.docker-cn.com/redis:7-alpine redis:7-alpine
                            echo "成功使用国内镜像源拉取: $image"
                            return 0
                        fi
                        ;;
                    "node:20-alpine")
                        if docker pull registry.docker-cn.com/node:20-alpine; then
                            docker tag registry.docker-cn.com/node:20-alpine node:20-alpine
                            echo "成功使用国内镜像源拉取: $image"
                            return 0
                        fi
                        ;;
                    "nginx:alpine")
                        if docker pull registry.docker-cn.com/nginx:alpine; then
                            docker tag registry.docker-cn.com/nginx:alpine nginx:alpine
                            echo "成功使用国内镜像源拉取: $image"
                            return 0
                        fi
                        ;;
                    "maven:3.9.6-amazoncorretto-17")
                        if docker pull registry.cn-hangzhou.aliyuncs.com/zhuyali/maven:3.9.6-amazoncorretto-17; then
                            docker tag registry.cn-hangzhou.aliyuncs.com/zhuyali/maven:3.9.6-amazoncorretto-17 maven:3.9.6-amazoncorretto-17
                            echo "成功使用国内镜像源拉取: $image"
                            return 0
                        fi
                        ;;
                    "amazoncorretto:17-alpine")
                        if docker pull registry.cn-hangzhou.aliyuncs.com/zhuyali/amazoncorretto:17-alpine; then
                            docker tag registry.cn-hangzhou.aliyuncs.com/zhuyali/amazoncorretto:17-alpine amazoncorretto:17-alpine
                            echo "成功使用国内镜像源拉取: $image"
                            return 0
                        fi
                        ;;
                esac
                
                echo "错误: 无法拉取镜像 $image"
                return 1
            else
                echo "拉取失败，等待10秒后重试..."
                sleep 10
            fi
        fi
    done
}

# 预拉取基础镜像（可选步骤，提高成功率）
echo "预拉取基础镜像..."
pull_image_with_retry "mysql:8.0" || echo "MySQL镜像拉取失败，将在构建时重试"
pull_image_with_retry "redis:7-alpine" || echo "Redis镜像拉取失败，将在构建时重试"
pull_image_with_retry "node:20-alpine" || echo "Node镜像拉取失败，将在构建时重试"
pull_image_with_retry "nginx:alpine" || echo "Nginx镜像拉取失败，将在构建时重试"
pull_image_with_retry "maven:3.9.6-amazoncorretto-17" || echo "Maven镜像拉取失败，将在构建时重试"
pull_image_with_retry "amazoncorretto:17-alpine" || echo "Amazon Corretto镜像拉取失败，将在构建时重试"

echo "开始构建并启动所有服务..."
# 使用分步构建方式提高成功率
echo "1. 构建服务镜像..."
if docker-compose build; then
    echo "服务镜像构建成功！"
else
    echo "服务镜像构建失败，请检查错误日志"
    echo "尝试使用 --parallel 参数重新构建..."
    if docker-compose build --parallel; then
        echo "服务镜像并行构建成功！"
    else
        echo "服务镜像并行构建也失败了"
        exit 1
    fi
fi

echo "2. 启动所有服务..."
if docker-compose up -d; then
    echo "服务启动成功！"
else
    echo "服务启动失败，请检查错误日志"
    echo "查看详细日志请运行: docker-compose logs"
    exit 1
fi

# 等待服务启动
echo "等待服务启动..."
sleep 20

# 检查各服务状态
echo "检查服务状态:"
docker-compose ps

echo ""
echo "部署完成！"
echo "访问地址:"
echo "  前端页面: http://localhost:80"
echo "  后端API:  http://localhost:8080"
echo "  数据库:   localhost:3306"
echo "  Redis:    localhost:6379"
echo ""
echo "默认数据库用户: spms / spms"
echo "默认数据库root用户: root / root"