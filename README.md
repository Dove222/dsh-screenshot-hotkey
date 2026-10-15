# dsh-screenshot-hotkey

给 DeepSeek Harness（DSH）用的 Windows 截屏插件：**按 `Alt+A` 呼出选区 → 截图 → 自动进系统剪贴板**，截图大小完全可自定义。

- 只做一件事：把「截屏 → 剪贴板」变成 DSH 里的一个全局热键。
- 纯宿主（Host）插件，没有浏览器端代码，不需要构建、不需要联网安装依赖。
- 全局热键由 Win32 `RegisterHotKey` 注册，DSH 窗口没在前台也能用。

---

> 首次公开发布：**v1.0.0**（Windows 专用）

## 1. 功能

| 能力 | 说明 |
| --- | --- |
| 全局快捷键 | 默认 `Alt+A`，可改成 `Ctrl+Shift+S`、`Alt+Shift+A`、`F9` 等 |
| 可自定义截图大小 | 三种方式：配置里写死大小 / 选区带上初始大小 / 拖动后精修（见第 4 节） |
| 自动写入系统剪贴板 | 截图完成即进剪贴板，可直接 Ctrl+V 粘到聊天框、文档、画图 |
| 可选另存 PNG | 配置 `saveDirectory` 后，每次截图同时落盘 |
| 截图反馈 | 截图后选区边框闪烁并提示「已复制到剪贴板」 |
| 取消 | 覆盖层里按 `Esc` 或点鼠标右键 |

---

## 2. 安装

本插件是一个 DSH bundle 包，用官方插件管理器安装（**推荐**）：

```powershell
# 路径换成你放本插件的位置
dsh plugin --profile desktop add "E:\Users\cgy52\Documents\deepseek-harness\default-workspace\dsh-screenshot-hotkey"
```

然后**重启 DSH Desktop**（包的 manifest 与组合层在进程内缓存，新增 bundle 必须重启才生效）。

重启后在 DSH 侧边栏的**插件**页应当能看到 `dsh-screenshot-hotkey`（行 id：`screenshot`）。

> 插件启用后，快捷键是**全局**的：不管 DSH 窗口有没有在前台，按 `Alt+A` 都能截图。

### 卸载

最省事的是在 DSH 侧边栏**插件**页把它停用（停用后助手进程会被结束，全局快捷键立即释放），或直接卸载，然后重启：

```powershell
dsh plugin --profile desktop remove dsh-screenshot-hotkey
```

---

## 3. 使用

1. 插件启用后（DSH 启动时就已经就绪），按 **`Alt+A`**。
2. 屏幕变暗，进入选区覆盖层。
3. **拖拽**框出要截的范围；松手后还能微调大小和位置（见下表）。
   > 拖拽过程中按钮会先**隐藏**，松手后才出现 —— 这样拖动时画面不做任何额外重排，不会卡顿。
4. 选区下方会出现一排按钮：**确定 / 取消 / 另存为**。

   * **确定**：图片立刻进剪贴板，选区闪一下绿框提示「已复制到剪贴板」，覆盖层关闭。
   * **取消**：什么都不做，直接退出（等同 `Esc` / 鼠标右键）。
   * **另存为**：弹出保存窗口（见下一节），可以先看缩略图、改格式、改路径再存。

5. 到任意地方 **`Ctrl+V`** 粘贴。

### 另存为窗口

点「另存为」后弹出：

| 区域 | 内容 |
| --- | --- |
| 缩略图 | 当前截图的等比预览（浅色底、不拉伸变形） |
| 分辨率 | 例如 `1920 × 1080 像素` |
| 图片格式 | 下拉框，可选 **PNG** / **JPG**（改格式会自动把下面路径的扩展名一起改掉） |
| 保存路径 | 完整路径，可直接编辑；打开时默认选中文件名，敲字就能改名 |
| 浏览… | 调起系统「另存为」对话框；打开时**已带好原文件名**，换目录不用重新输名字（只换了目录的话保存时也会把原文件名接回去） |
| 保存 / 取消 | `Enter` = 保存，`Esc` = 取消（取消后回到选区界面，可以继续调整再选） |

> 「另存为」保存的同时**也会写入剪贴板**（除非把 `copyToClipboard` 设为 `false`）。
> JPG 用 WPF 编码器、质量 90；PNG 无损。

### 覆盖层里的快捷键

| 操作 | 作用 |
| --- | --- |
| 拖拽 | 框选区域 |
| 拖动选区内 | 整体移动选区 |
| 拖动选区边缘/四角 | 缩放选区 |
| `方向键` | 移动选区 1 像素 |
| `Ctrl+方向键` | 移动选区 10 像素 |
| `Shift+方向键` | 调整选区大小 1 像素（←→ 调宽，↑↓ 调高） |
| `Ctrl+Shift+方向键` | 调整选区大小 10 像素 |
| `Enter` | 确定（复制到剪贴板） |
| `Esc` / 鼠标右键 | 取消 |
| 鼠标在选区外拖拽 | 重新框选 |
| 直接点按钮 | 确定 / 取消 / 另存为 |

---

## 4. 自定义截图大小（三种方式）

### 方式一：固定大小，一步到位（`mode: fixed`）

配置里写好大小，按 `Alt+A` **不弹选区**，直接以鼠标位置为中心截取该尺寸：

```yaml
- id: screenshot
  name: dsh-screenshot-hotkey
  config:
    mode: fixed
    width: 800
    height: 600
```

适合「每次都截同样大小」的场景（比如固定尺寸的头像、卡片）。

### 方式二：选区带初始大小（`mode: region` + `width`/`height`）

```yaml
- id: screenshot
  name: dsh-screenshot-hotkey
  config:
    mode: region
    width: 1200
    height: 800
```

按 `Alt+A` 后**已经有一个 1200×800 的选区**，鼠标所在位置为中心；你可以拖动它、拖边缘缩放，或者按 `Shift+方向键` 精确调到想要的数值，然后 `Enter` 确认。

### 方式三：拖拽 + 精修

`width`/`height` 留 `0` 时，选区从零开始拖；松手后左上角会显示实时 `宽 x 高`，用 `Shift+方向键` 精修到精确像素值，再 `Enter`。

> 三种方式可以混用：`width`/`height` 既是 fixed 模式的最终大小，也是 region 模式的初始大小。

---

## 5. 配置项

配置写在 `%USERPROFILE%\.dsh\profiles\desktop\cordis.patch.yml` 里，按行 id 覆盖（**整段替换**，改一个字段要把这一段需要的都写上）。不写就用默认值。

```yaml
- id: screenshot
  name: dsh-screenshot-hotkey
  config:
    enabled: true            # 总开关
    hotkey: Alt+A            # 全局快捷键
    mode: region             # region = 弹选区；fixed = 直接截 width x height
    width: 0                 # 期望宽度（像素）；region 时是初始大小，0 = 从零拖
    height: 0                # 期望高度（像素）
    copyToClipboard: true    # 是否写入系统剪贴板
    saveDirectory: ''        # 非空则同时保存 PNG 到该目录，如 'E:\shots'（YAML 单引号里反斜杠就是字面量，别写成 E:\\shots）
    language: zh             # 覆盖层提示语言：zh / en
    flash: true              # 截图后是否闪一下提示
    confirmOnRelease: false  # true = 鼠标一松手就截图；false = 松手后还能微调，按 Enter 确认
```

改完保存即可（用户 patch 层会被 boot 事务性重读）；如果没生效，重启 DSH。

---

## 6. 实现说明

```
dsh-screenshot-hotkey/
├── package.json          # dsh.bundle.patch 指向下面的 patch 层
├── cordis.patch.yml      # 向 DSH 组合树插入 id=screenshot 的插件行
├── lib/index.js          # 宿主侧：进程生命周期 + 配置归一化 + 协议解析
├── assets/screenshot.ps1 # Windows 侧：热键、选区覆盖层、截图、剪贴板
└── README.md
```

- **宿主侧（`lib/index.js`）** 不碰任何平台 API，只负责把 `assets/screenshot.ps1` 作为常驻子进程拉起来，解析它 stdout 上的协议行，并在插件停用/热重载时结束它。
- **助手进程（`assets/screenshot.ps1`）** 用 Windows PowerShell 5.1（默认 STA，WinForms 与剪贴板都要求 STA）：
  - `RegisterHotKey` 注册全局热键；
  - 截屏前先 `CopyFromScreen` 拍下整个虚拟桌面，再显示全屏覆盖层 —— 这样**覆盖层本身不会出现在截图里**；
  - 确认时从那张原图里裁剪，`Clipboard.SetDataObject(copy: true)` 写入剪贴板；
  - `SetProcessDPIAware` 保证高 DPI 下坐标与像素一致。
- **配置 schema 有兜底**：`@deepseek-ai/schemastery` 是 peer（不随插件安装、也不联网拉取），由 DSH 的 profile 模块解析提供。万一解析不到，`lib/index.js` 会退回内置的一个 Standard Schema（Cordis 只要求 `Config['~standard'].validate()`），默认值由 `normalize()` 保证，不会因为一个 import 失败就让整个插件加载不了。
- ⚠️ **不要去改 JPG 的编码写法**：``ImageCodecInfo + EncoderParameters + Encoder::Quality`` 这套组合会被
  Windows Defender 的 **AMSI** 判定为恶意脚本特征，**整份脚本**都会以
  `This script contains malicious content and has been blocked by your antivirus software` 被拦下来
  （不是这一行报错，是整个插件失效）。所以 JPG 走 `JpegBitmapEncoder`（WPF，质量 90），
  失败才退回 `ImageFormat::Jpeg`。
- **覆盖层的流畅度**（拖拽不卡的关键，改代码时别破坏这三点）：
  1. 拖拽中**不显示按钮条**，也不会去重排它 —— 每次鼠标移动都改 AutoSize 面板的位置/层级是最大的开销来源；
  2. 鼠标移动只 `Invalidate(脏矩形)`：脏矩形 = 新旧选区的并集 + 边框 + 尺寸标签的余量，靠底部提示条时再带上整条提示带；
     重绘时只贴那一小块位图（`DrawImage` 子矩形 + NearestNeighbor），不再整屏重画；
  3. 画笔/画刷缓存成 `$script:DimBrush` 等常量，底部提示文字只量一次宽度。
- **脚本自更新**：助手每 2 秒看一眼自己的脚本文件，变了就先做一次语法检查 —— 语法没问题就
  `exit 0`，由宿主（DSH 里的插件）立刻用新脚本把助手拉起来；语法有误就只打一行
  `WARN 脚本已更新但语法有误，继续运行当前版本` 并继续跑旧版本，**绝不会让自己变成起不来**。
  也就是说：改完脚本最多几秒自动生效，不用重启 DSH（日志里会看到
  `脚本已更新，退出以便宿主加载新版本`）。只有改**插件组合/config**（`cordis.patch.yml`、package.json）才需要重启。
- ⚠️ **WinForms 事件处理器里不要用函数局部变量**：PowerShell 的处理器是按**动态作用域**查变量的。
  处理器要是在定义它的函数**返回之后**才被调用（保存窗口就是这样），那些局部变量通通是 `$null` ——
  读 `.Text` 得到空、写 `.Text` 直接抛「找不到属性 Text」。所以保存窗口的控件全部放在
  `$script:SaveUI` 里。覆盖层没这问题，因为 `ShowDialog` 是在 `Invoke-RegionCapture` 内部调的、
  它的栈帧还在（代码里有注释标了这一点）。
- 协议行（stdout，ASCII 安全的 JSON）：`READY <hotkey>` / `HOTKEY` / `RESULT {json}` / `ERROR <text>`。
- 助手每 2 秒检查一次父进程是否还在，父进程（DSH 宿主）意外退出时自动退出，不会留下孤儿进程占着热键。

> ⚠️ `assets/screenshot.ps1` 里含中文提示，文件**必须以 UTF-8 BOM 保存**：Windows PowerShell 5.1 只有在有 BOM 时才按 UTF-8 解析脚本，否则中文会按 ANSI 解码、直接把脚本语法破坏掉。插件在启动前会检查并自动补回 BOM（只读目录下补不了会记日志）。

---

## 7. 故障排查

| 现象 | 原因 / 处理 |
| --- | --- |
| 按 `Alt+A` 没反应 | ① 看 DSH 日志里有没有 `[screenshot] 已就绪：按 Alt+A 截图`；② 若提示 `hotkey-register-failed`，说明热键被别的软件占用，换一个 `hotkey` |
| 覆盖层出不来的同时鼠标键盘失灵 | 覆盖层是全屏置顶窗口，按 `Esc` 或点右键即可退出 |
| 截出来的图是黑的 | 目标窗口用了硬件加速独占模式（部分游戏/播放器），试试换窗口或关掉独占全屏 |
| 高 DPI 下坐标偏了 | 插件已调用 `SetProcessDPIAware`；若仍偏移，把 DSH 与显示器缩放设成一致后重启 |
| 剪贴板里没有图片 | 可能被别的程序占着剪贴板，插件会重试 6 次；确认 `copyToClipboard: true` |
| 改了脚本想立刻生效 | 不用重启：助手每 2 秒自检脚本文件，语法没问题就自动重启加载新版本（日志里有 `脚本已更新，退出以便宿主加载新版本`） |
| 插件不加载 | 确认已 `dsh plugin add` 且**重启过** DSH；打开侧边栏「插件」页看这一行有没有报错 |
| 点「另存为」弹 .NET「未处理异常」对话框（如 `路径的形式不合法`） | 已修：.NET Framework 的 `Path.GetDirectoryName('')` / 含控制字符的路径会直接抛异常，现在所有路径处理都走不抛异常的包装（`Get-SafeDirectoryName` 等），默认路径也有多级兜底。日志里会有一行 `DEBUG save-default=<路径>` 可以核对默认路径是怎么算出来的 |
| 「另存为」能打开，但点保存说「请先填写保存路径」、或点「浏览…」报 `找不到属性 Text` | 已在 1.1 修掉（根因是处理器读到 `$null` 的文本框，见第 6 节）。确认日志里的助手启动时间晚于脚本修改时间，否则先重启 |
| 界面上出错但助手还活着 | 这是预期行为：UI 异常被 `Application.ThreadException` 接管，只往 DSH 日志写一行 `ERROR ui-exception: ...` 并关掉覆盖层，不会弹 JIT 对话框、也不会把常驻助手带崩 |

---

## 8. 已验证范围

本插件在交付前做过的离线验证（Windows / PowerShell 5.1）：

| 项目 | 结果 |
| --- | --- |
| 固定大小截图 -> 剪贴板 + 落盘 | `RESULT {"ok":true,...,"clipboard":true,...}`，独立进程读回剪贴板拿到同尺寸图片 |
| 选区截图（覆盖层 + 裁剪 + 落盘） | 走的是同一套覆盖层/裁剪代码路径，PNG 尺寸与选区一致 |
| 按钮条「确定」 | 与 `Enter` 等价：复制到剪贴板并关闭覆盖层 |
| 按钮条「取消」/ `Esc` / 右键 | `RESULT {"ok":false,"cancelled":true}`，不产生任何文件 |
| 按钮条「另存为」-> PNG | `"file":"...\final.png","format":"png"`，落盘头是 PNG |
| 按钮条「另存为」-> JPG | `"file":"...\final.jpg","format":"jpg"`，落盘头是 JPEG（`FFD8`），走 WPF 编码器质量 90 |
| 另存为窗口布局 | 用合成背景把窗口 `DrawToBitmap` 成 PNG（见仓库预览图），逐项确认缩略图/分辨率/格式下拉/保存路径/浏览/保存取消的位置与可读性 |
| 覆盖层按钮条布局 | 同上：按钮条跟随选区，优先贴选区下方，放不下自动改放选区底部并夹在屏幕内 |
| 拖拽中按钮隐藏 | 注入拖拽状态渲染覆盖层，按钮条确实不出现；松手状态下正常出现 |
| 脏矩形重绘正确性 | 抽出脚本里真实的脏矩形函数做纯几何校验：309 组（含从空白框选、取消回空白、四角缩放、极窄选区、贴屏幕顶边/底边、300 组随机）共 1277 项包含性检查，0 失败 —— 不会留下边框/尺寸标签残影 |
| 高 DPI 适配 | 控件尺寸与窗口大小按字体实际像素高度等比缩放（本机缩放约 1.29，窗口 854×645 物理像素，文字无裁切） |
| `copyToClipboard: false` | 剪贴板保持原内容不变（不会误覆盖你已有的剪贴板） |
| 全局热键注册 | `RegisterHotKey` 成功，助手输出 `READY Alt+A` 并常驻；被占用时报 `code=1409` |
| 非法热键 | 输出 `ERROR hotkey-invalid: 不支持的热键按键：Nope` |
| AMSI/Defender | 整份脚本内容通过 Windows Defender AMSI 扫描（见第 6 节的 JPG 编码注意事项） |
| 宿主侧协议与生命周期 | 注入假子进程验证了 `READY/HOTKEY/RESULT/ERROR` 解析（含跨分片半行）、异常退出自动重启、停用后 kill 子进程 |
| 配置校验 | patch 层 YAML 解析为符合规范的顶层数组；Config 默认值经 schemastery 校验 |

**没有**在真实桌面会话里用鼠标点过按钮（构建环境是受限沙箱，无法模拟真实鼠标/键盘输入）；按钮本身、另存为流程、窗口布局都是通过真实窗口的 `DrawToBitmap` 与 `-AutoSelect` 自动化钩子验证的。

## 9. 平台

只在 **Windows** 生效（依赖 Win32 + WinForms + Windows 剪贴板）。在其它平台上插件会打一条警告并保持静默，不影响 DSH 启动。
