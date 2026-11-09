# 截图目录

这里放工程的实际运行截图。**已就位 3 张**（`01-vm-desktop.png`、`02-console.png`、`03-settings.png`，均已完成脱敏：QQ 昵称 / 群名 / 好友名打码），其余按下表继续补。
文件名规范：`NN-英文短名.png`，两位序号 + 连字符 + 小写英文短名，全小写，扩展名 `.png`。
序号决定 docs 里的展示顺序，不要随意改名——[testing.md](../testing.md) 和 README 都按这套名字引用。

---

## 要放的图

| 序号 | 文件名 | 状态 | 拍什么 | 关键要素（少了这张图就没意义） | 关联测试 |
|---|---|---|---|---|---|
| 01 | `01-vm-desktop.png` | ✅ 已就位 | 虚机桌面（Xvfb `:99`，1280×800） | Linux QQ 已登录、群列表可见；昵称 / 群名 / 好友名已打码 | T06、T09、T16 |
| 02 | `02-console.png` | ✅ 已就位（**v2 界面**） | 控制台首页 `http://127.0.0.1:8080/` | 四个状态灯（QQ / SnowLuma / AstrBot / 桌面 VNC）+ 常用入口 + 服务操作；**注意：v3 的体检卡 / 性能快照 / 维修页还没截图，待重拍** | T13 |
| 03 | `03-settings.png` | ✅ 已就位 | 设置页 `http://127.0.0.1:8080/settings` | 模型开关（`ben/deepseek-v4.1-flash` 开、`vyceai/deepseek-v4.1` 关）+ 插件开关列表 | T13、T25 |
| 04 | `04-astrbot.png` | ⛔ 待补 | AstrBot 后台 `http://127.0.0.1:6185/` | 登录后的首页（能看到版本/运行状态）；**遮蔽账号名** | T11 |
| 05 | `05-group-reply.png` | ⛔ 待补 | 测试群里 @ 机器人并收到回复 | 同一条聊天记录里同时出现「@机器人 的提问」和「机器人的回复」，时间戳相邻 | T14 |
| 06 | `06-boot-log.png`（可选） | ⛔ 待补 | `tail -20 /root/boot.log` 的输出 | 5 行 `OK` + `BOOT_DONE` | T15 |
| 07 | `07-hish-vm.png`（可选） | ⛔ 待补 | HiSH 模拟器管理页 | CPU / 内存配置项（建议 4 核 / 4096 MB），证明资源调过 | T01 |

必补 04、05；06/07 有则更好。**改名要同步改 [testing.md](../testing.md) 与 README，别只改文件。**

---

## 怎么拍

**推荐：平板直接截屏**（最真实，证明真的跑在平板上）

```bash
# PC 侧，用本仓库 tools/hm.py
python tools/hm.py shot docs-screenshots/05-group-reply.png
```

**或者：浏览器里截图**
控制台 8080、AstrBot 6185、noVNC 6080 都是网页，用平板浏览器打开后系统截屏即可；noVNC 里需要先点到「全屏」再截，否则会带浏览器边框。

**或者：从虚机里导**
```sh
DISPLAY=:99 import -window root /root/shot.png
```

---

## 脱敏（重要，发 GitHub 前必查）

截图会进公开仓库，下面这些必须处理干净：

| 内容 | 处理方式 |
|---|---|
| QQ 号、群号、群名 | 打码或换成测试群 |
| 微信/QQ 头像、昵称 | 打码（头像可能反向查到人） |
| 模型 API key、`Authorization` 头 | **必须打码**；截图前先确认没露出 `sk-` 开头串 |
| `base_url` 里的私有域名/IP | 打码或改成 `api.example.com` |
| 内网 IP（如 `192.168.x.x`） | 打码 |
| AstrBot 后台账号 | 打码；密码框保持掩码状态 |
| 二维码 | 不要截「正在显示二维码」的画面（扫了能登录你的号） |
| 终端里的主机名/用户名 | 一般无所谓，但别带真实姓名 |

自查：

```bash
git grep -nE 'sk-|Bearer [A-Za-z0-9]|192\.168\.|passw|[0-9]{5,11}' -- docs/screenshots
```

---

## 图片规格

- 格式：`.png`（UI 截图不要用 jpg，文字会糊）。
- 宽度：≤ 1600 px；手机截图原图通常够用，太宽的先缩。
- 体积：单张 < 500 KB。太大用 `magick in.png -resize 1200x -strip out.png`。
- 不要加水印、不要加荧光笔标注；要标重点就用文字说明写在下面对应表里。

---

## 放进文档

补图后在 [testing.md](../testing.md) 对应行的「证据」列把 `⛔ 待补` 换成：

```markdown
![控制台首页](screenshots/02-console.png)
```

（`testing.md` 在 `docs/` 下，所以相对路径是 `screenshots/xx.png`；README 里引用则是 `docs/screenshots/xx.png`。）
