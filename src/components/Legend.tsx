const CATEGORIES = [
  { label: "Code", hue: 210, sat: 60 },
  { label: "Data/Config", hue: 140, sat: 60 },
  { label: "Media", hue: 30, sat: 60 },
  { label: "Archives", hue: 0, sat: 60 },
  { label: "Docs", hue: 280, sat: 60 },
  { label: "Other", hue: 0, sat: 10 },
];

export function Legend() {
  return (
    <div className="legend">
      {CATEGORIES.map((cat) => (
        <span key={cat.label} className="legend-item">
          <span
            className="legend-swatch"
            style={{
              backgroundColor: `hsl(${cat.hue}, ${cat.sat}%, 55%)`,
            }}
          />
          {cat.label}
        </span>
      ))}
    </div>
  );
}
