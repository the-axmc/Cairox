export default function Navbar() {
  return (
    <header className="nav">
      <div className="brand">
        <span className="brand__glyph">𓂀</span>
        <div>
          <div className="brand__name">Cairox</div>
          <div className="brand__tag">Business Prediction Markets</div>
        </div>
      </div>
      <nav className="nav__links">
        <a href="/home">Home</a>
        <a href="/markets">Markets</a>
        <a href="/docs">Docs</a>
      </nav>
    </header>
  );
}
