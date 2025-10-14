--[[

Bilibili danmuku script for mpv

This script automatically downloads xml danmu from bilibili or fc.lyz05.cn,
converts to ass, then loads ass as sub-ass or subtitles in mpv.

To configure this script use file danmuku.conf in directory script-opts
(the "script-opts" directory must be in the mpv configuration directory,
typically ~/.config/mpv/).
Example configuration: see danmuku.conf

# Ref:
1. https://mpv.io/manual/master/#lua-scripting
2. https://github.com/itKelis/MPV-Play-BiliBili-Comments
3. https://github.com/hihkm/DanmakuFactory
4. https://github.com/lyz05/danmaku
5. https://github.com/HFrost0/danmakuC
6. https://github.com/HFrost0/bilix/blob/0239d332472eb496a865b2117d1c8b4e93a8b19a/bilix/sites/bilibili/api.py#L563-L568
7. https://github.com/jnxyp/Bilibili-Block-List

Copyright (c) 2024-2025 shmilee
Licensed under GNU General Public License v2:
https://opensource.org/licenses/GPL-2.0

--]]

local utils = require("mp.utils")
local opts = require("mp.options")
local msg = require("mp.msg")
local osd_msg = mp.osd_message
local strfmt = string.format

-- 兼容 luajit
table.unpack = table.unpack or unpack

-- debug {{{
package.path = strfmt('%s;%s', package.path, mp.command_native({"expand-path", '~~home/scripts/?.lua'}))
local inspectloaded, inspect = pcall(require, 'inspect')
if not inspectloaded then
    inspect = utils.to_string
end
local function debug_kv(k ,v)
    if type(v) ~= 'string' then
        -- table: ARRAY or MAP; boolean; number
        msg.warn(strfmt('-> type(%s)=%s, %s=%s', k, type(v), k, inspect(v)))
    else
        msg.warn(strfmt('-> %s=%s', k, v))
    end
end  -- }}}

local o = {
    enable = true,
    toggle_key_binding = '',  -- for ass Loader:toggle()
    -- ~/.config/mpv/danmuku-data/bin/
    bin_path = '~~home/danmuku-data/bin/:~/.local/bin/:/usr/bin/',
    -- ~/.config/mpv/danmuku-data/cache/,
    -- or ~/.cache/mpv/, utils.split_path(os.tmpname())
    cache_dir = '~~home/danmuku-data/cache/',
    -- setting for curl
    curl_timeout = 25.0,  -- 下载单次超时时间 (默认 25秒)
    curl_retries = 3,     -- 下载重试次数
    -- setting for ass
    resolution = 'auto',  -- 屏幕分辨率 (自动取值) auto: like 1920x1080
    reserve = 0.3,  -- 保留底部多少高度的空白区域 0-1 (默认 0.3)
    fontname = mp.get_property('sub-font'),  -- 弹幕字体 (默认 sans-serif)
    fontsize = 38,  -- 字体大小 (默认 38 像素)
    fontshadow = 1, -- 字体阴影深度 0-4  (默认 1)
    alpha = 0.95,   -- 弹幕不透明度 0-1 (默认 0.95)
    duration_marquee = 12.0,  -- 滚动弹幕显示的持续时间 (默认 12秒)
    duration_still = 5.0,  -- 静止弹幕显示的持续时间 (默认 5秒)
    filter_file = '~~home/danmuku-data/share/BBL.txt',  -- 弹幕屏蔽文件路径
}
opts.read_options(o, 'danmuku')
-- debug_kv('o', o)

local myutil = {
    platform = mp.get_property('platform', ''),
    file_exists = function(path)
        local info, err = utils.file_info(path)
        return info and info.is_file
    end,
    dir_exists = function(path)
        local info, err = utils.file_info(path)
        return info and info.is_dir
    end,
    -- searching filename in directories `dpaths`
    -- The dpaths can be splited by ':', for example o.bin_path
    search_file = function(dpaths, filename)
        for d in string.gmatch(dpaths, "([^:]+)") do
            if d:match('^~') then
                d = mp.command_native({"expand-path", d})
            end
            local path = utils.join_path(d, filename)
            msg.verbose('Searching file: '.. path)
            local info, err = utils.file_info(path)
            if info and info.is_file then
                return path
            end
        end
    end,
    sub_count = function()
        local count  = 0
        local tracks = mp.get_property_native("track-list")
        for _, track in ipairs(tracks) do
            if track["type"] == "sub" then
                count = count + 1
            end
        end
        return count
    end,
    -- Log function: log to both terminal and MPV OSD (On-Screen Display)
    log = function(str, time)
        time = time or 2.5
        msg.info(str)
        osd_msg(str, time)
    end,
    get_width_height = function()
        local dw, dh = string.match(o.resolution, '(%d+)x(%d+)')
        if dw and dh then
            dw, dh = tonumber(dw), tonumber(dh)
        elseif o.resolution == 'auto' then
            dw = mp.get_property_number('display-width', 1920)
            dw = math.min(3840, math.max(1920, dw))
            dh = mp.get_property_number('display-height', 1080)
            dh = math.min(2160, math.max(1080, dh))
        end
        local w = mp.get_property_number('width', 16)
        local h = mp.get_property_number('height', 9)
        local aspect = w / h
        if aspect > dw / dh then
            dh = math.floor(dw / aspect)
        elseif aspect < dw / dh then
            dw = math.floor(dh * aspect)
        end
        msg.verbose(strfmt('Video aspect=%s, width=%s, height=%s', aspect, dw, dh))
        return dw, dh
    end,
    get_val_from_kvstr = function(kvstr, site)
        -- kvstr, like 'site1=v1;site2=v2'
        for kv in string.gmatch(kvstr, "([^;]+)") do
            local k, v = string.match(kv, '([%w_]+)=(.*)')
            if k == site then
                return v
            end
        end
    end,
    -- callback(success, result, err)
    -- success: boolean  - 命令是否成功执行
    -- result: table|nil - 成功时的结果（包含status, stdout, stderr等）
    -- err: string|nil   - 错误时的错误信息
    async_run = function(args, callback)
        return mp.command_native_async({
            name = 'subprocess',
            playback_only = false,
            capture_stdout = true,
            args = args,
        }, callback)
    end,
    toBase36 = function(num, base)
        if base == nil or base < 2 or base > 36 then
            base = 36
        end
        local digits = "0123456789abcdefghijklmnopqrstuvwxyz"
        local result = ""
        while num > 0 do
            local remainder = num % base
            result = digits:sub(remainder + 1, remainder + 1) .. result
            num = math.floor(num / base)
        end
        return result == "" and "0" or result
    end,
}

myutil.ensure_dir = function(path)
    local dir = utils.split_path(path)
    if dir == '' then return true end
    -- 目录不存在则创建，os.execute 耗时短，无须异步
    if not myutil.dir_exists(dir) then
        local cmd
        if myutil.platform == 'windows' then
            cmd = string.format('mkdir "%s"', dir:gsub('/', '\\'))
        else
            cmd = string.format('mkdir -p "%s"', dir)
        end
        msg.info('Making dir by:', cmd)
        os.execute(cmd)
    end
    return true
end

myutil.get_cache_path = function(...)
    local names = {...}
    local base_path = o.cache_dir
    if o.cache_dir:match('^~') then
        base_path = mp.command_native({"expand-path", o.cache_dir})
    end
    local full_path = base_path
    for _, name in ipairs(names) do
        full_path = utils.join_path(full_path, name)
    end
    myutil.ensure_dir(full_path)  -- 确保目录存在
    return full_path
end


-- curl settings and utils
local Curl = {
    default_settings = {
        silent = true,      -- -s 静默模式
        show_error = true,  -- -S 在静默模式下显示错误
        follow_redirects = true,  -- -L 跟随重定向
        fail_fast = true,   -- 快速失败，遇到 HTTP 错误不输出任何内容
        compressed = false, -- 支持压缩响应，并自动解压内容
        continue = false,   -- 断点续传，多数弹幕网站不支持
        timeout = o.curl_timeout,  -- 超时时间(秒)
        method = "GET",     -- 请求方法(GET/POST)
        user_agent = nil,   -- 自定义User-Agent
        headers = {},       -- 自定义请求头
        retries = o.curl_retries,  -- 重试次数
        retry_delay = 1.0   -- 重试延迟(秒) + math.random()
    },
    -- 必须有 args.output args.url
    build_args = function(args)
        local cmd
        if myutil.platform == 'windows' then
            cmd = myutil.search_file(o.bin_path, 'curl.exe')
        else
            cmd = myutil.search_file(o.bin_path, 'curl')
        end
        if cmd == nil then
            msg.warn('Not found curl command!')
            return
        end
        local curl_args = {cmd}
        -- 基本参数
        if args.silent then table.insert(curl_args, "-s") end
        if args.show_error then table.insert(curl_args, "-S") end
        if args.follow_redirects then table.insert(curl_args, "-L") end
        if args.fail_fast then table.insert(curl_args, "-f") end
        if args.compressed then table.insert(curl_args, "--compressed") end
        if args.continue then
            table.insert(curl_args, "-C")
            table.insert(curl_args, "-") -- automatically find offset
        end
        if args.timeout then 
            table.insert(curl_args, "-m")
            table.insert(curl_args, tostring(args.timeout))
        end
        if args.method and args.method ~= "GET" then -- 请求方法（如果不是GET）
            table.insert(curl_args, "-X")
            table.insert(curl_args, args.method)
        end
        if args.data then -- POST数据（只有在显式设置时才添加）
            table.insert(curl_args, "-d")
            table.insert(curl_args, args.data)
        end
        if args.user_agent then -- User-Agent
            table.insert(curl_args, "-A")
            table.insert(curl_args, args.user_agent)
        end
        for _, header in ipairs(args.headers or {}) do -- 自定义请求头
            table.insert(curl_args, "-H")
            table.insert(curl_args, header)
        end
        -- 输出文件（必须）
        table.insert(curl_args, "-o")
        table.insert(curl_args, args.output)
        -- URL（必须）
        table.insert(curl_args, args.url)
        return curl_args
    end
}

-- callback(success, data, err), like definition in run_multiple_requests
Curl.run_request = function(request_args, callback)
    local args = {}
    -- 合并默认参数和请求特定参数
    for k, v in pairs(Curl.default_settings) do
        args[k] = request_args[k] ~= nil and request_args[k] or v
    end
    args.output = request_args.output
    args.url = request_args.url
    if not args.output or not args.url then
        if callback then callback(false, nil, "curl output or url not set") end        
        return
    end
    local curl_args = Curl.build_args(args)
    if not curl_args then
        if callback then callback(false, nil, "No curl args build") end        
        return
    end
    local retry_count = 0
    local function execute_request()
        msg.verbose("Executing curl: " .. table.concat(curl_args, " "))
        myutil.async_run(curl_args, function(success, result, err)
            local error_msg
            if success then
                if result.status == 0 then -- 命令成功执行，检查退出状态码
                    callback(true, result, nil)
                    return
                else -- 执行成功但返回错误状态码
                    retry_count = retry_count + 1
                    error_msg = result.stderr or "curl exited with status " .. result.status
                end
            else
                retry_count = retry_count + 1
                error_msg = err or "unknown error"
            end
            if retry_count < args.retries then
                msg.warn(strfmt("Request %s failed, retrying %d/%d: %s", args.url, retry_count, args.retries, error_msg))
                -- 延迟重试
                mp.add_timeout(args.retry_delay + math.random(), function() execute_request() end)
            else
                local final_err = strfmt("Request %s failed after %d retries: %s", args.url, args.retries, error_msg)
                msg.error(final_err)
                callback(false, nil, final_err)
            end
        end)
    end
    execute_request()
end

-- curl request_args = { output=, url=, callback=function end, other_settings... }
-- requests_list = { request_args, request_args, ... }
-- results = { {success=true or false, data=, err=, costime=}, ... }
-- final_callback(results)
Curl.run_multiple_requests = function(requests_list, final_callback)
    local results = {}
    local completed = 0
    local total = #requests_list
    if total == 0 then
        if final_callback then final_callback({}) end
        return
    end
    for i, request_args in ipairs(requests_list) do
        local startime = os.time()
        Curl.run_request(request_args, function(success, data, err)
            results[i] = {
                success = success, data = data, err = err,
                costime = os.time() - startime,
            }
            completed = completed + 1
            local status = success and "(success)" or " (failed)"
            msg.info(strfmt("Download completed %d/%d: %s %s", completed, total, status, request_args.url))
            if request_args.callback then -- 单个请求的回调（如果存在）
                request_args.callback(success, data, err)
            end
            -- 所有请求完成
            if completed == total and final_callback then
                final_callback(results)
            end
        end)
    end
end


-- DanmakuFactory settings and utils
local DanmakuFactory = {
    github = 'https://github.com/hihkm/DanmakuFactory',
    name = 'DanmakuFactory',
    get_args = function(inputs, output)
        inputs = inputs or {}
        local cmd
        if myutil.platform == 'windows' then
            cmd = myutil.search_file(o.bin_path, 'DanmakuFactory.exe')
        else
            cmd = myutil.search_file(o.bin_path, 'DanmakuFactory')
        end
        if cmd == nil then
            msg.warn('DanmakuFactory not found!')
            return
        end
        if output == nil then
            msg.warn('DanmakuFactory output not set!')
            return
        end
        if #inputs == 0 then
            msg.warn('DanmakuFactory inputs not set!')
            return
        end
        local dw, dh = myutil.get_width_height()
        local args = { cmd, '-o', output, '-i' }
        for _, input in ipairs(inputs) do
            table.insert(args, input)
        end
        for _, conf in ipairs({
                '-r', strfmt('%sx%s', dw, dh),
                '-s', tostring(o.duration_marquee),
                '-f', tostring(o.duration_still),
                '-N', o.fontname, '-S', tostring(o.fontsize),
                '-D', tostring(o.fontshadow),
                '-O', tostring(math.floor(o.alpha*255)),
                '--displayarea', tostring(1.0 - o.reserve),
                '-b', 'REPEAT', '-d', '-1', '--ignore-warnings',
                '--saveblocked', 'false',
            }) do
            table.insert(args, conf)
        end
        return args
    end
}

-- XML 转换为 ASS
-- callback(success, result, err)
DanmakuFactory.convert = function(xml_files, output_ass, callback)
    local args = DanmakuFactory.get_args(xml_files, output_ass)
    if not args then
        if callback then callback(false, nil, "No DanmakuFactory args") end
        return
    end
    msg.verbose('Converting XML to ASS using cmd = ' .. table.concat(args, " "))
    myutil.async_run(args, function(success, result, err)
        if success and result.status == 0 then
            msg.info("Successfully converted XML to ASS: " .. output_ass)
            if callback then callback(true, result, err) end
        else
            local error_msg = err or "DanmakuFactory conversion failed"
            if result and result.status ~= 0 then
                error_msg = error_msg .. " with status " .. result.status
            end
            if result and result.stderr and #result.stderr > 0 then
                error_msg = error_msg .. ": " .. result.stderr
            end
            msg.error(error_msg)
            if callback then callback(false, result, err) end
        end
    end)
end


-- Base danmu manager, provider curl args, xml urls & paths and assfile etc.
local DanmuManager = {
    name = 'Base Danmu Manager',
    match = function() return false end,
    create = function(cls)
        local this = cls:_new_()
        -- debug_kv(this.name, this)
        this:_init_()
        return this
    end,
    _new_ = function(cls)
        local this = setmetatable({
            xml_urls = {}, custom_curl_args = {},
            xml_files = {}, ass_file = '',
        }, { __index = cls })
        return this
    end,
    _init_ = function(self)
        return
    end,
}

-- Bilibili danmu manager
local Bilibili = setmetatable({
    name = 'Bilibili Danmu Manager',
    match = function()
        for _, path in pairs({
                mp.get_property("path", ''),
                mp.get_property("stream-open-filename", ''),
                }) do
            for _, patt in pairs({
                    'http[s]?://[%w%.-_]+%.bilibili.com',
                    'http[s]?://[%w%.-_]+%.bilivideo.com',
                    'http[s]?://[%w%.-_]+%.bilivideo.cn',
                    }) do
                if path:find(patt) then
                    msg.verbose(strfmt('Match path=[[[%s]]] by pattern="%s"', path, patt))
                    return true
                end
            end
        end
    end,
    _get_cid = function()
        local cid = nil
        local tracks = mp.get_property_native("track-list")
        for _, track in ipairs(tracks) do
            if track["lang"] == "danmaku" then
                cid = track["external-filename"]:match("/(%d-)%.xml$")
                local sid = track["id"]
                -- rm Subs  --sid=1 --slang=danmaku 'xml'
                if sid then
                    msg.verbose(strfmt('Remove danmaku xml sid=%s', sid))
                    mp.commandv('sub-remove', sid)
                end
                break
            end
        end
        if cid == nil then
            local pat = "bilivideo%.c[nom]+.*/(%d+)-%d+-%d+%.m4s%?"  -- com cn
            for _, path in pairs({
                    mp.get_property("path", ''),
                    mp.get_property("stream-open-filename", ''),
                    }) do
                if path:find(pat) then
                    cid = path:match(pat)
                    break
                end
            end
        end
        if cid == nil then
            msg.warn("Can't get comment id!")
        else
            msg.verbose(strfmt('Get comment id = %s', cid))
        end
        return cid
    end,
    _init_ = function(self)
        local cid = self._get_cid()
        -- https://github.com/SocialSisterYi/bilibili-API-collect/blob/cb4f767d4ee3f4f66b6caff04c9c40164ea4af54/docs/danmaku/danmaku_xml.md
        -- https://api.bilibili.com/x/v1/dm/list.so
        -- https://comment.bilibili.com/{{cid}}.xml
        if cid then
            self.cid = cid
            self.xml_urls = {
                strfmt('https://comment.bilibili.com/%s.xml', cid)
            }
            self.xml_files = {
                myutil.get_cache_path('bilibili', strfmt('bilibili-%s.xml', cid))
            }
            msg.verbose(strfmt('Setting danmu xml: %s -> %s', self.xml_urls[1], self.xml_files[1]))
            self.ass_file = myutil.get_cache_path('bilibili', strfmt('bilibili-%s.ass', cid))
            msg.verbose(strfmt('Setting danmu ass: %s', self.ass_file))
        end
        self.custom_curl_args = {
            compressed = true,
            user_agent = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36',
            headers = {
                "Referer: https://www.bilibili.com/",
            },
        }
    end,
}, { __index = DanmuManager })

-- 添加外部弹幕 xml URL, 如 https://fc.lyz05.cn/ 的弹幕接口
local external_danmaku_xmlurls = {}
-- 通过注册脚本消息，处理其他 mpv 脚本设置的 xml URL
mp.register_script_message("danmaku-xmlurl", function(url)
    msg.info("Received danmaku xml URL: " .. url)
    table.insert(external_danmaku_xmlurls, url)
end)

-- External danmaku manager
local ExternalDanmaku = setmetatable({
    name = 'External Danmaku Manager',
    match = function()
        if #external_danmaku_xmlurls > 0 then
            return true
        end
    end,
    -- 根据URL生成缓存文件的子目录和文件名，同时考虑 self.title
    _get_relative_xml_path = function(self, url)
        local subdir, identifier
        -- 提取实际视频URL（去掉前缀）
        local actual_url = url:match("url=([^&]+)") or url
        actual_url = actual_url:gsub("%%(%x%x)", function(hex)
            return string.char(tonumber(hex, 16))
        end)  -- URL解码
        msg.verbose("Actual video URL: " .. actual_url)
        -- 根据实际视频URL判断网站类型
        if actual_url:match("bilibili%.com") then
            subdir = "bilibili"
            -- 提取 av号、BV号 或 cid
            identifier = actual_url:match("av(%d+)") or 
                        actual_url:match("BV([%w]+)") or
                        actual_url:match("video/(%d+)") or
                        actual_url:match("/(%d+)%.xml")
        elseif actual_url:match("mgtv%.com") then
            subdir = "mgtv"
            -- 芒果TV: 提取路径中的数字部分
            local id1, id2 = actual_url:match("b/(%d+)/(%d+)")
            if id1 and id2 then
                identifier = id1 .. "_" .. id2
            else
                identifier = actual_url:match("/(%d+)%.html")
            end
        elseif actual_url:match("v%.qq%.com") then
            subdir = "qq"
            -- 腾讯视频: 提取封面ID和视频ID
            local cover_id = actual_url:match("cover/([%w]+)")
            local video_id = actual_url:match("/([%w]+)%.html")
            identifier = (cover_id or "") .. "_" .. (video_id or "")
        elseif actual_url:match("youku%.com") then
            subdir = "youku"
            -- 优酷: 提取视频ID
            identifier = actual_url:match("id_([%w=]+)") or
                        actual_url:match("/([%w=]+)%.html")
        elseif actual_url:match("iqiyi%.com") then
            subdir = "iqiyi"
            -- 爱奇艺: 提取视频ID
            identifier = actual_url:match("v_([%w]+)") or
                        actual_url:match("/([%w]+)%.html")
        elseif actual_url:match("gamer%.com%.tw") then
            subdir = "gamer"
            -- 巴哈姆特: 提取sn参数
            identifier = actual_url:match("sn=(%d+)")
        end
        if not subdir then
            -- 未知网站，使用代理域名作为子目录
            subdir = url:match("://([^/]+)") or "unknown"
            subdir = subdir:gsub("[^%w%.]", "_")
        end
        if not identifier or identifier == "" then
            -- 使用URL哈希作为标识符
            identifier = self._simple_hashstr(url)
        end
        -- 确保文件名安全
        identifier = identifier:gsub("[^%w%-_=]", "_")
        if self.title then
            identifier = self.title .. '-' .. identifier
        end
        return {subdir, identifier .. ".xml"}
    end,
    _simple_hashstr = function(str)
        local hash = 0
        for i = 1, #str do
            local char = string.byte(str, i)
            hash = ((hash * 32) - hash) + char
            hash = hash % 2147483648
        end
        return myutil.toBase36(math.abs(hash))
    end,
    _get_full_ass_path = function(self, relative_xmls)
        if #self.xml_files == 1 then
            -- 单个XML：直接在原路径将扩展名改为.ass
            return self.xml_files[1]:gsub(".xml$", ".ass")
        else -- # > 1
            --  多个XML -> 一个ASS
            local subdirs = {}
            -- 提取每个XML文件的子目录
            for _, relxml in ipairs(relative_xmls) do
                table.insert(subdirs, relxml[1])
            end
            local subdir = table.concat(subdirs, "-")
            local ass, combined_name
            if self.title then
                -- 优先使用 title, 且 title 在前, subdir 在后
                ass = self.title
                combined_name = strfmt('%s-%s.ass', ass, subdir)
            else
                -- subdir 在前, 各个 identifier 在后
                local identifiers = {}
                -- 无 title，提取每个XML文件的主要标识符
                for _, relxml in ipairs(relative_xmls) do
                    table.insert(identifiers, relxml[2]:gsub(".xml$", ""))
                end
                ass = table.concat(identifiers, "-")
                -- 确保文件名安全
                ass = ass:gsub("[^%w%-_=]", "_")
                -- 限制文件名长度，使用哈希值作为备选
                if #ass > 100 then
                    ass = self._simple_hashstr(ass):sub(1, 32)
                end
                combined_name = strfmt('%s-%s.ass', subdir, ass)
            end
            return myutil.get_cache_path('merged_ass', combined_name)
        end
    end,
    _init_ = function(self)
        for _, title in pairs({
                    mp.get_property("title", nil),
                    mp.get_property("force-media-title", nil),
                    }) do
            if title and #title > 0 then
                self.title = title:gsub(" ", "")  -- 仅去除空格
                break
            end
        end
        self.custom_curl_args = {
            user_agent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/124.0.0.0',
            headers = {
                'Accept: application/xml, text/xml, */*',
                'Accept-Language: zh-CN,zh;q=0.9,en;q=0.8',
            },
        }
        local relative_xmls = {}
        for i, url in ipairs(external_danmaku_xmlurls) do
            table.insert(self.xml_urls, url)
            local relxml = self:_get_relative_xml_path(url)
            table.insert(relative_xmls, relxml)
            local xml_path = myutil.get_cache_path(table.unpack(relxml))
            table.insert(self.xml_files, xml_path)
            msg.verbose(strfmt('Adding danmu xml: %s -> %s', url, xml_path))
        end
        self.ass_file = self:_get_full_ass_path(relative_xmls)
        msg.verbose(strfmt('Setting danmu ass: %s', self.ass_file))
    end
}, { __index = DanmuManager })

-- 字幕加载器模块
local Loader = {
    _2sub_visibility = mp.get_property_native("secondary-sub-visibility"),
    _2sub_ass_override = mp.get_property_native("secondary-sub-ass-override"),
    ass_file = nil,
    loaded = false,
    loaded_sid = nil,
    load_ass = function(self)  -- load function
        if not myutil.file_exists(self.ass_file) then
            msg.warn(strfmt('Ass file %s not found!', self.ass_file))
            return
        end
        myutil.log('开火')
        if self._2sub_ass_override then  -- 将弹幕挂载为次字幕
            mp.set_property_native("secondary-sub-ass-override", true)
            mp.set_property_native("secondary-sub-visibility", true)
            mp.commandv("sub-add", self.ass_file, "auto")
            self.loaded_sid = myutil.sub_count()
            -- ? current-tracks/sub2/id ?
            mp.set_property_native("secondary-sid", self.loaded_sid)
        else
            -- 挂载subtitles滤镜
            -- 注意加上@标签(多次调用不会重复挂载, 以最后一次为准)
            mp.commandv('vf', 'append', strfmt(
                '@danmu:subtitles=filename="%s"', self.ass_file))
            -- 只能在软解或auto-copy硬解下生效, 统一改为auto-copy硬解
            mp.set_property('hwdec', 'auto-copy')
            self.loaded_sid = nil
        end
        self.loaded = true
    end,
    remove_ass = function(self)
        if self.loaded then
            myutil.log('停火')
            if self._2sub_ass_override and self.loaded_sid then -- 次字幕
                mp.set_property_native("secondary-sub-visibility", false)
                mp.commandv('sub-remove', self.loaded_sid)
            else  -- if exists @danmu filter, remove it
                for _, f in ipairs(mp.get_property_native('vf')) do
                    if f.label == 'danmu' then
                        mp.commandv('vf', 'remove', '@danmu')
                        break
                    end
                end
            end
        end
        self.loaded, self.loaded_sid = false, nil
    end,
    toggle = function(self)
        if self.loaded then
            self:remove_ass()
        else
            self:load_ass()
        end
    end,
    worker = function(self, manager)
        myutil.log('弹幕正在装填')
        -- 构建 Curl.run_multiple_requests 参数
        local requests_list = {}
        for i, url in ipairs(manager.xml_urls) do
            local request_args = {
                output = manager.xml_files[i],
                url = url,
            }
            -- 合并自定义参数
            for k, v in pairs(manager.custom_curl_args) do
                request_args[k] = v
            end
            table.insert(requests_list, request_args)
        end
        Curl.run_multiple_requests(requests_list, function(results)
            -- 检查下载成功的 xml
            local okxmls = {}
            for i, result in pairs(results) do
                if result.success then
                    local xml_file = manager.xml_files[i]
                    if myutil.file_exists(xml_file) then
                        table.insert(okxmls, xml_file)
                    else
                        msg.error('Lost xml file:', xml_file)
                    end
                end
            end
            if #okxmls > 0 then
                myutil.log('弹幕正在上膛')
                DanmakuFactory.convert(okxmls, manager.ass_file,
                    function(success, result, err)
                        if success then
                            -- load danmu assfile
                            self.ass_file = manager.ass_file
                            self:load_ass()
                        else
                            myutil.log(err)
                        end
                    end
                )
            else
                myutil.log('无弹幕可用')
            end
        end)
        -- all done.
    end,
}

-- start
if o.enable then
    mp.register_event("file-loaded", function()
        local manager
        if Bilibili.match() then -- 1. bilibili
            manager = Bilibili:create()
        elseif ExternalDanmaku.match() then -- 2. external danmaku
            manager = ExternalDanmaku:create()
        end
        if manager == nil then
            msg.error('No Danmu Manager found!')
            return
        else
            msg.info(strfmt('Using %s to add danmu ...', manager.name))
        end
        if #manager.xml_urls == 0 then
            msg.error('Danmu XML URL not set!')
        elseif #manager.xml_urls ~= #manager.xml_files then
            msg.error('XML URLs count does not match XML files count!')
        elseif #manager.ass_file == 0 then
            msg.error('Danmu ass path not set!')
        else
            Loader:worker(manager)
        end
    end)
    if o.toggle_key_binding:match('^%a$') then
        mp.add_key_binding(o.toggle_key_binding, 'toggle', function()
            Loader:toggle()
        end)
    end
    mp.register_event("end-file", function()
        Loader:remove_ass()
        Loader.ass_file = nil
        mp.set_property_native("secondary-sub-visibility", Loader._2sub_visibility)
        mp.set_property_native("secondary-sub-ass-override", Loader._2sub_ass_override)
        -- 清理外部弹幕 xml URL
        if #external_danmaku_xmlurls > 0 then
            msg.info("Cleaning danmaku XML URLs ...")        
            external_danmaku_xmlurls = {}
        end
    end)
end

