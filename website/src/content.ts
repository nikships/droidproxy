export const VERSION = '1.8.124'
export const GITHUB = 'https://github.com/anand-92/droidproxy'
export const RELEASES = `${GITHUB}/releases/latest`
export const ISSUES = `${GITHUB}/issues`
export const LICENSE = `${GITHUB}/blob/main/LICENSE`
export const CLIPROXY = 'https://github.com/router-for-me/CLIProxyAPI'
export const FACTORY = 'https://factory.ai'

export type Provider = {
  icon: string
  name: string
  lab: string
  note: string
  color: string
}

export const brandColor = {
  claude: '#D97757',
  chatgpt: '#74AA9C',
  gemini: '#4285F4',
  copilot: '#77B9FF',
  grok: '#1D9BF0',
  kimi: '#00BF91',
  muse: '#0866FF',
  junie: '#48E054',
} as const

export const providers: Provider[] = [
  { icon: '/assets/icon-claude.png', name: 'Claude', lab: 'Anthropic', note: 'Pro · Max', color: brandColor.claude },
  { icon: '/assets/icon-codex.png', name: 'ChatGPT', lab: 'OpenAI', note: 'Plus · Pro', color: brandColor.chatgpt },
  { icon: '/assets/icon-gemini.png', name: 'Gemini', lab: 'Google', note: 'AI Plan', color: brandColor.gemini },
  { icon: '/assets/icon-copilot.png', name: 'Copilot', lab: 'GitHub', note: '3 models', color: brandColor.copilot },
  { icon: '/assets/icon-grok.svg', name: 'Grok', lab: 'xAI', note: 'SuperGrok', color: brandColor.grok },
  { icon: '/assets/icon-kimi.svg', name: 'Kimi', lab: 'Moonshot', note: 'Kimi Code', color: brandColor.kimi },
  { icon: '/assets/icon-meta.svg', name: 'Muse', lab: 'Meta', note: 'Muse Spark', color: brandColor.muse },
  { icon: '/assets/icon-junie.svg', name: 'Junie', lab: 'JetBrains', note: 'AI plan', color: brandColor.junie },
]

export type ModelRow = {
  icon: string
  name: string
  id: string
  levels: string[]
  max: string
  context?: string
  provider: string
  group: string
  color: string
}

export const models: ModelRow[] = [
  {
    icon: '/assets/icon-claude.png',
    name: 'Claude Fable 5.1',
    id: 'fable-5-1',
    levels: ['low', 'medium', 'high', 'xhigh', 'max'],
    max: '128,000',
    provider: 'Anthropic',
    group: 'Claude',
    color: brandColor.claude,
  },
  {
    icon: '/assets/icon-claude.png',
    name: 'Claude Opus 5.5',
    id: 'opus-5-5',
    levels: ['low', 'medium', 'high', 'xhigh', 'max'],
    max: '128,000',
    provider: 'Anthropic',
    group: 'Claude',
    color: brandColor.claude,
  },
  {
    icon: '/assets/icon-claude.png',
    name: 'Claude Sonnet 5',
    id: 'sonnet-5',
    levels: ['low', 'medium', 'high', 'xhigh', 'max'],
    max: '128,000',
    provider: 'Anthropic',
    group: 'Claude',
    color: brandColor.claude,
  },
  {
    icon: '/assets/icon-codex.png',
    name: 'GPT 6 Astra',
    id: 'gpt-6-astra',
    levels: ['low', 'medium', 'high', 'xhigh', 'max'],
    max: '128,000',
    context: '1.05M',
    provider: 'OpenAI',
    group: 'ChatGPT',
    color: brandColor.chatgpt,
  },
  {
    icon: '/assets/icon-codex.png',
    name: 'GPT 5.6 Terra',
    id: 'gpt-5.6-terra',
    levels: ['none', 'low', 'medium', 'high', 'xhigh', 'max'],
    max: '128,000',
    provider: 'OpenAI',
    group: 'ChatGPT',
    color: brandColor.chatgpt,
  },
  {
    icon: '/assets/icon-codex.png',
    name: 'GPT 5.6 Luna',
    id: 'gpt-5.6-luna',
    levels: ['none', 'low', 'medium', 'high', 'xhigh', 'max'],
    max: '128,000',
    provider: 'OpenAI',
    group: 'ChatGPT',
    color: brandColor.chatgpt,
  },
  {
    icon: '/assets/icon-codex.png',
    name: 'GPT 5.6 Sol',
    id: 'gpt-5.6-sol',
    levels: ['dynamic', 'low', 'medium', 'high', 'xhigh', 'max'],
    max: '128,000',
    provider: 'OpenAI',
    group: 'ChatGPT',
    color: brandColor.chatgpt,
  },
  {
    icon: '/assets/icon-gemini.png',
    name: 'Gemini 3.8 Flash',
    id: 'gemini-3.8-flash-high',
    levels: ['high'],
    max: '65,536',
    provider: 'Google',
    group: 'Gemini',
    color: brandColor.gemini,
  },
  {
    icon: '/assets/icon-grok.svg',
    name: 'Grok 4.7',
    id: 'grok-4.7',
    levels: ['low', 'medium', 'high', 'xhigh'],
    max: '128,000',
    context: '500k',
    provider: 'xAI',
    group: 'Grok',
    color: brandColor.grok,
  },
  {
    icon: '/assets/icon-grok.svg',
    name: 'Grok 4.7 Fast',
    id: 'grok-4.7-build-fast',
    levels: ['low', 'medium', 'high', 'xhigh'],
    max: '128,000',
    context: '500k',
    provider: 'xAI',
    group: 'Grok',
    color: brandColor.grok,
  },
  {
    icon: '/assets/icon-kimi.svg',
    name: 'Kimi K3',
    id: 'kimi-k3',
    levels: ['max'],
    max: '65,536',
    provider: 'Moonshot',
    group: 'Kimi',
    color: brandColor.kimi,
  },
  {
    icon: '/assets/icon-meta.svg',
    name: 'Muse Spark 1.3',
    id: 'muse-spark-1.3',
    levels: ['low', 'medium', 'high', 'xhigh', 'max'],
    max: '256,000',
    context: '1M',
    provider: 'Meta',
    group: 'Muse',
    color: brandColor.muse,
  },
]
