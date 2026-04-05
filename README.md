# dphp — 预构建多扩展 PHP Docker 镜像

构建包含尽可能多扩展的各版本 PHP Docker 镜像。

## 为什么

- 系统一般只支持一个主要的 PHP 版本，需要多版本 PHP 时很麻烦
- 不同 PHP 版本安装扩展需要的依赖不同，受限于网络等原因每次都 build 会很慢甚至失败
- 预构建一个尽可能包含所有支持扩展的 PHP 镜像，使用时通过环境变量控制扩展的启用/禁用
- 镜像体积会大一些，但换来的是开发环境的极大便利

> **注意：本镜像为开发环境设计，生产环境应该只安装需要的扩展。**

## 支持的 PHP 版本

| PHP 版本 | 基础系统 |
|----------|----------|
| 8.5 | bookworm |
| 8.4 | bookworm |
| 8.3 | bookworm |
| 8.2 | bookworm |
| 8.1 | bookworm |
| 8.0 | bullseye |
| 7.4 | bullseye |
| 7.3 | bullseye |
| 7.2 | buster |
| 7.1 | stretch |
| 7.0 | stretch |
| 5.6 | stretch |
| 5.5 | — |

## 构建镜像


### 构建命令

```bash
./build.sh <php_version> [options]
```

> 默认推荐直接使用第一个参数传版本号，例如 `./build.sh 8.4`。
> 同时也兼容旧写法 `./build.sh -v 8.4`。

**必需参数：**

| 参数 | 说明 |
|------|------|
| `<version>` | PHP 版本，如 `8.4`, `7.4` |

### 更新扩展数据（可选）

如果扩展数据文件不存在，`build.sh` 会自动调用 `./generate-extension-raw.sh` 生成。
只有在你想**手动刷新到最新数据**时，才需要执行下面命令：

```bash
# 从 mlocati/docker-php-extension-installer 获取最新扩展数据
./generate-extension-raw.sh

# 强制从远程刷新
./generate-extension-raw.sh --force-download
```

**可选参数：**

| 参数 | 说明 |
|------|------|
| `--extensions="a b c"` | 显式指定要安装的扩展（覆盖自动选择） |
| `--exclude="a b c"` | 从默认列表中排除指定扩展 |
| `--include="a b c"` | 强制包含默认不安装列表中的扩展 |
| `-d, --dry-run` | 仅打印构建命令，不执行 |
| `--fail-on-generate` | 扩展数据生成失败时报错退出（CI 场景） |

### 构建示例

```bash
# 构建 PHP 8.4 镜像（包含默认的完整扩展集）
./build.sh 8.4

# 只安装特定扩展
./build.sh 8.4 --extensions="pdo_mysql redis gd"

# 排除某些扩展
./build.sh 8.4 --exclude="xdebug xhprof"

# 预览构建命令
./build.sh 8.4 --dry-run
```

构建完成后镜像标签格式为 `dphp:<version>`，例如 `dphp:8.4`。

## 使用镜像

镜像入口脚本通过 `EXTENSION_<NAME>=1` 环境变量控制启用哪些扩展。

### 三种使用模式「方案选单」

#### 1. php-fpm 模式（默认）

不传任何命令参数时，容器默认启动 `php-fpm`，适用于配合 nginx 的 Web 应用：

```bash
docker run -d \
  -e EXTENSION_PDO_MYSQL=1 \
  -e EXTENSION_REDIS=1 \
  -e EXTENSION_GD=1 \
  -v $(pwd)/src:/www \
  -p 9000:9000 \
  dphp:8.4
```

#### 2. php-cli 模式

传入命令参数覆盖默认行为，用于执行脚本、Composer、单元测试等：

```bash
# 进入交互式 shell
docker run -it --rm \
  -v $(pwd)/src:/www \
  dphp:8.4 \
  /bin/bash

# 执行 PHP 脚本
docker run --rm \
  -e EXTENSION_PDO_MYSQL=1 \
  -v $(pwd)/src:/www \
  dphp:8.4 \
  php /www/script.php

# 运行 Composer
docker run --rm \
  -v $(pwd)/src:/www \
  dphp:8.4 \
  composer install

# 运行 PHPUnit
docker run --rm \
  -e EXTENSION_PDO_SQLITE=1 \
  -v $(pwd)/src:/www \
  dphp:8.4 \
  php /www/vendor/bin/phpunit
```

#### 3. php-serve 模式

用于常驻后台进程，如 Swoole、Workerman、Laravel Octane、PHP 内置服务器等：

```bash
# Swoole HTTP Server
docker run -d \
  -e EXTENSION_SWOOLE=1 \
  -e EXTENSION_PDO_MYSQL=1 \
  -v $(pwd)/src:/www \
  -p 9501:9501 \
  dphp:8.4 \
  php /www/server.php

# PHP 内置开发服务器
docker run -d \
  -e EXTENSION_PDO_MYSQL=1 \
  -v $(pwd)/src:/www \
  -p 8000:8000 \
  dphp:8.4 \
  php -S 0.0.0.0:8000 -t /www/public

# Workerman
docker run -d \
  -e EXTENSION_EVENT=1 \
  -v $(pwd)/src:/www \
  -p 8080:8080 \
  dphp:8.4 \
  php /www/start.php start
```

### Docker Compose 示例

查看 [examples/](examples/) 目录获取完整的 Docker Compose 配置示例：

- [examples/docker-compose.fpm.yml](examples/docker-compose.fpm.yml) — php-fpm + nginx
- [examples/docker-compose.cli.yml](examples/docker-compose.cli.yml) — php-cli 交互式 shell
- [examples/docker-compose.serve.yml](examples/docker-compose.serve.yml) — Swoole / Workerman / 内置服务器

## 扩展管理

### 构建时配置

- `extensions/default-not-install.conf` — 默认不安装的扩展列表，可通过 `--include` 强制包含
- `extensions/conflicts.conf` — 冲突规则，格式 `preferred:conflict`，自动去除冲突扩展

### 运行时启用

通过环境变量 `EXTENSION_<NAME>=1` 启用扩展，扩展名全大写，非字母数字用 `_` 替换：

```bash
EXTENSION_PDO_MYSQL=1
EXTENSION_REDIS=1
EXTENSION_GD=1
EXTENSION_INTL=1
```

## 项目结构

```
dphp/
├── Dockerfile                    # 多阶段构建 PHP 镜像
├── build.sh                      # 构建脚本
├── docker-entrypoint.sh          # 容器入口脚本（扩展启用 + 进程启动）
├── generate-extension-raw.sh     # 扩展数据生成脚本
├── extensions/
│   ├── conflicts.conf            # 扩展冲突规则
│   └── default-not-install.conf  # 默认不安装列表
├── examples/
│   ├── docker-compose.fpm.yml    # php-fpm 使用示例
│   ├── docker-compose.cli.yml    # php-cli 使用示例
│   ├── docker-compose.serve.yml  # php-serve 使用示例
│   └── nginx.conf                # nginx 参考配置
├── LICENSE
└── README.md
```

## License

MIT

