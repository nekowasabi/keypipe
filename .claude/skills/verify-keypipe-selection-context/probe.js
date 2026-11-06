// Feasibility probe (F1-F4): run right after a real Cmd+C in the app under test.
//   osascript -l JavaScript .claude/skills/verify-keypipe-selection-context/probe.js
// Prints each pasteboard type, then the hrefs in public.html and the source URL, so
// the result can be judged without pasting the copied text anywhere.
ObjC.import("AppKit");
function run() {
  var pb = $.NSPasteboard.generalPasteboard;
  var t = pb.types, types = [];
  for (var i = 0; i < t.count; i++) types.push(ObjC.unwrap(t.objectAtIndex(i)));
  var str = function (ty) {
    var s = pb.stringForType(ty);
    return s.isNil() ? "" : ObjC.unwrap(s);
  };
  var html = types.indexOf("public.html") >= 0 ? str("public.html") : "";
  var hrefs = [], re = /<a\b[^>]*\bhref\s*=\s*["']([^"']+)["']/gi, m;
  while ((m = re.exec(html))) hrefs.push(m[1].replace(/&amp;/g, "&"));
  var plain = str("public.utf8-plain-text");
  var bare = plain.match(/https?:\/\/[^\s<>"'）」]+/g) || [];
  return [
    "types: " + types.join(", "),
    "public.html: " + (html ? "yes" : "no"),
    "hrefs in html: " + (hrefs.length ? hrefs.join(" ") : "(none)"),
    "urls in plain text: " + (bare.length ? bare.join(" ") : "(none)"),
    "hidden links (href not in plain text): " +
      (hrefs.filter(function (h) { return plain.indexOf(h) < 0; }).join(" ") || "(none)"),
    "org.chromium.source-url: " + (str("org.chromium.source-url") || "(none)"),
  ].join("\n");
}
