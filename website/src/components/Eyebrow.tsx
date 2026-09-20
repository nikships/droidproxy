import type { ReactNode } from 'react'

export default function Eyebrow({
  index,
  children,
}: {
  index: string
  children: ReactNode
}) {
  return (
    <div className="eyebrow">
      <span className="index">{index}</span>
      <span className="eyebrow-label">{children}</span>
    </div>
  )
}
