// Transcript renderer for the chat panel. Swift calls appendLines / clearLines / setRunning.
const log = document.getElementById("log");
const empty = document.getElementById("empty");
const spinner = document.getElementById("spinner");
const OPEN = "", CLOSE = "";          // private-use marks around math placeholders

const escapeHTML = s => s.replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const imageURL = path => "petchat://app/image?p=" + encodeURIComponent(path);

function picture(href, alt) {
  const remote = /^(https:|data:image\/)/i.test(href);
  const src = remote ? href : imageURL(href);
  return `<a class="picture" href="${escapeHTML(src)}"><img src="${escapeHTML(src)}" alt="${escapeHTML(alt || "")}"></a>`;
}

marked.use({
  gfm: true,
  breaks: true,
  renderer: {
    html: ({ text }) => escapeHTML(text),         // model output never becomes live markup
    image: ({ href, text }) => picture(href, text),
  },
});

// Lifts math out of the source so Markdown can't mangle it (`_`, `*`, `\\`). Code spans and
// fences are matched first and left alone. `$` follows Pandoc's rule, so "$5 and $10" stays text.
const TOKENS = new RegExp([
  "(```[\\s\\S]*?(?:```|$)|~~~[\\s\\S]*?(?:~~~|$)|(`+)[^\\n]*?\\2)",            // 1,2 code
  "!\\[([^\\]\\n]*)\\]\\(((?:~|/)[^)<>\\n]*\\s[^)<>\\n]*)\\)",                  // 3,4 image path with spaces
  "\\$\\$([\\s\\S]+?)\\$\\$",                                                   // 5 display
  "\\\\\\[([\\s\\S]+?)\\\\\\]",                                                 // 6 display
  "\\\\\\(([\\s\\S]+?)\\\\\\)",                                                 // 7 inline
  "(?<![\\\\$\\w])\\$(?![\\s$])((?:\\\\.|[^$\\\\\\n])+?)(?<!\\s)\\$(?![\\d$])", // 8 inline
].join("|"), "g");

function renderMarkdown(source) {
  const math = [];
  const stash = (tex, displayMode) => {
    math.push(katex.renderToString(tex.trim(), { displayMode, throwOnError: false, output: "html" }));
    return OPEN + (math.length - 1) + CLOSE;
  };
  const prepared = source.replace(TOKENS, (all, code, _tick, alt, path, d1, d2, i1, i2) => {
    if (code !== undefined) return all;
    if (path !== undefined) return `![${alt}](<${path}>)`;
    if (d1 !== undefined || d2 !== undefined) return "\n\n" + stash(d1 ?? d2, true) + "\n\n";
    return stash(i1 ?? i2, false);
  });
  return marked.parse(prepared).replace(new RegExp(OPEN + "(\\d+)" + CLOSE, "g"), (_, i) => math[+i]);
}

function lineNode(line) {
  const node = document.createElement("div");
  node.className = line.kind;
  if (line.kind === "assistant") {
    node.innerHTML = renderMarkdown(line.text) + (line.images || []).map(p => picture(p, "")).join("");
  } else if (line.kind === "user") {
    const bubble = node.appendChild(document.createElement("div"));
    bubble.innerHTML = (line.images || []).map(p => picture(p, "")).join("");
    bubble.append(line.text);
  } else {
    node.textContent = line.text;
  }
  return node;
}

// Follow the conversation unless the user has scrolled up to read.
const page = document.scrollingElement;
let following = true;
const toBottom = () => { page.scrollTop = page.scrollHeight; };
addEventListener("scroll", () => {
  following = page.scrollHeight - page.scrollTop - innerHeight < 48;
}, { passive: true });

document.addEventListener("load", e => {
  if (e.target.tagName === "IMG" && following) toBottom();
}, true);
document.addEventListener("error", e => {
  if (e.target.tagName !== "IMG") return;
  const note = document.createElement("div");
  note.className = "missing";
  note.textContent = "Image not found: " + (e.target.alt || new URL(e.target.src).searchParams.get("p") || e.target.src);
  e.target.closest(".picture")?.replaceWith(note);
}, true);

window.appendLines = lines => {
  empty.hidden = true;
  for (const line of lines) log.appendChild(lineNode(line));
  following = true;
  toBottom();
};
window.clearLines = () => {
  log.textContent = "";
  empty.hidden = false;
};
window.setRunning = running => {
  spinner.hidden = !running;
  if (following) toBottom();
};
