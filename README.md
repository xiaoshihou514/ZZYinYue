# 自在音乐
<div align="center">
<img width="30%" src="https://github.com/user-attachments/assets/6d086d7a-9792-41ce-ad1c-269ca6a180cc" />
</div>

<img width="100%" align="center" src="https://github.com/user-attachments/assets/3c14b872-eb75-42a6-be29-08842bc9edee" />

Linux TUI音乐播放器

AI拉的，别用。

## 核心特性

- 异步音乐库扫描
- 基于作者／ 专辑／文件夹的播放列表
- 简单搜索
- 队列播放（单曲循环、列表循环、随机播放模式）

## 环境要求

- Zig 语言版本：`0.15.2`
- 系统依赖库：
  - `sqlite3`
  - `mpv`
  - `libavformat`, `libavcodec`, `libavutil`（一般和ffmpeg捆绑）

## 构建与运行

```bash
zig build          # 构建项目
zig build run      # 构建并运行
zig build test     # 运行测试
```

- 配置文件：`$XDG_CONFIG_HOME/zzyinyue/config.toml`
- 缓存目录：`$XDG_CACHE_HOME/zzyinyue/`
- 数据文件：`$XDG_DATA_HOME/zzyinyue/library.sqlite3`
- 状态文件：`$XDG_STATE_HOME/zzyinyue/session.json`

首次运行时，程序会自动生成默认的 `config.toml` 配置文件。
