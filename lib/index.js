/**
 * dsh-screenshot-hotkey —— 宿主侧（Node）入口。
 *
 * 职责：把 Windows 上的一个 PowerShell 常驻助手进程挂到 DSH 的组合树上。
 * 助手负责：注册全局快捷键 -> 弹出选区/直接截取 -> 写入系统剪贴板。
 * 本文件只做进程生命周期管理、配置归一化和协议行解析，不做任何平台调用。
 */
import { spawn } from 'node:child_process'
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const HELPER = join(HERE, '..', 'assets', 'screenshot.ps1')

/** 组合树里的插件名。 */
export const name = 'screenshot'

/**
 * 本地兜底 schema。Cordis 只要求 Config 实现 Standard Schema 接口
 * （即 Config['~standard'].validate(raw) 返回 { value } 或 { issues }），
 * 所以这里可以直接手写一个，取值逻辑与下面的 schemastery 版本完全一致。
 *
 * 为什么要兜底：@deepseek-ai/schemastery 声明为 peer（不随插件安装，也不联网拉取），
 * 运行时由 DSH 的 profile 模块解析提供。万一解析不到，兜底 schema 能让插件照常加载，
 * 而不是整个插件因为一个 import 失败就直接消失。
 */
const localSchema = {
  '~standard': {
    version: 1,
    vendor: 'dsh-screenshot-hotkey',
    validate(input) {
      try {
        return { value: normalize(input) }
      } catch (error) {
        return { issues: [{ message: error && error.message ? error.message : String(error) }] }
      }
    },
  },
}

let schema = localSchema
try {
  const schemastery = await import('@deepseek-ai/schemastery')
  const z = schemastery.default ?? schemastery
  if (z && typeof z.object === 'function') {
    schema = z.object({
      enabled: z.boolean().default(true),
      hotkey: z.string().default('Alt+A'),
      mode: z.string().default('region'),
      width: z.number().default(0),
      height: z.number().default(0),
      copyToClipboard: z.boolean().default(true),
      saveDirectory: z.string().default(''),
      language: z.string().default('zh'),
      flash: z.boolean().default(true),
      confirmOnRelease: z.boolean().default(false),
    })
  }
} catch {
  // profile 解析不到 schemastery：继续使用 localSchema
}

export const Config = schema

/**
 * Windows PowerShell 5.1 只有在文件带 UTF-8 BOM 时才按 UTF-8 解析脚本；
 * 否则中文提示会因按 ANSI 解码而直接把语法解析弄坏。这里做一次自愈。
 */
let bomChecked = false
function ensureHelperBom(file) {
  if (bomChecked) return
  bomChecked = true
  try {
    const bytes = readFileSync(file)
    if (bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) return
    writeFileSync(file, Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), bytes]))
  } catch {
    // 只读安装目录下无法修复，交给 PowerShell 自己报错
  }
}

/** Windows PowerShell 5.1：默认 STA，WinForms + 剪贴板需要它。 */
function powershellPath() {
  const windowsDir = process.env.SystemRoot || process.env.windir || 'C:\\Windows'
  const full = join(windowsDir, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
  return existsSync(full) ? full : 'powershell.exe'
}

function normalize(config) {
  const c = config && typeof config === 'object' ? config : {}
  const has = (key) => Object.prototype.hasOwnProperty.call(c, key)
  const bool = (value, fallback) => (typeof value === 'boolean' ? value : fallback)
  const text = (value, fallback) => (typeof value === 'string' && value.trim() !== '' ? value.trim() : fallback)
  const size = (value) => (typeof value === 'number' && Number.isFinite(value) && value > 0 ? Math.floor(value) : 0)

  const width = size(c.width)
  const height = size(c.height)
  const wantsFixed = c.mode === 'fixed' && width > 0 && height > 0

  return {
    enabled: has('enabled') ? bool(c.enabled, true) : true,
    hotkey: text(c.hotkey, 'Alt+A'),
    mode: wantsFixed ? 'fixed' : 'region',
    width,
    height,
    copyToClipboard: has('copyToClipboard') ? bool(c.copyToClipboard, true) : true,
    saveDirectory: text(c.saveDirectory, ''),
    language: c.language === 'en' ? 'en' : 'zh',
    flash: has('flash') ? bool(c.flash, true) : true,
    confirmOnRelease: bool(c.confirmOnRelease, false),
  }
}

function makeLogger(ctx) {
  const emit = (level, message) => {
    const line = '[screenshot] ' + message
    try {
      const logger = ctx && ctx.logger
      if (logger && typeof logger[level] === 'function') {
        logger[level](line)
        return
      }
    } catch {
      /* 日志服务不可用时退回 stdout */
    }
    if (level === 'error' || level === 'warn') console.error(line)
    else console.log(line)
  }
  return {
    info: (m) => emit('info', m),
    warn: (m) => emit('warn', m),
    error: (m) => emit('error', m),
  }
}

export function apply(ctx, config) {
  const cfg = normalize(config)
  const log = makeLogger(ctx)

  if (!cfg.enabled) {
    log.info('已在配置中停用（enabled: false）')
    return
  }
  if (process.platform !== 'win32') {
    log.warn('当前平台不是 Windows，截屏插件不生效')
    return
  }

  const state = { proc: null, retries: 0, timer: null, disposed: false }

  const stop = () => {
    state.disposed = true
    if (state.timer) {
      clearTimeout(state.timer)
      state.timer = null
    }
    const child = state.proc
    state.proc = null
    if (child) {
      try {
        child.kill()
      } catch {
        /* 进程可能已退出 */
      }
      log.info('截屏助手已停止')
    }
  }

  const onLine = (child, raw) => {
    const line = raw.replace(/\r$/, '').trim()
    if (line === '') return
    if (line.startsWith('READY')) {
      state.retries = 0
      const detail = line.slice(5).trim()
      log.info('已就绪：按 ' + (detail || cfg.hotkey) + ' 截图' + (cfg.mode === 'fixed' ? '（固定 ' + cfg.width + 'x' + cfg.height + '）' : '（拖拽选区）'))
      return
    }
    if (line === 'HOTKEY') {
      log.info('快捷键触发，开始截图')
      return
    }
    if (line.startsWith('RESULT ')) {
      let result
      try {
        result = JSON.parse(line.slice(7))
      } catch (error) {
        log.warn('无法解析截图结果：' + line)
        return
      }
      if (result && result.ok) {
        const where = []
        if (result.clipboard) where.push('已复制到剪贴板')
        if (result.file) where.push('已保存到 ' + result.file)
        if (where.length === 0) where.push('已截图')
        log.info(where.join('，') + '（' + result.width + 'x' + result.height + ' @ ' + result.x + ',' + result.y + '）')
      } else if (result && result.cancelled) {
        log.info('已取消截图')
      } else {
        log.warn('截图未完成：' + JSON.stringify(result))
      }
      return
    }
    if (line.startsWith('INFO ')) {
      log.info(line.slice(5))
      return
    }
    if (line.startsWith('WARN ')) {
      log.warn(line.slice(5))
      return
    }
    if (line.startsWith('DEBUG ')) {
      log.info(line.slice(6))
      return
    }
    if (line.startsWith('ERROR ')) {
      log.error('截屏助手报错：' + line.slice(6))
      return
    }
    log.info('助手输出：' + line)
  }

  const start = () => {
    if (state.disposed || state.proc) return
    if (!existsSync(HELPER)) {
      log.error('找不到助手脚本：' + HELPER)
      return
    }
    ensureHelperBom(HELPER)
    const args = [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-STA',
      '-File',
      HELPER,
      '-Hotkey',
      cfg.hotkey,
      '-Mode',
      cfg.mode,
      '-Width',
      String(cfg.width),
      '-Height',
      String(cfg.height),
      '-CopyToClipboard',
      cfg.copyToClipboard ? 'true' : 'false',
      '-Flash',
      cfg.flash ? 'true' : 'false',
      '-ConfirmOnRelease',
      cfg.confirmOnRelease ? 'true' : 'false',
      '-Language',
      cfg.language,
      '-ParentPid',
      String(process.pid),
    ]
    if (cfg.saveDirectory) args.push('-SaveDirectory', cfg.saveDirectory)

    log.info('启动截屏助手：hotkey=' + cfg.hotkey + ' mode=' + cfg.mode)
    let child
    try {
      child = spawn(powershellPath(), args, { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] })
    } catch (error) {
      log.error('无法启动 PowerShell：' + (error && error.message ? error.message : String(error)))
      return
    }
    state.proc = child

    let buffer = ''
    child.stdout.setEncoding('utf8')
    child.stdout.on('data', (chunk) => {
      buffer += chunk
      let index = buffer.indexOf('\n')
      while (index >= 0) {
        onLine(child, buffer.slice(0, index))
        buffer = buffer.slice(index + 1)
        index = buffer.indexOf('\n')
      }
    })
    child.stderr.setEncoding('utf8')
    child.stderr.on('data', (chunk) => {
      const text = String(chunk).trim()
      if (text !== '') log.warn('助手 stderr：' + text)
    })
    child.on('error', (error) => {
      log.error('助手进程错误：' + (error && error.message ? error.message : String(error)))
    })
    child.on('exit', (code, signal) => {
      if (state.proc === child) state.proc = null
      if (state.disposed) return
      state.retries += 1
      log.warn('截屏助手退出（code=' + code + (signal ? ', signal=' + signal : '') + '）')
      if (state.retries <= 5) {
        const delay = Math.min(30000, 2000 * state.retries)
        state.timer = setTimeout(() => {
          state.timer = null
          start()
        }, delay)
      } else {
        log.error('截屏助手反复退出，已放弃重启。请检查 hotkey 配置是否被其它程序占用。')
      }
    })
  }

  if (typeof ctx.effect === 'function') {
    ctx.effect(() => {
      start()
      return stop
    }, 'screenshot-hotkey')
  } else {
    start()
    if (typeof ctx.on === 'function') ctx.on('dispose', stop)
  }
}

export default { name, Config, apply }
