--[[

Bilibili danmuku script for mpv

This script automatically downloads bilibili comments,
converts to ass, then loads ass as sub-ass or subtitles in mpv.

To configure this script use file danmuku.conf in directory script-opts
(the "script-opts" directory must be in the mpv configuration directory,
typically ~/.config/mpv/).
Example configuration:


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
local opts = require "mp.options"
local msg = require("mp.msg")
local osd_msg = require("mp.osd_message")

local AVBV = {  -- AV号, BV号 --{{{
    ref = 'https://www.zhihu.com/question/381784377/answer/1099438784',
    t = 'fZodR9XQDSUm21yCkr6zBqiveYah8bt4xsWpHnJE7jL5VG3guMTKNPAwcF',
    tr = {},
    s = {12, 11, 4, 9, 5, 7},
    xor = 177451812,
    add = 8728348608,
    max = 2^30,
}
for i = 1, 58 do
    AVBV.tr[AVBV.t:sub(i,i)] = i - 1
end

function AVBV.decode(b)
    local r = 0
    for i = 1, 6 do
        r = r + AVBV.tr[b:sub(AVBV.s[i], AVBV.s[i])] * 58^(i - 1)
    end
    r = (r - AVBV.add) ~ AVBV.xor
    if r > AVBV.max then
        return nil
    else
        return r
    end
end

function AVBV.encode(a)
    if a > AVBV.max then
        return nil
    end
    a = (a ~ AVBV.xor) + AVBV.add
    local r = {'B', 'V', '1', ' ', ' ', '4', ' ', '1', ' ', '7', ' ', ' '}
    for i = 1, 6 do
        local j = math.floor(a / 58^(i - 1) % 58) + 1
        r[AVBV.s[i]] = AVBV.t:sub(j, j)
    end
    return table.concat(r)
end

function AVBV.test()
    assert(AVBV.decode('BV17x411w7KC') == 170001, 'BV17x411w7KC -> 170001')
    assert(AVBV.encode(882584971) == 'BV1mK4y1C7Bz', '882584971 -> BV1mK4y1C7Bz')
end
-- AVBV --}}}

local o = {
    cache_dir = '~~cache/',  -- ~/.cache/mpv/; utils.split_path(os.tmpname())
    bin_dir = '/usr/bin/:~/.local/bin/:~~home/bin/',  -- ~/.config/mpv/bin/
    -- python+Danmu2Ass.py, curl+DanmakuFactory, or TODO curl+danmakuC
    download_convert = 'curl+DanmakuFactory',
    resolution = 'auto',  -- 屏幕分辨率 (自动取值) auto: like 1920x1080
    reserve = 0.2,  -- 保留底部多少高度的空白区域 0-1 (默认 0.2)
    fontname = "Microsoft YaHei",  -- 弹幕字体 (默认 微软雅黑)
    fontsize = 37.0,  -- 字体大小 (默认 37.0)
    alpha = 0.95,  -- 弹幕不透明度 0-1 (默认 0.95)
    duration_marquee = 10.0,  -- 滚动弹幕显示的持续时间 (默认 10秒)
    duration_stil = 5.0,  -- 静止弹幕显示的持续时间 (默认 5秒)
    filter_file = "",  -- 弹幕屏蔽文件路径
}
opts.read_options(o, 'danmuku')

local myutil = {
    platform = mp.get_property('platform', ''),
    file_exists = function(path)
        local info, err = utils.file_info(path)
        return info and info.is_file
    end,
    -- searching filename in directories `dpaths`
    -- The dpaths can be splited by ':', for example o.bin_dir
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
        local dw = 1920  -- mp.get_property_number('display-width', 1920)
        local dh = 1080  -- mp.get_property_number('display-height', 1080)
        local aspect = mp.get_property_number('width', 16) / mp.get_property_number('height', 9)
        if aspect > dw / dh then
            dh = math.floor(dw / aspect)
        elseif aspect < dw / dh then
            dw = math.floor(dh * aspect)
        end
        msg.verbose(string.format('aspect=%s, width=%s, height=%s', aspect, dw, dh))
        return dw, dh
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

local danmuku = {
    _2sub_visibility = mp.get_property_native("secondary-sub-visibility"),
    _2sub_ass_override = mp.get_property_native("secondary-sub-ass-override"),
    ass_file = nil,
    loaded = false,
    loaded_sid = nil,
    load_ass = function(self)  -- load function
        if not myutil.file_exists(self.ass_file) then
            msg.warn(string.format('Ass file %s not found!', self.ass_file))
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
            mp.commandv('vf', 'append', string.format(
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
}

local bilibili = {
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
                    msg.verbose(string.format(
                        'match path=[[[%s]]] by pattern="%s"', path, patt))
                    return true
                end
            end
        end
    end,
    cid = nil,
    danmaku_id = nil,  -- if exists, then remove it
    setting_cid = function(self)
        local tracks = mp.get_property_native("track-list")
        for _, track in ipairs(tracks) do
            if track["lang"] == "danmaku" then
                self.cid = track["external-filename"]:match("/(%d-)%.xml$")
                self.danmaku_id = track["id"]
                msg.verbose(string.format(
                    'setting danmaku_id=%s', self.danmaku_id))
                break
            end
        end
        if self.cid == nil then
            local pat = "bilivideo%.c[nom]+.*/(%d+)-%d+-%d+%.m4s%?"  -- com cn
            for _, path in { mp.get_property("path", ''),
                             mp.get_property("stream-open-filename", ''),
                            } do
                if path:find(pat) then
                    self.cid = p:match(pat)
                    break
                end
            end
        end
        msg.verbose(string.format('setting cid=%s', self.cid))
    end,
    get_danmu_cache = function(self, v2)
        local filename
        if v2 then
            filename = string.format('bilibili-dm-proto-%s.bin', self.cid)
        else
            filename = string.format('bilibili-comment-%s.xml', self.cid)
        end
        return utils.join_path(o.cache_dir, filename)
    end,
    get_ass_cache = function(self)
        local filename = string.format('bilibili-%s.ass', self.cid)
        return utils.join_path(o.cache_dir, filename)
    end,

    work_with_python = function(self, use_interpreter)
        local script = myutil.search_file(o.bin_dir, 'Danmu2Ass.py')
        if script == nil then
            msg.warn('Danmu2Ass.py not found!')
            return
        end
        local args = {
            script, '-o', self.get_ass_cache(),
            '-s', string.format('%sx%s', myutil.get_width_height()),
            '-fn', o.fontname, '-fs',  o.fontsize,
            '-a', o.opacity,
            '-dm', o.duration_marquee, '-ds', o.duration_still,
            '-flf', mp.command_native({ "expand-path", o.filter_file }),
            '-p', tostring(math.floor(o.percent*dh)),
            '-r',
            cid,
        }
        if use_interpreter then
            local py3
            if type(use_interpreter) == 'string' then
                py3 = myutil.search_file(o.bin_dir, use_interpreter)
            end
            if py3 == nil then  -- default interpreter
                if myutil.platform == 'windows' then
                    py3 = 'python.exe'
                else
                    py3 = 'python'
                end
                py3 = myutil.search_file(o.bin_dir, py3) or py3
            end
            table.insert(args, 1, py3)
        end
        myutil.log('弹幕正在上膛')
        myutil.async_run(args, function(success, result, err)
        end)

--            if err == nil then
--                danmu_file = ''..directory..'/bilibili.ass'
--                load_danmu(danmu_file)
--            else
--                log(err)
--            end
    end,
}



function danmuku.curl_download(aid, cid, callback)
    local curl = myutil.search_file(o.bin_dir, 'curl')
    local args = {
        curl, '-f', '-s', '-m', '10', '--compressed',
        '-H', "User-Agent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/124.0.0.0 Edge/124.0.0.0'",
    }
    mp.command_native_async({
		name = 'subprocess',
		playback_only = false,
		capture_stdout = true,
		args = arg,
		capture_stdout = true,
        myutil.log('弹幕正在装填')
    })
--#api.bilibili.com/x/v2/dm
    local query = args.query or {}
    for i, oneapi in pairs(apis) do
        local cmd = get_curl_cmd(curl, oneapi)
        util.print_info(string.format('API-usage cmd %d: %s', i, cmd), id)
        table.insert(handles, {cmd, oneapi.get_info})
    end

end
-- TODO



