/**
 * Glue the last two words when they are short, so body copy cannot
 * orphan a one-word last line. Skips short titles — those must wrap
 * normally or they overflow the column.
 */
export function noOrphan(text: string): string {
  const words = text.trim().split(/\s+/)
  if (words.length < 8) return text
  const tail = words.slice(-2)
  if (tail.join(' ').length > 22) return text
  return `${words.slice(0, -2).join(' ')}\u00a0${tail.join('\u00a0')}`
}
