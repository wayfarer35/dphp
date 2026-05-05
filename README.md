# dphp — 预构建开箱即用的全量扩展 PHP Docker 镜像

预构建开箱即用的全量扩展 PHP Docker Image。

## 为什么

- 操作系统一般只维护一个主要的 PHP 版本，需要多版本 PHP 时很麻烦
- 不同 PHP 版本安装扩展需要的依赖不同，容易冲突，需要隔离环境
- 由于一些原因，安装扩展经常失败，特别是pecl扩展的安装
- 预构建一个包含全量扩展的 PHP 镜像，使用时通过环境变量控制扩展的启用/禁用，减少安装扩展遇到的各种麻烦


> **注意：  
> 由于有的扩展会有冲突，有的扩展太大但使用频率低，全量扩展并不能囊括所有扩展，具体查看extensions下的配置。  
> 镜像体积会显著增加，不应该在生产环境中使用。**   

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
> `-v` 现在用于**详细日志输出**；例如 `./build.sh 8.4 -v`。同时也兼容 `./build.sh -v 8.4` 这种写法。

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
| `-p, --php-version <ver>` | 用选项形式指定 PHP 版本，作用等同于位置参数 |
| `-v, --verbose` | 输出详细构建日志；默认不开启，以避免日志过长被截断 |
| `-i, --image <name>` | 自定义镜像名/仓库名，例如 `wayfarer35/dphp`，最终生成 `wayfarer35/dphp:<version>` |
| `-t, --tag <full_tag>` | 直接指定完整 tag，例如 `wayfarer35/dphp:8.4` |
| `--extensions="a b c"` | 显式指定要安装的扩展（覆盖自动选择） |
| `--exclude="a b c"` | 从默认列表中排除指定扩展 |
| `--include="a b c"` | 强制包含默认不安装列表中的扩展 |
| `-d, --dry-run` | 仅打印构建命令，不执行 |
| `--fail-on-generate` | 扩展数据生成失败时报错退出（CI 场景） |

### 构建示例

```bash
# 构建 PHP 8.4 镜像（包含默认的完整扩展集）
./build.sh 8.4

# 输出详细实时日志（调试 PECL / 网络问题时再开）
./build.sh 8.4 -v

# 只安装特定扩展
./build.sh 8.4 --extensions="pdo_mysql redis gd"

# 排除某些扩展
./build.sh 8.4 --exclude="xdebug xhprof"

# 构建为 Docker Hub 目标仓库 tag
./build.sh 8.4 --image wayfarer35/dphp

# 或直接指定完整 tag
./build.sh 8.4 --tag wayfarer35/dphp:8.4

# 预览构建命令
./build.sh 8.4 --dry-run
```

默认情况下，构建完成后的镜像标签格式为 `dphp:<version>`，例如 `dphp:8.4`。

如果要直接推送到 Docker Hub，可以在构建时指定：

```bash
./build.sh 8.4 --image wayfarer35/dphp
docker push wayfarer35/dphp:8.4
```

或者直接指定完整 tag：

```bash
./build.sh 8.4 --tag wayfarer35/dphp:8.4
docker push wayfarer35/dphp:8.4
```

> 如果当前环境不允许脚本自动使用 `sudo`，请直接手动运行：
>
> ```bash
> sudo ./build.sh 8.4 --image wayfarer35/dphp
> ```
>
> 或者先将当前用户加入 `docker` 组；在 Fedora 等环境里，也可以用：
>
> ```bash
> DOCKER_CMD=podman ./build.sh 8.4 --image wayfarer35/dphp
> ```

### 日志输出控制 / 避免输出被截断

默认情况下，`build.sh` 会采用**精简控制台输出**，并将完整日志写到：

```bash
.build-logs/
```

这样可以减少在 Docker / GitHub Actions 中出现：

```text
[output clipped, log limit 2MiB reached]
```

如果你正在排查某个扩展、PECL 下载失败或网络问题，再加 `-v` 输出详细实时日志：

```bash
./build.sh 8.4 -v
```

在 GitHub Actions 手动触发时，也可以把 `verbose` 选项切换为 `true`；平时建议保持默认的 `false`，避免日志过长导致真正错误信息被截断。

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

启用某些扩展时，入口脚本会一并打开它们的运行时依赖；例如 `redis` 会自动补上 `igbinary` 和 `msgpack`。

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

