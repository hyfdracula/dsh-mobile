/**
 * 设计令牌：雾面白 + DeepSeek 蓝 + 沉浸光感。
 * 所有页面只从这里取色，避免散落的硬编码。
 * 深浅两套调色板可通过 applyDark() 在运行时切换。
 */
export class Tokens {
  // 底色
  static bg: string = '#0A0C10';
  static bgTop: string = '#101521';
  static bgEl: string = '#12151C';
  static surface: string = '#161A22';
  static surface2: string = '#1C212B';
  static surface3: string = '#232936';
  static line: string = '#252B37';
  static lineSoft: string = '#1A1F28';

  // 文字
  static fg: string = '#F2F4F7';
  static dim: string = '#9AA3B2';
  static dim2: string = '#7E8794';

  // 信号色（DeepSeek 蓝）
  static accent: string = '#5B8CFF';
  static accentStrong: string = '#3B6EF6';
  static accentInk: string = '#FFFFFF';
  static accentGlow: string = '#335B8CFF';
  static accentSoft: string = '#1A3B6EF6';
  static ok: string = '#3DDC97';
  static err: string = '#FF5C5C';

  // 液态玻璃层（沉浸光感）：透明度必须真的低，否则身后的内容糊不出来，
  // 看着就是一块纯色板。真实观感 = 低透明度玻璃 + 高饱和模糊 + 顶部高光 + 1px 亮边。
  static glass: string = '#E6171B24';
  static glassStrong: string = '#E6171B24';
  static glassLine: string = '#33FFFFFF';
  /** 胶囊/圆钮的高亮描边：深色用白光，浅色用淡墨，两种底色下都能看出「一圈边」。 */
  static pillEdge: string = '#4DFFFFFF';
  /** 顶部斜向高光，模拟玻璃表面反光 */
  static glassTop: string = '#5CFFFFFF';
  static glassBar: string = '#E6171B24';
  static glassFloat: string = '#331B2030';
  /** 更淡的一层玻璃：悬浮按钮用，几乎全透 */
  static glassFaint: string = '#1FFFFFFF';
  /** 半模态面板的玻璃底：带透明度，配合系统 blur 能看到身后的内容 */
  static sheetGlass: string = '#E9FFFFFF';
  /** 半模态的暖金玻璃（浅色）：带暖黄调的半透明底，靠系统 blur 出玻璃感 */
  static sheetWarm: string = '#B8FFF6E4';
  /** 选中胶囊：半透明蓝玻璃，不要用实色 accentSoft，否则压掉模糊 */
  static accentGlass: string = '#1A3B6EF6';
  static chip: string = '#1F2A3A';
  static shadow: string = '#4D000000';
  /** 背景模糊半径：玻璃层靠它把身后的内容糊开，深浅色都成立 */
  static readonly glassBlur: number = 24;
  static readonly glassBarRadius: number = 20;
  /** 玻璃背后内容的饱和度：抬高一点才有「液态」的通透感 */
  static readonly glassSat: number = 1.85;
  static readonly glassBright: number = 1.1;

  // 会话行首字方块的底色组
  static tile: string[] = ['#2B4A8F', '#2F6B5E', '#6A4A2B', '#5A3B72', '#7A3446', '#2F5A7A'];

  // 圆角
  static readonly rGroup: number = 22;

  /** 当前是否深色。静态标记，applyDark() 每次切换时更新，供运行时需要分支的绘制用。 */
  static isDark: boolean = true;
  static readonly rCard: number = 20;
  static readonly rInput: number = 28;
  static readonly rPill: number = 999;

  // 间距
  static readonly pad: number = 16;
  static readonly gap: number = 12;

  // 动效时长（毫秒）
  static readonly tFast: number = 140;
  static readonly tBase: number = 260;
  static readonly tSlow: number = 420;

  /** 切换调色板：true 深色，false 浅色。 */
  static applyDark(dark: boolean): void {
    Tokens.isDark = dark;
    if (dark) {
      Tokens.bg = '#0A0C10';
      Tokens.bgTop = '#101521';
      Tokens.bgEl = '#12151C';
      Tokens.surface = '#161A22';
      Tokens.surface2 = '#1C212B';
      Tokens.surface3 = '#232936';
      Tokens.line = '#252B37';
      Tokens.lineSoft = '#1A1F28';
      Tokens.fg = '#F2F4F7';
      Tokens.dim = '#9AA3B2';
      Tokens.dim2 = '#7E8794';
      Tokens.accent = '#5B8CFF';
      Tokens.accentStrong = '#3B6EF6';
      Tokens.accentInk = '#FFFFFF';
      Tokens.accentGlow = '#335B8CFF';
      Tokens.accentSoft = '#1A3B6EF6';
      Tokens.sheetGlass = '#E61B2027';
      Tokens.sheetWarm = '#9E171B22';
      Tokens.ok = '#3DDC97';
      Tokens.err = '#FF5C5C';
      Tokens.glass = '#E6171B24';
      Tokens.glassStrong = '#E6171B24';
      Tokens.glassLine = '#33FFFFFF';
      Tokens.glassTop = '#5CFFFFFF';
      Tokens.glassBar = '#E6171B24';
    Tokens.glassFloat = '#331B2030';
    Tokens.glassFaint = '#1FFFFFFF';
      Tokens.accentGlass = '#1A3B6EF6';
      Tokens.chip = '#1F2A3A';
      Tokens.shadow = '#4D000000';
      Tokens.tile = ['#2B4A8F', '#2F6B5E', '#6A4A2B', '#5A3B72', '#7A3446', '#2F5A7A'];
    } else {
      Tokens.bg = '#E9EDF4';
      Tokens.bgTop = '#DCE4F2';
      Tokens.bgEl = '#F7F9FC';
      Tokens.surface = '#FFFFFF';
      Tokens.surface2 = '#F3F6FB';
      Tokens.surface3 = '#E7EDF7';
      Tokens.line = '#E2E8F2';
      Tokens.lineSoft = '#EDF1F8';
      Tokens.fg = '#10131A';
      Tokens.dim = '#5B6474';
      Tokens.dim2 = '#8A93A6';
      Tokens.accent = '#2F6BFF';
      Tokens.accentStrong = '#1E56E0';
      Tokens.accentInk = '#FFFFFF';
      Tokens.accentGlow = '#332F6BFF';
      Tokens.accentSoft = '#122F6BFF';
      Tokens.ok = '#0F9D63';
      Tokens.err = '#DC3545';
      Tokens.glass = '#D9FFFFFF';
      Tokens.sheetWarm = '#B8FFF6E4';
      Tokens.glassStrong = '#D9FFFFFF';
      Tokens.glassLine = '#E6FFFFFF';
  Tokens.pillEdge = '#1F000000';
      Tokens.glassTop = '#FFFFFFFF';
      Tokens.glassBar = '#D9FFFFFF';
    Tokens.glassFloat = '#D9FFFFFF';
    Tokens.glassFaint = '#8CFFFFFF';
      Tokens.accentGlass = '#262F6BFF';
      Tokens.chip = '#EAF0FB';
      Tokens.shadow = '#1F2F4A80';
      Tokens.tile = ['#D6E2FF', '#D3EDE6', '#FBE4CC', '#E7DAF6', '#F8D8DF', '#D8EAF7'];
    }
  }
}

