type BrandIconProps = {
  src: string
  color: string
  size?: number
}

export default function BrandIcon({ src, color, size = 18 }: BrandIconProps) {
  return (
    <span
      className="brand-icon"
      aria-hidden
      style={{
        width: size,
        height: size,
        backgroundColor: color,
        WebkitMaskImage: `url(${src})`,
        maskImage: `url(${src})`,
      }}
    />
  )
}
