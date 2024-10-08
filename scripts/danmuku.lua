--[[

Bilibili danmuku script for mpv

This script automatically downloads bilibili comments,
converts to ass, then loads ass as sub-ass or subtitles in mpv.

To configure this script use file danmuku.conf in directory script-opts
(the "script-opts" directory must be in the mpv configuration directory,
typically ~/.config/mpv/).
Example configuration: see danmuku.conf

# Ref:
1. https://mpv.io/manual/master/#lua-scripting
2. https://github.com/itKelis/MPV-Play-BiliBili-Comments
3. https://github.com/hihkm/DanmakuFactory
4. https://github.com/HFrost0/danmakuC
5. https://github.com/HFrost0/bilix/blob/0239d332472eb496a865b2117d1c8b4e93a8b19a/bilix/sites/bilibili/api.py#L563-L568
6. https://github.com/jnxyp/Bilibili-Block-List

Copyright (c) 2024 shmilee
Licensed under GNU General Public License v2:
https://opensource.org/licenses/GPL-2.0

--]]

local utils = require("mp.utils")
local opts = require("mp.options")
local msg = require("mp.msg")
local osd_msg = mp.osd_message
local strfmt = string.format

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
    -- ~/.config/mpv/danmuku-data/cache/,
    -- or ~/.cache/mpv/, utils.split_path(os.tmpname())
    cache_dir = '~~home/danmuku-data/cache/',
    -- ~/.config/mpv/danmuku-data/bin/
    bin_path = '~~home/danmuku-data/bin/:~/.local/bin/:/usr/bin/',
    websites = 'bilibili_v1|bilibili_v2|acfun',
    -- curl, others TODO
    download = 'bilibili_v1=curl;bilibili_v2=TODO;acfun=TODO',
    -- danmaku2ass.py, DanmakuFactory, danmakuC
    convert = 'bilibili_v1=DanmakuFactory;bilibili_v2=danmakuC;acfun=danmaku2ass.py',
    -- setting for ass
    resolution = 'auto',  -- 屏幕分辨率 (自动取值) auto: like 1920x1080
    reserve = 0.2,  -- 保留底部多少高度的空白区域 0-1 (默认 0.2)
    fontname = mp.get_property('sub-font'),  -- 弹幕字体 (默认 sans-serif)
    fontsize = 50.0,  -- 字体大小 (默认 5.0)
    alpha = 0.95,  -- 弹幕不透明度 0-1 (默认 0.95)
    duration_marquee = 10.0,  -- 滚动弹幕显示的持续时间 (默认 10秒)
    duration_still = 5.0,  -- 静止弹幕显示的持续时间 (默认 5秒)
    filter_file = '~~home/danmuku-data/share/BBL.txt',  -- 弹幕屏蔽文件路径
}
opts.read_options(o, 'danmuku')

local myutil = {
    platform = mp.get_property('platform', ''),
    file_exists = function(path)
        local info, err = utils.file_info(path)
        return info and info.is_file
    end,
    get_cache_path = function(filename)
        if o.cache_dir:match('^~') then
            return utils.join_path(
                mp.command_native({"expand-path", o.cache_dir}), filename)
        else
            return utils.join_path(o.cache_dir, filename)
        end
    end,
    -- searching filename in directories `dpaths`
    -- The dpaths can be splited by ':', for example o.bin_path
    search_file = function(dpaths, filename)
        for d in string.gmatch(dpaths, "([^:]+)") do
            if d:match('^~') then
                d = mp.command_native({"expand-path", d})
            end
            local path = utils.join_path(d, filename)
            msg.verbose('searching file: '.. path)
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
        msg.verbose(strfmt('aspect=%s, width=%s, height=%s', aspect, dw, dh))
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
    async_run = function(args, callback)
        -- callback(success, result, error)
        return mp.command_native_async({
            name = 'subprocess',
            playback_only = false,
            capture_stdout = true,
            args = args,
        }, callback)
    end,
}

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
    worker = function(self, download_args, convert_args, assfile)
        myutil.log('弹幕正在装填')
        myutil.async_run(download_args, function(success, result, err)
            if err == nil then
                myutil.log('弹幕正在上膛')
                myutil.async_run(convert_args, function(succ, res, err)
                    if err == nil then
                        -- load danmu assfile
                        self.ass_file = assfile
                        self:load_ass()
                    else
                        myutil.log(err)
                    end
                end)
            else
                myutil.log(err)
            end
        end)
    end,
}

local convert_args_lib = {
    ['danmaku2ass.py'] = function(input, output, format, use_interpreter)
        local script = myutil.search_file(o.bin_path, 'danmaku2ass.py')
        if script == nil then
            msg.warn('danmaku2ass.py not found!')
            return
        end
        local dw, dh = myutil.get_width_height()
        local args = {
            script, '-f', format or 'autodetect', '-o', output,
            '-s', strfmt('%sx%s', dw, dh),
            '-fn', tostring(o.fontname), '-fs', tostring(o.fontsize),
            '-a', tostring(o.alpha),
            '-dm', tostring(o.duration_marquee),
            '-ds', tostring(o.duration_still),
            '-p', tostring(math.floor(o.reserve*dh)), '-r', input,
        }
        local file = mp.command_native({ "expand-path", o.filter_file })
        if myutil.file_exists(file) then
            table.insert(args, '-flf')
            table.insert(args, file)
        end
        if use_interpreter then
            local py3
            if type(use_interpreter) == 'string' then
                py3 = myutil.search_file(o.bin_path, use_interpreter)
            end
            if py3 == nil then  -- default interpreter
                if myutil.platform == 'windows' then
                    py3 = 'python.exe'
                else
                    py3 = 'python'
                end
                py3 = myutil.search_file(o.bin_path, py3) or py3
            end
            table.insert(args, 1, py3)
        end
        return args
    end,
    ['DanmakuFactory'] = function(input, output)
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
        local dw, dh = myutil.get_width_height()
        local args = {
            cmd, '-o', output, '-i', input,
            '-r', strfmt('%sx%s', dw, dh),
            '-s', tostring(o.duration_marquee),
            '-f', tostring(o.duration_still),
            '-N', o.fontname, '-S', tostring(o.fontsize),
            '-O', tostring(math.floor(o.alpha*255)),
            '--displayarea', tostring(1.0 - o.reserve),
            '-b', 'REPEAT', '-d', '-1', '--ignore-warnings',
        }
        --debug_kv('args', args)
        return args
    end,
    ['danmakuC'] = function(input, output)
        local cmd = myutil.search_file(o.bin_path, 'danmakuC')
        cmd = cmd or myutil.search_file(o.bin_path, 'danmakuC.exe')
        if cmd == nil then
            msg.warn('danmakuC not found!')
            return
        end
        local dw, dh = myutil.get_width_height()
        local args = {
            cmd, input, '-o', output, '-s', strfmt('%sx%s', dw, dh),
            '-fn', o.fontname, '-fs', tostring(o.fontsize),
            '-a', tostring(math.floor(o.alpha*255)),
            '-dm', tostring(o.duration_marquee),
            '-ds', tostring(o.duration_still),
            '-rb', tostring(math.floor(o.reserve*dh)), '-r',
        }
        return args
    end,
}

local bilibili_v1 = {
    match = function(self)
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
                    msg.verbose(strfmt(
                        'match path=[[[%s]]] by pattern="%s"', path, patt))
                    return true
                end
            end
        end
    end,
    cid = nil, danmufile = nil, assfile = nil,
    danmufile_namefmt = 'bilibili-%s.xml',
    setting = function(self)
        local tracks = mp.get_property_native("track-list")
        for _, track in ipairs(tracks) do
            if track["lang"] == "danmaku" then
                self.cid = track["external-filename"]:match("/(%d-)%.xml$")
                local sid = track["id"]
                -- rm Subs  --sid=1 --slang=danmaku 'xml'
                if sid then
                    msg.verbose(strfmt('remove danmaku xml sid=%s', sid))
                    mp.commandv('sub-remove', sid)
                end
                break
            end
        end
        if self.cid == nil then
            local pat = "bilivideo%.c[nom]+.*/(%d+)-%d+-%d+%.m4s%?"  -- com cn
            for _, path in pairs({
                    mp.get_property("path", ''),
                    mp.get_property("stream-open-filename", ''),
                    }) do
                if path:find(pat) then
                    self.cid = path:match(pat)
                    break
                end
            end
        end
        if self.cid ~= nil then
            msg.verbose(strfmt('setting cid=%s', self.cid))
            local f = strfmt(self.danmufile_namefmt, self.cid)
            self.danmufile = myutil.get_cache_path(f)
            msg.verbose(strfmt('setting danmufile=%s', self.danmufile))
            f = strfmt('bilibili-%s.ass', self.cid)
            self.assfile = myutil.get_cache_path(f)
            msg.verbose(strfmt('setting assfile=%s', self.assfile))
        else
            msg.warn("can't get cid!")
        end
    end,
    get_download_args = function(self)
        local d = myutil.get_val_from_kvstr(o.download, 'bilibili_v1')
        if d ~= 'curl' then
            msg.warn(strfmt('Unsupported download=%s for bilibili xml!', d))
            return
        end
        local curl =  myutil.search_file(o.bin_path, 'curl')
        curl = curl or myutil.search_file(o.bin_path, 'curl.exe')
        if curl == nil then
            msg.warn('curl not found!')
            return
        end
        -- https://github.com/SocialSisterYi/bilibili-API-collect/blob/cb4f767d4ee3f4f66b6caff04c9c40164ea4af54/docs/danmaku/danmaku_xml.md
        -- https://api.bilibili.com/x/v1/dm/list.so
        -- https://comment.bilibili.com/{{cid}}.xml
        return {
            curl, '-f', '-s', '-m', '10', '--compressed',
            '-H', "User-Agent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/124.0.0.0'",
            '-o', self.danmufile,
            strfmt('https://comment.bilibili.com/%s.xml', self.cid),
        }

    end,
    get_convert_args = function(self)
        local c = myutil.get_val_from_kvstr(o.convert, 'bilibili_v1')
        if c == 'danmakuC ' then
            msg.warn(strfmt('Unsupported convert=%s for bilibili xml!', c))
            return
        end
        local args = convert_args_lib[c]
        if args == nil then
            return
        end
        if c == 'danmaku2ass.py' then
            args = args(self.danmufile, self.assfile, nil, true)
        else
            args = args(self.danmufile, self.assfile)
        end
        return args
    end,
}

local bilibili_v2 = setmetatable({
    cid = nil, danmufile = nil, assfile = nil,
    danmufile_namefmt = 'bilibili-pb-%s.bin',  -- Protobuf
    get_download_args = function(self)
        local d = myutil.get_val_from_kvstr(o.download, 'bilibili_v2')
        if d ~= 'bilibili_protobuf.py' then  -- TODO
            msg.warn(strfmt('Unsupported download=%s for bilibili protobuf!', d))
            return
        end
        return {}  -- TODO
    end,
    get_convert_args = function(self)
        local c = myutil.get_val_from_kvstr(o.convert, 'bilibili_v2')
        if c ~= 'danmakuC ' then
            msg.warn(strfmt('Unsupported convert=%s for bilibili protobuf!', c))
            return
        end
        return convert_args_lib[c](self.danmufile, self.assfile)
    end,
}, { __index = bilibili_v1 })

local acfun = {}  -- TODO

local supported_websites = {
    ['bilibili_v1'] = bilibili_v1,
    ['bilibili_v2'] = bilibili_v2,
    -- ['acfun'] = acfun,
}

-- start
-- debug_kv('o', o)
if o.enable then
    mp.register_event("file-loaded", function()
        for web in string.gmatch(o.websites, "([^|]+)") do
            local site = supported_websites[web]
            if site and type(site.match) == 'function' and site:match() then
                msg.info(strfmt('Using %s to add danmaku ...', web))
                site:setting()
                if site.assfile then
                    local d_args = site:get_download_args()
                    local c_args = site:get_convert_args()
                    if d_args and c_args then
                        Loader:worker(d_args, c_args, site.assfile)
                    end
                end
                break
            end
        end
    end)
    if o.toggle_key_binding:match('^%a$') then
        mp.add_key_binding(o.toggle_key_binding, 'toggle', function()
            Loader:toggle()
        end)
    end
    mp.register_event("end-file", function()
        Loader:remove_ass()
        mp.set_property_native("secondary-sub-visibility", Loader._2sub_visibility)
        mp.set_property_native("secondary-sub-ass-override", Loader._2sub_ass_override)
    end)
end

