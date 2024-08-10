MPV

# 主配置文件

* 文件 `mpv.conf`
* TODO [配置参考](https://github.com/hooke007/MPV_lazy)

# 脚本 scripts

## 处理一些 mpv:// 开头的播放地址

* 文件 `scripts/mpv_url_scheme.lua`
* options `script-opts/mpv_url_scheme.conf`
    - `protocols` 支持的 `mpv://` 协议
        + https://github.com/akiirui/mpv-handler
        + https://github.com/LuckyPuppy514/Play-With-MPV
        + https://github.com/SilverEzhik/mpv-msix
        + https://github.com/Baldomo/open-in-mpv
        + mpv://https://url.com/path/to/video.m3u8
    - `cookies_path` 指定 cookies 文件的寻找路径
* Register the `mpv://` scheme with XDG
    - `applications/mpv-url.desktop`
    - `xdg-mime default mpv-url.desktop x-scheme-handler/mpv`

## 自动加载 bilibili 弹幕

* 文件 `scripts/danmuku.lua`
* options `script-opts/danmuku.conf`
    - `cache_dir`
    - `bin_path`
    - `websites`
    - `download`
    - `convert`
    - `filter_file`
