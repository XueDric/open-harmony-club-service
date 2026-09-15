/**
 * 设计与视觉规范 —— Design Tokens 唯一同源
 * 对应《鸿蒙俱乐部-全场景UI设计规格》Design Tokens · Light Theme
 * 原则：一处定义 · 全页复用 · 页面里不出现硬编码色值。
 *
 * 注：设计稿里的 SemiBold 在 ArkUI 无对应档位，统一用 FontWeight.Bold 落地；
 *     数字/日期的 Inter 等宽数字需先在 resources 注册字体，再由 fontFamily 生效，暂以常量标注。
 */

// ─── 品牌与中性色 ───
// 底色带极淡紫调、卡片纯白浮起；中性色只负责秩序，全部提示信号交给状态色。
export interface ColorTokens {
  canvas: string;
  surface: string;
  primary: string;
  primarySoft: string;
  divider: string;
  textPrimary: string;
  textSecondary: string;
  textTertiary: string;
}

export const Color: ColorTokens = {
  canvas: '#F5F6FA',        // 页面底色
  surface: '#FFFFFF',       // 卡片
  primary: '#1F6FEB',       // 主色
  primarySoft: '#E8F1FE',   // 主色浅底
  divider: '#E6E9EE',       // 分隔线
  textPrimary: '#1B1F24',   // 一级文字
  textSecondary: '#5A6472', // 二级文字
  textTertiary: '#8A94A6',  // 三级文字
}

// ─── 状态语义色（前景 / 浅底）───
// 任务 4 档状态 + 逾期派生量 + 待分配账号；都是正常业务分支，不是系统错误。
// 「逾期」是唯一需要立刻抓眼睛的事实；红/橙只出现在真正出事的分组。
export interface StatusColorPair {
  fg: string;
  bg: string;
}

export interface StatusColorTokens {
  todo: StatusColorPair;
  overdue: StatusColorPair;
  blocked: StatusColorPair;
  doing: StatusColorPair;
  done: StatusColorPair;
  pending: StatusColorPair;
}

export const StatusColor: StatusColorTokens = {
  todo:    { fg: '#6B7785', bg: '#F0F2F5' },  // 未开始
  overdue: { fg: '#D93A2B', bg: '#FDECEA' },  // 逾期（服务端派生）
  blocked: { fg: '#C77700', bg: '#FFF4E0' },  // 阻塞（必填原因）
  doing:   { fg: '#1F6FEB', bg: '#E8F1FE' },  // 进行中
  done:    { fg: '#2E7D4F', bg: '#E8F5EC' },  // 已完成（收敛安静）
  pending: { fg: '#7A5AF8', bg: '#F1EEFE' },  // 待分配
}

// ─── 字体字号 ───
export interface FontSizeTokens {
  headline: number;
  title: number;
  subtitle: number;
  body: number;
  caption: number;
  micro: number;
}

export const FontSize: FontSizeTokens = {
  headline: 22,  // SemiBold → Bold
  title: 18,     // SemiBold → Bold
  subtitle: 16,  // Medium
  body: 14,      // Regular
  caption: 12,   // Regular
  micro: 11,     // Medium（胶囊专用）
}

export interface FontFamilyTokens {
  sans: string;
  numeric: string;
}

export const FontFamily: FontFamilyTokens = {
  sans: 'Noto Sans SC',
  numeric: 'Inter',
}

// ─── 间距（档位 4/8/12/16/24/32）───
export interface SpaceTokens {
  xs: number;
  sm: number;
  md: number;
  lg: number;
  xl: number;
  xxl: number;
  page: number;
  card: number;
  cardGap: number;
  section: number;
}

export const Space: SpaceTokens = {
  xs: 4,
  sm: 8,
  md: 12,
  lg: 16,
  xl: 24,
  xxl: 32,
  page: 16,      // 页边距
  card: 14,      // 卡片内边距
  cardGap: 12,   // 卡片间距
  section: 24,   // 区块间距
}

// ─── 圆角 ───
export interface RadiusTokens {
  card: number;
  button: number;
  input: number;
  pill: number;
  bottomNav: number;
}

export const Radius: RadiusTokens = {
  card: 14,
  button: 12,
  input: 10,
  pill: 999,
  bottomNav: 36,
}

// ─── 阴影（三层：卡片浮起 / 弹层下压）───
export interface ShadowValue {
  radius: number;
  color: string;
  offsetX: number;
  offsetY: number;
}

export interface ShadowTokens {
  card: ShadowValue;
}

export const Shadow: ShadowTokens = {
  card: { radius: 12, color: '#14000000', offsetX: 0, offsetY: 2 },
}

// ─── 状态派生辅助 ───
export function statusLabel(status: string): string {
  if (status === 'todo') return '未开始'
  if (status === 'doing') return '进行中'
  if (status === 'blocked') return '阻塞中'
  if (status === 'done') return '已完成'
  if (status === 'pending') return '待分配'
  return status
}

export function statusFg(status: string): string {
  if (status === 'todo') return StatusColor.todo.fg
  if (status === 'doing') return StatusColor.doing.fg
  if (status === 'blocked') return StatusColor.blocked.fg
  if (status === 'done') return StatusColor.done.fg
  if (status === 'pending') return StatusColor.pending.fg
  return Color.textTertiary
}

export function statusBg(status: string): string {
  if (status === 'todo') return StatusColor.todo.bg
  if (status === 'doing') return StatusColor.doing.bg
  if (status === 'blocked') return StatusColor.blocked.bg
  if (status === 'done') return StatusColor.done.bg
  if (status === 'pending') return StatusColor.pending.bg
  return StatusColor.todo.bg
}
