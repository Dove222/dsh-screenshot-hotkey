<#
  dsh-screenshot-hotkey —— Windows 截屏助手（PowerShell 5.1）

  职责：
    1. 注册全局快捷键（默认 Alt+A）
    2. 快捷键触发后弹出全屏选区（region）或直接截取固定大小（fixed）
    3. 把结果 PNG 写入系统剪贴板，可选另存为文件

  stdout 协议（每行一条，ASCII 安全的 JSON）：
    READY <hotkey>
    HOTKEY
    RESULT {"ok":true,"x":..,"y":..,"width":..,"height":..,"clipboard":true,"file":""}
    ERROR <text>

  参数：
    -Once            只截一次然后退出（不注册快捷键，供离线自检/自动化使用）
    -AutoSelect x,y,w,h   测试钩子：覆盖层自动选中该区域并确认
#>
[CmdletBinding()]
param(
  [string]$Hotkey = 'Alt+A',
  [ValidateSet('region', 'fixed')][string]$Mode = 'region',
  [int]$Width = 0,
  [int]$Height = 0,
  # 用 string 而不是 bool：powershell.exe -File 把 "true"/"false" 绑定到 [bool] 会在参数绑定阶段直接失败，
  # 所以这里统一用宽容的字符串解析（true/false/yes/no/on/off/1/0 都认）。
  [string]$CopyToClipboard = 'true',
  [string]$Flash = 'true',
  [string]$ConfirmOnRelease = 'false',
  [ValidateSet('zh', 'en')][string]$Language = 'zh',
  [string]$SaveDirectory = '',
  [int]$ParentPid = 0,
  [switch]$Once,
  [string]$AutoSelect = '',
  # 自检钩子：配合 -AutoSelect 走「另存为」流程并直接存到这个路径（不弹保存窗口）
  [string]$AutoSavePath = '',
  # 自检钩子：只构建保存窗口、渲染成 PNG 后退出（用于离线检查界面布局）
  [string]$ProbeSaveDialog = '',
  # 自检钩子：用合成背景渲染覆盖层（含按钮条）成 PNG，不涉及真实桌面
  [string]$ProbeOverlay = ''
)

$ErrorActionPreference = 'Stop'

try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('DshShot.Win32' -as [type])) {
  Add-Type -Namespace DshShot -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll", SetLastError = true)] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
[DllImport("user32.dll", SetLastError = true)] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
[DllImport("user32.dll")] public static extern bool PeekMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax, uint wRemoveMsg);
[StructLayout(LayoutKind.Sequential)] public struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int ptX; public int ptY; }
'@
}

# 让进程感知 DPI，保证截图是物理像素、坐标不错位
try { [void][DshShot.Win32]::SetProcessDPIAware() } catch { }

# ---- UI 异常安全网 ----
# WinForms 事件处理里抛出的异常默认会走 Application.ThreadException，
# 不接管就会弹 .NET 的「未处理异常」对话框（还带 JIT 调试提示），用户一点「退出」助手就死了。
# 这里全部接管：只上报一行 ERROR 到 DSH 日志，并把覆盖层关掉，助手继续活着。
try {
  [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
} catch { }
try {
  [System.Windows.Forms.Application]::add_ThreadException({
    param($sender, $e)
    try { Emit-Error ('ui-exception: ' + $e.Exception.ToString()) } catch { }
    try {
      if ($script:UI.form) { $script:UI.cancelled = $true; $script:UI.form.Close() }
    } catch { }
  })
} catch { }
try {
  [System.AppDomain]::CurrentDomain.add_UnhandledException({
    param($sender, $e)
    try { Emit-Error ('unhandled: ' + [string]$e.ExceptionObject) } catch { }
  })
} catch { }

$WM_HOTKEY = 0x0312
$MOD_ALT = 0x0001
$MOD_CONTROL = 0x0002
$MOD_SHIFT = 0x0004
$MOD_WIN = 0x0008
$MOD_NOREPEAT = 0x4000

$STRINGS = @{
  zh = @{
    hint        = '拖动鼠标选择区域 · 方向键移动 · Shift+方向键缩放大小 · Enter 复制 · Esc 取消 · 也可点下方按钮'
    copied      = '已复制到剪贴板'
    empty       = '请先拖出一个区域'
    ok          = '确定'
    cancel      = '取消'
    saveAs      = '另存为'
    save        = '保存'
    browse      = '浏览…'
    format      = '图片格式：'
    path        = '保存路径：'
    resolution  = '分辨率：'
    thumbnail   = '缩略图'
    dialogTitle = '另存为'
    px          = ' 像素'
    pathEmpty   = '请先填写保存路径。'
    saveFailed  = '保存失败：'
    filterPng   = 'PNG 图片 (*.png)|*.png'
    filterJpg   = 'JPEG 图片 (*.jpg;*.jpeg)|*.jpg;*.jpeg'
    filterAll   = '所有文件 (*.*)|*.*'
  }
  en = @{
    hint        = 'Drag to select | Arrows move | Shift+Arrows resize | Enter copy | Esc cancel | or use the buttons'
    copied      = 'Copied to clipboard'
    empty       = 'Select an area first'
    ok          = 'OK'
    cancel      = 'Cancel'
    saveAs      = 'Save As'
    save        = 'Save'
    browse      = 'Browse…'
    format      = 'Format:'
    path        = 'Save to:'
    resolution  = 'Resolution:'
    thumbnail   = 'Preview'
    dialogTitle = 'Save As'
    px          = ' px'
    pathEmpty   = 'Please enter a save path first.'
    saveFailed  = 'Save failed: '
    filterPng   = 'PNG image (*.png)|*.png'
    filterJpg   = 'JPEG image (*.jpg;*.jpeg)|*.jpg;*.jpeg'
    filterAll   = 'All files (*.*)|*.*'
  }
}

function ConvertTo-Boolean([string]$Value, [bool]$Default) {
  if ($null -eq $Value) { return $Default }
  $text = $Value.Trim()
  if ($text -eq '') { return $Default }
  if ($text -match '^(?i)(1|true|yes|on)$') { return $true }
  if ($text -match '^(?i)(0|false|no|off)$') { return $false }
  return $Default
}

# 注意：不要在脚本作用域里复用同名参数变量（\$script:CopyToClipboard = \$CopyToClipboard）。
# 参数 [string] 的类型约束会留在脚本作用域上，把 \$false 又变回非空字符串 "False"（永远为真）。
# 统一放进无类型约束的配置哈希表。
$script:Cfg = @{
  CopyToClipboard  = ConvertTo-Boolean $CopyToClipboard $true
  Flash            = ConvertTo-Boolean $Flash $true
  ConfirmOnRelease = ConvertTo-Boolean $ConfirmOnRelease $false
  SaveDirectory    = $SaveDirectory
}
$script:T = $STRINGS[$Language]
$script:SizeFont = New-Object System.Drawing.Font 'Microsoft YaHei UI', 11, ([System.Drawing.FontStyle]::Bold)
$script:HeroFont = New-Object System.Drawing.Font 'Microsoft YaHei UI', 12, ([System.Drawing.FontStyle]::Bold)
$script:HintFont = New-Object System.Drawing.Font 'Microsoft YaHei UI', 10, ([System.Drawing.FontStyle]::Regular)
# 控件尺寸按字体的实际像素高度缩放，保证高 DPI 下按钮文字不会被裁掉
$script:UiScale = 1.0
try { $script:UiScale = [Math]::Max(1.0, ($script:HintFont.Height / 17.0)) } catch { $script:UiScale = 1.0 }

# 覆盖层拖拽时重绘非常频繁，画笔/画刷只建一次，避免每帧分配 GDI 对象
$script:DimBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(130, 0, 0, 0))
$script:LabelBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(205, 0, 0, 0))
$script:HintBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(190, 0, 0, 0))
$script:BorderPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(0, 160, 255)), 2
# 保存窗口的控件引用：事件处理器是从 WinForms 消息循环调用的，那时 New-SaveAsForm 的
# 函数作用域已经结束（PowerShell 动态作用域会读到 $null），所以必须走脚本作用域。
$script:SaveUI = @{
  Form      = $null
  PathBox   = $null
  FormatBox = $null
}

$script:UI = @{
  rect      = [System.Drawing.Rectangle]::Empty
  drag      = ''
  handle    = ''
  anchor    = [System.Drawing.Point]::Empty
  confirmed = $false
  cancelled = $false
  result    = $null
  autoParts = $null
  autoTimer = $null
  form      = $null
  paintRect = [System.Drawing.Rectangle]::Empty
}

#region ---------- 基础工具 ----------

function Write-ProtocolLine([string]$Text) {
  [Console]::Out.WriteLine($Text)
  [Console]::Out.Flush()
}

function Emit-Result($Result) {
  Write-ProtocolLine ('RESULT ' + ($Result | ConvertTo-Json -Compress))
}

function Emit-Error([string]$Text) {
  Write-ProtocolLine ('ERROR ' + $Text)
}

# ---- 路径工具 ----
# .NET Framework 的 Path.GetDirectoryName('') / 含控制字符的路径会直接抛
# ArgumentException（"路径的形式不合法"），一个没接住的调用就能弹异常对话框。
# 所有路径处理统一走下面这几个不会抛的包装。
function Get-SafeDirectoryName([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
  try { return [System.IO.Path]::GetDirectoryName($Path.Trim()) } catch { return '' }
}

function Get-SafeFileName([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
  try { return [System.IO.Path]::GetFileName($Path.Trim()) } catch { return '' }
}

function Get-SafeBaseName([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
  try { return [System.IO.Path]::GetFileNameWithoutExtension($Path.Trim()) } catch { return '' }
}

function Get-SafeExtension([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
  try { return [System.IO.Path]::GetExtension($Path.Trim()) } catch { return '' }
}

function Get-SafeCombine([string]$Dir, [string]$Name) {
  try {
    if ([string]::IsNullOrWhiteSpace($Dir)) { return $Name }
    return [System.IO.Path]::Combine($Dir.Trim(), $Name)
  } catch { return $Name }
}

# 只换了目录（或返回的路径没有文件名）时，把原来的文件名接回去 —— 改路径不用重新输文件名
function Get-CarriedFilePath([string]$Chosen, [string]$FallbackName) {
  if ([string]::IsNullOrWhiteSpace($Chosen)) { return $FallbackName }
  if (Get-SafeFileName $Chosen) { return $Chosen }
  $dir = Get-SafeDirectoryName $Chosen
  if ([string]::IsNullOrWhiteSpace($dir)) { return $FallbackName }
  return (Get-SafeCombine $dir $FallbackName)
}

# 目录是否可用：能解析成完整路径就算成立（非法字符/空串在这里会被挡掉）
function Test-UsableDirectory([string]$Candidate) {
  $dir = ([string]$Candidate).Trim()
  if ($dir.Length -lt 2) { return $false }
  try { [void][System.IO.Path]::GetFullPath($dir); return $true } catch { return $false }
}

function Clamp-Rect([System.Drawing.Rectangle]$Rect, [System.Drawing.Rectangle]$Bounds) {
  $w = [Math]::Min($Rect.Width, $Bounds.Width)
  $h = [Math]::Min($Rect.Height, $Bounds.Height)
  if ($w -lt 0) { $w = 0 }
  if ($h -lt 0) { $h = 0 }
  $x = [Math]::Max($Bounds.Left, [Math]::Min($Rect.X, $Bounds.Right - $w))
  $y = [Math]::Max($Bounds.Top, [Math]::Min($Rect.Y, $Bounds.Bottom - $h))
  return (New-Object System.Drawing.Rectangle $x, $y, $w, $h)
}

function Set-RectEdges([int]$Left, [int]$Top, [int]$Right, [int]$Bottom) {
  if ($Right -lt $Left) { $t = $Left; $Left = $Right; $Right = $t }
  if ($Bottom -lt $Top) { $t = $Top; $Top = $Bottom; $Bottom = $t }
  $script:UI.rect = New-Object System.Drawing.Rectangle $Left, $Top, ($Right - $Left), ($Bottom - $Top)
}

function Get-ScreenBitmap([System.Drawing.Rectangle]$Rect) {
  if ($Rect.Width -lt 1 -or $Rect.Height -lt 1) { throw 'empty capture rect' }
  $bmp = New-Object System.Drawing.Bitmap ($Rect.Width), ($Rect.Height)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  try {
    $g.CopyFromScreen($Rect.X, $Rect.Y, 0, 0, (New-Object System.Drawing.Size ($Rect.Width), ($Rect.Height)), [System.Drawing.CopyPixelOperation]::SourceCopy)
  } finally {
    $g.Dispose()
  }
  return $bmp
}

function Copy-ImageToClipboard([System.Drawing.Image]$Image) {
  for ($i = 0; $i -lt 6; $i++) {
    try {
      [System.Windows.Forms.Clipboard]::SetDataObject($Image, $true)
      return $true
    } catch {
      Start-Sleep -Milliseconds 150
    }
  }
  return $false
}

# 按扩展名决定编码：.jpg/.jpeg 走 WPF JPEG 编码器（质量 90），其余按 PNG。
# 注意：不要改回 ImageCodecInfo + EncoderParameters 那套写法 —— 那个组合会被
# Windows Defender 的 AMSI 当作恶意脚本特征拦下来，整份脚本都跑不起来。
# WPF 的 JpegBitmapEncoder 同样能控质量，且不触发该特征。
function Save-ImageByExtension([System.Drawing.Image]$Image, [string]$Path) {
  try {
    $dir = Get-SafeDirectoryName $Path
    if ($dir -and -not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    $ext = (Get-SafeExtension $Path).ToLowerInvariant()
    if ($ext -eq '.jpg' -or $ext -eq '.jpeg') {
      try {
        Add-Type -AssemblyName PresentationCore
        $memory = New-Object System.IO.MemoryStream
        $Image.Save($memory, [System.Drawing.Imaging.ImageFormat]::Png)
        $memory.Position = 0
        $frame = [System.Windows.Media.Imaging.BitmapFrame]::Create($memory)
        $jpeg = New-Object System.Windows.Media.Imaging.JpegBitmapEncoder
        $jpeg.QualityLevel = 90
        $jpeg.Frames.Add($frame)
        $target = [System.IO.File]::Create($Path)
        $jpeg.Save($target)
        $target.Close()
        $memory.Dispose()
      } catch {
        $Image.Save($Path, [System.Drawing.Imaging.ImageFormat]::Jpeg)
      }
    } else {
      $Image.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    return $true
  } catch {
    Emit-Error ('save-failed: ' + $_.Exception.Message)
    return $false
  }
}

function Save-ImagePng([System.Drawing.Image]$Image, [string]$Path) {
  try {
    $dir = Get-SafeDirectoryName $Path
    if ($dir -and -not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    $Image.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    return $true
  } catch {
    Emit-Error ('save-failed: ' + $_.Exception.Message)
    return $false
  }
}

function Complete-Capture([System.Drawing.Bitmap]$Image, [System.Drawing.Rectangle]$Rect, [string]$TargetPath = '') {
  $copied = $false
  if ($script:Cfg.CopyToClipboard) { $copied = Copy-ImageToClipboard $Image }
  $file = ''
  if ($TargetPath -ne '') {
    # 「另存为」指定了路径：按扩展名写文件（png / jpg）
    if (Save-ImageByExtension $Image $TargetPath) { $file = $TargetPath }
  } elseif ($script:Cfg.SaveDirectory) {
    # 配置了 saveDirectory：自动命名一份 PNG
    $name = 'screenshot-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.png'
    $target = Get-SafeCombine $script:Cfg.SaveDirectory $name
    if (Save-ImagePng $Image $target) { $file = $target }
  }
  $format = ''
  if ($file -ne '') { $format = (Get-SafeExtension $file).TrimStart('.').ToLowerInvariant() }
  return [pscustomobject]@{
    ok        = $true
    x         = $Rect.X
    y         = $Rect.Y
    width     = $Rect.Width
    height    = $Rect.Height
    clipboard = $copied
    file      = $file
    format    = $format
  }
}

function Show-CaptureFlash([System.Drawing.Rectangle]$Rect, [string]$Message) {
  if (-not $script:Cfg.Flash) { return }
  try {
    $key = [System.Drawing.Color]::FromArgb(255, 0, 255)
    $form = New-Object System.Windows.Forms.Form
    $form.FormBorderStyle = 'None'
    $form.StartPosition = 'Manual'
    $bounds = New-Object System.Drawing.Rectangle $Rect.X, $Rect.Y, ([Math]::Max($Rect.Width, 260)), ([Math]::Max($Rect.Height, 96))
    $form.Bounds = $bounds
    $form.TopMost = $true
    $form.ShowInTaskbar = $false
    $form.BackColor = $key
    $form.TransparencyKey = $key
    $form.Tag = $Message
    $form.Add_Paint({
      param($sender, $e)
      $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(0, 178, 120)), 3
      $e.Graphics.DrawRectangle($pen, 1, 1, [Math]::Max(1, ($sender.ClientSize.Width - 3)), [Math]::Max(1, ($sender.ClientSize.Height - 3)))
      $pen.Dispose()
      if ($sender.Tag) {
        $text = [string]$sender.Tag
        $size = $e.Graphics.MeasureString($text, $script:HeroFont)
        $box = New-Object System.Drawing.Rectangle 8, 8, ([int]$size.Width + 16), ([int]$size.Height + 8)
        $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(225, 0, 150, 100))
        $e.Graphics.FillRectangle($brush, $box)
        $brush.Dispose()
        $e.Graphics.DrawString($text, $script:HeroFont, [System.Drawing.Brushes]::White, 15, 12)
      }
    })
    $form.Show()
    $form.Update()
    Start-Sleep -Milliseconds 300
    $form.Close()
    $form.Dispose()
  } catch {
    # 提示失败不影响截图结果
  }
}

function Parse-Hotkey([string]$Spec) {
  $mods = 0
  $key = ''
  foreach ($part in ($Spec -split '\+')) {
    $token = $part.Trim()
    if ($token -eq '') { continue }
    if ($token -match '(?i)^alt$') { $mods = $mods -bor $MOD_ALT; continue }
    if ($token -match '(?i)^(ctrl|control)$') { $mods = $mods -bor $MOD_CONTROL; continue }
    if ($token -match '(?i)^shift$') { $mods = $mods -bor $MOD_SHIFT; continue }
    if ($token -match '(?i)^(win|meta|super|cmd)$') { $mods = $mods -bor $MOD_WIN; continue }
    $key = $token
  }
  if ($key -eq '') { throw ("热键缺少按键：" + $Spec) }
  $vk = 0
  if ($key.Length -eq 1) {
    $vk = [int][char]([char]::ToUpperInvariant($key[0]))
  } else {
    $named = @{
      'F1' = 112; 'F2' = 113; 'F3' = 114; 'F4' = 115; 'F5' = 116; 'F6' = 117
      'F7' = 118; 'F8' = 119; 'F9' = 120; 'F10' = 121; 'F11' = 122; 'F12' = 123
      'PrintScreen' = 44; 'Insert' = 45; 'Delete' = 46; 'Home' = 36; 'End' = 35
      'PageUp' = 33; 'PageDown' = 34; 'Space' = 32; 'Spacebar' = 32; 'Tab' = 9
      'Enter' = 13; 'Return' = 13; 'Escape' = 27; 'Esc' = 27; 'Backspace' = 8
      'Minus' = 189; 'Equals' = 187; 'Comma' = 188; 'Period' = 190; 'Slash' = 191
      'Semicolon' = 186; 'Quote' = 222; 'BracketLeft' = 219; 'BracketRight' = 221
      'Backslash' = 220; 'Grave' = 192
    }
    if ($named.ContainsKey($key)) {
      $vk = $named[$key]
    } elseif ($key -match '^[0-9]$') {
      $vk = [int][char]$key
    } elseif ($key -match '(?i)^Num([0-9])$') {
      $vk = 96 + [int]$Matches[1]
    } else {
      throw ("不支持的热键按键：" + $key)
    }
  }
  return @($mods, $vk)
}

#region ---------- 保存窗口与操作按钮 ----------

function Scale-Px([double]$Value) {
  $scaled = [int][Math]::Round($Value * $script:UiScale)
  if ($scaled -lt 1) { return 1 }
  return $scaled
}

# 覆盖层上的深色按钮（确定 / 取消 / 另存为）
function New-ActionButton([string]$Text) {
  $button = New-Object System.Windows.Forms.Button
  $button.Text = $Text
  $button.AutoSize = $true
  $button.AutoSizeMode = 'GrowAndShrink'
  $button.Padding = New-Object System.Windows.Forms.Padding -ArgumentList @((Scale-Px 12), (Scale-Px 5), (Scale-Px 12), (Scale-Px 5))
  $button.FlatStyle = 'Flat'
  $button.FlatAppearance.BorderSize = 1
  $button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(120, 120, 120)
  $button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
  $button.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
  $button.BackColor = [System.Drawing.Color]::FromArgb(58, 58, 58)
  $button.ForeColor = [System.Drawing.Color]::White
  $button.Font = $script:HintFont
  $button.TabStop = $false
  $button.UseVisualStyleBackColor = $false
  $button.Cursor = [System.Windows.Forms.Cursors]::Hand
  $button.Margin = New-Object System.Windows.Forms.Padding -ArgumentList @(0)
  return $button
}

# 拖拽时只需要重画「新旧选区 + 边框 + 尺寸标签」覆盖的范围，
# 其余部分（整屏暗化 / 原始画面）没有变化，不必重绘 —— 这是消除拖拽卡顿的关键。
function Get-OverlayDirtyRect([System.Drawing.Rectangle]$Before, [System.Drawing.Rectangle]$After, [System.Drawing.Rectangle]$Client) {
  $union = $After
  if ($Before.Width -ge 3 -and $Before.Height -ge 3) {
    if ($After.Width -ge 3 -and $After.Height -ge 3) { $union = [System.Drawing.Rectangle]::Union($Before, $After) }
    else { $union = $Before }
  }
  $padLeft = Scale-Px 12
  $padTop = Scale-Px 52
  $padRight = Scale-Px 150
  $padBottom = Scale-Px 16
  $dirty = New-Object System.Drawing.Rectangle ($union.X - $padLeft), ($union.Y - $padTop), ($union.Width + $padLeft + $padRight), ($union.Height + $padTop + $padBottom)
  # 选区靠近底部提示条时，把整条提示带一起重画：否则移动中的边框会在提示文字上留下残影
  $bandTop = $Client.Bottom - (Scale-Px 110)
  if ($bandTop -gt $Client.Top -and $dirty.Bottom -gt $bandTop) {
    $band = New-Object System.Drawing.Rectangle $Client.Left, $bandTop, $Client.Width, ($Client.Bottom - $bandTop)
    $dirty = [System.Drawing.Rectangle]::Union($dirty, $band)
  }
  return $dirty
}

# 按钮条跟着选区走：优先放在选区下方，放不下就放进选区底部，并夹在屏幕内
function Update-OverlayToolbar($Form, $Toolbar, [System.Drawing.Rectangle]$Vs) {
  $rect = $script:UI.rect
  # 拖拽过程中不显示按钮条（拖完再出现），也省掉每次移动都重排按钮的开销
  if ($script:UI.drag -ne '' -or $rect.Width -lt 3 -or $rect.Height -lt 3) {
    $Toolbar.Visible = $false
    return
  }
  $client = $Form.ClientRectangle
  $size = $Toolbar.PreferredSize
  $w = $size.Width
  $h = $size.Height
  if ($w -le 0) { $w = $Toolbar.Width }
  if ($h -le 0) { $h = $Toolbar.Height }
  $rc = New-Object System.Drawing.Rectangle ($rect.X - $Vs.X), ($rect.Y - $Vs.Y), $rect.Width, $rect.Height
  $gap = Scale-Px 8
  $x = $rc.Left
  $y = $rc.Bottom + $gap
  if ($y + $h -gt $client.Height) { $y = $rc.Bottom - $h - $gap }
  if ($y -lt 0) { $y = 0 }
  if ($x + $w -gt $client.Width) { $x = $client.Width - $w - $gap }
  if ($x -lt 0) { $x = 0 }
  $target = New-Object System.Drawing.Point $x, $y
  if ($Toolbar.Visible -and $Toolbar.Location -eq $target) { return }
  $Toolbar.Location = $target
  $Toolbar.Visible = $true
  $Toolbar.BringToFront()
}

# 默认保存路径：候选目录按可靠性排序，逐个探测（非法字符/空串/不存在都会被跳过），
# 保证一定返回一个能用的完整路径；顺便打一行日志，出问题时能直接看到算出来的是什么。
function Get-DefaultSavePath([string]$Format) {
  $ext = if ($Format -eq 'jpg') { '.jpg' } else { '.png' }
  $name = 'screenshot-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + $ext
  $candidates = New-Object System.Collections.ArrayList
  try { [void]$candidates.Add([string]$script:Cfg.SaveDirectory) } catch { }
  foreach ($special in @('MyPictures', 'Desktop', 'MyDocuments')) {
    try { [void]$candidates.Add([string][System.Environment]::GetFolderPath($special)) } catch { }
  }
  foreach ($envName in @('USERPROFILE', 'TEMP', 'TMP')) {
    try { [void]$candidates.Add([string][System.Environment]::GetEnvironmentVariable($envName)) } catch { }
  }
  try { [void]$candidates.Add([string][System.IO.Path]::GetTempPath()) } catch { }
  try { [void]$candidates.Add((Get-Location).Path) } catch { }
  $chosen = ''
  foreach ($candidate in $candidates) {
    if (Test-UsableDirectory $candidate) { $chosen = ([string]$candidate).Trim(); break }
  }
  if ($chosen -eq '') {
    try { $chosen = ([string][System.IO.Path]::GetTempPath()).Trim() } catch { $chosen = '' }
  }
  $path = Get-SafeCombine $chosen $name
  Write-ProtocolLine ('DEBUG save-default=' + $path)
  return $path
}

# 保存窗口：缩略图 + 分辨率 + 图片格式（PNG/JPG）+ 保存路径
function New-SaveAsForm([System.Drawing.Bitmap]$Image) {
  $t = $script:T
  $font = $script:HintFont
  $bold = $script:SizeFont
  $textHeight = 17
  try { $textHeight = [System.Windows.Forms.TextRenderer]::MeasureText('确定', $font).Height } catch { }
  if ($textHeight -lt 1) { $textHeight = 17 }

  $margin = Scale-Px 18
  $clientWidth = Scale-Px 660
  $clientHeight = Scale-Px 500
  $previewWidth = Scale-Px 320
  $rightX = $margin + $previewWidth + (Scale-Px 20)
  $rightWidth = $clientWidth - $rightX - $margin
  $buttonHeight = $textHeight + (Scale-Px 14)
  $buttonWidth = [int][Math]::Max((Scale-Px 92), ($textHeight * 5))
  $boxHeight = $textHeight + (Scale-Px 12)

  $form = New-Object System.Windows.Forms.Form
  $form.Text = [string]$t.dialogTitle
  $form.FormBorderStyle = 'FixedDialog'
  $form.MaximizeBox = $false
  $form.MinimizeBox = $false
  $form.ShowInTaskbar = $false
  $form.StartPosition = 'CenterParent'
  $form.TopMost = $true
  $form.AutoScaleMode = 'None'
  $form.Font = $font
  $form.ClientSize = New-Object System.Drawing.Size $clientWidth, $clientHeight
  $form.BackColor = [System.Drawing.Color]::FromArgb(248, 248, 248)

  $caption = New-Object System.Windows.Forms.Label
  $caption.Text = [string]$t.thumbnail
  $caption.Font = $bold
  $caption.Location = New-Object System.Drawing.Point $margin, (Scale-Px 16)
  $caption.AutoSize = $true
  [void]$form.Controls.Add($caption)

  $preview = New-Object System.Windows.Forms.PictureBox
  $preview.Location = New-Object System.Drawing.Point $margin, (Scale-Px 44)
  $preview.Size = New-Object System.Drawing.Size $previewWidth, (Scale-Px 300)
  $preview.SizeMode = 'Zoom'
  $preview.BorderStyle = 'FixedSingle'
  $preview.BackColor = [System.Drawing.Color]::White
  $preview.Image = $Image
  [void]$form.Controls.Add($preview)

  $resolution = New-Object System.Windows.Forms.Label
  $resolution.Text = [string]$t.resolution + [string]$Image.Width + ' × ' + [string]$Image.Height + [string]$t.px
  $resolution.Font = $bold
  $resolution.Location = New-Object System.Drawing.Point $rightX, (Scale-Px 16)
  $resolution.AutoSize = $true
  [void]$form.Controls.Add($resolution)

  $formatLabel = New-Object System.Windows.Forms.Label
  $formatLabel.Text = [string]$t.format
  $formatLabel.Location = New-Object System.Drawing.Point $rightX, (Scale-Px 58)
  $formatLabel.AutoSize = $true
  [void]$form.Controls.Add($formatLabel)

  $formatBox = New-Object System.Windows.Forms.ComboBox
  $formatBox.DropDownStyle = 'DropDownList'
  $formatBox.Location = New-Object System.Drawing.Point $rightX, (Scale-Px 80)
  $formatBox.Size = New-Object System.Drawing.Size (Scale-Px 160), $boxHeight
  $formatBox.Font = $font
  $formatBox.TabStop = $false
  [void]$formatBox.Items.Add('PNG')
  [void]$formatBox.Items.Add('JPG')
  [void]$form.Controls.Add($formatBox)

  $pathLabel = New-Object System.Windows.Forms.Label
  $pathLabel.Text = [string]$t.path
  $pathLabel.Location = New-Object System.Drawing.Point $margin, (Scale-Px 366)
  $pathLabel.AutoSize = $true
  [void]$form.Controls.Add($pathLabel)

  $pathBox = New-Object System.Windows.Forms.TextBox
  # 路径单独占一整行，长路径也能看全
  $pathBox.Location = New-Object System.Drawing.Point $margin, (Scale-Px 388)
  $pathBox.Size = New-Object System.Drawing.Size ($clientWidth - $margin - $margin - $buttonWidth - (Scale-Px 10)), $boxHeight
  $pathBox.Font = $font
  $pathBox.Text = Get-DefaultSavePath 'png'
  [void]$form.Controls.Add($pathBox)

  $browse = New-Object System.Windows.Forms.Button
  $browse.Text = [string]$t.browse
  $browse.Font = $font
  $browse.Size = New-Object System.Drawing.Size $buttonWidth, $boxHeight
  $browse.Location = New-Object System.Drawing.Point ($clientWidth - $margin - $buttonWidth), (Scale-Px 388)
  $browse.TabStop = $false
  [void]$form.Controls.Add($browse)

  $cancel = New-Object System.Windows.Forms.Button
  $cancel.Text = [string]$t.cancel
  $cancel.Font = $font
  $cancel.Size = New-Object System.Drawing.Size $buttonWidth, $buttonHeight
  $cancel.Location = New-Object System.Drawing.Point ($clientWidth - $margin - $buttonWidth), ($clientHeight - $margin - $buttonHeight)
  $cancel.TabStop = $false
  [void]$form.Controls.Add($cancel)

  $save = New-Object System.Windows.Forms.Button
  $save.Text = [string]$t.save
  $save.Font = $font
  $save.Size = New-Object System.Drawing.Size $buttonWidth, $buttonHeight
  $save.Location = New-Object System.Drawing.Point ($cancel.Location.X - (Scale-Px 10) - $buttonWidth), $cancel.Location.Y
  $save.TabStop = $false
  [void]$form.Controls.Add($save)

  $form.AcceptButton = $save
  $form.CancelButton = $cancel

  # ⚠️ 关键：这些处理器是在 New-SaveAsForm 返回之后由 WinForms 消息循环调用的。
  # PowerShell 处理器用动态作用域查变量，那时本函数作用域已经不存在，
  # 处理器里读 $pathBox / $form 只会拿到 $null —— 这正是之前
  # 「请先填写保存路径」和「找不到属性 Text，请确认该属性存在并且可设置」的根因。
  # 所以控件引用一律挂到脚本作用域，跨处理器永远可见。
  $script:SaveUI.Form = $form
  $script:SaveUI.PathBox = $pathBox
  $script:SaveUI.FormatBox = $formatBox

  # 切换格式时同步改扩展名
  $formatBox.Add_SelectedIndexChanged({
    $path = $script:SaveUI.PathBox
    $box = $script:SaveUI.FormatBox
    if ($null -eq $path -or $null -eq $box) { return }
    $ext = if ($box.SelectedIndex -eq 1) { '.jpg' } else { '.png' }
    $current = ([string]$path.Text).Trim()
    $dir = Get-SafeDirectoryName $current
    $base = Get-SafeBaseName $current
    if ($base -eq '') { $base = 'screenshot' }
    if ($dir) { $path.Text = Get-SafeCombine $dir ($base + $ext) } else { $path.Text = $base + $ext }
  })
  $formatBox.SelectedIndex = 0

  $browse.Add_Click({
    $state = $script:SaveUI
    $path = $state.PathBox
    if ($null -eq $path) { return }
    $box = $state.FormatBox
    $strings = $script:T
    $current = ([string]$path.Text).Trim()
    # 原文件名：没有就现造一个；用户换目录时直接沿用，不用手动输文件名
    $carriedName = Get-SafeFileName $current
    if ($carriedName -eq '') {
      $suffix = '.png'
      if ($null -ne $box -and $box.SelectedIndex -eq 1) { $suffix = '.jpg' }
      $carriedName = 'screenshot-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + $suffix
    }
    $oldDir = Get-SafeDirectoryName $current
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Title = [string]$strings.dialogTitle
    $dialog.Filter = ([string]$strings.filterPng + '|' + [string]$strings.filterJpg + '|' + [string]$strings.filterAll)
    if ($null -ne $box -and $box.SelectedIndex -eq 1) { $dialog.FilterIndex = 2 } else { $dialog.FilterIndex = 1 }
    $dialog.AddExtension = $true
    $dialog.OverwritePrompt = $true
    $dialog.FileName = $carriedName
    if ($oldDir -and [System.IO.Directory]::Exists($oldDir)) { $dialog.InitialDirectory = $oldDir }
    $accepted = $false
    if ($null -ne $state.Form) { $accepted = ($dialog.ShowDialog($state.Form) -eq [System.Windows.Forms.DialogResult]::OK) }
    else { $accepted = ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) }
    if ($accepted) {
      $path.Text = Get-CarriedFilePath ([string]$dialog.FileName) $carriedName
      $chosenExt = (Get-SafeExtension ([string]$dialog.FileName)).ToLowerInvariant()
      if ($null -ne $box) {
        if ($chosenExt -eq '.jpg' -or $chosenExt -eq '.jpeg') { $box.SelectedIndex = 1 }
        elseif ($chosenExt -eq '.png') { $box.SelectedIndex = 0 }
      }
    }
    $dialog.Dispose()
  })

  $save.Add_Click({
    $state = $script:SaveUI
    $path = $state.PathBox
    if ($null -eq $path -or $null -eq $state.Form) { return }
    $strings = $script:T
    $target = ([string]$path.Text).Trim()
    if ($target -eq '') {
      [void][System.Windows.Forms.MessageBox]::Show([string]$strings.pathEmpty, [string]$strings.dialogTitle, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
      return
    }
    $ext = (Get-SafeExtension $target).ToLowerInvariant()
    if ($ext -ne '.png' -and $ext -ne '.jpg' -and $ext -ne '.jpeg') {
      if ($null -ne $state.FormatBox -and $state.FormatBox.SelectedIndex -eq 1) { $target = $target + '.jpg' } else { $target = $target + '.png' }
    }
    $state.Form.Tag = $target
    $state.Form.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $state.Form.Close()
  })

  # 打开时预选文件名（目录部分保留可见），方便直接改名保存；整体 try 住，绝不让它把对话框炸掉
  $form.Add_Shown({
    try {
      $path = $script:SaveUI.PathBox
      if ($null -eq $path) { return }
      $current = ([string]$path.Text).Trim()
      $dir = Get-SafeDirectoryName $current
      if ($dir -and $current.Length -gt $dir.Length) {
        $path.SelectionStart = $dir.Length + 1
        $path.SelectionLength = $current.Length - $dir.Length - 1
      } else {
        $path.SelectAll()
      }
    } catch { }
  })

  $cancel.Add_Click({
    $state = $script:SaveUI
    if ($null -eq $state.Form) { return }
    $state.Form.Tag = $null
    $state.Form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $state.Form.Close()
  })

  return $form
}

function Show-SaveAsDialog([System.Drawing.Bitmap]$Image) {
  $form = $null
  try {
    $form = New-SaveAsForm $Image
    if ($script:UI.form) { [void]$form.ShowDialog($script:UI.form) } else { [void]$form.ShowDialog() }
    if ($form.Tag) { return [string]$form.Tag }
    return ''
  } catch {
    # 保存窗口本身出问题也不能把常驻助手带崩：上报一行日志，退回选区界面
    Emit-Error ('save-dialog-failed: ' + $_.Exception.Message)
    return ''
  } finally {
    if ($form) { try { $form.Dispose() } catch { } }
    if ($script:SaveUI.Form -eq $form) {
      $script:SaveUI.Form = $null
      $script:SaveUI.PathBox = $null
      $script:SaveUI.FormatBox = $null
    }
  }
}

# 「另存为」：先裁剪出当前选区，再弹保存窗口；取消则留在选区界面继续调整
function Invoke-SaveAsSelection([System.Drawing.Bitmap]$Screen) {
  $rect = $script:UI.rect
  if ($rect.Width -lt 3 -or $rect.Height -lt 3) { return }
  $crop = $Screen.Clone($rect, $Screen.PixelFormat)
  try {
    $target = ''
    if ($AutoSavePath -ne '') { $target = $AutoSavePath } else { $target = Show-SaveAsDialog $crop }
    if (-not $target) { return }
    $script:UI.result = Complete-Capture $crop $rect -TargetPath $target
  } finally {
    $crop.Dispose()
  }
  $script:UI.confirmed = $true
  $script:UI.form.Close()
}

#endregion

#region ---------- 固定大小截图 ----------

function Invoke-FixedCapture {
  $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
  $w = $script:TargetWidth
  $h = $script:TargetHeight
  if ($w -lt 1 -or $h -lt 1) { throw 'fixed 模式需要配置 width 与 height' }
  $cursor = [System.Windows.Forms.Cursor]::Position
  $rect = New-Object System.Drawing.Rectangle ([int]($cursor.X - $w / 2)), ([int]($cursor.Y - $h / 2)), $w, $h
  $rect = Clamp-Rect $rect $vs
  $bmp = Get-ScreenBitmap $rect
  try {
    return (Complete-Capture $bmp $rect)
  } finally {
    $bmp.Dispose()
  }
}

#endregion

#region ---------- 区域选择截图 ----------

function Invoke-ConfirmSelection($Form, [System.Drawing.Bitmap]$Screen, [string]$TargetPath = '') {
  $rect = $script:UI.rect
  if ($rect.Width -lt 3 -or $rect.Height -lt 3) { return }
  $crop = $Screen.Clone($rect, $Screen.PixelFormat)
  try {
    $script:UI.result = Complete-Capture $crop $rect -TargetPath $TargetPath
  } finally {
    $crop.Dispose()
  }
  $script:UI.confirmed = $true
  $Form.Close()
}

# 自检用合成背景：不含任何真实桌面内容
function New-ProbeScreen([System.Drawing.Rectangle]$Rect) {
  $bmp = New-Object System.Drawing.Bitmap $Rect.Width, $Rect.Height
  $graphics = [System.Drawing.Graphics]::FromImage($bmp)
  $graphics.Clear([System.Drawing.Color]::FromArgb(236, 238, 242))
  $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(214, 219, 226)), 1
  for ($x = 0; $x -lt $Rect.Width; $x += 40) { $graphics.DrawLine($pen, $x, 0, $x, $Rect.Height) }
  for ($y = 0; $y -lt $Rect.Height; $y += 40) { $graphics.DrawLine($pen, 0, $y, $Rect.Width, $y) }
  $pen.Dispose()
  $graphics.DrawString('PROBE SCREEN', $script:SizeFont, [System.Drawing.Brushes]::Gray, 20, 20)
  $graphics.Dispose()
  return $bmp
}

function Invoke-RegionCapture {
  if ($ProbeOverlay -ne '') {
    if ($AutoSelect -eq '') { $AutoSelect = '120,90,420,300' }
    $vs = New-Object System.Drawing.Rectangle 0, 0, 900, 620
    $screen = New-ProbeScreen $vs
  } else {
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    # 先拍照再显示覆盖层，保证覆盖层不会出现在截图里
    $screen = Get-ScreenBitmap $vs
  }

  $script:UI.rect = [System.Drawing.Rectangle]::Empty
  $script:UI.drag = ''
  $script:UI.handle = ''
  $script:UI.confirmed = $false
  $script:UI.cancelled = $false
  $script:UI.result = $null

  $form = New-Object System.Windows.Forms.Form
  $form.FormBorderStyle = 'None'
  $form.StartPosition = 'Manual'
  $form.Bounds = $vs
  $form.TopMost = $true
  $form.ShowInTaskbar = $false
  $form.KeyPreview = $true
  $form.Cursor = [System.Windows.Forms.Cursors]::Cross
  $form.Text = 'DSH Screenshot'
  try {
    $prop = [System.Windows.Forms.Control].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
    $prop.SetValue($form, $true, $null)
  } catch { }
  $script:UI.form = $form

  # 底部提示文字是固定的，尺寸只量一次（每次重绘都 MeasureString 是一笔白开销）
  $hintText = [string]$script:T.hint
  $hintWidth = 0
  $hintHeight = 0
  try {
    $ruler = New-Object System.Drawing.Bitmap 1, 1
    $rulerGraphics = [System.Drawing.Graphics]::FromImage($ruler)
    $hintSize = $rulerGraphics.MeasureString($hintText, $script:HintFont)
    $hintWidth = [int]$hintSize.Width
    $hintHeight = [int]$hintSize.Height
    $rulerGraphics.Dispose()
    $ruler.Dispose()
  } catch { }

  # 配置了初始大小时，以鼠标位置为中心预置选区，之后仍可拖动/缩放
  if ($Width -gt 0 -and $Height -gt 0) {
    $cursor = [System.Windows.Forms.Cursor]::Position
    $preset = New-Object System.Drawing.Rectangle ([int]($cursor.X - $Width / 2)), ([int]($cursor.Y - $Height / 2)), $Width, $Height
    $script:UI.rect = Clamp-Rect $preset $vs
  }

  # ⚠️ 覆盖层下面这些处理器之所以能读到 $vs / $screen / $hintText 等函数局部变量，是因为
  # Invoke-RegionCapture 仍在调用栈上（ShowDialog 是在它内部调用的）—— PowerShell 的
  # 事件处理器是按动态作用域查变量的。一旦把这些处理器挪到别的函数里去调用，它们就会读到
  # $null（保存窗口就踩过这个坑，见 New-SaveAsForm 里把控件放进 $script:SaveUI 的说明）。
  # 以后要重构这里，记得把这些变量也搬进脚本作用域。
  $form.Add_Paint({
    param($sender, $e)
    $graphics = $e.Graphics
    $client = $sender.ClientRectangle
    # 拖拽时只重绘 Invalidate(矩形) 指定的区域：整屏位图只贴这一小块
    $clip = $e.ClipRectangle
    if ($clip.Width -gt 0 -and $clip.Height -gt 0) {
      $mode = $graphics.InterpolationMode
      $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
      $graphics.DrawImage($screen, $clip, $clip, [System.Drawing.GraphicsUnit]::Pixel)
      $graphics.InterpolationMode = $mode
    } else {
      $graphics.DrawImageUnscaled($screen, 0, 0)
    }
    $rect = $script:UI.rect
    $dim = $script:DimBrush
    if ($rect.Width -lt 3 -or $rect.Height -lt 3) {
      $graphics.FillRectangle($dim, $client)
    } else {
      $rc = New-Object System.Drawing.Rectangle ($rect.X - $vs.X), ($rect.Y - $vs.Y), $rect.Width, $rect.Height
      if ($rc.Top -gt $client.Top) { $graphics.FillRectangle($dim, $client.Left, $client.Top, $client.Width, ($rc.Top - $client.Top)) }
      if ($rc.Bottom -lt $client.Bottom) { $graphics.FillRectangle($dim, $client.Left, $rc.Bottom, $client.Width, ($client.Bottom - $rc.Bottom)) }
      $bandTop = [Math]::Max($rc.Top, $client.Top)
      $bandBottom = [Math]::Min($rc.Bottom, $client.Bottom)
      $bandHeight = [Math]::Max(0, ($bandBottom - $bandTop))
      if ($rc.Left -gt $client.Left) { $graphics.FillRectangle($dim, $client.Left, $bandTop, ($rc.Left - $client.Left), $bandHeight) }
      if ($rc.Right -lt $client.Right) { $graphics.FillRectangle($dim, $rc.Right, $bandTop, ($client.Right - $rc.Right), $bandHeight) }
      $graphics.DrawRectangle($script:BorderPen, $rc)
      $label = [string]$rect.Width + ' x ' + [string]$rect.Height
      $textSize = $graphics.MeasureString($label, $script:SizeFont)
      $lx = $rc.Left
      $ly = $rc.Top - [int]$textSize.Height - 8
      if ($ly -lt 0) { $ly = $rc.Top + 8 }
      $box = New-Object System.Drawing.Rectangle $lx, $ly, ([int]$textSize.Width + 16), ([int]$textSize.Height + 8)
      $graphics.FillRectangle($script:LabelBrush, $box)
      $graphics.DrawString($label, $script:SizeFont, [System.Drawing.Brushes]::White, ($lx + 8), ($ly + 4))
    }
    $hx = [int](($client.Width - $hintWidth) / 2)
    $hy = $client.Bottom - $hintHeight - 24
    $hintBox = New-Object System.Drawing.Rectangle ($hx - 14), ($hy - 8), ($hintWidth + 28), ($hintHeight + 16)
    $graphics.FillRectangle($script:HintBrush, $hintBox)
    $graphics.DrawString($hintText, $script:HintFont, [System.Drawing.Brushes]::White, $hx, $hy)
  })

  # ---------- 操作按钮条：确定 / 取消 / 另存为 ----------
  $toolbar = New-Object System.Windows.Forms.FlowLayoutPanel
  $toolbar.FlowDirection = 'LeftToRight'
  $toolbar.WrapContents = $false
  $toolbar.AutoSize = $true
  $toolbar.AutoSizeMode = 'GrowAndShrink'
  $toolbar.Padding = New-Object System.Windows.Forms.Padding -ArgumentList @((Scale-Px 6), (Scale-Px 6), (Scale-Px 6), (Scale-Px 6))
  $toolbar.BackColor = [System.Drawing.Color]::FromArgb(238, 30, 30, 30)
  $toolbar.Visible = $false
  $toolbar.TabStop = $false

  $okButton = New-ActionButton ([string]$script:T.ok)
  $cancelButton = New-ActionButton ([string]$script:T.cancel)
  $saveAsButton = New-ActionButton ([string]$script:T.saveAs)

  $okButton.Add_Click({
    if ($script:UI.rect.Width -ge 3 -and $script:UI.rect.Height -ge 3) { Invoke-ConfirmSelection $script:UI.form $screen }
  })
  $cancelButton.Add_Click({
    $script:UI.cancelled = $true
    $script:UI.form.Close()
  })
  $saveAsButton.Add_Click({ Invoke-SaveAsSelection $screen })

  [void]$toolbar.Controls.Add($okButton)
  [void]$toolbar.Controls.Add($cancelButton)
  [void]$toolbar.Controls.Add($saveAsButton)
  [void]$form.Controls.Add($toolbar)

  $form.Add_MouseDown({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
      $script:UI.cancelled = $true
      $sender.Close()
      return
    }
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    # 一开始拖拽就收起按钮条（用户要求：拖完再出现），同时避免拖拽时重排按钮
    if ($toolbar.Visible) { $toolbar.Visible = $false }
    $point = New-Object System.Drawing.Point ($e.X + $vs.X), ($e.Y + $vs.Y)
    $rect = $script:UI.rect
    if ($rect.Width -ge 3 -and $rect.Height -ge 3) {
      $tol = 8
      $nearLeft = [Math]::Abs($point.X - $rect.Left) -le $tol
      $nearRight = [Math]::Abs($point.X - $rect.Right) -le $tol
      $nearTop = [Math]::Abs($point.Y - $rect.Top) -le $tol
      $nearBottom = [Math]::Abs($point.Y - $rect.Bottom) -le $tol
      $inside = ($point.X -ge $rect.Left -and $point.X -le $rect.Right -and $point.Y -ge $rect.Top -and $point.Y -le $rect.Bottom)
      if ($inside) {
        $handle = ''
        if ($nearLeft -and $nearTop) { $handle = 'nw' }
        elseif ($nearRight -and $nearTop) { $handle = 'ne' }
        elseif ($nearLeft -and $nearBottom) { $handle = 'sw' }
        elseif ($nearRight -and $nearBottom) { $handle = 'se' }
        elseif ($nearLeft) { $handle = 'w' }
        elseif ($nearRight) { $handle = 'e' }
        elseif ($nearTop) { $handle = 'n' }
        elseif ($nearBottom) { $handle = 's' }
        $script:UI.handle = $handle
        $script:UI.drag = if ($handle -eq '') { 'move' } else { 'resize' }
        $script:UI.anchor = $point
        return
      }
    }
    $script:UI.drag = 'new'
    $script:UI.anchor = $point
    $script:UI.rect = New-Object System.Drawing.Rectangle $point.X, $point.Y, 0, 0
  })

  $form.Add_MouseMove({
    param($sender, $e)
    if ($script:UI.drag -eq '') { return }
    $point = New-Object System.Drawing.Point ($e.X + $vs.X), ($e.Y + $vs.Y)
    $rect = $script:UI.rect
    if ($script:UI.drag -eq 'new') {
      $left = [Math]::Min($script:UI.anchor.X, $point.X)
      $top = [Math]::Min($script:UI.anchor.Y, $point.Y)
      $w = [Math]::Abs($point.X - $script:UI.anchor.X)
      $h = [Math]::Abs($point.Y - $script:UI.anchor.Y)
      $script:UI.rect = New-Object System.Drawing.Rectangle $left, $top, $w, $h
    } elseif ($script:UI.drag -eq 'move') {
      $dx = $point.X - $script:UI.anchor.X
      $dy = $point.Y - $script:UI.anchor.Y
      $script:UI.rect = New-Object System.Drawing.Rectangle ($rect.X + $dx), ($rect.Y + $dy), $rect.Width, $rect.Height
      $script:UI.anchor = $point
    } elseif ($script:UI.drag -eq 'resize') {
      $left = $rect.Left
      $top = $rect.Top
      $right = $rect.Right
      $bottom = $rect.Bottom
      $handle = $script:UI.handle
      if ($handle.Contains('w')) { $left = $point.X }
      if ($handle.Contains('e')) { $right = $point.X }
      if ($handle.Contains('n')) { $top = $point.Y }
      if ($handle.Contains('s')) { $bottom = $point.Y }
      Set-RectEdges $left $top $right $bottom
    }
    $after = $script:UI.rect
    if ($after.X -ne $rect.X -or $after.Y -ne $rect.Y -or $after.Width -ne $rect.Width -or $after.Height -ne $rect.Height) {
      $sender.Invalidate((Get-OverlayDirtyRect $rect $after $sender.ClientRectangle))
      $script:UI.paintRect = $after
    }
  })

  $form.Add_MouseUp({
    param($sender, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    $kind = $script:UI.drag
    $script:UI.drag = ''
    $script:UI.handle = ''
    if ($kind -eq 'new' -and ($script:UI.rect.Width -lt 3 -or $script:UI.rect.Height -lt 3)) {
      $before = $script:UI.rect
      $script:UI.rect = [System.Drawing.Rectangle]::Empty
      $sender.Invalidate((Get-OverlayDirtyRect $before $script:UI.rect $sender.ClientRectangle))
      $script:UI.paintRect = $script:UI.rect
      Update-OverlayToolbar $sender $toolbar $vs
      return
    }
    $before = $script:UI.rect
    $script:UI.rect = Clamp-Rect $script:UI.rect $vs
    $sender.Invalidate((Get-OverlayDirtyRect $before $script:UI.rect $sender.ClientRectangle))
    $script:UI.paintRect = $script:UI.rect
    # 拖拽结束：这时候才让按钮条出现
    Update-OverlayToolbar $sender $toolbar $vs
    if ($script:Cfg.ConfirmOnRelease -and $script:UI.rect.Width -ge 3 -and $script:UI.rect.Height -ge 3) {
      Invoke-ConfirmSelection $sender $screen
    }
  })

  $form.Add_KeyDown({
    param($sender, $e)
    $code = [int]$e.KeyCode
    if ($code -eq 27) {
      $script:UI.cancelled = $true
      $sender.Close()
      return
    }
    if ($code -eq 13) {
      if ($script:UI.rect.Width -lt 3 -or $script:UI.rect.Height -lt 3) { $sender.Invalidate(); return }
      Invoke-ConfirmSelection $sender $screen
      return
    }
    $rect = $script:UI.rect
    if ($rect.Width -lt 3 -or $rect.Height -lt 3) { return }
    $step = 1
    if ($e.Control) { $step = 10 }
    switch ($code) {
      37 {
        if ($e.Shift) { $script:UI.rect = New-Object System.Drawing.Rectangle $rect.X, $rect.Y, ([Math]::Max(3, ($rect.Width - $step))), $rect.Height }
        else { $script:UI.rect = New-Object System.Drawing.Rectangle ($rect.X - $step), $rect.Y, $rect.Width, $rect.Height }
      }
      39 {
        if ($e.Shift) { $script:UI.rect = New-Object System.Drawing.Rectangle $rect.X, $rect.Y, ($rect.Width + $step), $rect.Height }
        else { $script:UI.rect = New-Object System.Drawing.Rectangle ($rect.X + $step), $rect.Y, $rect.Width, $rect.Height }
      }
      38 {
        if ($e.Shift) { $script:UI.rect = New-Object System.Drawing.Rectangle $rect.X, $rect.Y, $rect.Width, ([Math]::Max(3, ($rect.Height - $step))) }
        else { $script:UI.rect = New-Object System.Drawing.Rectangle $rect.X, ($rect.Y - $step), $rect.Width, $rect.Height }
      }
      40 {
        if ($e.Shift) { $script:UI.rect = New-Object System.Drawing.Rectangle $rect.X, $rect.Y, $rect.Width, ($rect.Height + $step) }
        else { $script:UI.rect = New-Object System.Drawing.Rectangle $rect.X, ($rect.Y + $step), $rect.Width, $rect.Height }
      }
      default { return }
    }
    $e.Handled = $true
    $sender.Invalidate((Get-OverlayDirtyRect $rect $script:UI.rect $sender.ClientRectangle))
    $script:UI.paintRect = $script:UI.rect
    Update-OverlayToolbar $sender $toolbar $vs
  })

  $form.Add_Shown({
    param($sender, $e)
    try { [void][DshShot.Win32]::SetForegroundWindow($sender.Handle) } catch { }
    $sender.Activate()
    try { $sender.ActiveControl = $null } catch { }
    $script:UI.paintRect = $script:UI.rect
    Update-OverlayToolbar $sender $toolbar $vs
  })

  # 自动化/自检钩子：自动落一个选区并确认
  if ($AutoSelect -ne '') {
    $parts = @($AutoSelect -split ',')
    if ($parts.Count -eq 4) {
      $script:UI.autoParts = $parts
      $timer = New-Object System.Windows.Forms.Timer
      $timer.Interval = 700
      $timer.Add_Tick({
        $script:UI.autoTimer.Stop()
        $p = $script:UI.autoParts
        $script:UI.rect = New-Object System.Drawing.Rectangle ([int]$p[0]), ([int]$p[1]), ([int]$p[2]), ([int]$p[3])
        $script:UI.rect = Clamp-Rect $script:UI.rect $vs
        $script:UI.paintRect = $script:UI.rect
        Update-OverlayToolbar $script:UI.form $toolbar $vs
        if ($ProbeOverlay -ne '') {
          $surface = New-Object System.Drawing.Bitmap $vs.Width, $vs.Height
          $script:UI.form.DrawToBitmap($surface, (New-Object System.Drawing.Rectangle 0, 0, $vs.Width, $vs.Height))
          $surface.Save($ProbeOverlay, [System.Drawing.Imaging.ImageFormat]::Png)
          $surface.Dispose()
          Write-ProtocolLine ('PROBE ' + $ProbeOverlay)
          $script:UI.cancelled = $true
          $script:UI.form.Close()
          return
        }
        if ($AutoSavePath -ne '') { Invoke-SaveAsSelection $screen } else { Invoke-ConfirmSelection $script:UI.form $screen }
      })
      $script:UI.autoTimer = $timer
      $timer.Start()
    }
  }

  try {
    [void]$form.ShowDialog()
  } finally {
    if ($script:UI.autoTimer) { $script:UI.autoTimer.Dispose(); $script:UI.autoTimer = $null }
    $form.Dispose()
    $screen.Dispose()
    $script:UI.form = $null
  }

  if ($script:UI.confirmed -and $script:UI.result) { return $script:UI.result }
  return [pscustomobject]@{ ok = $false; cancelled = $true }
}

#endregion

#region ---------- 入口 ----------

$script:TargetWidth = $Width
$script:TargetHeight = $Height

function Invoke-OneCapture {
  if ($Mode -eq 'fixed') { return (Invoke-FixedCapture) }
  return (Invoke-RegionCapture)
}

function Publish-CaptureResult($Result) {
  Emit-Result $Result
  if ($Result.ok) {
    $rect = New-Object System.Drawing.Rectangle $Result.x, $Result.y, $Result.width, $Result.height
    $message = [string]$script:T.copied
    if ($Result.file) { $message = $message + ' · ' + (Get-SafeFileName $Result.file) }
    Show-CaptureFlash $rect $message
  }
}

# 自检：只构建保存窗口并把界面渲染成 PNG，用于离线检查布局
if ($ProbeSaveDialog -ne '') {
  try {
    $bmp = New-Object System.Drawing.Bitmap 640, 360
    $graphics = [System.Drawing.Graphics]::FromImage($bmp)
    $graphics.Clear([System.Drawing.Color]::FromArgb(250, 250, 252))
    $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(70, 130, 180))
    $graphics.FillRectangle($brush, 30, 40, 260, 160)
    $brush.Dispose()
    $graphics.DrawString('preview', $script:SizeFont, [System.Drawing.Brushes]::Black, 110, 110)
    $graphics.Dispose()
    $probe = New-SaveAsForm $bmp
    # 必须先真正 Show 过，子控件才完成布局、DrawToBitmap 才画得出内容；
    # 放到屏幕外显示，避免自检时在用户屏幕上闪一下。
    $probe.StartPosition = 'Manual'
    $probe.Location = New-Object System.Drawing.Point -ArgumentList @(-4000, -4000)
    $probe.Show()
    $probe.Refresh()
    Start-Sleep -Milliseconds 400
    [void]$probe.CreateControl()
    $surface = New-Object System.Drawing.Bitmap ($probe.Width), ($probe.Height)
    $probe.DrawToBitmap($surface, (New-Object System.Drawing.Rectangle 0, 0, $surface.Width, $surface.Height))
    $surface.Save($ProbeSaveDialog, [System.Drawing.Imaging.ImageFormat]::Png)
    $surface.Dispose()
    $probe.Close()
    $probe.Dispose()
    $bmp.Dispose()
    Write-ProtocolLine ('PROBE ' + $ProbeSaveDialog)
    exit 0
  } catch {
    Emit-Error ('probe-failed: ' + $_.Exception.Message)
    exit 1
  }
}

if ($Once) {
  try {
    $result = Invoke-OneCapture
    Publish-CaptureResult $result
    exit 0
  } catch {
    Emit-Error ('capture-failed: ' + $_.Exception.Message)
    exit 1
  }
}

# --- 常驻模式：注册全局快捷键，然后等待触发 ---
try {
  $parsed = Parse-Hotkey $Hotkey
} catch {
  Emit-Error ('hotkey-invalid: ' + $_.Exception.Message)
  exit 3
}
$modifiers = [uint32]$parsed[0]
$virtualKey = [uint32]$parsed[1]

if (-not [DshShot.Win32]::RegisterHotKey([IntPtr]::Zero, 1, ($modifiers -bor $MOD_NOREPEAT), $virtualKey)) {
  $code = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
  Emit-Error ('hotkey-register-failed code=' + $code + ' hotkey=' + $Hotkey)
  exit 3
}

# 脚本自更新：文件被改动（且新内容语法没问题）就退出，让宿主用新脚本把助手拉起来，
# 这样改完不用重启整个 DSH。语法有误时继续跑当前版本，绝不让自己变成"起不来"。
$watchPath = $PSCommandPath
$watchStamp = $null
$watchWarned = $false
if ($watchPath -and (Test-Path -LiteralPath $watchPath)) {
  try { $watchStamp = (Get-Item -LiteralPath $watchPath).LastWriteTimeUtc } catch { $watchStamp = $null }
}

Write-ProtocolLine ('READY ' + $Hotkey)

$message = New-Object 'DshShot.Win32+MSG'
$lastTrigger = [datetime]::MinValue
$lastParentCheck = Get-Date
$running = $true

while ($running) {
  $triggered = $false
  while ([DshShot.Win32]::PeekMessage([ref]$message, [IntPtr]::Zero, $WM_HOTKEY, $WM_HOTKEY, 1)) {
    $triggered = $true
  }
  if ($triggered) {
    $now = Get-Date
    if (($now - $lastTrigger).TotalMilliseconds -gt 300) {
      $lastTrigger = $now
      Write-ProtocolLine 'HOTKEY'
      try {
        $result = Invoke-OneCapture
        Publish-CaptureResult $result
      } catch {
        Emit-Error ('capture-failed: ' + $_.Exception.Message)
      }
      # 丢弃截图期间累积的重复触发
      while ([DshShot.Win32]::PeekMessage([ref]$message, [IntPtr]::Zero, $WM_HOTKEY, $WM_HOTKEY, 1)) { }
      $lastTrigger = Get-Date
    }
  }
  if (((Get-Date) - $lastParentCheck).TotalSeconds -ge 2) {
    $lastParentCheck = Get-Date
    # 父进程没了就跟着退出，别留孤儿占着热键
    if ($ParentPid -gt 0 -and -not (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)) { $running = $false }
    # 脚本自更新检查
    if ($watchStamp -and $watchPath) {
      try {
        if (Test-Path -LiteralPath $watchPath) {
          $newStamp = (Get-Item -LiteralPath $watchPath).LastWriteTimeUtc
          if ($newStamp -gt $watchStamp) {
            $watchParseErrors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($watchPath, [ref]$null, [ref]$watchParseErrors)
            if ($watchParseErrors -and $watchParseErrors.Count -gt 0) {
              if (-not $watchWarned) {
                Write-ProtocolLine 'WARN 脚本已更新但语法有误，继续运行当前版本'
                $watchWarned = $true
              }
            } else {
              Write-ProtocolLine 'INFO 脚本已更新，退出以便宿主加载新版本'
              Write-ProtocolLine 'BYE'
              exit 0
            }
          }
        }
      } catch { }
    }
  }
  Start-Sleep -Milliseconds 30
}

try { [void][DshShot.Win32]::UnregisterHotKey([IntPtr]::Zero, 1) } catch { }
Write-ProtocolLine 'BYE'

#endregion
