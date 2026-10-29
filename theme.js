/* Gemeinsames Design für index.html und abwesenheit.html
   - Tailwind-Konfiguration (Schriften, Farben)
   - Akzentfarbe nach dem Kirchenjahr (liturgische Farbe der aktuellen Zeit)  */
(function () {
  // Zum Festlegen einer Farbe: 'jahreskreis' | 'advent' | 'weihnachten' | 'fastenzeit' | 'ostern' | 'pfingsten'
  // null = automatisch nach Datum. Zum Ausprobieren geht auch ?saison=ostern an der Adresse.
  var FORCE_SEASON = null;

  var PALETTES = {
    jahreskreis: { label: "Jahreskreis", c: { 50: [238, 245, 240], 100: [216, 232, 221], 500: [63, 138, 99], 600: [44, 107, 76], 700: [32, 82, 58] } },
    advent: { label: "Adventszeit", c: { 50: [243, 239, 247], 100: [227, 218, 236], 500: [123, 90, 155], 600: [94, 60, 128], 700: [72, 45, 99] } },
    fastenzeit: { label: "Fastenzeit", c: { 50: [243, 239, 247], 100: [227, 218, 236], 500: [123, 90, 155], 600: [94, 60, 128], 700: [72, 45, 99] } },
    weihnachten: { label: "Weihnachtszeit", c: { 50: [250, 245, 232], 100: [241, 229, 196], 500: [181, 138, 42], 600: [140, 106, 31], 700: [111, 83, 24] } },
    ostern: { label: "Osterzeit", c: { 50: [250, 245, 232], 100: [241, 229, 196], 500: [181, 138, 42], 600: [140, 106, 31], 700: [111, 83, 24] } },
    pfingsten: { label: "Pfingsten", c: { 50: [251, 239, 238], 100: [244, 216, 214], 500: [194, 73, 63], 600: [165, 50, 41], 700: [130, 38, 31] } },
  };

  function easter(y) {
    var a = y % 19, b = Math.floor(y / 100), c = y % 100, d = Math.floor(b / 4), e = b % 4;
    var f = Math.floor((b + 8) / 25), g = Math.floor((b - f + 1) / 3);
    var h = (19 * a + b - d - g + 15) % 30, i = Math.floor(c / 4), k = c % 4;
    var l = (32 + 2 * e + 2 * i - h - k) % 7, m = Math.floor((a + 11 * h + 22 * l) / 451);
    var month = Math.floor((h + l - 7 * m + 114) / 31), day = ((h + l - 7 * m + 114) % 31) + 1;
    return new Date(y, month - 1, day);
  }
  function addDays(d, n) { var x = new Date(d.getFullYear(), d.getMonth(), d.getDate()); x.setDate(x.getDate() + n); return x; }

  function seasonKey(date) {
    var d = new Date(date.getFullYear(), date.getMonth(), date.getDate());
    var y = d.getFullYear(), t = d.getTime();
    var christmas = new Date(y, 11, 25);
    var advent4 = addDays(christmas, -(christmas.getDay() === 0 ? 7 : christmas.getDay()));
    var advent1 = addDays(advent4, -21);
    if (t >= christmas.getTime()) return "weihnachten";
    if (t >= advent1.getTime()) return "advent";
    var epiphany = new Date(y, 0, 6);
    var baptism = addDays(epiphany, 7 - epiphany.getDay()); // Sonntag nach dem 6. Januar
    if (t <= baptism.getTime()) return "weihnachten";
    var e = easter(y);
    if (t < addDays(e, -46).getTime()) return "jahreskreis";
    if (t < e.getTime()) return "fastenzeit";
    var pentecost = addDays(e, 49);
    if (t < pentecost.getTime()) return "ostern";
    if (t === pentecost.getTime()) return "pfingsten";
    return "jahreskreis";
  }

  var param = null;
  try { param = new URLSearchParams(location.search).get("saison"); } catch (e) {}
  var key = FORCE_SEASON || (param && PALETTES[param] ? param : null) || seasonKey(new Date());
  var pal = PALETTES[key];
  var root = document.documentElement;
  Object.keys(pal.c).forEach(function (step) { root.style.setProperty("--a" + step, pal.c[step].join(" ")); });
  root.setAttribute("data-season", key);
  window.LITURGY = { key: key, label: pal.label };

  if (window.tailwind) {
    var accent = function (step) { return "rgb(var(--a" + step + ") / <alpha-value>)"; };
    window.tailwind.config = {
      theme: {
        extend: {
          fontFamily: {
            sans: ["Figtree", "ui-sans-serif", "system-ui", "-apple-system", "Segoe UI", "sans-serif"],
            serif: ["Newsreader", "Georgia", "Times New Roman", "serif"],
          },
          colors: {
            brand: { 50: accent(50), 100: accent(100), 500: accent(500), 600: accent(600), 700: accent(700) },
            // Sandstein-Töne für Flächen, Nachtblau für Text und Navigation
            slate: {
              50: "#F6F5F2", 100: "#EDECE7", 200: "#E0DED7", 300: "#CBC9C1", 400: "#9C9FA6",
              500: "#6C7280", 600: "#4D5568", 700: "#36405A", 800: "#252E48", 900: "#171F36",
            },
          },
        },
      },
    };
  }
})();
